---
title: Explore — native web3 capabilities (prove EIP-1193 + IPFS attach at the seam, decide the security model)
slug: explore-web3-capabilities
humanOnly: true
needsAnswers: true
taskedAfter: [explore-webview-shell]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

> **This is an EXPLORATION-scoped spec.** Its deliverable is CONFIDENCE + a de-risked plan for wezig's differentiators — NOT a finished wallet or a production IPFS stack. It proves that an EIP-1193 provider can be injected at the `Renderer` seam's script-bridge and round-trip ONE real call (`eth_requestAccounts`) on the webview backend, and that ONE `ipfs://` fetch+verify can be served through the interception hook, and it EVALUATES/RECOMMENDS the security-critical wallet model rather than building it. The actual wallet (key custody, signing UX, chains) and the production IPFS integration are follow-on BUILD specs, written once this exploration decides the model and proves the seam attachment. The security-critical build must not start on guesses.

<!-- open-questions -->

## Open questions

These gate tasking this spec (`needsAnswers: true`). Exploration exists to answer them; the wallet ones are decided by evaluation, not by building.

1. **Ethereum wallet security model** (was browser Q3, security-critical). Where and how are private keys stored (OS keychain, encrypted-at-rest, hardware-wallet support)? What is the signing/approval UX? Which chains beyond Ethereum mainnet? What exactly does the page-facing provider expose (EIP-1193 `request`, which RPC methods, the permission model)? The exploration EVALUATES and RECOMMENDS a model + threat analysis; it does NOT store a real key. Highest-judgement area in the project.
2. **IPFS integration depth** (was browser Q2). What does "native IPFS" mean: embed a full node (Zig/Rust) in-process, bind an existing node (e.g. kubo) over its API, or resolve via a trusted gateway with content-hash verification? Is `ipns://` in scope alongside `ipfs://`? The exploration proves ONE resolution path end-to-end (fetch + hash-verify one CID) and recommends the depth.
3. **Attachment at the `Renderer` seam.** Confirm the seam surface pinned by `explore-webview-shell` (script-message bridge + request-interception / custom-scheme hook) is sufficient for BOTH the webview backend AND `WezigRenderer`, by actually attaching to it in the spike. If it is not sufficient, that is a finding fed back to the seam.
4. **Provider ↔ wallet process boundary.** Given the process/sandbox model observed by `explore-webview-shell`, where does key custody + signing run relative to the page-facing provider? A browser holding keys must not expose them to page/renderer processes. The exploration DEFINES this boundary as a decision before any key touches real code.

<!-- /open-questions -->

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
