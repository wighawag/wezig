package dev.wighawag.wezig;

import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebView;
import android.widget.FrameLayout;

import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.ext.junit.runners.AndroidJUnit4;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The Android reference assertion for the ViewHandle-EMBEDDING proof (spec
 * {@code explore-mobile-shell}, Q3/story 6; task
 * {@code mobile-viewhandle-embedding-proof}) — the SHARP mobile risk (ADR-0007's
 * flagged cross-toolkit-embedding spike). Run on an x86_64 emulator by the CI
 * verification leg ({@code mobile-verification-legs-ci}); NOT part of
 * {@code zig build test}.
 *
 * <p>It proves the opaque {@code ViewHandle} carries the Android {@link WebView}
 * across the mobile chrome-surface&harr;renderer seam, driven THROUGH the seam
 * (not a direct {@code addView}):
 * <ol>
 *   <li>a {@code WezigWebViewController} owns a WebView and exposes the
 *       renderer's opaque {@code ViewHandle} (a JNI global-ref) via the Zig
 *       {@code Renderer} seam;</li>
 *   <li>a {@code WezigEmbeddingController} owns a container and drives
 *       {@code ChromeSurface.embedView(rendererView)} across the Zig seam;</li>
 *   <li>the WebView becomes a child of the container (the opaque JNI ref carried
 *       across the boundary and the native side downcast it), and</li>
 *   <li>the container renders the page non-blank (the page is visible through
 *       the embedded view).</li>
 * </ol>
 *
 * <p>The load-callback marshalling (spec Q5) is unchanged from
 * {@code RendererSeamTest}; this test adds the embedding step on top.
 */
@RunWith(AndroidJUnit4.class)
public final class EmbeddingProofTest {

    private static final int PAGE_FINISHED = 2; // AndroidLoadEvent.page_finished

    // A self-contained data: page with an opaque coloured background + text, so a
    // correct render is decisively non-blank (mirrors the desktop smoke_page).
    private static final String SMOKE_PAGE =
        "data:text/html,"
        + "<body style='margin:0;background:%23204080;color:%23ffffff;"
        + "font:48px sans-serif'><h1>wezig android embedding</h1>"
        + "<p>hosted via ChromeSurface.embedView</p></body>";

    @Test
    public void embedViewHostsRendererViewThroughSeamAndPageShows() throws Exception {
        final var instrumentation = InstrumentationRegistry.getInstrumentation();
        final var context = instrumentation.getTargetContext();

        final CountDownLatch finished = new CountDownLatch(1);
        final AtomicBoolean sawFinished = new AtomicBoolean(false);
        final WebView[] webViewHolder = new WebView[1];
        final FrameLayout[] containerHolder = new FrameLayout[1];

        instrumentation.runOnMainSync(() -> {
            // The renderer side: a WebView + the Renderer-seam controller.
            WebView webView = new WebView(context);
            webViewHolder[0] = webView;
            WezigWebViewController renderer = new WezigWebViewController(webView);

            // The chrome-surface side: a container the renderer's view is embedded
            // into via the seam.
            FrameLayout container = new FrameLayout(context);
            container.layout(0, 0, 1080, 1920); // a real size so it renders
            containerHolder[0] = container;
            WezigEmbeddingController embedding = new WezigEmbeddingController(container);

            // Subscribe to the .finished seam event (through the Zig Renderer
            // callback), then navigate down through the seam.
            renderer.setSeamLifecycleObserver((code, uri) -> {
                if (code == PAGE_FINISHED) {
                    sawFinished.set(true);
                    finished.countDown();
                }
            });

            // THE PROOF: embed the renderer's view THROUGH the chrome-surface
            // seam. The opaque handle (a JNI global-ref to the WebView) crosses
            // Renderer.view() -> ChromeSurface.embedView -> native downcast.
            embedding.embedRendererView(renderer.nativeHandle());

            // Give the freshly-embedded container a layout pass, then navigate.
            container.measure(
                View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(1920, View.MeasureSpec.EXACTLY));
            container.layout(0, 0, 1080, 1920);

            renderer.navigate(SMOKE_PAGE);
        });

        // 1. the WebView is now a CHILD of the container (the opaque handle
        // carried across the seam and the native side embedded it).
        final WebView[] childHolder = new WebView[1];
        instrumentation.runOnMainSync(() -> {
            ViewGroup container = containerHolder[0];
            assertTrue("container has no embedded child — embedView did not host the view",
                container.getChildCount() >= 1);
            View child = container.getChildAt(0);
            assertSame("embedded child is not the renderer's WebView — the opaque handle "
                + "did not carry the JNI ref across the seam", webViewHolder[0], child);
            childHolder[0] = (WebView) child;
        });

        // 2. the seam delivered `.finished` (the page loaded through the seam).
        boolean got = finished.await(30, TimeUnit.SECONDS);
        assertTrue("seam did not deliver a .finished LifecycleEvent within 30s", got);
        assertTrue("expected a .finished event through the seam", sawFinished.get());

        // 3. the EMBEDDED view renders the page non-blank (the page is visible
        // through the chrome-surface embed).
        final boolean[] nonBlank = new boolean[1];
        instrumentation.runOnMainSync(() -> {
            // Lay out the container (and its now-embedded child) at a real size.
            containerHolder[0].measure(
                View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(1920, View.MeasureSpec.EXACTLY));
            containerHolder[0].layout(0, 0, 1080, 1920);
            nonBlank[0] = isNonBlank(containerHolder[0]);
        });
        assertTrue("embedded container snapshot was blank — page did not render through embed",
            nonBlank[0]);
    }

    /** Draw {@code view} into a bitmap and check it is not a single uniform colour. */
    private static boolean isNonBlank(View view) {
        int w = Math.max(1, view.getWidth());
        int h = Math.max(1, view.getHeight());
        Bitmap bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        view.draw(canvas);

        int first = bitmap.getPixel(0, 0);
        for (int y = 0; y < h; y += 8) {
            for (int x = 0; x < w; x += 8) {
                if (bitmap.getPixel(x, y) != first) {
                    bitmap.recycle();
                    return true; // found a distinct pixel => non-blank
                }
            }
        }
        bitmap.recycle();
        return false;
    }
}
