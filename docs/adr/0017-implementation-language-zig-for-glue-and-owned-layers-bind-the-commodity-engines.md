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
  parts of Firefox prove it at browser scale. Rejected as a SWITCH now — not
  because Rust is worse in the abstract, but because (a) the memory-safety win is
  largely recoverable for wezig via PROCESS ISOLATION + fuzzing on the small
  attacker-facing surface (see Consequences), (b) Rust's C++ interop (the thing
  wezig does constantly) is materially MORE friction than Zig's, and (c) switching
  discards the validated Zig foundation for a multi-quarter rewrite with the seams
  already bounding the risk. Re-evaluate only if the memory-safety posture below
  proves insufficient in practice.
- **C++.** What Chromium/WebKit/Ladybird(historically) use; maximal ecosystem and
  the native tongue of the engines wezig binds. Rejected: it gives up the
  safety-checked builds + ergonomics Zig has, for a language wezig would only want
  for parity with the libs it is deliberately NOT rewriting. Binding C++ from Zig
  is the pragmatic middle.
- **Swift.** Notable because **Ladybird's maintainer publicly chose Swift for NEW
  engine code, moving away from C++**, explicitly for memory-safety + modern
  ergonomics + contributor appeal (see "Learning from Ladybird"). A real signal
  about what a from-scratch engine team wants from its language. Rejected for wezig
  now: Swift's non-Apple-platform story + C++ interop maturity are weaker for a
  Linux-first, bind-everything project, and again a switch discards the Zig
  foundation. It IS the clearest external evidence that "memory-safe + modern"
  matters for this class of work — which is why the safety posture below is pinned
  rather than left implicit.

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
- **The direct data point for THIS ADR:** Ladybird chose Swift over C++ for
  memory-safety + ergonomics. wezig's answer to the same pressure is different
  (keep Zig, mitigate safety by sandbox+fuzz on a small surface) but the pressure
  is REAL and is why the posture below is a pinned consequence, not an afterthought.
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
  keeping Zig low-risk.
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
