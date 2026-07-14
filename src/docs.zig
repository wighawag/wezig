//! Doc-drift guard for the v0 subset-limits reference (`docs/v0-subset.md`).
//!
//! `docs/v0-subset.md` is the written CONTRACT for what HTML/CSS v0 accepts and
//! rejects (spec story 6). Its whole value is that it matches REALITY, so this
//! module holds a test that reads the doc and asserts it names every piece of
//! the subset the code actually enforces: every allowlisted HTML element, every
//! supported CSS `Property`, every diagnostic `Code`, and each element the
//! default-`display` table classifies as `block`. If a later task extends the
//! allowlist / property set / diagnostic codes but forgets to update the doc,
//! this test fails, keeping the reference honest.
//!
//! This is deliberately a NAME-PRESENCE guard, not a semantic parser: it proves
//! the doc mentions each token, not that the surrounding prose is correct (a
//! human/reviewer owns the prose). The authoritative sources it checks against
//! are the code itself (`html.element_allowlist`, `css.Property`,
//! `css.defaultDisplay`, `diagnostics.Code`), so the doc can never silently
//! drop a name the code still enforces.

const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const html = @import("html.zig");
const css = @import("css.zig");

/// The v0 subset-limits doc, relative to the repo root (the cwd `zig build
/// test` runs from).
const doc_path = "docs/v0-subset.md";

/// Read the whole doc into an owned buffer (relative to the test's cwd, the
/// repo root). Uses the testing `Io` since these are test-only reads.
fn readDoc(gpa: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, doc_path, gpa, .limited(1 << 20));
}

/// Whether `haystack` contains `needle` as a case-sensitive substring.
fn mentions(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "the v0 subset doc names every allowlisted HTML element" {
    const gpa = std.testing.allocator;
    const doc = try readDoc(gpa);
    defer gpa.free(doc);

    for (html.element_allowlist) |el| {
        // Elements are documented in backticks (e.g. `div`), so require the
        // backticked form to avoid matching an unrelated substring.
        var buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "`{s}`", .{el});
        if (!mentions(doc, needle)) {
            std.debug.print("doc is missing allowlisted element: {s}\n", .{el});
            return error.DocMissingElement;
        }
    }
}

test "the v0 subset doc names every supported CSS property" {
    const gpa = std.testing.allocator;
    const doc = try readDoc(gpa);
    defer gpa.free(doc);

    for (comptime std.enums.values(css.Property)) |prop| {
        const name = cssPropertyName(prop);
        var buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "`{s}`", .{name});
        if (!mentions(doc, needle)) {
            std.debug.print("doc is missing CSS property: {s}\n", .{name});
            return error.DocMissingProperty;
        }
    }
}

test "the v0 subset doc names every diagnostic code" {
    const gpa = std.testing.allocator;
    const doc = try readDoc(gpa);
    defer gpa.free(doc);

    for (comptime std.enums.values(diagnostics.Code)) |code| {
        const name = @tagName(code);
        if (!mentions(doc, name)) {
            std.debug.print("doc is missing diagnostic code: {s}\n", .{name});
            return error.DocMissingCode;
        }
    }
}

test "the v0 subset doc names every default-block element" {
    const gpa = std.testing.allocator;
    const doc = try readDoc(gpa);
    defer gpa.free(doc);

    // Every allowlisted element the hardcoded default-`display` table treats as
    // `block` must appear in the doc's default-display table (backticked).
    for (html.element_allowlist) |el| {
        if (!std.mem.eql(u8, css.defaultDisplay(el), "block")) continue;
        var buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "`{s}`", .{el});
        if (!mentions(doc, needle)) {
            std.debug.print("doc is missing default-block element: {s}\n", .{el});
            return error.DocMissingBlockElement;
        }
    }
}

/// The canonical CSS property NAME (hyphenated, as written in CSS and the doc)
/// for a `css.Property`. Kept here so the doc guard checks the real property
/// spelling, not the Zig enum spelling (`background_color` vs
/// `background-color`).
fn cssPropertyName(prop: css.Property) []const u8 {
    return switch (prop) {
        .display => "display",
        .color => "color",
        .background_color => "background-color",
        .font_family => "font-family",
        .font_size => "font-size",
        .font_weight => "font-weight",
        .width => "width",
        .height => "height",
        .margin => "margin",
        .padding => "padding",
    };
}
