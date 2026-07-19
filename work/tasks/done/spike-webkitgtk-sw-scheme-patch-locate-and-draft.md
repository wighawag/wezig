---
title: Locate + size the WebKitGTK SW-scheme patch, draft the upstream proposal, express the SW-capable trait at the seam (no WebKit build)
slug: spike-webkitgtk-sw-scheme-patch-locate-and-draft
spec: explore-web3-capabilities
blockedBy: []
covers: [2]
---

## What to build

The ENVIRONMENT-INDEPENDENT half of the WebKitGTK SW-scheme fork spike (ADR-0016
decision 6), split out because building WebKitGTK from source is impossible on the
current dev box (see the re-scope note). This half needs NO WebKit build: locate +
SIZE the minimal patch against the real WebKit source, DRAFT the upstream
proposal, and express the SW-capable scheme trait AT the `Renderer` seam (proven
in the core gate with the fake backend). The patched-build + live-SW proof +
build-time measurement are the SEPARATE, deferred
`spike-webkitgtk-sw-scheme-patch-build-and-measure`.

> **Re-scope note (2026-07-19).** The original `spike-webkitgtk-sw-scheme-patch`
> assumed a buildable WebKitGTK ("build time on this box", a live patched-WebKit
> SW leg). The dev box CANNOT build WebKitGTK from source (25 GB free disk, 3.7 GB
> RAM, 2 cores, no cmake/ninja/ruby; a WebKit source build needs ~40–60 GB disk +
> 16 GB+ RAM + hours). So the spike is split: THIS task lands everything that does
> not need the build; the build/measure half is deferred to a provisioned host
> (the author's laptop). Both trace to ADR-0016.

- **Locate + size the patch (against REAL WebKit source, read-only).** The gate is
  in `Source/WebCore/workers/service/ServiceWorkerContainer.cpp`,
  `ServiceWorkerContainer::addRegistration` — the predicate
  `!jobData.scriptURL.protocolIsInHTTPFamily() && !jobData.isFromServiceWorkerPage`
  rejects a non-HTTP(S) `scriptURL` (and a SECOND, sibling check does the same for
  `scopeURL`). Both must be widened to also admit a scheme the embedder registered
  as SW-capable. Pin the exact predicate + both sites, define the minimal change
  (widen the predicate via a `LegacySchemeRegistry`-style "is this scheme
  SW-capable?" query), and the `WebKitSecurityManager` opt-in that feeds it
  (`webkit_security_manager_register_uri_scheme_as_service_worker_capable` +
  `..._uri_scheme_is_service_worker_capable`, MIRRORING the existing
  `_as_secure`/`_is_secure` etc. in `WebKitSecurityManager.h`). Capture the patch
  as a `.patch`/diff in the task's `<slug>/` sidecar, and MEASURE its size +
  file/function footprint (how many files, how many lines, which layers:
  WebCore predicate + the WebKitGTK API glue + the scheme-registry plumbing).
- **Draft the upstream proposal.** Write the argument (a HASH-VERIFIED secure
  origin should be permitted to host a service worker; the embedder opts in
  explicitly, so it is not a blanket relaxation) + the corroborating demand
  (Tauri #13031, "status: upstream"), as a note ready to become a WebKit bug /
  merge request. Do NOT file it (that is a human action).
- **Express the SW-capable trait at the seam (core gate, NO WebKit build).** Extend
  the `Renderer` seam's scheme-security-traits (from
  `spike-ipfs-fetch-verify-and-secure-origin-seam`, `SchemeSecurityTraits` +
  `declareSchemeSecurity`) with a `service_worker_capable` trait, so the CAPABILITY
  is declared uniformly at the seam and a `WezigRenderer` (which needs no patch)
  reproduces it natively. Prove the seam contract with the fake backend in the
  display-free `zig build test` gate. The `SystemWebviewRenderer` wiring of the
  trait to the (patched) `WebKitSecurityManager` opt-in is STUBBED/guarded here
  (it compiles against the current unpatched header, which lacks the symbol) and
  is ACTIVATED by the deferred build-and-measure task — do NOT call a symbol the
  installed WebKitGTK does not export (that would break the shell build).

## Acceptance criteria

- [ ] The exact patch site(s) are pinned against real WebKit source (the
      `protocolIsInHTTPFamily()` gate for BOTH `scriptURL` and `scopeURL` in
      `ServiceWorkerContainer::addRegistration`), the minimal patch is captured as a
      `.patch`/diff in the task sidecar, and its SIZE + file/function footprint is
      measured + recorded.
- [ ] A drafted upstream proposal (argument + Tauri #13031 corroboration) is
      recorded, ready for a human to file.
- [ ] The `Renderer` seam expresses a `service_worker_capable` scheme trait
      (extending the existing `SchemeSecurityTraits`/`declareSchemeSecurity`), proven
      by a seam-contract test with the fake backend in the display-free
      `zig build test` gate. The core gate stays green.
- [ ] The `SystemWebviewRenderer` does NOT call any WebKitSecurityManager symbol the
      installed (unpatched) WebKitGTK lacks — the patched wiring is stubbed/guarded so
      the shell still builds; a clear TODO points at the build-and-measure task.
- [ ] A findings note records what is DONE here (patch located/sized, upstream draft,
      seam trait) and what remains for the deferred task (build patched WebKitGTK,
      observe one live SW on a secure `ipfs://` page, measure build time + rebase
      friction), with the environment reason for the split.
- [ ] Every claim traces to real source/measurement (no speculation); no chrome
      reaches past the seam (`chrome_conformance` stays green).

## Blocked by

- None — can start immediately. (Builds on the landed
  `spike-ipfs-fetch-verify-and-secure-origin-seam` seam extension; the deferred
  `spike-webkitgtk-sw-scheme-patch-build-and-measure` consumes the patch this task
  captures.)

## Prompt

> Goal: land the ENVIRONMENT-INDEPENDENT half of the WebKitGTK SW-scheme fork spike
> (ADR-0016 d.6) — locate + SIZE the minimal patch against real WebKit source, DRAFT
> the upstream proposal, and express a `service_worker_capable` scheme trait AT the
> `Renderer` seam (core-gate proof with the fake backend). NO WebKit build (the dev
> box cannot build WebKitGTK — 25 GB disk / 3.7 GB RAM / 2 cores / no cmake-ninja-ruby;
> a source build needs ~40-60 GB + 16 GB+ RAM + hours). The patched build + live SW
> proof + build-time measurement are the SEPARATE deferred
> `spike-webkitgtk-sw-scheme-patch-build-and-measure`, to run on a provisioned host.
>
> FIRST reconcile against reality: read ADR-0016, the observation
> `work/notes/observations/webkitgtk-service-worker-hard-restricted-to-http-https-2026-07-19.md`,
> and the landed seam extension (`SchemeSecurityTraits` + `declareSchemeSecurity` in
> `src/renderer.zig`; the WebKitGTK wiring in `src/system_webview_renderer.zig`;
> `src/ipfs_scheme.zig`). The REAL patch site (verified against WebKit main): in
> `Source/WebCore/workers/service/ServiceWorkerContainer.cpp`,
> `ServiceWorkerContainer::addRegistration`, the check
> `if (!jobData.scriptURL.protocolIsInHTTPFamily() && !jobData.isFromServiceWorkerPage)`
> rejects a non-HTTP(S) scriptURL, and a SIBLING check does the same for `scopeURL`.
> Widen BOTH to also admit an embedder-registered SW-capable scheme (via a
> `LegacySchemeRegistry`-style query), fed by a new `WebKitSecurityManager` opt-in
> mirroring `webkit_security_manager_register_uri_scheme_as_secure` / `..._is_secure`
> (see `/usr/include/webkitgtk-6.0/webkit/WebKitSecurityManager.h`). Capture the
> patch as a `.patch` in the task sidecar and measure its size/footprint.
>
> Extend the seam with a `service_worker_capable` trait so the capability is declared
> uniformly (a `WezigRenderer` reproduces it with no patch). Prove the seam contract
> in the core gate with the fake backend. CRITICAL: do NOT make `SystemWebviewRenderer`
> call a WebKitSecurityManager symbol the INSTALLED (unpatched) WebKitGTK does not
> export — stub/guard the patched wiring with a clear TODO for the build-and-measure
> task, so `zig build shell` still links. Draft (do not file) the upstream proposal
> (hash-verified secure origin should host a SW; embedder opts in explicitly; Tauri
> #13031 corroborates). Record a findings note: what is done vs deferred + why (the
> build constraint). Domain vocabulary: `CONTEXT.md`, ADR-0005, ADR-0011, ADR-0015,
> ADR-0016. "Done" = patch located+sized+captured, upstream proposal drafted, seam
> `service_worker_capable` trait expressed + core-gate-tested, unpatched shell still
> builds, findings note records the done/deferred split, core gate green.
