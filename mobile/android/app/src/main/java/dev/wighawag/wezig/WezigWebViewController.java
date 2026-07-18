package dev.wighawag.wezig;

import android.os.Handler;
import android.os.Looper;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;

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

            // The custom-scheme hook (spec story 9): shouldInterceptRequest runs
            // on a NON-UI (binder) thread and MUST return synchronously (the
            // WebView blocks it waiting for the bytes), so unlike the load
            // callbacks it does NOT marshal to the UI thread — it up-calls the
            // Zig seam handler directly on this thread. The seam handler is the
            // native scheme handler (thread-safe by contract). See the thread
            // finding in android_renderer.zig's module doc.
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                if (request == null || request.getUrl() == null) return null;
                String uri = request.getUrl().toString();
                if (registeredScheme == null || !uri.startsWith(registeredScheme + ":")) {
                    return null; // not our scheme — let the WebView handle it.
                }
                SchemeResponse resp = nativeServeScheme(nativeHandle, uri);
                if (resp == null) return null;
                return new WebResourceResponse(
                    resp.contentType,
                    "utf-8",
                    new ByteArrayInputStream(resp.body.getBytes(StandardCharsets.UTF_8)));
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

    /** A subscriber to the seam's `.title_changed` event (delivered THROUGH the
     *  seam). The scheme test uses it to prove a native-served body rendered
     *  (its `<title>` marker reaching the seam). */
    public interface SeamTitleObserver {
        void onTitle(String title);
    }

    private SeamTitleObserver titleObserver;

    /** Called from native (the seam callback) with each `.title_changed` event. */
    @SuppressWarnings("unused") // invoked via JNI
    private void onSeamTitle(String title) {
        SeamTitleObserver obs = titleObserver;
        if (obs != null) obs.onTitle(title);
    }

    /** Subscribe {@code observer} to the seam's `.title_changed` events. Shares
     *  the single seam lifecycle sink with {@link #setSeamLifecycleObserver}. */
    public void setSeamTitleObserver(SeamTitleObserver observer) {
        this.titleObserver = observer;
        nativeSetLifecycleObserver(nativeHandle, this);
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

    // --- the two web3 hooks (spec stories 8,9) ----------------------------

    /** The channel name the addJavascriptInterface object posts under. */
    private String bridgeChannel;
    /** The registered custom scheme shouldInterceptRequest serves. */
    private String registeredScheme;

    /**
     * The page->native bridge object exposed via addJavascriptInterface. The
     * page calls `window.<channel>.postMessage(v)`; `postMessage` is invoked on
     * a PRIVATE binder thread (the JavaBridge thread), so it MARSHALS onto the
     * UI thread before crossing into the Zig seam — the same discipline as the
     * load callbacks (the thread contract).
     */
    private final class BridgeInterface {
        @JavascriptInterface
        public void postMessage(String body) {
            final String b = body;
            ui.post(() -> nativeOnScriptMessage(nativeHandle, bridgeChannel, b));
        }
    }

    /** Called from the Zig seam (via the JNI shim) to install the bridge object
     *  under `channel` (opens `window.<channel>.postMessage`). */
    @SuppressWarnings("unused") // invoked via JNI (bridge down-call)
    void doSetScriptMessageHandler(String channel) {
        this.bridgeChannel = channel;
        webView.addJavascriptInterface(new BridgeInterface(), channel);
    }

    /** Called from the Zig seam to inject a page-world script. Android has no
     *  document-start user-script API, so this evaluates the source; the app is
     *  expected to (re)inject on page start for a real bridge (see the finding). */
    @SuppressWarnings("unused") // invoked via JNI (bridge down-call)
    void doInjectUserScript(String source) {
        webView.evaluateJavascript(source, null);
    }

    /** Called from the Zig seam to evaluate JS back into the page (reply leg). */
    @SuppressWarnings("unused") // invoked via JNI (bridge down-call)
    void doEvaluateScript(String source) {
        webView.evaluateJavascript(source, null);
    }

    /** Called from the Zig seam to record which custom scheme
     *  shouldInterceptRequest serves from native. */
    @SuppressWarnings("unused") // invoked via JNI (scheme down-call)
    void doRegisterScheme(String scheme) {
        this.registeredScheme = scheme;
    }

    /** The native-served response shouldInterceptRequest builds a
     *  WebResourceResponse from. Populated by the Zig seam via the JNI shim. */
    public static final class SchemeResponse {
        public final String body;
        public final String contentType;
        public SchemeResponse(String body, String contentType) {
            this.body = body;
            this.contentType = contentType;
        }
    }

    // --- observer wiring for the instrumented bridge/scheme tests ---------
    // The tests subscribe THROUGH the seam (the Zig Renderer), mirroring the
    // desktop shell-bridge-test/shell-scheme-test, not the WebView directly.

    /** A page->native bridge observer (the instrumented bridge test's sink). */
    public interface SeamBridgeObserver {
        void onMessage(String name, String body);
    }

    private SeamBridgeObserver bridgeObserver;

    @SuppressWarnings("unused") // invoked via JNI (seam bridge up-call)
    private void onSeamScriptMessage(String name, String body) {
        SeamBridgeObserver obs = bridgeObserver;
        if (obs != null) obs.onMessage(name, body);
    }

    /** Register the page->native channel THROUGH the seam + subscribe a bridge
     *  observer (the addJavascriptInterface object is installed by the seam). */
    public void setSeamBridgeObserver(String channel, SeamBridgeObserver observer) {
        this.bridgeObserver = observer;
        nativeSetScriptMessageObserver(nativeHandle, channel, this);
    }

    /** Inject a page-world script THROUGH the seam (native->page setup leg). */
    public void injectUserScript(String source) {
        nativeInjectUserScript(nativeHandle, source);
    }

    /** Evaluate JS in the page THROUGH the seam (native->page reply leg). */
    public void evaluateScript(String source) {
        nativeEvaluateScript(nativeHandle, source);
    }

    /** A native scheme observer (the instrumented scheme test's server). */
    public interface SeamSchemeObserver {
        SchemeResponse onRequest(String uri);
    }

    private SeamSchemeObserver schemeObserver;

    @SuppressWarnings("unused") // invoked via JNI (seam scheme up-call, binder thread)
    private SchemeResponse onSeamSchemeRequest(String uri) {
        SeamSchemeObserver obs = schemeObserver;
        return obs != null ? obs.onRequest(uri) : null;
    }

    /** Register the custom scheme THROUGH the seam + subscribe a scheme observer
     *  (shouldInterceptRequest then serves it from the observer). */
    public void setSeamSchemeObserver(String scheme, SeamSchemeObserver observer) {
        this.schemeObserver = observer;
        this.registeredScheme = scheme;
        nativeRegisterSchemeObserver(nativeHandle, scheme, this);
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

    // The two web3 hooks (spec stories 8,9): seam down-calls + up-calls.
    private static native void nativeInjectUserScript(long handle, String source);

    private static native void nativeEvaluateScript(long handle, String source);

    private static native void nativeSetScriptMessageObserver(long handle, String channel, WezigWebViewController controller);

    private static native void nativeOnScriptMessage(long handle, String name, String body);

    private static native void nativeRegisterSchemeObserver(long handle, String scheme, WezigWebViewController controller);

    /** Java -> Zig scheme serve (binder thread): returns the native body +
     *  content-type for `uri`, or null if no handler is registered. */
    private static native SchemeResponse nativeServeScheme(long handle, String uri);
}
