---
title: Spike ipfs:// fetch+verify one CID through the interception hook + the secure-origin scheme-security-traits seam extension
slug: spike-ipfs-fetch-verify-and-secure-origin-seam
spec: explore-web3-capabilities
blockedBy: []
covers: [2, 4]
---

## What to build

Prove native content-addressed resolution AND the SECURE-ORIGIN seam extension on
the narrowest real case (ADR-0015 decisions 6 + 7; **re-scoped by ADR-0016**):
serve ONE `ipfs://` CID through the `Renderer` seam's custom-scheme interception
hook, HASH-VERIFY the bytes locally (reject on mismatch), and add the seam's
ability to declare a scheme's SECURITY TRAITS (secure/CORS/local) so `ipfs://` is
registered as a SECURE origin. This de-risks the IPFS attach + the secure-origin
seam extension.

> **Re-scope note (ADR-0016).** This task is the DELIVERABLE HALF of the original
> `spike-ipfs-secure-origin-service-worker`. The original also required proving a
> service worker HOSTED on an `ipfs://` page end-to-end; the exploration verified
> LIVE that stock WebKitGTK HARD-REJECTS `serviceWorker.register()` on any
> non-HTTP(S) scheme at the WebCore engine level with no public allowlist API
> (`work/notes/observations/webkitgtk-service-worker-hard-restricted-to-http-https-2026-07-19.md`).
> ADR-0016 decided SW-hosting is delivered separately via a carried WebKitGTK fork
> patch (proposed upstream, not depended on) proven by `spike-webkitgtk-sw-scheme-patch`,
> with `WezigRenderer` the eventual restriction-free home. So THIS task drops the
> SW-end-to-end criterion and lands the clean, self-contained secure-origin seam
> extension + fetch/verify, which are unaffected by the WebKit SW limit.

- **Fetch + verify one CID (verified-gateway depth first).** Reuse the landed
  `net.Fetcher` + `ContentAddress.verify`/`fetchVerified` (`src/networking.zig`):
  fetch one CID's bytes (from a gateway — untrusted transport) and verify they hash
  to the content address; a mismatch REJECTS. This is depth (i) of ADR-0015
  decision 6; embed/bound-node/`ipns://` are the build's job (record the depth
  ladder for the findings task, don't build it). Do NOT rebuild the verify half.
- **Serve it through the interception hook.** Register `ipfs://` via the seam's
  `registerScheme` so requests are served from native with the verified bytes
  (the NATIVE/context interception layer, per
  `work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`).
- **Secure-origin scheme-security-traits seam extension.** Extend the `Renderer`
  seam so the backend can declare a scheme's SECURITY TRAITS (secure/CORS/local),
  not just body+content-type today, and register `ipfs://` as a SECURE origin. The
  WebKitGTK backend wires this to `WebKitSecurityManager`
  (`register_uri_scheme_as_secure` / `_as_cors_enabled`); express the TRAIT
  declaration AT the seam so a `WezigRenderer` reproduces it. This is the seam
  extension ADR-0015 decision 7 names — and it WORKS on WebKitGTK (the origin IS
  treated as secure; only the separate SW-protocol allowlist fails, which is
  ADR-0016 / `spike-webkitgtk-sw-scheme-patch`'s concern, NOT this task's).

## Acceptance criteria

- [ ] One `ipfs://` CID is fetched and HASH-VERIFIED locally (reject on mismatch)
      through the `net.Fetcher`/`ContentAddress` seam, served via the custom-scheme
      interception hook — proven by a test in the display-free `zig build test` gate.
- [ ] The `Renderer` seam gains a scheme-security-traits declaration
      (secure/CORS/local) so `ipfs://` is registered as a SECURE origin; the trait
      declaration is expressed AT the seam (so a `WezigRenderer` must reproduce it),
      not as a one-off webview call — proven by a seam-contract test with a fake
      backend in the core gate.
- [ ] If a live WebKitGTK leg proves the real backend marks the origin secure
      (via `WebKitSecurityManager`), it is a dedicated off-core-gate step/CI leg
      mirroring the `webview` leg (Xvfb + WebKitGTK, ADR-0007) — NOT in the core
      gate. (SW-hosting is explicitly OUT of scope here — see the re-scope note;
      that lives in `spike-webkitgtk-sw-scheme-patch`.)
- [ ] The findings note records the IPFS depth ladder AS THE STORY-4 DEPTH
      RECOMMENDATION (verified-gateway default → bound node → in-browser node; user's
      own node always allowed; `ipns://` in scope), BACKED BY the one proven
      resolution path this task exercises, per ADR-0015 decision 6 (spec story 4).
- [ ] The verify/seam-contract half runs in the display-free `zig build test` gate
      (fake fetcher + fake scheme handler); the v0 gate stays green.
- [ ] Tests cover fetch+verify + the secure-origin trait declaration. If anything
      persists to a shared/global location, tests isolate it to a temp dir and
      assert the real one is untouched.

## Blocked by

- None — can start immediately. (Independent of `spike-webkitgtk-sw-scheme-patch`,
  which proves the SEPARATE SW-hosting patch; this task delivers the fetch/verify
  + secure-origin seam extension that patch builds ON.)

## Prompt

> Goal: spike `ipfs://` fetch+verify one CID through the seam's interception hook
> AND add the secure-origin scheme-security-traits seam extension (spec
> `explore-web3-capabilities`, stories 2 + 4; ADR-0015 decisions 6 + 7; re-scoped
> by ADR-0016). De-risking the IPFS attach + the secure-origin seam extension, NOT
> the IPFS subsystem and NOT service-worker hosting.
>
> FIRST reconcile against reality (drift check): the verify-half is already built —
> `net.Fetcher` + `ContentAddress.verify`/`fetchVerified` in `src/networking.zig`
> (`work/tasks/done/spike-networking-fetch-verify.md`): fetch bytes, verify they
> hash to the address, reject on mismatch — reuse it, do NOT rebuild it. The seam's
> custom-scheme interception (`registerScheme`) is proven
> (`seam-script-bridge-and-interception`, `src/renderer.zig`). Today `registerScheme`
> carries only body+content-type — this task adds the ability to declare scheme
> SECURITY TRAITS (secure/CORS/local) at the seam, the extension ADR-0015 decision 7
> names.
>
> IMPORTANT scope boundary (ADR-0016): SERVICE-WORKER HOSTING on `ipfs://` is OUT of
> scope for this task. The exploration verified live that stock WebKitGTK hard-rejects
> `serviceWorker.register()` on non-HTTP(S) schemes with no public allowlist knob
> (`work/notes/observations/webkitgtk-service-worker-hard-restricted-to-http-https-2026-07-19.md`);
> ADR-0016 delivers SW-hosting via a carried WebKitGTK fork patch proven by the
> SEPARATE `spike-webkitgtk-sw-scheme-patch`. Here, prove ONLY: fetch+verify one CID
> served through the hook, and the secure-origin TRAIT declaration at the seam (the
> origin IS treated as secure by WebKitGTK — that part works). Do NOT attempt to
> register a service worker.
>
> Keep the verify + seam-contract half in the display-free `zig build test` gate
> (fake fetcher + fake scheme handler); if you add a live WebKitGTK "origin is
> secure" proof, put it in a dedicated off-core-gate step + CI leg mirroring the
> `webview` leg (ADR-0007). Record the IPFS depth ladder + `ipns://`-in-scope for the
> findings task (don't build them). Domain vocabulary + framing: `CONTEXT.md`,
> ADR-0011, ADR-0015, ADR-0016,
> `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`
> (content-addressed origin = the strongest origin),
> `work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`.
> "Done" = one CID fetch-verified + served through the hook, the secure-origin
> scheme-security-traits seam extension expressed at the seam + tested, depth ladder
> recorded, v0 gate green. SW-hosting is a separate task.
