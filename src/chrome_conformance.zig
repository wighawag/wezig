//! Swap-discipline guard for the chrome<->seams boundary (ADR-0005, ADR-0006).
//!
//! ADR-0005's "discipline that makes or breaks it" and ADR-0006's two-seams
//! rule both say the same thing: the CHROME (`src/chrome.zig`) must talk ONLY
//! to the `Renderer` + `Toolkit` seams and NEVER reach past them into the
//! WebKitGTK or GTK bindings. The moment chrome code imports `webkit` or `gtk`
//! directly, the content-backend swap (WebKitGTK -> `WezigRenderer`) and the
//! chrome-toolkit swap (GTK -> Qt -> Zig-native) stop being cheap. Only
//! `SystemWebviewRenderer` (`system_webview_renderer.zig`) may touch `webkit`,
//! and only `GtkToolkit` (`gtk_toolkit.zig`) may touch `gtk`.
//!
//! ADR-0006 pins the exact machine check: "grep this module for
//! `webkit_`/`gtk_` and expect zero hits". This module is that check, modelled
//! on `src/docs.zig`: a Zig test in the library that fails `zig build test` (the
//! v0 gate) when the boundary is violated, so a future direct-webkit/gtk call
//! in the chrome is caught rather than silently eroding the swap. It is a
//! STATIC import/symbol scan, so it needs no webview and no display and lives
//! in the normal gate (unlike `shell-test`, which needs Xvfb).
//!
//! ## What "a direct import" means here (the tokens we forbid)
//!
//! In this repo a direct binding reach from the chrome takes one of two forms,
//! and both are caught by scanning for a small set of case-insensitive tokens:
//!   - the C binding itself: `@cImport`/`@cInclude("webkit_c.h")`, or any bare
//!     `webkit`/`gtk` symbol (`webkit_web_view_*`, `gtk_window_new`, `GtkWindow`,
//!     `WebKitWebView`, ...);
//!   - reaching into a backend impl file: `@import("system_webview_renderer.zig")`
//!     or `@import("gtk_toolkit.zig")` (importing the binding transitively).
//! Scanning for `webkit` and `gtk` (case-insensitively) catches every one of
//! these: the C symbols, the header name (`webkit_c.h`), and both backend
//! filenames (`system_webview_renderer` contains `webview`, not `webkit`, so
//! that name alone is allowed -- but `gtk_toolkit.zig` contains `gtk`, and any
//! import of the webkit backend drags in `webkit` symbols the moment it is
//! used, so the pair is covered in practice by forbidding both tokens).
//!
//! ## Why we strip comments before scanning (a deliberate choice)
//!
//! `src/chrome.zig`'s OWN doc comment names `webkit`/`gtk` in prose (it explains
//! the very discipline this guard enforces, and mentions "GTK/WebKit state").
//! A naive raw-substring grep would therefore FAIL on the current,
//! seam-respecting chrome -- the opposite of what we want. So the scan strips
//! Zig line comments (`//...` to end of line; Zig has no block comments, so this
//! is complete) and inspects only the CODE. This means the guard proves the
//! chrome contains no webkit/gtk *code*, while prose is free to discuss the
//! boundary. The trade-off is a string literal like `"gtk"` in chrome code
//! would trip it, but the chrome has no reason to hold such a literal, and a
//! false-positive that forces a rename is far cheaper than a false-negative
//! that lets the binding leak in. Alternative considered: parse imports with
//! a real Zig tokenizer -- rejected as overkill for a name-presence guard, the
//! same call `docs.zig` makes.

const std = @import("std");

/// The chrome module, relative to the repo root (the cwd `zig build test` runs
/// from). This is the ONE file the discipline governs: it is the sole module
/// that holds both seams and wires them together (ADR-0006), so it is where a
/// direct binding reach would first appear.
const chrome_path = "src/chrome.zig";

/// The binding tokens the chrome must never reach for, checked case-insensitively
/// against the comment-stripped code. `webkit` covers the WebKitGTK content
/// binding (only `SystemWebviewRenderer` may import it); `gtk` covers the GTK
/// toolkit binding (only `GtkToolkit` may). Both the C symbols and the header
/// name (`webkit_c.h`) contain one of these tokens.
const forbidden_tokens = [_][]const u8{ "webkit", "gtk" };

/// Read a source file whole into an owned buffer (relative to the test's cwd,
/// the repo root). Uses the testing `Io` since these are test-only reads, just
/// like `docs.zig`.
fn readSource(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20));
}

/// Return `src` with every Zig line comment (`//` through end of line) blanked
/// to spaces, preserving length and newlines so the result still scans as code
/// only. Zig has no block comments, so stripping line comments is complete. The
/// caller owns the returned buffer.
///
/// Note this is a lexical strip that does NOT understand string literals, so a
/// `//` inside a string would also be blanked; that is fine for a
/// name-presence guard (it only ever makes the scan MORE permissive by removing
/// text, never less, and the chrome holds no such literal).
fn stripLineComments(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, src.len);
    @memcpy(out, src);
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == '/' and i + 1 < out.len and out[i + 1] == '/') {
            // Blank from here to the end of the line (exclusive of the newline).
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        } else {
            i += 1;
        }
    }
    return out;
}

/// The first forbidden token that appears (case-insensitively) in `code`, or
/// `null` if the code is clean. `code` is expected to already have comments
/// stripped.
fn firstForbiddenToken(code: []const u8) ?[]const u8 {
    for (forbidden_tokens) |tok| {
        if (std.ascii.indexOfIgnoreCase(code, tok) != null) return tok;
    }
    return null;
}

/// Scan a chrome-like source buffer for a direct binding reach: strip comments,
/// then look for any forbidden token in the remaining code. Returns the
/// offending token or `null` if the source respects the seams. This is the
/// reusable core; the real-file test and the synthetic both-directions tests
/// all go through it.
fn scanForDirectImport(gpa: std.mem.Allocator, src: []const u8) !?[]const u8 {
    const code = try stripLineComments(gpa, src);
    defer gpa.free(code);
    return firstForbiddenToken(code);
}

test "the real chrome module respects the seams (imports neither webkit nor gtk)" {
    const gpa = std.testing.allocator;
    const src = try readSource(gpa, chrome_path);
    defer gpa.free(src);

    if (try scanForDirectImport(gpa, src)) |tok| {
        std.debug.print(
            "{s} reaches directly for the `{s}` binding; the chrome must talk ONLY to the Renderer/Toolkit seams (ADR-0005/0006)\n",
            .{ chrome_path, tok },
        );
        return error.ChromeReachesPastSeam;
    }
}

test "the guard FAILS a chrome that imports the webkit binding directly" {
    const gpa = std.testing.allocator;
    // A chrome that reaches past the Renderer seam into WebKitGTK. Even with the
    // forbidden token only in CODE (the prose mentions are irrelevant), the scan
    // must catch it.
    const bad =
        \\//! A chrome that cheats and drives the webview directly.
        \\const std = @import("std");
        \\const c = @cImport({
        \\    @cInclude("webkit_c.h");
        \\});
        \\pub fn go(view: *c.WebKitWebView) void {
        \\    c.webkit_web_view_reload(view);
        \\}
    ;
    const tok = try scanForDirectImport(gpa, bad);
    try std.testing.expect(tok != null);
    try std.testing.expectEqualStrings("webkit", tok.?);
}

test "the guard FAILS a chrome that imports the gtk toolkit directly" {
    const gpa = std.testing.allocator;
    // A chrome that reaches past the Toolkit seam into GTK (the OTHER swap axis).
    const bad =
        \\//! A chrome that builds its own GTK window instead of using the seam.
        \\const std = @import("std");
        \\const c = @cImport({
        \\    @cInclude("gtk/gtk.h");
        \\});
        \\pub fn makeWindow() *c.GtkWindow {
        \\    return @ptrCast(c.gtk_window_new());
        \\}
    ;
    const tok = try scanForDirectImport(gpa, bad);
    try std.testing.expect(tok != null);
    try std.testing.expectEqualStrings("gtk", tok.?);
}

test "the guard PASSES prose that only DISCUSSES the bindings in comments" {
    const gpa = std.testing.allocator;
    // Mirrors the real chrome: the forbidden tokens appear ONLY in doc comments
    // (explaining the discipline), never in code. Comment-stripping must let
    // this through, else the guard would fail the current seam-respecting chrome.
    const clean =
        \\//! The chrome imports NEITHER `webkit` NOR `gtk`; it talks only to the
        \\//! Renderer/Toolkit seams. It owns no GTK/WebKit state.
        \\const std = @import("std");
        \\const renderer = @import("renderer.zig");
        \\const toolkit = @import("toolkit.zig");
        \\pub fn wire() void {} // no webkit/gtk here, only in this comment
    ;
    try std.testing.expect((try scanForDirectImport(gpa, clean)) == null);
}

test "comment stripping blanks line comments but preserves code length and newlines" {
    const gpa = std.testing.allocator;
    const src = "const a = 1; // gtk mentioned here\nconst b = 2;\n";
    const code = try stripLineComments(gpa, src);
    defer gpa.free(code);

    try std.testing.expectEqual(src.len, code.len);
    // The code before the comment survives; the comment body is gone.
    try std.testing.expect(std.mem.indexOf(u8, code, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "const b = 2;") != null);
    try std.testing.expect(std.ascii.indexOfIgnoreCase(code, "gtk") == null);
    // Newlines are preserved so line structure is intact.
    try std.testing.expectEqual(
        std.mem.count(u8, src, "\n"),
        std.mem.count(u8, code, "\n"),
    );
}
