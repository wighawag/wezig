---
title: Spike ipfs:// as a first-class secure origin — fetch+verify one CID and host one service worker
slug: spike-ipfs-secure-origin-service-worker
spec: explore-web3-capabilities
blockedBy: []
covers: [2]
---

## What to build

Prove native content-addressed resolution AND that `ipfs://` is a first-class
SECURE origin on the narrowest real case (ADR-0015 decisions 6 + 7): serve ONE
`ipfs://` CID through the `Renderer` seam's custom-scheme interception hook,
HASH-VERIFY the bytes locally (reject on mismatch), register the scheme as a
SECURE origin, and prove content served over it can host ONE service worker. This
de-risks the IPFS attach + the secure-origin seam extension, NOT the IPFS
subsystem.

- **Fetch + verify one CID (verified-gateway depth first).** Reuse the landed
  `net.Fetcher` + `ContentAddress.verify`/`fetchVerified` (`src/networking.zig`):
  fetch one CID's bytes (from a gateway — untrusted transport) and verify they hash
  to the content address; a mismatch REJECTS. This is depth (i) of ADR-0015
  decision 6; embed/bound-node/`ipns://` are the build's job (record the depth
  ladder for the findings task, don't build it).
- **Serve it through the interception hook.** Register `ipfs://` via the seam's
  `registerScheme` so requests are served from native with the verified bytes
  (the NATIVE/context interception layer, per
  `work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`).
- **Secure origin + one service worker.** Register `ipfs://` with SECURE-ORIGIN
  security traits (the seam must gain the ability to declare scheme security traits
  — secure/CORS/local — not just body+content-type today) and prove a page served
  over `ipfs://` can register + run ONE service worker. This confirms the seam
  extension ADR-0015 decision 7 requires.

## Acceptance criteria

- [ ] One `ipfs://` CID is fetched and HASH-VERIFIED locally (reject on mismatch)
      through the `net.Fetcher`/`ContentAddress` seam, served via the custom-scheme
      interception hook — proven by a test.
- [ ] `ipfs://` is registered as a SECURE origin (the seam can declare scheme
      security traits), and a page served over `ipfs://` registers + runs ONE
      service worker, proven end-to-end.
- [ ] The seam extension (scheme security traits) is expressed at the `Renderer`
      seam so a `WezigRenderer` must reproduce it, not as a one-off webview call.
- [ ] The findings note records the IPFS depth ladder (verified-gateway default →
      bound node → in-browser node; user's own node always allowed; `ipns://` in
      scope) per ADR-0015 decision 6.
- [ ] The verify/seam-contract half runs in the display-free `zig build test` gate
      (fake fetcher + fake scheme handler); the live webview service-worker leg is a
      dedicated off-core-gate step/CI leg (ADR-0007). The v0 gate stays green.
- [ ] Tests cover fetch+verify + the secure-origin/SW path. If anything persists to
      a shared/global location (e.g. SW registrations), tests isolate it to a temp
      dir and assert the real one is untouched.

## Blocked by

- None — can start immediately.

## Prompt

> Goal: spike `ipfs://` as a first-class SECURE origin on the narrowest case —
> fetch+verify one CID through the seam and host ONE service worker over it (spec
> `explore-web3-capabilities`, story 2; ADR-0015 decisions 6 + 7). De-risking the
> attach + the secure-origin seam extension, NOT the IPFS subsystem.
>
> FIRST reconcile against reality (drift check): the verify-half is already built —
> `net.Fetcher` + `ContentAddress.verify`/`fetchVerified` in `src/networking.zig`
> (`work/tasks/done/spike-networking-fetch-verify.md`,
> `work/notes/findings/networking-http-tls-pick-libcurl-2026-07-18.md`): fetch bytes,
> verify they hash to the address, reject on mismatch — reuse it, do NOT rebuild it.
> The seam's custom-scheme interception (`registerScheme`) is proven
> (`seam-script-bridge-and-interception`, `src/renderer.zig`). The TWO-LAYER finding
> `work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`
> is load-bearing: custom-scheme interception is the NATIVE/context layer where
> `ipfs://` is served; whether content served there can HOST a service worker depends
> on registering the scheme's SECURITY TRAITS (secure/CORS) at the same layer
> (WebKitGTK `WebKitSecurityManager` register_uri_scheme_as_secure/_cors_enabled).
> Today `registerScheme` carries only body+content-type — this task adds the ability
> to declare scheme security traits at the seam (secure origin), the extension
> ADR-0015 decision 7 names.
>
> Prove: fetch+verify one CID (verified-gateway depth — the default of ADR-0015
> decision 6; record the fuller depth ladder + `ipns://`-in-scope for the findings
> task, don't build them), serve it via the interception hook, register `ipfs://`
> as a secure origin, and register+run ONE service worker on an `ipfs://` page. Keep
> the verify + seam-contract half in the display-free `zig build test` gate (fake
> fetcher + fake scheme handler); put the live webview-SW leg in a dedicated
> off-core-gate step + CI leg (mirror the `webview` leg — it needs Xvfb +
> WebKitGTK, ADR-0007). The v0 gate stays green.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0011, ADR-0015,
> `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`
> (content-addressed origin = the strongest origin). Exploration, NARROWEST case:
> one CID, one SW; do NOT build the IPFS subsystem, IPNS resolution, or a node.
> "Done" = one CID fetch-verified + served + hosting one service worker over a
> secure `ipfs://` origin, the seam extension expressed at the seam, findings
> recorded, v0 gate green.
