---
status: accepted
---

# ADR-0017's "Zig wins on interop" is LAYER-SPECIFIC, not global: for the BOUND engines it holds, but for the OWNED renderer a mature pure-Rust ecosystem lets Rust AVOID the C boundary rather than pay it worse — sharpening (not reversing) the language decision and strengthening the Rust-behind-a-seam escape hatch

ADR-0017 kept Zig as the implementation language and rejected Rust as a *switch*,
its load-bearing anti-Rust argument being "Rust's C/C++ interop is materially more
friction than Zig's `@cImport`, and wezig binds C **constantly**." That argument
carries a hidden assumption — *bind-everything* — that is TRUE for Zig (there is no
mature pure-Zig Skia/HarfBuzz/GPU stack, so Zig MUST bind C for the renderer's
commodity work) but only PARTIALLY true for Rust: for the layers wezig OWNS (the
DOM/cascade/layout/shape/paint of `WezigRenderer`) a mature pure-Rust ecosystem
exists, so a Rust renderer would NOT cross the C boundary there at all. This ADR
records that correction. It does NOT reverse ADR-0017 ("keep Zig now" stands for
all the other reasons); it SCOPES the interop claim to the bound engines and
notes that the Rust-behind-a-seam escape hatch is therefore stronger than
ADR-0017's flat interop argument implied. Raised 2026-07-20 while re-examining the
Rust trade; changes no code.

## Context — the gap in ADR-0017

ADR-0017 conceded Rust's "large ecosystem" in one line and cited Servo, but its
OPERATIVE rejection of Rust framed interop as an ALWAYS-PAID tax:

> "Rust's C/C++ interop — the thing wezig does CONSTANTLY (it binds Skia/HarfBuzz/
> SDL/libcurl/WebKitGTK/wgpu-native) — is materially MORE friction than Zig's
> `@cImport`; this is Zig's single biggest edge for a bind-everything browser."

It compared **Rust-binding-C vs Zig-binding-C** and found Zig better. It never
asked the inverting question: **what if Rust does NOT bind C for that layer?** For
Zig that question is moot — Zig has no pure-Zig alternative and must bind. For Rust
it is live for the OWNED renderer, and that is exactly the surface ADR-0017's
escape hatch is about.

## Decision

Amend how ADR-0017's interop reasoning is stated and applied:

1. **The "interop favours Zig" claim is SCOPED to the BOUND engines** — the
   commodity layers wezig binds regardless of host language: the system-webview
   backend, the JS engine (V8/SpiderMonkey — bound in BOTH worlds per ADR-0013),
   TLS/networking (libcurl), SDL, and whatever GPU/paint C library the Zig arm
   uses. Here Zig's `@cImport` edge is real and STANDS: `@cImport(@cInclude(...))`
   beats `bindgen`/`cxx`, and `zig cc`/`zig build` cross-compile those C deps
   (including the mobile static libs) more smoothly than cargo + external
   toolchains. Nothing about this ADR weakens that.

2. **For the OWNED renderer, the interop argument does NOT hold — it NEUTRALISES
   or REVERSES.** A Rust `WezigRenderer` would compose its pipeline from mature
   PURE-RUST crates and bind almost no C for the renderer internals: html5ever
   (WHATWG HTML parse), stylo/selectors (cascade), taffy (flex/grid layout),
   parley/cosmic-text/swash (text layout + shaping + rasterization — the HarfBuzz/
   FreeType job in Rust), vello + wgpu (GPU paint — the Skia/Dawn job in Rust) —
   the stack Servo ships and Blitz already composes into a modular web renderer.
   For this layer Zig BINDS C (shaping, paint) while Rust would NOT, so the
   interop cost is not "worse for Rust", it is ABSENT for Rust and PAID by Zig.

3. **JS is a WASH on this axis and stays so.** The mature Rust JS path is a binding
   (`rusty_v8`), and pure-Rust engines (e.g. Boa, ~90%+ of the spec) are not yet at
   V8/SpiderMonkey compatibility. ADR-0013 already pins "bind a mature engine
   first" regardless of host language, so JS is interop-bound in both worlds — no
   advantage either way. The renderer, not JS, is where the inversion lives.

4. **This STRENGTHENS ADR-0017's Rust-behind-a-seam escape hatch; it does not open
   a new switch.** ADR-0017's pre-agreed answer to "if the sandbox+fuzz safety
   posture proves insufficient" is "move the hotspot to Rust behind the `Renderer`
   seam." A Rust `WezigRenderer` behind that seam would (a) BUY the compile-time
   memory safety Zig lacks (ADR-0017's one serious anti-Zig point, the LLM-
   authorship lens) AND (b) NOT pay the interop tax for the renderer internals
   (this ADR). Two of the three ADR-0017 costs of "Rust for the renderer" shrink;
   even the third — Rust's ownership vs the DOM's GC-shaped object graph
   (ADR-0017 reason c) — is a SOLVED problem in the pure-Rust stack (stylo/Servo
   ship a real Rust DOM+cascade using arenas/ids/`Rc`), so it is weaker for the
   renderer specifically than ADR-0017 implied.

## Consequences

- **"Keep Zig now" is UNCHANGED.** The reasons that survive untouched: the
  validated Zig foundation (~16k green lines, the seams, the mobile cross-compiles)
  that a switch would discard; `@cImport` + `zig cc`/`zig build` for the glue and
  the engines wezig DOES bind in both worlds (webview, JS, TLS); and the accepted,
  mitigated pre-1.0 churn tax. This ADR is a scoping correction to ONE argument,
  not a reversal of the decision.
- **The `WezigRenderer` language decision (deferred, seam-gated, per-component per
  ADR-0017) now has a sharper input:** the Rust arm's disadvantage is confined to
  where it binds C (which for the renderer internals is near-zero), and its
  advantages (safety + a ready-made mature crate stack) are concentrated exactly on
  the owned renderer. When `WezigRenderer` is specced, the interop axis must be
  weighed PER LAYER, not globally.
- **Direct input to the Rust+Zig differential bake-off** (`work/notes/ideas/rust-
  zig-renderer-differential-bakeoff-ethereum-multiclient-analogy.md`): the Rust arm
  would be ASSEMBLED from mature crates (stylo/taffy/parley/vello) while the Zig arm
  is more from-scratch, so the Rust arm may reach an ADR-0012 conformance tier
  FASTER by standing on Servo's shoulders. That asymmetry is a fairness variable
  the bake-off's "guard fairness" step must account for, and a reason the Rust arm
  could win on MORE than safety.
- **A dependency-surface caveat is inherited, not erased.** "Bind almost no C for
  the renderer" trades C-interop friction for a LARGE pure-Rust dependency tree
  (stylo/servo-adjacent crates move fast and carry their own churn + supply-chain
  surface). This is a different cost, not zero cost — but it is the kind of cost
  the seam contains, and it does not touch the Zig glue.

## Note

This records the CORRECTION to ADR-0017's interop reasoning and its scope; it
changes no code and does not re-open the language decision. ADR-0017 remains the
governing language ADR (Zig for the owned glue/DOM/layout/trust logic, bind the
commodity engines, safety via sandbox+fuzz, Rust behind a seam as the escape
hatch); ADR-0013 remains the JS decision (bind-first, so JS is a wash here). The
analysis behind this ADR is in
`work/notes/ideas/rust-pure-ecosystem-erodes-the-interop-argument-for-owned-layers.md`;
the Odin evaluation that prompted the wider re-examination is in
`work/notes/ideas/odin-vs-zig-implementation-language-evaluated.md`.
