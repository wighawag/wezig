//! The networking SEAM + the content-address verifier (spec
//! `explore-native-renderer`, story 2 + story 6, decision 2).
//!
//! This is the PURE-ZIG half of the networking de-risking spike: the boundary a
//! future `WezigRenderer` / `explore-web3-capabilities` extends, plus the
//! load-bearing THESIS logic — "content is trusted because it HASHES TO its
//! address, not because a server served it" (ADR-0011). It links NO system
//! library (std crypto only), so it lives in the `wezig` library `mod` and its
//! tests run in the display-free `zig build test` gate.
//!
//! The BOUND HTTP + TLS stack (libcurl) that satisfies this seam over the real
//! network — the "never write TLS" pick — lives in `src/networking_spike.zig`,
//! compiled + run ONLY by the dedicated `zig build networking-fetch-test` step
//! (its live `https://` leg needs `libcurl4-openssl-dev` + network egress, so it
//! stays OFF the core gate, mirroring the HarfBuzz / WebKitGTK provisioned legs;
//! ADR-0007). This file is what BOTH share: `networking_spike.zig`'s
//! `CurlFetcher` implements THIS `Fetcher`, and both the offline fake fetcher
//! (here) and the live curl fetcher (there) go through THIS `fetchVerified`, so
//! the plain fetch AND the verified content-addressed fetch ride ONE seam.
//!
//! ## Scope (narrowest real case — NOT the networking/IPFS subsystem)
//!
//! Two fetches, prove-and-record. The full networking layer (redirects beyond a
//! simple follow, caching, cookies, connection reuse, an HTTP/2 story) and the
//! full IPFS subsystem (real multibase/multihash CID decoding, gateway vs native
//! DHT resolution) are follow-on BUILDs scoped by
//! `native-renderer-findings-and-build-plan`, not this spike. A real `ipfs://`
//! address is a CID (a multihash + codec/version metadata, base-encoded);
//! decoding that grammar is out of scope. This spike models the LOAD-BEARING
//! half — the address IS the hash of the content, verify the bytes against it —
//! with a `ContentAddress` carrying a hash algorithm + expected digest. Swapping
//! the full CID parser in later changes only how a `ContentAddress` is
//! constructed from an `ipfs://…` string, NOT the `verify` contract below.

const std = @import("std");

// ===========================================================================
// The networking seam (the boundary `WezigRenderer` / web3 extend).
// ===========================================================================

/// A fetched resource: the raw bytes plus the HTTP status that produced them.
/// The caller owns `body` (freed with the allocator passed to `fetch`).
pub const Resource = struct {
    /// The response body bytes.
    body: []u8,
    /// The HTTP status code (e.g. 200). 0 for non-HTTP transports.
    status: u16,

    pub fn deinit(self: *Resource, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
        self.* = undefined;
    }
};

/// Errors any `Fetcher` may surface. Deliberately small for the spike: transport
/// failures (DNS/TCP/TLS/HTTP) collapse to `FetchFailed`; the content-address
/// path adds `HashMismatch` (below) — the REJECTION that is the thesis.
pub const FetchError = error{
    /// The transport failed to deliver a body.
    FetchFailed,
    /// Ran out of memory buffering the body.
    OutOfMemory,
};

/// The one interface the networking stack lives behind, in the same
/// `{ ptr, vtable }` shape as `PaintBackend` (ADR-0002) and `Renderer`
/// (ADR-0005): a concrete client is a runtime VALUE, so `CurlFetcher`
/// (`networking_spike.zig`) today and a future in-engine client tomorrow satisfy
/// it with no caller change. `fetchVerified` (below) is built ON this seam, so
/// the content-addressed path rides the SAME boundary as the plain fetch.
pub const Fetcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Fetch `url` and return its bytes + status. The caller owns the
        /// returned `Resource.body` (freed with `gpa`). REQUIRED.
        fetch: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, url: []const u8) FetchError!Resource,
    };

    /// Fetch a resource by URL through the bound backend. The one method the
    /// plain (compatibility-floor) path uses.
    pub fn fetch(self: Fetcher, gpa: std.mem.Allocator, url: []const u8) FetchError!Resource {
        return self.vtable.fetch(self.ptr, gpa, url);
    }
};

// ===========================================================================
// The content-address verifier (the thesis: verify, don't trust).
// ===========================================================================

/// The hash function a `ContentAddress` pins its digest under. Only the one the
/// spike needs (SHA-256, the multihash default for IPFS CIDv1 raw); the enum
/// exists so the IPFS subsystem can add SHA-512 / BLAKE3 later WITHOUT changing
/// the `verify` contract.
pub const HashAlgo = enum {
    sha256,

    /// Digest length in bytes.
    pub fn digestLen(self: HashAlgo) usize {
        return switch (self) {
            .sha256 => std.crypto.hash.sha2.Sha256.digest_length,
        };
    }
};

/// A content address: the LOAD-BEARING half of an `ipfs://` CID for this spike —
/// "the address IS the hash of the content". Carries the hash algorithm + the
/// expected digest; decoding a real CID string into one of these is the IPFS
/// subsystem's job (out of scope), but the VERIFY contract below is what that
/// subsystem reuses unchanged.
pub const ContentAddress = struct {
    algo: HashAlgo,
    /// The expected digest bytes (length == `algo.digestLen()`).
    digest: []const u8,

    /// The verification errors. `HashMismatch` is the rejection that makes a
    /// fetch VERIFIABLE rather than merely served.
    pub const Error = error{
        /// The fetched bytes did not hash to this address — REJECT (the thesis).
        HashMismatch,
        /// The address's digest length does not match its algorithm.
        MalformedAddress,
    };

    /// Compute the digest of `bytes` under this address's algorithm, writing it
    /// into `out` (>= `algo.digestLen()` long) and returning the written slice.
    pub fn hash(self: ContentAddress, bytes: []const u8, out: []u8) []u8 {
        switch (self.algo) {
            .sha256 => {
                const Sha256 = std.crypto.hash.sha2.Sha256;
                var digest: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(bytes, &digest, .{});
                @memcpy(out[0..Sha256.digest_length], &digest);
                return out[0..Sha256.digest_length];
            },
        }
    }

    /// Verify that `bytes` hash to this content address. Returns
    /// `error.HashMismatch` if they do NOT — that rejection is the thesis: the
    /// content is accepted because it hashes to its address, not because an
    /// origin served it (ADR-0011). Constant-time comparison so verification is
    /// not a timing oracle (cheap insurance; the digests are equal-length).
    pub fn verify(self: ContentAddress, bytes: []const u8) Error!void {
        if (self.digest.len != self.algo.digestLen()) return error.MalformedAddress;
        var buf: [64]u8 = undefined; // fits every `HashAlgo` digest length.
        const got = self.hash(bytes, &buf);
        // Only sha256 (32 bytes) exists today; the fixed-size compare matches it.
        if (!std.crypto.timing_safe.eql([32]u8, got[0..32].*, self.digest[0..32].*)) {
            return error.HashMismatch;
        }
    }

    /// Build a content address by hashing `bytes` under `algo`, storing the
    /// digest in caller-owned `digest_buf` (>= `algo.digestLen()` long, must
    /// outlive the address). A test/authoring convenience — the content address
    /// of a KNOWN resource — NOT how a real `ipfs://` CID is obtained (that is
    /// decoded from the URL).
    pub fn ofBytes(algo: HashAlgo, bytes: []const u8, digest_buf: []u8) ContentAddress {
        const self = ContentAddress{ .algo = algo, .digest = digest_buf[0..algo.digestLen()] };
        _ = self.hash(bytes, digest_buf); // writes the digest into digest_buf in place
        return self;
    }
};

/// The verified error set: any transport error OR a verification failure.
pub const VerifiedError = FetchError || ContentAddress.Error;

/// Fetch a content-addressed resource and VERIFY it, on the SAME `Fetcher` seam
/// as a plain fetch. The thesis end-to-end: fetch the bytes (through the bound
/// stack), then hash-check them against `address`; on mismatch the fetched
/// `Resource` is freed and `error.HashMismatch` is returned, so a caller can
/// NEVER observe unverified content-addressed bytes. `url` is where the bytes
/// come from (an `ipfs://` gateway, a mirror — transport is orthogonal to
/// verification); `address` is what they must hash to.
pub fn fetchVerified(
    fetcher: Fetcher,
    gpa: std.mem.Allocator,
    url: []const u8,
    address: ContentAddress,
) VerifiedError!Resource {
    var res = try fetcher.fetch(gpa, url);
    errdefer res.deinit(gpa);
    try address.verify(res.body);
    return res;
}

// ===========================================================================
// A fake, in-memory Fetcher (no network) — for the seam-contract + verify
// THESIS tests that run in the display-free `zig build test` gate.
// ===========================================================================

/// A `Fetcher` that returns caller-supplied bytes with NO network. It lets the
/// hash-verify THESIS (the load-bearing proof) run offline + deterministically
/// in the core gate, and lets a mismatch be forced by returning DIFFERENT bytes
/// than the address expects (a tampered/corrupted transport), proving `verify`
/// rejects — the crux acceptance criterion — with zero network. The live curl
/// fetcher (`networking_spike.zig`) is the same seam over the real network.
pub const FakeFetcher = struct {
    body: []const u8,
    status: u16 = 200,
    /// When set, `fetch` fails with this error instead of returning `body`.
    fail_with: ?FetchError = null,

    pub fn fetcher(self: *FakeFetcher) Fetcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Fetcher.VTable{ .fetch = fetch };

    fn fetch(ctx: *anyopaque, gpa: std.mem.Allocator, url: []const u8) FetchError!Resource {
        const self: *FakeFetcher = @ptrCast(@alignCast(ctx));
        _ = url;
        if (self.fail_with) |e| return e;
        const buf = try gpa.dupe(u8, self.body);
        return .{ .body = buf, .status = self.status };
    }
};

// ===========================================================================
// Tests (PURE ZIG, in the display-free `zig build test` gate): the seam
// contract + the hash-verify THESIS. The LIVE `https://` fetch through the
// bound libcurl+TLS stack (the compatibility floor) lives in
// `networking_spike.zig` behind the dedicated networking step (ADR-0007).
// ===========================================================================

const testing = std.testing;

/// The one content-addressed "resource" for the offline thesis proof: a fixed
/// byte string standing in for an `ipfs://`-served blob. Its content address is
/// the SHA-256 of exactly these bytes.
const ipfs_style_blob = "wezig: content is trusted because it hashes to its address, not because a server said so.\n";

test "content-addressed fetch is hash-VERIFIED and accepted when the bytes match (the thesis)" {
    const gpa = testing.allocator;

    var digest_buf: [32]u8 = undefined;
    const address = ContentAddress.ofBytes(.sha256, ipfs_style_blob, &digest_buf);

    var fake = FakeFetcher{ .body = ipfs_style_blob };
    var res = try fetchVerified(fake.fetcher(), gpa, "ipfs://bafyExampleCid", address);
    defer res.deinit(gpa);

    try testing.expectEqualSlices(u8, ipfs_style_blob, res.body);
    try testing.expectEqual(@as(u16, 200), res.status);
}

test "content-addressed fetch is REJECTED on a hash mismatch (tampered/corrupted bytes)" {
    const gpa = testing.allocator;

    var digest_buf: [32]u8 = undefined;
    const address = ContentAddress.ofBytes(.sha256, ipfs_style_blob, &digest_buf);

    // The transport delivers DIFFERENT bytes than the address pins (a tampered
    // gateway / a corrupted transfer): verify MUST reject. The crux criterion.
    var tampered = FakeFetcher{ .body = "wezig: these are NOT the bytes the address pins.\n" };
    try testing.expectError(
        error.HashMismatch,
        fetchVerified(tampered.fetcher(), gpa, "ipfs://bafyExampleCid", address),
    );
}

test "verify() accepts matching bytes and rejects any single-bit change" {
    var digest_buf: [32]u8 = undefined;
    const address = ContentAddress.ofBytes(.sha256, ipfs_style_blob, &digest_buf);

    try address.verify(ipfs_style_blob);

    const gpa = testing.allocator;
    const mutated = try gpa.dupe(u8, ipfs_style_blob);
    defer gpa.free(mutated);
    mutated[0] ^= 0x01;
    try testing.expectError(error.HashMismatch, address.verify(mutated));
}

test "a malformed content address (wrong digest length) is rejected, not silently accepted" {
    const short = ContentAddress{ .algo = .sha256, .digest = &[_]u8{ 0x00, 0x01 } };
    try testing.expectError(error.MalformedAddress, short.verify(ipfs_style_blob));
}

test "the Fetcher seam surfaces transport failures as FetchError" {
    const gpa = testing.allocator;
    var failing = FakeFetcher{ .body = "", .fail_with = error.FetchFailed };
    try testing.expectError(error.FetchFailed, failing.fetcher().fetch(gpa, "https://example.com/"));
}

test "a plain fetch returns bytes + status through the seam (compatibility-floor shape)" {
    const gpa = testing.allocator;
    var fake = FakeFetcher{ .body = "hello from a server", .status = 200 };
    var res = try fake.fetcher().fetch(gpa, "https://example.com/");
    defer res.deinit(gpa);
    try testing.expectEqualSlices(u8, "hello from a server", res.body);
    try testing.expectEqual(@as(u16, 200), res.status);
}
