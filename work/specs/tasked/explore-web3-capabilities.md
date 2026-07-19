---
title: Explore — native web3 capabilities (prove EIP-1193 + IPFS attach at the seam, decide the security model)
slug: explore-web3-capabilities
humanOnly: true
taskedAfter: [explore-webview-shell]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

> **This is an EXPLORATION-scoped spec.** Its deliverable is CONFIDENCE + a de-risked plan for wezig's differentiators — NOT a finished wallet or a production IPFS stack. It proves that an EIP-1193 provider can be injected at the `Renderer` seam's script-bridge and round-trip ONE real call (`eth_requestAccounts`) on the webview backend, and that ONE `ipfs://` fetch+verify can be served through the interception hook, and it EVALUATES/RECOMMENDS the security-critical wallet model rather than building it. The actual wallet (key custody, signing UX, chains) and the production IPFS integration are follow-on BUILD specs, written once this exploration decides the model and proves the seam attachment. The security-critical build must not start on guesses.

## Resolved decisions (the four open questions, answered by the human 2026-07-19)

The `needsAnswers` gate is CLEARED. The decisions are pinned in **ADR-0015** and
grounded in `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`
(the author's published web3-UX thesis). Reconciliation note: this spec was authored
BEFORE the seam spikes landed; it has drifted FORWARD — prior exploration already
de-risked much of it (the `Renderer` seam's two web3 hooks are proven; the
content-address verify-half is built as `net.Fetcher` + `ContentAddress.verify`; the
shell findings §4 already observed the process/sandbox model + the wallet-broker
boundary). The tasks build ON that landed ground.

1. **Wallet security model (Q1).** Origin-keyed wallet; custody = **OS keychain
   primary + encrypted-at-rest fallback (vetted crypto, never hand-rolled) +
   hardware-wallet first-class**; **WebExtensions (MetaMask-compatible) wallet-compat
   EVALUATED as a future path, not built** (a WebExtensions runtime is its own
   subsystem). Provider advertised via **EIP-6963** (not bare `window.ethereum`);
   method surface **split by risk** — signing/state-changing/disclosure methods
   require explicit out-of-page approval and are **origin-bound** (EIP-712 origin
   check), read-only (`eth_call`, …) is supported ungated; **multi-EVM-chain**;
   **non-interactive (origin-bound + auth) signatures a first-class UX goal**. Full
   threat analysis in ADR-0015.
2. **IPFS depth (Q2).** Support **all** depths (verified-gateway / bound-node /
   in-browser full node); **default to verified-gateway first**, in-browser node as
   an option that may become the later default, and **always allow the user's own
   external node**; **`ipns://` in scope**. The verify contract is identical across
   depths.
3. **Seam sufficiency (Q3).** The seam carries both capabilities, with **two
   confirmed extensions fed back**: (a) **per-ORIGIN provider binding** — the wallet
   link is keyed by content origin, so two tabs on the same origin SHARE a link and
   different origins are independent (replaces the single hardcoded `"wezig"`
   channel); (b) **scheme security traits** — `ipfs://` is registered as a **secure
   origin (the strongest)** so it can host **service workers**.
4. **Provider↔wallet boundary (Q4).** A **dedicated signing BROKER (own
   process/sandbox)** holds keys + signs; the page-world provider only REQUESTS over
   the bridge; the page never sees key material. Holds after the `WezigRenderer`
   swap. The exploration **spikes the broker boundary** against a throwaway test key.

## Problem Statement

wezig's reason to exist beyond rendering is treating a native Ethereum provider (EIP-1193) and native IPFS resolution as first-class rather than extension-grafted: mainstream browsers reach on-chain apps via third-party extensions and IPFS via HTTP gateways (a trust + UX compromise). But the wallet is the most security-critical part of the whole project, and "native IPFS" has several very different meanings. Before committing to a build, we need CONFIDENCE that these capabilities attach cleanly at the `Renderer` seam (so they work on the webview backend NOW and the native renderer later), and a DECIDED, threat-analysed security model — not code written on guesses.

## Solution

Explore, don't build the wallet. Spike the seam attachment: inject an EIP-1193 provider into the page world via the seam's script-message bridge and round-trip one real `eth_requestAccounts` (against a throwaway/test key, no production custody), and serve one `ipfs://` request through the interception hook, fetching and hash-verifying one CID. In parallel, EVALUATE and RECOMMEND the wallet security model (key storage, signing UX, permission model, chains) and the IPFS integration depth, and DEFINE the provider↔wallet process boundary — all as decisions (with a threat analysis for the wallet), captured in an ADR. Feed any seam insufficiency back to `explore-webview-shell`. Output: proof the seam carries both capabilities + a decided security model + a de-risked build plan — never a real key in real custody.

## User Stories

1. As a developer, I want an EIP-1193 provider injected at the seam's script-bridge that round-trips one real `eth_requestAccounts` on the webview backend (against a test key), so that "the provider attaches at the seam" is proven, not assumed.
2. As a developer, I want one `ipfs://` request served through the seam's interception hook, fetching and hash-verifying one CID, so that native content-addressed resolution is proven end-to-end on the narrowest case.
3. As a developer, I want a written, threat-analysed RECOMMENDATION for the wallet security model (key storage, signing UX, permission model, chains) and the provider↔wallet process boundary, so that the security-critical build starts from a decided model, not guesses.
4. As a developer, I want a RECOMMENDATION on IPFS integration depth (embed / bind / verified-gateway; `ipns://` or not) backed by the one proven resolution path, so that the build spec can commit.
5. As a developer, I want confirmation (by attaching to it) that the pinned `Renderer` seam is sufficient for both capabilities across both backends, with any insufficiency fed back to `explore-webview-shell`, so that these features are written once and are backend-agnostic.
6. As a developer, I want a de-risked BUILD PLAN (the follow-on wallet spec and IPFS spec, their scope and ordering, with the security model already decided), so that the differentiators become a known quantity.

## Out of Scope (this is exploration)

- A production wallet — real key custody, hardware-wallet support, multi-chain signing, the full permission UX. The exploration DECIDES the model and proves the attachment; BUILDING the wallet is a follow-on spec.
- A production IPFS stack — the exploration proves ONE resolution path and recommends the depth; the real integration is a follow-on spec.
- The seam itself and the chrome (`explore-webview-shell`) and the native renderer (`explore-native-renderer`). No real private key is stored or used in this exploration.
