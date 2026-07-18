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
#include <stddef.h>

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

/*
 * iOS web3-hook proof C-ABI (spec explore-mobile-shell stories 8,9; task
 * mobile-web3-hooks-parity). The iOS twins of the desktop shell-bridge-test /
 * shell-scheme-test, each driving ONE hook THROUGH the pinned `Renderer` seam
 * over the Swift-owned WKWebView. Keep in lock-step with the `export fn`s in
 * src/mobile_abi.zig.
 */

/* --- script-message bridge (WKUserContentController / WKScriptMessageHandler) - */

/* Construct the iOS backend + wire the bridge hook through the seam (inject
 * `window.wezig.ping`, register the `wezig` channel). Swift installs the
 * WKUserScript + WKScriptMessageHandler behind the two hook ops; the page's
 * posts flow back via `wezig_ios_on_script_message`. Returns the proof ctx. */
void *wezig_ios_bridge_proof_start(
    void *wk,
    void *view,
    wezig_wk_source_fn injectUserScript,
    wezig_wk_source_fn evaluateScript,
    void (*setScriptMessageHandler)(void *wk, const char *name));

/* Swift forwards a page-world post from the WKScriptMessageHandler (`didReceive`,
 * on the main queue) here: channel `name` + message `body`. */
void wezig_ios_on_script_message(void *ctx, const char *name, const char *body);

/* The bridge verdict: true iff BOTH legs landed (page->native ping AND
 * native->page pong came back through the page). */
bool wezig_ios_bridge_proof_passed(void *ctx);

/* --- custom-scheme interception (WKURLSchemeHandler) ----------------------- */

/* Construct the iOS backend + register `wezig-test://` through the seam. Swift
 * MUST have installed the WKURLSchemeHandler on the WKWebViewConfiguration
 * BEFORE creating the webview (the iOS ordering constraint), then navigate
 * `wezig-test://hello`. Returns the proof ctx. */
void *wezig_ios_scheme_proof_start(
    void *wk,
    void *view,
    void (*registerScheme)(void *wk, const char *scheme));

/* Swift forwards a WKURLSchemeHandler request (`startURLSchemeTask`) here. Sets
 * *out_body/*out_body_len/*out_content_type to the native-served bytes (borrowed
 * until the next call) and returns true, or false if no handler is registered
 * (Swift then fails the task). */
bool wezig_ios_serve_scheme(
    void *ctx,
    const char *uri,
    const unsigned char **out_body,
    size_t *out_body_len,
    const char **out_content_type);

/* Swift forwards a `.title_changed` (the served body's <title>) here so the seam
 * confirms the native body rendered. */
void wezig_ios_scheme_on_title(void *ctx, const char *title);

/* The scheme verdict: true iff the native handler served the body AND the marker
 * <title> reached the seam (served + rendered). */
bool wezig_ios_scheme_proof_passed(void *ctx);

/*
 * iOS SHELL C-ABI (spec build-mobile-shell, stories 1/3/4/5/6; src/ios_shell.zig).
 *
 * The REAL-app entry points the Xcode project's `WKWebViewShellController`
 * (a `UIViewController`) links against to stand up a minimal browser: construct
 * the iOS `Renderer` backend + the mobile `ChromeSurface` + the shared
 * `MobileChrome` over the Swift-owned `WKWebView` + URL-field/back-forward
 * toolbar, register the trivial marker scheme on the `WKWebViewConfiguration`
 * BEFORE the webview is created (the iOS ordering constraint), and relay
 * URL-bar/back-forward intents + `WKNavigationDelegate` lifecycle events THROUGH
 * the seams. Background/foreground state restoration is HOST-ONLY (ADR-0010):
 * the native `WKWebView` state save-restore + the existing navigate op, no seam
 * method added. Keep these declarations in lock-step with `src/ios_shell.zig`.
 */

/* Construct the iOS Renderer backend + mobile ChromeSurface + shared MobileChrome
 * over the Swift-owned WKWebView + toolbar. The `registerScheme` op MUST install
 * the WKURLSchemeHandler on the WKWebViewConfiguration BEFORE the WKWebView is
 * created (the ordering constraint); this call registers `marker_scheme` and
 * navigates `start_uri` THROUGH the seams. Returns the opaque shell context. */
void *wezig_ios_shell_start(
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
    void (*setScriptMessageHandler)(void *wk, const char *name),
    void (*registerScheme)(void *wk, const char *scheme),
    void *embed_host,
    wezig_embed_view_fn embedView,
    wezig_embed_url_fn setUrlText,
    wezig_embed_enabled_fn setBackEnabled,
    wezig_embed_enabled_fn setForwardEnabled,
    const char *marker_scheme,
    const char *start_uri);

/* Forward a WKNavigationDelegate load-state change to the seam
 * (0=started,1=committed,2=finished,3=failed; `uri` may be NULL). The chrome
 * reflects it into the URL field + Back/Forward sensitivity. */
void wezig_ios_shell_on_load_state(void *ctx, int state, const char *uri);

/* Forward a title change (KVO on WKWebView.title) to the seam. */
void wezig_ios_shell_on_title(void *ctx, const char *title);

/* Forward a URL change (KVO on WKWebView.URL) to the seam; the chrome mirrors it
 * into the URL field so the field reflects the current page. */
void wezig_ios_shell_on_uri(void *ctx, const char *uri);

/* A URL the user submitted in the URL field: fires a navigate intent THROUGH the
 * chrome/seams (NOT a raw WKWebView call). */
void wezig_ios_shell_navigate(void *ctx, const char *uri);

/* Back / Forward / Reload taps: fire the matching intent THROUGH the chrome. */
void wezig_ios_shell_go_back(void *ctx);
void wezig_ios_shell_go_forward(void *ctx);
void wezig_ios_shell_reload(void *ctx);

/* Swift forwards a WKURLSchemeHandler request for the marker scheme here. Sets
 * *out_body/*out_body_len/*out_content_type to the native-served bytes (borrowed
 * until the next call) and returns true, or false if no handler is registered. */
bool wezig_ios_shell_serve_scheme(
    void *ctx,
    const char *uri,
    const unsigned char **out_body,
    size_t *out_body_len,
    const char **out_content_type);

#ifdef __cplusplus
}
#endif

#endif /* WEZIG_MOBILE_H */
