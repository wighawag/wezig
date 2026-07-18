package dev.wighawag.wezig;

import android.app.Activity;
import android.os.Bundle;

/**
 * The wezig Android shell (spec {@code build-mobile-shell}, stories 2/3/4/5/6):
 * a REAL, minimal mobile browser. It hosts a {@link WezigShellController}, which
 * lays out a URL field + back/forward toolbar over a WebView-backed
 * {@code Renderer}, and constructs the shared mobile chrome over the
 * {@code Renderer} + {@code ChromeSurface} seams — all navigation driven THROUGH
 * the seams (never a raw {@code android.webkit.*} call above the backend).
 *
 * <p>Background→foreground page-state restoration is HOST-ONLY (ADR-0010,
 * Resolved decision 1): this Activity wires {@code onSaveInstanceState} /
 * {@code onRestoreInstanceState} to {@link WebView#saveState}/{@code restoreState}
 * via the controller, so the current page survives a background/foreground
 * round-trip WITHOUT adding any {@code Renderer} seam method.
 *
 * <p>Emulator/unsigned-debug only (signing is Slice C).
 */
public class MainActivity extends Activity {

    // The page the shell opens with on a COLD start. A `data:` document (offline,
    // deterministic) so the app browses one real page on first launch with no
    // network — the mobile equivalent of the desktop shell's smoke page. The user
    // can type any URL after. (On a warm restore the WebView state is restored
    // instead — see onRestoreInstanceState.)
    private static final String START_PAGE =
        "data:text/html,"
        + "<body style='margin:0;background:%23f4f6fb;color:%23101828;"
        + "font:20px sans-serif;padding:2rem'><h1>wezig</h1>"
        + "<p>A minimal mobile browser. Type a URL above to navigate.</p></body>";

    private WezigShellController shell;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        shell = new WezigShellController(this, START_PAGE);
        setContentView(shell.rootView());

        // Foreground restore (host-only, ADR-0010): if the OS handed us saved
        // state, re-materialise the WebView's page/scroll/history natively so the
        // page the user was on survives the background→foreground round-trip.
        if (savedInstanceState != null) {
            shell.restoreState(savedInstanceState);
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        // Persist the WebView state (host-only, ADR-0010): the OS re-delivers this
        // to onCreate/onRestoreInstanceState on a foreground restore.
        if (shell != null) {
            shell.saveState(outState);
        }
    }

    @Override
    protected void onRestoreInstanceState(Bundle savedInstanceState) {
        super.onRestoreInstanceState(savedInstanceState);
        if (shell != null) {
            shell.restoreState(savedInstanceState);
        }
    }
}
