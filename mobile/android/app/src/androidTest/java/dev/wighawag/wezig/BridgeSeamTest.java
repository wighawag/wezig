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

    // The native `addJavascriptInterface` channel name. It MUST differ from the
    // page-facing `window.wezig` object below: on Android addJavascriptInterface
    // installs its object AT `window.<channel>`, so if the channel were `wezig`
    // the INJECT script's `window.wezig = {...}` would OVERWRITE the native
    // interface and `wezig.postMessage` would be undefined. Registering the
    // native leg as `wezigNative` (distinct from the page object `window.wezig`)
    // mirrors the desktop/iOS shape, where the native channel lives in a separate
    // namespace (`window.webkit.messageHandlers.wezig`) from `window.wezig`.
    private static final String CHANNEL = "wezigNative";

    // The page-world object the bridge injects: `ping` posts its argument over
    // the SEPARATE native `wezigNative` interface (not over itself).
    private static final String INJECT =
        "window.wezig = { ping: function(v){ wezigNative.postMessage(v); } };";

    // The page whose script drives the page->native leg. It pings over
    // `window.wezigNative` — the `addJavascriptInterface` object, which the
    // WebView injects at document-start NATIVELY (reliably present, no async
    // race). It deliberately does NOT depend on the injected `window.wezig`
    // wrapper: Android has no document-start user-script API, so the backend
    // re-injects `injectUserScript` on the `.started` lifecycle event (Resolved
    // decision 2), which lands slightly LATER than a true pre-load injection
    // (spec build-mobile-shell, Resolved decision 2 Caveat; ADR-0009 §3) and can
    // race the page's own script under the emulator's timing. `injectUserScript`
    // re-injection is proven separately (the headless seam-contract test + the
    // desktop/iOS bridge legs); THIS test's charter is the page->native->page
    // ROUND-TRIP through the real `addJavascriptInterface` seam channel, which
    // `window.wezigNative` exercises directly. It still RETRIES defensively until
    // the interface is present (belt-and-braces against a slow first frame).
    private static final String BRIDGE_PAGE =
        "data:text/html,"
        + "<body><script>"
        + "function p(){if(window.wezigNative){window.wezigNative.postMessage('" + PING + "');}"
        + "else{setTimeout(p,10);}}p();"
        + "</script></body>";

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
            controller.setSeamBridgeObserver(CHANNEL, (name, body) -> {
                if (!gotPing.get()) {
                    if (PING.equals(body)) {
                        gotPing.set(true);
                        // native->page reply: evaluate JS that re-posts pong back
                        // through the SAME seam channel (native->page leg). Uses
                        // window.wezigNative directly (reliably present), matching
                        // the page's ping path.
                        controller.evaluateScript("window.wezigNative.postMessage('" + PONG + "');");
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
