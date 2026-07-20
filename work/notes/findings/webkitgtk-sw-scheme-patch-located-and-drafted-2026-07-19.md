---
title: WebKitGTK SW-scheme fork patch — LOCATED + SIZED + upstream draft written; build/measure DEFERRED (env constraint)
date: 2026-07-19
status: open
kind: finding
forTask: spike-webkitgtk-sw-scheme-patch-locate-and-draft
source: WebKit main source (ServiceWorkerContainer.cpp, LegacySchemeRegistry.{h,cpp}, WebKitSecurityManager.{h,cpp}, WebProcessPool.cpp — read-only, fetched 2026-07-19) + the installed WebKitGTK 6.0 header /usr/include/webkitgtk-6.0/webkit/WebKitSecurityManager.h + ADR-0016 + the observation webkitgtk-service-worker-hard-restricted-to-http-https-2026-07-19.md + the landed seam (src/renderer.zig, src/system_webview_renderer.zig, src/ipfs_scheme.zig)
---

The DONE/DEFERRED record for the split WebKitGTK SW-scheme fork spike (ADR-0016
decision 6). The spike is split because **this dev box cannot build WebKitGTK from
source** (25 GB free disk, 3.7 GB RAM, 2 cores, no cmake/ninja/ruby; a WebKit
source build needs ~40–60 GB disk + 16 GB+ RAM + hours). This
environment-independent half (`spike-webkitgtk-sw-scheme-patch-locate-and-draft`)
lands everything that does NOT need the build; the hardware-gated half
(`spike-webkitgtk-sw-scheme-patch-build-and-measure`, `humanOnly`) runs on a
provisioned host.

## DONE here (environment-independent)

- **Patch located + pinned against REAL WebKit main source.** The gate is
  `ServiceWorkerContainer::addRegistration`
  (`Source/WebCore/workers/service/ServiceWorkerContainer.cpp`). Verified BOTH
  sibling predicates against upstream (fetched 2026-07-19):
  - scriptURL: `if (!jobData.scriptURL.protocolIsInHTTPFamily() && !jobData.isFromServiceWorkerPage)` → rejects non-HTTP(S).
  - scopeURL: `if (!jobData.scopeURL.isNull() && !jobData.scopeURL.protocolIsInHTTPFamily() && !jobData.isFromServiceWorkerPage)` → the same, for the scope.
  `LegacySchemeRegistry.h` is ALREADY included in that file, and its per-trait
  register/should-treat pattern (secure, CORS-enabled, …) is the exact template
  for a `registerURLSchemeAsServiceWorkerCapable` /
  `shouldTreatURLSchemeAsServiceWorkerCapable` pair.
- **Minimal patch captured as a `.patch`** in the spike-evidence folder
  (`docs/spikes/spike-webkitgtk-sw-scheme-patch-locate-and-draft/webkitgtk-sw-scheme-capable.patch`),
  widening BOTH predicates via the new registry query, plus the WebKitGTK
  `WebKitSecurityManager` opt-in
  (`webkit_security_manager_register_uri_scheme_as_service_worker_capable` /
  `..._uri_scheme_is_service_worker_capable`) mirroring the installed header's
  `_as_secure`/`_is_secure`, plus the UI→web-process IPC sync that surface uses.
- **Size + footprint measured**
  (`docs/spikes/spike-webkitgtk-sw-scheme-patch-locate-and-draft/patch-size-and-footprint.md`):
  **9 files, ~105 added / 2 changed lines, 3 layers** (WebCore predicate + WebCore
  registry + WebKitGTK GLib glue, with a UI↔web IPC-sync sub-layer). The real
  policy change is 2 predicate clauses + one registry pair; the rest mirrors the
  existing `_as_secure`/`_as_cors_enabled` plumbing, so rebase anchors are stable.
  The one non-obvious hunk (the creation-parameters replay for late web processes)
  is flagged for the build task.
- **Upstream proposal DRAFTED (not filed)**
  (`docs/spikes/spike-webkitgtk-sw-scheme-patch-locate-and-draft/upstream-proposal-draft.md`):
  a hash-verified content-addressed origin is at least as strong a secure context
  as `https://`; the embedder opts IN explicitly (default-off), so it is a
  targeted relaxation, not blanket; Tauri #13031 ("status: upstream") is the
  corroborating demand. Filing is a human action (ADR-0016 d.3).
- **Seam expresses a `service_worker_capable` trait.** `SchemeSecurityTraits` in
  `src/renderer.zig` gains a default-false `service_worker_capable` field (a
  DISTINCT trait, not implied by `secure` — mirroring the two-gate finding), with
  seam-contract tests in the display-free `zig build test` gate proving the fake
  backend records it and that a secure origin is NOT automatically SW-capable. A
  `WezigRenderer` reproduces it natively (no patch).
- **Unpatched shell still builds.** `SystemWebviewRenderer.declareSchemeSecurity`
  honours secure/CORS/local on stock WebKitGTK and **stubs** the
  `service_worker_capable` trait to a no-op with a `TODO(...-build-and-measure)`,
  precisely because the installed WebKitGTK 6.0 header exports no such symbol.
  `zig build shell` links green (verified: `wezig-shell` binary produced).

## DEFERRED to `spike-webkitgtk-sw-scheme-patch-build-and-measure` (hardware-gated)

- Build a patched WebKitGTK from source with the captured `.patch` (rebased onto
  the exact tag it compiles).
- Observe ONE live service worker registering + controlling a secure `ipfs://`
  page end-to-end on the patched backend (the leg stock WebKitGTK rejects).
- Activate the stubbed `SystemWebviewRenderer` wiring against the patched
  `webkit_security_manager_register_uri_scheme_as_service_worker_capable`.
- MEASURE the real cost: build time on a provisioned host + rebase friction across
  1–2 WebKitGTK releases (the keep-as-fork commitment ratifies AFTER this data).

## Why the split (the environment reason)

The build is the ONLY thing this box cannot do; locating, sizing, drafting, and
expressing the trait at the seam need only read-only WebKit source + the installed
header + the existing Zig seam. Splitting keeps the ratification data-gathering
moving (patch size + upstream draft + seam trait land now) while the true build
cost is measured where the hardware exists — exactly the ADR-0016 decision-6 gate
shape ("commit to the fork ONLY after a de-risking spike measures its cost").

## Decisions

- **New trait name `service_worker_capable` (not folded into `secure`).** The
  two-gate finding is load-bearing: a secure origin is NECESSARY but NOT
  SUFFICIENT for SW hosting, so collapsing them would re-mean `secure` and hide
  the second gate. Kept a distinct default-false trait, mirroring WebKit's own
  per-trait registry pattern (`…AsSecure` vs `…AsServiceWorkerCapable`). Touches:
  `SchemeSecurityTraits` (renderer.zig), the WebKitGTK stub
  (system_webview_renderer.zig), and the drafted patch's naming. Alternative
  considered — a bool on `registerScheme` or reusing `secure` — rejected as it
  conflates the two gates the observation proved distinct.
- **`ipfs_scheme.secure_origin_traits` left UNCHANGED (still secure+CORS, not
  SW-capable).** That constant is the SECURE-ORIGIN declaration proven on stock
  WebKitGTK by `ipfs-secure-origin-test`; flipping `service_worker_capable` on it
  would drive the stubbed (no-op) backend path and muddy that existing proof.
  The SW-capable trait is exercised via the seam-contract tests in renderer.zig
  instead. When the patched build lands, the build-and-measure task decides
  whether `ipfs://`'s shipped constant gains the trait. Touches:
  `ipfs-secure-origin-test`, the deferred build task. Recorded here so a reviewer
  is not surprised the trait exists at the seam but is not yet on `ipfs://`'s
  shipped constant.
