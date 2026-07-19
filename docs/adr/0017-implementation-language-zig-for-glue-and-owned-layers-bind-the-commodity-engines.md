---
status: accepted
---

# Implementation language: Zig for the glue + owned layers (DOM/layout/trust logic), bind the commodity engines; memory-safety posture is sandbox + fuzz for attacker-facing components

wezig is written in Zig (CONTEXT.md states this as fact, but no ADR ever recorded
WHY — this closes that gap, raised late-but-better-now). This ADR records the
LANGUAGE decision, its alternatives, and the load-bearing reframe that makes it a
BOUNDED, reversible bet rather than "an entire browser in a pre-1.0 language": the
SEAMS (ADR-0005/0006/0013) shrink the surface actually OWNED in Zig to the glue +
DOM/layout/cascade + the trust-model logic; the commodity engines (paint, shaping,
GPU, JS, TLS) are BOUND, not rewritten (ADR-0003 ethos). It also pins the
memory-safety POSTURE the choice obliges, because Zig is not memory-safe by
default and wezig parses the most hostile input on the web.

## Context

The question "is Zig the right choice to implement everything owned, and is there
anything to learn from Ladybird?" was raised while planning `WezigRenderer`. It is
the right time to record the decision: the language is hard to reverse once the
native engine grows, surprising to a future reader (why a pre-1.0 language for a
browser?), and the result of a real trade-off — the ADR-FORMAT trifecta.

The decision is ALSO not as large as "a whole browser in Zig", because of the
architecture already pinned:

- Painting → Skia; text shaping → HarfBuzz; GPU → wgpu-native/Dawn; windowing →
  SDL; networking/TLS → libcurl (ADR-0003 C-binding ethos, CONTEXT.md).
- JavaScript → a BOUND mature engine first (lean SpiderMonkey), a Zig-native
  engine (`kiesel`) only an aspirational later swap behind the `ScriptEngine` seam
  (ADR-0013).
- The content BACKEND is a system webview first, `WezigRenderer` swapped in behind
  the `Renderer` seam progressively (ADR-0005/0006).

So "owned in Zig" is a SHRINKING set: the glue that wires the seams, the DOM /
layout / cascade / paint-orchestration of `WezigRenderer`, and the TRUST-MODEL
logic (content-addressed origin, the wallet broker's decision layer, verification).
The language question is really "Zig for THAT scope," which is far more defensible
than "Zig for a browser".

## Decision

**Keep Zig as the implementation language for the owned layers + the glue, and
BIND mature (mostly C/C++) libraries for every commodity engine.** Do NOT
re-litigate the language wholesale now (it would trade a validated, working
foundation — the v0 pipeline + the seams + the mobile cross-compiles all exist and
are green — for a rewrite, with the seams already containing the blast radius).

Alongside, pin two consequences (below): the memory-safety posture, and the
seam-level escape hatch.

### Why Zig (for this scope)

- **Best-in-class C/C++ interop is the single best fit for wezig's strategy.**
  wezig's whole plan is BINDING C/C++ libraries; Zig's `@cImport`/`@cInclude` bind
  them with no FFI ceremony and no hand-written prototypes (already proven:
  stb_truetype, SDL3, WebKitGTK, libcurl, EGL/GLES, wgpu-native, HarfBuzz). A
  language whose C interop is a first-class feature is exactly right for a
  bind-the-commodity-engines browser.
- **`comptime` + explicit, allocator-as-value control** suits a layout/DOM engine
  and keeps allocation legible (the seams are `{ptr,vtable}` runtime values, not
  comptime types — a pattern Zig expresses cleanly).
- **A validated, working foundation already exists in Zig** — not just sunk cost
  but sunk VALIDATION: v0 HTML/CSS/layout/paint, the `Renderer`/`Toolkit`/
  `ScriptEngine`/networking seams with fakes in a display-free gate, desktop +
  iOS + Android backends, a green acceptance gate. Throwing that away has a real
  cost the alternatives must beat, and none clearly does.

### Considered alternatives (and why not now)

- **Rust.** The strongest alternative: memory-safe by default (the property most
  relevant to a browser's hostile-input surface), a large ecosystem, and Servo/
  parts of Firefox/Chromium prove it at browser scale — and, as of Feb 2026,
  Ladybird ADOPTED it (see "Learning from Ladybird"). Rejected as a SWITCH now —
  not because Rust is worse in the abstract (its memory-safety is a genuine
  advantage wezig does NOT get for free), but because (a) the memory-safety win is
  largely recoverable for wezig's SMALL owned attacker-facing surface via PROCESS
  ISOLATION + fuzzing (see Consequences), (b) Rust's C/C++ interop — the thing
  wezig does CONSTANTLY (it binds Skia/HarfBuzz/SDL/libcurl/WebKitGTK/wgpu-native)
  — is materially MORE friction than Zig's `@cImport` (Rust needs `bindgen`/`cxx`
  and non-trivial glue; this is Zig's single biggest edge for a bind-everything
  browser), (c) Rust's ownership model fits the web platform's deep-inheritance +
  GC-shaped object graph POORLY — the exact reason Ladybird itself rejected Rust in
  2024 — whereas wezig's manual-allocation style sidesteps that mismatch, and (d)
  switching discards the validated Zig foundation for a multi-quarter rewrite with
  the seams already bounding the risk. Honestly weighed, Rust is the alternative
  with the best case AGAINST this decision; re-evaluate it (behind a seam, per the
  escape hatch) if the memory-safety posture below proves insufficient in practice.
- **C++.** What Chromium/WebKit/Ladybird use as their main language; maximal
  ecosystem and the native tongue of the engines wezig binds. Rejected: it gives
  up the safety-checked builds + ergonomics Zig has, for a language wezig would
  only want for parity with the libs it is deliberately NOT rewriting. Binding C++
  from Zig is the pragmatic middle.
- **Swift.** Notable because Ladybird EVALUATED it (2024) as its memory-safe C++
  successor before rejecting it. Rejected for the SAME reasons Ladybird found:
  insufficient C++ interoperability and limited platform support outside the Apple
  ecosystem — both disqualifying for a Linux-first, bind-everything project. (This
  corrects an earlier draft of this ADR that mis-stated Ladybird as having chosen
  Swift; it evaluated Swift, then adopted Rust — see below.)

### The positive Zig-over-Rust case (why not JUST default to Rust)

The alternatives above say why not SWITCH; this says what Zig positively BUYS over
Rust for wezig's specific shape (so the choice is a reason, not inertia):

1. **C/C++ interop is night-and-day, and it is the whole strategy.**
   `@cImport(@cInclude("skia.h"))` yields bindings directly — no `bindgen`, no
   `cxx` crate, no separate FFI layer, no `unsafe extern` upkeep. For a browser
   that BINDS Skia/HarfBuzz/SDL/libcurl/WebKitGTK/wgpu-native/SpiderMonkey — i.e.
   crosses the C boundary constantly — this is Zig's single biggest, most
   defensible edge. Rust can do all of it, but every binding is friction; in Zig
   it is the happy path.
2. **Zig is also a C/C++ COMPILER + cross-compiler + build system.** `zig build`
   cross-compiles to iOS/Android/etc. out of the box (wezig already does this for
   the mobile static libs) and `zig cc` compiles the C deps for any target. Rust
   leans on cargo + external toolchains + `cc-rs`, and cross-compiling with C deps
   is fiddlier. wezig's mobile cross-compile story is materially simpler in Zig.
3. **No hidden control flow / no hidden allocation.** No implicit destructors,
   operator overloading, `Deref` magic, or default unwinding panics — what you read
   is what runs, and allocators are explicit VALUES passed in (which is why the
   seam tests catch leaks deterministically with a testing allocator).
4. **`comptime` is one simple mechanism** replacing macros + most generics + const
   generics — less magic, less to learn, no separate macro language.
5. **The web platform's object graph fits manual memory better than ownership.**
   The DOM is deep inheritance + cyclic references + GC-shaped lifetimes; Rust's
   single-owner model fights that (→ `Rc<RefCell<>>`/arenas/`unsafe`, which claws
   back much of the safety benefit anyway). This is the EXACT reason Ladybird
   rejected Rust in 2024. Zig's manual/arena allocation sidesteps the mismatch.
6. **Smaller language + faster productivity** for a small team: no borrow-checker
   to fight, no lifetime puzzles, no trait-resolution rabbit holes.

The counterweight is honest and stated elsewhere in this ADR: Rust's memory
safety + ecosystem + tooling maturity beat Zig's, and Zig's pre-1.0 churn is a
standing tax. The net: Zig wins on interop/cross-compile/legibility/object-graph
fit; Rust wins on safety/ecosystem — and for a bind-everything, Linux-first,
single-author, seam-isolated browser, Zig's wins compound daily while Rust's
biggest win (safety) is the one wezig can most credibly buy back with ARCHITECTURE
(the posture in Consequences).

### The LLM-authorship lens (the strongest single argument FOR Rust — weighed honestly)

If LLMs write most of wezig's code, the balance shifts TOWARD Rust, and this is
recorded rather than buried because it is the most serious case against this
decision:

- **Rust's compiler catches an LLM's most common failure mode.** LLMs produce
  confident-but-subtly-wrong memory handling (use-after-free, aliasing,
  forgotten cleanup, iterator invalidation). Rust REJECTS that class at compile
  time; Zig compiles it and fails at runtime (or silently in `ReleaseFast`). A
  compiler that refuses to build the unsafe version is a large safety net when the
  author does not reliably hold invariants in its head.
- **More + fresher training data.** Rust is post-1.0 and huge in the corpus; Zig
  is younger, smaller, and PRE-1.0 with breaking churn — so much Zig in training
  data is written against OLD std/language versions. wezig already felt this
  (`std.Io` reader API churn, `std.ArrayList` unmanaged, `std.posix.write` absent):
  an LLM trained on Zig 0.11–0.13 confidently writes code that fails on 0.16.
- **Richer type-level guardrails tighten the fix-loop.** More LLM mistakes surface
  as Rust type errors the model can then repair, making the
  compile-error→regenerate loop more productive.

**Can testing (which LLMs do cheaply) EMULATE Rust's safety? Partially — not
fully, and the gap is where the risk concentrates.** This is the load-bearing
nuance, because if testing fully substituted, the LLM-argument for Rust would
collapse; it does not:

- **What testing DOES catch:** deterministic reachable bugs (with `ReleaseSafe`/
  UBSan trapping), input-shaped bugs (coverage-guided fuzzing), and leaks (the
  testing allocator) — and LLMs make writing lots of tests + fuzz harnesses cheap,
  which genuinely strengthens the Zig case versus a human-authored world.
- **What it CANNOT fully emulate:** Rust PROVES safety over all inputs and all
  interleavings; testing SAMPLES them. An attacker's whole job is the path the
  tests missed (fuzzing narrows this but never closes it). CONCURRENCY DATA RACES
  are the worst case — Rust's `Send`/`Sync` eliminate them at compile time; testing
  for races is timing-dependent and unreliable, and a browser is heavily concurrent.
- **The LLM-specific trap — CORRELATED BLIND SPOTS.** If the SAME LLM writes both
  the code and the tests that are supposed to substitute for safety, the test
  suite inherits the author's blind spots (the flawed mental model that produced
  the use-after-free also fails to test that edge). Rust's borrow checker is
  valuable precisely because it is an INDEPENDENT adversary that does not share the
  author's assumptions. A self-graded test suite is not that.

**Consequence (this is what makes keeping Zig defensible UNDER LLM authorship):**
the safety buy-back must NOT rely on the author grading its own homework. It
requires (a) an INDEPENDENT adversarial safety review — a DIFFERENT model/context
reviewing specifically for memory safety, which is exactly the Gate-2 reviewer
pattern wezig already runs; (b) fuzzing as a MANDATORY CI leg, not optional;
(c) `ReleaseSafe` on security paths; and (d) PROCESS ISOLATION as the
architectural backstop — the one mitigation that does NOT inherit the LLM's blind
spots, because a contained parser crash is a topological guarantee, not a test. So
under LLM authorship the posture in Consequences is not merely good practice — it
is the load-bearing substitute for the compile-time safety the LLM-author lacks,
and "testing emulates Rust safety" is only true with an INDEPENDENT checker +
isolation, never with self-written tests alone. If, in practice, that discipline
proves insufficient, the escape hatch (move the hottest attacker-facing component
to Rust BEHIND A SEAM) is the pre-agreed answer — mirroring how Ladybird itself
ported incrementally behind interop boundaries.

## Learning from Ladybird (the most relevant sibling — recorded so the lesson is durable)

Ladybird is the closest independent, from-scratch, no-Chromium browser, so its
lessons are load-bearing:

- **VALIDATES wezig's sequencing hedge.** Ladybird had NO usable product for
  years (a from-scratch engine is multi-year). wezig's ship-on-a-system-webview-
  behind-a-seam (ADR-0005) is exactly the hedge Ladybird lacked — usability now,
  native engine in parallel. This is wezig's biggest structural advantage over the
  naive Ladybird path; keep it.
- **VALIDATES bind-the-commodity-layers.** Ladybird converged on established libs
  (Skia-class paint, HarfBuzz shaping) rather than rewriting them — the ADR-0003 /
  CONTEXT.md ethos wezig already holds.
- **The cautionary tale that makes ADR-0013 correct.** Ladybird wrote its own JS
  engine (LibJS) and hit the bottomless pit of web-COMPATIBILITY (not language
  conformance — the DOM/quirks/timing tail). wezig's ADR-0013 already absorbs this:
  BIND a mature engine first, `kiesel`-native only aspirational-later. Do NOT let
  this be reopened into "kiesel-first"; Ladybird is the evidence.
- **The direct data point for THIS ADR (and its nuance):** Ladybird spent a YEAR
  searching for a memory-safe successor to C++ — it REJECTED Rust in 2024 (arguing
  Rust's ownership model fit the web platform's deep-inheritance + GC-shaped object
  graph poorly), EVALUATED Swift (rejected: weak C++ interop + non-Apple platform
  support), then in Feb 2026 pragmatically ADOPTED Rust anyway (porting LibJS's
  lexer/parser/AST/bytecode — ~25k lines — with AI assistance, C++ staying the
  main language while Rust coexists behind interop boundaries). Two lessons for
  wezig: (1) the memory-safety PRESSURE on a from-scratch engine is real and
  sustained — which is why wezig's sandbox+fuzz posture below is a pinned
  consequence, not an afterthought; (2) even a team that went Rust kept C++ as the
  main language and ported INCREMENTALLY behind interop boundaries — which is
  exactly wezig's escape hatch (a component CAN move to a safer language behind a
  SEAM without a wholesale rewrite). Ladybird did NOT choose Zig; wezig's Zig bet
  rests on its C-interop edge + the seams shrinking the owned surface, not on
  copying Ladybird's language.
- **Do NOT copy** Ladybird's early "rewrite everything including JS" instinct or
  its lack of a shippable-now fallback — wezig has already dodged both.

## Consequences

- **Memory-safety is a FIRST-CLASS, pinned constraint for attacker-facing
  components — BECAUSE Zig is not memory-safe by default.** A browser parses the
  most hostile input on the web, and the highest-stakes surface is the wallet
  broker + the content parsers. The posture (mandatory, not optional):
  - **Process isolation / sandboxing** for the trust-critical broker is ALREADY the
    design (ADR-0015 d.5: the signing broker runs in its own process/sandbox; the
    page never holds key material). Generalise the instinct: attacker-controlled
    parsing should not share an address space with secrets, and the owned engine
    should run content parsing under OS sandboxing where the platform allows.
  - **Continuous FUZZING** of every parser that eats attacker bytes (HTML/CSS
    tokenisers, the CID/URL decoders, any wire-format the broker parses) — Zig's
    safety-checked builds + a fuzz harness are the substitute for compile-time
    memory safety. This is a build-plan obligation for `WezigRenderer` and the
    wallet build, tracked in
    `work/notes/ideas/memory-safety-posture-sandbox-and-fuzz-attacker-facing-components.md`.
  - Use Zig's `ReleaseSafe`/safety-checked builds for the security-critical paths;
    NEVER hand-roll crypto (already pinned, ADR-0015 d.3) — bind vetted primitives.
- **The seam discipline is the ESCAPE HATCH — wezig is NOT committed to "100% Zig
  forever".** The same `{ptr,vtable}` seams that swap a renderer BACKEND mean a
  future hotspot (a specific parser, a perf-critical or safety-critical component)
  COULD be implemented in Rust/C++ behind a seam without a wholesale rewrite. The
  commitment is "Zig glue + seams + bound engines", which is looser and more
  reversible than "the whole browser in Zig". This is the property that makes
  keeping Zig low-risk. A stronger form of the same escape hatch — building
  `WezigRenderer` in BOTH Rust and Zig behind the seam as a differential-testing +
  language bake-off judged by the shared ADR-0012 WPT/checklist vectors, then
  converging to one — is analysed (with the Ethereum multi-client analogy and why
  a PERMANENT two-engine commitment does NOT pay off for a single-author browser)
  in `work/notes/ideas/rust-zig-renderer-differential-bakeoff-ethereum-multiclient-analogy.md`.
  The `WezigRenderer` language is therefore a DEFERRED, seam-gated, per-component
  decision — NOT a rewrite of the existing ~16k Zig lines (most of which is
  platform/webview glue a Rust rewrite would only make harder).
- **The pre-1.0 churn tax is accepted, and already mitigated.** Zig < 1.0 breaks
  across minors (already felt: the `std.Io` streaming-reader EOF spin worked around
  in the wallet-broker child; the compiler-version guard in `build.zig`). The
  mitigation is the pinned toolchain (`build.zig.zon` `minimum_zig_version` +
  `assertZigVersion`) so a mismatched compiler fails fast, not silently. Each bump
  is a known, bounded cost.
- **Contributor pool is smaller than C++/Rust.** Accepted for now (wezig is
  single-author-led); if outside contribution becomes a goal, revisit against the
  same seam-escape-hatch argument (a specific subsystem could use a
  larger-pool language behind its seam).

## Note

This records the DECISION + its rationale + the alternatives, and is deliberately
reversible in its DETAILS (a specific component may move behind a seam to another
language) while the core stance — Zig for the owned glue/DOM/layout/trust logic,
bind the commodity engines, mitigate safety by sandbox+fuzz — is the fixed point.
It changes no code.
