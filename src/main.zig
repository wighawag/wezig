//! Minimal CLI entry point. For now it just prints the product name so
//! `zig build run` executes something real; the actual browser CLI/UI lands in
//! later tasks. The display name is read from the single branding source of
//! truth, never hard-coded here.

const std = @import("std");
const wezig = @import("wezig");

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;

    try out.print("{s} — nothing to render yet.\n", .{wezig.branding.display_name});
    try out.flush();
}
