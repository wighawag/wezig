/*
 * JNI shim for the wezig Android SHELL (spec `build-mobile-shell`, stories
 * 2/3/4/5/6; src/android_shell.zig). This is the real-app glue: it bridges the
 * Java `WezigShellController` (which owns the URL field / back-forward toolbar /
 * content container + the WebView-backed `Renderer`) to the Zig shell C-ABI
 * (`wezig_android_shell_*`), which composes the shared `MobileChrome` over the
 * `Renderer` + `MobileChromeSurface` seams.
 *
 *   - construction: `nativeShellStart(rendererHandle, controller, startUri)`
 *     builds a `CEmbedPlatform` whose ops call the Java shell controller's
 *     `do*` methods over JNI (embed the view, reflect the URL text + button
 *     enabled-state), then calls `wezig_android_shell_start` with the shim-owned
 *     renderer handle (the `*AndroidWebviewRenderer` the `WezigWebViewController`
 *     already built via `wezig_android_renderer_init`).
 *   - user intents (URL submit / Back / Forward / Reload): the `nativeShell*`
 *     down-calls fire the matching `ChromeIntent` INTO the surface THROUGH the
 *     Zig shell C-ABI, so navigation crosses the seams (never a raw WebView call
 *     above the backend).
 *
 * The Zig side is the ONLY seam logic; this shim is mechanical JNI glue. It
 * touches NO `android.webkit.*` (that is exclusively the Java controllers).
 */
#include <jni.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

// --- Zig core C-ABI (src/mobile_chrome_surface.zig + src/android_shell.zig) --

// The C-ABI mirror of the Zig `CEmbedPlatform` (field order MUST match). Same
// shape the embedding shim fills in; here the ops reflect chrome widget state.
typedef struct {
    void *host;
    void (*embedView)(void *host, void *view);
    void (*setUrlText)(void *host, const char *text);
    void (*setBackEnabled)(void *host, bool enabled);
    void (*setForwardEnabled)(void *host, bool enabled);
} WezigCEmbedPlatform;

extern void *wezig_android_shell_start(
    void *renderer_handle, const WezigCEmbedPlatform *cplatform, const char *start_uri);
extern void wezig_android_shell_navigate(void *ctx, const char *uri);
extern void wezig_android_shell_go_back(void *ctx);
extern void wezig_android_shell_go_forward(void *ctx);
extern void wezig_android_shell_reload(void *ctx);

// --- The Java-side host each embed/widget op needs --------------------------
//
// A `CEmbedPlatform.host` points at one of these: the cached JavaVM + a GLOBAL
// ref to the Java `WezigShellController`. The ops recover the controller and
// call its `do*` methods (embed the WebView; reflect URL text + button states).
typedef struct {
    JavaVM *vm;
    jobject controller; // global ref to the WezigShellController
} ShellCtx;

// One shell at a time (spec: one visible page; N-context tabs are Slice B), so a
// single tracked ctx suffices — the same discipline the other shims use — and
// teardown can free the global-ref + heap.
static ShellCtx *g_shell_ctx = NULL;

static JNIEnv *attach_env(ShellCtx *sc) {
    JNIEnv *env = NULL;
    (*sc->vm)->GetEnv(sc->vm, (void **)&env, JNI_VERSION_1_6);
    if (env == NULL) {
        (*sc->vm)->AttachCurrentThread(sc->vm, &env, NULL);
    }
    return env;
}

// --- CEmbedPlatform op implementations (call the Java shell controller) ------

static void shell_embed_view(void *host, void *view) {
    // `view` is the OPAQUE ViewHandle the Zig chrome-surface seam forwarded — a
    // JNI global-ref to the WebView. Downcast it back to the jobject and hand it
    // to the Java controller's `doEmbedView(WebView)` (a `ViewGroup.addView`).
    // THIS is the only place the opaque handle is interpreted (the seam never
    // touched it), mirroring the embedding shim.
    ShellCtx *sc = (ShellCtx *)host;
    if (!view) return;
    JNIEnv *env = attach_env(sc);
    jobject webview = (jobject)view;
    jclass cls = (*env)->GetObjectClass(env, sc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "doEmbedView", "(Landroid/webkit/WebView;)V");
    if (mid) (*env)->CallVoidMethod(env, sc->controller, mid, webview);
    (*env)->DeleteLocalRef(env, cls);
}

static void shell_set_url_text(void *host, const char *text) {
    ShellCtx *sc = (ShellCtx *)host;
    JNIEnv *env = attach_env(sc);
    jclass cls = (*env)->GetObjectClass(env, sc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "doSetUrlText", "(Ljava/lang/String;)V");
    if (mid) {
        jstring jtext = text ? (*env)->NewStringUTF(env, text) : NULL;
        (*env)->CallVoidMethod(env, sc->controller, mid, jtext);
        if (jtext) (*env)->DeleteLocalRef(env, jtext);
    }
    (*env)->DeleteLocalRef(env, cls);
}

static void shell_call_enabled(void *host, const char *method, bool enabled) {
    ShellCtx *sc = (ShellCtx *)host;
    JNIEnv *env = attach_env(sc);
    jclass cls = (*env)->GetObjectClass(env, sc->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, method, "(Z)V");
    if (mid) (*env)->CallVoidMethod(env, sc->controller, mid, enabled ? JNI_TRUE : JNI_FALSE);
    (*env)->DeleteLocalRef(env, cls);
}

static void shell_set_back_enabled(void *host, bool enabled) {
    shell_call_enabled(host, "doSetBackEnabled", enabled);
}
static void shell_set_forward_enabled(void *host, bool enabled) {
    shell_call_enabled(host, "doSetForwardEnabled", enabled);
}

// --- Java -> Zig: construct the shell + drive intents -----------------------

JNIEXPORT jlong JNICALL
Java_dev_wighawag_wezig_WezigShellController_nativeShellStart(
    JNIEnv *env, jclass clazz, jlong rendererHandle, jobject controller, jstring startUri) {
    (void)clazz;
    // Track a fresh ctx (freeing any prior one — one shell at a time).
    if (g_shell_ctx) {
        (*env)->DeleteGlobalRef(env, g_shell_ctx->controller);
        free(g_shell_ctx);
        g_shell_ctx = NULL;
    }
    ShellCtx *sc = (ShellCtx *)calloc(1, sizeof(ShellCtx));
    if (!sc) return 0;
    (*env)->GetJavaVM(env, &sc->vm);
    sc->controller = (*env)->NewGlobalRef(env, controller);

    WezigCEmbedPlatform cplatform = {
        .host = sc,
        .embedView = shell_embed_view,
        .setUrlText = shell_set_url_text,
        .setBackEnabled = shell_set_back_enabled,
        .setForwardEnabled = shell_set_forward_enabled,
    };

    const char *uri = startUri ? (*env)->GetStringUTFChars(env, startUri, NULL) : NULL;
    void *shell = wezig_android_shell_start(
        (void *)(intptr_t)rendererHandle, &cplatform, uri ? uri : "");
    if (uri) (*env)->ReleaseStringUTFChars(env, startUri, uri);

    if (!shell) {
        (*env)->DeleteGlobalRef(env, sc->controller);
        free(sc);
        return 0;
    }
    g_shell_ctx = sc;
    return (jlong)(intptr_t)shell;
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigShellController_nativeShellNavigate(
    JNIEnv *env, jclass clazz, jlong shellHandle, jstring uri) {
    (void)clazz;
    const char *c = uri ? (*env)->GetStringUTFChars(env, uri, NULL) : NULL;
    if (c) {
        wezig_android_shell_navigate((void *)(intptr_t)shellHandle, c);
        (*env)->ReleaseStringUTFChars(env, uri, c);
    }
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigShellController_nativeShellGoBack(
    JNIEnv *env, jclass clazz, jlong shellHandle) {
    (void)env;
    (void)clazz;
    wezig_android_shell_go_back((void *)(intptr_t)shellHandle);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigShellController_nativeShellGoForward(
    JNIEnv *env, jclass clazz, jlong shellHandle) {
    (void)env;
    (void)clazz;
    wezig_android_shell_go_forward((void *)(intptr_t)shellHandle);
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigShellController_nativeShellReload(
    JNIEnv *env, jclass clazz, jlong shellHandle) {
    (void)env;
    (void)clazz;
    wezig_android_shell_reload((void *)(intptr_t)shellHandle);
}

// Tear down the shell shim state: free the tracked `ShellCtx` (DeleteGlobalRef
// its controller ref + free the heap), so zero shell-side JNI global-refs
// outlive teardown. The Zig `android_shell` is a module-level value (not heap),
// so there is nothing to free on the Zig side; the renderer's own teardown
// (view ref + `JavaCtx`) is driven by WezigWebViewController.destroy().
JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigShellController_nativeShellDestroy(
    JNIEnv *env, jclass clazz, jlong shellHandle) {
    (void)clazz;
    (void)shellHandle;
    if (g_shell_ctx) {
        (*env)->DeleteGlobalRef(env, g_shell_ctx->controller);
        free(g_shell_ctx);
        g_shell_ctx = NULL;
    }
}
