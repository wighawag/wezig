---
title: Build patched WebKitGTK, prove one live service worker on a secure ipfs:// origin, and measure the fork cost
slug: spike-webkitgtk-sw-scheme-patch-build-and-measure
humanOnly: true
spec: explore-web3-capabilities
blockedBy: [spike-webkitgtk-sw-scheme-patch-locate-and-draft]
covers: [2]
needsAnswers: true
---

## What to build

The DEFERRED, HARDWARE-DEPENDENT half of the WebKitGTK SW-scheme fork spike
(ADR-0016 decision 6): apply the patch captured by
`spike-webkitgtk-sw-scheme-patch-locate-and-draft`, BUILD patched WebKitGTK from
source, prove one live service worker hosts on a secure `ipfs://` page end-to-end,
and MEASURE the standing fork cost (build time, rebase friction). This produces
the last of the data a human needs to ratify keep-fork vs defer-to-`WezigRenderer`
vs loopback-shim.

> **Why `humanOnly` + deferred.** Building WebKitGTK from source needs a
> PROVISIONED HOST the standard dev box + CI runners do not have (~40–60 GB disk,
> 16 GB+ RAM, many cores/hours, cmake+ninja+ruby toolchain). This task is to be
> run by a human on a capable machine (the author's laptop), not an autonomous
> agent on the dev box. It is NOT security-critical-by-nature; it is
> hardware-gated. Strip `humanOnly` if/when a provisioned autonomous runner exists.

- **Apply + build.** Fetch the matching WebKitGTK source, apply the sidecar
  `.patch` from the locate-and-draft task, build it. Record the ACTUAL build time
  + the host spec (so "the fork build costs X on a Y" is a real datum).
- **Activate the seam wiring.** Un-stub the `SystemWebviewRenderer` wiring the
  locate-and-draft task guarded: with the patched header/lib, call the new
  `webkit_security_manager_register_uri_scheme_as_service_worker_capable` when the
  seam declares the `service_worker_capable` trait, so `ipfs://` becomes
  SW-capable through the seam.
- **Prove one live SW.** Serve an `ipfs://` page (through the interception hook,
  reusing `src/ipfs_scheme.zig`) that calls `serviceWorker.register('sw.js')`;
  observe the SW registers AND its `fetch` handler runs — the exact thing stock
  WebKitGTK rejected. This is a dedicated off-core-gate leg (Xvfb + the PATCHED
  WebKitGTK); it NEVER enters the core `zig build test` gate, and cannot run on the
  bare CI runner (it needs the patched lib) — mark it a manual/provisioned-host
  step.
- **Measure rebase friction.** Rebase the patch across 1–2 recent WebKit releases;
  record whether the touched code (`ServiceWorkerContainer.cpp` predicate + the
  `WebKitSecurityManager` glue) churned, so the maintenance tail is a real datum.

## Acceptance criteria

- [ ] Patched WebKitGTK builds from source on a provisioned host; the build time +
      host spec are recorded.
- [ ] With patched WebKitGTK + the activated seam wiring, an `ipfs://` page registers
      AND runs ONE service worker end-to-end (SW `fetch` observed), proven by a
      dedicated off-core-gate step on the provisioned host. The core `zig build test`
      gate is UNTOUCHED and stays green.
- [ ] The fork cost is MEASURED and recorded (build time, patch rebase friction
      across 1–2 releases), completing the keep-fork-vs-defer-vs-shim ratification
      data alongside the locate-and-draft task's patch size + upstream draft.
- [ ] The seam contract is unchanged: SW-capability is the `service_worker_capable`
      trait declared AT the seam (a `WezigRenderer` reproduces it with no patch); no
      chrome reaches past the seam (`chrome_conformance` stays green).
- [ ] Every claim traces to a real build/measurement; the patched build is clearly a
      spike artifact, NOT wired into release/distribution.

## Blocked by

- `spike-webkitgtk-sw-scheme-patch-locate-and-draft` — this task consumes the patch
  it captures + the seam trait + the stubbed wiring it lands. Also needs a
  provisioned build host (a human on a capable machine).

## Prompt

> Goal: apply the patch from `spike-webkitgtk-sw-scheme-patch-locate-and-draft`,
> BUILD patched WebKitGTK, prove one live service worker hosts on a secure `ipfs://`
> page, and MEASURE the fork cost (build time + rebase friction) — the last data for
> a human to ratify keep-fork vs defer-to-`WezigRenderer` vs loopback-shim (ADR-0016
> d.6). This is HARDWARE-GATED: it needs a provisioned build host (~40-60 GB disk,
> 16 GB+ RAM, cmake+ninja+ruby, hours), so it is `humanOnly` and run on a capable
> machine, not the dev box or the bare CI runner.
>
> Consume from the locate-and-draft task: the `.patch` in its sidecar, the seam's
> `service_worker_capable` trait, and the STUBBED `SystemWebviewRenderer` wiring
> (activate it against the patched header — call
> `webkit_security_manager_register_uri_scheme_as_service_worker_capable` when the
> trait is declared). Fetch matching WebKitGTK source, apply the patch, build,
> record actual build time + host spec. Serve an `ipfs://` page (through
> `src/ipfs_scheme.zig`'s interception hook) that registers a service worker under
> Xvfb + the PATCHED WebKitGTK; observe the SW + its `fetch` run. Rebase the patch
> across 1-2 recent WebKit releases; record churn. Keep ALL of this OFF the core
> `zig build test` gate and off the bare CI runner (it needs the patched lib) — a
> manual/provisioned-host step. Record the build time + rebase friction into the
> fork-cost findings the locate-and-draft task started.
>
> Domain: ADR-0016, ADR-0005 (webview is a disposable first backend), ADR-0011,
> ADR-0015, the observation + seam extension the earlier tasks landed. "Done" =
> patched WebKitGTK built (time recorded), one live SW on a secure `ipfs://` page,
> fork cost measured, seam contract unchanged, core gate green, patched build marked
> a spike (not release-wired).
