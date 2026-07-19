---
title: Content-addressed origin as a STRONGER origin + origin-bound / non-interactive signatures (wezig's web3 UX thesis)
slug: web3-origin-and-signature-ux-thesis-wighawag-blog
source: 'Two blog posts by the project author (wighawag / ronan.eth): "3 Proposals For Making Web3 A Better Experience" (2018-10-12, https://ronan.eth.limo/blog/3-proposals-for-making-web3-a-better-experience) and "Automatic Authentication Signatures For Web3" (2019-01-15, https://ronan.eth.limo/blog/automatic-authentication-signatures-for-web3), retrieved 2026-07-19; ratified as design intent for explore-web3-capabilities by the author in-session.'
---

This finding records the DESIGN INTENT wezig's native web3 capabilities are built
to realise — the author's own published web3-UX thesis, ratified in-session as
load-bearing input to `explore-web3-capabilities`. It is external/domain ground
truth in the sense that it is a fixed, citable design position the wallet + IPFS
work integrates with; the ADR the exploration produces DECIDES against it, this
note preserves the WHY.

## 1. Content-addressed origin is a STRONGER origin (the root idea)

The web's same-origin policy gates access to per-origin data (cookies,
localStorage) WITHOUT asking the user, and that automatism is only possible
because the browser can check a document's origin BY ITSELF. Traditionally the
origin is a DNS domain, so the guarantee rests on DNS security + trusting the
domain owner not to change the app's content/logic at whim.

An **IPFS/content-addressed origin encodes the HASH of the content**, so it is a
*stronger* origin than a domain: the app owner cannot change the content or logic
without also changing the origin. The browser can verify the fetched bytes belong
to the origin (they hash to it). This is the direct expression of ADR-0011
("prefer verifiable/content-addressed content over server-authoritative"): the
content-addressed origin is not merely supported, it is the STRONGEST origin the
browser recognises.

- **Mixed-content caution (carried over from the blog):** when content-addressed
  content fetches NON-verifiable subresources, that is web3 "mixed content" (the
  analogue of https-fetching-http) and the browser must treat it with the same
  care — the strong-origin guarantee only covers what is actually hash-verified.

## 2. The ENS + IPFS origin model (ratified in-session, 2026-07-19)

Decided by the author for wezig specifically (extends the blog's origin idea):

- **The ORIGIN is the IPFS (content) address, EVEN when the site is reached via
  an ENS name.** An ENS name is a mutable POINTER to a content hash; the security
  origin wezig binds storage/permissions to is the **IPFS origin it currently
  resolves to**, not the ENS name. So the strong (content-addressed) origin is
  what owns localStorage, wallet permissions, encryption scope, etc.
- **ENS-repoint = a NEW origin the USER can accept to carry data forward.** When an
  ENS name is updated to point at a NEW IPFS hash (a new app version), that is a
  new origin. The browser must let the user ACCEPT the new IPFS origin so they can
  CONTINUE with their existing local storage / data from the previous origin
  (a user-authorised origin-to-origin data carry-forward). This is the concrete,
  wezig-specific realisation of the blog's "transfer access to private data from
  one origin to another, guarded by clear user authorization" and its
  "application encrypts data for a FUTURE origin so a trusted app can upgrade its
  hash without re-authorising" mechanism.

- **ONE ORIGIN = ONE TRUST BOUNDARY FOR EVERYTHING (ratified 2026-07-19).** The
  content-addressed origin is the single key for ALL per-origin state: localStorage,
  wallet permissions/link, encryption scope, AND signature origin-binding. They are
  not separate boundaries that happen to align — they are the SAME boundary, keyed
  by the content hash.

- **The WALLET LINK is keyed by ORIGIN, not by tab (ratified 2026-07-19).**
  Consequence of the above: two tabs on the SAME (content-addressed) origin SHARE
  one wallet link — same accounts, same permission grant, same selected chain,
  exactly as they share localStorage. Two tabs on DIFFERENT origins get INDEPENDENT
  wallet links (each its own grant, each possibly a different EVM chain). So the
  page-facing provider binding the seam must carry is **per-ORIGIN**, not per-tab and
  not a single global channel: tabs multiplex onto the origin they belong to. (This
  corrects an earlier "per-tab wallet channel" framing — the unit is the origin.)

## 3. Origin-bound signatures (reduce authorization fatigue WITHOUT losing security)

The blog's Proposal 2 + the non-interactive-decryption idea, applied to wezig:

- **Authorization fatigue IS a security risk.** Asking the user to confirm
  low-risk actions too often trains them to blindly accept — including the
  dangerous ones. Security and usability are not opposed here; excessive prompts
  HURT security.
- **Origin checks let the browser safely automate what belongs to one origin.**
  Just as the web grants localStorage/cookie access to the same origin with no
  prompt, wezig can (a) **non-interactively DECRYPT** data whose encoded allowed
  origin(s) match the requesting document's origin (if the app encrypted it, a
  malicious version of that same app already had the plaintext — so no prompt adds
  security), and (b) **automated origin checks for SIGNATURES** (EIP-712): bind a
  signature to the requesting origin so a malicious app cannot trick the user into
  signing data destined for ANOTHER app (the "Bob's app mimics Alice's app"
  attack). Cross-origin data transfer stays behind an explicit user prompt.

## 4. Non-interactive AUTHENTICATION signatures (the second post)

- Web3 apps commonly authenticate a user by asking the wallet to sign a message
  (proving control of the address) — replacing password sign-up. Done naively
  (static message, always-confirm) it causes fatigue AND is replay-vulnerable.
- **A dedicated AUTHENTICATION-signature standard** would let wallets RECOGNISE
  an auth-signature request (an envelope type, e.g. over EIP-712) and perform it
  WITHOUT a confirmation popup, safely — because the verifier injects unforgeable
  data (CSRF-token-like) so it cannot be replayed, and the user has nothing to
  verify by hand (the payload is verifier-generated). Confirming such a signature
  would not add security; it only adds fatigue. Compatible with smart-contract
  wallets via ERC-1271 / ERC-1654. This is a SUPERSET relationship with the
  origin-bound non-interactive signatures above (either unforgeable-data OR
  origin-check suffices).

## What this means for `explore-web3-capabilities` (the build inputs)

- The wallet permission model is **ORIGIN-BOUND**, where "origin" is the
  IPFS/content origin (ENS names resolve TO it). Signature requests are bound to
  the requesting origin (EIP-712 origin check) so cross-app signature confusion is
  prevented by the BROWSER, not left to the user.
- The browser should distinguish **signing/state-changing wallet methods**
  (require approval, origin-bound) from **read-only methods** (`eth_call`,
  `eth_accounts` disclosure policy) — see the Decisions in the spec / ADR.
- **Non-interactive signatures (auth + origin-bound-decrypt) are a first-class
  UX goal, not an afterthought** — they are the whole point of "better web3 UX
  without sacrificing security." The exploration should RECOMMEND how wezig
  recognises and safely automates these classes (an EIP envelope wezig honours),
  even if the spike only proves one interactive round-trip first.
- **Encryption for a FUTURE origin** enables trusted content-addressed apps to
  upgrade their hash and carry user data forward without re-authorisation — the
  mechanism behind the ENS-repoint "accept new origin, continue with your data"
  flow.
