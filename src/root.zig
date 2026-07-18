//! Library entry point for the project. For now this exposes one trivial
//! function so the build + test acceptance loop is real; the browser engine
//! subsystems (HTML parse, CSS, layout, paint) land in later tasks and
//! re-export from here.

const std = @import("std");

/// The project's two swappable name identifiers (single source of truth).
pub const branding = @import("branding.zig");

/// The structured diagnostics channel every v0 subset boundary reports through.
pub const diagnostics = @import("diagnostics.zig");

/// The v0 HTML parser: fixed-subset HTML in, DOM tree out, behind a swappable
/// `Tokenizer | TreeBuilder` seam.
pub const html = @import("html.zig");

/// The v0 CSS parser + cascade: fixed-subset CSS in, computed styles attached
/// to DOM nodes out, behind a `Selector`-AST seam and the real cascade.
pub const css = @import("css.zig");

/// The v0 layout engine: styled DOM in, a box tree with real positions/sizes
/// out, driving text line-breaking through the `PaintBackend` measurement seam.
pub const layout = @import("layout.zig");

/// The offscreen RGBA paint target + a minimal PNG codec (for golden-image
/// tests) the paint backend renders into.
pub const surface = @import("surface.zig");

/// The v0 paint backend: `StbSoftwareBackend` (stb_truetype glyphs + software
/// raster) realising the `PaintBackend` seam, plus `paintTree`.
pub const paint = @import("paint.zig");

/// The `Renderer` seam (ADR-0005/0006): the chrome-to-content boundary the
/// chrome, wallet, and IPFS talk to. Pure interface (no webview binding);
/// `SystemWebviewRenderer` (in the shell exe) implements it on WebKitGTK.
pub const renderer = @import("renderer.zig");

/// The Android `Renderer` backend (ADR-0005/0006; spec `explore-mobile-shell`
/// story 5): `AndroidWebviewRenderer` satisfies the pinned `Renderer` seam over
/// `android.webkit.WebView`, bridging Zig↔Java over JNI. Pure Zig (no `jni.h`,
/// no `android.webkit.*` — those live in the Java `WezigWebViewController` and
/// the JNI shim), so it builds into the mobile static lib AND runs its headless
/// seam-contract tests in `zig build test`, unlike the desktop backend which
/// links native GTK/WebKit and stays shell-exe-only.
pub const android_renderer = @import("android_renderer.zig");

/// The chrome/toolkit seam (ADR-0006, ADR-0008): the chrome-host boundary, SPLIT
/// into a `ChromeSurface` half (widgets + intents, both platforms) and a
/// desktop-only `HostLoop` half (window + main loop), composed into `Toolkit`.
/// Pure interface (no GTK binding); `GtkToolkit` (in the shell exe) implements
/// both halves on GTK4; a mobile toolkit implements only `ChromeSurface`.
pub const toolkit = @import("toolkit.zig");

/// The minimal chrome (one window, URL bar, back/forward) that talks ONLY to
/// the `renderer` + `toolkit` seams. Imports neither webkit nor gtk symbols.
pub const chrome = @import("chrome.zig");

/// Doc-drift guard for the v0 subset-limits reference (`docs/v0-subset.md`):
/// asserts the doc names every allowlisted element, supported property, and
/// diagnostic code the code enforces, so the contract cannot silently drift.
pub const docs = @import("docs.zig");

/// Swap-discipline guard (ADR-0005/0006): fails the gate if `src/chrome.zig`
/// reaches past the `Renderer`/`Toolkit` seams into the `webkit` or `gtk`
/// bindings, so both the content-backend and chrome-toolkit swaps stay cheap.
pub const chrome_conformance = @import("chrome_conformance.zig");

/// The C-ABI surface the mobile shells (iOS/Android) link against: a static lib
/// the OS-native shell hosts. Proves Zig↔native linkage without dragging the
/// WebKitGTK/GTK shell seams into the mobile build.
pub const mobile_abi = @import("mobile_abi.zig");

/// The iOS `Renderer` backend (ADR-0005/0006): the pinned `Renderer` seam
/// implemented over a `WKWebView` through a C-ABI ops table the Swift shell
/// installs. The iOS twin of `SystemWebviewRenderer`; the sole WKWebView toucher
/// above the FFI. Pure Zig (no WebKit import) so its seam-contract tests run in
/// the display-free `zig build test` gate.
pub const ios_webview_renderer = @import("ios_webview_renderer.zig");

/// The mobile `ChromeSurface` backend (ADR-0006/0008; spec `explore-mobile-shell`
/// Q3/story 6): `MobileChromeSurface` implements the chrome-surface half of the
/// split `Toolkit` for the iOS/Android chrome host, `embedView`-ing the
/// renderer's OPAQUE `ViewHandle` (a `WKWebView` `UIView*` / a JNI global-ref to
/// an `android.webkit.WebView`) through a C-ABI ops table — the module that
/// resolves ADR-0007's flagged cross-toolkit-embedding spike on mobile. Pure Zig
/// (no UIKit / `jni.h`), so its seam-contract tests run in `zig build test`.
pub const mobile_chrome_surface = @import("mobile_chrome_surface.zig");

/// The shared mobile chrome loop (ADR-0008; spec `build-mobile-shell`, stories
/// 3/5/11): `MobileChrome` is the mobile analogue of `chrome.zig` over the
/// `ChromeSurface` half of the split `Toolkit` — it drives a `Renderer` and
/// reflects its lifecycle events into a `ChromeSurface`'s widgets, with NO
/// `HostLoop` (the OS owns the run loop on mobile). The ONE shared chrome piece
/// both platform shells consume; pure Zig (no webview / native-UI binding), so
/// its seam-contract tests run in the display-free `zig build test` gate.
pub const mobile_chrome = @import("mobile_chrome.zig");

/// The iOS shell C-ABI (ADR-0008/0010; spec `build-mobile-shell`, stories
/// 1/3/4/5/6): the real-app entry points the Xcode/SwiftPM project's
/// `UIViewController` links against to construct the `IosWebviewRenderer` +
/// `MobileChromeSurface` + shared `MobileChrome`, register the trivial marker
/// scheme at config-build time (the iOS ordering constraint), and relay URL-bar /
/// back-forward intents + `WKNavigationDelegate` lifecycle events THROUGH the
/// seams. Pure Zig (no WebKit/UIKit), so its headless wiring tests run in the
/// display-free `zig build test` gate; the real browse + background/foreground
/// round-trip is the iOS Simulator leg.
pub const ios_shell = @import("ios_shell.zig");

// Force the mobile C-ABI `export fn`s to be ANALYSED (and thus emitted) in a
// NON-test build. Without this, `mobile_abi` is only referenced from the test
// block below, so a plain `zig build android-lib`/`ios-lib` would garbage-collect
// the exports and the native shim would fail to link `_wezig_greeting` &c. This
// comptime reference keeps them in the produced static archive. (The desktop
// build harmlessly carries the same exports — they are tiny and unused there.)
comptime {
    _ = mobile_abi;
    _ = android_renderer;
    _ = mobile_chrome_surface;
    _ = ios_shell;
}

/// Trivial placeholder so `zig build test` has real behaviour to assert on.
/// Replaced/extended by the first real subsystem task.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "add sums two integers" {
    try std.testing.expect(add(3, 7) == 10);
}

test {
    // Pull in the branding module's tests.
    std.testing.refAllDecls(@This());
    _ = branding;
    _ = diagnostics;
    _ = html;
    _ = css;
    _ = layout;
    _ = surface;
    _ = paint;
    _ = docs;
    _ = chrome_conformance;
    _ = renderer;
    _ = android_renderer;
    _ = toolkit;
    _ = chrome;
    _ = mobile_abi;
    _ = ios_webview_renderer;
    _ = mobile_chrome_surface;
    _ = mobile_chrome;
    _ = ios_shell;
}
