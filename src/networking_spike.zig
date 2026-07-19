//! De-risking SPIKE — the BOUND HTTP + TLS half (spec `explore-native-renderer`,
//! story 2 + story 6, decision 2). This module binds the PICKED stack — **libcurl
//! + its vetted TLS backend, NEVER hand-written TLS** — to the `Fetcher` seam in
//! `src/networking.zig`, and proves the COMPATIBILITY FLOOR on the narrowest real
//! case: fetch ONE ordinary `https://` resource successfully.
//!
//! ## The library pick (recorded for `native-renderer-findings-and-build-plan`)
//!
//! HTTP client + TLS: **libcurl** (its OpenSSL TLS backend on the dev box/CI),
//! bound through Zig's C interop. libcurl is a mature, ubiquitously-vetted C HTTP
//! stack that terminates TLS through a vetted library (OpenSSL here;
//! GnuTLS/BoringSSL are drop-in curl backends) — so wezig writes ZERO TLS, in
//! line with decision 2 ("a BOUND HTTP+TLS stack, never write TLS"). It slots
//! into the repo's existing C-library-binding strategy (CONTEXT.md; Skia /
//! FreeType / HarfBuzz / SDL are bound the same way). Durable record:
//! `work/notes/findings/networking-http-tls-pick-libcurl-2026-07-18.md`.
//!
//! ## Why a separate module + step (mirrors `harfbuzz_spike.zig`)
//!
//! `src/networking.zig` (the seam + the hash-verify THESIS) is PURE ZIG (std
//! crypto) and lives in the `wezig` library `mod` + the display-free
//! `zig build test` gate. THIS module links **libcurl**, a SYSTEM library
//! (`curl/curl.h` via pkg-config / the `-lcurl` the build adds), which the bare
//! CI `gate` job never provisions; and its only real proof is a LIVE `https://`
//! fetch (network + `libcurl4-openssl-dev`). So it is compiled + run ONLY by the
//! dedicated `zig build networking-fetch-test` step, in a dedicated `networking`
//! CI leg — mirroring the `harfbuzz` / `webview` legs (ADR-0007: provisioned/live
//! proofs stay OFF the core display-free gate). It is deliberately NOT
//! re-exported from `src/root.zig`, so libcurl never enters the desktop library
//! `mod` or the mobile cross-compiles.
//!
//! The live legs are guarded by a build option (`build_options.networking_live`):
//! `zig build networking-fetch-test` sets `-Dnetworking-live`, so the real fetch
//! runs; without it (a bare `zig test`, or the flag off) the network legs SKIP
//! and still pass, proving compilation/linkage of the bound stack without egress.
//! The offline seam + verify proof is the gate's job (`networking.zig`), so
//! nothing load-bearing depends on network reachability.

const std = @import("std");
const wezig = @import("wezig");
const build_options = @import("build_options");

const net = wezig.networking;
const Fetcher = net.Fetcher;
const Resource = net.Resource;
const FetchError = net.FetchError;
const ContentAddress = net.ContentAddress;
const fetchVerified = net.fetchVerified;

/// libcurl (the PICK): the bound HTTP + TLS stack (decision 2). A `Fetcher` that
/// does a real `https://` GET terminated by a vetted TLS library (curl's OpenSSL
/// backend here), with wezig writing ZERO TLS.
const c = @cImport({
    @cInclude("curl/curl.h");
});

/// The libcurl-backed `Fetcher`. Satisfies the SAME `net.Fetcher` seam the
/// offline fake fetcher does, so `fetchVerified` and any future caller are
/// backend-agnostic.
pub const CurlFetcher = struct {
    /// Accumulates body chunks libcurl streams via `writeChunk`.
    const Accum = struct {
        gpa: std.mem.Allocator,
        buf: std.ArrayList(u8) = .empty,
    };

    pub fn init() error{FetchFailed}!CurlFetcher {
        if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return error.FetchFailed;
        return .{};
    }

    pub fn deinit(_: *CurlFetcher) void {
        c.curl_global_cleanup();
    }

    pub fn fetcher(self: *CurlFetcher) Fetcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Fetcher.VTable{ .fetch = fetch };

    fn writeChunk(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
        const total = size * nmemb;
        const accum: *Accum = @ptrCast(@alignCast(userdata.?));
        accum.buf.appendSlice(accum.gpa, ptr[0..total]) catch return 0; // 0 => curl aborts
        return total;
    }

    fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, url: []const u8) FetchError!Resource {
        _ = ctx;
        const handle = c.curl_easy_init() orelse return error.FetchFailed;
        defer c.curl_easy_cleanup(handle);

        // NUL-terminate the URL for the C API.
        var url_buf: [2048]u8 = undefined;
        if (url.len + 1 > url_buf.len) return error.FetchFailed;
        @memcpy(url_buf[0..url.len], url);
        url_buf[url.len] = 0;

        var accum = Accum{ .gpa = gpa };
        defer accum.buf.deinit(gpa);

        _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, &url_buf);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, writeChunk);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, &accum);
        _ = c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
        _ = c.curl_easy_setopt(handle, c.CURLOPT_TIMEOUT, @as(c_long, 30));
        // Fail on >=400 so a broken URL surfaces as FetchFailed, not an
        // error-page body that would then confuse hash-verify.
        _ = c.curl_easy_setopt(handle, c.CURLOPT_FAILONERROR, @as(c_long, 1));
        // TLS verification stays ON (curl's default): the compatibility floor
        // is a REAL https handshake through the vetted TLS backend.

        if (c.curl_easy_perform(handle) != c.CURLE_OK) return error.FetchFailed;

        var status: c_long = 0;
        _ = c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status);

        const body = accum.buf.toOwnedSlice(gpa) catch return error.OutOfMemory;
        return .{ .body = body, .status = @intCast(status) };
    }
};

// ===========================================================================
// Live tests (run via `zig build networking-fetch-test`, the `networking` CI
// leg). Guarded by WEZIG_NETWORKING_LIVE so a bare `zig test` without network
// egress compiles + links the bound stack and SKIPS the fetch — nothing
// load-bearing depends on reachability (the offline verify proof is the gate's
// job, in `networking.zig`).
// ===========================================================================

const testing = std.testing;

/// True iff this build opted into live network legs (`-Dnetworking-live`, set by
/// the `networking-fetch-test` step).
fn liveEnabled() bool {
    return build_options.networking_live;
}

test "CurlFetcher builds + links the bound libcurl+TLS stack (compile/link proof, no network)" {
    // Even with the network off, this proves the bound stack COMPILES and LINKS
    // (curl_global_init succeeds) — the linkage half of the pick, on every run.
    var client = try CurlFetcher.init();
    client.deinit();
}

test "LIVE: one ordinary https resource is fetched through the bound libcurl+TLS stack" {
    if (!liveEnabled()) return error.SkipZigTest;
    const gpa = testing.allocator;

    var client = try CurlFetcher.init();
    defer client.deinit();

    // example.com: a stable, boring https resource — the compatibility floor.
    var res = try client.fetcher().fetch(gpa, "https://example.com/");
    defer res.deinit(gpa);

    try testing.expectEqual(@as(u16, 200), res.status);
    try testing.expect(res.body.len > 0);
    // It really came back as HTML from the server (sanity, not conformance): the
    // bound stack terminated TLS and delivered a body.
    try testing.expect(std.mem.indexOf(u8, res.body, "Example Domain") != null or
        std.mem.indexOf(u8, res.body, "<html") != null or
        std.mem.indexOf(u8, res.body, "<!doctype") != null);
}

test "LIVE: the SAME bound stack fetches a resource and hash-verifies it end-to-end" {
    if (!liveEnabled()) return error.SkipZigTest;
    const gpa = testing.allocator;

    // The content-addressed path over the REAL bound transport, on the same
    // `fetchVerified` seam as offline. A live IPFS gateway's exact CID hashing
    // (multihash/codec) is the IPFS subsystem's concern (out of scope), and
    // public gateways are flaky; so this leg proves the SEAM + VERIFY hold over
    // real network bytes using a resource we can address deterministically:
    // fetch example.com's bytes, author the content address FROM those bytes,
    // and prove `fetchVerified` ACCEPTS the matching address and REJECTS a wrong
    // one. The offline `networking.zig` tests are the primary thesis proof; this
    // shows it composes with the bound stack.
    var client = try CurlFetcher.init();
    defer client.deinit();

    var probe = try client.fetcher().fetch(gpa, "https://example.com/");
    defer probe.deinit(gpa);
    try testing.expect(probe.body.len > 0);

    // A CONTENT ADDRESS derived from the fetched bytes: a second fetch of the
    // same resource must hash to it (accept). This is the verify contract riding
    // the bound transport.
    var digest_buf: [32]u8 = undefined;
    const good = ContentAddress.ofBytes(.sha256, probe.body, &digest_buf);
    var verified = try fetchVerified(client.fetcher(), gpa, "https://example.com/", good);
    defer verified.deinit(gpa);
    try testing.expect(verified.body.len > 0);

    // And a WRONG address over the same live transport is REJECTED — the thesis.
    const wrong = ContentAddress{ .algo = .sha256, .digest = &[_]u8{0xAB} ** 32 };
    try testing.expectError(
        error.HashMismatch,
        fetchVerified(client.fetcher(), gpa, "https://example.com/", wrong),
    );
}
