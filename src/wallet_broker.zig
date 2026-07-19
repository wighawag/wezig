//! The wallet BROKER boundary + the page-facing EIP-6963 provider, spiked on the
//! NARROWEST real case: ONE origin-bound `eth_requestAccounts` round-trip
//! (spec `explore-web3-capabilities`, story 1; ADR-0015 decisions 4 + 5;
//! ADR-0011). This is a de-risking spike of the SECURITY BOUNDARY + the provider
//! SHAPE — NOT the wallet. It stores/uses NO real private key.
//!
//! ## What this module is (and is NOT)
//!
//! It pins the two boundary halves the security-critical wallet build starts
//! from, expressed PURELY at the `Renderer` seam so they survive the
//! `WezigRenderer` swap (ADR-0005/0006), and proves them headlessly in the
//! display-free `zig build test` gate with a FAKE bridge (`FakeRenderer`) + a
//! FAKE broker:
//!
//!   1. **The broker boundary (ADR-0015 decision 5).** Key custody + the
//!      "decide + return accounts" step live behind the `Broker` seam — a
//!      `{ ptr, vtable }` value exactly like `Renderer`/`net.Fetcher`. The
//!      page-world provider only REQUESTS over the boundary (a request STRING in,
//!      a response STRING out); it holds NO reference to key material. The
//!      boundary is a message boundary, so a real broker can sit in its OWN
//!      process/sandbox behind the SAME seam (the live proof —
//!      `wallet_broker_spike.zig` — does exactly that over a child process), and
//!      a single-process `WezigRenderer` still routes signing to the out-of-page
//!      broker. **The page never receives key material — only a request/response.**
//!   2. **EIP-6963 discovery (ADR-0015 decision 4).** The provider is advertised
//!      via EIP-6963 (`eip6963:announceProvider` / `eip6963:requestProvider`),
//!      NOT a bare `window.ethereum`, so it coexists with extension wallets and
//!      is discovered per origin. The injected page-world script + the announce
//!      payload (`Eip6963ProviderInfo`) are settled here.
//!
//! The request is ORIGIN-BOUND (ADR-0015 decision 2): the provider stamps the
//! requesting content origin onto every broker request, the broker echoes it,
//! and the resulting grant is recorded on THAT origin's `web3_origin.WalletLink`
//! (shared per origin, so two tabs on one origin share the grant; two origins
//! are independent). The per-origin channel binding itself is
//! `web3_origin.OriginProviderBinding` (the `pin-content-origin-and-wallet-link-model`
//! task); this module drives it for the single-provider spike.
//!
//! What is DELIBERATELY out of scope (the wallet BUILD spec owns it): real
//! custody (OS keychain / encrypted-at-rest / hardware — ADR-0015 decision 3),
//! signing/state-changing methods + their approval UX, multi-chain switching,
//! and persistence. The `eth_requestAccounts` here auto-grants a throwaway test
//! account WITHOUT an approval prompt — proving the boundary + the message
//! shape, not the (out-of-page) approval policy.
//!
//! ## DECISION: the broker IPC shape is line-delimited JSON request/response
//!
//! CHOICE: the provider↔broker boundary carries ONE JSON object per request and
//! ONE per response, each a single line (newline-terminated on the wire). The
//! request is `{ "id", "origin", "method", "params" }`; the response is either
//! `{ "id", "result" }` or `{ "id", "error": { "code", "message" } }` (the
//! EIP-1193 shape a provider forwards to the page). WHY: JSON is exactly what an
//! EIP-1193 `request({method, params})` already is, so the provider forwards the
//! page's call almost verbatim (adding only the trusted `origin` stamp), and
//! line-delimiting makes the SAME bytes frame trivially over a real pipe/socket
//! to an out-of-process broker (the live proof) with no length-prefix framing to
//! design. TOUCHES: the wallet BUILD spec inherits this envelope (it adds signing
//! methods + an approval field, and MAY promote it to JSON-RPC 2.0 proper);
//! `wallet_broker_spike.zig` frames these same lines over a child process's
//! stdio. ALTERNATIVE CONSIDERED: a packed binary/length-prefixed struct —
//! REJECTED for a spike: it buys nothing over newline-framed JSON here and
//! diverges from the EIP-1193 JSON the page speaks, adding a hand-rolled codec to
//! the security-critical boundary the build must audit. The `origin` field is the
//! load-bearing addition over raw EIP-1193: it is stamped by TRUSTED native (the
//! provider), never by the page, which is what makes the request origin-bound.

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const web3_origin = @import("web3_origin.zig");

const Renderer = renderer_mod.Renderer;
const ScriptMessageCallback = renderer_mod.ScriptMessageCallback;
const ContentOrigin = web3_origin.ContentOrigin;
const WalletLink = web3_origin.WalletLink;
const WalletLinkStore = web3_origin.WalletLinkStore;
const OriginProviderBinding = web3_origin.OriginProviderBinding;

/// The EIP-6963 announce payload (`detail.info`; ADR-0015 decision 4). This is
/// the wallet's self-description a page discovers via `eip6963:announceProvider`
/// — the exact four fields EIP-6963 mandates. It carries NO key material and NO
/// capability: it only lets a page RECOGNISE and select wezig's provider among
/// several (so wezig coexists with extension wallets). The provider INSTANCE the
/// page then calls (`detail.provider.request(...)`) is the injected page-world
/// object that posts over the script bridge — see `announce_script_template`.
pub const Eip6963ProviderInfo = struct {
    /// A per-announcement UUIDv4 (EIP-6963 requires it be regenerated each
    /// announce; here a fixed spike value — the build wires a real generator).
    uuid: []const u8 = "00000000-0000-4000-8000-000000000000",
    /// The human-readable wallet name shown in a provider picker.
    name: []const u8 = "wezig",
    /// A data-URI icon (EIP-6963 requires a data URI). A tiny SVG placeholder.
    icon: []const u8 = "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg'/>",
    /// The reverse-DNS wallet identifier (EIP-6963's stable provider key).
    rdns: []const u8 = "eth.wezig",
};

/// The provider→broker request envelope (ADR-0015 decision 5). The page-world
/// provider builds ONE of these per page call and hands it to the `Broker` seam
/// as a JSON line. It is the EIP-1193 `{ method, params }` the page spoke, PLUS
/// the two fields trusted native adds: a correlation `id` and — load-bearing —
/// the `origin` the request is bound to (stamped by native, NEVER by the page,
/// so a page cannot forge another origin's identity).
pub const BrokerRequest = struct {
    /// Correlates a response to its request (per-provider monotonic counter).
    id: u64,
    /// The requesting CONTENT origin (the IPFS CID text; ADR-0015 decisions 1/2).
    /// Stamped by the trusted provider from the channel the message arrived on,
    /// so the broker's decision + the recorded grant are ORIGIN-bound.
    origin: []const u8,
    /// The EIP-1193 method (this spike proves only `eth_requestAccounts`).
    method: []const u8,
    /// The raw EIP-1193 params array as a JSON snippet (e.g. `[]`), forwarded
    /// verbatim. Kept as a JSON string so the envelope needs no per-method typing.
    params_json: []const u8 = "[]",

    /// Serialise to ONE JSON line (no trailing newline; the transport frames it).
    /// This is the exact wire form both the fake broker and the out-of-process
    /// broker (the live proof) parse.
    pub fn toJson(self: BrokerRequest, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            gpa,
            "{{\"id\":{d},\"origin\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ self.id, self.origin, self.method, self.params_json },
        );
    }
};

/// The broker→provider response envelope (the EIP-1193 result shape the provider
/// forwards to the page). Exactly one of `result_json` / `error_*` is populated.
/// On success the provider evaluates `result_json` back into the page as the
/// resolved value of the page's `request(...)` promise; on failure it rejects
/// with the EIP-1193 `{ code, message }`. It carries the disclosed ACCOUNTS on a
/// granted `eth_requestAccounts` — public addresses only, NEVER key material.
pub const BrokerResponse = struct {
    /// The `id` of the request this answers.
    id: u64,
    /// The EIP-1193 result as a JSON snippet (e.g. an accounts array
    /// `["0x…"]`), or null when an error is set.
    result_json: ?[]const u8 = null,
    /// The EIP-1193 provider error, or null on success.
    error_code: ?i64 = null,
    error_message: ?[]const u8 = null,

    pub fn toJson(self: BrokerResponse, gpa: std.mem.Allocator) ![]u8 {
        if (self.result_json) |r| {
            return std.fmt.allocPrint(gpa, "{{\"id\":{d},\"result\":{s}}}", .{ self.id, r });
        }
        return std.fmt.allocPrint(
            gpa,
            "{{\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
            .{ self.id, self.error_code orelse -32603, self.error_message orelse "internal error" },
        );
    }
};

/// EIP-1193 `4001 User Rejected Request` — the standard code for a denied
/// permission request (the broker returns it when it declines a grant).
pub const eip1193_user_rejected: i64 = 4001;
/// EIP-1193 `4200 Unsupported Method` — returned for any method other than the
/// one `eth_requestAccounts` this spike proves.
pub const eip1193_unsupported_method: i64 = 4200;

/// The BROKER seam (ADR-0015 decision 5): the trusted boundary that owns key
/// custody and makes the "decide + return accounts/sign" call. A `{ ptr, vtable }`
/// value, the SAME shape as `Renderer`/`net.Fetcher`, so it abstracts over WHERE
/// the broker runs: `FakeBroker` below satisfies it IN-PROCESS for the gate's
/// contract test; the live proof (`wallet_broker_spike.zig`) satisfies it with an
/// OUT-OF-PROCESS child the parent reaches only over stdio. Either way the caller
/// (the provider) sees ONLY `handle(request_line) -> response_line` — never keys.
///
/// The boundary is a STRING boundary on purpose: the provider hands the broker a
/// JSON request LINE and gets back a JSON response LINE, exactly what frames over
/// a pipe/socket to another process. Key material is confined behind `ptr`; it
/// cannot cross this vtable.
pub const Broker = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Decide `request_line` (one JSON `BrokerRequest`) and return the JSON
        /// `BrokerResponse` line, allocated with `gpa` (caller frees). This is
        /// the ONLY method the page/provider side can invoke on the broker — it
        /// gets a response, never a key.
        handle: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, request_line: []const u8) anyerror![]u8,
    };

    pub fn handle(self: Broker, gpa: std.mem.Allocator, request_line: []const u8) ![]u8 {
        return self.vtable.handle(self.ptr, gpa, request_line);
    }
};

/// The origin + id + method parsed out of a `BrokerRequest` JSON line — the three
/// fields a broker decides on (`eth_requestAccounts` needs no params). Shared by
/// `FakeBroker` and the live out-of-process broker so both parse the SAME wire
/// shape. Returned slices BORROW `line`.
pub const ParsedRequest = struct {
    id: u64,
    origin: []const u8,
    method: []const u8,

    pub fn parse(line: []const u8) !ParsedRequest {
        return .{
            .id = try jsonNumberField(line, "\"id\":"),
            .origin = try jsonStringField(line, "origin"),
            .method = try jsonStringField(line, "method"),
        };
    }
};

/// Extract the string value of `"<key>":"<value>"` from a flat JSON `line`
/// (borrowing). Sufficient for this spike's flat, wezig-generated envelope; the
/// build swaps in `std.json` when the envelope grows nested/user-supplied fields.
fn jsonStringField(line: []const u8, key: []const u8) ![]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{key});
    const start = (std.mem.indexOf(u8, line, needle) orelse return error.FieldMissing) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return error.FieldMissing;
    return line[start..end];
}

/// Extract an unsigned-integer value following `needle` (e.g. `"id":`) in `line`.
fn jsonNumberField(line: []const u8, needle: []const u8) !u64 {
    const start = (std.mem.indexOf(u8, line, needle) orelse return error.FieldMissing) + needle.len;
    var end = start;
    while (end < line.len and line[end] >= '0' and line[end] <= '9') : (end += 1) {}
    if (end == start) return error.FieldMissing;
    return std.fmt.parseInt(u64, line[start..end], 10);
}

/// Extract the `"result":<json>` value (the array/snippet after the key) from a
/// response line, to the response object's final closing brace. Borrowing.
fn jsonResultField(line: []const u8) ![]const u8 {
    const needle = "\"result\":";
    const start = (std.mem.indexOf(u8, line, needle) orelse return error.FieldMissing) + needle.len;
    const end = std.mem.lastIndexOfScalar(u8, line, '}') orelse return error.FieldMissing;
    return line[start..end];
}

/// A FAKE broker holding a THROWAWAY test key, for the display-free gate's
/// contract test (and reused by the live proof's in-child logic). It models the
/// trusted side of the boundary WITHOUT any real custody:
///
///   - it owns a fixed, throwaway test PRIVATE KEY and the ACCOUNT ADDRESS
///     derived from it (a spike value — NOT real secp256k1; the real derivation
///     is the wallet build's job);
///   - `handle` answers `eth_requestAccounts` by returning the ADDRESS only;
///   - the key NEVER appears in any response (asserted by the tests).
///
/// **This is never real custody.** The "key" is a compile-time constant test
/// value; nothing here reads an OS keychain, a file, or a real secret. A real
/// broker (ADR-0015 decision 3) replaces `FakeBroker` behind the same `Broker`
/// seam, in its own process (the live proof shows the process boundary).
pub const FakeBroker = struct {
    /// The THROWAWAY test private key. A fixed non-secret constant — the whole
    /// point of the spike is that this value must NEVER cross the boundary, so
    /// the tests can assert its absence. NOT a real key; NEVER real custody.
    pub const throwaway_test_privkey: []const u8 =
        "0x0000000000000000000000000000000000000000000000000000000000000001";
    /// The ACCOUNT ADDRESS the broker discloses for the test key. In a real
    /// broker this is derived from the key via secp256k1 + keccak; here it is a
    /// fixed spike address (public, disclosure-gated — safe to return).
    pub const test_account_address: []const u8 =
        "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf";

    /// If true, `handle` DECLINES the next grant (returns EIP-1193 4001), so a
    /// test can prove the boundary carries a rejection too (the approval policy
    /// itself is the build's job; this just proves both response legs).
    decline: bool = false,

    pub fn broker(self: *FakeBroker) Broker {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Broker.VTable{ .handle = handle };

    fn handle(ctx: *anyopaque, gpa: std.mem.Allocator, request_line: []const u8) anyerror![]u8 {
        const self: *FakeBroker = @ptrCast(@alignCast(ctx));
        return decide(self, gpa, request_line);
    }

    /// The trusted decision, shared by the in-process seam impl AND the live
    /// out-of-process broker child (so both sides run IDENTICAL broker logic).
    /// Only `eth_requestAccounts` is supported; a grant discloses the ADDRESS,
    /// never the key.
    pub fn decide(self: *FakeBroker, gpa: std.mem.Allocator, request_line: []const u8) ![]u8 {
        const req = try ParsedRequest.parse(request_line);
        if (!std.mem.eql(u8, req.method, "eth_requestAccounts")) {
            const resp = BrokerResponse{
                .id = req.id,
                .error_code = eip1193_unsupported_method,
                .error_message = "unsupported method",
            };
            return resp.toJson(gpa);
        }
        if (self.decline) {
            const resp = BrokerResponse{
                .id = req.id,
                .error_code = eip1193_user_rejected,
                .error_message = "user rejected",
            };
            return resp.toJson(gpa);
        }
        // Grant: disclose the ACCOUNT ADDRESS (public), never the key.
        var buf: [128]u8 = undefined;
        const accounts = try std.fmt.bufPrint(&buf, "[\"{s}\"]", .{test_account_address});
        const resp = BrokerResponse{ .id = req.id, .result_json = accounts };
        return resp.toJson(gpa);
    }
};

/// The page-world EIP-6963 announce + provider script injected via the seam
/// (`injectUserScript`). It (1) defines the provider INSTANCE — an EIP-1193-ish
/// object whose `request({method,params})` posts a JSON line over the script
/// bridge and resolves when native evaluates the reply — and (2) announces it via
/// `eip6963:announceProvider`, re-announcing on `eip6963:requestProvider`, so a
/// page discovers wezig via EIP-6963 and NOT `window.ethereum`. The `{[0]s}`
/// placeholder is the per-origin channel; the rest are the announce `info`.
///
/// This is the SHAPE settled for the finding; the live proof drives the real
/// backend, the gate proves the message contract this script implements.
const announce_script_template =
    \\(function() {{
    \\  var CHANNEL = "{[channel]s}";
    \\  var nextId = 1, pending = {{}};
    \\  window.__wezigResolve = function(id, result) {{
    \\    var p = pending[id]; if (p) {{ delete pending[id]; p.resolve(result); }}
    \\  }};
    \\  window.__wezigReject = function(id, err) {{
    \\    var p = pending[id]; if (p) {{ delete pending[id]; p.reject(err); }}
    \\  }};
    \\  var provider = {{
    \\    request: function(args) {{
    \\      var id = nextId++;
    \\      return new Promise(function(resolve, reject) {{
    \\        pending[id] = {{ resolve: resolve, reject: reject }};
    \\        window.webkit.messageHandlers[CHANNEL].postMessage(
    \\          JSON.stringify({{ id: id, method: args.method, params: args.params || [] }}));
    \\      }});
    \\    }}
    \\  }};
    \\  var info = {{ uuid: "{[uuid]s}", name: "{[name]s}", icon: "{[icon]s}", rdns: "{[rdns]s}" }};
    \\  function announce() {{
    \\    window.dispatchEvent(new CustomEvent("eip6963:announceProvider",
    \\      {{ detail: Object.freeze({{ info: info, provider: provider }}) }}));
    \\  }}
    \\  window.addEventListener("eip6963:requestProvider", announce);
    \\  announce();
    \\}})();
;

/// Build the concrete EIP-6963 announce script for `channel` + `info` (fills the
/// template). Caller owns the returned buffer.
pub fn announceScript(gpa: std.mem.Allocator, channel: []const u8, info: Eip6963ProviderInfo) ![]u8 {
    return std.fmt.allocPrint(gpa, announce_script_template, .{
        .channel = channel,
        .uuid = info.uuid,
        .name = info.name,
        .icon = info.icon,
        .rdns = info.rdns,
    });
}

/// The reply script native evaluates back into the page to RESOLVE a page
/// `request(...)` promise with `result_json` for correlation `id` (the native→
/// page leg over the seam's `evaluateScript`).
pub fn resolveScript(gpa: std.mem.Allocator, id: u64, result_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "window.__wezigResolve({d}, {s});", .{ id, result_json });
}

/// The reply script native evaluates to REJECT a page promise with an EIP-1193
/// error for `id`.
pub fn rejectScript(gpa: std.mem.Allocator, id: u64, code: i64, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "window.__wezigReject({d}, {{ code: {d}, message: \"{s}\" }});",
        .{ id, code, message },
    );
}

/// The `id` field of a page→native message body (the page's `request` id).
fn pageMessageId(body: []const u8) !u64 {
    return jsonNumberField(body, "\"id\":");
}

/// The PAGE-FACING PROVIDER: the trusted native glue between the page-world
/// EIP-6963 provider (over the seam's script bridge) and the `Broker` seam. It
/// is the ONLY thing that touches the broker; the page reaches it only by posting
/// over the bridge. For each page→native message it:
///
///   1. resolves which content ORIGIN the message arrived on (the channel name),
///      via `OriginProviderBinding` — the request is thereby ORIGIN-BOUND;
///   2. STAMPS that origin onto a `BrokerRequest` (the page cannot forge it) and
///      hands the JSON line to the `Broker` — crossing the boundary;
///   3. on a granted `eth_requestAccounts`, records the disclosed accounts on
///      THAT origin's shared `WalletLink` (so same-origin tabs share the grant),
///      then evaluates the resolve/reject reply back into the page.
///
/// It holds NO key material — only a `Broker` value (opaque `ptr` + vtable) and
/// the origin store. The whole point: the page → provider → broker → page path
/// moves REQUESTS and public results, never keys. Reproduced identically by a
/// `WezigRenderer` because it drives ONLY seam methods + the `Broker` seam.
pub const PageProvider = struct {
    gpa: std.mem.Allocator,
    renderer: Renderer,
    broker: Broker,
    binding: *OriginProviderBinding,
    info: Eip6963ProviderInfo = .{},
    /// Set on the LAST reply evaluated back into the page, so the gate's test can
    /// assert what the page would observe without a real webview. Owned.
    last_reply: ?[]u8 = null,

    pub fn init(
        gpa: std.mem.Allocator,
        r: Renderer,
        broker_seam: Broker,
        binding: *OriginProviderBinding,
    ) PageProvider {
        return .{ .gpa = gpa, .renderer = r, .broker = broker_seam, .binding = binding };
    }

    pub fn deinit(self: *PageProvider) void {
        if (self.last_reply) |s| self.gpa.free(s);
    }

    /// ADVERTISE + WIRE the provider for `origin`: inject the EIP-6963 announce +
    /// provider script into the page world, and open the origin's page→native
    /// channel routing page posts to `onPageMessage`. After this, a page
    /// discovers wezig via `eip6963:announceProvider` and its `request(...)`
    /// posts reach this provider. Idempotent per origin (the binding dedupes).
    pub fn advertise(self: *PageProvider, origin: ContentOrigin) !void {
        var name_buf: [512]u8 = undefined;
        const channel = try OriginProviderBinding.channelName(origin, &name_buf);

        const script = try announceScript(self.gpa, channel, self.info);
        defer self.gpa.free(script);
        try self.injectZ(script);

        // Open the origin's channel; page posts route to onPageMessage.
        try self.binding.bind(origin, .{ .ctx = self, .onMessage = onPageMessage });
    }

    /// The seam's page→native message sink (registered by `advertise`). Resolves
    /// the origin from `channel`, stamps it onto a broker request, crosses the
    /// boundary, records a grant on the origin's link, and replies into the page.
    /// Errors become an EIP-1193 reject reply (native never crashes on bad input).
    fn onPageMessage(ctx: *anyopaque, channel: []const u8, body: []const u8) void {
        const self: *PageProvider = @ptrCast(@alignCast(ctx));
        self.dispatch(channel, body) catch |err| {
            const id = pageMessageId(body) catch 0;
            const script = rejectScript(self.gpa, id, -32603, @errorName(err)) catch return;
            defer self.gpa.free(script);
            self.evalReply(script);
        };
    }

    /// The core round-trip for one page message (fallible; `onPageMessage` maps
    /// errors to a reject). Split out so the gate's test drives it directly and
    /// asserts the boundary crossing without a real webview delivering the post.
    pub fn dispatch(self: *PageProvider, channel: []const u8, body: []const u8) !void {
        const origin = OriginProviderBinding.originForChannel(channel) orelse return error.UnknownOrigin;
        const page_id = try pageMessageId(body);
        const method = try jsonStringField(body, "method");

        // Stamp the TRUSTED origin onto the request (the page never supplies it),
        // then cross the boundary. The broker sees the request LINE only.
        const req = BrokerRequest{ .id = page_id, .origin = origin.cid, .method = method };
        const req_line = try req.toJson(self.gpa);
        defer self.gpa.free(req_line);

        const resp_line = try self.broker.handle(self.gpa, req_line);
        defer self.gpa.free(resp_line);

        // On a granted eth_requestAccounts, record the disclosed accounts on THIS
        // origin's shared link, then resolve the page promise with them.
        if (std.mem.indexOf(u8, resp_line, "\"result\":") != null) {
            if (std.mem.eql(u8, method, "eth_requestAccounts")) {
                try self.recordGrant(origin, resp_line);
            }
            const result = try jsonResultField(resp_line);
            const script = try resolveScript(self.gpa, page_id, result);
            defer self.gpa.free(script);
            self.evalReply(script);
        } else {
            const code = jsonNumberField(resp_line, "\"code\":") catch 0;
            const message = jsonStringField(resp_line, "message") catch "error";
            const script = try rejectScript(self.gpa, page_id, @intCast(code), message);
            defer self.gpa.free(script);
            self.evalReply(script);
        }
    }

    /// Record the granted accounts (parsed from the broker's result array) onto
    /// `origin`'s SHARED wallet link, so the grant is origin-bound + shared by
    /// same-origin tabs. Public addresses only — the broker never disclosed a key.
    fn recordGrant(self: *PageProvider, origin: ContentOrigin, resp_line: []const u8) !void {
        const link = try self.binding.store.linkFor(origin);
        var addrs: std.ArrayList([]const u8) = .empty;
        defer addrs.deinit(self.gpa);
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |o| self.gpa.free(o);
            owned.deinit(self.gpa);
        }
        // The result is a flat `["0x…","0x…"]` array; tokenise the addresses out.
        const result = jsonResultField(resp_line) catch "[]";
        var it = std.mem.tokenizeAny(u8, result, "[]\", ");
        while (it.next()) |tok| {
            const dup = try self.gpa.dupe(u8, tok);
            try owned.append(self.gpa, dup);
            try addrs.append(self.gpa, dup);
        }
        try link.grant(self.gpa, addrs.items);
    }

    /// Inject a NUL-terminated copy of `source` into the page world over the seam.
    fn injectZ(self: *PageProvider, source: []const u8) !void {
        const z = try self.gpa.allocSentinel(u8, source.len, 0);
        defer self.gpa.free(z);
        @memcpy(z, source);
        self.renderer.injectUserScript(z.ptr);
    }

    fn evalReply(self: *PageProvider, script: []const u8) void {
        if (self.last_reply) |s| self.gpa.free(s);
        self.last_reply = self.gpa.dupe(u8, script) catch null;
        const z = self.gpa.allocSentinel(u8, script.len, 0) catch return;
        defer self.gpa.free(z);
        @memcpy(z, script);
        self.renderer.evaluateScript(z.ptr);
    }
};

// ===========================================================================
// Tests: the broker-boundary contract + the EIP-6963 provider round-trip, all
// headless (no webview, no display, no child process) in `zig build test`. The
// provider drives a `FakeRenderer` (the fake BRIDGE) and a `FakeBroker` (the
// fake BROKER); the live out-of-process broker proof is `wallet_broker_spike.zig`
// + `zig build wallet-broker-roundtrip-test`.
//
// The load-bearing assertions:
//   - ONE origin-bound `eth_requestAccounts` round-trips page→broker→page;
//   - the request the broker sees carries the CONTENT ORIGIN (origin-bound);
//   - the reply the page sees discloses the ACCOUNT ADDRESS and NEVER the key;
//   - the grant is recorded on THAT origin's shared link (per-origin);
//   - the provider is announced via EIP-6963, not `window.ethereum`.
// ===========================================================================

const testing = std.testing;
const FakeRenderer = renderer_mod.FakeRenderer;

test "BrokerRequest/Response: the settled JSON wire shape round-trips" {
    const gpa = testing.allocator;

    const req = BrokerRequest{ .id = 7, .origin = "bafyReq", .method = "eth_requestAccounts" };
    const req_line = try req.toJson(gpa);
    defer gpa.free(req_line);
    try testing.expectEqualStrings(
        "{\"id\":7,\"origin\":\"bafyReq\",\"method\":\"eth_requestAccounts\",\"params\":[]}",
        req_line,
    );

    const parsed = try ParsedRequest.parse(req_line);
    try testing.expectEqual(@as(u64, 7), parsed.id);
    try testing.expectEqualStrings("bafyReq", parsed.origin);
    try testing.expectEqualStrings("eth_requestAccounts", parsed.method);

    const ok = BrokerResponse{ .id = 7, .result_json = "[\"0xabc\"]" };
    const ok_line = try ok.toJson(gpa);
    defer gpa.free(ok_line);
    try testing.expectEqualStrings("{\"id\":7,\"result\":[\"0xabc\"]}", ok_line);

    const err = BrokerResponse{ .id = 7, .error_code = eip1193_user_rejected, .error_message = "user rejected" };
    const err_line = try err.toJson(gpa);
    defer gpa.free(err_line);
    try testing.expectEqualStrings(
        "{\"id\":7,\"error\":{\"code\":4001,\"message\":\"user rejected\"}}",
        err_line,
    );
}

test "FakeBroker: eth_requestAccounts discloses the ADDRESS and NEVER the key" {
    const gpa = testing.allocator;
    var fb = FakeBroker{};

    const req = BrokerRequest{ .id = 1, .origin = "bafyKeyGuard", .method = "eth_requestAccounts" };
    const req_line = try req.toJson(gpa);
    defer gpa.free(req_line);

    const resp = try fb.broker().handle(gpa, req_line);
    defer gpa.free(resp);

    // The disclosed account address is present...
    try testing.expect(std.mem.indexOf(u8, resp, FakeBroker.test_account_address) != null);
    // ...and the throwaway PRIVATE KEY is NOT anywhere in the response. This is
    // the boundary's core guarantee: the page never receives key material.
    try testing.expect(std.mem.indexOf(u8, resp, FakeBroker.throwaway_test_privkey) == null);
}

test "FakeBroker: unsupported method + decline both surface as EIP-1193 errors" {
    const gpa = testing.allocator;
    var fb = FakeBroker{};

    const other = BrokerRequest{ .id = 2, .origin = "bafyX", .method = "eth_sendTransaction" };
    const other_line = try other.toJson(gpa);
    defer gpa.free(other_line);
    const r1 = try fb.broker().handle(gpa, other_line);
    defer gpa.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "4200") != null);

    fb.decline = true;
    const req = BrokerRequest{ .id = 3, .origin = "bafyX", .method = "eth_requestAccounts" };
    const req_line = try req.toJson(gpa);
    defer gpa.free(req_line);
    const r2 = try fb.broker().handle(gpa, req_line);
    defer gpa.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "4001") != null);
    try testing.expect(std.mem.indexOf(u8, r2, FakeBroker.test_account_address) == null);
}

test "EIP-6963: the injected script announces a provider, not window.ethereum" {
    const gpa = testing.allocator;
    const script = try announceScript(gpa, "wezig:bafyAnnounce", .{});
    defer gpa.free(script);

    // Discovery is EIP-6963 announce/request events...
    try testing.expect(std.mem.indexOf(u8, script, "eip6963:announceProvider") != null);
    try testing.expect(std.mem.indexOf(u8, script, "eip6963:requestProvider") != null);
    // ...NOT a bare window.ethereum injection.
    try testing.expect(std.mem.indexOf(u8, script, "window.ethereum") == null);
    // The provider posts on the per-origin channel, and carries the info payload.
    try testing.expect(std.mem.indexOf(u8, script, "wezig:bafyAnnounce") != null);
    try testing.expect(std.mem.indexOf(u8, script, "eth.wezig") != null);
}

test "PageProvider: ONE origin-bound eth_requestAccounts round-trips page->broker->page" {
    const gpa = testing.allocator;

    var fr = FakeRenderer.init(gpa);
    defer fr.deinit();
    var store = WalletLinkStore.init(gpa);
    defer store.deinit();
    var binding = OriginProviderBinding.init(gpa, fr.renderer(), &store);
    defer binding.deinit();
    var fb = FakeBroker{};

    var provider = PageProvider.init(gpa, fr.renderer(), fb.broker(), &binding);
    defer provider.deinit();

    const origin = ContentOrigin.init("bafyDApp");

    // Advertise: inject the EIP-6963 script + open the origin's channel.
    try provider.advertise(origin);
    try testing.expect(fr.injected_script != null);
    try testing.expect(std.mem.indexOf(u8, fr.injected_script.?, "eip6963:announceProvider") != null);
    try testing.expectEqualStrings("wezig:bafyDApp", fr.msg_name.?);

    // The page calls provider.request({method:"eth_requestAccounts"}) — simulate
    // the resulting post arriving on the origin's channel over the fake bridge.
    fr.firePageMessage("wezig:bafyDApp", "{\"id\":1,\"method\":\"eth_requestAccounts\",\"params\":[]}");

    // page->broker->page completed: native evaluated a RESOLVE reply into the
    // page carrying the disclosed account address — and NOT the private key.
    try testing.expect(provider.last_reply != null);
    const reply = provider.last_reply.?;
    try testing.expect(std.mem.indexOf(u8, reply, "__wezigResolve") != null);
    try testing.expect(std.mem.indexOf(u8, reply, FakeBroker.test_account_address) != null);
    try testing.expect(std.mem.indexOf(u8, reply, FakeBroker.throwaway_test_privkey) == null);

    // The grant is recorded on THIS origin's shared link (origin-bound), so a
    // same-origin tab sees it; the address is stored lowercase.
    const link = store.existing(origin).?;
    try testing.expect(link.granted);
    try testing.expectEqual(@as(usize, 1), link.accounts.items.len);
    try testing.expectEqualStrings(FakeBroker.test_account_address, link.accounts.items[0]);
}

test "PageProvider: the request the broker sees is ORIGIN-BOUND (stamped by native)" {
    const gpa = testing.allocator;

    // A recording broker capturing the request LINE, so we assert the trusted
    // origin was stamped onto it (the page never supplied it).
    const Recorder = struct {
        captured: ?[]u8 = null,
        gpa: std.mem.Allocator,
        fn broker(self: *@This()) Broker {
            return .{ .ptr = self, .vtable = &.{ .handle = handle } };
        }
        fn handle(ctx: *anyopaque, a: std.mem.Allocator, line: []const u8) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.captured) |c| self.gpa.free(c);
            self.captured = try self.gpa.dupe(u8, line);
            const resp = BrokerResponse{ .id = 1, .result_json = "[\"0x0000000000000000000000000000000000000000\"]" };
            return resp.toJson(a);
        }
    };
    var rec = Recorder{ .gpa = gpa };
    defer if (rec.captured) |c| gpa.free(c);

    var fr = FakeRenderer.init(gpa);
    defer fr.deinit();
    var store = WalletLinkStore.init(gpa);
    defer store.deinit();
    var binding = OriginProviderBinding.init(gpa, fr.renderer(), &store);
    defer binding.deinit();

    var provider = PageProvider.init(gpa, fr.renderer(), rec.broker(), &binding);
    defer provider.deinit();

    const origin = ContentOrigin.init("bafyOriginBound");
    try provider.advertise(origin);
    // The page posts WITHOUT any origin field — native must stamp it.
    fr.firePageMessage("wezig:bafyOriginBound", "{\"id\":1,\"method\":\"eth_requestAccounts\",\"params\":[]}");

    try testing.expect(rec.captured != null);
    // The broker's request carries the requesting content origin, stamped by the
    // trusted provider from the channel — origin-bound (ADR-0015 decision 2).
    try testing.expect(std.mem.indexOf(u8, rec.captured.?, "\"origin\":\"bafyOriginBound\"") != null);
}

test "PageProvider: two tabs on the SAME origin share the grant; different origins are independent" {
    const gpa = testing.allocator;

    var fr = FakeRenderer.init(gpa);
    defer fr.deinit();
    var store = WalletLinkStore.init(gpa);
    defer store.deinit();
    var binding = OriginProviderBinding.init(gpa, fr.renderer(), &store);
    defer binding.deinit();
    var fb = FakeBroker{};
    var provider = PageProvider.init(gpa, fr.renderer(), fb.broker(), &binding);
    defer provider.deinit();

    const app_a = ContentOrigin.init("bafyShareA");
    const app_b = ContentOrigin.init("bafyShareB");
    try provider.advertise(app_a);
    fr.firePageMessage("wezig:bafyShareA", "{\"id\":1,\"method\":\"eth_requestAccounts\",\"params\":[]}");

    // A second tab on the SAME origin already sees the shared grant (the link is
    // origin-keyed, not tab-keyed) WITHOUT a second request.
    const shared = store.existing(app_a).?;
    try testing.expect(shared.granted);

    // A different origin has NO grant until it asks — cross-origin isolation.
    try provider.advertise(app_b);
    try testing.expect(store.existing(app_b) == null or !store.existing(app_b).?.granted);
}

test "PageProvider: a declined grant rejects the page promise and discloses nothing" {
    const gpa = testing.allocator;

    var fr = FakeRenderer.init(gpa);
    defer fr.deinit();
    var store = WalletLinkStore.init(gpa);
    defer store.deinit();
    var binding = OriginProviderBinding.init(gpa, fr.renderer(), &store);
    defer binding.deinit();
    var fb = FakeBroker{ .decline = true };
    var provider = PageProvider.init(gpa, fr.renderer(), fb.broker(), &binding);
    defer provider.deinit();

    const origin = ContentOrigin.init("bafyDecline");
    try provider.advertise(origin);
    fr.firePageMessage("wezig:bafyDecline", "{\"id\":1,\"method\":\"eth_requestAccounts\",\"params\":[]}");

    // The page promise is REJECTED (4001) and no account/grant leaked.
    try testing.expect(provider.last_reply != null);
    try testing.expect(std.mem.indexOf(u8, provider.last_reply.?, "__wezigReject") != null);
    try testing.expect(std.mem.indexOf(u8, provider.last_reply.?, "4001") != null);
    const link = store.existing(origin);
    try testing.expect(link == null or !link.?.granted);
}
