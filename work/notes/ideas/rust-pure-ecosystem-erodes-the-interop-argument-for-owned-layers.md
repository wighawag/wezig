---
title: The pure-Rust ecosystem partly INVERTS ADR-0017's interop argument — for the OWNED layers (renderer, JS), Rust can AVOID the C interop wezig treats as always-paid, not just pay it worse; ADR-0017 conceded Rust's "large ecosystem" but never engaged this specific inversion
slug: rust-pure-ecosystem-erodes-the-interop-argument-for-owned-layers
---

A correction/sharpening of ADR-0017, raised 2026-07-20: "re Rust — did we consider
that while Rust has worse C interop than Zig, it has a more mature ecosystem that
can provide PURE-Rust libraries — even a JS runtime, or rendering — so you would
not PAY the interop cost at all for those layers?" This is an IDEA (pre-spec); it
changes no code and pins no ADR. It records a gap in ADR-0017's reasoning so the
Rust escape-hatch decision is made on the honest trade, not a strawman.

## The gap in ADR-0017 (accurate statement of what was and was not argued)

ADR-0017 DID mention Rust's "large ecosystem" and cite "Servo / parts of Firefox/
Chromium prove it at browser scale" — but only as a one-line concession. Its
OPERATIVE argument against Rust is interop friction, stated as an ALWAYS-PAID cost:

> "(b) Rust's C/C++ interop — the thing wezig does CONSTANTLY (it binds Skia/
> HarfBuzz/SDL/libcurl/WebKitGTK/wgpu-native) — is materially MORE friction than
> Zig's `@cImport` … this is Zig's single biggest edge for a bind-everything
> browser."

The unexamined assumption is **"bind-everything"** — that whatever the language,
wezig crosses the C boundary constantly, so worse interop is a constant tax. **That
is true for Zig BECAUSE Zig has no other option: it MUST bind C for paint/shaping/
GPU/JS since there is no mature pure-Zig Skia/HarfBuzz/V8.** For RUST the premise
partially fails: for several of the OWNED layers there exist mature PURE-RUST
libraries, so a Rust wezig would **not cross the C boundary there at all** — the
interop cost is not "worse", it is **absent**. ADR-0017 never engaged this; it
compared "Rust-binding-C" vs "Zig-binding-C" and found Zig better, without asking
"what if Rust doesn't bind C here?" That is the real question and it was skipped.

## How real is the pure-Rust option? (ground-truth 2026-07, so this is evidence not vibes)

Strong where it matters most for the OWNED layers:

- **Rendering / engine internals — genuinely strong.** The pure-Rust web-engine
  stack is real and shipping: **Servo** (stylo cascade, layout), **html5ever**
  (browser-grade WHATWG HTML parser), **selectors**, **taffy** (flexbox/grid
  layout), **parley**/**cosmic-text**/**swash** (text layout + shaping +
  rasterization — the HarfBuzz/FreeType job in Rust), **vello** + **wgpu** (GPU
  paint — the Skia/Dawn job in Rust). **Blitz** (Dioxus) already composes
  stylo+html5ever+taffy+parley+vello+wgpu into a modular ~12MB web renderer. So a
  Rust `WezigRenderer` could assemble its DOM/cascade/layout/shape/paint pipeline
  from PURE-RUST crates and **bind almost no C** — exactly the subsystem ADR-0017
  frames as owned-in-Zig. Here the interop argument doesn't just weaken, it
  **reverses**: Zig binds C for shaping/paint; Rust wouldn't.
- **JS — the honest, weaker case.** Two pure-Rust engines exist (**Boa** ~90%+ of
  the spec; and others), but they are NOT yet at V8/SpiderMonkey/JSC compatibility
  (Boa's own maintainers say so). The MATURE Rust path is still a BINDING —
  `rusty_v8` (Deno's V8 bindings). So for JS, Rust does NOT escape the C++ boundary
  today; it binds V8 much as Zig would bind SpiderMonkey. **This does not undercut
  the point — it confirms it is layer-specific:** the inversion is strong for
  rendering, weak-to-absent for JS. ADR-0013 already says "bind a mature engine
  first" regardless of host language, so JS is interop-bound in BOTH worlds and is
  a wash on this axis.

Net: the "pure-Rust avoids the interop entirely" argument is **strong and real for
the renderer stack, and a wash for JS.** That is enough to matter, because the
renderer is the single biggest owned surface and the exact thing ADR-0017's
escape-hatch is about.

## What this does to the ADR-0017 decision (and what it does NOT)

It does NOT overturn "keep Zig now." Three ADR-0017 reasons survive untouched:

- **The validated foundation is Zig** (~16k green lines, seams, mobile cross-
  compiles). Switching still discards that.
- **Cross-compile / build**: `zig cc` + `zig build` for the C deps wezig DOES still
  bind (SDL, libcurl, the webview, V8-if-chosen) remains a Zig edge.
- **`@cImport` for the glue + the engines still bound** (webview backend, V8/
  SpiderMonkey, TLS) is real and constant regardless of the pure-Rust renderer.

But it DOES change the SHAPE of the Rust case in a way ADR-0017 got subtly wrong,
and this is the correction worth recording:

1. **ADR-0017 overstates interop as a UNIFORM anti-Rust argument.** It is uniform
   for the ENGINES WE BIND (paint/GPU/JS-via-V8), but it is INVERTED for the
   RENDERER LOGIC WE OWN, because pure-Rust crates let Rust skip the C boundary
   there entirely. The ADR should say "interop favours Zig for the BOUND engines;
   for the OWNED renderer the pure-Rust ecosystem NEUTRALISES or REVERSES it" —
   not a flat "Rust interop is worse, therefore Zig".
2. **It strengthens exactly the escape hatch ADR-0017 already names.** ADR-0017's
   pre-agreed answer to "if the safety posture proves insufficient" is "move the
   hotspot to RUST BEHIND A SEAM." This note makes that hatch MORE attractive, not
   less: a Rust `WezigRenderer` behind the `Renderer` seam would (a) buy the
   compile-time memory safety (the one thing Zig lacks, per ADR-0017's LLM lens),
   AND (b) NOT pay the interop tax for the renderer internals, because it would
   compose stylo/taffy/parley/vello/wgpu rather than bind C. The two headline
   costs of "Rust for the renderer" — safety-you-give-up (none; you GAIN it) and
   interop-friction (largely absent for this layer) — both shrink. The main
   remaining Rust cost for the renderer is the object-graph-fit one (ADR-0017
   reason c: Rust's ownership vs the DOM's GC-shaped graph) — but that is a SOLVED
   problem in the pure-Rust stack (stylo/Servo already ship a real DOM+cascade in
   Rust using arenas/ids/`Rc`), so even that objection is weaker than ADR-0017
   implies for the RENDERER specifically.
3. **It feeds the bake-off note directly.** `rust-zig-renderer-differential-
   bakeoff-*` proposes building `WezigRenderer` in BOTH languages behind the seam.
   This note supplies a missing input to that: the Rust arm would likely be
   ASSEMBLED from mature crates (stylo/taffy/parley/vello) rather than written
   from scratch, which changes the velocity + risk math of the bake-off (the Rust
   arm may reach a conformance tier FASTER by standing on Servo's shoulders, while
   the Zig arm is more from-scratch). That asymmetry is exactly the kind of thing
   the bake-off's "guard fairness" step must account for — and it is a reason the
   Rust arm could win on MORE than safety.

## Conclusion / recommendation

The original conclusion stands and is if anything REINFORCED: **Zig stays the glue
now; Rust is the escape target behind a seam.** But the WHY is corrected —

> Rust's disadvantage vs Zig is real for the ENGINES wezig BINDS, but for the
> OWNED renderer the mature pure-Rust ecosystem (Servo/stylo/taffy/parley/vello/
> wgpu) lets Rust AVOID the C interop rather than pay it worse — so "Zig wins on
> interop" is layer-specific, not global, and the seam-gated Rust renderer is a
> STRONGER option than ADR-0017's flat interop argument implies.

Suggested durable home (a human/`to-spec` call): amend ADR-0017's Rust bullet + the
"positive Zig-over-Rust case #1" to scope the interop claim to the BOUND engines,
and add one line to the escape-hatch consequence noting the pure-Rust renderer
stack as a reason the Rust-behind-a-seam option is attractive on interop too, not
only on safety. JS stays a wash (bound in both worlds, per ADR-0013).

Related: ADR-0017 (the decision this sharpens), ADR-0013 (bind-JS-first — why JS is
a wash here), ADR-0012 (conformance tiers = the bake-off oracle),
`work/notes/ideas/rust-zig-renderer-differential-bakeoff-ethereum-multiclient-analogy.md`
(this note is a direct input to the Rust arm's velocity/risk math),
`work/notes/ideas/odin-vs-zig-implementation-language-evaluated.md`.
