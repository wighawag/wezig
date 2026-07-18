/*
 * JNI shim for the wezig Android ViewHandle-EMBEDDING proof (spec
 * `explore-mobile-shell`, Q3/story 6; task mobile-viewhandle-embedding-proof;
 * ADR-0006's opaque ViewHandle, ADR-0007's flagged cross-toolkit-embedding
 * spike). This is the SHARP mobile risk: on Android the renderer's view is a JNI
 * global-ref to the `android.webkit.WebView`, not a raw pointer. This shim proves
 * that opaque handle carries across the chrome-surface `embedView` seam:
 *
 *   1. The instrumented test gets the renderer's opaque `ViewHandle` (a JNI
 *      global-ref) from the Zig `Renderer` seam (`wezig_android_renderer_view`).
 *   2. It drives `nativeEmbedView(surfaceHandle, viewHandle)` here, which calls
 *      `wezig_android_embed_view` (mobile_chrome_surface.zig) — the Zig
 *      chrome-surface's `embedView`, which forwards the OPAQUE bits back to this
 *      shim's `embed_view` op (installed via `CEmbedPlatform`).
 *   3. `embed_view` downcasts the opaque handle back to the `WebView` jobject and
 *      calls the Java controller's `doEmbedView(WebView)` (a `ViewGroup.addView`).
 *
 * So the JNI global-ref goes: renderer seam -> opaque `*anyopaque` -> chrome
 * surface seam -> opaque `*anyopaque` -> native downcast -> `ViewGroup.addView`,
 * with the Zig side never interpreting it. This is the Android answer to the Q3
 * question: does the opaque contract cleanly carry a JNI global-ref across the
 * mobile toolkit<->renderer boundary.
 *
 * The Zig side is the ONLY seam logic; this shim is mechanical JNI glue and one
 * of only two places `jni.h` meets the Zig C-ABI. It touches NO
 * `android.webkit.*` (that is the Java controller).
 */
#include <jni.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

// --- Zig core C-ABI (src/mobile_chrome_surface.zig export fns) --------------

// The C-ABI mirror of the Zig `CEmbedPlatform` (field order MUST match).
typedef struct {
    void *host;
    void (*embedView)(void *host, void *view);
    void (*setUrlText)(void *host, const char *text);
    void (*setBackEnabled)(void *host, bool enabled);
    void (*setForwardEnabled)(void *host, bool enabled);
} WezigCEmbedPlatform;

extern void *wezig_android_chrome_surface_init(const WezigCEmbedPlatform *platform);
extern void wezig_android_chrome_surface_deinit(void *handle);
extern void wezig_android_embed_view(void *handle, void *view);

// The Zig Renderer-seam accessor (src/android_renderer.zig) that returns the
// renderer's opaque ViewHandle (a JNI global-ref to the WebView).
extern void *wezig_android_renderer_view(void *renderer_handle);

// --- The Java-side host each embed op needs ---------------------------------
//
// A `CEmbedPlatform.host` points at one of these: the cached JavaVM + a GLOBAL
// ref to the Java `WezigEmbeddingController`. The `embed_view` op recovers the
// jobject WebView from the opaque handle and calls the controller's
// `doEmbedView(WebView)`.
typedef struct {
    JavaVM *vm;
    jobject controller; // global ref to the WezigEmbeddingController
} EmbedCtx;

static JNIEnv *attach_env(EmbedCtx *ec) {
    JNIEnv *env = NULL;
    (*ec->vm)->GetEnv(ec->vm, (void **)&env, JNI_VERSION_1_6);
    if (env == NULL) {
        (*ec->vm)->AttachCurrentThread(ec->vm, &env, NULL);
    }
    return env;
}

// --- CEmbedPlatform op implementations --------------------------------------

static void embed_view(void *host, void *view) {
    // `view` is the OPAQUE ViewHandle the Zig chrome-surface seam forwarded — a
    // JNI global-ref to the WebView (spec Q3). Downcast it back to the jobject
    // and hand it to the Java controller's `doEmbedView(WebView)`. THIS is the
    // only place the opaque handle is interpreted (the seam never touched it).
    EmbedCtx *ec = (EmbedCtx *)host;
    if (!view) return;
    JNIEnv *env = attach_env(ec);
    jobject webview = (jobject)view;
    jclass cls = (*env)->GetObjectClass(env, ec->controller);
    jmethodID mid = (*env)->GetMethodID(env, cls, "doEmbedView", "(Landroid/webkit/WebView;)V");
    if (mid) (*env)->CallVoidMethod(env, ec->controller, mid, webview);
    (*env)->DeleteLocalRef(env, cls);
}

static void embed_set_url_text(void *host, const char *text) {
    (void)host;
    (void)text; // No URL bar in the narrowest-case proof; op is total but inert.
}
static void embed_set_back_enabled(void *host, bool enabled) {
    (void)host;
    (void)enabled;
}
static void embed_set_forward_enabled(void *host, bool enabled) {
    (void)host;
    (void)enabled;
}

// The live embed ctx (the seam hosts one surface at a time — the same
// single-instance discipline the renderer shim's `g_*_observer_ctx` use), so
// `nativeDestroySurface` can free the `EmbedCtx` global-ref + heap on teardown
// instead of leaking it (the ADR-0009 `EmbedCtx` leak fix, deferred here from
// the backend task's `android-renderer-reinject-and-globalref-fix`).
static EmbedCtx *g_embed_ctx = NULL;

// --- Java -> Zig: construct the chrome-surface + drive one embed -------------

/*
 * Construct the mobile chrome-surface over `controller` (a WezigEmbeddingController
 * that owns the container ViewGroup + implements `doEmbedView`). Returns the Zig
 * `*MobileChromeSurface` boxed as a jlong.
 */
JNIEXPORT jlong JNICALL
Java_dev_wighawag_wezig_WezigEmbeddingController_nativeCreateSurface(
    JNIEnv *env, jclass clazz, jobject controller) {
    (void)clazz;
    EmbedCtx *ec = (EmbedCtx *)calloc(1, sizeof(EmbedCtx));
    if (!ec) return 0;
    (*env)->GetJavaVM(env, &ec->vm);
    ec->controller = (*env)->NewGlobalRef(env, controller);

    WezigCEmbedPlatform platform = {
        .host = ec,
        .embedView = embed_view,
        .setUrlText = embed_set_url_text,
        .setBackEnabled = embed_set_back_enabled,
        .setForwardEnabled = embed_set_forward_enabled,
    };
    void *handle = wezig_android_chrome_surface_init(&platform);
    if (!handle) {
        (*env)->DeleteGlobalRef(env, ec->controller);
        free(ec);
        return 0;
    }
    // Track the ctx so teardown can release its global-ref + heap (one surface
    // at a time). If a prior surface was never destroyed, free it now so we do
    // not leak the earlier ctx by overwriting the tracker.
    if (g_embed_ctx) {
        (*env)->DeleteGlobalRef(env, g_embed_ctx->controller);
        free(g_embed_ctx);
    }
    g_embed_ctx = ec;
    return (jlong)(intptr_t)handle;
}

JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigEmbeddingController_nativeDestroySurface(
    JNIEnv *env, jclass clazz, jlong surfaceHandle) {
    (void)env;
    (void)clazz;
    wezig_android_chrome_surface_deinit((void *)(intptr_t)surfaceHandle);
    // Free the `EmbedCtx`: DeleteGlobalRef its controller ref + free the heap, so
    // zero JNI global-refs outlive teardown (ADR-0009 hazard; the literal
    // `EmbedCtx` free deferred to this task from the backend's global-ref fix).
    // The Zig `CAndroidSurface` (which held `ec` as its `EmbedPlatform.host`) is
    // already freed by `..._deinit` above; `g_embed_ctx` is the shim-side tracker
    // so we can still reach the ctx here.
    if (g_embed_ctx) {
        (*env)->DeleteGlobalRef(env, g_embed_ctx->controller);
        free(g_embed_ctx);
        g_embed_ctx = NULL;
    }
}

/*
 * Obtain the renderer's opaque ViewHandle (a JNI global-ref to the WebView) from
 * the Zig Renderer seam, then embed it THROUGH the chrome-surface seam. This is
 * the whole Q3 proof at the C boundary: the JNI global-ref crosses
 * `Renderer.view()` -> opaque -> `ChromeSurface.embedView` -> opaque -> native
 * downcast, all without the Zig side interpreting the handle.
 */
JNIEXPORT void JNICALL
Java_dev_wighawag_wezig_WezigEmbeddingController_nativeEmbedRendererView(
    JNIEnv *env, jclass clazz, jlong surfaceHandle, jlong rendererHandle) {
    (void)env;
    (void)clazz;
    void *view = wezig_android_renderer_view((void *)(intptr_t)rendererHandle);
    wezig_android_embed_view((void *)(intptr_t)surfaceHandle, view);
}
