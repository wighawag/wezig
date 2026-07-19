---
title: review-gate non-blocking nits for 'pin-content-origin-and-wallet-link-model' (Gate 2 approve)
date: 2026-07-19
status: open
reviewOf: pin-content-origin-and-wallet-link-model
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'pin-content-origin-and-wallet-link-model' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify the in-memory-only WalletLinkStore decision: the store deliberately does NOT persist links (unlike renderer_swap.DomainAllowList), on the grounds that persistence entails the storage subsystem + encryption-at-rest (ADR-0015 decision 3), both explicitly out of scope. This is recorded in a clear DECISION block in the module doc and is well-reasoned; confirming it is the intended boundary.
  (src/web3_origin.zig WalletLinkStore doc 'DECISION: this store is IN-MEMORY only'; spec scopes out storage/encryption; because nothing persists, no shared-write isolation test is needed and none is present (correct).)
- Ratify the new channel-naming convention channel_prefix='wezig:' (a per-origin channel name is the prefix ++ the CID). This is an in-scope design default the task did not spell out; it reuses the existing 'wezig' channel token as a prefix so it is coherent, but it is a user-invisible wire default worth a human nod.
  (src/web3_origin.zig channel_prefix + OriginProviderBinding.channelName/originForChannel; replaces the single hardcoded 'wezig' channel per ADR-0015 decision 2.)
- Doc imprecision (cosmetic): the module repeatedly refers to 'the seam's ScriptMessageCallback.name' but name is the onMessage(ctx, name, body) PARAMETER, not a field on the ScriptMessageCallback struct (which is {ctx,onMessage}). The substance (the seam carries the channel name to the handler) is correct and verified.
  (src/renderer.zig:110 ScriptMessageCallback has no name field; name is delivered via firePageMessage/onMessage param. web3_origin.zig lines 327/414/426.)
