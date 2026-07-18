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
    void (*setViewportSize)(void *ctx, int width, int height);
} WezigCJavaBridge;

// A C lifecycle observer the seam calls back with `.load_changed` events (the
// instrumented test subscribes THROUGH this, mirroring desktop shell-test).
typedef struct {
    void *ctx;
    void (*onLoadState)(void *ctx, int code, const char *uri);
} WezigCLifecycleObserver;

extern void *wezig_android_renderer_init(const WezigCJavaBridge *bridge);
extern void wezig_android_renderer_deinit(void *handle);
extern void wezig_android_navigate(void *handle, const char *uri);
extern void wezig_android_set_lifecycle_observer(void *handle, const WezigCLifecycleObserver *observer);

extern void wezig_android_on_load_state(void *handle, int code, const char *uri);
extern void wezig_android_on_uri_changed(void *handle, const char *uri);
extern void wezig_android_on_title_changed(void *handle, const char *title);
extern void wezig_android_on_progress(void *handle, int percent);

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

static void bridge_set_viewport(void *ctx, int width, int height) {
    JavaCtx *jc = (JavaCtx *)ctx;
    JNIEnv *env = attach_env(jc);
    jclass cls = (*env)->GetObjectClass(env, jc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "doSetViewportSize", "(II)V");
    if (mid) (*env)->CallVoidMethod(env, jc->controller, mid, (jint)width, (jint)height);
    (*env)->DeleteLocalRef(env, cls);
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
        .setViewportSize = bridge_set_viewport,
    };
    void *handle = wezig_android_renderer_init(&bridge);
    return (jlong)(intptr_t)handle;
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

    WezigCLifecycleObserver obs = { .ctx = jc, .onLoadState = observer_on_load_state };
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
