package dev.wighawag.wezig;

import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebView;
import android.widget.FrameLayout;

/**
 * The Android chrome-surface EMBEDDING half for the ViewHandle-embedding proof
 * (spec {@code explore-mobile-shell}, Q3/story 6; task
 * {@code mobile-viewhandle-embedding-proof}; ADR-0006/0007). This is the Java
 * host the mobile {@code ChromeSurface} (src/mobile_chrome_surface.zig) drives:
 * it owns a container {@link ViewGroup} (the content area a mobile chrome hosts
 * the renderer's view in) and implements {@link #doEmbedView(WebView)}, which the
 * Zig chrome-surface seam calls (through the JNI shim {@code wezig_embedding_jni.c})
 * with the renderer's opaque view.
 *
 * <h2>What this proves (the sharp Q3 risk)</h2>
 *
 * On Android the renderer's opaque {@code ViewHandle} is a JNI global-ref to the
 * {@link WebView}, not a raw pointer. The proof drives an embed THROUGH the seam:
 * <ol>
 *   <li>get the renderer's opaque handle from the Zig {@code Renderer} seam
 *       ({@code wezig_android_renderer_view}),</li>
 *   <li>hand it to {@link #embedRendererView(long)}, which crosses the Zig
 *       {@code ChromeSurface.embedView} seam,</li>
 *   <li>the shim downcasts the opaque handle back to this WebView and calls
 *       {@code doEmbedView}, adding it to the container.</li>
 * </ol>
 * So the JNI global-ref carries across the chrome-surface&harr;renderer boundary
 * as an opaque {@code *anyopaque}, with the Zig side never interpreting it. This
 * is the ONLY code here that touches the view hierarchy; the seam stays
 * backend-agnostic.
 *
 * <p>This is NOT a full mobile chrome — one container, one embed, the narrowest
 * real case. The URL bar / nav buttons the {@code ChromeSurface} contract also
 * carries are inert in this spike (proven by the headless Zig tests).
 */
public final class WezigEmbeddingController {

    static {
        // libwezigshell.so carries the JNI shim + the linked Zig core (the
        // chrome-surface C-ABI). Load it so the controller works from the test.
        System.loadLibrary("wezigshell");
    }

    /** The content area the renderer's view is embedded into (a mobile chrome's
     *  content slot). */
    private final ViewGroup container;

    /** Opaque handle to the Zig {@code *MobileChromeSurface} (a jlong). */
    private final long surfaceHandle;

    /**
     * Construct the embedding host over {@code container}. Creates the Zig mobile
     * chrome-surface (whose {@code embedView} op calls back into
     * {@link #doEmbedView(WebView)} through the JNI shim).
     */
    public WezigEmbeddingController(ViewGroup container) {
        this.container = container;
        this.surfaceHandle = nativeCreateSurface(this);
    }

    /** The Zig chrome-surface pointer (for assertions / teardown). */
    public long surfaceHandle() {
        return surfaceHandle;
    }

    /** The container the renderer's view is embedded into. */
    public ViewGroup container() {
        return container;
    }

    /**
     * Embed the renderer's view (identified by its Zig {@code *AndroidWebviewRenderer}
     * handle) THROUGH the chrome-surface seam. The native side fetches the
     * renderer's opaque {@code ViewHandle} (a JNI global-ref to the WebView) and
     * drives {@code ChromeSurface.embedView(handle)}, which forwards the opaque
     * bits back to {@link #doEmbedView(WebView)}. Must run on the UI thread (it
     * mutates the view hierarchy).
     */
    public void embedRendererView(long rendererHandle) {
        nativeEmbedRendererView(surfaceHandle, rendererHandle);
    }

    /**
     * Called from native (the chrome-surface {@code embedView} op) with the
     * renderer's {@link WebView} — the opaque handle downcast back to the view.
     * Adds it to the container, hosting the foreign view on this NON-GTK toolkit.
     * If the view already has a parent (re-embed), detach it first so
     * {@code addView} is safe.
     */
    @SuppressWarnings("unused") // invoked via JNI
    void doEmbedView(WebView webView) {
        if (webView == null) return;
        View parent = (View) webView.getParent();
        if (parent instanceof ViewGroup) {
            ((ViewGroup) parent).removeView(webView);
        }
        container.addView(
            webView,
            new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
    }

    /** Teardown: free the Zig chrome-surface. */
    public void destroy() {
        nativeDestroySurface(surfaceHandle);
    }

    // --- Native (Zig) bindings ----------------------------------------------
    // Implemented in wezig_embedding_jni.c, which forwards to the Zig
    // chrome-surface C-ABI in src/mobile_chrome_surface.zig.

    private static native long nativeCreateSurface(WezigEmbeddingController controller);

    private static native void nativeDestroySurface(long surfaceHandle);

    private static native void nativeEmbedRendererView(long surfaceHandle, long rendererHandle);
}
