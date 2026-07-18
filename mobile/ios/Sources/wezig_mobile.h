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

/*
 * iOS ViewHandle-EMBEDDING proof C-ABI (spec explore-mobile-shell, Q3/story 6).
 *
 * The embedding proof drives BOTH seams: it constructs the iOS `Renderer` backend
 * AND a mobile `ChromeSurface` (src/mobile_chrome_surface.zig), then embeds the
 * renderer's OPAQUE `ViewHandle` (the WKWebView's UIView*) THROUGH the
 * chrome-surface seam (`surface.embedView(renderer.view())`) — resolving
 * ADR-0007's flagged cross-toolkit-embedding case on iOS. Swift installs the
 * WKWebView ops (as in the renderer proof) AND the container's embed ops; when
 * the page finishes, Swift snapshots the CONTAINER (not the webview directly)
 * and reports non-blank. Keep in lock-step with `src/mobile_chrome_surface.zig`.
 */

/* The chrome-surface embed-op signatures. `host` is the Swift container cookie. */
typedef void (*wezig_embed_view_fn)(void *host, void *view);
typedef void (*wezig_embed_url_fn)(void *host, const char *text);
typedef void (*wezig_embed_enabled_fn)(void *host, bool enabled);

/* Construct the iOS Renderer backend + the mobile ChromeSurface, embed the
 * renderer's view THROUGH the chrome-surface seam, and navigate one page. Returns
 * an opaque proof context for the callbacks. */
void *wezig_ios_embed_proof_start(
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
    void *embed_host,
    wezig_embed_view_fn embedView,
    wezig_embed_url_fn setUrlText,
    wezig_embed_enabled_fn setBackEnabled,
    wezig_embed_enabled_fn setForwardEnabled,
    const char *uri);

/* Forward a WKNavigationDelegate load-state change to the seam (same codes as
 * wezig_ios_on_load_state): 0=started,1=committed,2=finished,3=failed. */
void wezig_ios_embed_on_load_state(void *ctx, int state, const char *uri);

/* Report whether the EMBEDDED container's snapshot scanned non-blank. */
void wezig_ios_embed_set_non_blank(void *ctx, bool non_blank);

/* The verdict: true iff the seam delivered `.finished` AND the EMBEDDED view
 * rendered non-blank (the opaque handle carried the view across the seam and the
 * page showed). */
bool wezig_ios_embed_proof_passed(void *ctx);

#ifdef __cplusplus
}
#endif

#endif /* WEZIG_MOBILE_H */
