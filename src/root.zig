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

/// Doc-drift guard for the v0 subset-limits reference (`docs/v0-subset.md`):
/// asserts the doc names every allowlisted element, supported property, and
/// diagnostic code the code enforces, so the contract cannot silently drift.
pub const docs = @import("docs.zig");

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
}
