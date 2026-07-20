---
status: accepted
---

# Prioritise `WezigRenderer` for the don't-trust features; keep the webview backend with ACCEPTED degraded features (ipfs:// service workers do NOT work on it)

The `spike-webkitgtk-sw-scheme-patch-build-and-measure` spike (ADR-0016 d.6) BUILT
a patched WebKitGTK and measured the fork's real cost. The result revises
ADR-0016's "carry a minimal fork patch" plan: the minimal patch removes the
`serviceWorker.register()` block but does NOT deliver a working SW `fetch`
round-trip on an `ipfs://` origin, and closing that gap means fighting WebKit's
content-process SW internals — an engine we do not control. So we DECIDE: make
`WezigRenderer` (our own engine, where we own the scheme registry) the home for
the don't-trust features a system webview resists, and keep the webview backend as
the compatibility path with those specific features ACCEPTED as degraded /
unavailable rather than force-fitted via a fork.

## Context — what the spike measured

On a provisioned host (16 cores) the carried patch: rebased cleanly onto WebKitGTK
2.52.3 (policy hunks verbatim on the sibling CORS/secure surface; only mechanical
file-set growth); BUILT in ~57 minutes into a private prefix; exported the patched
symbols (`nm` confirmed); and REMOVED the `serviceWorker.register()` rejection on
`ipfs://`. But the off-core-gate `ipfs-sw-hosting-test` leg (register + `clients.claim()`
+ fetch a sentinel + assert the SW `fetch` marker) FAILED with
`ServiceWorkerFetchNotObserved` on the patched build: register is unblocked, a full
SW `fetch` round-trip is not achieved, and WebKitGTK does not surface the SW-internal
reason without content-process debugging. Build deps also exceeded the paper list
(`-DENABLE_SPEECH_SYNTHESIS=OFF`, `-DUSE_LIBBACKTRACE=OFF`, the `unifdef` tool,
`-DENABLE_WEBDRIVER=OFF`), discoverable only by building.

## Decision

1. **`WezigRenderer` is the primary home for the don't-trust / content-addressed
   features a system webview resists** — chief among them `ipfs://` hosting a
   service worker. In our own engine we own the scheme registry + the SW plumbing,
   so it is a native capability: no fork, no upstream dependency, no fighting an
   engine we do not control. The concrete, evidence-backed instance of ADR-0005's
   "why the native renderer matters" and ADR-0017's "the owned engine avoids
   inheriting an incumbent's restrictions".
2. **Keep the system-webview backend as the COMPATIBILITY path, with the
   webview-resistant features ACCEPTED as degraded/unavailable on it.** wezig still
   ships usably on WebKitGTK now (ADR-0005) and renders the normal web; but
   `ipfs://`-hosted service workers (and anything needing SW-fetch interception on a
   custom scheme) are NOT available on the webview backend. The chrome degrades
   gracefully (surface "unavailable on this backend", never crash/mis-behave). The
   seam already models this: `service_worker_capable` is declared uniformly and a
   backend that cannot honour it leaves the hook effectively no-op (ADR-0016 d.5),
   so the degradation is expressible at the seam and disappears under `WezigRenderer`.
3. **Do NOT carry the WebKitGTK fork for SW-hosting.** ADR-0016's "carry a minimal
   patch" is SUPERSEDED for SW-hosting: the measured patch is necessary-but-not-
   sufficient (unblocks register, not fetch), so carrying it buys an incomplete
   capability at the cost of a per-release WebKit fork build (~1hr compile + a
   maintenance tail) — a trade that does not clear the bar. The rebased patch + the
   measurements are RETAINED as evidence (findings + sidecar), and
   `-Dsw-patch`/`-Dsw-webkit-prefix` stay a spike-only build option (never
   release-wired) so the experiment is reproducible, but the fork is NOT adopted.
   The drafted upstream proposal MAY still be filed — if upstream ever makes
   custom-scheme SW-hosting fully work, the webview backend regains the feature for
   free — but wezig does not wait on it and does not carry the incomplete patch.
4. **The loopback-shim fallback (ADR-0016 option) is not pursued now** — it
   fabricates an `https://` origin that is not the CID, conflicting with the
   content-addressed-origin thesis (ADR-0011/0015); `WezigRenderer` is the cleaner
   answer. Available only if a webview-only SW capability becomes urgent before
   `WezigRenderer` is ready.

## Consequences

- The web3/IPFS build plan's SW-hosting story is now DECIDED per backend: webview =
  no `ipfs://` SW hosting (accepted degradation); `WezigRenderer` = native SW
  hosting (no patch). The follow-on IPFS build spec starts from this.
- `WezigRenderer` gains priority + a concrete, measured capability driver beyond
  conformance: the don't-trust features incumbents structurally resist. Sharpens
  the conformance-ladder work (ADR-0012) with a feature-driven target.
- The chrome needs a "feature unavailable on this backend" affordance — a small,
  honest degradation surface (consistent with ADR-0011's "the trust posture is a
  product surface"). A follow-on chrome task.
- The spike is a SUCCESS: its job (ADR-0016 d.6) was to MEASURE the fork so the
  choice is evidence-based. It measured it; the evidence says DEFER to
  `WezigRenderer`.

## Note

This revises the SW-hosting DELIVERY decision of ADR-0016 (which pinned "carry a
minimal fork patch") in light of the spike ADR-0016 commissioned; ADR-0016's
analysis (the two-gate WebKit blocker, the seam trait, `WezigRenderer` as eventual
home) stands — only the near-term "carry the fork" recommendation is downgraded to
"defer to `WezigRenderer`; keep the patch as reproducible evidence, not an adopted
fork". No real custody/secret/release path is touched. `WezigRenderer` remains a
separate, deferred, seam-gated build (ADR-0017).
