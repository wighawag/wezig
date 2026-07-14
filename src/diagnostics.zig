//! The one structured diagnostics channel every v0 subset boundary reports
//! through. Unsupported-but-recoverable input is COLLECTED (many per run) while
//! processing continues, so tests can assert on exactly which diagnostics an
//! input produced, rather than scraping scattered `std.log` output or unwinding
//! error-union returns.
//!
//! Decisions (see the task done record for the why):
//!   - Severity is PER-CALL (an argument to `add`), not baked per `code`: the
//!     same boundary can be a recoverable `warning` in one context and a fatal
//!     `error` in another.
//!   - A source `Span` is a half-open byte range `[start, end)` into the input,
//!     carried OPTIONALLY per entry (some diagnostics have no meaningful span).
//!   - `msg` is a borrowed `[]const u8`; the sink does NOT own or copy it. The
//!     caller keeps message strings alive for the sink's lifetime (v0 messages
//!     are string literals, so this is free).

const std = @import("std");

/// How severe a diagnostic is.
pub const Severity = enum {
    /// The offending input was skipped and processing continued.
    warning,
    /// Could not produce output at all.
    err,
};

/// Stable diagnostic codes. Seeded with the v0 subset-boundary codes; later
/// tasks (HTML parse, CSS cascade, layout) APPEND to this enum. Keep additions
/// append-only so existing `@intFromEnum` values stay stable.
pub const Code = enum {
    /// `!important` was used but is not supported in the v0 cascade.
    unsupported_important,
    /// A CSS property outside the supported set.
    unknown_property,
    /// A CSS selector outside the supported set.
    unsupported_selector,
    /// An HTML element outside the v0 allow-list.
    non_allowlisted_element,
    /// A CSS unit outside the supported set.
    unsupported_unit,
};

/// A half-open byte range `[start, end)` into the source input a diagnostic
/// points at.
pub const Span = struct {
    start: usize,
    end: usize,
};

/// One collected diagnostic.
pub const Entry = struct {
    severity: Severity,
    code: Code,
    /// Where in the input this points, if anywhere.
    span: ?Span,
    /// Borrowed, human-readable detail (not owned by the sink).
    msg: []const u8,
};

/// Structured collector. Push entries with `add`; read them back via
/// `entries()`; surface them to the app with `logAll`.
pub const Diagnostics = struct {
    list: std.ArrayList(Entry),

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        _ = gpa;
        return .{ .list = .empty };
    }

    pub fn deinit(self: *Diagnostics, gpa: std.mem.Allocator) void {
        self.list.deinit(gpa);
    }

    /// Record one diagnostic. `span` may be `null` when the diagnostic does not
    /// point at a specific input location.
    pub fn add(
        self: *Diagnostics,
        gpa: std.mem.Allocator,
        severity: Severity,
        code: Code,
        span: ?Span,
        msg: []const u8,
    ) !void {
        try self.list.append(gpa, .{
            .severity = severity,
            .code = code,
            .span = span,
            .msg = msg,
        });
    }

    /// The collected entries, in insertion order.
    pub fn entries(self: *const Diagnostics) []const Entry {
        return self.list.items;
    }

    /// Whether any collected diagnostic is an `err`.
    pub fn hasError(self: *const Diagnostics) bool {
        for (self.list.items) |e| {
            if (e.severity == .err) return true;
        }
        return false;
    }

    /// App-facing helper: surface every collected diagnostic via `std.log`, so
    /// the app "errors visibly" while tests assert structurally on `entries()`.
    pub fn logAll(self: *const Diagnostics) void {
        for (self.list.items) |e| {
            switch (e.severity) {
                .warning => std.log.warn("{t}: {s}", .{ e.code, e.msg }),
                .err => std.log.err("{t}: {s}", .{ e.code, e.msg }),
            }
        }
    }
};

test "collects entries in order with exact code+severity sequence" {
    const gpa = std.testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    try diag.add(gpa, .warning, .unknown_property, .{ .start = 0, .end = 4 }, "prop 'wibble'");
    try diag.add(gpa, .warning, .unsupported_unit, null, "unit 'vmin'");
    try diag.add(gpa, .err, .non_allowlisted_element, .{ .start = 10, .end = 16 }, "<script>");

    const got = diag.entries();
    try std.testing.expectEqual(@as(usize, 3), got.len);

    const expected = [_]struct { code: Code, sev: Severity }{
        .{ .code = .unknown_property, .sev = .warning },
        .{ .code = .unsupported_unit, .sev = .warning },
        .{ .code = .non_allowlisted_element, .sev = .err },
    };
    for (expected, 0..) |want, i| {
        try std.testing.expectEqual(want.code, got[i].code);
        try std.testing.expectEqual(want.sev, got[i].severity);
    }
}

test "carries optional source span per entry" {
    const gpa = std.testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    try diag.add(gpa, .warning, .unsupported_important, .{ .start = 3, .end = 13 }, "!important");
    try diag.add(gpa, .warning, .unsupported_selector, null, "::before");

    const got = diag.entries();
    try std.testing.expectEqual(Span{ .start = 3, .end = 13 }, got[0].span.?);
    try std.testing.expect(got[1].span == null);
}

test "hasError reflects whether any err severity was collected" {
    const gpa = std.testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    try diag.add(gpa, .warning, .unknown_property, null, "w");
    try std.testing.expect(!diag.hasError());
    try diag.add(gpa, .err, .non_allowlisted_element, null, "e");
    try std.testing.expect(diag.hasError());
}

test "empty sink has no entries" {
    const gpa = std.testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), diag.entries().len);
    try std.testing.expect(!diag.hasError());
}
