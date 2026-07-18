//! The `ScriptEngine` seam: the JavaScript-runtime boundary (ADR-0013).
//!
//! wezig needs a JavaScript runtime for dynamic pages. We reach it through THIS
//! interface so the choice of engine is REVERSIBLE — the same reversibility
//! pattern the `Renderer` seam (ADR-0005/0006) applies at the chrome↔content
//! boundary: an interface a BOUND engine satisfies now, and a Zig-native engine
//! satisfies LATER, swapped in behind the SAME seam with no caller change.
//!
//! Concretely: a BOUND engine (SpiderMonkey / JavaScriptCore / V8 — the ADR
//! leans SpiderMonkey for independence, pending an embedding-cost eval) is the
//! FIRST implementation, because compatibility with the real web needs a mature
//! engine on day one. A Zig-native engine (e.g. `kiesel`) is an ASPIRATIONAL
//! LATER swap-in behind this seam — first, plausibly, for a narrow
//! controlled-trust surface (verifiable / local-first content, ADR-0011), never
//! the general-web compatibility engine at the start (ADR-0013).
//!
//! ## ⚠️ CAVEAT: this is a WIDE, DOM-COUPLED seam — intimate, not a thin vtable
//!
//! Read this before treating `ScriptEngine` like `Renderer` or `PaintBackend`.
//! Those seams are THIN: `PaintBackend` is a handful of draw/measure calls, and
//! `Renderer` is a navigate/interact surface the caller drives one way. A
//! JS-engine boundary is fundamentally DIFFERENT: a running script calls BACK
//! into the embedder CONSTANTLY and at fine granularity —
//!
//!   - **DOM:** every `document.getElementById`, property read/write, and node
//!     mutation is a callback from the engine into our DOM (ADR-0005's seam is
//!     one-way navigation; this is a tight two-way conversation per statement).
//!   - **GC:** the engine's garbage collector must trace embedder-held object
//!     references (wrappers around DOM nodes), so object lifetime is CO-MANAGED
//!     across the boundary, not owned cleanly on one side.
//!   - **event loop / microtasks:** promises, `queueMicrotask`, timers, and
//!     `async` all interleave engine execution with the host event loop, so the
//!     boundary is a scheduling contract, not a call-and-return.
//!
//! So the swap is REVERSIBLE but NOT CHEAP the way the `Renderer` swap is: the
//! real coupling lives in the DOM/GC/event-loop bindings a concrete engine grows
//! behind this seam, and those are engine-shaped. This file pins only the
//! COARSE, engine-agnostic lifecycle (create a context, evaluate a script, tear
//! it down, report host bindings a bound engine will need) — enough to prove the
//! boundary EXISTS and holds with a stub, and to keep the engine choice a
//! documented decision rather than a hard-wired assumption. The wide binding
//! surface (host object exposure, GC rooting, microtask draining) is deliberately
//! NOT modelled here yet: it is grown by the follow-on BUILD that binds a real
//! engine, and its shape is engine-specific. Pinning it speculatively now — with
//! no implementation to check it against — would bake one engine's binding model
//! into the "neutral" seam and defeat the reversibility this seam exists for.
//! (Same discipline ADR-0006 used: pin the MINIMAL surface, grow it with its
//! implementation.)
//!
//! ## Shape (vtable, like `PaintBackend` / `Renderer` / `std.mem.Allocator`)
//!
//! `ScriptEngine` is a `{ ptr, vtable }` pair so a concrete engine is a runtime
//! VALUE, not a comptime type: the caller holds one `ScriptEngine` and could
//! hold a different backend tomorrow with no code change. The method set is
//! MINIMAL on purpose (see the caveat above): create/evaluate/destroy plus a
//! single host-binding hook, enough to prove the seam without pretending to
//! model the whole DOM/GC/event-loop conversation.
//!
//! ## The stub (this task)
//!
//! `StubScriptEngine` below is a trivial, no-real-engine implementation that
//! satisfies the seam so it compiles and its contract is testable headlessly. It
//! does NOT execute JavaScript — it records what it was asked to do (the last
//! evaluated source, the registered host bindings) so the seam's shape is proven
//! drivable. Binding SpiderMonkey/JSC/V8 (or `kiesel`) behind this seam is a
//! FOLLOW-ON build, explicitly out of scope here (ADR-0013).

const std = @import("std");

/// The outcome of asking the engine to evaluate a script. A real engine returns
/// the completion value / throws; the seam models only what a caller above it
/// needs to route: did evaluation complete or throw, and (for a thrown case) the
/// borrowed error message. Kept a tagged union rather than a Zig error so a
/// thrown JS exception (an ordinary runtime outcome, not a host failure) does not
/// collapse into the same channel as "the host could not run the engine at all".
pub const EvalResult = union(enum) {
    /// The script ran to completion. `value` is a borrowed textual rendering of
    /// the completion value (for the stub / for logging); a real engine grows a
    /// richer value handle here when it binds.
    completed: []const u8,
    /// The script threw. `message` is a borrowed rendering of the thrown value
    /// (valid only for the duration of the `evaluate` call).
    threw: []const u8,
};

/// A host object/function a bound engine must expose to page script (e.g. the
/// `window.wezig` provider surface). This is the NARROW, engine-agnostic slice
/// of the wide binding surface the seam pins now: the caller names a binding and
/// hands over a context + callback; how a concrete engine wires it into its DOM
/// wrappers, GC rooting, and value marshalling is engine-specific and grows
/// behind the seam (see the caveat at the top of this file). `onCall` receives
/// the string argument the page passed and returns a string result — a
/// deliberately COARSE shape that stands in for "native code the page can call"
/// without committing to one engine's value-type ABI.
pub const HostBinding = struct {
    ctx: *anyopaque,
    onCall: *const fn (ctx: *anyopaque, arg: []const u8) []const u8,
};

/// The `ScriptEngine` seam value: a context pointer plus a function-pointer
/// table, exactly like `Renderer` (ADR-0005/0006) and `PaintBackend` (ADR-0002).
/// Construct an engine, obtain this value from it, and hand it to the caller; the
/// caller talks only to these methods and never learns which engine (bound
/// SpiderMonkey/JSC/V8, or a later Zig-native `kiesel`) is behind it.
pub const ScriptEngine = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Evaluate `source` as a script in the engine's context and report the
        /// outcome. `source` is borrowed for the call; the returned
        /// `EvalResult`'s borrowed slices are valid only until the next engine
        /// call (a real engine copies out of its GC heap; the stub returns its
        /// own stored copy).
        evaluate: *const fn (ctx: *anyopaque, source: [*:0]const u8) EvalResult,

        /// Expose `binding` to page script under the global name `name` (e.g.
        /// `wezig`), so page code can call into native. This is the ONE
        /// host-binding hook the minimal seam pins; the full DOM/GC/event-loop
        /// binding surface grows behind the seam with a real engine (see caveat).
        /// At most one binding per name; a later call with the same name
        /// replaces it.
        exposeHostBinding: *const fn (ctx: *anyopaque, name: [*:0]const u8, binding: HostBinding) void,

        /// Tear down the engine's context and release its resources. After this
        /// the `ScriptEngine` value must not be used again.
        destroy: *const fn (ctx: *anyopaque) void,
    };

    // Thin forwarders so callers write `engine.evaluate(...)` not
    // `engine.vtable.evaluate(engine.ptr, ...)`.
    pub fn evaluate(self: ScriptEngine, source: [*:0]const u8) EvalResult {
        return self.vtable.evaluate(self.ptr, source);
    }
    pub fn exposeHostBinding(self: ScriptEngine, name: [*:0]const u8, binding: HostBinding) void {
        self.vtable.exposeHostBinding(self.ptr, name, binding);
    }
    pub fn destroy(self: ScriptEngine) void {
        self.vtable.destroy(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// A trivial stub `ScriptEngine` (this task): proves the seam holds WITHOUT
// binding a real engine. It executes NO JavaScript — it records what it was
// asked to do so the seam's shape is testable headlessly.
// ---------------------------------------------------------------------------

/// A no-op `ScriptEngine` that satisfies the seam so it compiles and its
/// contract can be asserted in `zig build test` with no bound engine, no DOM, no
/// event loop. It does NOT run JavaScript: `evaluate` echoes the source back as a
/// `.completed` value (except the one sentinel `throw` marker, so the `.threw`
/// arm is exercised too) and remembers the last source; `exposeHostBinding`
/// records the binding and can be INVOKED via `callHostBinding` to prove the
/// native-callback direction round-trips. Binding a real engine (SpiderMonkey /
/// JSC / V8, or later `kiesel`) is the follow-on build (ADR-0013).
pub const StubScriptEngine = struct {
    gpa: std.mem.Allocator,
    /// The last script `evaluate` was asked to run (owned copy), or null.
    last_source: ?[]const u8 = null,
    /// The single registered host binding name (owned copy), if any.
    binding_name: ?[]const u8 = null,
    binding: ?HostBinding = null,
    /// Whether `destroy` has been called (so a test can assert teardown ran).
    destroyed: bool = false,

    pub fn init(gpa: std.mem.Allocator) StubScriptEngine {
        return .{ .gpa = gpa };
    }

    /// Free the stub's owned bookkeeping. Separate from the seam's `destroy`
    /// (which only flips `destroyed`), so tests can inspect state after teardown
    /// and still release memory deterministically.
    pub fn deinit(self: *StubScriptEngine) void {
        if (self.last_source) |s| self.gpa.free(s);
        if (self.binding_name) |s| self.gpa.free(s);
    }

    pub fn engine(self: *StubScriptEngine) ScriptEngine {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Simulate page script calling the registered host binding `name` with
    /// `arg` (the native-callback direction). Returns what native served, or
    /// null if no matching binding is registered. Stands in for what a bound
    /// engine does when page code invokes an exposed native function.
    pub fn callHostBinding(self: *StubScriptEngine, name: []const u8, arg: []const u8) ?[]const u8 {
        if (self.binding_name) |registered| {
            if (std.mem.eql(u8, registered, name)) {
                if (self.binding) |b| return b.onCall(b.ctx, arg);
            }
        }
        return null;
    }

    const vtable = ScriptEngine.VTable{
        .evaluate = evaluate,
        .exposeHostBinding = exposeHostBinding,
        .destroy = destroy,
    };

    /// Sentinel source the stub treats as "this script threw", so the `.threw`
    /// arm of `EvalResult` is exercised without a real engine. Everything else
    /// is echoed back as `.completed`.
    const throw_marker = "throw";

    fn evaluate(ctx: *anyopaque, source: [*:0]const u8) EvalResult {
        const self: *StubScriptEngine = @ptrCast(@alignCast(ctx));
        const slice = std.mem.span(source);
        if (self.last_source) |s| self.gpa.free(s);
        self.last_source = self.gpa.dupe(u8, slice) catch null;
        if (std.mem.eql(u8, slice, throw_marker)) {
            return .{ .threw = "Error: stub thrown" };
        }
        // Echo the (owned) source back as the completion value so a caller can
        // assert the round-trip; a real engine returns the JS completion value.
        return .{ .completed = self.last_source orelse slice };
    }

    fn exposeHostBinding(ctx: *anyopaque, name: [*:0]const u8, binding: HostBinding) void {
        const self: *StubScriptEngine = @ptrCast(@alignCast(ctx));
        if (self.binding_name) |s| self.gpa.free(s);
        self.binding_name = self.gpa.dupe(u8, std.mem.span(name)) catch null;
        self.binding = binding;
    }

    fn destroy(ctx: *anyopaque) void {
        const self: *StubScriptEngine = @ptrCast(@alignCast(ctx));
        self.destroyed = true;
    }
};

test "ScriptEngine seam: the stub evaluates a script and records the source" {
    var se = StubScriptEngine.init(std.testing.allocator);
    defer se.deinit();
    const eng = se.engine();

    const res = eng.evaluate("1 + 1");
    switch (res) {
        .completed => |v| try std.testing.expectEqualStrings("1 + 1", v),
        .threw => try std.testing.expect(false),
    }
    // The stub remembered the last source it was asked to run.
    try std.testing.expect(se.last_source != null);
    try std.testing.expectEqualStrings("1 + 1", se.last_source.?);
}

test "ScriptEngine seam: a thrown script surfaces on the .threw arm" {
    // The seam models a thrown JS exception as an ordinary runtime OUTCOME
    // (the `.threw` arm), NOT a host failure — so a caller can route it without
    // it collapsing into "the engine could not run at all".
    var se = StubScriptEngine.init(std.testing.allocator);
    defer se.deinit();
    const eng = se.engine();

    const res = eng.evaluate("throw");
    switch (res) {
        .completed => try std.testing.expect(false),
        .threw => |msg| try std.testing.expectEqualStrings("Error: stub thrown", msg),
    }
}

test "ScriptEngine seam: an exposed host binding round-trips a page->native call" {
    // The wide DOM-coupled surface is NOT modelled here (see the file caveat);
    // this proves only the ONE minimal host-binding hook the seam pins: page
    // script names a native binding and calls into it, native replies. Mirrors
    // what `window.wezig.<fn>()` will do over a real engine, proven here
    // headlessly (no bound engine, no DOM, no event loop).
    const Native = struct {
        got_arg: [32]u8 = undefined,
        got_arg_len: usize = 0,
        fn onCall(ctx: *anyopaque, arg: []const u8) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(self.got_arg[0..arg.len], arg);
            self.got_arg_len = arg.len;
            return "native-reply";
        }
    };

    var se = StubScriptEngine.init(std.testing.allocator);
    defer se.deinit();
    const eng = se.engine();

    var native = Native{};
    eng.exposeHostBinding("wezig", .{ .ctx = &native, .onCall = Native.onCall });
    try std.testing.expectEqualStrings("wezig", se.binding_name.?);

    const reply = se.callHostBinding("wezig", "hello-from-page").?;
    try std.testing.expectEqualStrings("native-reply", reply);
    try std.testing.expectEqualStrings("hello-from-page", native.got_arg[0..native.got_arg_len]);

    // An unregistered name is not served (proves the name gate).
    try std.testing.expect(se.callHostBinding("other", "x") == null);
}

test "ScriptEngine seam: destroy tears the engine down through the vtable" {
    var se = StubScriptEngine.init(std.testing.allocator);
    defer se.deinit();
    const eng = se.engine();

    try std.testing.expect(!se.destroyed);
    eng.destroy();
    try std.testing.expect(se.destroyed);
}
