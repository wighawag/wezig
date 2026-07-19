//! The `ipfs://` fetch+verify glue that serves ONE content-addressed CID
//! THROUGH the `Renderer` seam's custom-scheme interception hook (spec
//! `explore-web3-capabilities`, stories 2 + 4; ADR-0015 decision 6 depth (i);
//! ADR-0011). This is the NARROWEST real case of native content-addressed
//! resolution: fetch a CID's bytes from an untrusted transport (a gateway),
//! HASH-VERIFY them locally against the content address, and serve the verified
//! bytes as a `renderer.SchemeResponse` — or REJECT on mismatch, so the page
//! NEVER observes unverified content-addressed bytes.
//!
//! ## What this de-risks (and what it deliberately is NOT)
//!
//! This proves the ATTACH: the landed verify-half (`net.Fetcher` +
//! `net.ContentAddress.verify` / `net.fetchVerified`, `src/networking.zig`) rides
//! the `Renderer` seam's `registerScheme` hook (`src/renderer.zig`, proven by
//! `seam-script-bridge-and-interception`). It does NOT rebuild verification and
//! it is NOT the IPFS subsystem:
//!
//!   - The full CID GRAMMAR (multibase/multihash decode of an `ipfs://…` string
//!     into a `net.ContentAddress`) is the IPFS build's job, out of scope here;
//!     this spike is handed the address + the source URL directly (`CidMapping`).
//!   - Only depth (i) verified-gateway is exercised (ADR-0015 decision 6). The
//!     DEPTH LADDER (bound node → in-browser node; user's own node always
//!     allowed; `ipns://` in scope) is RECORDED for the findings task, not built
//!     — see `work/notes/findings/ipfs-depth-ladder-and-verified-gateway-2026-07-19.md`.
//!   - SERVICE-WORKER HOSTING on `ipfs://` is OUT of scope (ADR-0016): stock
//!     WebKitGTK hard-rejects `serviceWorker.register()` on non-HTTP(S) schemes
//!     with no public knob; that is delivered separately by a carried fork patch
//!     (`spike-webkitgtk-sw-scheme-patch`). The SECURE-ORIGIN trait declaration
//!     this task DOES add (`Renderer.declareSchemeSecurity`) is independent and
//!     works on stock WebKitGTK.
//!
//! ## Pure Zig behind the seam — runs in the display-free `zig build test` gate
//!
//! This module imports only `networking.zig` (the seam + verifier, std crypto)
//! and `renderer.zig` (the seam interface): NO webview/GTK binding. So the
//! fetch+verify-through-the-hook proof runs OFFLINE and deterministically in the
//! core gate with a `net.FakeFetcher` + the `renderer.FakeRenderer` — the same
//! discipline `web3_origin.zig` / `wallet_broker.zig` follow. The live WebKitGTK
//! leg (the real `ipfs://` scheme + `WebKitSecurityManager` secure-origin proof)
//! is a dedicated off-core-gate step under Xvfb (ADR-0007), NOT here.

const std = @import("std");
const net = @import("networking.zig");
const renderer = @import("renderer.zig");

/// The `ipfs://` scheme string this handler registers under. A constant so the
/// scheme name has ONE source of truth shared by the seam registration and the
/// secure-origin trait declaration below.
pub const scheme = "ipfs";

/// The security traits `ipfs://` is registered with (ADR-0015 decision 7): a
/// first-class SECURE origin (its bytes are hash-verified — the strongest
/// origin, ADR-0011), CORS-enabled so verified content can be fetched
/// cross-origin the way a real app needs. NOT `local`. Declared at the seam via
/// `Renderer.declareSchemeSecurity(ipfs_scheme.scheme, ipfs_scheme.secure_origin_traits)`,
/// so a `WezigRenderer` reproduces it after the swap.
pub const secure_origin_traits = renderer.SchemeSecurityTraits{ .secure = true, .cors = true };

/// A single resolved CID: where its bytes come from (`source_url` — an untrusted
/// gateway/mirror; transport is orthogonal to verification) and what they must
/// hash to (`address`). Decoding a real `ipfs://…` CID string into one of these
/// is the IPFS subsystem's job (the CID grammar, out of scope); the spike is
/// handed the mapping directly. The `content_type` is what the verified bytes
/// are served as through the hook.
pub const CidMapping = struct {
    /// The `ipfs://…` request URI this mapping answers (the full scheme URI the
    /// hook receives, e.g. `ipfs://bafy…`).
    request_uri: []const u8,
    /// Where to fetch the bytes from (an untrusted gateway/mirror URL). May
    /// differ from `request_uri`: the CID is the trust, the gateway is transport.
    source_url: []const u8,
    /// The content address the fetched bytes MUST hash to, or they are rejected.
    address: net.ContentAddress,
    /// The MIME type the verified bytes are served as (e.g. `text/html`).
    content_type: []const u8,
};

/// The result of resolving one `ipfs://` request through fetch+verify: either
/// the VERIFIED, owned bytes ready to serve through the hook, or a rejection.
pub const Resolution = union(enum) {
    /// The bytes were fetched AND hash-verified: safe to serve. `body` is owned
    /// by the caller (freed with the allocator passed to `resolve`).
    verified: struct { body: []u8, content_type: []const u8 },
    /// No mapping matched the request URI (a request for an unknown CID).
    unknown_cid,
    /// The bytes did NOT hash to the content address — REJECTED (the thesis).
    hash_mismatch,
    /// The transport failed to deliver the bytes.
    fetch_failed,
    /// Ran out of memory buffering the body.
    out_of_memory,
};

/// Resolve one `ipfs://` request URI to VERIFIED bytes THROUGH the `net.Fetcher`
/// seam: find the CID mapping for `request_uri`, `net.fetchVerified` its bytes
/// (fetch through the untrusted transport, then hash-check against the content
/// address), and hand back the owned verified bytes — or a rejection variant.
/// This is the load-bearing step: a caller can NEVER get bytes back that did not
/// hash to their address (`net.fetchVerified` frees the fetched `Resource` and
/// surfaces `HashMismatch` on a mismatch). The `mappings` are the spike's
/// stand-in for the IPFS subsystem's CID resolver.
pub fn resolve(
    gpa: std.mem.Allocator,
    fetcher: net.Fetcher,
    mappings: []const CidMapping,
    request_uri: []const u8,
) Resolution {
    const mapping = for (mappings) |m| {
        if (std.mem.eql(u8, m.request_uri, request_uri)) break m;
    } else return .unknown_cid;

    const res = net.fetchVerified(fetcher, gpa, mapping.source_url, mapping.address) catch |err| {
        return switch (err) {
            error.HashMismatch => .hash_mismatch,
            error.MalformedAddress => .hash_mismatch,
            error.FetchFailed => .fetch_failed,
            error.OutOfMemory => .out_of_memory,
        };
    };
    // Transfer ownership of the verified body to the caller; drop the status
    // wrapper (the hook serves bytes + content-type, not an HTTP status).
    return .{ .verified = .{ .body = res.body, .content_type = mapping.content_type } };
}

/// A native `renderer.SchemeHandler` that serves `ipfs://` requests by
/// fetch-verifying the CID's bytes through the `net.Fetcher` seam. Construct with
/// `init`, obtain the seam handler with `handler()`, register it through
/// `Renderer.registerScheme(ipfs_scheme.scheme, …)`, and declare the secure
/// origin with `Renderer.declareSchemeSecurity(ipfs_scheme.scheme,
/// ipfs_scheme.secure_origin_traits)`.
///
/// The seam's `SchemeHandler.onRequest` is synchronous and returns a
/// `SchemeResponse` whose slices must stay valid until the handler is next
/// called (the backend copies them immediately). So this handler owns ONE
/// `served` buffer: each request frees the previous body and stores the new
/// verified one, exactly matching the seam's borrow contract. On any rejection
/// it serves a small error body (so a mismatch is visible, never silently
/// served as if valid) — the REJECTION is the thesis.
pub const IpfsSchemeHandler = struct {
    gpa: std.mem.Allocator,
    fetcher: net.Fetcher,
    mappings: []const CidMapping,
    /// The verified body currently being served (owned); freed on the next
    /// request and in `deinit`. Null until the first request.
    served: ?[]u8 = null,
    /// The outcome of the last request (test-observable): proves a request was
    /// verified-and-served vs rejected.
    last: ?Resolution = null,

    /// The body served on a rejection, so a page never receives rejected bytes
    /// as if they were the CID's content. A fixed, safe placeholder.
    pub const rejection_body = "ipfs: content REJECTED (bytes did not hash to the content address)";
    pub const rejection_content_type = "text/plain";

    pub fn init(gpa: std.mem.Allocator, fetcher: net.Fetcher, mappings: []const CidMapping) IpfsSchemeHandler {
        return .{ .gpa = gpa, .fetcher = fetcher, .mappings = mappings };
    }

    pub fn deinit(self: *IpfsSchemeHandler) void {
        if (self.served) |b| self.gpa.free(b);
        self.* = undefined;
    }

    /// The seam `SchemeHandler` value: register THIS through
    /// `Renderer.registerScheme(ipfs_scheme.scheme, h.handler())`.
    pub fn handler(self: *IpfsSchemeHandler) renderer.SchemeHandler {
        return .{ .ctx = self, .onRequest = onRequest };
    }

    fn onRequest(ctx: *anyopaque, uri: []const u8) renderer.SchemeResponse {
        const self: *IpfsSchemeHandler = @ptrCast(@alignCast(ctx));
        // Free the previous served body (the seam only needs it valid until the
        // next call) before resolving the new request.
        if (self.served) |b| {
            self.gpa.free(b);
            self.served = null;
        }
        const resolution = resolve(self.gpa, self.fetcher, self.mappings, uri);
        self.last = resolution;
        switch (resolution) {
            .verified => |v| {
                self.served = v.body;
                return .{ .body = v.body, .content_type = v.content_type };
            },
            // Every rejection serves the safe placeholder, NEVER the bytes: a
            // tampered gateway cannot get its bytes rendered for a CID.
            .unknown_cid, .hash_mismatch, .fetch_failed, .out_of_memory => return .{
                .body = rejection_body,
                .content_type = rejection_content_type,
            },
        }
    }
};

// ===========================================================================
// Tests (PURE ZIG, in the display-free `zig build test` gate): one CID
// fetch-verified AND served through the interception hook, on the SAME two
// seams the real backend uses — a `net.FakeFetcher` + a `renderer.FakeRenderer`,
// no network, no display. The live WebKitGTK `ipfs://` + secure-origin proof is
// the dedicated off-core-gate Xvfb step (ADR-0007).
// ===========================================================================

const testing = std.testing;

/// The one CID's bytes for the offline proof: a fixed blob standing in for an
/// `ipfs://`-served page. Its content address is the SHA-256 of exactly these
/// bytes (the multihash default for CIDv1 raw + SHA-256).
const cid_blob = "<html><head><title>ipfs page</title></head><body>hello from a verified CID</body></html>";
const cid_request_uri = "ipfs://bafyExampleCidForTheSpike";
const cid_gateway_url = "https://ipfs.example.gateway/ipfs/bafyExampleCidForTheSpike";

test "ipfs://: one CID is fetch-VERIFIED and served through the interception hook" {
    const gpa = testing.allocator;

    // The content address is the hash of the exact bytes (the IPFS subsystem
    // would decode this from the CID string; the spike is handed it directly).
    var digest_buf: [32]u8 = undefined;
    const address = net.ContentAddress.ofBytes(.sha256, cid_blob, &digest_buf);
    const mappings = [_]CidMapping{.{
        .request_uri = cid_request_uri,
        .source_url = cid_gateway_url,
        .address = address,
        .content_type = "text/html",
    }};

    // The untrusted gateway delivers the correct bytes.
    var fake_fetcher = net.FakeFetcher{ .body = cid_blob };
    var ipfs = IpfsSchemeHandler.init(gpa, fake_fetcher.fetcher(), &mappings);
    defer ipfs.deinit();

    // Register the handler through the REAL seam interface (the fake backend),
    // exactly as the WebKitGTK backend does, and declare the secure origin.
    var fr = renderer.FakeRenderer.init(gpa);
    defer fr.deinit();
    const r = fr.renderer();
    r.registerScheme(scheme, ipfs.handler());
    r.declareSchemeSecurity(scheme, secure_origin_traits);

    // A request for the CID is served THROUGH the hook with the verified bytes.
    const resp = fr.serveSchemeRequest(cid_request_uri).?;
    try testing.expectEqualStrings(cid_blob, resp.body);
    try testing.expectEqualStrings("text/html", resp.content_type);
    try testing.expect(ipfs.last.? == .verified);

    // And the seam recorded the secure-origin declaration for `ipfs`.
    try testing.expectEqualStrings("ipfs", fr.declared_scheme.?);
    try testing.expect(fr.declared_traits.?.secure);
}

test "ipfs://: a tampered gateway (hash mismatch) is REJECTED, not served as the CID" {
    const gpa = testing.allocator;

    var digest_buf: [32]u8 = undefined;
    const address = net.ContentAddress.ofBytes(.sha256, cid_blob, &digest_buf);
    const mappings = [_]CidMapping{.{
        .request_uri = cid_request_uri,
        .source_url = cid_gateway_url,
        .address = address,
        .content_type = "text/html",
    }};

    // The gateway delivers DIFFERENT bytes than the CID pins (a tampered/
    // corrupted transport): verify MUST reject, and the hook must serve the
    // safe placeholder, never the tampered bytes. The crux criterion.
    var tampered = net.FakeFetcher{ .body = "<html>NOT the bytes the CID pins</html>" };
    var ipfs = IpfsSchemeHandler.init(gpa, tampered.fetcher(), &mappings);
    defer ipfs.deinit();

    var fr = renderer.FakeRenderer.init(gpa);
    defer fr.deinit();
    const r = fr.renderer();
    r.registerScheme(scheme, ipfs.handler());

    const resp = fr.serveSchemeRequest(cid_request_uri).?;
    try testing.expect(ipfs.last.? == .hash_mismatch);
    try testing.expectEqualStrings(IpfsSchemeHandler.rejection_body, resp.body);
    // The tampered bytes were NEVER served.
    try testing.expect(!std.mem.eql(u8, resp.body, "<html>NOT the bytes the CID pins</html>"));
}

test "ipfs://: a transport failure is surfaced as a rejection, not a served body" {
    const gpa = testing.allocator;

    var digest_buf: [32]u8 = undefined;
    const address = net.ContentAddress.ofBytes(.sha256, cid_blob, &digest_buf);
    const mappings = [_]CidMapping{.{
        .request_uri = cid_request_uri,
        .source_url = cid_gateway_url,
        .address = address,
        .content_type = "text/html",
    }};

    var failing = net.FakeFetcher{ .body = "", .fail_with = error.FetchFailed };
    var ipfs = IpfsSchemeHandler.init(gpa, failing.fetcher(), &mappings);
    defer ipfs.deinit();

    const resolution = resolve(gpa, failing.fetcher(), &mappings, cid_request_uri);
    try testing.expect(resolution == .fetch_failed);

    // Through the handler it serves the safe placeholder.
    var fr = renderer.FakeRenderer.init(gpa);
    defer fr.deinit();
    const r = fr.renderer();
    r.registerScheme(scheme, ipfs.handler());
    const resp = fr.serveSchemeRequest(cid_request_uri).?;
    try testing.expect(ipfs.last.? == .fetch_failed);
    try testing.expectEqualStrings(IpfsSchemeHandler.rejection_body, resp.body);
}

test "ipfs://: a request for an unknown CID is not served as if verified" {
    const gpa = testing.allocator;

    var digest_buf: [32]u8 = undefined;
    const address = net.ContentAddress.ofBytes(.sha256, cid_blob, &digest_buf);
    const mappings = [_]CidMapping{.{
        .request_uri = cid_request_uri,
        .source_url = cid_gateway_url,
        .address = address,
        .content_type = "text/html",
    }};

    var fake_fetcher = net.FakeFetcher{ .body = cid_blob };
    const resolution = resolve(gpa, fake_fetcher.fetcher(), &mappings, "ipfs://someOtherCidNobodyMapped");
    try testing.expect(resolution == .unknown_cid);
}

test "ipfs://: the secure-origin traits are exactly secure+CORS (not local)" {
    // The declared traits are a stable, reviewable constant: ipfs:// is a secure,
    // CORS-enabled origin but NOT local (ADR-0015 decision 7).
    try testing.expect(secure_origin_traits.secure);
    try testing.expect(secure_origin_traits.cors);
    try testing.expect(!secure_origin_traits.local);
}
