---
title: Evaluate wallet custody options + WebExtensions wallet-compat + non-interactive signature classes (written recommendation)
slug: evaluate-custody-and-extension-compat
spec: explore-web3-capabilities
blockedBy: []
covers: [3]
---

## What to build

The EVALUATE-and-RECOMMEND deliverable for the security-critical choices ADR-0015
settled in DIRECTION but that a build spec must commit against with a written,
threat-analysed recommendation (story 1, the highest-judgement area). This is a
DOCUMENT (a findings doc + ADR input), NOT wallet code. No real key is stored.

- **Custody recommendation.** Evaluate + recommend the key-storage stack per
  ADR-0015 decision 3: **OS keychain primary** (Secret Service/libsecret, macOS/iOS
  Keychain, Android Keystore) with per-platform notes; **encrypted-at-rest fallback**
  when a keychain is unavailable (a vetted KDF + AEAD — @noble-family / libsodium
  class, NEVER hand-rolled crypto); **hardware-wallet as first-class**. Threat-analyse
  each (exfiltration surface, platform coverage, the owned-crypto residual).
- **WebExtensions wallet-compat evaluation (the big alternative).** Evaluate
  supporting real Chrome/Firefox extension wallets (ideally MetaMask-compatible) as
  an ALTERNATIVE/COMPLEMENT to a native wallet. State honestly what it costs — a
  WebExtensions RUNTIME (`manifest.json`, background/service-worker, `chrome.*`/
  `browser.*` APIs, content-script injection, permissions) is its own large
  subsystem — and the compatibility ceiling. RECOMMEND whether it is a follow-on
  exploration/build of its own vs a native-wallet-first path. Do NOT build a
  WebExtensions runtime here.
- **Non-interactive signature classes.** Recommend how wezig recognises + safely
  automates the low-fatigue signature classes from the thesis: origin-bound
  automatic decryption, and an authentication-signature envelope wezig performs
  WITHOUT a confirmation popup when the verifier injects unforgeable data (per
  `web3-origin-and-signature-ux-thesis-wighawag-blog`). Name the standard shape
  (e.g. an EIP-712 envelope type; ERC-1271/1654 for contract wallets) without
  committing the wire format.

## Acceptance criteria

- [ ] A findings doc recommends the custody stack (keychain primary / encrypted
      fallback / hardware first-class) with a per-option threat analysis, anchored on
      ADR-0015 decision 3.
- [ ] The doc evaluates WebExtensions wallet-compat (MetaMask-compatible) honestly —
      cost (a WebExtensions runtime is its own subsystem) + compatibility ceiling —
      and recommends native-first vs its own follow-on spec. No runtime is built.
- [ ] The doc recommends how wezig recognises + automates non-interactive signature
      classes (origin-bound decryption + auth-signature envelope with unforgeable
      data), grounded in the thesis finding, without committing the wire format.
- [ ] Every claim traces to ADR-0015, the thesis finding, or an observed fact (no
      speculation dressed as a recommendation); this is documentation only and the v0
      gate stays green.

## Blocked by

- None — can start immediately.

## Prompt

> Goal: write the EVALUATE-and-RECOMMEND deliverable for wezig's wallet custody,
> the WebExtensions wallet-compat alternative, and the non-interactive signature
> classes (spec `explore-web3-capabilities`, story 1; ADR-0015 decision 3). This is
> the highest-judgement, security-critical area: a WRITTEN, threat-analysed
> recommendation a build spec commits against — NOT wallet code. Store no real key.
>
> Custody: recommend OS keychain primary (per-platform: Secret Service/libsecret,
> macOS/iOS Keychain, Android Keystore), encrypted-at-rest fallback when unavailable
> (vetted KDF+AEAD, @noble/libsodium class — NEVER hand-rolled crypto, per the
> C-library-binding ethos), hardware-wallet first-class; threat-analyse each.
> WebExtensions: evaluate supporting real Chrome/Firefox (MetaMask-compatible)
> extension wallets HONESTLY — it needs a WebExtensions runtime (manifest,
> background SW, chrome.*/browser.* APIs, content scripts, permissions), a large
> subsystem — and recommend native-first vs a dedicated follow-on spec; do NOT build
> a runtime. Non-interactive signatures: recommend how wezig recognises + safely
> automates origin-bound decryption + an auth-signature envelope performed without a
> popup when the verifier injects unforgeable data (name the shape, e.g. an EIP-712
> envelope + ERC-1271/1654 for contract wallets; don't commit the wire format).
>
> Ground EVERYTHING in ADR-0015 and
> `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`
> (authorization fatigue is a security risk; origin-bound + non-interactive
> signatures reduce it without losing security). Domain vocabulary: `CONTEXT.md`,
> ADR-0011. This is exploration: evaluate + recommend so the build spec can commit;
> do NOT build the wallet, the crypto, or a WebExtensions runtime. "Done" = a reader
> can, from this doc alone, commit the custody stack + know the WebExtensions
> cost/decision + know how non-interactive signatures are recognised, each
> threat-analysed and traced to ADR-0015 / the thesis; v0 gate green.
