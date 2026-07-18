package dev.wighawag.wezig;

import android.content.Context;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;

/**
 * The Android shell's chrome-surface HOST (spec {@code build-mobile-shell},
 * stories 2/3/4/5/6; the Android twin of the iOS
 * {@code WKWebViewShellController}). It lays out a URL field + a back/forward
 * (+ reload) toolbar + a content container, constructs the shared mobile chrome
 * over the WebView-backed {@code Renderer} + the mobile {@code ChromeSurface}
 * (via the shell JNI shim {@code wezig_shell_jni.c} → {@code src/android_shell.zig}),
 * and drives navigation ENTIRELY through the shell C-ABI (the chrome/seams) —
 * never a raw {@code android.webkit.*} call (that discipline lives in
 * {@link WezigWebViewController}, the sole {@code android.webkit.*} toucher).
 *
 * <h2>What is wired here (all THROUGH the seams)</h2>
 * <ul>
 *   <li>URL field submit → {@code nativeShellNavigate} (a {@code .navigate} intent)</li>
 *   <li>Back / Forward tap → {@code nativeShellGoBack} / {@code nativeShellGoForward}</li>
 *   <li>Reload tap → {@code nativeShellReload}</li>
 *   <li>The shared {@code MobileChrome} reflects {@code Renderer} lifecycle events
 *       back into the URL field text + the Back/Forward buttons' enabled state via
 *       the {@code CEmbedPlatform} ops ({@link #doSetUrlText}/{@link #doSetBackEnabled}/
 *       {@link #doSetForwardEnabled}), so the chrome MIRRORS the renderer's
 *       lifecycle exactly as the desktop chrome does (story 5).</li>
 * </ul>
 *
 * <h2>Background/foreground state restoration is HOST-ONLY (ADR-0010, Resolved 1)</h2>
 * A background→foreground round-trip preserves the current page WITHOUT any
 * {@code Renderer} seam change: {@link MainActivity} wires
 * {@code onSaveInstanceState}/{@code onRestoreInstanceState} +
 * {@link WebView#saveState}/{@link WebView#restoreState} (the OS mandate). See
 * {@link #saveState(Bundle)} / {@link #restoreState(Bundle)}. No suspend/resume/
 * state seam method is added.
 *
 * <p>Emulator/unsigned-debug only (signing is Slice C).
 */
public final class WezigShellController {

    static {
        // libwezigshell.so carries the shell JNI shim + the linked Zig core.
        System.loadLibrary("wezigshell");
    }

    private static final String STATE_WEBVIEW = "wezig.webview.state";

    private final WebView webView;
    private final WezigWebViewController renderer;

    // Chrome widgets (the Android side of the mobile ChromeSurface).
    private final LinearLayout root;
    private final EditText urlField;
    private final Button backButton;
    private final Button forwardButton;
    private final Button reloadButton;
    private final FrameLayout contentContainer;

    /** Opaque handle to the Zig shell context (a jlong from nativeShellStart). */
    private long shellHandle;

    /** The last URL the chrome reflected (kept so the field can be restored). */
    private String currentUrlText = "";

    /**
     * Build the shell over {@code context}: lay out the chrome, construct the
     * WebView-backed renderer, and start the shared mobile chrome navigating
     * {@code startUri} THROUGH the seams.
     */
    public WezigShellController(Context context, String startUri) {
        this.webView = new WebView(context);
        this.renderer = new WezigWebViewController(webView);

        // --- layout: [ ◀ ▶ ⟳ | url field ] over a content container ---
        this.root = new LinearLayout(context);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setLayoutParams(new ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        LinearLayout toolbar = new LinearLayout(context);
        toolbar.setOrientation(LinearLayout.HORIZONTAL);
        toolbar.setGravity(Gravity.CENTER_VERTICAL);
        toolbar.setPadding(dp(context, 8), dp(context, 8), dp(context, 8), dp(context, 8));
        toolbar.setLayoutParams(new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        backButton = new Button(context);
        backButton.setText("\u25C0"); // ◀
        backButton.setEnabled(false);
        backButton.setOnClickListener(v -> onBack());

        forwardButton = new Button(context);
        forwardButton.setText("\u25B6"); // ▶
        forwardButton.setEnabled(false);
        forwardButton.setOnClickListener(v -> onForward());

        reloadButton = new Button(context);
        reloadButton.setText("\u27F3"); // ⟳
        reloadButton.setOnClickListener(v -> onReload());

        urlField = new EditText(context);
        urlField.setHint("Enter a URL");
        urlField.setSingleLine(true);
        urlField.setInputType(android.text.InputType.TYPE_TEXT_VARIATION_URI);
        urlField.setImeOptions(EditorInfo.IME_ACTION_GO);
        LinearLayout.LayoutParams urlLp = new LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        urlField.setLayoutParams(urlLp);
        urlField.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_GO || actionId == EditorInfo.IME_ACTION_DONE) {
                onUrlSubmit(v.getText().toString());
                return true;
            }
            return false;
        });

        toolbar.addView(backButton);
        toolbar.addView(forwardButton);
        toolbar.addView(reloadButton);
        toolbar.addView(urlField);

        contentContainer = new FrameLayout(context);
        contentContainer.setLayoutParams(new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        root.addView(toolbar);
        root.addView(contentContainer);

        // Construct the shared MobileChrome over the two seams and navigate the
        // start page — all THROUGH the shell C-ABI. Embeds the renderer's opaque
        // view via ChromeSurface.embedView (→ doEmbedView here).
        this.shellHandle = nativeShellStart(renderer.nativeHandle(), this, startUri);
    }

    /** The root view the Activity sets as its content view. */
    public View rootView() {
        return root;
    }

    /** The WebView-backed renderer controller (the sole android.webkit.* toucher).
     *  Package-private: the instrumented ShellSeamTest subscribes to the SEAM
     *  through it (mirroring the other seam tests) to await lifecycle events; the
     *  app itself never reaches around the chrome to it. */
    WezigWebViewController rendererController() {
        return renderer;
    }

    /** The URL field's current text (for the instrumented test's URL-reflection
     *  assertion). */
    String urlFieldText() {
        return urlField.getText() != null ? urlField.getText().toString() : "";
    }

    /** Whether the Back button is currently enabled (test assertion). */
    boolean isBackEnabled() {
        return backButton.isEnabled();
    }

    /** Whether the Forward button is currently enabled (test assertion). */
    boolean isForwardEnabled() {
        return forwardButton.isEnabled();
    }

    /** The content container the renderer's view is embedded into (test assertion). */
    ViewGroup contentContainer() {
        return contentContainer;
    }

    // --- CEmbedPlatform ops: the chrome drives these on Renderer lifecycle
    //     events; the container/field/buttons MIRROR the renderer's state (story
    //     5), never the other way round. Invoked via JNI (wezig_shell_jni.c). ---

    /** Embed the renderer's WebView into the content container (the opaque handle
     *  downcast back to the view). The ONLY view-hierarchy touch here. */
    @SuppressWarnings("unused") // invoked via JNI (embed op)
    void doEmbedView(WebView view) {
        if (view == null) return;
        View parent = (View) view.getParent();
        if (parent instanceof ViewGroup) {
            ((ViewGroup) parent).removeView(view);
        }
        contentContainer.addView(
            view,
            new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
    }

    /** Reflect the current page's URL into the URL field (unless the user is
     *  actively editing it, so a live edit is not clobbered). */
    @SuppressWarnings("unused") // invoked via JNI (setUrlText op)
    void doSetUrlText(String text) {
        currentUrlText = text != null ? text : "";
        if (!urlField.hasFocus()) {
            urlField.setText(currentUrlText);
        }
    }

    /** Reflect Back-button sensitivity from the renderer's history. */
    @SuppressWarnings("unused") // invoked via JNI (setBackEnabled op)
    void doSetBackEnabled(boolean enabled) {
        backButton.setEnabled(enabled);
    }

    /** Reflect Forward-button sensitivity from the renderer's history. */
    @SuppressWarnings("unused") // invoked via JNI (setForwardEnabled op)
    void doSetForwardEnabled(boolean enabled) {
        forwardButton.setEnabled(enabled);
    }

    // --- user intents → shell C-ABI (THROUGH the chrome/seams) -----------------

    private void onUrlSubmit(String raw) {
        if (shellHandle == 0 || raw == null) return;
        String normalized = normalizeUrl(raw);
        urlField.clearFocus();
        nativeShellNavigate(shellHandle, normalized);
    }

    /** Drive a navigate THROUGH the chrome/seams exactly as a URL-field submit
     *  does (a {@code .navigate} intent) — for the instrumented ShellSeamTest,
     *  which passes a full {@code data:} URL (no host-normalisation needed). */
    void navigateForTest(String uri) {
        if (shellHandle != 0) nativeShellNavigate(shellHandle, uri);
    }

    /**
     * Tear down the shell: free the shell shim's tracked ctx (its controller
     * global-ref) and the native renderer (its one cached view global-ref + the
     * renderer {@code JavaCtx}), leaving no leaked JNI global-ref. Call ONCE on
     * the UI thread at shutdown. (The app itself lets the process own teardown;
     * this is the explicit path the instrumented test exercises.)
     */
    public void destroy() {
        if (shellHandle != 0) {
            nativeShellDestroy(shellHandle);
            shellHandle = 0;
        }
        renderer.destroy();
    }

    private void onBack() {
        if (shellHandle != 0) nativeShellGoBack(shellHandle);
    }

    private void onForward() {
        if (shellHandle != 0) nativeShellGoForward(shellHandle);
    }

    private void onReload() {
        if (shellHandle != 0) nativeShellReload(shellHandle);
    }

    /** Normalise a bare host into an https URL, leaving explicit schemes intact. */
    static String normalizeUrl(String raw) {
        String trimmed = raw.trim();
        if (trimmed.contains("://")) return trimmed;
        return "https://" + trimmed;
    }

    // --- app lifecycle: state restoration is HOST-ONLY (ADR-0010) --------------
    // A background→foreground round-trip preserves the page via the native
    // WebView save-restore the OS mandates, driven from the Activity's
    // onSaveInstanceState/onRestoreInstanceState — NO Renderer seam method added.

    /** Persist the WebView's page/scroll/history into {@code outState}
     *  (WebView.saveState), so a foreground restore re-materialises the page. */
    public void saveState(Bundle outState) {
        Bundle webViewBundle = new Bundle();
        webView.saveState(webViewBundle);
        outState.putBundle(STATE_WEBVIEW, webViewBundle);
    }

    /** Restore the WebView's page/scroll/history from {@code savedState}
     *  (WebView.restoreState) after a background→foreground round-trip. The URL
     *  field re-mirrors the restored page via the normal lifecycle reflection. */
    public void restoreState(Bundle savedState) {
        if (savedState == null) return;
        Bundle webViewBundle = savedState.getBundle(STATE_WEBVIEW);
        if (webViewBundle != null) {
            webView.restoreState(webViewBundle);
        }
        if (!currentUrlText.isEmpty()) {
            urlField.setText(currentUrlText);
        }
    }

    private static int dp(Context context, int value) {
        return (int) TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, value, context.getResources().getDisplayMetrics());
    }

    // --- Native (Zig) bindings ----------------------------------------------
    // Implemented in wezig_shell_jni.c, which forwards to the Zig shell C-ABI in
    // src/android_shell.zig.

    private static native long nativeShellStart(long rendererHandle, WezigShellController controller, String startUri);

    private static native void nativeShellNavigate(long shellHandle, String uri);

    private static native void nativeShellGoBack(long shellHandle);

    private static native void nativeShellGoForward(long shellHandle);

    private static native void nativeShellReload(long shellHandle);

    private static native void nativeShellDestroy(long shellHandle);
}
