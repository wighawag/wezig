package dev.wighawag.wezig;

import static org.junit.Assert.assertTrue;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.webkit.WebView;

import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.ext.junit.runners.AndroidJUnit4;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The Android reference assertion for the `Renderer` seam (spec
 * `explore-mobile-shell`, story 5) — the mobile analogue of the desktop
 * `shell-test` (WebKitGTK) smoke proof. Run on an x86_64 emulator by the CI
 * verification leg (`mobile-verification-legs-ci`); NOT part of `zig build test`.
 *
 * It drives ONE real page THROUGH the pinned seam (Java -> Zig
 * `AndroidWebviewRenderer` -> `android.webkit.WebView`) and asserts the same
 * three things the desktop smoke does:
 *   1. navigate one page,
 *   2. a `.finished` `LifecycleEvent` reaches a subscriber THROUGH the seam
 *      (the Zig `Renderer` seam callback, not the WebView observed directly),
 *   3. the view renders non-blank (a bitmap snapshot has >1 distinct pixel).
 *
 * The `WebViewClient` callbacks arrive on a non-UI thread and are marshalled to
 * the UI thread by `WezigWebViewController` before crossing the seam (spec Q5);
 * this test drives the WebView from the UI thread and awaits the seam event on
 * a latch.
 */
@RunWith(AndroidJUnit4.class)
public final class RendererSeamTest {

    private static final int PAGE_FINISHED = 2; // AndroidLoadEvent.page_finished

    // A self-contained data: page with an opaque coloured background + text, so a
    // correct render is decisively non-blank (mirrors the desktop smoke_page).
    private static final String SMOKE_PAGE =
        "data:text/html,"
        + "<body style='margin:0;background:%23204080;color:%23ffffff;"
        + "font:48px sans-serif'><h1>wezig android shell</h1>"
        + "<p>hello, window</p></body>";

    @Test
    public void navigateDrivesFinishedEventAndNonBlankView() throws Exception {
        final var instrumentation = InstrumentationRegistry.getInstrumentation();
        final var context = instrumentation.getTargetContext();

        final CountDownLatch finished = new CountDownLatch(1);
        final AtomicBoolean sawFinished = new AtomicBoolean(false);
        final WebView[] webViewHolder = new WebView[1];

        instrumentation.runOnMainSync(() -> {
            WebView webView = new WebView(context);
            webView.layout(0, 0, 1080, 1920); // give it a real size so it renders
            webViewHolder[0] = webView;

            WezigWebViewController controller = new WezigWebViewController(webView);

            // Subscribe THROUGH the seam (the Zig Renderer callback), exactly as
            // the desktop shell-test subscribes to the Renderer seam.
            controller.setSeamLifecycleObserver((code, uri) -> {
                if (code == PAGE_FINISHED) {
                    sawFinished.set(true);
                    finished.countDown();
                }
            });

            // Navigate down through the seam (Java -> Zig seam -> WebView).
            controller.navigate(SMOKE_PAGE);
        });

        // 2. the seam delivered `.finished`.
        boolean got = finished.await(30, TimeUnit.SECONDS);
        assertTrue("seam did not deliver a .finished LifecycleEvent within 30s", got);
        assertTrue("expected a .finished event through the seam", sawFinished.get());

        // 3. the view is non-blank: snapshot the WebView to a bitmap and assert
        // it has more than one distinct pixel (a blank/failed render is uniform).
        final boolean[] nonBlank = new boolean[1];
        instrumentation.runOnMainSync(() -> nonBlank[0] = isNonBlank(webViewHolder[0]));
        assertTrue("WebView snapshot was blank (uniform) — page did not render", nonBlank[0]);
    }

    /** Draw the WebView into a bitmap and check it is not a single uniform colour. */
    private static boolean isNonBlank(WebView webView) {
        int w = Math.max(1, webView.getWidth());
        int h = Math.max(1, webView.getHeight());
        Bitmap bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        webView.draw(canvas);

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
