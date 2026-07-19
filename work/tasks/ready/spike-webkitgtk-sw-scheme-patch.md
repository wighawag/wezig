---
title: Spike a minimal WebKitGTK fork patch that lets a secure ipfs:// origin host a service worker + measure the fork cost
slug: spike-webkitgtk-sw-scheme-patch
spec: explore-web3-capabilities
blockedBy: []
covers: [2]
---

## What to build

A TIME-BOXED de-risking spike (ADR-0016 decision 6) that (a) PROVES a minimal
WebKitGTK patch lets a page served over a secure `ipfs://` origin register + run
ONE service worker, and (b) MEASURES the standing cost of carrying that patch as a
fork — so the keep-as-fork commitment is ratified from DATA, not speculation. This
is EXPLORATION: prove-and-measure, then a human decides keep-fork vs
defer-to-`WezigRenderer` vs loopback-shim. Do NOT stand up a production fork
build/distribution pipeline in this task.

Background (ADR-0016 + the observation
`work/notes/observations/webkitgtk-service-worker-hard-restricted-to-http-https-2026-07-19.md`):
stock WebKitGTK hard-rejects `navigator.serviceWorker.register()` on any
non-HTTP(S) scheme at the WebCore level
(`Source/WebCore/workers/service/ServiceWorkerContainer.cpp` ~L194–200), with no
public API to allowlist a scheme. The patch WIDENS that one policy predicate to
"http/https OR an embedder-registered SW-capable scheme", behind an explicit
opt-in.

- **The minimal patch.** Change the WebCore protocol check to also admit a scheme
  the embedder explicitly registered as SW-capable, and expose that opt-in as a
  `WebKitSecurityManager`-style call (e.g.
  `webkit_security_manager_register_uri_scheme_as_service_worker_capable`),
  mirroring the existing `_as_secure` / `_as_cors_enabled` surface. Keep it a
  POLICY relaxation behind an opt-in, not a rendering change — as small and as
  upstream-shaped as possible.
- **The end-to-end proof.** Build patched WebKitGTK, register `ipfs://` as secure +
  SW-capable through the seam, serve an `ipfs://` page that calls
  `serviceWorker.register('sw.js')`, and prove the SW registers AND its `fetch`
  handler runs — the exact thing `spike-ipfs-fetch-verify-and-secure-origin-seam`
  could NOT do on stock WebKit. This is a live webview leg (Xvfb + the patched
  WebKitGTK), OFF the core gate.
- **The cost measurement (the load-bearing output).** Record, as data a human can
  ratify against: the patched-WebKitGTK build time on this box; the patch SIZE +
  file/function footprint against the current WebKitGTK `main`; how cleanly the
  patch REBASES across 1–2 recent WebKit releases (does the touched code churn?);
  and a DRAFT of the upstream proposal (the argument: a hash-verified secure origin
  should be allowed to host a SW; corroborated by Tauri #13031). Capture all of it
  in a findings/observation note.

## Acceptance criteria

- [ ] A minimal WebKitGTK patch adds an embedder opt-in that admits a registered
      secure scheme to SW-hosting; the patch is captured (a `.patch`/diff in the
      task's sidecar or a linked branch) and is as small + upstream-shaped as
      practical.
- [ ] With patched WebKitGTK, a page served over a secure `ipfs://` origin registers
      AND runs ONE service worker end-to-end (SW `fetch` handler observed), proven by
      a dedicated off-core-gate step/CI leg (Xvfb + patched WebKitGTK, ADR-0007). The
      core `zig build test` gate is UNTOUCHED and stays green (this proof never
      enters it).
- [ ] A findings note MEASURES the fork cost: patched build time, patch size/footprint
      vs current WebKitGTK `main`, rebase friction across 1–2 recent releases, and a
      DRAFT upstream proposal — enough for a human to ratify keep-fork vs
      defer-to-`WezigRenderer` vs loopback-shim.
- [ ] The seam contract is unchanged from
      `spike-ipfs-fetch-verify-and-secure-origin-seam`: SW-capability is a scheme
      SECURITY TRAIT declared AT the seam (so a `WezigRenderer` — which needs no
      patch — reproduces the capability natively). No chrome reaches past the seam
      (`chrome_conformance` stays green).
- [ ] Every claim traces to something actually built/measured (no speculation dressed
      as a finding); the patched build + its CI leg are clearly marked as a spike, not
      wired into release/distribution here.

## Blocked by

- None — can start immediately. (Pairs with, but does not block on,
  `spike-ipfs-fetch-verify-and-secure-origin-seam`, which lands the fetch/verify +
  secure-origin seam extension this patch builds ON. This task adds ONLY the
  SW-capable trait + the fork proof/measurement.)

## Prompt

> Goal: prove a MINIMAL WebKitGTK fork patch lets a secure `ipfs://` origin host ONE
> service worker, and MEASURE the cost of carrying that patch as a fork, so a human
> can ratify keep-fork vs defer-to-`WezigRenderer` vs loopback-shim (ADR-0016
> decision 6). Time-boxed EXPLORATION: prove-and-measure, do NOT stand up a
> production fork build/distribution pipeline.
>
> FIRST reconcile against reality (drift check): read ADR-0016 (the decided
> direction), the observation
> `work/notes/observations/webkitgtk-service-worker-hard-restricted-to-http-https-2026-07-19.md`
> (the exact WebCore gate: `Source/WebCore/workers/service/ServiceWorkerContainer.cpp`
> ~L194–200, http/https-only, no public allowlist API), and the seam extension
> `spike-ipfs-fetch-verify-and-secure-origin-seam` lands (scheme security traits at
> the `Renderer` seam). The patch WIDENS the one protocol predicate to also admit an
> embedder-registered SW-capable scheme, behind a `WebKitSecurityManager`-style
> opt-in — keep it minimal and upstream-shaped.
>
> Prove: build patched WebKitGTK, register `ipfs://` secure + SW-capable through the
> seam, serve an `ipfs://` page that registers a service worker, and observe the SW's
> `fetch` handler run. Put this in a DEDICATED off-core-gate step + CI leg (Xvfb +
> the patched WebKitGTK, mirroring the `webview` leg, ADR-0007); NEVER fold it into
> the core `zig build test` gate. Measure + record (a findings note): patched build
> time, patch size/footprint vs WebKitGTK `main`, rebase friction across 1–2 recent
> releases, and a draft upstream proposal (argument: a hash-verified secure origin
> should host a SW; cite Tauri #13031). Express SW-capability as a scheme SECURITY
> TRAIT at the seam so a `WezigRenderer` reproduces it with no patch.
>
> This touches a heavy external build (WebKitGTK is a large C++ build) — be explicit
> about build cost and keep the patch tiny. It does NOT touch real custody, secrets,
> or a release/distribution path (the patched build is a spike artifact, not a
> shipped package). Domain vocabulary + framing: `CONTEXT.md`, ADR-0005 (webview is a
> disposable first backend), ADR-0011, ADR-0015, ADR-0016. "Done" = patched WebKitGTK
> hosts one SW on a secure `ipfs://` page (off-core-gate leg), the fork cost is
> measured + the upstream proposal drafted, the seam contract is unchanged, and the
> core gate stays green.
