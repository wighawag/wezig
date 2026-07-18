/*
 * C-ABI surface for the wezig mobile static library (src/mobile_abi.zig).
 *
 * This is the bridging header the iOS Swift shell imports (via
 * `-import-objc-header`) to call the Zig `export fn`s and prove the Zig core is
 * linked and live. The same functions are used by the Android JNI shim. Keep
 * these declarations in lock-step with `src/mobile_abi.zig`.
 */
#ifndef WEZIG_MOBILE_H
#define WEZIG_MOBILE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The mobile C-ABI contract version (matches mobile_abi.abi_version). */
int wezig_abi_version(void);

/* A NUL-terminated greeting owned by the library (do NOT free it). */
const char *wezig_greeting(void);

/*
 * iOS `Renderer`-backend proof C-ABI (spec explore-mobile-shell, story 4).
 *
 * These drive the pinned `Renderer` seam over the Swift-owned `WKWebView`:
 * `wezig_ios_proof_start` constructs the iOS backend from a C-ABI ops table (the
 * WKWebView operations Swift implements), subscribes a proof sink, and navigates
 * one page THROUGH the seam. The `WKNavigationDelegate` forwards load-state
 * changes via `wezig_ios_on_load_state`; when the page finishes, Swift snapshots
 * the view, scans it non-blank, reports via `wezig_ios_proof_set_snapshot_non_blank`,
 * and reads the verdict with `wezig_ios_proof_passed`. Keep these declarations in
 * lock-step with the `export fn`s in `src/mobile_abi.zig`.
 */

/* The WKWebView op-pointer signatures the ops table is built from. `wk` is the
 * Swift coordinator cookie; kept opaque to the Zig side. */
typedef void (*wezig_wk_navigate_fn)(void *wk, const char *uri);
typedef void (*wezig_wk_action_fn)(void *wk);
typedef bool (*wezig_wk_query_fn)(void *wk);
typedef void (*wezig_wk_viewport_fn)(void *wk, int width, int height);
typedef void (*wezig_wk_source_fn)(void *wk, const char *source);

/* Construct the iOS Renderer backend over the Swift-owned WKWebView and navigate
 * `uri` through the seam. Returns an opaque proof context for the callbacks. */
void *wezig_ios_proof_start(
    void *wk,
    void *view,
    wezig_wk_navigate_fn navigate,
    wezig_wk_action_fn reload,
    wezig_wk_action_fn stop,
    wezig_wk_action_fn goBack,
    wezig_wk_action_fn goForward,
    wezig_wk_query_fn canGoBack,
    wezig_wk_query_fn canGoForward,
    wezig_wk_viewport_fn setViewportSize,
    wezig_wk_source_fn injectUserScript,
    wezig_wk_source_fn evaluateScript,
    const char *uri);

/* The WKWebView's UIView* the backend returns across the seam as the opaque
 * ViewHandle (the Q3 decision). Swift adds THIS view to its window. */
void *wezig_ios_proof_view(void *ctx);

/* Forward a WKNavigationDelegate load-state change to the seam. `state`:
 * 0=started, 1=committed, 2=finished, 3=failed. `uri` may be NULL. */
void wezig_ios_on_load_state(void *ctx, int state, const char *uri);

/* Report the result of scanning WKWebView.takeSnapshot: true if non-blank. */
void wezig_ios_proof_set_snapshot_non_blank(void *ctx, bool non_blank);

/* The verdict: true iff the seam delivered `.finished` AND the snapshot was
 * non-blank (the two facts spec story 4 requires). */
bool wezig_ios_proof_passed(void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* WEZIG_MOBILE_H */
