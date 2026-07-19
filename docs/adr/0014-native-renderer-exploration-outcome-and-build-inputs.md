<!--
  ADR NUMBER COORDINATION: several sibling exploration tasks (spec
  `explore-native-renderer`: `pin-conformance-tiers` → landed 0012,
  `pin-scriptengine-seam` → landed 0013, `native-renderer-findings-and-build-plan`
  → this file) add ADRs in parallel. `0014` was the next free number when this
  branch was cut (highest existing was 0013). If a sibling landed 0014 first,
  RE-NUMBER this file (and every "ADR-0014" reference in it and in
  `docs/native-renderer-exploration-findings.md`) to the next free number at
  integration. Do not assume 0014 is free.
-->
---
status: accepted
---

# The native-renderer exploration outcome: grow `WezigRenderer` up the tiers on the pinned libraries + seams, and the build inputs it settled

The `explore-native-renderer` exploration (ADR-0011 thesis) is complete. Its
verdict: **yes, grow wezig's own `WezigRenderer` past the v0 subset toward a real
general browser** — a decade-scale, Ladybird-class effort taken as a sequence of
follow-on BUILD specs, each aimed at a NAMED conformance tier, because the six
exploration tasks proved the load-bearing hard parts (real text shaping, bound
networking + hash-verified content-addressed fetch, the native page-facing GPU
path, the user-controlled swap mechanism) work behind the existing seams, and
pinned the reversible `ScriptEngine` boundary + the library picks. The full
findings, the per-spike outcomes, the seam gap the native path revealed, and the
de-risked, SLICED build plan live in `docs/native-renderer-exploration-findings.md`;
this ADR records only the load-bearing decisions that document settles (or points
to the per-decision ADRs that pin them), so the follow-on native-renderer build
specs inherit them as fixed points.

This ADR does not re-pin the conformance tiers (ADR-0012 does that), the
`ScriptEngine` seam (ADR-0013 does that), or the `Renderer`/`PaintBackend` seams
(ADR-0005/0006/0002 do that). It records WHAT the exploration proved and the
load-bearing choices it deliberately DEFERRED to the build specs, so those are not
silently re-litigated. It is the native-renderer analogue of ADR-0007 (webview
shell) and ADR-0009 (mobile shell).

## Decisions this exploration settled

- **The conformance target is a tiered capability ladder (T0..T3), and each build
  slice aims at a named tier.** Pinned in ADR-0012 + `docs/conformance-tiers.md`:
  the page checklist DRIVES each tier, the WPT bar MEASURES/guards it, and both
  floors (a normal server-served page AND a content-addressed `ipfs://` page) ride
  EVERY rung. The build plan is keyed on these tiers, not on a WPT percentage.
- **Text shaping is HarfBuzz behind `PaintBackend`, with NO seam reshaping, and
  FreeType is sequenced AFTER the first shaping slice.** `spike-harfbuzz-shaping`
  proved one non-trivial string shapes behind the existing `PaintBackend` seam
  (ADR-0002) on the vendored stb glyph-index raster — so real shaping is an
  additive backend upgrade, not a seam change. FreeType is leant (unchanged) but
  becomes load-bearing only at the milestone needing hinting / colour fonts /
  exact HarfBuzz↔raster metric sharing (`hb_ft_font_create`). Ground truth:
  `work/notes/findings/harfbuzz-freetype-not-needed-yet-2026-07-18.md`.
- **Networking is libcurl (bound, vetted TLS, never write TLS) behind the
  `net.Fetcher` seam, with hash-verified content-addressed fetch.**
  `spike-networking-fetch-verify` proved one ordinary `https://` fetch AND one
  content-addressed fetch whose bytes are verified against the address
  (`ContentAddress.verify` / `fetchVerified`, reject on mismatch) behind one seam
  in the `PaintBackend`/`Renderer` shape. The pick + the weighed alternatives are
  recorded so they are not re-litigated. Ground truth:
  `work/notes/findings/networking-http-tls-pick-libcurl-2026-07-18.md`.
- **The native page-facing GPU leaf is `wgpu-native` (over its Vulkan backend) for
  WebGPU; WebGL is the ANGLE-style GL→native route.** `spike-page-gpu-context`
  proved one native WebGPU frame + one native WebGL frame into the offscreen
  `Surface`, picked `wgpu-native` for Zig build ergonomics (standard `webgpu.h`
  keeps Dawn a link-line alternative; its GL backend panics headless, so Vulkan),
  and ASSESSED WebGL first-class-viable via ANGLE (translate GLES to the native
  API as Chrome does) — a confidence judgment, NOT an in-spike 100%-conformance
  proof. The webview backend already serves page-GPU content today; this de-risks
  the NATIVE path only. Ground truth:
  `work/notes/findings/gpu-page-context-pick-wgpu-native-2026-07-19.md` +
  `work/notes/observations/wgpu-native-gl-backend-submit-panic-2026-07-19.md`.
- **The renderer swap is USER-CONTROLLED with NO automatic routing, proven at the
  `Renderer` seam.** `spike-native-stub-and-user-swap` supplied the native
  `WezigRenderer` static-page stub (the minimal real second backend, in the
  library `mod`) and the `RendererSwap` coordinator that re-points/re-attaches/
  re-navigates (the three ADR-0005 steps) as a backend-VALUE change, so
  `chrome_conformance` stays green. The webview is the DEFAULT; native is used
  only on a MANUAL per-page trigger (`toggle`) or a per-domain user ALLOW-LIST
  (`DomainAllowList`); manual fallback only. This is a DESIGN + mechanism proof
  the build spec promotes into product chrome, not a shipped UX.
- **The `ScriptEngine` seam is reversible: bind a mature engine first (lean
  SpiderMonkey, pending an embedding-cost eval), Zig-native (`kiesel`) later.**
  Pinned in ADR-0013 + `src/script_engine.zig` (stubbed). The load-bearing caveat
  is recorded there: unlike `Renderer`/`PaintBackend` this is a WIDE, DOM-COUPLED
  seam (constant DOM/GC/event-loop callbacks), so the swap is reversible but NOT
  cheap; the bind slice must expect an intimate binding effort. `kiesel` is a
  LATER swap-in (plausibly first on a narrow controlled-trust surface), never the
  day-one general-web engine.

## The seam gap the native path revealed (surfaced, not yet fixed)

The native `WezigRenderer` stub is the FIRST non-webview `Renderer` backend, and
standing it up CONFIRMED the gap the webview-shell exploration flagged (ADR-0007):
**the `Renderer` seam has no input/scroll/focus forwarding.** The webview view is
a live OS widget that handles input itself; a `WezigRenderer` owns no such widget
and cannot. The stub only paints a static page, so it did not yet FORCE the
extension — but the build plan makes adding it (pointer / key / wheel/scroll /
focus) the FIRST slice (`grow-renderer-seam-for-native`), BEFORE the native
backend becomes interactive, because adding input methods after two real backends
exist is a breaking change to a pinned interface. (Full detail:
`docs/native-renderer-exploration-findings.md` §5 + §7 Slice 0.)

## Load-bearing choices deferred to the build specs (surfaced, not decided)

These are recorded so the build specs make them deliberately rather than
inheriting them by accident (full detail:
`docs/native-renderer-exploration-findings.md` §7):

- **Input/scroll/focus forwarding on the `Renderer` seam** (Slice 0, highest
  priority — must land before any interactive native backend).
- **The bound JS engine** — run the embedding-cost eval FIRST; do not inherit the
  SpiderMonkey lean as a lock (JSC-reuse and V8-ergonomics cases are recorded in
  ADR-0013 for re-weighting).
- **The TLS trust-store / pinning policy**, and whether content-addressed fetches
  relax origin trust because verification moves to the hash.
- **The GPU-process / command-buffer security model** for the untrusted-page→GPU
  boundary, and whether to bind ANGLE directly or via `wgpu`/Dawn's GL-on-native
  path; the still-OPEN 2D-rasterizer pick (Skia vs lighter), partly subsumed by
  the GPU path.
- **The native `ipfs://` resolution boundary** (real CID grammar +
  gateway-vs-native-DHT) is `explore-web3-capabilities`'s, not this build's — this
  exploration proved only the fetch+verify half.
- **Promoting the swap gesture to a first-class `ChromeIntent`** (the spike
  deliberately kept it a beside-the-chrome coordinator to avoid widening a pinned
  seam), and where the persisted `DomainAllowList` file lives.

## Consequences

- The follow-on native-renderer BUILD specs are authorable from
  `docs/native-renderer-exploration-findings.md` alone, with the risky parts
  de-risked and the target tiers named; its slices (`grow-renderer-seam-for-native`
  → `build-native-static-parse-and-css` → the T1/T2/T3 parser/CSS/layout/text/
  networking/GPU/JS slices + `build-native-swap-chrome`) each build against a seam
  whose surface and deferred decisions are now recorded — the "atomically taskable
  when authored" outcome the exploration exists to produce.
- `explore-web3-capabilities` inherits concrete boundaries: the hash-verified
  `net.Fetcher` seam (it owns the CID grammar + resolution on top), and the
  user-controlled swap + per-domain-allow model for where native rendering applies.
- This is a documentation-only outcome: no renderer code changed, no real engine /
  GPU / networking library is linked into the `wezig` `mod`, and the v0 build gate
  (`zig fmt --check`, `zig build`, `zig build test`) stays green. The per-decision
  ADRs (0012, 0013) and the two seams they pin stand; this ADR neither supersedes
  nor amends them — it records the exploration's outcome and the build inputs that
  reference them.
