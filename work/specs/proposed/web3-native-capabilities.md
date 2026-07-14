---
title: Native web3 capabilities — built-in Ethereum provider (EIP-1193) and native IPFS
slug: web3-native-capabilities
humanOnly: true
needsAnswers: true
taskedAfter: [usable-browser-webview-shell]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

<!-- open-questions -->

## Open questions

These gate tasking this spec (`needsAnswers: true`). They are the security-critical and integration-depth forks; these are the ORIGINAL browser-spec Ethereum/IPFS questions, now owned here.

1. **Ethereum wallet security model** (was browser-spec Q3, security-critical). Where and how are private keys stored (OS keychain, encrypted-at-rest, hardware-wallet support)? What is the signing/approval UX? Which chains beyond Ethereum mainnet? What exactly does the page-facing provider expose (EIP-1193 `request`, which RPC methods, the permission model)? This is the highest-judgement area in the whole project.
2. **IPFS integration depth** (was browser-spec Q2). What does "native IPFS" mean concretely: embed a full IPFS node (Zig/Rust) in-process, bind an existing node (e.g. kubo) over its API, or resolve via a trusted gateway with content-hash verification? And is `ipns://` in scope alongside `ipfs://`?
3. **Attachment at the `Renderer` seam.** ADR-0005 says these capabilities attach via the seam's script-message bridge (inject a page-world EIP-1193 provider, receive `request` calls, post results back) and its request-interception / custom-scheme hook (serve `ipfs://` natively). Ratify that the seam surface (owned by `usable-browser-webview-shell` Q2) is sufficient for BOTH the webview backend AND `WezigRenderer`, so these features are written once and work whichever backend renders the page.
4. **Provider ↔ wallet process boundary.** Given the process/sandbox model (owned by `usable-browser-webview-shell` Q3), where does key custody and signing run relative to the page-facing provider? A browser holding keys must not expose them to page/renderer processes; define that boundary before any key touches the code.

<!-- /open-questions -->

## Problem Statement

wezig's reason to exist beyond rendering the standard web is treating capabilities a complete browser ought to have as first-class rather than leaving them to third-party extensions: a native Ethereum provider (EIP-1193) for connecting to and signing for on-chain apps, and native IPFS content resolution. Mainstream browsers omit these (Brave is a notable exception that ships a native Ethereum provider); reaching on-chain apps means grafting an extension onto a browser with no native notion of accounts or signing, and IPFS content is reached through HTTP gateways (a trust and UX compromise, not real content-addressing).

## Solution

Attach both capabilities at the `Renderer` seam (ADR-0005) so they are backend-agnostic and ship EARLY on the system-webview backend, before the native renderer is ready:

- A **built-in Ethereum provider (EIP-1193 RPC)** injected into the page world via the seam's script-message bridge: the page calls `request(...)`, the native side handles accounts/permissions/signing behind a well-defined security boundary, and results are posted back. Key custody and signing run outside the page/renderer process per the ratified process model.
- **Native IPFS resolution** via the seam's request-interception / custom-scheme hook: an `ipfs://` (and possibly `ipns://`) request is served as verified content-addressed data — embedded node, bound node, or verified gateway per the ratified integration depth — not proxied opaquely through an HTTP gateway.

Because both attach at the seam, they are written once and work whether a page is rendered by the webview backend (now) or `WezigRenderer` (later).

## User Stories

1. As a page, I want to request accounts and signatures from wezig's built-in Ethereum provider (EIP-1193) natively, so that users transact without a third-party extension.
2. As a user, I want my wallet keys stored and signing approved through a trustworthy, well-defined security model, so that a browser holding keys is safe to use.
3. As a user, I want a clear signing/approval UX in the chrome, so that I understand and consent to each request a page makes.
4. As a user, I want to open an `ipfs://` address and have wezig resolve and verify the content natively, so that content-addressed sites load without a gateway.
5. As a developer, I want the provider and IPFS handlers to attach at the `Renderer` seam (script bridge + request interception), so that they work identically on the webview backend and the native renderer.
6. As a developer, I want key custody and signing to run outside the page/renderer process, so that no page or renderer bug can exfiltrate keys.

## Out of Scope

- The `Renderer` seam itself and the chrome — that is `usable-browser-webview-shell` (this spec CONSUMES the seam's script-bridge and interception hooks).
- The native rendering engine — that is `native-renderer-conformance` (these capabilities are backend-agnostic).
- Chains, protocols, and node choices beyond what the open questions ratify — kept deliberately open until the security and integration-depth forks are decided.
