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

// Force the mobile C-ABI `export fn`s to be ANALYSED (and thus emitted) in a
// NON-test build. Without this, `mobile_abi` is only referenced from the test
// block below, so a plain `zig build android-lib`/`ios-lib` would garbage-collect
// the exports and the native shim would fail to link `_wezig_greeting` &c. This
// comptime reference keeps them in the produced static archive. (The desktop
// build harmlessly carries the same exports — they are tiny and unused there.)
comptime {
    _ = mobile_abi;
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
    _ = toolkit;
    _ = chrome;
    _ = mobile_abi;
}
