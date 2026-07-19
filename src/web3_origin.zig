//! The content-addressed ORIGIN model + the per-ORIGIN wallet-link data model +
//! the seam's per-origin provider binding (spec `explore-web3-capabilities`,
//! stories 1/3/5; ADR-0015 decisions 1–3; ADR-0011). This is the TRUST-BOUNDARY
//! model everything web3 keys on — a DECISION/DATA-MODEL deliverable + the
//! confirmed seam-binding SHAPE, NOT the wallet or the storage subsystem.
//!
//! The design intent this realises is
//! `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`
//! (the author's published web3-UX thesis, ratified in-session 2026-07-19) and
//! it is pinned in ADR-0015. This module is the TYPED, TESTABLE expression of
//! that pinned model, pure Zig behind the `Renderer` seam (it imports only
//! `renderer.zig`, never a webview/GTK binding), so its tests run in the
//! display-free `zig build test` gate exactly like `renderer_swap.zig`.
//!
//! ## 1. The origin IS the content-addressed (IPFS) address (ADR-0015 decision 1)
//!
//! The security origin wezig binds ALL per-origin state to is the **content
//! hash** (the IPFS CID), NOT a DNS domain and NOT an ENS name. A
//! content-addressed origin is a STRONGER origin than a domain because the app
//! owner cannot change the content or logic without changing the origin (the
//! browser verifies the bytes hash to it — the `net.ContentAddress.verify`
//! contract). This is the concrete realisation of ADR-0011.
//!
//!   - **ENS is a mutable POINTER to a content origin.** A site reached via an
//!     ENS name has its ENS name resolve TO an IPFS origin; the origin wezig
//!     keys trust on is that IPFS origin, not the ENS name. So `ContentOrigin`
//!     here is ALWAYS the IPFS origin, even when the user typed an ENS name.
//!   - **ENS-repoint = a NEW origin the user may ACCEPT to carry data forward.**
//!     When an ENS name is repointed to a new hash (a new app version), that is
//!     a NEW origin. The browser offers the user an explicit "accept the new
//!     origin and continue with your existing data (localStorage, wallet link,
//!     …)" flow — a user-authorised origin-to-origin carry-forward, modelled
//!     here as `WalletLinkStore.acceptRepoint`.
//!
//! ## 2. ONE origin = ONE trust boundary; the wallet link is ORIGIN-keyed (decision 2)
//!
//! All per-origin state shares ONE boundary keyed by the content hash. In
//! particular the **wallet link is keyed by ORIGIN, not by tab**: two tabs on
//! the SAME content origin SHARE one wallet link (same accounts, grant, selected
//! chain); two tabs on DIFFERENT origins get INDEPENDENT links (each possibly a
//! different EVM chain). Tabs multiplex onto the origin they belong to. That is
//! exactly what `WalletLinkStore.linkFor` guarantees below (same-origin-shares /
//! cross-origin-isolates), and what the tests assert.
//!
//! ## 3. The seam's per-ORIGIN provider binding (decision 2/3; story 5)
//!
//! The page↔native provider channel is bound **per ORIGIN**, replacing today's
//! single hardcoded `"wezig"` channel. `OriginProviderBinding` expresses this
//! over the `Renderer` seam's script-message bridge: each concurrent origin gets
//! its OWN named channel (the channel name IS the content origin), so a message
//! arriving on the bridge is routed to that origin's wallet link. Two tabs on
//! the same origin share the one channel/link; different origins are independent.
//! This is expressed AT the seam (it drives `setScriptMessageHandler` /
//! `evaluateScript`) so a `WezigRenderer` reproduces it by delivering the message
//! under the origin's channel `name` — see the seam-sufficiency note at the
//! bottom of this file for the ONE backend insufficiency this surfaces (the
//! WebKitGTK backend must recover the channel name it hardcodes today).
//!
//! This is EXPLORATION: it pins the model + the binding SHAPE and proves them
//! headlessly. It does NOT build the wallet (custody/signing/EIP-6963 —
//! `spike-wallet-broker-eip6963-provider`), the storage subsystem, the
//! encryption, or the multi-chain switching UX; a `WalletLink` here is an inert
//! data record, never real custody.

const std = @import("std");
const renderer_mod = @import("renderer.zig");

const Renderer = renderer_mod.Renderer;
const ScriptMessageCallback = renderer_mod.ScriptMessageCallback;

/// A CONTENT-ADDRESSED origin: the IPFS content address (CID) a document is
/// served from, the STRONGEST origin (ADR-0015 decision 1, ADR-0011). This is
/// the SINGLE key for all per-origin state — localStorage, wallet link,
/// encryption scope, signature origin-binding — they are the SAME boundary.
///
/// It wraps the origin STRING (the CID text as it appears in the `ipfs://`
/// authority). Decoding a real CID grammar is the IPFS subsystem's job (out of
/// scope, like `net.ContentAddress`); here the origin is compared as its stable
/// string form. An ENS name is NOT a `ContentOrigin` — it is a mutable pointer
/// that resolves TO one, so callers convert an ENS name to the IPFS origin it
/// currently resolves to BEFORE constructing this (`fromEns` documents that
/// direction; the resolution itself is the follow-on build's job).
pub const ContentOrigin = struct {
    /// The content address text (the CID as it appears in the `ipfs://`
    /// authority). Borrowed — the owner is whoever constructed it (the store
    /// owns its keys); compared by value via `eql`.
    cid: []const u8,

    pub fn init(cid: []const u8) ContentOrigin {
        return .{ .cid = cid };
    }

    /// Two content origins are the same trust boundary iff their content
    /// addresses are byte-identical. Content addresses are case-SENSITIVE (a CID
    /// is a base-encoded multihash, not a hostname), unlike a DNS domain.
    pub fn eql(self: ContentOrigin, other: ContentOrigin) bool {
        return std.mem.eql(u8, self.cid, other.cid);
    }

    /// DOCUMENTS the ENS→IPFS direction (ADR-0015 decision 1): the origin wezig
    /// keys trust on is the IPFS origin an ENS name RESOLVES TO, never the ENS
    /// name itself. The resolution (`name.eth` → a CID) is a follow-on build's
    /// job; this constructor takes the ALREADY-RESOLVED content address so the
    /// call site records that an ENS entry point still keys on the content
    /// origin. It is deliberately identical to `init` — the point is the NAME at
    /// the call site, making "ENS is a pointer TO this origin" explicit.
    pub fn fromEns(resolved_cid: []const u8) ContentOrigin {
        return init(resolved_cid);
    }
};

/// A selected EVM chain, identified by its chain id (EIP-155). Per-origin: two
/// different origins may each hold a DIFFERENT chain (ADR-0015 decision 2). This
/// is an inert selector, NOT chain switching UX (out of scope).
pub const ChainId = u64;

/// Ethereum mainnet — the mainnet-first default of ADR-0015 decision 4, used as
/// the initial selected chain of a fresh link.
pub const mainnet_chain_id: ChainId = 1;

/// The PER-ORIGIN wallet-link DATA MODEL (ADR-0015 decision 2): the state a
/// content origin has with the wallet — which accounts it was granted, whether
/// a permission grant is currently in effect, and which EVM chain it selected.
/// Keyed by `ContentOrigin` in the store below, so two tabs on the same origin
/// SHARE one of these and two tabs on different origins get INDEPENDENT ones.
///
/// This is a DATA RECORD only. It holds ACCOUNT ADDRESSES the origin may see
/// (public, disclosure-gated) — NEVER key material (custody + signing live in
/// the out-of-page broker, `spike-wallet-broker-eip6963-provider`; the page and
/// this model only ever hold the ability to REQUEST). Building the grant UX, the
/// signing flow, and multi-chain switching is out of scope.
pub const WalletLink = struct {
    /// Whether the origin currently holds a permission grant (the user approved
    /// `eth_requestAccounts` for it). False = no grant (the fresh state).
    granted: bool = false,
    /// The account addresses disclosed to this origin (owned, lowercased hex
    /// strings incl. the `0x`). Empty until a grant is made. Public addresses
    /// only — never keys.
    accounts: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The EVM chain this origin currently has selected (EIP-155 chain id).
    /// Per-origin, so a different origin may hold a different chain. Defaults to
    /// mainnet (ADR-0015 decision 4, mainnet-first).
    chain_id: ChainId = mainnet_chain_id,

    pub fn deinit(self: *WalletLink, gpa: std.mem.Allocator) void {
        for (self.accounts.items) |a| gpa.free(a);
        self.accounts.deinit(gpa);
    }

    /// Record a permission grant of `accounts` to this origin (the result of an
    /// approved `eth_requestAccounts`). Replaces any prior account set and flips
    /// `granted`. Addresses are stored lowercase (EVM addresses compare
    /// case-insensitively; EIP-55 checksum display is a UX concern out of scope).
    /// The signing/approval that PRODUCES a grant is the broker's job; this only
    /// records the resulting disclosure state on the link.
    pub fn grant(self: *WalletLink, gpa: std.mem.Allocator, accounts: []const []const u8) !void {
        for (self.accounts.items) |a| gpa.free(a);
        self.accounts.clearRetainingCapacity();
        for (accounts) |a| {
            const owned = try gpa.alloc(u8, a.len);
            for (a, 0..) |ch, i| owned[i] = std.ascii.toLower(ch);
            errdefer gpa.free(owned);
            try self.accounts.append(gpa, owned);
        }
        self.granted = true;
    }

    /// Revoke the grant: drop the disclosed accounts and clear `granted` (the
    /// origin reverts to no-grant). The selected chain is left as-is (a
    /// preference), matching "revoke the disclosure, not the whole record".
    pub fn revoke(self: *WalletLink, gpa: std.mem.Allocator) void {
        for (self.accounts.items) |a| gpa.free(a);
        self.accounts.clearRetainingCapacity();
        self.granted = false;
    }

    /// A deep, owned copy of this link under `gpa` — the mechanism behind the
    /// ENS-repoint carry-forward (the NEW origin starts with a COPY of the old
    /// origin's link, then evolves independently).
    fn clone(self: *const WalletLink, gpa: std.mem.Allocator) !WalletLink {
        var out = WalletLink{ .granted = self.granted, .chain_id = self.chain_id };
        errdefer out.deinit(gpa);
        for (self.accounts.items) |a| {
            const owned = try gpa.dupe(u8, a);
            errdefer gpa.free(owned);
            try out.accounts.append(gpa, owned);
        }
        return out;
    }
};

/// The per-ORIGIN wallet-link STORE: the map from `ContentOrigin` → `WalletLink`
/// that makes the wallet link ORIGIN-keyed, not tab-keyed (ADR-0015 decision 2).
/// This is the schema + the lookup the provider binding consults. It owns its
/// keys (the origin CID strings) and the links.
///
/// The SHARING GUARANTEE it enforces (the whole point):
///   - `linkFor(origin)` returns the SAME link for the same content origin, so
///     two tabs on that origin SHARE it (same accounts / grant / chain);
///   - two DIFFERENT origins get DIFFERENT links, independent (each may hold a
///     different chain), so cross-origin state never leaks.
///
/// It is inert data; there is no automatic grant anywhere — an origin has a
/// granted link only because a grant was recorded on it (by the broker flow).
///
/// ## DECISION: this store is IN-MEMORY only (no persistence in this task)
///
/// CHOICE: `WalletLinkStore` keeps links in memory for the process lifetime and
/// does NOT persist them to disk (unlike `renderer_swap.DomainAllowList`, which
/// does persist). WHY: persisting the wallet link IS the storage subsystem, and
/// this task's spec (`explore-web3-capabilities`) explicitly scopes OUT "the
/// storage subsystem, the encryption, [and] the multi-chain switching UX" — a
/// persisted wallet link also entails the encryption-at-rest custody boundary
/// (ADR-0015 decision 3), which is a follow-on BUILD, not this exploration. So
/// this task pins the SCHEMA + the sharing/isolation semantics + the seam
/// binding; where a link lives across sessions (and how it is encrypted) is the
/// wallet build's decision. TOUCHES: the follow-on wallet BUILD spec owns
/// persistence + encryption; `spike-wallet-broker-eip6963-provider` records a
/// GRANT onto a link here but likewise persists nothing. ALTERNATIVE CONSIDERED:
/// mirror `DomainAllowList`'s plain-text file persistence — REJECTED: a wallet
/// link is security-critical state whose at-rest form must be the vetted
/// encrypted-custody path (ADR-0015 decision 3), never a plain-text file, so
/// adding persistence here would either pre-empt that decision or ship an
/// insecure placeholder. (Because nothing persists, the tests need no temp-dir
/// isolation — there is no shared/global location to protect.)
pub const WalletLinkStore = struct {
    gpa: std.mem.Allocator,
    /// origin CID (owned) -> the shared link for that origin.
    links: std.StringHashMapUnmanaged(WalletLink) = .empty,

    pub fn init(gpa: std.mem.Allocator) WalletLinkStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *WalletLinkStore) void {
        var it = self.links.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.links.deinit(self.gpa);
    }

    /// The shared `WalletLink` for `origin`, CREATING a fresh one (no grant,
    /// mainnet) on first touch. Returns a POINTER into the store, so all callers
    /// for the same origin observe + mutate the SAME link — that is how two tabs
    /// on one origin share, and two origins stay independent. The returned
    /// pointer is stable until the entry is removed (`forget`/`deinit`).
    pub fn linkFor(self: *WalletLinkStore, origin: ContentOrigin) !*WalletLink {
        const gop = try self.links.getOrPut(self.gpa, origin.cid);
        if (!gop.found_existing) {
            // getOrPut stored the borrowed slice as the key; own a stable copy.
            const owned = self.gpa.dupe(u8, origin.cid) catch |err| {
                _ = self.links.remove(origin.cid);
                return err;
            };
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    /// The existing link for `origin`, or null if the origin has never been
    /// touched (a read that does NOT create). Lets a caller ask "does this origin
    /// already have a link?" without minting one.
    pub fn existing(self: *WalletLinkStore, origin: ContentOrigin) ?*WalletLink {
        return self.links.getPtr(origin.cid);
    }

    /// Drop the link for `origin` entirely (e.g. the user cleared this origin's
    /// data). A no-op if the origin has no link.
    pub fn forget(self: *WalletLinkStore, origin: ContentOrigin) void {
        if (self.links.fetchRemove(origin.cid)) |kv| {
            self.gpa.free(kv.key);
            var link = kv.value;
            link.deinit(self.gpa);
        }
    }

    /// The ENS-REPOINT carry-forward (ADR-0015 decision 1): the user ACCEPTS a
    /// NEW content origin (`to`, e.g. the new hash an ENS name now points at) and
    /// carries the PREVIOUS origin's data forward. Concretely: copy `from`'s
    /// wallet link into `to` so the new app version continues with the existing
    /// grant/accounts/chain, THEN the two origins evolve INDEPENDENTLY (the copy
    /// is a snapshot, not an alias — mutating one never touches the other).
    ///
    /// This is a USER-AUTHORISED action: the caller invokes it only after the
    /// user accepted the new origin (this model does not decide policy, it
    /// performs the carry-forward). It is a NO-OP that still mints a fresh `to`
    /// link if `from` has none (nothing to carry). If `to` already had a link, it
    /// is REPLACED by the carried-forward copy (accepting the repoint supersedes
    /// any prior state under the new origin). Returns the `to` link pointer.
    pub fn acceptRepoint(self: *WalletLinkStore, from: ContentOrigin, to: ContentOrigin) !*WalletLink {
        // Same origin is not a repoint; just return its link.
        if (from.eql(to)) return self.linkFor(to);

        const dst = try self.linkFor(to);
        if (self.existing(from)) |src| {
            var carried = try src.clone(self.gpa);
            errdefer carried.deinit(self.gpa);
            dst.deinit(self.gpa);
            dst.* = carried;
        }
        return dst;
    }

    /// The number of distinct origins with a link (each an independent trust
    /// boundary). For tests + diagnostics.
    pub fn originCount(self: *const WalletLinkStore) usize {
        return self.links.count();
    }
};

/// The channel-name convention for the per-origin provider binding: the
/// page↔native script-message channel for an origin is that origin's content
/// address, prefixed so it is unambiguously a wezig provider channel and never
/// collides with a non-provider channel. This is what REPLACES the single
/// hardcoded `"wezig"` channel — one channel PER ORIGIN.
pub const channel_prefix = "wezig:";

/// The seam's PER-ORIGIN provider binding (ADR-0015 decisions 2/3; story 5). It
/// expresses the per-origin channel over the `Renderer` seam's script-message
/// bridge and routes each page→native message to the RIGHT origin's wallet link.
///
/// A `WezigRenderer` reproduces it identically: it is driven ENTIRELY through the
/// seam (`setScriptMessageHandler` to open an origin's channel, the seam's
/// `ScriptMessageCallback.name` to identify which origin a message came from),
/// with no webview-specific call. The binding owns NO wallet state — it consults
/// the shared `WalletLinkStore`, so same-origin tabs share and cross-origin
/// isolate falls straight out of the store.
pub const OriginProviderBinding = struct {
    gpa: std.mem.Allocator,
    renderer: Renderer,
    store: *WalletLinkStore,
    /// The channel name (owned, `channel_prefix ++ cid`) registered for each
    /// bound origin, so re-binding the same origin is idempotent and a message's
    /// channel name maps back to its origin.
    channels: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: std.mem.Allocator, renderer: Renderer, store: *WalletLinkStore) OriginProviderBinding {
        return .{ .gpa = gpa, .renderer = renderer, .store = store };
    }

    pub fn deinit(self: *OriginProviderBinding) void {
        var it = self.channels.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.channels.deinit(self.gpa);
    }

    /// The script-message channel NAME for `origin` (`channel_prefix ++ cid`),
    /// written NUL-terminated into caller-owned `buf` for the seam's
    /// `[*:0]const u8` argument. Returns the slice (sans the NUL). The inverse of
    /// `originForChannel`.
    pub fn channelName(origin: ContentOrigin, buf: []u8) ![:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}{s}", .{ channel_prefix, origin.cid });
    }

    /// The `ContentOrigin` a channel `name` belongs to, or null if `name` is not
    /// a wezig provider channel (wrong prefix). The inverse of `channelName`; the
    /// message-routing entry point uses it to find the origin a page→native
    /// message came in on.
    pub fn originForChannel(name: []const u8) ?ContentOrigin {
        if (!std.mem.startsWith(u8, name, channel_prefix)) return null;
        return ContentOrigin.init(name[channel_prefix.len..]);
    }

    /// BIND the provider for `origin`: open the origin's OWN page→native channel
    /// on the seam so this origin's page can post provider requests to native,
    /// each routed to THIS origin's wallet link. Idempotent per origin (binding
    /// again just re-registers the same channel). This is the per-ORIGIN
    /// replacement for the single `"wezig"` channel: concurrent origins each get
    /// an independent binding.
    ///
    /// The message handler `cb` is registered by the CALLER (typically the broker
    /// spike's provider handler) — this binding owns the CHANNEL↔origin mapping,
    /// not the request semantics. Ensures the origin has a link in the store.
    pub fn bind(self: *OriginProviderBinding, origin: ContentOrigin, cb: ScriptMessageCallback) !void {
        var buf: [512]u8 = undefined;
        const name = try channelName(origin, &buf);
        const gop = try self.channels.getOrPut(self.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
        }
        // Ensure this origin has a (possibly fresh) link to consult.
        _ = try self.store.linkFor(origin);
        self.renderer.setScriptMessageHandler(name.ptr, cb);
    }

    /// Whether `origin` is currently bound (has an open channel).
    pub fn isBound(self: *const OriginProviderBinding, origin: ContentOrigin) bool {
        var buf: [512]u8 = undefined;
        const name = channelName(origin, &buf) catch return false;
        return self.channels.contains(name);
    }

    /// Route a page→native message that arrived on channel `name`: resolve the
    /// origin the channel belongs to and return that origin's SHARED wallet link
    /// (the one a provider request would read/mutate). Returns null if `name` is
    /// not a wezig provider channel. This is HOW the provider binding CONSULTS
    /// the per-origin model — every message resolves to exactly one origin's
    /// link, and two tabs on the same origin resolve to the SAME link.
    pub fn linkForChannel(self: *OriginProviderBinding, name: []const u8) !?*WalletLink {
        const origin = originForChannel(name) orelse return null;
        return try self.store.linkFor(origin);
    }
};

// ===========================================================================
// Seam-sufficiency note (spec story 5 — CONFIRM + record insufficiency).
//
// This module CONFIRMS the pinned `Renderer` seam (ADR-0005/0006) carries the
// per-origin provider binding across BOTH backends: `OriginProviderBinding`
// drives ONLY seam methods (`setScriptMessageHandler` with a per-origin channel
// name, and the seam's `ScriptMessageCallback.name` to identify the origin), so
// a `WezigRenderer` reproduces it with no webview-specific call. The tests below
// prove the routing headlessly through `FakeRenderer`.
//
// The ONE recorded INSUFFICIENCY (feedback to the backend, per the drift note
// `work/notes/observations/review-nits-seam-script-bridge-and-interception-2026-07-15.md`
// and `docs/shell-exploration-findings.md` §1): the WebKitGTK backend
// (`system_webview_renderer.zig` `onScriptMessage`) HARDCODES the channel name
// `"wezig"` because the `JSCValue` it receives does not carry the channel name.
// For the per-ORIGIN binding to work on that backend, the backend must recover
// the channel name it registered under (connect the per-detail
// `script-message-received::<name>` signal so `<name>` is recoverable) and pass
// it as `ScriptMessageCallback.name`, instead of the hardcoded literal. The seam
// INTERFACE already carries `name` (it needs no change); this is a backend-impl
// fix the wallet build must land before multiple concurrent origins work on the
// webview backend. A single-provider spike
// (`spike-wallet-broker-eip6963-provider`) is unaffected (it uses one channel).
//
// The OTHER confirmed seam extension for web3 (scheme SECURITY TRAITS for
// `ipfs://` secure origins, ADR-0015 decision 7) is owned by
// `spike-ipfs-secure-origin-service-worker`, not this task.
// ===========================================================================

// ---------------------------------------------------------------------------
// Tests: the origin model, the per-origin wallet-link store (same-origin-shares
// / cross-origin-isolates), the ENS-repoint carry-forward, and the seam
// per-origin binding routing — all headlessly (no webview, no display) in
// `zig build test`. The binding drives a `FakeRenderer`, so we assert which
// channel a handler was registered under and that a message routes to the right
// origin's link.
// ---------------------------------------------------------------------------

const testing = std.testing;
const FakeRenderer = renderer_mod.FakeRenderer;

test "ContentOrigin: the IPFS content address is the origin; ENS resolves TO it" {
    const a = ContentOrigin.init("bafyA");
    const b = ContentOrigin.init("bafyA");
    const c = ContentOrigin.init("bafyB");
    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));

    // ENS is a mutable POINTER: two ENS names resolving to the same CID are the
    // SAME origin; the CID, not the name, is what wezig keys trust on.
    const via_ens = ContentOrigin.fromEns("bafyA");
    try testing.expect(via_ens.eql(a));

    // Content addresses are case-SENSITIVE (a CID is not a hostname).
    try testing.expect(!ContentOrigin.init("bafyA").eql(ContentOrigin.init("bafya")));
}

test "WalletLink: grant records accounts + flips granted; revoke clears disclosure" {
    var link = WalletLink{};
    defer link.deinit(testing.allocator);

    try testing.expect(!link.granted);
    try testing.expectEqual(mainnet_chain_id, link.chain_id);

    try link.grant(testing.allocator, &.{ "0xAbC", "0xDeF" });
    try testing.expect(link.granted);
    try testing.expectEqual(@as(usize, 2), link.accounts.items.len);
    // Stored lowercase.
    try testing.expectEqualStrings("0xabc", link.accounts.items[0]);

    link.revoke(testing.allocator);
    try testing.expect(!link.granted);
    try testing.expectEqual(@as(usize, 0), link.accounts.items.len);
    // The selected chain is a preference; revoke leaves it.
    try testing.expectEqual(mainnet_chain_id, link.chain_id);
}

test "WalletLinkStore: same-origin tabs SHARE one link (the origin, not the tab, is the key)" {
    var store = WalletLinkStore.init(testing.allocator);
    defer store.deinit();

    const origin = ContentOrigin.init("bafySame");

    // Two independent lookups for the SAME origin (stand-ins for two tabs) must
    // return the SAME link — a grant made through one is seen through the other.
    const tab1 = try store.linkFor(origin);
    try tab1.grant(testing.allocator, &.{"0x1111"});
    tab1.chain_id = 10; // Optimism.

    const tab2 = try store.linkFor(origin);
    try testing.expectEqual(tab1, tab2); // same pointer -> shared state.
    try testing.expect(tab2.granted);
    try testing.expectEqual(@as(usize, 1), tab2.accounts.items.len);
    try testing.expectEqualStrings("0x1111", tab2.accounts.items[0]);
    try testing.expectEqual(@as(ChainId, 10), tab2.chain_id);

    // Still exactly one origin -> one trust boundary.
    try testing.expectEqual(@as(usize, 1), store.originCount());
}

test "WalletLinkStore: different origins are INDEPENDENT (each may hold a different chain)" {
    var store = WalletLinkStore.init(testing.allocator);
    defer store.deinit();

    const app_a = ContentOrigin.init("bafyAppA");
    const app_b = ContentOrigin.init("bafyAppB");

    const link_a = try store.linkFor(app_a);
    try link_a.grant(testing.allocator, &.{"0xaaaa"});
    link_a.chain_id = 1; // mainnet

    const link_b = try store.linkFor(app_b);
    try link_b.grant(testing.allocator, &.{"0xbbbb"});
    link_b.chain_id = 137; // Polygon

    // Cross-origin isolation: A's link never sees B's accounts or chain.
    try testing.expect(link_a != link_b);
    try testing.expectEqualStrings("0xaaaa", link_a.accounts.items[0]);
    try testing.expectEqualStrings("0xbbbb", link_b.accounts.items[0]);
    try testing.expectEqual(@as(ChainId, 1), link_a.chain_id);
    try testing.expectEqual(@as(ChainId, 137), link_b.chain_id);
    try testing.expectEqual(@as(usize, 2), store.originCount());
}

test "WalletLinkStore: existing/forget do not mint or leak" {
    var store = WalletLinkStore.init(testing.allocator);
    defer store.deinit();

    const origin = ContentOrigin.init("bafyForget");
    // existing() must NOT create.
    try testing.expect(store.existing(origin) == null);
    try testing.expectEqual(@as(usize, 0), store.originCount());

    _ = try store.linkFor(origin);
    try testing.expect(store.existing(origin) != null);
    try testing.expectEqual(@as(usize, 1), store.originCount());

    store.forget(origin);
    try testing.expect(store.existing(origin) == null);
    try testing.expectEqual(@as(usize, 0), store.originCount());
    // Forgetting a missing origin is a no-op.
    store.forget(origin);
}

test "WalletLinkStore.acceptRepoint: ENS-repoint carries data forward, then origins diverge" {
    var store = WalletLinkStore.init(testing.allocator);
    defer store.deinit();

    const old_origin = ContentOrigin.init("bafyV1"); // app v1
    const new_origin = ContentOrigin.init("bafyV2"); // ENS repointed to v2

    // The user had granted the old origin on Polygon.
    const old_link = try store.linkFor(old_origin);
    try old_link.grant(testing.allocator, &.{"0xuser"});
    old_link.chain_id = 137;

    // User ACCEPTS the new origin: its data is carried forward.
    const new_link = try store.acceptRepoint(old_origin, new_origin);
    try testing.expect(new_link.granted);
    try testing.expectEqualStrings("0xuser", new_link.accounts.items[0]);
    try testing.expectEqual(@as(ChainId, 137), new_link.chain_id);

    // The carry-forward is a SNAPSHOT, not an alias: the two origins now evolve
    // INDEPENDENTLY (mutating the new origin never touches the old).
    try testing.expect(new_link != store.existing(old_origin).?);
    new_link.chain_id = 8453; // the new version switches to Base.
    try testing.expectEqual(@as(ChainId, 137), store.existing(old_origin).?.chain_id);

    // Repoint from an origin with no link just mints a fresh target link.
    const fresh_target = ContentOrigin.init("bafyFresh");
    const carried = try store.acceptRepoint(ContentOrigin.init("bafyNeverSeen"), fresh_target);
    try testing.expect(!carried.granted);
}

test "OriginProviderBinding: channel name round-trips to/from the content origin" {
    const origin = ContentOrigin.init("bafyChan");
    var buf: [512]u8 = undefined;
    const name = try OriginProviderBinding.channelName(origin, &buf);
    try testing.expectEqualStrings("wezig:bafyChan", name);

    const back = OriginProviderBinding.originForChannel(name).?;
    try testing.expect(back.eql(origin));

    // A non-provider channel name resolves to no origin.
    try testing.expect(OriginProviderBinding.originForChannel("some-other-channel") == null);
}

test "OriginProviderBinding: binds a per-origin channel and routes a message to that origin's link" {
    var fr = FakeRenderer.init(testing.allocator);
    defer fr.deinit();
    var store = WalletLinkStore.init(testing.allocator);
    defer store.deinit();
    var binding = OriginProviderBinding.init(testing.allocator, fr.renderer(), &store);
    defer binding.deinit();

    const origin = ContentOrigin.init("bafyBind");

    // A no-op message handler (the caller — the broker spike — owns request
    // semantics; this test proves the CHANNEL wiring, not request handling).
    const noop = struct {
        fn onMessage(_: *anyopaque, _: []const u8, _: []const u8) void {}
    };
    var sink: u8 = 0;
    try testing.expect(!binding.isBound(origin));
    try binding.bind(origin, .{ .ctx = &sink, .onMessage = noop.onMessage });
    try testing.expect(binding.isBound(origin));

    // The seam registered the handler under the ORIGIN's channel, not "wezig".
    try testing.expectEqualStrings("wezig:bafyBind", fr.msg_name.?);

    // A message arriving on that channel routes to THIS origin's shared link.
    const routed = (try binding.linkForChannel("wezig:bafyBind")).?;
    const direct = try store.linkFor(origin);
    try testing.expectEqual(routed, direct); // same link the store holds.

    // A message on a non-provider channel routes nowhere.
    try testing.expect((try binding.linkForChannel("not-a-provider")) == null);
}

test "OriginProviderBinding: concurrent origins get independent bindings (cross-origin isolation)" {
    var fr = FakeRenderer.init(testing.allocator);
    defer fr.deinit();
    var store = WalletLinkStore.init(testing.allocator);
    defer store.deinit();
    var binding = OriginProviderBinding.init(testing.allocator, fr.renderer(), &store);
    defer binding.deinit();

    const noop = struct {
        fn onMessage(_: *anyopaque, _: []const u8, _: []const u8) void {}
    };
    var sink: u8 = 0;

    const app_a = ContentOrigin.init("bafyConcA");
    const app_b = ContentOrigin.init("bafyConcB");
    try binding.bind(app_a, .{ .ctx = &sink, .onMessage = noop.onMessage });
    try binding.bind(app_b, .{ .ctx = &sink, .onMessage = noop.onMessage });

    try testing.expect(binding.isBound(app_a));
    try testing.expect(binding.isBound(app_b));

    // Each origin's channel routes to its OWN link — different links.
    const link_a = (try binding.linkForChannel("wezig:bafyConcA")).?;
    const link_b = (try binding.linkForChannel("wezig:bafyConcB")).?;
    try testing.expect(link_a != link_b);

    // Binding the SAME origin again is idempotent (no second channel).
    try binding.bind(app_a, .{ .ctx = &sink, .onMessage = noop.onMessage });
    try testing.expectEqual(@as(u32, 2), binding.channels.count());
}
