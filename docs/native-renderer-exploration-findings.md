# Native-renderer exploration: findings + de-risked, sliced build plan

This is the CONFIDENCE deliverable of the `explore-native-renderer` exploration
(stories 6–7): a durable, grounded report of what the six exploration tasks
LEARNED about growing wezig's own `WezigRenderer` past the v0 subset toward a
real general browser, plus a de-risked, SLICED build plan for the follow-on
native-renderer BUILD specs. An exploration's "done" is CONFIDENCE + a plan, not
a shipped renderer — matching an incumbent browser is a decade-scale,
Ladybird-class effort that is many follow-on build specs (spec
`explore-native-renderer`; ADR-0011). So THIS document — not the spike code — is
what a human or agent reads to author those build specs with the renderer's real
shape, the risky parts already de-risked, and the target tiers already named.

It is the native-renderer analogue of `docs/shell-exploration-findings.md` (which
fed the desktop shell build plan) and `docs/mobile-exploration-findings.md` (the
mobile one). The load-bearing DECISIONS the exploration settled are pinned in the
per-decision ADRs the spike tasks produced (ADR-0012 conformance tiers, ADR-0013
`ScriptEngine` seam) and in the companion **ADR-0014**, which records the
exploration's outcome and points here. Every claim below traces to something a
task actually observed or a verified finding under `work/notes/findings/`; those
are cited inline. Where a task settled a concrete library or made a judgement
call, its finding note is the ground truth.

The six exploration tasks, and what each delivered:

- `pin-conformance-tiers` (story 1): the general-browser conformance target as a
  TIERED capability ladder — T0..T3, each a page checklist + a WPT-subset bar.
  Landed as **ADR-0012** + `docs/conformance-tiers.md`.
- `spike-harfbuzz-shaping` (stories 2, 6): real HarfBuzz text shaping behind the
  `PaintBackend` seam on one string, plus the FreeType-needed-yet note.
- `spike-networking-fetch-verify` (stories 2, 6): one ordinary `https://` fetch
  AND one hash-verified content-addressed fetch behind a `net.Fetcher` seam; the
  bound HTTP+TLS library pick.
- `spike-page-gpu-context` (stories 3, 6): one native WebGPU frame + one native
  WebGL frame, the Dawn-vs-`wgpu-native` pick, and the ANGLE-style WebGL-route
  assessment.
- `spike-native-stub-and-user-swap` (stories 4, 6): the native `WezigRenderer`
  static-page stub + the USER-controlled swap mechanism + the per-domain-allow
  data model at the `Renderer` seam.
- `pin-scriptengine-seam` (stories 5, 6): the reversible `ScriptEngine` seam
  (stubbed) + the SpiderMonkey/JSC/V8 bind recommendation + the `kiesel`-later
  position. Landed as **ADR-0013** + `src/script_engine.zig`.

---

## 1. The pinned conformance target: a tiered capability ladder (T0..T3)

The exploration's first job (story 1) was to turn "grow toward a real general
browser" from a vibe into a measurable goal, so the build plan below can aim each
slice at a NAMED rung. That target is pinned in **ADR-0012** and operationalised
in `docs/conformance-tiers.md`; this section only summarises it as the plan's
spine (read those two for the full checklists + bars + rationale).

- **T0 — Fixed v0 subset (DONE).** Exactly `docs/v0-subset.md`: the subset
  tokenizer + allowlist tree builder, a real cascade on ten CSS properties,
  block/inline flow, software text via `stb_truetype`. No WPT bar (there is no
  real parser to run it against); guarded by the goldens + the doc-drift test
  (`src/docs.zig`). The ladder's floor the higher tiers extend, not an aspiration.
- **T1 — Real static documents.** Real WHATWG parse + core CSS + HarfBuzz Latin
  shaping → correct static block/inline layout of REAL pages. WPT: ≥ 90 % HTML
  tree-construction, ≥ 70 % core CSS static-layout areas.
- **T2 — Full static layout.** Floats/flex/grid/tables + positioning + full
  complex-script/bidi shaping → MOST static real pages. WPT: ≥ 85 % static-layout
  areas, ≥ 80 % text/bidi.
- **T3 — Interactive sites.** `ScriptEngine` (bound engine first) + networking +
  dynamic DOM → interactive real sites. WPT: ≥ 75 % DOM / HTML-scripting / fetch
  areas.

Two framing facts the build plan inherits and MUST NOT re-litigate:

- **The page checklist DRIVES each tier; the WPT bar MEASURES and guards it.** A
  tier is "reached" when its full page checklist renders correctly; the WPT
  pass-rate is the objective SECONDARY regression meter, never the roadmap driver
  (ADR-0012, "The role of WPT %"). Follow-on specs pick work by "which
  representative page does not render yet", not "which WPT directory scores
  lowest".
- **Every tier carries BOTH floors at the SAME rung — a normal server-served
  page AND a content-addressed (`ipfs://`) static page.** The verifiable /
  content-addressed thesis (ADR-0011) is not deferred to a final tier; it rides
  every rung, from a T1 `ipfs://` static site to a T3 `ipfs://` interactive
  frontend. The build slices below therefore always grow the content-addressed
  path in lockstep with the server-web path.

---

## 2. Text shaping: HarfBuzz behind `PaintBackend` works — and FreeType is not needed YET

`spike-harfbuzz-shaping` proved the PINNED shaping library on the narrowest real
case and answered the one open question (does HarfBuzz force FreeType in yet?).
Ground truth: `work/notes/findings/harfbuzz-freetype-not-needed-yet-2026-07-18.md`
(HarfBuzz 10.2.0 via pkg-config, the vendored `stb_truetype` v1.26, Roboto-Regular
on the dev box).

**What landed (proven).** HarfBuzz is bound and shapes ONE non-trivial string
behind the existing `PaintBackend` seam (ADR-0002), painting into the offscreen
`Surface` the v0 goldens target (ADR-0003). The spike shapes the `office`
`ffi`/`fi` ligature — glyph id 1834, a glyph the v0 codepoint path never selects
for that ASCII input — and it differs pixel-for-pixel from the v0 `stb` render,
proving the shaping path is load-bearing (`src/harfbuzz_spike.zig`, the
`harfbuzz-shape-test` step). The v0 `stb_truetype` glyph-by-glyph path is NOT
removed; it stays the v0/fallback path.

**The seam already hosts real shaping.** HarfBuzz does the SHAPING (bytes + font
→ a run of positioned glyph IDs, with GSUB ligatures / kerning / contextual
substitution applied); the rasteriser's only remaining job is "glyph ID →
coverage bitmap", which the vendored `stb_truetype` already exposes BY GLYPH
INDEX (`stbtt_GetGlyphBitmap` / `stbtt_GetGlyphHMetrics`). So the SAME face
rasterises HarfBuzz's shaped output with no new rasteriser and no FreeType. The
important structural finding: **the `PaintBackend` seam needs no reshaping to
host real shaping** — real shaping is an additive backend upgrade behind the seam
ADR-0002 already pinned, not a seam change.

**FreeType is leant, but SEQUENCED after the first shaping slice.** Decision 2
LEANs FreeType to pair with HarfBuzz; the spike finds FreeType is NOT required
for the shaping proof itself, and records exactly where it DOES become
load-bearing (do not skip it in the plan): hinting / grid-fitting at small sizes
(stb has no hinting); colour / bitmap / `COLR`-`CPAL` fonts and emoji (stb does
not rasterise these); and exact HarfBuzz↔raster metric agreement — the production
path wants ONE source of truth for outlines + metrics, and the canonical pairing
is HarfBuzz over a FreeType `FT_Face` (`hb_ft_font_create`), so shaper and
rasteriser share identical metrics/hinting (the spike's two-independent-rasterisers
arrangement is a spike shortcut, not a subsystem design).

**Recommendation for the plan (from the finding):** pin FreeType as leant
(unchanged), but introduce it at the shaping milestone that needs
hinting/colour-fonts/exact metric sharing — the FIRST shaping milestone can stand
on stb glyph-index raster to keep the slice small. This is why the text slice
below splits into "Latin shaping on stb raster (T1)" then "FreeType raster +
complex script (T2)".

---

## 3. Networking: bind libcurl (never write TLS) + hash-verified content-addressed fetch

`spike-networking-fetch-verify` proved the PINNED networking direction — "BIND a
vetted HTTP + TLS stack, NEVER write TLS" — on two fetches, and settled the
concrete library pick. Ground truth:
`work/notes/findings/networking-http-tls-pick-libcurl-2026-07-18.md` (libcurl
8.14.1, OpenSSL/3.5.6 TLS backend, HTTP/2 via nghttp2, bound through Zig 0.16 C
interop; the offline hash-verify half proven in the display-free `zig build test`
gate).

**The pick: libcurl.** libcurl is the HTTP client; its TLS is terminated by a
vetted TLS library chosen at curl build time (OpenSSL on the dev box/CI, with
GnuTLS / BoringSSL / wolfSSL as drop-in curl backends). wezig writes ZERO TLS,
exactly what decision 2 requires, and libcurl binds cleanly through Zig C interop
— the same C-library-binding strategy the repo already uses for
Skia/FreeType/HarfBuzz/SDL. The alternatives were weighed and recorded so they
are not re-litigated: Zig std `std.http.Client` + a bound TLS lib (rejected — its
TLS story is in flux and cuts against "never own TLS"); a Rust client + rustls
(rejected now — a Rust toolchain + a second FFI boundary for no floor-level
gain); hand-rolled HTTP over raw OpenSSL (rejected — more HTTP semantics to own
for no gain over libcurl).

**Both fetches sit behind ONE small seam, `net.Fetcher`** (`src/networking.zig`)
— a `{ ptr, vtable }` boundary in the SAME shape as `PaintBackend` and `Renderer`
— so a future `WezigRenderer` and `explore-web3-capabilities` extend one
boundary, not scattered call sites:

- **The compatibility floor** is one ordinary `https://` fetch of `example.com`
  through the bound libcurl+TLS stack (`CurlFetcher` in `src/networking_spike.zig`,
  proven in the `-Dnetworking-live networking-fetch-test` step / the `networking`
  CI leg).
- **The thesis** is `ContentAddress.verify` + `fetchVerified` (same file): content
  is trusted because it HASHES to its address (SHA-256, the multihash default for
  IPFS CIDv1 raw), not because a server served it (ADR-0011). On a hash mismatch
  the bytes are freed and `error.HashMismatch` is returned, so a caller can NEVER
  observe unverified content-addressed bytes. This half is pure Zig (std crypto)
  and runs OFFLINE in the core gate with a fake in-memory fetcher — the
  load-bearing proof does not depend on network reachability. libcurl is linked
  only into the spike's test exe, never the `wezig` `mod` or the mobile
  cross-compiles (the provisioned-leg discipline of ADR-0007).

**What the spike deliberately did NOT settle (build-plan inputs, from the
finding):** the full IPFS story (real CID grammar — multibase/multihash/codec/
version decoding — and gateway-vs-native-DHT resolution; the `ContentAddress` +
`HashAlgo` enum are shaped so a CID parser and extra hashes slot in WITHOUT
changing the `verify` contract; `explore-web3-capabilities` owns native
`ipfs://`); the full networking layer (caching, cookies, redirect/proxy policy,
connection pooling, streaming to the parser, cancellation, async/event-loop
integration — `CurlFetcher` is a blocking one-shot GET); and the TLS
trust-store / pinning policy (whether content-addressed fetches relax origin
trust because verification moves to the hash is a design decision for the plan).

---

## 4. Page-facing GPU: pick `wgpu-native` (WebGPU) + the ANGLE route is first-class-viable (WebGL)

`spike-page-gpu-context` proved the NATIVE page-facing GPU path on the narrowest
case (one WebGPU frame + one WebGL frame, each into the offscreen `Surface` a
page `<canvas>` would present, read back and pixel-verified) and settled its two
open questions. Ground truth:
`work/notes/findings/gpu-page-context-pick-wgpu-native-2026-07-19.md` (wgpu-native
v25.0.2.2 over lavapipe Vulkan; WebGL via EGL surfaceless + GLES 2.0), plus the
backend caveat in
`work/notes/observations/wgpu-native-gl-backend-submit-panic-2026-07-19.md`.

> **Two-backends reality (ADR-0005), stated first so nothing below is misread:**
> the SYSTEM-WEBVIEW backend already ships working WebGL/WebGPU TODAY, so
> page-GPU content (e.g. games) runs in wezig NOW via the webview. This spike
> de-risks the NATIVE `WezigRenderer` GPU path ONLY — the path wezig needs when a
> page is rendered natively rather than in the webview. The webview keeps serving
> page-GPU content until the native path reaches its target tier.

**WebGPU leaf: `wgpu-native` (over its Vulkan backend).** Run against whichever of
Dawn / wgpu-native stands up FASTEST in Zig for a one-frame path, and record the
pick (resolved decision 2). Pick = `wgpu-native`, because:

- **Build ergonomics in Zig (the deciding factor).** wgpu-native ships a PREBUILT
  `libwgpu_native.{so,a}` + the standard C headers (`webgpu.h`, `wgpu.h`), which
  drop straight into Zig `@cImport` + `linkSystemLibrary` — no C++ toolchain, no
  GN/`depot_tools`, no multi-GB source build. Dawn is a Chromium-family C++/GN
  project, materially more setup to stand a one-frame path up from in Zig.
- **WebGPU API currency + swappability.** wgpu-native tracks the current
  `webgpu.h`, and the SAME `webgpu.h` is what Dawn exposes — so the seam is
  written against the STANDARD header, keeping the leaf itself swappable (Dawn
  later is a link-line change, not an API rewrite).
- **Cross-compile / maintenance.** Per-target release archives (Linux/macOS/
  Windows, x86_64/aarch64) make CI provisioning a `curl | unzip`; actively
  maintained (gfx-rs), pure C ABI outward, fitting the repo's C-binding strategy.
- **Backend caveat (load-bearing).** wgpu-native's OpenGL(ES) backend PANICS on
  `wgpuQueueSubmit` headless (even a clear-only pass); the Vulkan backend is
  clean (lavapipe in CI, native ICDs on real machines) and is what the frame
  proof uses. So the pick is "wgpu-native over its VULKAN backend", not GL. This
  is a spike-informed recommendation, NOT a final pin — the build may re-benchmark
  Dawn once a trusted prebuilt exists, or reassess the GL backend on an upstream
  fix — but the leaf IS chosen (choosing it is part of de-risking).

**WebGL: ASSESSED first-class-viable via the ANGLE-style route (confidence, NOT
in-spike proof).** Per resolved decision 1(a), the spike delivers (i) one working
WebGL frame + (ii) an evidence-grounded judgement; it does NOT claim "100%
conformant + performant proven" (that is a multi-year BUILD claim):

- **(i) The one frame (proven).** `WebGlContext` (`src/gpu_page_spike.zig`) makes
  a headless EGL surfaceless + OpenGL ES 2.0 context, compiles a GLSL-ES shader
  pair, draws one full-viewport triangle into an FBO, and reads it back into the
  offscreen `Surface` (centre pixel is the shader's blue, not the clear colour).
  WebGL 1.0 IS GLES 2.0 and WebGL 2.0 IS GLES 3.0, so a headless GLES2 frame is a
  frame on the EXACT substrate a native WebGL implementation targets.
- **(ii) The assessment (grounded in ANGLE).** Chrome/Chromium do NOT ship a
  bespoke WebGL renderer: they implement WebGL by translating the WebGL (≈ GLES)
  command stream through **ANGLE** onto the platform's native GPU API — ANGLE
  translates GLES 2.0/3.0/3.1 to Vulkan, desktop GL, Direct3D 9/11, and Metal
  (angleproject.org; chromium.googlesource.com/angle/angle). Safari and Firefox
  use ANGLE too. This is the industry's PROVEN route to first-class, conformant,
  performant WebGL: translate GLES to the native API ANGLE already supports and
  inherit ANGLE's Khronos GLES conformance, rather than hand-writing a GL stack
  per OS. For wezig the route is: bind ANGLE (or, longer term, target `wgpu`/Dawn's
  GL-on-native path) as the WebGL backend, mapping GLES to Vulkan on
  Linux/Android, D3D11 on Windows, Metal on macOS/iOS — mirroring Chrome. The
  spike's direct EGL/GLES frame is the substrate END of that route; ANGLE is the
  translation END the build ADOPTS rather than reinvents.
- **Named risks / costs (per the bar):** ANGLE is a large C++/GN dependency (the
  same integration class as Dawn — a prebuilt/vendored ANGLE eases it);
  conformance is INHERITED but not free (wezig must run the WebGL CTS on top of
  ANGLE and fix the wezig-side glue — context creation, canvas sizing, extension
  exposure, robustness); performance depends on the native-API path ANGLE picks
  and on avoiding readback stalls (the spike used software rasterisers, so it
  proves CORRECTNESS of the route, not performance — performance is a real-GPU
  build measurement); and security needs the GPU-process / command-buffer
  isolation Chrome uses (untrusted page → GPU), a first-class build concern under
  ADR-0011's trust posture.
- **Judgement (confidence):** the ANGLE-style GL→native route is the same route
  every shipping browser uses, it is open-source and liberally licensed, and the
  spike proved the GLES substrate frame works natively headless. So reaching full
  WebGL conformance + performance via this route is CREDIBLE/VIABLE — the build
  cost is ANGLE integration + the WebGL CTS + the GPU-process security model, NOT
  inventing a GL stack. The build plan scopes WebGL as "integrate ANGLE + prove
  conformance/perf", never "hand-write a GL backend".

**Where the GPU spike sits + what it is NOT.** `wgpu-native` + EGL/GLES are linked
ONLY into the spike's test exe (not re-exported from `src/root.zig`), so they
never enter the `wezig` library `mod`, the desktop consumers, or the mobile
cross-compiles; the live render legs are `-Dgpu-live` (the `gpu` job) and stay
OUT of the display-free gate. It is NOT the Canvas/WebGL/WebGPU subsystem: no
canvas element, no WebGL/WebGPU JS API, no swapchain/windowing, no
bind-groups/textures beyond the one triangle — those are the follow-on build this
spike de-risks. The 2D-rasterizer pick (Skia vs lighter) remains an OPEN,
deliberately-not-spiked pick (spec Out of Scope), partly subsumed by this GPU
path; the build plan carries it as a decision, not a finding.

---

## 5. The user-controlled swap: mechanism + per-domain-allow model proven, and the seam gap

`spike-native-stub-and-user-swap` proved decision 4's policy — USER-CONTROLLED,
NO automatic routing — at the `Renderer` seam (ADR-0005/0006) on the narrowest
case. The code is `src/wezig_renderer.zig` (the native stub) + `src/renderer_swap.zig`
(the swap coordinator + the allow-list); both are proven headlessly in
`zig build test`. The one process nit (a coordinator beside the chrome, not wired
into a shell) is in
`work/notes/observations/review-nits-spike-native-stub-and-user-swap-2026-07-19.md`
and carried into the plan below.

**The native second backend the swap needed: `WezigRenderer`, a static-page
stub.** The idea note flagged the swap was blocked on "there is no second backend
to swap TO", so the spike supplies the trivial one: on `navigate`, `WezigRenderer`
paints ONE simple static page THROUGH the existing v0 layout/paint pipeline
(`paint.renderScene` → `html.parse` → `css.styleDocument` → layout →
`StbSoftwareBackend`) into an owned offscreen `Surface`, and re-emits the seam's
`LifecycleEvent`s exactly as a real backend would. Crucially it links NOTHING new
(it paints via the pipeline already in the `wezig` module), so unlike the webview
backend it lives in the library `mod`, is re-exported from `src/root.zig`, and
its seam-contract tests run headlessly — the same class as `FakeRenderer`. It is
deliberately NOT the native renderer: no networking, no real WHATWG parsing, no
interactive view, no JS; growing this stub toward the real engine is precisely
what the build plan below sequences.

**The swap is a backend-VALUE change, not a seam change** (so `chrome_conformance`
stays green, ADR-0005). `RendererSwap` holds BOTH `Renderer` seam values and, on
a swap, does the three ADR-0005 steps: RE-POINTS which backend is active,
RE-ATTACHES the chrome's single lifecycle callback to it, and RE-NAVIGATES the
current URL through it. It talks ONLY to the `Renderer` seam (never imports a
webview/GTK binding), so the swap widens nothing.

**The policy, encoded exactly (decision 4, ADR-0011).** The webview is the
DEFAULT; the native `WezigRenderer` is used ONLY when the user opts in, two ways,
with NO automatic mismatch routing anywhere:

- a MANUAL per-page trigger (`RendererSwap.toggle`) — the long-press-reload
  gesture the shell turns into a `toggle`, swapping ONLY the current page;
  toggling back (native → webview) is the MANUAL fallback (there is no automatic
  fallback);
- a per-domain user ALLOW-LIST (`DomainAllowList`) — domains the user marked to
  ALWAYS render native, consulted on `navigate` via `engineFor(url)` to pick that
  domain's default engine. Everything not on the list defaults to webview. A URL
  with no parseable domain (`about:blank`, a bare path) defaults to webview,
  never native.

**The per-domain-allow DATA MODEL (schema + how the swap consults it).** A
persistent, user-controlled set of domains: on disk a plain UTF-8 text file, ONE
lowercase domain per line, `#` comments + blank lines ignored (trivially
diffable + human-editable — deliberate for a spike; the persistence MECHANISM is
what is proven, not a binary/DB schema). `domainOf(url)` extracts the host
without a URL-parser dependency (v0 has none); `add`/`remove`/`contains` are
case-insensitive and idempotent; `saveToFile`/`loadFromFile` round-trip, and a
MISSING file is the correct first-run empty state (not an error). Tests isolate
persistence to a temp dir and assert the real user list is untouched.

**The `Renderer`-seam gap the native stub revealed (the load-bearing carry-forward).**
The stub is the FIRST non-webview backend, and standing it up confirmed the gap
the shell exploration already flagged (`docs/shell-exploration-findings.md` §1;
ADR-0007): **the `Renderer` seam has no input/scroll/focus forwarding.** On the
webview backend the embedded view is itself a live OS widget that handles input
directly, so `setViewportSize` is the only viewport method and it is a no-op; a
`WezigRenderer` owns NO OS-native interactive widget, so it CANNOT rely on the
widget-handles-input path and WILL need the seam extended with explicit pointer /
key / wheel/scroll / focus forwarding. The stub only paints a static page, so it
did not yet FORCE the extension — but it confirms the shell exploration's call
that this is the single most important known-incomplete part of the `Renderer`
interface, and that it must be added BEFORE the native backend becomes
interactive, because adding input methods after two real implementations exist is
a breaking change to a pinned seam. Two smaller stub-honesty facts the plan
inherits: the stub keeps no session history of its own (back/forward stay a
webview concern for the narrowest case — a real `WezigRenderer` grows real
history), and the two web3 hooks (script bridge, custom-scheme) are INERT on the
stub (recorded, not executed — no JS engine, serves no scheme); the seam SHAPE is
honoured so the coordinator re-attaches them uniformly, but wiring them to a real
native pipeline is a follow-on build.

---

## 6. The `ScriptEngine` seam: bind first (lean SpiderMonkey), Zig-native later

`pin-scriptengine-seam` made the JS-engine boundary REVERSIBLE and wrote the
first-engine recommendation (decision 3, story 5). Pinned in **ADR-0013**; the
seam is `src/script_engine.zig`, proven with a trivial `StubScriptEngine` (no
real engine is bound — that is a follow-on build). This section states what the
build plan inherits.

**The seam exists and is reversible, like `Renderer`.** `ScriptEngine` is a
`{ ptr, vtable }` boundary (the `PaintBackend`/`Renderer` shape) so a concrete
engine is a runtime VALUE: a BOUND engine satisfies it FIRST (compatibility with
the real web needs a mature engine on day one), and a Zig-native engine satisfies
it LATER behind the SAME seam with no caller change. Only the COARSE,
engine-agnostic lifecycle is pinned now (create context / evaluate / one host
binding / destroy), proven by the stub.

**⚠️ The load-bearing caveat the seam surfaces (must not be misread as "a seam
like `Renderer`").** `PaintBackend` and `Renderer` are THIN. A JS-engine boundary
is WIDE and DOM-COUPLED: a running script calls BACK into the embedder constantly
— every DOM property read/write and node mutation is an engine→embedder callback;
the engine's GC must trace embedder-held DOM-wrapper references, so object
lifetime is CO-MANAGED across the boundary; and promises/microtasks/timers
interleave engine execution with the host event loop (a scheduling contract, not
call-and-return). **Consequence for the build:** the swap is REVERSIBLE but NOT
cheap the way the `Renderer` swap is — whoever binds a real engine must expect an
intimate DOM/GC/event-loop binding effort behind this seam, not a thin-vtable
swap. The wide binding surface is DELIBERATELY not modelled yet (pinning it
speculatively with no engine to check it against would bake one engine's binding
model into the "neutral" seam and defeat the reversibility — the same
pin-the-minimal-surface discipline as ADR-0006); it is grown by the build that
binds a real engine.

**The recommendation: lean SpiderMonkey (pending an embedding-cost eval).** Three
mature engines, three explicit criteria: **independence / ethos-alignment →
SpiderMonkey** (the one major engine NOT owned by a browser-platform vendor, and
Servo's engine — aligns with wezig's own-your-stack thesis, ADR-0011; JSC is
Apple/WebKit's, V8 is Google/Chromium's); **reuse → JSC** (we ALREADY link WebKit
on the webview backend — WebKitGTK, `WKWebView` — and JSC ships inside WebKit, the
strongest pragmatic counter-argument, and why this is a LEAN not a lock); **raw
perf + embedding ergonomics → V8** (the perf leader with the most polished
embedding API; given how WIDE this seam is, embedding-API quality is load-bearing
for how much the DOM/GC/event-loop bindings cost).

We LEAN SpiderMonkey because independence is the tie-breaker matching wezig's
reason to own its stack — but it is PENDING an embedding-cost eval that measures
SpiderMonkey's binding cost against V8's (weighing the JSC-reuse saving). If that
eval finds SpiderMonkey prohibitive, the decision REOPENS toward JSC (reuse) or V8
(ergonomics) using the criteria recorded in ADR-0013 — re-weighting, not
re-discovering. The follow-on build that binds an engine runs that eval; the
exploration does not firm the lean into a lock.

**The Zig-native (`kiesel`) position: aspirational later swap-in, NOT first.** A
from-scratch JS engine is a multi-year, conformance-hungry effort (the same shape
as the native renderer). It swaps in behind the seam AFTER a bound engine has
carried real-web compatibility — never as the day-one general-web engine (pointing
a young engine at the full web fails ADR-0011's hard compatibility requirement).
Its plausible FIRST foothold is a narrow controlled-trust surface (verifiable /
content-addressed / local-first content, where the script is small,
trusted-by-verification, and wezig sets the compatibility bar), not the general
web. The bound engine owns general-web compatibility; `kiesel` earns surfaces
incrementally behind the seam. **Build implication:** the JS slice below is a
BIND slice (grow the wide DOM/GC/event-loop bindings for the leant engine), and
`kiesel` is explicitly a LATER, out-of-first-build slice, not a fork in the JS
slice's road.

---

## 7. The de-risked, SLICED BUILD PLAN

This section states the follow-on native-renderer BUILD spec(s) — their scope,
ordering, and the TARGET TIER each aims at (from §1 / ADR-0012) — so each can be
authored and tasked ATOMICALLY from THIS document alone (a follow-on `to-spec`
could work from it), mirroring how `docs/shell-exploration-findings.md` fed the
desktop build and `docs/mobile-exploration-findings.md` fed the mobile build.
Everything below is grounded in a finding above; the "DECIDE" points are the
load-bearing choices the exploration surfaced but (correctly, being out of scope)
did NOT settle.

### What the build already knows (de-risked by the exploration)

- The conformance target is a NAMED ladder (T0..T3, ADR-0012); each slice aims at
  a named tier, and both floors (server-web + content-addressed) ride every rung.
- HarfBuzz shaping works behind `PaintBackend` with NO seam reshaping, on stb
  glyph-index raster; FreeType is an additive raster upgrade sequenced later (§2).
- Networking is `libcurl` (bound, vetted TLS, never write TLS) behind the
  `net.Fetcher` seam, with hash-verified content-addressed fetch proven (§3).
- The native page-GPU path is `wgpu-native` (Vulkan) for WebGPU; WebGL is the
  ANGLE-integration route, not a hand-written GL stack (§4).
- The user-controlled swap MECHANISM (`RendererSwap` re-point/re-attach/re-navigate
  + `DomainAllowList`) and the native `WezigRenderer` stub both work at the
  `Renderer` seam with `chrome_conformance` green (§5).
- The `ScriptEngine` seam is pinned + reversible (stubbed), the bind
  recommendation (lean SpiderMonkey) + the `kiesel`-later position recorded (§6).
- The build builds AGAINST the pinned seams (`Tokenizer | TreeBuilder`,
  `PaintBackend`, `Renderer`, `net.Fetcher`, `ScriptEngine`), never around them —
  each higher tier is an additive backend swap behind a seam (ADR-0001/0012).

### Slicing (recommended follow-on specs, in dependency order)

The native renderer is far bigger than one atomically-taskable spec; it slices
into the follow-on build specs below, ordered so each lands behind the seam the
prior slices proved. Each names a TARGET TIER, what it CONTAINS, and what it must
DECIDE. Slices at the SAME tier that touch disjoint code can proceed in parallel;
the ordering constraints are called out per slice. The slice names are a PROPOSAL
the human authoring the follow-on specs adopts and may re-cut — not pinned
interfaces.

**Slice 0 — `grow-renderer-seam-for-native` (seam prerequisite; do FIRST,
T1-enabling).** The one seam-shape change the native path needs BEFORE it becomes
interactive: add **input/scroll/focus forwarding** to the `Renderer` seam
(pointer events, key events, wheel/scroll deltas, focus) — the gap the native
stub confirmed (§5) and the shell exploration flagged (ADR-0007). It must land
BEFORE any slice makes `WezigRenderer` interactive, because adding input methods
after two real backends exist is a breaking change to a pinned interface.
**Contains:** the input method set on the seam + its webview-backend
implementation (the webview forwards to its live widget or no-ops as today) + the
`WezigRenderer`-side consumption stub. **Bar:** the seam carries synthetic input
events end-to-end through `FakeRenderer` headlessly; `chrome_conformance` + the v0
gate stay green. **Must DECIDE:** the exact input method set + event vocabulary
(reuse the toolkit's event types vs a renderer-neutral set); whether a seam-level
`snapshot()` method is added here too (the one place tests reach past the seam
today — ADR-0007 deferred it).

**Slice A — `build-native-static-parse-and-css` (foundation; after Slice 0,
target T1).** Grow the v0 subset tokenizer/tree-builder into a REAL WHATWG parser
behind the `Tokenizer | TreeBuilder` seam (ADR-0001) and the subset cascade into
a CORE CSS engine (the common box-model, colour, typography, normal-flow
properties a static page uses), producing correct static block/inline layout of
REAL documents. **Contains:** the WHATWG tokenizer + tree-construction algorithm
behind the existing seam; the core CSS parser/selector-matcher/cascade extension;
the T1 page-checklist fixtures (a real article/blog page over HTTP AND an
`ipfs://` static site by CID) + the T1 WPT bar wired as a regression meter
(≥ 90 % tree-construction, ≥ 70 % core CSS static-layout). **Bar:** T1's page
checklist renders through `WezigRenderer` (not the webview), the T1 WPT subset is
at/over threshold, the v0 goldens + doc-drift guard stay green. **Must DECIDE:**
how the T1 fixtures are pinned (a specific commit/snapshot for the HTTP pages, a
specific CID for the `ipfs://` one) so the goldens are stable; whether the real
parser replaces the subset tokenizer outright or runs alongside it behind the
seam during the transition.

**Slice B — `build-native-latin-shaping` (text, T1; after Slice A, parallel with
C/D/E).** Grow the HarfBuzz shaping the spike proved (§2) into the T1 text path:
HarfBuzz Latin/LTR shaping behind `PaintBackend`, on the stb glyph-index raster
(NO FreeType yet — the spike proved this is enough for the T1 milestone).
**Contains:** the shaping integration into the real paint path (replacing the v0
glyph-by-glyph codepoint path for real text), font loading/selection for the T1
fixtures. **Bar:** T1 fixtures shape correctly (ligatures/kerning where the font
has them); the `stb` v0 path stays available as fallback; v0 gate green. **Must
DECIDE:** the font-selection model for T1 (system fonts vs a bundled default
face). **Sequenced before** the FreeType raster upgrade (Slice B2) per §2.

**Slice B2 — `build-native-freetype-raster-and-complex-script` (text, T2; after
Slice B).** Introduce FreeType at the milestone that needs it (§2): pair HarfBuzz
with a FreeType `FT_Face` (`hb_ft_font_create`) so shaper + rasteriser share ONE
source of truth for outlines/metrics, add hinting/grid-fitting, colour/emoji
fonts, and full complex-script + bidi shaping. **Contains:** FreeType binding
behind `PaintBackend`; the HarfBuzz↔FreeType metric-sharing path; bidi ordering.
**Bar:** T2's complex-script/bidi page checklist renders; the T2 text/bidi WPT
subset (≥ 80 %) at threshold. **Depends on** Slice A (real parse) + Slice B
(shaping path); pairs with Slice C at T2.

**Slice C — `build-native-full-layout` (layout, T2; after Slice A, parallel with
B2).** Grow block/inline flow into the FULL static-layout feature set: floats +
`clear`, flexbox, CSS grid, tables, and out-of-flow positioning
(relative/absolute/fixed/sticky), behind the layout stage. **Contains:** each
layout mode + the T2 page-checklist fixtures (a modern flex/grid landing page, a
table+float classic page, AND an `ipfs://` static site using modern layout) + the
T2 static-layout WPT bar (≥ 85 %). **Bar:** T2's layout checklist renders through
`WezigRenderer`; the T2 WPT static-layout subset at threshold. **Must DECIDE:**
the ordering of the layout modes within the slice (e.g. floats/tables — the "old
web still works" floor — before or after flex/grid) if it needs sub-slicing.

**Slice D — `build-native-page-gpu` (GPU, page-canvas; after Slice 0/A,
independent of B/C).** Grow the one-frame GPU spike (§4) into a real page-facing
`<canvas>` GPU stack on the native path. **Contains, in two sub-slices:** (D1
WebGPU) grow the `wgpu-native`/Vulkan one-frame path into a canvas-backed WebGPU
context (swapchain/surface, bind groups, textures/uniforms, the WebGPU JS API)
behind the paint/renderer seams, written against the standard `webgpu.h` so Dawn
stays a link-line alternative; (D2 WebGL) integrate ANGLE (translate GLES to the
platform native API) as the WebGL backend + run the WebGL CTS + build the
GPU-process/command-buffer isolation for the untrusted-page→GPU boundary.
**Bar:** a page `<canvas>` gets a working WebGPU context AND a working WebGL
context on the native path, the WebGL CTS runs as the conformance meter, and
correctness holds on real GPUs (the spike used software rasterisers, so real-GPU
perf is measured HERE). **Must DECIDE:** whether to bind ANGLE directly or reach
GL-on-native through `wgpu`/Dawn's path; the GPU-process security-model shape
(ADR-0011 trust posture); whether to re-benchmark Dawn vs `wgpu-native` now that a
trusted prebuilt may exist (the spike's pick is a recommendation, not a lock);
and the still-OPEN 2D-rasterizer pick (Skia vs lighter), partly subsumed here
(§4). **Note:** the webview backend keeps serving page-GPU content until this
slice reaches its tier (§4).

**Slice E — `build-native-networking` (networking, T3-enabling; after Slice A,
before/with Slice F).** Grow `CurlFetcher` into the real networking client behind
the `net.Fetcher` seam the spike proved (§3): the first milestone turns the
blocking one-shot GET into a real client (caching, cookies, redirect/proxy policy,
connection pooling, streaming to the parser, cancellation, async/event-loop
integration), and grows the content-addressed path a real CID decoder that
constructs a `ContentAddress` from an `ipfs://…` string — the `verify` contract
the spike proved is reused UNCHANGED. **Contains:** the real client + the CID
decoder + the T3 fixture wiring (fetch the T3 checklist pages, including the
`ipfs://` interactive frontend). **Bar:** the T3 fixtures fetch (server + hash-
verified content-addressed) through the real client behind the seam; the live leg
stays a provisioned CI leg, off the display-free gate. **Must DECIDE:** the TLS
trust-store / pinning policy, and whether content-addressed fetches relax origin
trust because verification moves to the hash (§3); the native-`ipfs://`
resolution boundary WITH `explore-web3-capabilities` (which owns native IPFS —
this slice grows the fetch+verify seam, not the DHT/gateway resolution).

**Slice F — `build-native-scriptengine-bind` (JS, T3; LAST of the tier climb;
after Slice A + Slice E).** Bind the first real engine behind the `ScriptEngine`
seam (§6). This is the WIDE-DOM-coupled slice the seam's caveat warns about — the
largest, most intimate slice. **Contains:** (1) the embedding-cost eval that firms
the SpiderMonkey lean into a lock or re-decides toward JSC/V8 on the recorded
criteria (ADR-0013) — this runs BEFORE the bind commits; (2) growing the wide
DOM/GC/event-loop binding surface behind the seam (DOM property/mutation
callbacks, GC rooting of DOM wrappers, microtask/event-loop draining, `fetch`/XHR
over Slice E's networking, timers) for the chosen engine; (3) the T3 page-checklist
fixtures (a JS-driven app page + a form/interaction page over HTTP AND an
`ipfs://` interactive frontend) + the T3 DOM/scripting/fetch WPT bar (≥ 75 %).
**Bar:** T3's interactive checklist renders AND runs through `WezigRenderer` with
the bound engine; the T3 WPT subset at threshold. **Must DECIDE:** the engine (run
the eval FIRST — do not inherit the lean as a lock); the DOM-binding architecture
(how tightly the binding couples to the chosen engine's object model, since that
shapes how reversible the swap stays in practice). `kiesel` is EXPLICITLY NOT in
this slice — it is a LATER swap-in behind the same seam, plausibly first on a
narrow controlled-trust surface (§6), authored as its own much-later spec.

**Slice G — `build-native-swap-chrome` (the user-swap chrome; after Slice 0, can
run alongside the tier climb).** Promote the swap MECHANISM the spike proved (§5)
from a beside-the-chrome coordinator into first-class product chrome UX.
**Contains:** wire `RendererSwap` into the real desktop + mobile chrome
(`src/chrome.zig` / `src/mobile_chrome.zig` hold the single `Renderer` value), add
the long-press-reload gesture that calls `toggle`, add the VISIBLE engine
indicator (the `webview`/`wezig` label the spike defined but did not display), and
wire the `DomainAllowList` load/save + the user gesture that edits it. **Bar:** a
user gesture swaps the current page to `WezigRenderer` and back in a real shell
with a visible indicator; an allow-listed domain renders native by default;
everything else stays webview; `chrome_conformance` + the v0 gate green. **Must
DECIDE:** whether to promote the gesture to a first-class `ChromeIntent` variant
(the spike deliberately did NOT, to avoid widening the pinned seam for a spike —
§5 / `renderer_swap.zig`); where the persisted `DomainAllowList` file lives (the
real user-config dir the spike's tests deliberately avoided touching).

### Ordering summary (the critical path)

Slice 0 (seam input-forwarding) → Slice A (real parse + core CSS) is the critical
path everything hangs off; at **T1** it is joined by Slice B (Latin shaping).
**T2** is Slice B2 (FreeType + complex script) + Slice C (full layout), which can
run in parallel once Slice A + B land. **Slice D** (page-GPU) is independent of
the parse/layout/text spine and can proceed after Slice 0/A. **T3** is Slice E
(networking) then Slice F (bind the JS engine — the largest, most intimate slice,
last on the tier climb). **Slice G** (the user-swap chrome) needs only Slice 0
and can run alongside the whole climb, since the swap mechanism + allow-model are
already proven. `kiesel` and the full native `ipfs://`/IPFS subsystem are
EXPLICITLY out of this plan (later swap-in behind the `ScriptEngine` seam;
`explore-web3-capabilities` respectively).

## Decisions recorded by this deliverable

This is a documentation task, but it makes judgement calls worth ratifying
(recorded here and cross-linked from the companion ADR-0014):

- **This findings doc lives at `docs/native-renderer-exploration-findings.md`,
  alongside `docs/shell-exploration-findings.md` and
  `docs/mobile-exploration-findings.md`,** NOT under `docs/adr/`. Rationale: it is
  a report + plan (a reference document), not a single decision; ADRs stay short
  (`work/protocol/ADR-FORMAT.md`), and the load-bearing DECISIONS are pinned in
  the per-decision ADRs the spikes produced (ADR-0012, ADR-0013) + the companion
  ADR-0014. Alternative considered: fold everything into one long ADR; rejected
  because it violates the "an ADR can be a single paragraph" norm and buries the
  plan — the exact precedent `docs/shell-exploration-findings.md` + ADR-0007 and
  `docs/mobile-exploration-findings.md` + ADR-0009 set for the sibling explorations.
- **The native-renderer build is SLICED into the specs of §7 (Slice 0..G), not
  one.** Rationale: the spec's Out-of-Scope explicitly separates parser / CSS /
  layout / text / networking / GPU / JS / user-swap chrome as follow-on BUILD
  specs, and "task a spec atomically or split it" forbids one spec mixing a
  foundation slice with the JS-bind slice. The slicing + ordering is a PROPOSAL
  the human authoring the follow-on specs adopts and may re-cut; it is not a
  pinned interface. It touches no code and no other task — it is the plan's shape,
  flagged for ratification rather than silently assumed.

## Cross-references

- **ADR-0014** — the companion ADR pinning this exploration's outcome + build
  inputs (points here).
- **ADR-0012** + **`docs/conformance-tiers.md`** — the tiered conformance target
  each slice aims at (§1).
- **ADR-0013** + **`src/script_engine.zig`** — the `ScriptEngine` seam + the bind
  recommendation (§6).
- **ADR-0005/0006** — the `Renderer` (and `Toolkit`) seams the swap routes at and
  the native path grows behind (§5).
- **ADR-0001/0002/0003** — the `Tokenizer | TreeBuilder` + `PaintBackend` +
  offscreen `Surface` seams the parser/CSS/text/GPU slices grow behind.
- **ADR-0011** — the general-browser, post-trusted-server thesis every decision is
  anchored on.
- **`docs/shell-exploration-findings.md`** / **`docs/mobile-exploration-findings.md`**
  — the sibling exploration deliverables this mirrors (and the input-forwarding /
  `PageContext` seam gaps §5 inherits).
- **`work/notes/findings/`** — the per-spike ground-truth notes every claim above
  traces to (cited inline).
- **Spec `explore-native-renderer`** — stories 6–7, the exploration this answers.
