package dev.wighawag.wezig;

import android.os.Handler;
import android.os.Looper;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * The Android `Renderer` backend's Java half (spec `explore-mobile-shell`,
 * story 5; ADR-0005/0006): the ONLY code in wezig that touches
 * `android.webkit.*`. It drives one {@link WebView} and translates its
 * `WebViewClient`/`WebChromeClient` load callbacks into the seam's
 * `LifecycleEvent` union by calling the Zig core's up-call entry points through
 * the JNI shim (`wezig_renderer_jni.c`).
 *
 * <h2>The thread contract (spec Q5 — the KNOWN GAP)</h2>
 *
 * `WebViewClient` callbacks (and `shouldInterceptRequest`, wired later) can
 * arrive on NON-UI (binder) threads. The seam's `LifecycleCallback` is
 * single-sink and, like the desktop WebKitGTK backend which emits on the GTK
 * main loop, must be delivered serialized on ONE thread. So EVERY callback here
 * is re-posted onto the UI thread via {@link #ui} (a
 * {@code Handler(Looper.getMainLooper())}) BEFORE it crosses into the Zig
 * up-call — the native side (`android_renderer.zig`) then performs no
 * cross-thread work and the chrome sees events exactly as it does on desktop.
 *
 * <p>Down-calls (navigate/reload/back/forward/…) originate from the seam via the
 * JNI shim and are issued on the UI thread by the shim; the WebView's own
 * methods require the UI thread, so this controller assumes UI-thread entry for
 * them (the instrumented test drives them from `runOnUiThread`).
 *
 * <p>This is NOT a full app — one WebView, one page, the narrowest real case
 * that proves the CONTENT seam carries Android. The chrome/embedding and the
 * two web3 hooks are downstream tasks.
 */
public final class WezigWebViewController {

    static {
        // The JNI shim (wezig_renderer_jni.c) + the linked Zig core live in
        // libwezigshell.so. Load it here so constructing a controller (e.g. from
        // the instrumented test) works without going through MainActivity.
        System.loadLibrary("wezigshell");
    }

    // Raw load-event codes, in lock-step with android_renderer.zig's
    // `AndroidLoadEvent`. The Zig side maps these onto the seam's `LoadState`.
    private static final int PAGE_STARTED = 0;
    private static final int PAGE_COMMITTED = 1;
    private static final int PAGE_FINISHED = 2;
    private static final int PAGE_FAILED = 3;

    /** Opaque handle to the Zig `*AndroidWebviewRenderer` (a jlong). */
    private final long nativeHandle;
    private final WebView webView;
    private final Handler ui = new Handler(Looper.getMainLooper());

    /**
     * Construct the backend over {@code webView}. {@code nativeHandle} is the
     * Zig renderer pointer the JNI shim created (via
     * {@link #nativeCreate(WezigWebViewController)}); it is threaded back into
     * every native up-call so the Zig side knows which renderer to dispatch to.
     */
    public WezigWebViewController(WebView webView) {
        this.webView = webView;
        this.webView.getSettings().setJavaScriptEnabled(true);
        this.nativeHandle = nativeCreate(this);

        this.webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageStarted(WebView view, String url, android.graphics.Bitmap favicon) {
                postLoadState(PAGE_STARTED, url);
            }

            @Override
            public void onPageCommitVisible(WebView view, String url) {
                postLoadState(PAGE_COMMITTED, url);
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                postLoadState(PAGE_FINISHED, url);
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                // Only the main-frame error is a load failure the seam cares about.
                if (request != null && request.isForMainFrame()) {
                    postLoadState(PAGE_FAILED, request.getUrl() != null ? request.getUrl().toString() : null);
                }
            }
        });

        this.webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int newProgress) {
                postProgress(newProgress);
            }

            @Override
            public void onReceivedTitle(WebView view, String title) {
                postTitle(title);
            }
        });
    }

    /** The live WebView (its JNI ref is the opaque `ViewHandle` on the seam). */
    public WebView webView() {
        return webView;
    }

    /** The Zig renderer pointer, so the shim can build the seam `Renderer`. */
    public long nativeHandle() {
        return nativeHandle;
    }

    /**
     * A subscriber to the seam's `.load_changed` lifecycle events, delivered
     * THROUGH the Zig `Renderer` seam (not observed off the WebView directly).
     * `code` is the raw `AndroidLoadEvent` (0=started,1=committed,2=finished,
     * 3=failed); `uri` may be null. This is the Android analogue of the desktop
     * `shell-test` seam sink — the instrumented test implements it to assert
     * `.finished` arrives.
     */
    public interface SeamLifecycleObserver {
        void onLoadState(int code, String uri);
    }

    private SeamLifecycleObserver seamObserver;

    /** Called from native (the seam callback) with each `.load_changed` event. */
    @SuppressWarnings("unused") // invoked via JNI
    private void onSeamLoadState(int code, String uri) {
        SeamLifecycleObserver obs = seamObserver;
        if (obs != null) obs.onLoadState(code, uri);
    }

    /**
     * Subscribe {@code observer} to the seam's lifecycle events. Installs a seam
     * callback on the Zig renderer; the up-call arrives on the UI thread (the
     * WebViewClient callbacks are already marshalled there).
     */
    public void setSeamLifecycleObserver(SeamLifecycleObserver observer) {
        this.seamObserver = observer;
        nativeSetLifecycleObserver(nativeHandle, this);
    }

    /** Drive a navigation THROUGH the seam (Java -> Zig seam -> WebView). */
    public void navigate(String uri) {
        nativeNavigate(nativeHandle, uri);
    }

    // --- WebViewClient callbacks -> UI thread -> Zig up-call ----------------
    // Each posts onto the UI thread so the native seam callback is serialized on
    // one thread (the thread contract above).

    private void postLoadState(int code, String url) {
        ui.post(() -> nativeOnLoadState(nativeHandle, code, url));
    }

    private void postUriChanged(String url) {
        ui.post(() -> nativeOnUriChanged(nativeHandle, url));
    }

    private void postTitle(String title) {
        ui.post(() -> nativeOnTitleChanged(nativeHandle, title));
    }

    private void postProgress(int percent) {
        ui.post(() -> nativeOnProgress(nativeHandle, percent));
    }

    // --- Down-calls the JNI shim invokes on the seam's behalf (UI thread) ----
    // The WebView's own methods must run on the UI thread; the shim ensures it.

    void doNavigate(String uri) {
        webView.loadUrl(uri);
    }

    void doReload() {
        webView.reload();
    }

    void doStop() {
        webView.stopLoading();
    }

    void doGoBack() {
        webView.goBack();
    }

    void doGoForward() {
        webView.goForward();
    }

    boolean doCanGoBack() {
        return webView.canGoBack();
    }

    boolean doCanGoForward() {
        return webView.canGoForward();
    }

    void doSetViewportSize(int width, int height) {
        // The embedded WebView tracks its size from Android layout; nothing to
        // do here today (mirrors the desktop backend's no-op). Kept so the seam
        // method has a home when a `WezigRenderer` needs an explicit viewport.
    }

    // --- Native (Zig) bindings ----------------------------------------------
    // Java -> Zig up-calls: declared native, implemented in wezig_renderer_jni.c
    // which forwards to android_renderer.zig's `wezig_android_on_*` export fns.

    private static native long nativeCreate(WezigWebViewController controller);

    private static native void nativeOnLoadState(long handle, int code, String uri);

    private static native void nativeOnUriChanged(long handle, String uri);

    private static native void nativeOnTitleChanged(long handle, String title);

    private static native void nativeOnProgress(long handle, int percent);

    // Seam down-call + observer wiring (drive/observe the seam, not the WebView).
    private static native void nativeNavigate(long handle, String uri);

    private static native void nativeSetLifecycleObserver(long handle, WezigWebViewController controller);
}
