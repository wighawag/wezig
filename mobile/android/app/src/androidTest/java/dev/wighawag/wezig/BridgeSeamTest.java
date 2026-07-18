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
 * The Android reference assertion for the script-message BRIDGE hook (spec
 * `explore-mobile-shell` story 8) — the mobile analogue of the desktop
 * `shell-bridge-test` (WebKitGTK). Run on an x86_64 emulator by the CI
 * verification leg (`mobile-verification-legs-ci`); NOT part of `zig build test`.
 *
 * It round-trips ONE message BOTH ways THROUGH the pinned `Renderer` seam
 * (Java -> Zig `AndroidWebviewRenderer` -> `android.webkit.WebView` via
 * `addJavascriptInterface` / `evaluateJavascript`), mirroring the desktop
 * proof's `window.wezig.ping`:
 *   1. inject `window.wezig` (the page-world object) THROUGH the seam,
 *   2. register the `wezig` page->native channel THROUGH the seam,
 *   3. load a page whose script calls `window.wezig.ping('ping-from-page')`,
 *   4. assert native received the ping (page->native leg), then native
 *      evaluates a reply that re-posts `pong-from-native`, and assert THAT comes
 *      back (native->page leg).
 *
 * The `addJavascriptInterface` `postMessage` fires on a NON-UI (binder) thread
 * and is marshalled onto the UI thread by `WezigWebViewController` before it
 * crosses the seam (spec Q5); this test awaits both legs on a latch.
 */
@RunWith(AndroidJUnit4.class)
public final class BridgeSeamTest {

    private static final String PING = "ping-from-page";
    private static final String PONG = "pong-from-native";

    // The page-world object the bridge injects: `ping` posts its argument over
    // the native `wezig` interface (addJavascriptInterface name). Mirrors the
    // desktop bridge injection, adapted to Android's interface object shape.
    private static final String INJECT =
        "window.wezig = { ping: function(v){ wezig.postMessage(v); } };";

    // The page whose inline script drives the page->native leg at load.
    private static final String BRIDGE_PAGE =
        "data:text/html,"
        + "<body><script>window.wezig.ping('" + PING + "')</script></body>";

    @Test
    public void bridgeRoundTripsBothWays() throws Exception {
        final var instrumentation = InstrumentationRegistry.getInstrumentation();
        final var context = instrumentation.getTargetContext();

        final CountDownLatch done = new CountDownLatch(1);
        final AtomicBoolean gotPing = new AtomicBoolean(false);
        final AtomicBoolean gotPong = new AtomicBoolean(false);
        final WebView[] holder = new WebView[1];
        final WezigWebViewController[] ctrl = new WezigWebViewController[1];

        instrumentation.runOnMainSync(() -> {
            WebView webView = new WebView(context);
            webView.getSettings().setJavaScriptEnabled(true);
            webView.layout(0, 0, 1080, 1920);
            holder[0] = webView;

            WezigWebViewController controller = new WezigWebViewController(webView);
            ctrl[0] = controller;

            // The page->native + native->page legs, driven THROUGH the seam.
            controller.setSeamBridgeObserver("wezig", (name, body) -> {
                if (!gotPing.get()) {
                    if (PING.equals(body)) {
                        gotPing.set(true);
                        // native->page reply: evaluate a call that re-posts pong
                        // back through the SAME injected channel.
                        controller.evaluateScript("window.wezig.ping('" + PONG + "');");
                    }
                    return;
                }
                if (PONG.equals(body)) {
                    gotPong.set(true);
                    done.countDown();
                }
            });

            // native->page setup: inject `window.wezig` THROUGH the seam, then
            // load the page that calls it. (The seam's addJavascriptInterface
            // object is `wezig`; the injected wrapper calls its postMessage.)
            controller.injectUserScript(INJECT);
            controller.navigate(BRIDGE_PAGE);
        });

        boolean ok = done.await(30, TimeUnit.SECONDS);
        assertTrue("bridge did not round-trip both ways within 30s", ok);
        assertTrue("page->native leg (ping) did not reach native", gotPing.get());
        assertTrue("native->page leg (pong) did not come back through the page", gotPong.get());
    }
}
