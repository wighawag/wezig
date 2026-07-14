//! The offscreen paint TARGET: a 32-bit RGBA8888 pixel buffer the software
//! rasteriser (`StbSoftwareBackend`) draws into, plus a minimal PNG codec so
//! golden-image tests can WRITE a rendered surface and COMPARE it against a
//! committed reference PNG.
//!
//! ## Why a surface, not a window (ADR-0003)
//!
//! The paint stack renders into THIS buffer with no SDL/window involved, so the
//! golden-image test path is HEADLESS and CI-safe: a test lays out a fixture,
//! paints it to a `Surface`, and compares pixels to a reference PNG. The
//! on-screen SDL3 window (the app entrypoint) merely BLITS this same surface;
//! it is never on the test path.
//!
//! ## Pixel format
//!
//! Pixels are RGBA in memory order (`[0]=R, [1]=G, [2]=B, [3]=A`), one byte per
//! channel, non-premultiplied. `fillRect`/glyph coverage blend source-over.
//!
//! ## PNG codec scope
//!
//! Deliberately minimal (ADR-0003): 8-bit RGBA, non-interlaced, a SINGLE
//! zlib STORED (uncompressed) block. This is enough to persist small v0
//! goldens with zero external dependency; it is NOT a general PNG library. The
//! decoder accepts exactly what the encoder writes (8-bit RGBA colour type 6,
//! filter type 0 per scanline) so a committed golden round-trips.

const std = @import("std");

/// One RGBA8888 pixel-buffer paint target. Owns its `pixels` slice.
pub const Surface = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes, RGBA in memory order, row-major top-to-bottom.
    pixels: []u8,
    gpa: std.mem.Allocator,

    /// Allocate a `width` x `height` surface, cleared to opaque `bg`.
    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, bg: Rgba) !Surface {
        const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
        var s = Surface{ .width = width, .height = height, .pixels = pixels, .gpa = gpa };
        s.clear(bg);
        return s;
    }

    pub fn deinit(self: *Surface) void {
        self.gpa.free(self.pixels);
    }

    /// Overwrite every pixel with `c` (opaque set, no blend).
    pub fn clear(self: *Surface, c: Rgba) void {
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            self.pixels[i + 0] = c.r;
            self.pixels[i + 1] = c.g;
            self.pixels[i + 2] = c.b;
            self.pixels[i + 3] = c.a;
        }
    }

    /// Blend one pixel source-over. `(x, y)` outside the surface is a no-op
    /// (clipping), so callers may draw partially-offscreen shapes safely.
    pub fn blendPixel(self: *Surface, x: i64, y: i64, c: Rgba) void {
        if (x < 0 or y < 0) return;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.width or uy >= self.height) return;
        const idx = (@as(usize, uy) * self.width + ux) * 4;
        blendInto(self.pixels[idx .. idx + 4], c);
    }

    /// Fill an axis-aligned integer rectangle, source-over blended, clipped to
    /// the surface. `w`/`h` <= 0 is a no-op.
    pub fn fillRect(self: *Surface, x: i64, y: i64, w: i64, h: i64, c: Rgba) void {
        if (w <= 0 or h <= 0) return;
        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = @min(x + w, @as(i64, self.width));
        const y1 = @min(y + h, @as(i64, self.height));
        var py = y0;
        while (py < y1) : (py += 1) {
            var px = x0;
            while (px < x1) : (px += 1) {
                const idx = (@as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px))) * 4;
                blendInto(self.pixels[idx .. idx + 4], c);
            }
        }
    }

    /// Encode the surface as a PNG (8-bit RGBA, stored zlib block). Caller owns
    /// the returned bytes.
    pub fn encodePng(self: *const Surface, gpa: std.mem.Allocator) ![]u8 {
        return encode(gpa, self.width, self.height, self.pixels);
    }

    /// Write the surface to `path` (relative to cwd) as a PNG, through the
    /// Zig 0.16 `Io` filesystem interface. Used by the golden generator; the
    /// golden TESTS compare in memory and never touch the disk.
    pub fn writePng(self: *const Surface, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const bytes = try self.encodePng(gpa);
        defer gpa.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }
};

/// A straight (non-premultiplied) RGBA colour.
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

/// Source-over blend `src` onto the 4-byte `dst` pixel (both straight alpha).
fn blendInto(dst: []u8, src: Rgba) void {
    if (src.a == 255) {
        dst[0] = src.r;
        dst[1] = src.g;
        dst[2] = src.b;
        dst[3] = 255;
        return;
    }
    if (src.a == 0) return;
    const sa: u32 = src.a;
    const ia: u32 = 255 - sa;
    // Straight-alpha over an opaque-ish background: round((src*sa + dst*ia)/255).
    dst[0] = @intCast((@as(u32, src.r) * sa + @as(u32, dst[0]) * ia + 127) / 255);
    dst[1] = @intCast((@as(u32, src.g) * sa + @as(u32, dst[1]) * ia + 127) / 255);
    dst[2] = @intCast((@as(u32, src.b) * sa + @as(u32, dst[2]) * ia + 127) / 255);
    const da: u32 = dst[3];
    dst[3] = @intCast(sa + (da * ia + 127) / 255);
}

// ---------------------------------------------------------------------------
// Minimal PNG codec (8-bit RGBA, non-interlaced, single STORED zlib block).
// ---------------------------------------------------------------------------

const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

/// Encode `w`x`h` RGBA (`w*h*4` bytes) as a PNG into a fresh buffer.
fn encode(gpa: std.mem.Allocator, w: u32, h: u32, pixels: []const u8) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, w) * h * 4);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &png_signature);

    // IHDR: width, height, bit depth 8, colour type 6 (RGBA), compression 0,
    // filter 0, interlace 0.
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(gpa, &out, "IHDR", &ihdr);

    // Raw image data with a leading filter byte (0 = none) per scanline.
    const stride = @as(usize, w) * 4;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.ensureTotalCapacity(gpa, (stride + 1) * h);
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        raw.appendAssumeCapacity(0);
        raw.appendSliceAssumeCapacity(pixels[row * stride ..][0..stride]);
    }

    const zlib = try zlibStore(gpa, raw.items);
    defer gpa.free(zlib);
    try writeChunk(gpa, &out, "IDAT", zlib);
    try writeChunk(gpa, &out, "IEND", &.{});

    return out.toOwnedSlice(gpa);
}

/// Wrap `data` in a zlib stream using STORED (uncompressed) deflate blocks.
fn zlibStore(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (check bits).
    try out.append(gpa, 0x78);
    try out.append(gpa, 0x01);

    // STORED blocks: each carries up to 65535 bytes; LEN then ~LEN (LE) then raw.
    var offset: usize = 0;
    while (true) {
        const remaining = data.len - offset;
        const block_len: u16 = @intCast(@min(remaining, 0xffff));
        const final = (offset + block_len) == data.len;
        try out.append(gpa, if (final) 1 else 0); // BFINAL, BTYPE=00 (stored).
        var lenbuf: [4]u8 = undefined;
        std.mem.writeInt(u16, lenbuf[0..2], block_len, .little);
        std.mem.writeInt(u16, lenbuf[2..4], ~block_len, .little);
        try out.appendSlice(gpa, &lenbuf);
        try out.appendSlice(gpa, data[offset .. offset + block_len]);
        offset += block_len;
        if (final) break;
    }

    // zlib trailer: Adler-32 of the uncompressed data (big-endian).
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, adler32(data), .big);
    try out.appendSlice(gpa, &adler);
    return out.toOwnedSlice(gpa);
}

fn writeChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(tag);
    crc.update(data);
    var crcbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crcbuf, crc.final(), .big);
    try out.appendSlice(gpa, &crcbuf);
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

/// A decoded PNG (RGBA), owning its pixels. Used by golden comparison.
pub const DecodedPng = struct {
    width: u32,
    height: u32,
    pixels: []u8,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *DecodedPng) void {
        self.gpa.free(self.pixels);
    }
};

/// Decode a PNG produced by `encode` (8-bit RGBA, non-interlaced, filter 0, a
/// single zlib STORED block). This accepts exactly what we write; it is not a
/// general PNG reader.
pub fn decodePng(gpa: std.mem.Allocator, bytes: []const u8) !DecodedPng {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &png_signature)) return error.NotPng;
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    while (pos + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const tag = bytes[pos + 4 .. pos + 8];
        const data_start = pos + 8;
        if (data_start + len + 4 > bytes.len) return error.Truncated;
        const data = bytes[data_start .. data_start + len];
        if (std.mem.eql(u8, tag, "IHDR")) {
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[9] != 6) return error.UnsupportedPng;
        } else if (std.mem.eql(u8, tag, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, tag, "IEND")) {
            break;
        }
        pos = data_start + len + 4; // skip data + CRC.
    }

    const raw = try zlibInflateStored(gpa, idat.items);
    defer gpa.free(raw);

    const stride = @as(usize, width) * 4;
    const pixels = try gpa.alloc(u8, stride * height);
    errdefer gpa.free(pixels);
    var row: u32 = 0;
    var rp: usize = 0;
    while (row < height) : (row += 1) {
        if (rp >= raw.len) return error.Truncated;
        const filter = raw[rp];
        rp += 1;
        if (filter != 0) return error.UnsupportedFilter;
        if (rp + stride > raw.len) return error.Truncated;
        @memcpy(pixels[row * stride ..][0..stride], raw[rp .. rp + stride]);
        rp += stride;
    }

    return .{ .width = width, .height = height, .pixels = pixels, .gpa = gpa };
}

/// Inflate a zlib stream of STORED (uncompressed) blocks (the only kind we
/// emit). Skips the 2-byte zlib header and the 4-byte Adler trailer.
fn zlibInflateStored(gpa: std.mem.Allocator, stream: []const u8) ![]u8 {
    if (stream.len < 2 + 4) return error.Truncated;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 2; // skip zlib header.
    const end = stream.len - 4; // stop before Adler trailer.
    while (pos < end) {
        const header = stream[pos];
        pos += 1;
        const final = (header & 1) == 1;
        const btype = (header >> 1) & 0x3;
        if (btype != 0) return error.UnsupportedDeflate;
        if (pos + 4 > end) return error.Truncated;
        const len = std.mem.readInt(u16, stream[pos..][0..2], .little);
        pos += 4; // LEN + ~LEN.
        if (pos + len > end) return error.Truncated;
        try out.appendSlice(gpa, stream[pos .. pos + len]);
        pos += len;
        if (final) break;
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Golden comparison.
// ---------------------------------------------------------------------------

/// The outcome of comparing a rendered surface against a reference image.
pub const Diff = struct {
    /// Number of pixels whose per-channel difference exceeded the tolerance.
    mismatched: usize,
    /// The largest single per-channel absolute difference seen anywhere.
    max_channel_delta: u8,
    /// True if dimensions matched and no pixel exceeded tolerance.
    equal: bool,
};

/// Compare `surface` against a decoded reference, allowing a small per-channel
/// `tolerance` (goldens are generated by this same rasteriser, so tolerance
/// absorbs only rounding noise; ADR-0003 sets the tolerance rationale). A size
/// mismatch is an immediate non-equal result.
pub fn compare(surface: *const Surface, ref: *const DecodedPng, tolerance: u8) Diff {
    if (surface.width != ref.width or surface.height != ref.height) {
        return .{ .mismatched = @max(surface.pixels.len, ref.pixels.len) / 4, .max_channel_delta = 255, .equal = false };
    }
    var mismatched: usize = 0;
    var max_delta: u8 = 0;
    var i: usize = 0;
    while (i < surface.pixels.len) : (i += 4) {
        var pixel_bad = false;
        for (0..4) |ch| {
            const a = surface.pixels[i + ch];
            const b = ref.pixels[i + ch];
            const d: u8 = if (a > b) a - b else b - a;
            if (d > max_delta) max_delta = d;
            if (d > tolerance) pixel_bad = true;
        }
        if (pixel_bad) mismatched += 1;
    }
    return .{ .mismatched = mismatched, .max_channel_delta = max_delta, .equal = mismatched == 0 };
}

// ===========================================================================
// Tests: the surface primitives + the PNG codec round-trip + golden compare.
// ===========================================================================

const testing = std.testing;

test "fillRect blends and clips to the surface bounds" {
    const gpa = testing.allocator;
    var s = try Surface.init(gpa, 4, 4, .{ .r = 0, .g = 0, .b = 0 });
    defer s.deinit();

    // Opaque red fill of the top-left 2x2, plus an overhanging rect that clips.
    s.fillRect(0, 0, 2, 2, .{ .r = 255, .g = 0, .b = 0 });
    s.fillRect(3, 3, 10, 10, .{ .r = 0, .g = 255, .b = 0 });

    // (0,0) is red.
    try testing.expectEqual(@as(u8, 255), s.pixels[0]);
    // (2,0) untouched (black).
    const idx_2_0 = (0 * 4 + 2) * 4;
    try testing.expectEqual(@as(u8, 0), s.pixels[idx_2_0]);
    // (3,3) green (the overhang clipped rather than crashing).
    const idx_3_3 = (3 * 4 + 3) * 4;
    try testing.expectEqual(@as(u8, 255), s.pixels[idx_3_3 + 1]);
}

test "source-over blend of a half-alpha colour" {
    const gpa = testing.allocator;
    var s = try Surface.init(gpa, 1, 1, .{ .r = 0, .g = 0, .b = 0 });
    defer s.deinit();
    // 50%-alpha white over black -> ~128 grey.
    s.blendPixel(0, 0, .{ .r = 255, .g = 255, .b = 255, .a = 128 });
    try testing.expect(s.pixels[0] >= 126 and s.pixels[0] <= 130);
}

test "PNG encode/decode round-trips pixels exactly" {
    const gpa = testing.allocator;
    var s = try Surface.init(gpa, 5, 3, .{ .r = 10, .g = 20, .b = 30 });
    defer s.deinit();
    s.fillRect(1, 1, 3, 1, .{ .r = 200, .g = 100, .b = 50 });

    const bytes = try s.encodePng(gpa);
    defer gpa.free(bytes);
    var dec = try decodePng(gpa, bytes);
    defer dec.deinit();

    try testing.expectEqual(s.width, dec.width);
    try testing.expectEqual(s.height, dec.height);
    try testing.expectEqualSlices(u8, s.pixels, dec.pixels);
}

test "compare reports equal within tolerance and flags size mismatch" {
    const gpa = testing.allocator;
    var s = try Surface.init(gpa, 3, 3, .{ .r = 0, .g = 0, .b = 0 });
    defer s.deinit();
    s.fillRect(0, 0, 3, 3, .{ .r = 100, .g = 100, .b = 100 });

    const bytes = try s.encodePng(gpa);
    defer gpa.free(bytes);
    var ref = try decodePng(gpa, bytes);
    defer ref.deinit();

    try testing.expect(compare(&s, &ref, 0).equal);

    // A one-channel-off surface stays equal under a tolerance of 2.
    s.pixels[0] = 101;
    try testing.expect(compare(&s, &ref, 2).equal);
    try testing.expect(!compare(&s, &ref, 0).equal);

    // Size mismatch is never equal.
    var small = try Surface.init(gpa, 2, 2, .{ .r = 0, .g = 0, .b = 0 });
    defer small.deinit();
    try testing.expect(!compare(&small, &ref, 255).equal);
}
