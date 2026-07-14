//! Golden-image generator (MAINTENANCE tool, ADR-0003). Regenerates the
//! committed reference PNGs under `src/testdata/golden/` from the SAME
//! `renderScene` path the golden tests assert against, so references stay
//! self-consistent with the rasteriser. Run it only after an intentional raster
//! change:
//!
//!     zig build gen-goldens
//!
//! It is NOT part of `zig build test`; the tests compare against the committed
//! PNGs rather than regenerating them, so an accidental raster regression is
//! caught instead of silently re-baselined. The output directory must already
//! exist (it is a committed part of the repo).

const std = @import("std");
const wezig = @import("wezig");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir = "src/testdata/golden";
    try wezig.paint.writeGoldens(gpa, io, dir);
    std.debug.print("wrote {d} golden references to {s}/\n", .{ wezig.paint.golden_scenes.len, dir });
}
