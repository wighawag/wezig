---
title: Spike the wallet broker boundary + EIP-6963 provider — one origin-bound eth_requestAccounts round-trip
slug: spike-wallet-broker-eip6963-provider
spec: explore-web3-capabilities
blockedBy: []
covers: [1]
---

## What to build

Prove the wallet's SECURITY BOUNDARY + the page-facing provider on the NARROWEST
real case (ADR-0015 decisions 4 + 5): a page discovers an EIP-6963 provider,
calls `eth_requestAccounts` ONCE, and the request crosses the `Renderer` seam's
script bridge to a **dedicated signing BROKER** (its own process/sandbox) that
holds a THROWAWAY test key, decides, and replies — the page never sees key
material. This is a de-risking spike of the boundary + provider shape, NOT the
wallet.

- **The broker boundary.** A separate broker process/sandbox owns the test key
  and does the "decide + sign/return accounts" step; the page-world provider only
  REQUESTS over the bridge (the seam's `injectUserScript` + `setScriptMessageHandler`
  + `evaluateScript`, proven by `seam-script-bridge-and-interception`). Prove the
  page→broker→page round-trip end-to-end for `eth_requestAccounts` against a
  throwaway key (NEVER real custody). The boundary must be expressed at the seam so
  it holds after the `WezigRenderer` swap.
- **EIP-6963 discovery.** Advertise the provider via EIP-6963 (Multi Injected
  Provider Discovery) — `eip6963:announceProvider` / `eip6963:requestProvider`,
  NOT a bare `window.ethereum` — so it can coexist with extension wallets and be
  discovered per origin.
- **Origin-bound.** The request is bound to the requesting CONTENT origin (ADR-0015
  decision 2): record the origin the grant/approval is keyed to (the per-origin
  binding data model is pinned by `pin-content-origin-and-wallet-link-model`; here
  just prove one request carries + is keyed by its origin).
- Keep any on-screen/webview/broker-process leg OUT of the display-free
  `zig build test` gate (ADR-0007); the seam-contract half (provider ↔ broker
  message shape) is pure Zig and runs in the core gate with a fake bridge + a fake
  broker.

## Acceptance criteria

- [ ] A page-world EIP-6963 provider is injected via the seam and one
      `eth_requestAccounts` round-trips page → broker → page, proven by a test.
- [ ] The signing/custody step runs in a broker boundary SEPARATE from the
      page/content side (its own process or an equivalently isolated boundary
      expressed at the seam); the page never receives key material — only a
      request/response. A THROWAWAY test key is used; no real custody.
- [ ] The provider is discovered via EIP-6963 (announce/request events), not a
      bare `window.ethereum`.
- [ ] The request is keyed to the requesting content origin (origin-bound), per
      ADR-0015.
- [ ] The seam-contract half runs in the display-free `zig build test` gate (fake
      bridge + fake broker); any live webview/broker-process leg is a dedicated
      off-core-gate step/CI leg (ADR-0007). The v0 gate stays green.
- [ ] Tests cover the round-trip + the boundary. If the broker persists anything
      to a shared/global location, tests isolate it to a temp dir and assert the
      real one is untouched.

## Blocked by

- None — can start immediately. (Pairs with `pin-content-origin-and-wallet-link-model`
  for the origin-binding data model, but does not block on it — prove one request
  carries its origin; the model task pins the schema.)

## Prompt

> Goal: spike the wallet BROKER boundary + the EIP-6963 provider on the narrowest
> case — one origin-bound `eth_requestAccounts` round-trip through a dedicated
> signing broker, against a THROWAWAY test key (spec `explore-web3-capabilities`,
> story 1; ADR-0015 decisions 4 + 5). This is de-risking the SECURITY BOUNDARY, not
> building the wallet. NEVER store or use a real private key.
>
> FIRST reconcile against reality (drift check): the `Renderer` seam's script-bridge
> hooks (`injectUserScript`/`setScriptMessageHandler`/`evaluateScript`) are proven
> (`work/tasks/done/seam-script-bridge-and-interception.md`, ADR-0005/0006,
> `src/renderer.zig`, `docs/shell-exploration-findings.md` §1 + §4). The shell
> findings §4 already define the boundary: "page-world provider (untrusted, content
> process) posts a `request` over the script bridge; native (trusted, out-of-page)
> decides and replies; the page never gets key material." Build on that. Note the
> shell finding that today `setScriptMessageHandler` hardcodes ONE channel
> (`"wezig"`) — one channel is enough for THIS single-provider spike; the
> per-origin multi-binding is pinned by `pin-content-origin-and-wallet-link-model`.
>
> Model on ADR-0015: advertise the provider via EIP-6963 (announce/request events),
> not `window.ethereum`; put custody+signing in a broker with its own
> process/sandbox that the page reaches only by REQUEST over the bridge; bind the
> request to the requesting content origin. Prove ONE `eth_requestAccounts`
> round-trip. Keep the seam-contract half (provider↔broker message shape) in the
> display-free `zig build test` gate using a fake bridge + fake broker; put any live
> webview/real-broker-process leg in a dedicated off-core-gate step + CI leg
> mirroring the `webview`/`networking` legs (ADR-0007). Record the broker IPC shape
> + the EIP-6963 payload you settled as a finding for the build plan.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0011, ADR-0015,
> `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`
> (origin-bound signatures + authorization fatigue). This is exploration on the
> NARROWEST case: one request, prove-the-boundary; do NOT build the wallet, signing
> UX, or multi-chain. "Done" = one origin-bound `eth_requestAccounts` round-trips
> through a real broker boundary via an EIP-6963 provider, the page never sees the
> key, the seam-contract test is in the core gate, and the v0 gate stays green.
