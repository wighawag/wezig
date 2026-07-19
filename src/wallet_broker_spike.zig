//! De-risking SPIKE — the LIVE OUT-OF-PROCESS broker leg (spec
//! `explore-web3-capabilities`, story 1; ADR-0015 decision 5). The core gate
//! (`src/wallet_broker.zig`) proves the provider↔broker MESSAGE CONTRACT + the
//! `eth_requestAccounts` round-trip headlessly with an IN-PROCESS fake broker.
//! THIS module proves the boundary is a REAL PROCESS boundary: it spawns the
//! broker as a SEPARATE child process that owns the THROWAWAY test key in ITS
//! OWN address space, and drives ONE `eth_requestAccounts` round-trip across the
//! process boundary over the child's stdio — the same JSON request/response LINE
//! shape the in-process `Broker` seam uses (`wallet_broker.BrokerRequest` /
//! `BrokerResponse`). The parent (the page/provider side) reaches the key-holding
//! broker ONLY by request; it never has the key.
//!
//! ## Why a separate module + step (mirrors `networking_spike.zig`)
//!
//! `src/wallet_broker.zig` is PURE ZIG behind the `Renderer` + `Broker` seams and
//! lives in the `wezig` library `mod` + the display-free `zig build test` gate.
//! THIS module spawns a child PROCESS (the real broker sandbox), which the bare
//! `gate` job's in-`test` model does not exercise — so it is compiled + run ONLY
//! by the dedicated `zig build wallet-broker-roundtrip-test` step, in a dedicated
//! `wallet-broker` CI leg, mirroring the `networking`/`harfbuzz`/`webview` legs
//! (ADR-0007: live/provisioned proofs stay OFF the core gate). It is deliberately
//! NOT re-exported from `src/root.zig`.
//!
//! The live legs are guarded by `build_options.wallet_broker_live`
//! (`-Dwallet-broker-live`, set by the step): with the flag off a bare `zig test`
//! of this file still compiles + links it and SKIPS the spawn, so nothing
//! load-bearing depends on being able to spawn (the boundary CONTRACT proof is
//! the gate's job in `wallet_broker.zig`). The child broker executable's path is
//! injected by the build (`build_options.broker_child_path`).
//!
//! **Never real custody.** The child broker holds a fixed THROWAWAY test key
//! (`wallet_broker.FakeBroker.throwaway_test_privkey`) — a non-secret constant.
//! The point proven here is topological: the key lives in a DIFFERENT process
//! from the page/provider side, and only the ACCOUNT ADDRESS crosses back.

const std = @import("std");
const wezig = @import("wezig");
const build_options = @import("build_options");

const wallet_broker = wezig.wallet_broker;
const Broker = wallet_broker.Broker;
const BrokerRequest = wallet_broker.BrokerRequest;
const BrokerResponse = wallet_broker.BrokerResponse;
const FakeBroker = wallet_broker.FakeBroker;

/// The CHILD broker's main loop (the OUT-OF-PROCESS trusted side). Runs in the
/// spawned broker executable: read ONE JSON request line from stdin, DECIDE it
/// with the throwaway-key `FakeBroker` logic (held entirely in THIS process),
/// write ONE JSON response line to stdout, repeat until stdin closes (EOF). The
/// private key never leaves this process — only the response line (the account
/// address on a grant) is written back. This is the exact `handle` the in-process
/// `Broker` seam runs, now behind a real process boundary.
///
/// It frames newline-delimited lines over RAW POSIX `read`/`write` on the
/// inherited stdio fds (0/1), DELIBERATELY bypassing the `std.Io` reader. WHY:
/// the `std.Io.Threaded` streaming file reader busy-loops at end-of-stream on a
/// closed inherited pipe (after the parent writes one line and closes stdin, the
/// next buffered read spins in userspace at 100% CPU inside the reader instead
/// of surfacing EOF — the child never exits, hanging the parent's `wait`). A
/// blocking POSIX `read` reports EOF UNAMBIGUOUSLY as a 0-byte return, so this
/// loop terminates the instant the parent closes stdin. This is the child's own
/// tiny transport; the SEAM boundary it proves (a JSON request line in, a JSON
/// response line out across a real process boundary) is unchanged. Output uses
/// the `std.Io` file writer (writing to a pipe never has the EOF-spin problem).
pub fn runBroker(io: std.Io, gpa: std.mem.Allocator) !void {
    const stdin_fd = std.posix.STDIN_FILENO;
    const stdout = std.Io.File.stdout();

    var broker = FakeBroker{};
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(stdin_fd, &chunk);
        if (n == 0) break; // EOF: the parent closed stdin. Exit cleanly.
        try acc.appendSlice(gpa, chunk[0..n]);
        // Drain every COMPLETE line currently buffered (there may be 0, 1, or more).
        while (std.mem.indexOfScalar(u8, acc.items, '\n')) |nl| {
            const line = acc.items[0..nl];
            if (line.len != 0) {
                const resp = try broker.decide(gpa, line);
                defer gpa.free(resp);
                try stdout.writeStreamingAll(io, resp);
                try stdout.writeStreamingAll(io, "\n");
            }
            // Drop the consumed line + its newline from the accumulator.
            const rest = acc.items[nl + 1 ..];
            std.mem.copyForwards(u8, acc.items[0..rest.len], rest);
            acc.shrinkRetainingCapacity(rest.len);
        }
    }
}

/// A `Broker` seam implementation backed by an OUT-OF-PROCESS child. Each
/// `handle` spawns the broker child, writes the request LINE to its stdin, reads
/// the response LINE from its stdout, and returns it — proving the boundary is a
/// real process boundary. (A one-shot spawn per request keeps the spike minimal;
/// a real broker holds one long-lived process — the build's concern.) The parent
/// holds only the child's PATH + its pipes; it never sees key material.
pub const ChildProcessBroker = struct {
    io: std.Io,
    child_path: []const u8,

    pub fn broker(self: *ChildProcessBroker) Broker {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Broker.VTable{ .handle = handle };

    fn handle(ctx: *anyopaque, gpa: std.mem.Allocator, request_line: []const u8) anyerror![]u8 {
        const self: *ChildProcessBroker = @ptrCast(@alignCast(ctx));
        return roundTrip(self.io, gpa, self.child_path, request_line);
    }

    /// Spawn the child broker, send ONE request line, read ONE response line.
    fn roundTrip(io: std.Io, gpa: std.mem.Allocator, child_path: []const u8, request_line: []const u8) ![]u8 {
        var child = try std.process.spawn(io, .{
            .argv = &.{child_path},
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer _ = child.kill(io);

        // Write the request line to the child's stdin, then close stdin so the
        // child sees EOF and its loop exits after replying.
        {
            var wbuf: [4096]u8 = undefined;
            var cw = child.stdin.?.writer(io, &wbuf);
            try cw.interface.writeAll(request_line);
            try cw.interface.writeAll("\n");
            try cw.interface.flush();
            child.stdin.?.close(io);
            child.stdin = null;
        }

        // Read the child's response line from its stdout.
        var rbuf: [4096]u8 = undefined;
        var cr = child.stdout.?.reader(io, &rbuf);
        const line = cr.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.BrokerClosed,
            else => return err,
        };
        const owned = try gpa.dupe(u8, line);
        errdefer gpa.free(owned);

        _ = try child.wait(io);
        return owned;
    }
};

// ===========================================================================
// Live tests (run via `zig build wallet-broker-roundtrip-test`, the
// `wallet-broker` CI leg). Guarded by `build_options.wallet_broker_live` so a
// bare `zig test` compiles + links this module and SKIPS the spawn — the
// boundary CONTRACT proof is the gate's job (`wallet_broker.zig`).
// ===========================================================================

const testing = std.testing;

fn liveEnabled() bool {
    return build_options.wallet_broker_live;
}

test "ChildProcessBroker builds + links (compile/link proof, no spawn)" {
    // Even with the live flag off, prove this module compiles + links against the
    // `Broker` seam and the child-path option — the linkage half, on every run.
    var cpb = ChildProcessBroker{ .io = std.testing.io, .child_path = build_options.broker_child_path };
    _ = cpb.broker();
}

test "LIVE: one eth_requestAccounts round-trips through a SEPARATE broker PROCESS; the key never crosses" {
    if (!liveEnabled()) return error.SkipZigTest;
    const gpa = testing.allocator;

    var cpb = ChildProcessBroker{ .io = std.testing.io, .child_path = build_options.broker_child_path };
    const b = cpb.broker();

    // Build the request the trusted provider would stamp (origin-bound), and send
    // it ACROSS the process boundary to the key-holding child broker.
    const req = BrokerRequest{ .id = 1, .origin = "bafyLiveOrigin", .method = "eth_requestAccounts" };
    const req_line = try req.toJson(gpa);
    defer gpa.free(req_line);

    const resp = try b.handle(gpa, req_line);
    defer gpa.free(resp);

    // The child (a DIFFERENT process) granted: the response discloses the ACCOUNT
    // ADDRESS...
    try testing.expect(std.mem.indexOf(u8, resp, FakeBroker.test_account_address) != null);
    // ...and the THROWAWAY PRIVATE KEY never crossed the process boundary. The
    // key lived only in the child's address space; the page/provider side (this
    // process) only ever saw the request/response lines.
    try testing.expect(std.mem.indexOf(u8, resp, FakeBroker.throwaway_test_privkey) == null);
}

test "LIVE: an unsupported method surfaces an EIP-1193 error across the process boundary" {
    if (!liveEnabled()) return error.SkipZigTest;
    const gpa = testing.allocator;

    var cpb = ChildProcessBroker{ .io = std.testing.io, .child_path = build_options.broker_child_path };
    const b = cpb.broker();

    const req = BrokerRequest{ .id = 2, .origin = "bafyLiveOrigin", .method = "eth_sendTransaction" };
    const req_line = try req.toJson(gpa);
    defer gpa.free(req_line);

    const resp = try b.handle(gpa, req_line);
    defer gpa.free(resp);
    // 4200 unsupported-method comes back over the boundary; no address disclosed.
    try testing.expect(std.mem.indexOf(u8, resp, "4200") != null);
    try testing.expect(std.mem.indexOf(u8, resp, FakeBroker.test_account_address) == null);
}
