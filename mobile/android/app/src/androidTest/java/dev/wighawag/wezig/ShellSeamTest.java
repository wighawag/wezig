package dev.wighawag.wezig;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebView;

import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.ext.junit.runners.AndroidJUnit4;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The Android reference assertion for the REAL SHELL (spec `build-mobile-shell`,
 * stories 2/3/4/5/6) — a real app module browsing one page through the seams
 * with a URL-bar/back-forward chrome, surviving a background→foreground
 * round-trip. The Android twin of the iOS shell's self-verify. Run on an x86_64
 * emulator by the CI verification leg (`mobile-verify`); NOT part of
 * `zig build test`.
 *
 * <p>It drives the SAME seams the user does — the {@link WezigShellController}'s
 * shared {@code MobileChrome} over the {@code Renderer} + {@code ChromeSurface}
 * — and asserts:
 * <ol>
 *   <li>the renderer's WebView is embedded into the content container THROUGH the
 *       chrome-surface seam (story 2/3);</li>
 *   <li>a start navigation drives a {@code .finished} lifecycle event THROUGH the
 *       seam and the URL field reflects the current page (story 5);</li>
 *   <li>a URL-field submit navigates THROUGH the chrome/seams and re-reflects;</li>
 *   <li>a background→foreground round-trip ({@code saveState}/{@code restoreState})
 *       preserves the current page (story 4, host-only per ADR-0010);</li>
 *   <li>full teardown runs cleanly (the JNI global-ref lifecycle — one view ref +
 *       the renderer {@code JavaCtx} + the {@code EmbedCtx} — releases without a
 *       crash; the leak-count contract is proven headlessly in
 *       `android_renderer.zig`, exercised on the real DeleteGlobalRef path here).</li>
 * </ol>
 */
@RunWith(AndroidJUnit4.class)
public final class ShellSeamTest {

    private static final int PAGE_FINISHED = 2; // AndroidLoadEvent.page_finished

    // A self-contained data: page so a correct render/navigation is deterministic
    // (offline). Distinct start + typed pages so URL reflection is checkable.
    private static final String START_PAGE =
        "data:text/html,<body style='background:%23204080'><h1>wezig start</h1></body>";
    private static final String TYPED_PAGE =
        "data:text/html,<body style='background:%23208040'><h1>wezig typed</h1></body>";

    @Test
    public void shellBrowsesThroughSeamsAndSurvivesBackgroundForeground() throws Exception {
        final var instrumentation = InstrumentationRegistry.getInstrumentation();
        final var context = instrumentation.getTargetContext();

        final WezigShellController[] shellHolder = new WezigShellController[1];
        final CountDownLatch startFinished = new CountDownLatch(1);
        final AtomicBoolean sawFinished = new AtomicBoolean(false);

        // 1. Construct the shell (lays out the chrome, builds the shared
        // MobileChrome over the two seams, embeds the view, navigates the start
        // page). Subscribe to the seam's .finished event through the renderer.
        instrumentation.runOnMainSync(() -> {
            WezigShellController shell = new WezigShellController(context, START_PAGE);
            shellHolder[0] = shell;
            shell.rendererController().setSeamLifecycleObserver((code, uri) -> {
                if (code == PAGE_FINISHED) {
                    sawFinished.set(true);
                    startFinished.countDown();
                }
            });
        });

        // The renderer's WebView is a CHILD of the content container (embedded
        // THROUGH ChromeSurface.embedView, not a direct addView).
        instrumentation.runOnMainSync(() -> {
            ViewGroup container = shellHolder[0].contentContainer();
            assertTrue("content container has no embedded WebView — embedView did not host the view",
                container.getChildCount() >= 1);
            assertTrue("embedded child is not a WebView",
                container.getChildAt(0) instanceof WebView);
        });

        // 2. The start navigation drove a .finished event THROUGH the seam...
        assertTrue("seam did not deliver a .finished LifecycleEvent within 30s",
            startFinished.await(30, TimeUnit.SECONDS));
        assertTrue(sawFinished.get());
        // ...and the chrome reflected the page URL into the URL field (story 5).
        instrumentation.runOnMainSync(() ->
            assertEquals("URL field did not reflect the current page after load",
                START_PAGE, shellHolder[0].urlFieldText()));

        // 3. A URL-field submit navigates THROUGH the chrome/seams and reflects.
        final CountDownLatch typedFinished = new CountDownLatch(1);
        instrumentation.runOnMainSync(() -> {
            shellHolder[0].rendererController().setSeamLifecycleObserver((code, uri) -> {
                if (code == PAGE_FINISHED && TYPED_PAGE.equals(uri)) typedFinished.countDown();
            });
            // Drive the URL submit exactly as the user's IME "Go" does — THROUGH
            // the shell C-ABI (a .navigate intent), never a raw WebView.loadUrl.
            shellHolder[0].navigateForTest(TYPED_PAGE);
        });
        assertTrue("typed navigation did not deliver .finished within 30s",
            typedFinished.await(30, TimeUnit.SECONDS));
        instrumentation.runOnMainSync(() ->
            assertEquals("URL field did not reflect the typed page",
                TYPED_PAGE, shellHolder[0].urlFieldText()));

        // 4. Background→foreground round-trip: saveState then restore into a NEW
        // shell (as onSaveInstanceState/onCreate do). The restored shell's WebView
        // re-materialises the current page natively (host-only, ADR-0010).
        //
        // Wait until the TYPED page is the CURRENT entry in the WebView's
        // back-forward list BEFORE saveState: `.finished` (onPageFinished) can
        // fire slightly before the emulator commits the entry to history, and
        // saveState persists the back-forward list — so saving too early captures
        // START as current and the restore "loses" the typed page. Poll the
        // back-forward list rather than sleeping a fixed amount.
        final boolean[] typedIsCurrent = { false };
        final long commitDeadline = System.currentTimeMillis() + 5000;
        do {
            instrumentation.runOnMainSync(() -> {
                WebView wv = (WebView) shellHolder[0].contentContainer().getChildAt(0);
                var cur = wv.copyBackForwardList().getCurrentItem();
                typedIsCurrent[0] = cur != null && TYPED_PAGE.equals(cur.getUrl());
            });
            if (typedIsCurrent[0]) break;
            Thread.sleep(100);
        } while (System.currentTimeMillis() < commitDeadline);
        assertTrue("typed page never became the current history entry before saveState",
            typedIsCurrent[0]);

        final Bundle saved = new Bundle();
        instrumentation.runOnMainSync(() -> shellHolder[0].saveState(saved));
        assertFalse("saveState produced an empty bundle — no WebView state persisted",
            saved.isEmpty());

        final WezigShellController[] restoredHolder = new WezigShellController[1];
        instrumentation.runOnMainSync(() -> {
            WezigShellController restored = new WezigShellController(context, START_PAGE);
            restored.restoreState(saved);
            restoredHolder[0] = restored;
        });
        // The restored WebView is embedded and carries the page we were on
        // (restoreState brings back the current URL/history). Restoration is
        // async on the emulator, so poll restoredView.getUrl() with a bounded
        // retry until it re-materialises the TYPED page (rather than a single
        // fixed sleep, which races the software renderer's restore).
        instrumentation.runOnMainSync(() -> {
            ViewGroup container = restoredHolder[0].contentContainer();
            assertTrue("restored shell did not embed its WebView", container.getChildCount() >= 1);
        });
        // Read the restored CURRENT entry from the back-forward list (more
        // reliable than getUrl(), which can be null mid-restore).
        final String[] restoredUrl = new String[1];
        final long restoreDeadline = System.currentTimeMillis() + 8000;
        do {
            instrumentation.runOnMainSync(() -> {
                ViewGroup container = restoredHolder[0].contentContainer();
                WebView restoredView = (WebView) container.getChildAt(0);
                var cur = restoredView.copyBackForwardList().getCurrentItem();
                restoredUrl[0] = cur != null ? cur.getUrl() : restoredView.getUrl();
            });
            if (TYPED_PAGE.equals(restoredUrl[0])) break;
            Thread.sleep(200);
        } while (System.currentTimeMillis() < restoreDeadline);
        assertEquals("background→foreground round-trip lost the current page",
            TYPED_PAGE, restoredUrl[0]);

        // 5. Teardown both shells cleanly (exercises the real DeleteGlobalRef /
        // teardown / EmbedCtx-free path — no leak, no crash).
        instrumentation.runOnMainSync(() -> {
            restoredHolder[0].destroy();
            shellHolder[0].destroy();
        });
    }
}
