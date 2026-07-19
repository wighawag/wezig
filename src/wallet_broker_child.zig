//! The OUT-OF-PROCESS wallet broker child executable (spec
//! `explore-web3-capabilities`, story 1; ADR-0015 decision 5). This is the tiny
//! entrypoint the `wallet-broker-roundtrip-test` spike spawns as a SEPARATE
//! process to prove the broker boundary is a real process boundary: it owns the
//! THROWAWAY test key in its OWN address space and answers `eth_requestAccounts`
//! request lines on stdin with response lines on stdout (`runBroker`), never
//! writing key material back. See `src/wallet_broker_spike.zig` for the parent
//! side + the live proof. NOT a real wallet; NEVER real custody.

const std = @import("std");
const runBroker = @import("wallet_broker_spike.zig").runBroker;

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try runBroker(io, gpa);
}
