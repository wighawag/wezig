<!--
  ADR NUMBER COORDINATION: several sibling exploration tasks (spec
  `explore-native-renderer`: `pin-conformance-tiers` → landed 0012,
  `native-renderer-findings-and-build-plan`) add ADRs in parallel. `0013` was the
  next free number when this branch was cut (highest existing was 0012). If a
  sibling landed 0013 first, RE-NUMBER this file (and every "ADR-0013" reference
  in it, in `src/script_engine.zig`, and in `CONTEXT.md`/`src/root.zig` if they
  name it) to the next free number at integration. Do not assume 0013 is free.
-->
---
status: accepted
---

# The `ScriptEngine` seam: BIND a mature engine first (lean SpiderMonkey), Zig-native (`kiesel`) later

wezig needs a JavaScript runtime for dynamic pages, and full compatibility with
the real web (ADR-0011) needs a MATURE engine from day one — not a from-scratch
one. So we reach JS through a **`ScriptEngine` seam** (`src/script_engine.zig`),
the same reversibility pattern as the `Renderer` seam (ADR-0005/0006): an
interface a **BOUND** engine satisfies FIRST for compatibility, with a
**Zig-native** engine (e.g. `kiesel`) as an **aspirational later swap-in** behind
the SAME seam. For the first bound engine we compare **SpiderMonkey vs
JavaScriptCore (JSC) vs V8** and **LEAN SpiderMonkey**, pending an embedding-cost
eval. This ADR is the exploration deliverable (spec `explore-native-renderer`,
decision 3, story 5); it does NOT bind an engine — that is a follow-on build. The
seam is proven here with a trivial stub (`StubScriptEngine`).

## Why a seam at all (reversibility, as with `Renderer`)

The same argument that put `Renderer` behind a seam applies here: the engine
choice is a technology decision with lock-in, and we want to be able to change it
— specifically to grow a Zig-native engine later without rewriting everything
above the JS boundary. Binding first buys real-web compatibility now; the seam
keeps the door open to swap the engine out per the project's own-your-stack
thesis (ADR-0011). One interface, a bound engine behind it today, a different
engine behind it tomorrow.

## ⚠️ The load-bearing caveat: this seam is WIDE and DOM-COUPLED, not a thin vtable

This is the one thing a future reader MUST NOT mis-read from "it's a seam like
`Renderer`". `PaintBackend` (ADR-0002) and `Renderer` (ADR-0005) are THIN
boundaries: a few draw/measure calls, or a navigate/interact surface the caller
drives largely one-way. **A JS-engine boundary is fundamentally different.** A
running script calls BACK into the embedder constantly and at fine granularity:

- **DOM:** every property read/write and node mutation is an engine→embedder
  callback — a tight two-way conversation per statement, not one-way navigation.
- **GC:** the engine's garbage collector must trace embedder-held references
  (wrappers around DOM nodes), so object lifetime is CO-MANAGED across the
  boundary, owned cleanly on neither side.
- **event loop / microtasks:** promises, `queueMicrotask`, timers and `async`
  interleave engine execution with the host event loop — a scheduling contract,
  not call-and-return.

**Consequence:** the swap is REVERSIBLE but NOT cheap the way the `Renderer` swap
is. The real coupling lives in the DOM/GC/event-loop bindings a concrete engine
grows behind the seam, and those are engine-shaped. So we pin only the COARSE,
engine-agnostic lifecycle now (create context / evaluate / expose one host
binding / destroy) — enough to prove the boundary exists and to make the engine
choice a documented decision — and DELIBERATELY do not model the wide binding
surface until the build that binds a real engine grows it (the same
pin-the-minimal-surface discipline as ADR-0006). Pinning the binding model
speculatively would bake one engine's shape into the "neutral" seam and defeat
its purpose. This intimacy is exactly why the recommendation below weighs
**embedding ergonomics** heavily, and why the SpiderMonkey lean is explicitly
**pending an embedding-cost eval** rather than final.

## The recommendation: lean SpiderMonkey (pending an embedding-cost eval)

Three viable mature engines, weighed against three explicit criteria:

- **Independence / ethos-alignment — favours SpiderMonkey.** SpiderMonkey
  (Mozilla) is the one major engine NOT owned by a browser-platform vendor whose
  incentives are its own platform; it is also **Servo's** engine, so the
  "independent from-scratch browser embeds SpiderMonkey" path is trodden. This
  aligns with wezig's own-your-stack, don't-inherit-an-incumbent's-defaults
  thesis (ADR-0011). JSC is Apple/WebKit's; V8 is Google/Chromium's — both are
  developed primarily to serve a browser platform we are trying NOT to depend on
  by default.
- **Reuse — favours JSC.** We ALREADY link WebKit on the webview backend
  (`SystemWebviewRenderer` on WebKitGTK, ADR-0005; `WKWebView` on iOS), and JSC
  ships inside WebKit. So JSC is, in a sense, already in the process — reusing it
  would avoid pulling in a second large engine dependency. This is a real pull
  toward JSC and is why the decision is a LEAN, not a lock.
- **Raw perf + embedding ergonomics — favours V8.** V8 is the perf leader and has
  the most polished, best-documented embedding API (Node/Electron/Deno have
  exercised it hard). Given how WIDE and intimate this seam is (see caveat), the
  quality of the embedding API is not a minor convenience — it is load-bearing
  for how much the DOM/GC/event-loop bindings cost to build and maintain.

**We LEAN SpiderMonkey** because independence/ethos-alignment is the tie-breaker
that matches wezig's reason to own its stack, and SpiderMonkey has a proven
independent-browser embedding path (Servo). This is a LEAN, not a lock: it is
**pending an embedding-cost eval** that actually measures SpiderMonkey's
embedding ergonomics and binding cost against V8's (and weighs the JSC-reuse
saving). If that eval shows SpiderMonkey's embedding cost is prohibitive relative
to the independence gain, the decision reopens — the reuse (JSC) and
ergonomics/perf (V8) cases are recorded here precisely so re-deciding is a
matter of re-weighting, not re-discovering.

## The Zig-native (`kiesel`) position: aspirational later swap-in, NOT first

A Zig-native JS engine (e.g. `kiesel`) is the eventual own-the-stack ideal — but
it is explicitly **NOT** the first engine and **NOT** the general-web
compatibility engine at the start:

- **After a bound engine ships compatibility.** A from-scratch JS engine is a
  multi-year, conformance-hungry effort (the same shape as the native renderer,
  ADR-0012). It swaps in behind this seam LATER, once a bound engine has carried
  real-web compatibility — never as the day-one general-web engine.
- **Possibly FIRST for a narrow controlled-trust surface.** The plausible first
  foothold for a Zig-native engine is NOT the general web but a narrow,
  controlled-trust surface — verifiable / content-addressed / local-first content
  (ADR-0011), where the script is small, trusted-by-verification, and the
  compatibility bar is set by wezig, not by the entire existing web. There the
  reduced surface makes a young engine viable long before it could run the
  general web.
- **Never the general-web compatibility engine at the start.** Pointing a young
  Zig-native engine at the full web would fail wezig's hard compatibility
  requirement (ADR-0011). The bound engine owns general-web compatibility; the
  Zig-native engine earns surfaces incrementally behind the seam.

## Scope of THIS decision (exploration, not the build)

- **In scope (done here):** add + pin the `ScriptEngine` seam with its
  WIDE-DOM-coupled caveat documented AT the seam, prove it holds with a trivial
  stub (`StubScriptEngine`, no real engine, tests in `zig build test`), and
  record this recommendation.
- **Out of scope (follow-on builds):** binding SpiderMonkey/JSC/V8; running the
  embedding-cost eval that firms the lean into a lock; growing the wide
  DOM/GC/event-loop binding surface; building `kiesel` or wiring it to any
  surface. The v0 build gate stays green; no real engine is linked.

## Considered options

- **Bind V8 first (perf + ergonomics).** Rejected as the LEAN (not as a
  possibility): V8's ergonomics and perf are real advantages, but it is
  Chromium's engine — leaning on it as the default cuts against the independence
  thesis (ADR-0011). Kept explicitly on the table for the embedding-cost eval.
- **Bind JSC first (reuse — we already link WebKit).** Rejected as the LEAN,
  though it is the strongest pragmatic counter-argument: reusing the engine
  already inside our webview dependency avoids a second large dependency. If the
  embedding-cost eval finds SpiderMonkey too costly, the reuse case makes JSC the
  most likely fallback. It loses the lean on independence grounds (JSC is
  Apple/WebKit's, and its standalone-embedding story outside WebKit is weaker).
- **Build a Zig-native engine (`kiesel`) first.** Rejected: it cannot meet the
  hard general-web compatibility requirement (ADR-0011) for years; making it the
  day-one engine would ship an incompatible browser. It is the aspirational later
  swap-in, plausibly first on a narrow controlled-trust surface, per above.
- **No seam — hard-wire the chosen engine.** Rejected for the same reason
  ADR-0005 rejected hard-wiring the webview: it forecloses the Zig-native swap and
  bakes a reversible technology choice into every caller. The seam is the point,
  even though it is a wider, more intimate seam than `Renderer` (see caveat).
- **Pin the full DOM/GC/event-loop binding surface now.** Rejected: with no real
  engine to check it against, a speculative wide interface would encode one
  engine's binding model as the "neutral" seam and defeat the reversibility. Pin
  the minimal lifecycle; grow the binding surface with its implementation
  (ADR-0006 discipline).

## Consequences

- A new top-level `ScriptEngine` interface exists (`src/script_engine.zig`),
  re-exported from `src/root.zig`, satisfied today only by `StubScriptEngine`. A
  bound engine (leaning SpiderMonkey) and, later, a Zig-native `kiesel` implement
  the SAME interface, swapped in behind it with no caller change.
- The recommendation is a documented, re-weightable decision, not a hard-wire:
  the follow-on build that binds an engine runs the embedding-cost eval and
  either firms SpiderMonkey or, on cost grounds, re-decides toward JSC (reuse) or
  V8 (ergonomics) using the criteria recorded here.
- The seam's WIDE, DOM-coupled nature is recorded as load-bearing: whoever binds
  a real engine must expect an intimate DOM/GC/event-loop binding effort behind
  this seam, NOT a thin-vtable swap. The seam guarantees the CHOICE is reversible,
  not that the binding work is cheap.
- No real JS engine is linked by this task; the v0 gate (`zig fmt --check`,
  `zig build`, `zig build test`) stays green, with the seam's contract proven by
  the stub's tests inside `zig build test`.
