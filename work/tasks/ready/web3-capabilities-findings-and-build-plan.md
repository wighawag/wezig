---
title: Web3-capabilities exploration findings + de-risked, sliced build plan (the confidence deliverable)
slug: web3-capabilities-findings-and-build-plan
spec: explore-web3-capabilities
blockedBy: [spike-wallet-broker-eip6963-provider, spike-ipfs-fetch-verify-and-secure-origin-seam, pin-content-origin-and-wallet-link-model, evaluate-custody-and-extension-compat]
covers: [6]
---

## What to build

The exploration's actual DELIVERABLE (story 6): a written, durable report + a
de-risked, SLICED build plan capturing what the web3 spikes LEARNED, so the
follow-on wallet + IPFS BUILD specs are known quantities. Documentation (a
findings doc under `docs/`, pointing at ADR-0015), grounded in what the earlier
tasks actually observed — do NOT speculate where a spike produced a fact.

Synthesize from the four tasks:
- **The wallet broker boundary + EIP-6963 provider, proven**
  (`spike-wallet-broker-eip6963-provider`) — the page→broker→page round-trip, the
  broker's process/sandbox boundary, the EIP-6963 discovery shape, and what the
  spike revealed the `Renderer` seam still needed (if anything).
- **`ipfs://` fetch+verify + the secure-origin scheme-security-traits seam
  extension, proven** (`spike-ipfs-fetch-verify-and-secure-origin-seam`) — the
  fetch+verify path, the scheme-security-traits seam extension, and the IPFS depth
  ladder (verified-gateway default → bound node → in-browser node; user's own node;
  `ipns://` in scope). NOTE (ADR-0016): service-worker HOSTING on `ipfs://` is NOT
  provable on stock WebKitGTK (a WebCore http(s)-only allowlist with no public knob);
  the plan records that SW-hosting is delivered via a carried WebKitGTK fork patch
  (proposed upstream, not depended on) — the SEPARATE `spike-webkitgtk-sw-scheme-patch`
  proves + costs it — with `WezigRenderer` the eventual restriction-free home. Fold
  that finding + the fork-vs-defer-vs-shim decision into the build plan; do NOT block
  this synthesis on the (heavy) fork spike running.
- **The content origin + per-origin wallet-link model, pinned**
  (`pin-content-origin-and-wallet-link-model`) — the ENS→IPFS origin model, the
  ENS-repoint carry-forward flow, the per-origin (not per-tab) wallet link, and the
  seam's per-origin binding.
- **The custody + WebExtensions + non-interactive-signature recommendations**
  (`evaluate-custody-and-extension-compat`) — the decided custody stack, the
  WebExtensions-compat cost/decision, and the non-interactive signature classes.
- **The de-risked, SLICED BUILD PLAN** — which follow-on specs build the wallet
  (custody, signing UX, broker, multi-chain, EIP-6963 provider, origin-bound +
  non-interactive signatures) and native IPFS (CID/IPNS decoding, the depth ladder,
  the in-browser node), IN WHAT ORDER, each atomically taskable when authored, and
  which are their OWN explorations (e.g. a WebExtensions runtime).

## Acceptance criteria

- [ ] A findings doc under `docs/` captures each spike's outcome (broker+provider,
      ipfs-secure-origin+SW, origin+wallet-link model, custody/extension/signature
      recommendations) and any `Renderer`-seam gaps the spikes revealed.
- [ ] The doc points to ADR-0015 for the load-bearing decisions (and any follow-on
      ADRs the spikes produced) rather than re-deciding them.
- [ ] A de-risked, SLICED BUILD PLAN names the follow-on wallet + IPFS specs, their
      order, and which are their own explorations (WebExtensions runtime), so each
      can be authored + tasked atomically.
- [ ] Every claim traces to something an earlier task actually observed (no
      speculation dressed as a finding); the plan is consistent with ADR-0011/0015.
- [ ] The doc matches reality (spot-checked against the seams/code the spikes
      touched); documentation only, v0 build gate stays green.

## Blocked by

- `spike-wallet-broker-eip6963-provider`, `spike-ipfs-fetch-verify-and-secure-origin-seam`,
  `pin-content-origin-and-wallet-link-model`, `evaluate-custody-and-extension-compat`
  — this report synthesizes ALL the spike learnings, so it comes last. (It also
  REFERENCES `spike-webkitgtk-sw-scheme-patch` + ADR-0016 for the SW-hosting story
  but does NOT block on that fork spike, which may run much later — fold its
  decided direction into the plan from ADR-0016.)

## Prompt

> Goal: write the web3-capabilities exploration's confidence deliverable — a
> findings doc + a de-risked, SLICED build plan for the follow-on wallet + IPFS BUILD
> specs (spec `explore-web3-capabilities`, story 6). An exploration's "done" is
> CONFIDENCE + a plan, not a shipped wallet/IPFS stack. Documentation, grounded in
> what the earlier tasks actually observed — do not speculate where a spike produced
> a fact.
>
> Synthesize from: `spike-wallet-broker-eip6963-provider` (broker boundary + EIP-6963
> provider + one origin-bound round-trip), `spike-ipfs-secure-origin-service-worker`
> (fetch+verify + secure-origin + one SW + the depth ladder),
> `pin-content-origin-and-wallet-link-model` (ENS→IPFS origin + per-origin wallet
> link + seam binding), and `evaluate-custody-and-extension-compat` (custody +
> WebExtensions + non-interactive signatures). Point to ADR-0015 for the decisions.
> End with a de-risked, SLICED BUILD PLAN: which follow-on specs build the wallet and
> native IPFS, in what order, each atomically taskable, and which are their own
> explorations (a WebExtensions runtime especially).
>
> This is the analogue of `docs/native-renderer-exploration-findings.md` and
> `docs/shell-exploration-findings.md` — match that shape. Domain vocabulary +
> framing: `CONTEXT.md`, ADR-0011, ADR-0015, and every finding the spike tasks
> produced (esp. `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`).
> "Done" = a reader can, from this doc alone, author the follow-on wallet + IPFS
> build specs with the risky parts de-risked and the model decided; every claim
> traces to a spike; v0 gate green.
