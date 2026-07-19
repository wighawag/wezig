---
title: IPFS integration depth ladder — verified-gateway-first, backed by the one proven resolution path
date: 2026-07-19
status: open
kind: finding
forTask: native-web3-findings-and-build-plan
source: ADR-0015 decision 6 (spec explore-web3-capabilities, story 4) + the proven resolution path in this repo (`net.Fetcher` + `ContentAddress.verify`/`fetchVerified` in src/networking.zig; served through the `Renderer` seam's interception hook by src/ipfs_scheme.zig) + the two-layer finding sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md
---

The STORY-4 DEPTH RECOMMENDATION for the follow-on IPFS build spec, backed by the
ONE resolution path `spike-ipfs-fetch-verify-and-secure-origin-seam` actually
exercised: fetch one CID's bytes from an untrusted gateway and HASH-VERIFY them
locally, served through the `Renderer` seam's custom-scheme interception hook
(`src/ipfs_scheme.zig` in the display-free `zig build test` gate; the live
WebKitGTK secure-origin leg is `zig build ipfs-secure-origin-test`). This records
the ladder for the build spec to commit to — it does NOT build the deeper rungs.

## The depth ladder (ADR-0015 decision 6): the DEFAULT and the ordering

The verify CONTRACT is identical across every depth — "the bytes must hash to the
content address, or REJECT" (`ContentAddress.verify`, ADR-0011). Only HOW a
`ContentAddress` is constructed (from the CID grammar) and HOW the bytes are
SOURCED changes per rung. So the depth is a transport/sourcing choice layered on
one unchanged trust core.

1. **(i) Verified gateway — the DEFAULT, and the one this spike PROVED.** Fetch a
   CID's bytes from an HTTP(S) IPFS gateway (untrusted transport), then hash-verify
   locally. The gateway is a dumb pipe; the math is the trust, so a malicious or
   buggy gateway cannot forge content for a CID (it can only fail to deliver, or
   deliver bytes that get rejected). This is the lowest-friction rung (no node to
   run, no DHT), already built end-to-end here (`net.fetchVerified` +
   `ipfs_scheme.IpfsSchemeHandler`), so it is the shipping DEFAULT.
2. **(ii) Bound external node — always allowed, the power-user path.** Point wezig
   at an EXISTING IPFS node (e.g. kubo over its HTTP API / gateway) the user runs
   separately. Same verify contract; the "gateway" URL is just the user's own node.
   The user running their OWN node is ALWAYS allowed regardless of the default
   (ADR-0015 decision 6) — it is strictly more trustworthy transport than a public
   gateway, and needs no new trust code (it reuses rung (i)'s fetch+verify).
3. **(iii) In-browser full node — the aspirational later default.** Embed an IPFS
   node (DHT participation, block exchange) IN the browser, so resolution needs no
   external gateway at all. This is the heaviest rung (its own subsystem: peer
   discovery, bitswap, datastore, resource budget) and is explicitly the rung that
   "may become the default later" (ADR-0015 decision 6), NOT v1. It still rides the
   same verify contract; it changes only sourcing (local block store / DHT instead
   of an HTTP fetch).

**Recommended ordering for the build spec:** ship (i) as the default + (ii) as an
always-available option first (both are the SAME fetch+verify code, differing only
in the configured source URL); schedule (iii) as a later, opt-in rung that may be
promoted to default once it is proven and its resource cost is acceptable.

## `ipns://` is IN SCOPE (ADR-0015 decision 6)

`ipns://` (mutable content-addressed naming) is in scope alongside `ipfs://`. It
resolves an IPNS name to a current CID (via the DHT / a resolver), then the SAME
fetch+verify-of-that-CID applies. The mutability lives in the NAME→CID resolution
step; once resolved to a concrete CID the trust core is unchanged. The build spec
owns the IPNS resolver (and its own freshness/verification story for the
name-record); this spike did not exercise it.

## What the build spec must build that this spike deliberately did NOT

- **The CID grammar.** This spike is handed a `ContentAddress` + source URL
  directly (`ipfs_scheme.CidMapping`); decoding a real `ipfs://…` / `ipns://…`
  string (multibase + multihash + codec/version) into a `ContentAddress` is the
  build's job. Only SHA-256 exists in the verifier today (`HashAlgo`); the CID
  decoder adds the other multihash algorithms behind the unchanged verify contract.
- **Subresource / mixed-content policy.** The strong content-addressed origin only
  covers HASH-VERIFIED bytes. A verified `ipfs://` page fetching an unverifiable
  `http://` subresource is the IPFS analogue of https→http mixed content and needs
  the same care (ADR-0015 threat analysis; the two-layer finding §1). The build
  spec decides the policy.
- **Service-worker HOSTING on `ipfs://`.** OUT of scope here and NOT a depth-ladder
  rung: it is a separate BACKEND-capability problem (stock WebKitGTK hard-rejects
  `serviceWorker.register()` on non-HTTP(S) schemes), delivered by a carried
  WebKitGTK fork patch proven by `spike-webkitgtk-sw-scheme-patch` (ADR-0016). The
  SECURE-ORIGIN trait declaration this spike DID add (`ipfs://` treated as secure)
  is necessary-but-not-sufficient for SW-hosting and works on stock WebKitGTK.
