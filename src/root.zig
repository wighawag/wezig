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

/// The networking SEAM + content-address verifier (spec `explore-native-renderer`,
/// story 2/6, decision 2): the boundary a future `WezigRenderer` /
/// `explore-web3-capabilities` fetch through, plus the hash-verify THESIS
/// ("content is trusted because it hashes to its address", ADR-0011). Pure Zig
/// (std crypto), so its seam-contract + verify tests run in the display-free
/// `zig build test` gate. The BOUND libcurl+TLS stack that satisfies the seam
/// over the live network is `src/networking_spike.zig`, compiled ONLY by the
/// dedicated `zig build networking-fetch-test` step (ADR-0007), NOT re-exported
/// here (so libcurl never enters the library `mod` or the mobile cross-compiles).
pub const networking = @import("networking.zig");

/// The native static-page `WezigRenderer` STUB (spec `explore-native-renderer`,
/// story 4/6, decision 4): the minimal real SECOND `Renderer` backend the
/// user-controlled swap needs, painting ONE static page THROUGH the v0
/// layout/paint pipeline behind the `Renderer` seam. Pure Zig (paints via
/// `paint.renderScene`, already in this module — links nothing new), so its
/// seam-contract + paint tests run in the display-free `zig build test` gate,
/// unlike the webview backend which links native GTK/WebKit and is shell-only.
pub const wezig_renderer = @import("wezig_renderer.zig");

/// The USER-controlled renderer swap coordinator + per-domain-allow data model
/// (spec `explore-native-renderer`, story 4/6, decision 4; ADR-0005/0011):
/// `RendererSwap` holds BOTH `Renderer` seam values and performs the three-step
/// swap (re-point + re-attach + re-navigate) on a MANUAL trigger, with an
/// `EngineKind` indicator; `DomainAllowList` is the persistent user allow-list
/// of domains that always render native. NO automatic routing; manual fallback.
/// Talks ONLY to the `Renderer` seam (no webview/GTK binding), so
/// `chrome_conformance` is untouched; pure Zig, tests run in `zig build test`.
pub const renderer_swap = @import("renderer_swap.zig");

/// The content-addressed ORIGIN model + the per-ORIGIN wallet-link data model +
/// the seam's per-origin provider binding (spec `explore-web3-capabilities`,
/// stories 1/3/5; ADR-0015 decisions 1–3; ADR-0011): the TRUST-BOUNDARY model
/// everything web3 keys on. `ContentOrigin` = the IPFS content address (ENS
/// resolves TO it); `WalletLinkStore` keys the wallet link by ORIGIN, not tab
/// (same-origin tabs SHARE, different origins are INDEPENDENT) + the ENS-repoint
/// carry-forward; `OriginProviderBinding` expresses the per-origin provider
/// channel over the `Renderer` seam (replacing the single hardcoded channel).
/// Pure Zig behind the seam (imports only `renderer.zig`, no webview/GTK
/// binding), so its data-model + binding-routing tests run in the display-free
/// `zig build test` gate. A decision/data-model deliverable — NOT the wallet,
/// storage, or encryption subsystem.
pub const web3_origin = @import("web3_origin.zig");

/// The wallet BROKER boundary + the page-facing EIP-6963 provider spiked on ONE
/// origin-bound `eth_requestAccounts` round-trip (spec `explore-web3-capabilities`
/// story 1; ADR-0015 decisions 4 + 5; ADR-0011): de-risks the SECURITY BOUNDARY,
/// not the wallet. The `Broker` seam (`{ ptr, vtable }`, like `Renderer`) is the
/// trusted custody+decide boundary — a `FakeBroker` holds a THROWAWAY test key
/// and returns only the ACCOUNT ADDRESS, never key material; `PageProvider` is
/// the trusted native glue that stamps the requesting content ORIGIN onto each
/// request, crosses the boundary, records the grant on that origin's
/// `web3_origin.WalletLink`, and replies into the page over the seam. Discovery
/// is EIP-6963 (announce/request events), not `window.ethereum`. Pure Zig behind
/// the `Renderer` + `Broker` seams (imports only `renderer.zig`/`web3_origin.zig`,
/// no webview/GTK binding), so its seam-contract round-trip runs in the
/// display-free `zig build test` gate; the LIVE out-of-process broker proof is
/// `src/wallet_broker_spike.zig` via the dedicated `zig build
/// wallet-broker-roundtrip-test` step + CI leg (ADR-0007), NOT re-exported here.
pub const wallet_broker = @import("wallet_broker.zig");

/// The `ScriptEngine` seam (ADR-0013): the JavaScript-runtime boundary. Pure
/// interface (no bound engine), making the JS-engine choice REVERSIBLE the same
/// way the `Renderer` seam is — a BOUND engine (SpiderMonkey/JSC/V8, lean
/// SpiderMonkey) satisfies it first for compatibility, a Zig-native `kiesel` as
/// an aspirational later swap-in behind the SAME seam. CAVEAT documented at the
/// seam: unlike `Renderer`/`PaintBackend` this is a WIDE, DOM-coupled boundary
/// (constant DOM/GC/event-loop callbacks), so it is intimate, not a thin vtable.
/// Proven here with a trivial `StubScriptEngine` (no real engine bound — that is
/// a follow-on build); its seam-contract tests run in the display-free
/// `zig build test` gate.
pub const script_engine = @import("script_engine.zig");

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

/// The ANDROID shell C-ABI (spec `build-mobile-shell`, stories 2/3/4/5/6): the
/// real-app entry points the Gradle app module's `Activity` links against
/// (through the JNI shim) to compose the shim-owned `AndroidWebviewRenderer` +
/// the `MobileChromeSurface` + the shared `MobileChrome`, and relay URL-bar /
/// back-forward intents + `WebViewClient` lifecycle events THROUGH the seams.
/// Pure Zig (no `jni.h`/`android.webkit.*`), so its headless wiring tests run in
/// the display-free `zig build test` gate; the real browse + background/foreground
/// round-trip is the x86_64-emulator leg. The twin of `ios_shell`.
pub const android_shell = @import("android_shell.zig");

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
    _ = android_shell;
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
    _ = web3_origin;
    _ = wallet_broker;
    _ = wezig_renderer;
    _ = renderer_swap;
    _ = script_engine;
    _ = networking;
    _ = android_renderer;
    _ = toolkit;
    _ = chrome;
    _ = mobile_abi;
    _ = ios_webview_renderer;
    _ = mobile_chrome_surface;
    _ = mobile_chrome;
    _ = ios_shell;
    _ = android_shell;
}
