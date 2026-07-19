---
title: Extensions gated by CAPABILITY COMPOSITION — warn only on the dangerous COMBINATION (network × local/inject), not per-permission
slug: capability-composition-extension-permissions-warn-on-dangerous-combination
---

A proposed design direction for wezig's extension support (input to the
`explore-webextensions-runtime`-style follow-on the wallet-custody finding
recommends, and to the "build our own extension API vs reuse Firefox's" question
it leaves open). Ratified in-conversation by the author 2026-07-19. This is an
IDEA (pre-spec), not a decision — it belongs in the WebExtensions follow-on's
scope, not the current exploration's build.

## The core idea: safety is a property of the CAPABILITY COMBINATION, not a flat permission list

An extension's install-time trust prompt should be driven by which CAPABILITIES it
requests and — crucially — HOW THEY COMPOSE, not by enumerating permissions the
user reads and ignores. The security-relevant fact is that DANGER LIVES IN THE
CONJUNCTION of a "read sensitive data" capability and a "send data out"
capability; either alone is safe.

Concretely (the author's examples):

- **No internet AND no script injection** (no `fetch`-granting capability) → the
  extension CANNOT exfiltrate anything: it has neither a channel to read
  cross-origin/sensitive data nor a channel to send it out. **Provably safe by
  capabilities → install with NO warning.**
- **Internet access but NO special local access / powerful features** → it can
  talk to the network but has nothing sensitive to leak. **Safe → NO warning.**
- **Local access / script injection (which can reach `fetch`) but NO independent
  network-exfiltration capability beyond the page's own** → still safe on its own.
- **BOTH network access AND (local access OR script injection)** → this is the
  dangerous combination: a channel to obtain sensitive data (page contents,
  cross-origin reads, injected script's reach) TIMES a channel to send it to an
  attacker. **This — and essentially only this — warrants a CLEAR install-time
  warning.**

The general rule: an EXFILTRATION capability (outbound network the page wouldn't
otherwise have) combined with an ACQUISITION capability (script injection / broad
local/host access / cross-origin read) is the thing to warn on. Neither factor
alone is a warning; their PRODUCT is.

## Why this matters (and why it's in-thesis for wezig)

- **It fixes the real failure of today's model.** Chrome/Firefox show a flat list
  of scary permissions at install ("read and change all your data on all
  websites", "access your data for all sites"), which trains users to click
  through — authorization fatigue, the SAME security anti-pattern the wallet
  thesis calls out (`web3-origin-and-signature-ux-thesis-wighawag-blog.md`: too
  many low-signal prompts HURT security). Capability composition lets wezig stay
  SILENT for the provably-safe majority and warn LOUDLY only for the genuinely
  dangerous combination — fewer, higher-signal prompts.
- **It is the ADR-0011 trust thesis applied to extensions.** wezig doesn't trust
  the origin by default; likewise it shouldn't trust an extension by default, but
  it CAN prove some extensions safe by construction (their capability set has no
  exfiltration path) and grant them silently — the same "the browser can safely
  automate what it can verify by itself" move ADR-0011/ADR-0015 make for
  same-origin data. Safety-by-capabilities is verifiable; a permission label is
  not.

## The load-bearing consequence: build-our-own-API vs reuse-Firefox's

This is why it was raised now — it bears on the WebExtensions follow-on's central
build question (the wallet-custody finding
`wallet-custody-webextensions-and-non-interactive-signatures-2026-07-19.md` §2
recommends native-first + a separate WebExtensions exploration, but leaves the
API-surface choice open):

- **The WebExtensions/`chrome.*`/`browser.*` (MV3) model is PERMISSION-based, not
  capability-COMPOSITION-based.** Its `permissions` / `host_permissions` /
  `activeTab` / `optional_permissions` map to individual grants and a flat
  install prompt. It does NOT natively express "this capability SET has no
  exfiltration path, therefore no warning." So wezig's model is NOT a subset of
  the Firefox API — it is a DIFFERENT trust lens laid over the capabilities.
- **BUT the two are not mutually exclusive.** The likely sweet spot (to evaluate
  in the follow-on): REUSE most of the Firefox/`browser.*` API surface for
  COMPATIBILITY (so real extensions run — the whole point of extension-compat),
  while REPLACING the install-time consent MODEL with wezig's capability-
  composition analysis. I.e. wezig would MAP a manifest's declared permissions →
  wezig capabilities → run the composition analysis → decide warn/no-warn, rather
  than surfacing Chrome/Firefox's flat list. The API a well-behaved extension
  CALLS can stay largely Firefox-compatible; the TRUST DECISION wezig makes about
  installing it is wezig's own.
- **Open questions for the follow-on to answer** (do NOT decide here): (1) can
  every dangerous `chrome.*`/`browser.*` capability be classified cleanly as
  acquisition vs exfiltration, or are there ambiguous ones (e.g.
  `declarativeNetRequest`, `webRequest`, native messaging, `downloads`) that are
  BOTH or escape the model? (2) does mapping Firefox permissions → wezig
  capabilities lose fidelity or create false-safe classifications (the dangerous
  case — a "safe" verdict on something that can actually exfiltrate)? (3) is a
  first-class wezig capability MANIFEST worth defining for extensions AUTHORED for
  wezig, alongside the Firefox-compat import path for existing ones? (4) how does
  this compose with the wallet case specifically — a wallet extension by
  definition sees signing traffic, so where does it land in the acquisition ×
  exfiltration grid, and does it ALWAYS warn?

## Scope / status

- IDEA, pre-spec. It does NOT change the current `explore-web3-capabilities`
  exploration or its build (the wallet is native-first; extension-compat is
  already a separate follow-on). It ADDS a design constraint the WebExtensions
  follow-on exploration must carry: evaluate a capability-composition consent
  model that warns only on the exfiltration combination, and decide the
  reuse-Firefox-API-but-replace-the-consent-model split against it.
- `web3-capabilities-findings-and-build-plan` (story 6) should REFERENCE this idea
  where it records the WebExtensions follow-on in the build plan, so the
  capability-composition consent model is on that exploration's charter from the
  start rather than discovered late.
