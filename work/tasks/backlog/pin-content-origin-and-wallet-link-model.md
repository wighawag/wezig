---
title: Pin the content-addressed origin model (ENS→IPFS) + the per-origin wallet-link data model + seam per-origin binding
slug: pin-content-origin-and-wallet-link-model
spec: explore-web3-capabilities
blockedBy: []
covers: [1, 3]
---

## What to build

Pin the ORIGIN MODEL that everything web3 binds to, and the data model + seam
shape that follow from it (ADR-0015 decisions 1–3). This is a decision/data-model
deliverable (a doc + a small typed model behind the seam) + the confirmed seam
extension, NOT the full wallet or storage subsystem.

- **The content-addressed origin model.** Define "origin" as the **content-addressed
  (IPFS) address**, the STRONGEST origin — including when a site is reached via an
  **ENS name** (ENS = a mutable pointer that resolves TO an IPFS origin; the origin
  wezig keys trust on is the IPFS one). Define the **ENS-repoint flow**: a repoint
  is a NEW origin the user can ACCEPT to carry existing data (localStorage, wallet
  link, …) forward — a user-authorised origin-to-origin carry-forward.
- **The per-ORIGIN wallet-link data model.** Pin the schema: a wallet link (accounts
  granted, permission grant, selected EVM chain) is keyed by **content origin, NOT
  tab**. Two tabs on the SAME origin SHARE one link; different origins are
  independent (each possibly a different chain). Define how the provider binding
  consults this model.
- **The seam per-origin binding.** Confirm + shape the `Renderer`-seam extension:
  the page↔native provider channel is bound **per ORIGIN** (replacing today's single
  hardcoded `"wezig"` channel), so concurrent origins each get their own binding.
  Express it at the seam so a `WezigRenderer` reproduces it.

## Acceptance criteria

- [ ] A doc/ADR-grounded model defines the content-addressed origin as the origin
      (ENS resolves TO it) and the ENS-repoint "accept new origin, carry data
      forward" flow, anchored on ADR-0015 decisions 1–2.
- [ ] A per-ORIGIN wallet-link data model (schema + how the provider binding
      consults it) exists: same-origin tabs share a link, different origins are
      independent (each may hold a different EVM chain), keyed by content origin.
- [ ] The `Renderer`-seam per-origin provider binding is defined + expressed at the
      seam (replacing the single hardcoded channel), so it survives the
      `WezigRenderer` swap; consistency with `chrome_conformance` preserved.
- [ ] Tests cover the data model + the binding lookup (same-origin-shares /
      cross-origin-isolates) per the repo's test style; the v0 gate stays green. If
      the model persists to a shared/global location, tests isolate it to a temp dir
      and assert the real one is untouched.

## Blocked by

- None — can start immediately. (Supplies the origin/link model
  `spike-wallet-broker-eip6963-provider` binds requests to; that spike proves one
  request carries its origin, this task pins the schema + the multi-origin binding.)

## Prompt

> Goal: pin the content-addressed ORIGIN model + the per-ORIGIN wallet-link data
> model + the seam's per-origin provider binding (spec `explore-web3-capabilities`,
> stories 1 + 3; ADR-0015 decisions 1–3). This is the trust-boundary model
> everything web3 keys on — a decision/data-model deliverable + a confirmed seam
> extension, NOT the wallet or storage subsystem.
>
> FIRST reconcile against reality (drift check): the seam's script bridge is proven
> but `setScriptMessageHandler` today hardcodes ONE channel (`"wezig"`) — the shell
> findings (`docs/shell-exploration-findings.md` §1) explicitly flag that
> `explore-web3-capabilities` must decide if more are needed; the answer (ADR-0015
> decision 2) is per-ORIGIN binding, so shape that. Ground the origin thesis in
> `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`
> (content-addressed origin = the strongest origin; ONE origin = ONE trust boundary
> for localStorage + wallet link + encryption + signature-binding; the wallet link
> is keyed by ORIGIN, not tab — two same-origin tabs SHARE it).
>
> Define: origin = the IPFS content address (ENS resolves TO it, is a mutable
> pointer); the ENS-repoint flow (new origin the user accepts to carry data
> forward); the per-origin wallet-link schema (accounts/grant/selected EVM chain,
> keyed by content origin; same-origin tabs share, different origins independent);
> and the seam's per-origin provider binding replacing the single channel. Keep it
> testable and behind the seam. This is exploration: pin the model + the binding
> shape; do NOT build the storage subsystem, the encryption, or the multi-chain
> switching UX.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0011, ADR-0015,
> `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`,
> `docs/shell-exploration-findings.md` §1/§4. "Done" = the origin model + ENS-repoint
> flow are pinned, the per-origin wallet-link model + seam binding exist and are
> tested (same-origin-shares / cross-origin-isolates), and the v0 gate stays green.
