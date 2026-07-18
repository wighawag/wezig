package dev.wighawag.wezig;

import static org.junit.Assert.assertTrue;

import android.webkit.WebView;

import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.ext.junit.runners.AndroidJUnit4;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The Android reference assertion for the custom-SCHEME interception hook (spec
 * `explore-mobile-shell` story 9) — the mobile analogue of the desktop
 * `shell-scheme-test` (WebKitGTK). Run on an x86_64 emulator by the CI
 * verification leg (`mobile-verification-legs-ci`); NOT part of `zig build test`.
 *
 * It serves ONE `wezig-test://hello` request from native THROUGH the pinned
 * `Renderer` seam (Java `WebViewClient.shouldInterceptRequest` -> Zig
 * `AndroidWebviewRenderer` -> the native seam handler), mirroring the desktop
 * proof:
 *   1. register `wezig-test` THROUGH the seam with a native handler that serves
 *      an HTML body whose `<title>` is a marker,
 *   2. navigate to `wezig-test://hello`,
 *   3. assert the native handler was invoked (served) AND the marker `<title>`
 *      reached the seam's `.title_changed` event (rendered).
 *
 * `shouldInterceptRequest` runs on a NON-UI (binder) thread and answers
 * SYNCHRONOUSLY — it does NOT marshal to the UI thread (spec Q5; see the
 * android_renderer.zig thread finding). This test drives the WebView from the UI
 * thread and awaits the seam events on a latch.
 */
@RunWith(AndroidJUnit4.class)
public final class SchemeSeamTest {

    private static final String SCHEME = "wezig-test";
    private static final String SCHEME_URI = "wezig-test://hello";
    private static final String MARKER = "WEZIG-SCHEME-OK";
    private static final int PAGE_FINISHED = 2; // AndroidLoadEvent.page_finished

    // The native-served body: a marker <title> proves both served AND rendered.
    private static final String BODY =
        "<html><head><title>" + MARKER + "</title></head>"
        + "<body><h1>" + MARKER + "</h1></body></html>";

    @Test
    public void customSchemeServesNativeBodyThatRenders() throws Exception {
        final var instrumentation = InstrumentationRegistry.getInstrumentation();
        final var context = instrumentation.getTargetContext();

        final CountDownLatch done = new CountDownLatch(1);
        final AtomicBoolean served = new AtomicBoolean(false);
        final AtomicBoolean rendered = new AtomicBoolean(false);
        final WebView[] holder = new WebView[1];

        instrumentation.runOnMainSync(() -> {
            WebView webView = new WebView(context);
            webView.getSettings().setJavaScriptEnabled(true);
            webView.layout(0, 0, 1080, 1920);
            holder[0] = webView;

            WezigWebViewController controller = new WezigWebViewController(webView);

            // Register the scheme THROUGH the seam; the handler serves the marker
            // body (invoked on the binder thread by shouldInterceptRequest).
            controller.setSeamSchemeObserver(SCHEME, uri -> {
                served.set(true);
                return new WezigWebViewController.SchemeResponse(BODY, "text/html");
            });

            // The marker <title> reaching the seam (delivered THROUGH the seam's
            // `.title_changed`, sourced from the WebChromeClient's onReceivedTitle)
            // proves the WebView parsed + rendered the native-served body.
            controller.setSeamTitleObserver(title -> {
                if (MARKER.equals(title)) {
                    rendered.set(true);
                    done.countDown();
                }
            });

            controller.navigate(SCHEME_URI);
        });

        boolean ok = done.await(30, TimeUnit.SECONDS);
        assertTrue("custom scheme did not serve+render within 30s", ok);
        assertTrue("native scheme handler was never invoked (not served)", served.get());
        assertTrue("native-served body did not render (marker <title> unseen)", rendered.get());
    }
}
