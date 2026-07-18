/*
 * JNI shim for the wezig Android `Renderer` backend (spec `explore-mobile-shell`
 * story 5; ADR-0005/0006). This bridges the Zig `AndroidWebviewRenderer`
 * (src/android_renderer.zig, in the linked Zig static core) to the Java
 * `WezigWebViewController` (which owns the `android.webkit.WebView`), in BOTH
 * directions:
 *
 *   - down-calls (seam -> WebView): the Zig renderer's `CJavaBridge` fn pointers
 *     (implemented here as `bridge_*`) call the Java `do*` methods over JNI, so
 *     `navigate`/`reload`/`back`/`forward`/… reach the real WebView.
 *   - up-calls (WebView -> seam): the Java WebViewClient callbacks arrive at the
 *     `nativeOn*` JNI functions here (already marshalled onto the UI thread by
 *     the controller), which convert the jstring to UTF-8 and forward to the Zig
 *     `wezig_android_on_*` entry points.
 *
 * The Zig side is the ONLY seam logic; this shim is the mechanical JNI glue and
 * the ONLY place `jni.h` meets the Zig C-ABI. It touches NO `android.webkit.*`
 * (that is exclusively the Java controller).
 */
#include <jni.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// --- Zig core C-ABI (src/android_renderer.zig export fns) -------------------

// The C-ABI mirror of the Zig `CJavaBridge` (field order MUST match).
typedef struct {
    void *ctx;
    void (*navigate)(void *ctx, const char *uri);
    void (*reload)(void *ctx);
    void (*stop)(void *ctx);
    void (*goBack)(void *ctx);
    void (*goForward)(void *ctx);
    bool (*canGoBack)(void *ctx);
    bool (*canGoForward)(void *ctx);
    void *(*view)(void *ctx);
    // Delete a JNI global-ref previously minted by `view` (DeleteGlobalRef).
    // Called EXACTLY ONCE on teardown, on the one cached view ref (ADR-0009
    // hazard). Mirror of the Zig `CJavaBridge.deleteView` — field order MUST
    // match: it sits between `view` and `setViewportSize`.
    void (*deleteView)(void *ctx, void *view);
    void (*setViewportSize)(void *ctx, int width, int height);
    // The two web3 hooks (spec stories 8,9).
    void (*injectUserScript)(void *ctx, const char *source);
    void (*setScriptMessageHandler)(void *ctx, const char *name);
    void (*evaluateScript)(void *ctx, const char *source);
    void (*registerScheme)(void *ctx, const char *scheme);
    // Free this bridge's own native side (the per-renderer `JavaCtx`: cached
    // JavaVM + the controller global-ref). Called EXACTLY ONCE on teardown,
    // AFTER `deleteView`, so no per-renderer JNI state outlives the backend
    // (ADR-0009 hazard). Mirror of the Zig `CJavaBridge.teardown` — LAST field.
    void (*teardown)(void *ctx);
} WezigCJavaBridge;

// A C lifecycle observer the seam calls back with `.load_changed` + `.title_changed`
// events (the instrumented test subscribes THROUGH this, mirroring desktop
// shell-test/shell-scheme-test). Field order MUST match android_renderer.zig's
// `CLifecycleObserver`.
typedef struct {
    void *ctx;
    void (*onLoadState)(void *ctx, int code, const char *uri);
    void (*onTitle)(void *ctx, const char *title);
} WezigCLifecycleObserver;

// A C bridge (page->native) observer the seam calls back with each page post.
typedef struct {
    void *ctx;
    void (*onMessage)(void *ctx, const char *name, const char *body);
} WezigCScriptMessageObserver;

// A C scheme observer: serves a request by writing the body/len/content-type
// out-params and returning true, or false to decline. Runs on the binder thread.
typedef struct {
    void *ctx;
    bool (*onRequest)(void *ctx, const char *uri,
                      const char **out_body, size_t *out_body_len,
                      const char **out_content_type);
} WezigCSchemeObserver;

extern void *wezig_android_renderer_init(const WezigCJavaBridge *bridge);
extern void wezig_android_renderer_deinit(void *handle);
extern void wezig_android_navigate(void *handle, const char *uri);
extern void wezig_android_set_lifecycle_observer(void *handle, const WezigCLifecycleObserver *observer);

extern void wezig_android_on_load_state(void *handle, int code, const char *uri);
extern void wezig_android_on_uri_changed(void *handle, const char *uri);
extern void wezig_android_on_title_changed(void *handle, const char *title);
extern void wezig_android_on_progress(void *handle, int percent);

// The two web3 hooks (spec stories 8,9): seam down-calls + up-calls.
extern void wezig_android_inject_user_script(void *handle, const char *source);
extern void wezig_android_evaluate_script(void *handle, const char *source);
extern void wezig_android_set_script_message_observer(
    void *handle, const char *name, const WezigCScriptMessageObserver *observer);
extern void wezig_android_on_script_message(void *handle, const char *name, const char *body);
extern void wezig_android_register_scheme_observer(
    void *handle, const char *scheme, const WezigCSchemeObserver *observer);
extern bool wezig_android_serve_scheme(
    void *handle, const char *uri,
    const char **out_body, size_t *out_body_len, const char **out_content_type);

// --- The Java-side context each bridge down-call needs ----------------------
//
// A `CJavaBridge.ctx` points at one of these: the cached JavaVM + a GLOBAL ref
// to the `WezigWebViewController` (a local ref would not survive past the JNI
// call that created the renderer). Down-calls attach the current thread and
// invoke the controller's `do*` methods.
typedef struct {
    JavaVM *vm;
    jobject controller; // global ref
} JavaCtx;

static JNIEnv *attach_env(JavaCtx *jc) {
    JNIEnv *env = NULL;
    (*jc->vm)->GetEnv(jc->vm, (void **)&env, JNI_VERSION_1_6);
    if (env == NULL) {
        (*jc->vm)->AttachCurrentThread(jc->vm, &env, NULL);
    }
    return env;
}

static void call_void(JavaCtx *jc, const char *method) {
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, method, "()V");
    if (mid) (*env)->CallVoidMethod(env, jc->controller, mid);
    (*env)->DeleteLocalRef(env, cls);
}

static bool call_bool(JavaCtx *jc, const char *method) {
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, method, "()Z");
    jboolean r = JNI_FALSE;
    if (mid) r = (*env)->CallBooleanMethod(env, jc->controller, mid);
    (*env)->DeleteLocalRef(env, cls);
    return r == JNI_TRUE;
}

// --- CJavaBridge down-call implementations ----------------------------------

static void bridge_navigate(void *ctx, const char *uri) {
    JavaCtx *jc = (JavaCtx *)ctx;
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "doNavigate", "(Ljava/lang/String;)V");
    if (mid) {
        jstring juri = (*env)->NewStringUTF(env, uri);
        (*env)->CallVoidMethod(env, jc->controller, mid, juri);
        (*env)->DeleteLocalRef(env, juri);
    }
    (*env)->DeleteLocalRef(env, cls);
}

static void bridge_reload(void *ctx) { call_void((JavaCtx *)ctx, "doReload"); }
static void bridge_stop(void *ctx) { call_void((JavaCtx *)ctx, "doStop"); }
static void bridge_go_back(void *ctx) { call_void((JavaCtx *)ctx, "doGoBack"); }
static void bridge_go_forward(void *ctx) { call_void((JavaCtx *)ctx, "doGoForward"); }
static bool bridge_can_go_back(void *ctx) { return call_bool((JavaCtx *)ctx, "doCanGoBack"); }
static bool bridge_can_go_forward(void *ctx) { return call_bool((JavaCtx *)ctx, "doCanGoForward"); }

static void *bridge_view(void *ctx) {
    // The opaque `ViewHandle` is the Java WebView as a JNI GLOBAL ref (spec Q3:
    // on Android the handle is a JNI reference, not a raw pointer). The embedding
    // task downcasts it; here we hand the controller's `webView()` global ref.
    JavaCtx *jc = (JavaCtx *)ctx;
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "webView", "()Landroid/webkit/WebView;");
    void *handle = NULL;
    if (mid) {
        jobject webview = (*env)->CallObjectMethod(env, jc->controller, mid);
        if (webview) handle = (*env)->NewGlobalRef(env, webview);
        (*env)->DeleteLocalRef(env, webview);
    }
    (*env)->DeleteLocalRef(env, cls);
    return handle;
}

// Delete a JNI global-ref previously minted by `bridge_view` (the backend caches
// exactly one per view and hands it back here on teardown). Runs on the UI
// thread (teardown is host-driven). `view` is the same global-ref bridge_view
// returned; DeleteGlobalRef releases it so the net live-ref count returns to
// zero (ADR-0009 hazard: the spike leaked a ref per `view()` call).
static void bridge_delete_view(void *ctx, void *view) {
    JavaCtx *jc = (JavaCtx *)ctx;
    if (!view) return;
    JNIEnv *env = attach_env(jc);
    (*env)->DeleteGlobalRef(env, (jobject)view);
}

// Free this renderer's own native context (the per-renderer `JavaCtx`: the
// cached JavaVM + the global-ref to the Java controller). Called EXACTLY ONCE on
// teardown, AFTER bridge_delete_view, so no per-renderer JNI global-ref outlives
// the backend (ADR-0009 hazard: the spike's `wezig_android_renderer_deinit` only
// freed the Zig adapter, leaking this ctx). The renderer-side analogue of the
// embedding shim's `EmbedCtx` free.
static void bridge_teardown(void *ctx) {
    JavaCtx *jc = (JavaCtx *)ctx;
    if (!jc) return;
    JNIEnv *env = attach_env(jc);
    if (jc->controller) (*env)->DeleteGlobalRef(env, jc->controller);
    free(jc);
}

static void bridge_set_viewport(void *ctx, int width, int height) {
    JavaCtx *jc = (JavaCtx *)ctx;
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "doSetViewportSize", "(II)V");
    if (mid) (*env)->CallVoidMethod(env, jc->controller, mid, (jint)width, (jint)height);
    (*env)->DeleteLocalRef(env, cls);
}

// --- the two web3 hooks: down-call impls (call the Java `do*` string methods) --

static void call_string(JavaCtx *jc, const char *method, const char *arg) {
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, method, "(Ljava/lang/String;)V");
    if (mid) {
        jstring jarg = (*env)->NewStringUTF(env, arg);
        (*env)->CallVoidMethod(env, jc->controller, mid, jarg);
        (*env)->DeleteLocalRef(env, jarg);
    }
    (*env)->DeleteLocalRef(env, cls);
}

static void bridge_inject_user_script(void *ctx, const char *source) {
    call_string((JavaCtx *)ctx, "doInjectUserScript", source);
}
static void bridge_set_script_message_handler(void *ctx, const char *name) {
    call_string((JavaCtx *)ctx, "doSetScriptMessageHandler", name);
}
static void bridge_evaluate_script(void *ctx, const char *source) {
    call_string((JavaCtx *)ctx, "doEvaluateScript", source);
}
static void bridge_register_scheme(void *ctx, const char *scheme) {
    call_string((JavaCtx *)ctx, "doRegisterScheme", scheme);
}

// --- Java -> Zig up-calls (nativeOn*) ---------------------------------------
// `handle` is the Zig `*AndroidWebviewRenderer` returned by nativeCreate, boxed
// as a jlong. Strings are converted to UTF-8 (freed after the forward); a null
// jstring passes a null pointer through (the Zig side is null-safe).

JNIEXPORT jlong JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeCreate(
    JNIEnv *env, jclass clazz, jobject controller) {
    (void)clazz;
    JavaCtx *jc = (JavaCtx *)calloc(1, sizeof(JavaCtx));
    if (!jc) return 0;
    (*env)->GetJavaVM(env, &jc->vm);
    jc->controller = (*env)->NewGlobalRef(env, controller);

    WezigCJavaBridge bridge = {
        .ctx = jc,
        .navigate = bridge_navigate,
        .reload = bridge_reload,
        .stop = bridge_stop,
        .goBack = bridge_go_back,
        .goForward = bridge_go_forward,
        .canGoBack = bridge_can_go_back,
        .canGoForward = bridge_can_go_forward,
        .view = bridge_view,
        .deleteView = bridge_delete_view,
        .setViewportSize = bridge_set_viewport,
        .injectUserScript = bridge_inject_user_script,
        .setScriptMessageHandler = bridge_set_script_message_handler,
        .evaluateScript = bridge_evaluate_script,
        .registerScheme = bridge_register_scheme,
        .teardown = bridge_teardown,
    };
    void *handle = wezig_android_renderer_init(&bridge);
    return (jlong)(intptr_t)handle;
}

// Tear down the renderer: `wezig_android_renderer_deinit` runs the backend
// teardown (deleting the one cached view global-ref via `bridge_delete_view`,
// then freeing this renderer's `JavaCtx` via `bridge_teardown`) BEFORE freeing
// the Zig adapter, so no JNI global-ref (view ref + renderer `JavaCtx`) outlives
// the backend (ADR-0009 leak fixes wired here from the backend task).
JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeDestroy(
    JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    wezig_android_renderer_deinit((void *)(intptr_t)handle);
}

// --- Seam lifecycle observer -> Java (the instrumented test's sink) ---------
//
// One observer at a time (the seam is single-sink). The observer's `ctx` caches
// the JavaVM + a global ref to the Java observer object, whose
// `onSeamLoadState(int code, String uri)` is called with each seam event.
static JavaCtx *g_observer_ctx = NULL;

static void observer_on_load_state(void *ctx, int code, const char *uri) {
    JavaCtx *jc = (JavaCtx *)ctx;
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onSeamLoadState", "(ILjava/lang/String;)V");
    if (mid) {
        jstring juri = uri ? (*env)->NewStringUTF(env, uri) : NULL;
        (*env)->CallVoidMethod(env, jc->controller, mid, (jint)code, juri);
        if (juri) (*env)->DeleteLocalRef(env, juri);
    }
    (*env)->DeleteLocalRef(env, cls);
}

static void observer_on_title(void *ctx, const char *title) {
    JavaCtx *jc = (JavaCtx *)ctx;
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onSeamTitle", "(Ljava/lang/String;)V");
    if (mid) {
        jstring jtitle = title ? (*env)->NewStringUTF(env, title) : NULL;
        (*env)->CallVoidMethod(env, jc->controller, mid, jtitle);
        if (jtitle) (*env)->DeleteLocalRef(env, jtitle);
    }
    (*env)->DeleteLocalRef(env, cls);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeSetLifecycleObserver(
    JNIEnv *env, jclass clazz, jlong handle, jobject observer) {
    (void)clazz;
    if (g_observer_ctx) {
        (*env)->DeleteGlobalRef(env, g_observer_ctx->controller);
        free(g_observer_ctx);
    }
    JavaCtx *jc = (JavaCtx *)calloc(1, sizeof(JavaCtx));
    if (!jc) return;
    (*env)->GetJavaVM(env, &jc->vm);
    jc->controller = (*env)->NewGlobalRef(env, observer);
    g_observer_ctx = jc;

    WezigCLifecycleObserver obs = {
        .ctx = jc,
        .onLoadState = observer_on_load_state,
        .onTitle = observer_on_title,
    };
    wezig_android_set_lifecycle_observer((void *)(intptr_t)handle, &obs);
}

static const char *cstr_or_null(JNIEnv *env, jstring s) {
    return s ? (*env)->GetStringUTFChars(env, s, NULL) : NULL;
}
static void release_cstr(JNIEnv *env, jstring s, const char *c) {
    if (s && c) (*env)->ReleaseStringUTFChars(env, s, c);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeNavigate(
    JNIEnv *env, jclass clazz, jlong handle, jstring uri) {
    (void)clazz;
    const char *c = uri ? (*env)->GetStringUTFChars(env, uri, NULL) : NULL;
    if (c) {
        wezig_android_navigate((void *)(intptr_t)handle, c);
        (*env)->ReleaseStringUTFChars(env, uri, c);
    }
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeOnLoadState(
    JNIEnv *env, jclass clazz, jlong handle, jint code, jstring uri) {
    (void)clazz;
    const char *c = cstr_or_null(env, uri);
    wezig_android_on_load_state((void *)(intptr_t)handle, (int)code, c);
    release_cstr(env, uri, c);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeOnUriChanged(
    JNIEnv *env, jclass clazz, jlong handle, jstring uri) {
    (void)clazz;
    const char *c = cstr_or_null(env, uri);
    wezig_android_on_uri_changed((void *)(intptr_t)handle, c);
    release_cstr(env, uri, c);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeOnTitleChanged(
    JNIEnv *env, jclass clazz, jlong handle, jstring title) {
    (void)clazz;
    const char *c = cstr_or_null(env, title);
    wezig_android_on_title_changed((void *)(intptr_t)handle, c);
    release_cstr(env, title, c);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeOnProgress(
    JNIEnv *env, jclass clazz, jlong handle, jint percent) {
    (void)env;
    (void)clazz;
    wezig_android_on_progress((void *)(intptr_t)handle, (int)percent);
}

// --- the two web3 hooks: seam down-calls + up-calls (spec stories 8,9) --------

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeInjectUserScript(
    JNIEnv *env, jclass clazz, jlong handle, jstring source) {
    (void)clazz;
    const char *c = cstr_or_null(env, source);
    if (c) wezig_android_inject_user_script((void *)(intptr_t)handle, c);
    release_cstr(env, source, c);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeEvaluateScript(
    JNIEnv *env, jclass clazz, jlong handle, jstring source) {
    (void)clazz;
    const char *c = cstr_or_null(env, source);
    if (c) wezig_android_evaluate_script((void *)(intptr_t)handle, c);
    release_cstr(env, source, c);
}

// The page->native bridge observer: forwards each seam message to the Java
// controller's `onSeamScriptMessage(String,String)` (the instrumented test's
// sink). One observer at a time (the seam channel is single today).
static JavaCtx *g_msg_observer_ctx = NULL;

static void bridge_observer_on_message(void *ctx, const char *name, const char *body) {
    JavaCtx *jc = (JavaCtx *)ctx;
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "onSeamScriptMessage",
                                        "(Ljava/lang/String;Ljava/lang/String;)V");
    if (mid) {
        jstring jname = name ? (*env)->NewStringUTF(env, name) : NULL;
        jstring jbody = body ? (*env)->NewStringUTF(env, body) : NULL;
        (*env)->CallVoidMethod(env, jc->controller, mid, jname, jbody);
        if (jname) (*env)->DeleteLocalRef(env, jname);
        if (jbody) (*env)->DeleteLocalRef(env, jbody);
    }
    (*env)->DeleteLocalRef(env, cls);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeSetScriptMessageObserver(
    JNIEnv *env, jclass clazz, jlong handle, jstring channel, jobject observer) {
    (void)clazz;
    if (g_msg_observer_ctx) {
        (*env)->DeleteGlobalRef(env, g_msg_observer_ctx->controller);
        free(g_msg_observer_ctx);
    }
    JavaCtx *jc = (JavaCtx *)calloc(1, sizeof(JavaCtx));
    if (!jc) return;
    (*env)->GetJavaVM(env, &jc->vm);
    jc->controller = (*env)->NewGlobalRef(env, observer);
    g_msg_observer_ctx = jc;

    const char *c = cstr_or_null(env, channel);
    WezigCScriptMessageObserver obs = { .ctx = jc, .onMessage = bridge_observer_on_message };
    wezig_android_set_script_message_observer((void *)(intptr_t)handle, c ? c : "", &obs);
    release_cstr(env, channel, c);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeOnScriptMessage(
    JNIEnv *env, jclass clazz, jlong handle, jstring name, jstring body) {
    (void)clazz;
    const char *cn = cstr_or_null(env, name);
    const char *cb = cstr_or_null(env, body);
    wezig_android_on_script_message((void *)(intptr_t)handle, cn, cb);
    release_cstr(env, name, cn);
    release_cstr(env, body, cb);
}

// The native scheme observer: serves each request by calling the Java
// controller's `onSeamSchemeRequest(String)` -> a SchemeResponse, and copying
// its body/content-type into the out-params. Runs on the BINDER thread (the
// shouldInterceptRequest thread contract), so it attaches the current thread.
// The copied strings are owned by this shim and freed on the NEXT serve (the
// seam contract: borrowed until the handler is next called).
static JavaCtx *g_scheme_observer_ctx = NULL;
static char *g_scheme_body = NULL;
static char *g_scheme_ct = NULL;

static bool scheme_observer_on_request(void *ctx, const char *uri,
                                       const char **out_body, size_t *out_body_len,
                                       const char **out_content_type) {
    JavaCtx *jc = (JavaCtx *)ctx;
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(
        env, cls, "onSeamSchemeRequest",
        "(Ljava/lang/String;)Ldev/wighawag/wezig/WezigWebViewController$SchemeResponse;");
    bool served = false;
    if (mid) {
        jstring juri = uri ? (*env)->NewStringUTF(env, uri) : NULL;
        jobject resp = (*env)->CallObjectMethod(env, jc->controller, mid, juri);
        if (juri) (*env)->DeleteLocalRef(env, juri);
        if (resp) {
            jclass rcls = (*env)->GetObjectClass(env, resp);
            jfieldID fbody = (*env)->GetFieldID(env, rcls, "body", "Ljava/lang/String;");
            jfieldID fct = (*env)->GetFieldID(env, rcls, "contentType", "Ljava/lang/String;");
            jstring jbody = (jstring)(*env)->GetObjectField(env, resp, fbody);
            jstring jct = (jstring)(*env)->GetObjectField(env, resp, fct);
            const char *body = cstr_or_null(env, jbody);
            const char *ct = cstr_or_null(env, jct);
            // Copy into shim-owned storage (freed on the next serve).
            free(g_scheme_body);
            free(g_scheme_ct);
            g_scheme_body = body ? strdup(body) : strdup("");
            g_scheme_ct = ct ? strdup(ct) : strdup("text/plain");
            *out_body = g_scheme_body;
            *out_body_len = strlen(g_scheme_body);
            *out_content_type = g_scheme_ct;
            served = true;
            release_cstr(env, jbody, body);
            release_cstr(env, jct, ct);
            (*env)->DeleteLocalRef(env, rcls);
            (*env)->DeleteLocalRef(env, jbody);
            (*env)->DeleteLocalRef(env, jct);
            (*env)->DeleteLocalRef(env, resp);
        }
    }
    (*env)->DeleteLocalRef(env, cls);
    return served;
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeRegisterSchemeObserver(
    JNIEnv *env, jclass clazz, jlong handle, jstring scheme, jobject observer) {
    (void)clazz;
    if (g_scheme_observer_ctx) {
        (*env)->DeleteGlobalRef(env, g_scheme_observer_ctx->controller);
        free(g_scheme_observer_ctx);
    }
    JavaCtx *jc = (JavaCtx *)calloc(1, sizeof(JavaCtx));
    if (!jc) return;
    (*env)->GetJavaVM(env, &jc->vm);
    jc->controller = (*env)->NewGlobalRef(env, observer);
    g_scheme_observer_ctx = jc;

    const char *c = cstr_or_null(env, scheme);
    WezigCSchemeObserver obs = { .ctx = jc, .onRequest = scheme_observer_on_request };
    wezig_android_register_scheme_observer((void *)(intptr_t)handle, c ? c : "", &obs);
    release_cstr(env, scheme, c);
}

JNIEXPORT jobject JNICALL
Java_dev_wighawag_wezig_WezigWebViewController_nativeServeScheme(
    JNIEnv *env, jclass clazz, jlong handle, jstring uri) {
    (void)clazz;
    const char *c = cstr_or_null(env, uri);
    const char *body = NULL;
    size_t body_len = 0;
    const char *ct = NULL;
    bool served = wezig_android_serve_scheme((void *)(intptr_t)handle, c, &body, &body_len, &ct);
    release_cstr(env, uri, c);
    if (!served) return NULL;

    // Build a WezigWebViewController$SchemeResponse(body, contentType).
    jclass rcls = (*env)->FindClass(env, "dev/wighawag/wezig/WezigWebViewController$SchemeResponse");
    if (!rcls) return NULL;
    jmethodID ctor = (*env)->GetMethodID(env, rcls, "<init>",
                                         "(Ljava/lang/String;Ljava/lang/String;)V");
    if (!ctor) return NULL;
    // body is NUL-terminated (the seam's proof bodies are), so NewStringUTF is
    // safe; a binary body would need a length-aware path (out of scope here).
    jstring jbody = (*env)->NewStringUTF(env, body ? body : "");
    jstring jct = (*env)->NewStringUTF(env, ct ? ct : "text/plain");
    jobject resp = (*env)->NewObject(env, rcls, ctor, jbody, jct);
    (*env)->DeleteLocalRef(env, jbody);
    (*env)->DeleteLocalRef(env, jct);
    (*env)->DeleteLocalRef(env, rcls);
    return resp;
}
