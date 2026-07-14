//! The single source of truth for the project's two swappable name identifiers.
//!
//! Per `CONTEXT.md` § Naming there are TWO names, each with its own lifecycle,
//! and NEITHER is hard-coded anywhere else. To rename either one, edit ONLY the
//! matching constant here (and, for `code_name`, keep `build.zig.zon`'s `.name`
//! in sync).
//!
//!   - `code_name`    the internal project/codebase identity (repo, module
//!                    namespace, `build.zig.zon` `.name`). Stable for now, but
//!                    it CAN change later.
//!   - `display_name` the user-facing product name. Undecided and WILL change;
//!                    every user-facing/UI reference must read this constant.

/// Internal code name for the project. Mirrors `build.zig.zon`'s `.name`.
pub const code_name: []const u8 = "wezig";

/// User-facing product name. Placeholder until a real name is chosen; every
/// user-facing surface must read this rather than hard-coding a literal.
pub const display_name: []const u8 = "wezig";

test "branding constants are non-empty" {
    const std = @import("std");
    try std.testing.expect(code_name.len > 0);
    try std.testing.expect(display_name.len > 0);
}
