---
title: Wallet custody stack + WebExtensions wallet-compat + non-interactive signature classes (the security-critical EVALUATE-and-RECOMMEND deliverable)
slug: wallet-custody-webextensions-and-non-interactive-signatures
date: 2026-07-19
status: open
kind: finding
spec: explore-web3-capabilities
covers: [3]
source: 'ADR-0015 (decisions 3, 4, 5) + `work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md` (the author''s ratified web3-UX thesis) + ADR-0011 (the trust thesis) + the platform-keystore / WebExtensions / EIP-712 / ERC-1271 / ERC-6963 specs as cited inline. No real key was stored to produce this document; it is a written recommendation, not wallet code.'
---

This is the highest-judgement, security-critical deliverable of
`explore-web3-capabilities` (spec story 1; ADR-0015 decision 3). It is a WRITTEN,
threat-analysed RECOMMENDATION a follow-on wallet BUILD spec can commit against —
NOT wallet code, NOT crypto, NOT a WebExtensions runtime. It settles three
choices ADR-0015 pinned in DIRECTION but left for a build spec to commit against
with a threat analysis attached:

1. the **key-custody stack** (keychain primary / encrypted-at-rest fallback /
   hardware-wallet first-class), each option threat-analysed;
2. whether to support real **WebExtensions (MetaMask-compatible) extension
   wallets** — honestly costed (it is a WebExtensions RUNTIME, its own large
   subsystem) — with a native-first-vs-follow-on-spec recommendation;
3. how wezig **recognises + safely automates the non-interactive signature
   classes** (origin-bound automatic decryption + an auth-signature envelope
   performed without a popup when the verifier injects unforgeable data), naming
   the standard shape without committing the wire format.

Every claim below traces to ADR-0015, to the thesis finding, or to an observed
fact about a platform API / EIP; where a detail is deliberately deferred to the
build spec it is flagged as such. Nothing here is speculation dressed as a
recommendation.

## Placement / concept-coherence note (read first)

- **This doc is a `notes/findings/` recommendation, not a `docs/` synthesis.** The
  whole-exploration synthesis + build plan is story 6
  (`web3-capabilities-findings-and-build-plan`), which lists THIS task as an input
  ("the custody + WebExtensions + non-interactive-signature recommendations") and
  will fold it into the `docs/` findings doc. So this belongs in the finding
  bucket as the component recommendation story 6 synthesizes, not as a second
  top-level `docs/*-exploration-findings.md`. See `## Decisions` for the full
  rationale + the alternative considered.
- **No NEW named concept is introduced.** Every term used here already MEANS
  something in `CONTEXT.md` / ADR-0011 / ADR-0015 / the thesis and is used with
  that meaning: *origin* = the content-addressed (IPFS) origin (ADR-0015 d.1),
  *wallet link* = the per-origin permission grant (ADR-0015 d.2), *broker* = the
  dedicated signing process/sandbox (ADR-0015 d.5), *origin-bound* = the EIP-712
  origin check (ADR-0015 d.4). "Custody backend", "auth-signature envelope", and
  "verifier-injected unforgeable data" are descriptive labels for the ADR/thesis
  mechanisms, not new gates or new status words. The one lexical addition — the
  **non-interactive predicate** (§3.4) — is named as a description of the
  decision the broker already makes, not a new flag; it is called out in
  `## Decisions` so a reviewer can ratify the label.

---

## 1. Custody stack (ADR-0015 decision 3), threat-analysed per option

ADR-0015 decision 3 pins the DIRECTION: OS keychain primary, encrypted-at-rest
fallback, hardware-wallet first-class, "least crypto we own." This section
commits the concrete stack and threat-analyses each tier. The governing
constraints are ADR-0011's don't-trust-the-server / privacy / local-first stance
(keys are the user's, held locally, never uploaded) and the C-library-binding
ethos (`CONTEXT.md`): **wezig binds vetted, audited crypto rather than writing
its own** — the same reason it binds Skia/libcurl rather than reimplementing
rasterization or TLS. The whole stack sits BEHIND the broker boundary (ADR-0015
decision 5): whichever tier holds the key, the key material lives in the broker
process/sandbox and the page/content/renderer process only gets the ability to
REQUEST a signature over the bridge.

**Recommended custody policy (what the build spec commits to):** at account
creation the broker probes for custody backends in this order and uses the first
available, per account, recording which backend holds each key so the user can
see + migrate it:

1. **Hardware wallet** (if the user has one and chooses it) — first-class, not a
   bolt-on; the key never exists in wezig at all.
2. **OS keychain / keystore** — the default for a software key on a platform that
   has one.
3. **Encrypted-at-rest vault** — the fallback ONLY where (2) is unavailable or the
   user opts out of it; the largest owned-crypto residual, so the most tightly
   scoped.

### 1.1 Tier A — Hardware wallet (first-class)

**What it is.** The private key is generated and held on a dedicated device
(Ledger/Trezor-class); signing happens ON the device after a physical
confirmation; wezig sends the unsigned payload and receives a signature. wezig
holds NO key material for these accounts — the broker is a transport + policy
layer, not a custodian.

**Why first-class (per ADR-0015 d.3), not a later bolt-on.** Bolting hardware
support onto a software-custody design after the fact tends to leak
software-custody assumptions (e.g. "the broker can always produce a signature
synchronously") that a device violates (it can be unplugged, it prompts on-device,
it may reject). Treating it as first-class means the broker's signing interface is
async + refusable from day one, which the software tiers can also satisfy — so the
device is the SHAPING case, exactly as ADR-0015 d.3 says.

**Threat analysis.**
- *Exfiltration surface:* the smallest of any tier — the key never enters wezig's
  address space, so a full compromise of the wezig process (page, content,
  renderer, or even the broker) cannot exfiltrate it. This is the gold standard
  and the reason it anchors the stack.
- *Platform coverage:* the WEAKEST tier for coverage — requires the user to own a
  device and a working transport (USB/HID or WebHID-equivalent on desktop; Bluetooth
  or USB-OTG on mobile). Cannot be the DEFAULT because most users have no device;
  hence it is offered first-class but the keychain is the default software path.
- *Owned-crypto residual:* effectively zero for signing — the device owns the
  curve math. wezig owns only the transport framing (an APDU/Ethereum-app protocol
  it BINDS from the vendor SDK/spec, not hand-rolls) and the payload it asks the
  device to sign, which the origin-binding + non-interactive rules (§3) still
  govern.
- *Residual risks the build spec must handle:* transport-layer MITM /
  malicious-cable concerns are the device's own threat model (on-device display is
  the mitigation — the user verifies on the device), but wezig MUST render what it
  is asking the device to sign truthfully so the on-device confirmation is
  meaningful; and blind-signing (device shows a hash, not the decoded struct) is a
  known device-side weakness wezig should surface, not paper over.

### 1.2 Tier B — OS keychain / keystore (primary software default)

**What it is.** The platform's hardened secret store holds the key (or a
key-encryption key), gated by the OS (login session, biometric, secure enclave
where present). Per-platform, ALL of these are `C-library-binding` targets — bound,
not reimplemented:

- **Linux/BSD — Secret Service via `libsecret`** (the freedesktop Secret Service
  API, backed by GNOME Keyring / KWallet). Caveat the build spec must plan for:
  Secret Service requires a running secret-service daemon + an unlocked collection;
  on a headless or minimal session it may be ABSENT — which is exactly the trigger
  for the Tier C fallback (§1.3). This is the platform where "keychain unavailable"
  is most common, so it is the primary justification for having a fallback at all.
- **macOS / iOS — Keychain Services** (Security.framework; `kSecClass...`,
  Secure Enclave-backed keys where the hardware has one, biometric via
  `LAContext` / access control flags). Strongest of the software tiers: on
  Secure-Enclave hardware a key can be marked non-exportable so even the OS cannot
  read it out, only ask it to sign — approaching hardware-wallet properties for
  the enclave-supported curve(s).
- **Android — Android Keystore** (`AndroidKeyStore` provider; StrongBox / TEE-backed
  where the device has it, biometric via `BiometricPrompt` + key-use authorization).
  Same non-exportable-key property as iOS on TEE/StrongBox hardware.

**Threat analysis.**
- *Exfiltration surface:* small. On enclave/TEE/StrongBox hardware the raw key
  never leaves the secure element (non-exportable → sign-only), so even OS-level
  compromise cannot read it. On non-enclave hardware (older Linux especially) the
  store protects at-rest bytes but the key is decrypted into process memory to
  sign, so a compromised broker process could read it while in use — the broker
  sandbox (ADR-0015 d.5) is what shrinks that window, and the key still never
  reaches the page/content process.
- *Platform coverage:* good on macOS/iOS/Android (a keychain effectively always
  exists), variable on Linux (see the `libsecret` caveat) — the coverage gap the
  fallback exists to fill.
- *Owned-crypto residual:* the LOWEST of the software tiers (ADR-0015 d.3's "least
  crypto we own") — wezig owns only the binding to the platform store + the choice
  of key policy (biometric-gated, non-exportable where supported); the OS owns the
  KDF/AEAD/enclave. This is why it is the software DEFAULT.
- *Residual risks the build spec must handle:* biometric/lock policy (should a
  signature require a fresh biometric, or a session unlock?) is a per-method policy
  decision that intersects §3 (a non-interactive signature must NOT silently
  bypass a key that the user asked to be biometric-gated — the automation is about
  the CONFIRMATION PROMPT, not about weakening key access; see §3.5).

### 1.3 Tier C — Encrypted-at-rest vault (fallback ONLY; the owned-crypto residual)

**What it is.** Where no keychain is available (headless/minimal Linux, or a user
who declines the OS store) and no hardware wallet is used, wezig encrypts the key
at rest with a key derived from a user passphrase, using **vetted, audited
primitives bound as C libraries — NEVER hand-rolled crypto** (ADR-0015 d.3;
`CONTEXT.md` C-library-binding ethos). The concrete primitive pick (exact KDF +
AEAD) is a build-spec decision, but the CLASS is fixed here: a
memory-hard password KDF + an authenticated-encryption (AEAD) construction from a
libsodium / @noble-family / audited-equivalent library. Illustrative, not
committed: Argon2id (memory-hard KDF) → XChaCha20-Poly1305 or
XSalsa20-Poly1305 (`crypto_secretbox`) AEAD, all from libsodium. The build spec
picks and pins one; the RULE is: only well-reviewed constructions, no bespoke
constructions, no rolling our own AEAD/KDF/curve.

**Threat analysis (this is the tier that carries the most owned risk — ADR-0015's
"largest residual owned-crypto surface").**
- *Exfiltration surface:* the LARGEST of the three tiers. The ciphertext lives in
  an ordinary file the user's other software can read; security reduces to (a) the
  passphrase's entropy, (b) the KDF's resistance to offline brute force, and (c)
  the AEAD's integrity. A weak passphrase is directly brute-forceable offline once
  the file is exfiltrated — a risk the keychain/hardware tiers don't have. This is
  precisely why it is the FALLBACK, not a co-default, and why it is scoped to
  keychain-unavailable contexts.
- *Platform coverage:* universal (it is pure userspace crypto over a file) — that
  universality is its only advantage and the reason it backstops the coverage gaps
  of Tiers A/B.
- *Owned-crypto residual:* the ONLY tier where wezig's own choices are load-bearing
  for the key's secrecy. Mitigations, all build-spec obligations: bind audited
  primitives only; use memory-hard KDF parameters sized against modern offline
  attackers; authenticate the ciphertext (AEAD, so tampering is detected);
  zero key material in memory after use; never sync/upload the vault (ADR-0011
  local-first — the vault is the user's, it does not leave the device unless the
  user explicitly exports it); and consider unlocking the vault into the broker's
  sandbox only, never the content process.
- *Residual risks the build spec must handle:* passphrase UX (strength coaching,
  no silent weak default); rekey/rotation; and the "encrypt for a FUTURE origin"
  mechanism (thesis §2 / ADR-0015 d.1) reuses this SAME AEAD class for the
  ENS-repoint data-carry-forward, so the primitive choice here is also the
  primitive the origin-carry-forward feature inherits — pick once, reuse.

### 1.4 Cross-tier custody threat summary

| Threat | Hardware (A) | Keychain (B) | Encrypted-at-rest (C) |
|---|---|---|---|
| Key exfiltration on process compromise | none (key off-device) | none on enclave/TEE; window while decrypted otherwise | file readable → reduces to passphrase+KDF |
| Platform coverage | weakest (needs a device) | good; Linux gap via `libsecret` | universal |
| Owned-crypto residual | ~zero (device owns curve) | lowest software (OS owns KDF/AEAD) | HIGHEST (our KDF/AEAD choices load-bearing) |
| Default role | offered first-class | **software default** | fallback only (keychain-absent / opt-out) |

The stack is deliberately ordered so the DEFAULT path owns the least crypto
(ADR-0015 d.3) and the tier that owns the most crypto is the one used least. All
three sit behind the broker (ADR-0015 d.5): the page never holds key material
regardless of tier — that boundary is what makes "key exfiltration" a broker-scoped
threat, not a page-scoped one (ADR-0015 threat-analysis summary, key-exfiltration
row).

---

## 2. WebExtensions wallet-compat (ADR-0015 decision 3), evaluated honestly

ADR-0015 decision 3 records WebExtensions (MetaMask-compatible) wallet-compat as
an EVALUATED option, NOT built in this exploration, and asks for the cost + the
compatibility ceiling + a native-first-vs-follow-on-spec recommendation. This
section delivers that honestly. **No runtime is built here.**

### 2.1 What "support real extension wallets" actually requires (the cost)

To let a user install and run a real Chrome/Firefox extension wallet (MetaMask,
Rabby, Frame's extension, etc.) INSIDE wezig, wezig must implement a
**WebExtensions RUNTIME** — a browser-extension platform, which is its own large
subsystem, not a feature. Concretely it must provide, at minimum:

- **`manifest.json` parsing + the MV3 model** — parse and honour Manifest V3
  (Chrome has retired MV2; a modern MetaMask targets MV3), including the
  declared background type, content-script matches, web-accessible resources,
  and the permission set.
- **A background service worker host** — MV3 wallets run their core logic in a
  background service worker (ephemeral, event-driven, restartable). wezig would
  need to run untrusted extension JS in a background SW context with the
  extension lifecycle (install/enable/update/suspend/wake) and storage, wired
  into wezig's JS engine (the `ScriptEngine` seam, ADR-0013) — which today is not
  even bound yet (bind-first SpiderMonkey is itself future work).
- **The `chrome.*` / `browser.*` extension API surface** — the wallet calls
  `chrome.runtime`, `chrome.storage`, `chrome.tabs`, `chrome.scripting`/
  `chrome.declarativeNetRequest`, messaging (`runtime.sendMessage`/`connect`,
  `tabs.sendMessage`), alarms, notifications, idle, etc. Each is an API wezig
  must implement, security-review, and keep bug-compatible with real Chrome/Firefox
  behaviour or extensions break in subtle ways. This is a MOVING target (browser
  vendors evolve it continuously).
- **Content-script injection** — inject the extension's content scripts into
  matching pages at the right timing (`document_start`/`_end`/`_idle`) in an
  ISOLATED WORLD (a separate JS realm sharing the DOM but not page globals),
  because that is exactly how a wallet injects its EIP-1193 provider (`inpage.js`)
  and bridges it to its background SW. Isolated worlds are a non-trivial JS-engine
  integration.
- **The permissions model + install/consent UX** — host permissions,
  `activeTab`, optional permissions, the install-time and runtime consent
  prompts, and revocation — a whole trust surface of its own, on TOP of wezig's
  origin-trust model.
- **An extension store / sideload + update path** — where do extensions come from,
  how are they updated, how is malicious-extension risk managed (this is a large
  attack surface: a wallet extension by definition has powerful permissions and
  sees signing traffic).

That is a browser-subsystem's worth of work — comparable in scope to the shell or
the renderer explorations — and most of it (JS-engine isolated worlds, a bound JS
engine at all, an extension lifecycle host) sits on foundations wezig has NOT yet
built. ADR-0015 d.3's phrase "its own large subsystem, arguably its own
exploration" is, on inspection, an understatement: it is arguably its own
MULTI-spec track.

### 2.2 The compatibility ceiling (honest)

Even with a runtime, "MetaMask-compatible" has a ceiling that never reaches 1.0:

- **Bug-for-bug `chrome.*` fidelity is unbounded.** Real extensions depend on
  undocumented behaviours, timing, and quirks of Chrome/Firefox; matching enough
  to run today's MetaMask does not guarantee running tomorrow's, or Rabby, or the
  long tail. wezig would be perpetually chasing a spec it does not control.
- **The provider-injection path fights wezig's own model.** A MetaMask-style
  extension injects `window.ethereum` (or advertises via EIP-6963) from a content
  script. wezig's NATIVE provider ALSO advertises via EIP-6963 (ADR-0015 d.4).
  EIP-6963's multi-provider design means they CAN coexist at the discovery layer —
  which is a genuine point in favour of extension-compat (both show up in the
  dapp's provider list) — but the extension wallet's keys, permission model, and
  origin semantics are the EXTENSION's, NOT wezig's origin-bound model (ADR-0015
  d.1/d.2/d.4). So an extension wallet running in wezig would NOT get wezig's
  content-addressed-origin binding or its non-interactive-signature UX for free;
  it brings its OWN (DNS-origin, always-prompt) model. The differentiator wezig
  exists to build (thesis; ADR-0011) is precisely what an imported extension
  wallet does NOT deliver.
- **Security surface inversion.** The whole point of wezig (ADR-0011) is not
  trusting the origin/server by default and keeping trust boundaries explicit.
  Hosting arbitrary powerful extensions imports a large, hard-to-audit,
  vendor-driven trust surface — the opposite posture. It can be done SAFELY, but
  safely-hosting-untrusted-extensions is itself a hard security problem, not a
  freebie.

### 2.3 Recommendation: NATIVE-FIRST; WebExtensions is its own follow-on exploration/spec

**Recommend: build the NATIVE wallet first (the broker + EIP-6963 native provider
+ origin-bound + non-interactive signatures, ADR-0015 d.4/d.5), and treat
WebExtensions wallet-compat as a SEPARATE, LATER exploration+build track, NOT part
of the wallet build spec.** Rationale, each traced:

- The native path is what delivers wezig's actual differentiator (content-addressed
  origin-bound, low-fatigue, non-interactive-capable wallet UX — ADR-0011 + thesis).
  Extension-compat delivers COMPATIBILITY with the incumbent model, not the thesis.
  Native-first is thesis-first.
- The native path's foundations are proven/decided (the seam's script bridge +
  scheme interception are landed per the shell findings; the broker boundary + EIP-6963
  are ADR-0015 d.4/d.5 and are the subject of the sibling broker spike). The
  WebExtensions path's foundations are NOT — it needs a bound JS engine + isolated
  worlds + an extension lifecycle host that do not exist yet.
- Sequencing extension-compat AFTER a bound JS engine (ADR-0013) is not optional —
  it is a hard dependency (extensions ARE JS). So even if wanted, it cannot come
  first.
- EIP-6963 (ADR-0015 d.4) leaves the door OPEN: because wezig advertises its native
  provider via multi-provider discovery, adding extension-hosted providers LATER is
  additive, not a re-architecture. So native-first does not foreclose extension-compat;
  it just doesn't pay for it now.

**Concretely for the build plan (story 6):** the follow-on WebExtensions track is
its OWN exploration spec ("explore-webextensions-runtime" or similar), gated behind
a bound `ScriptEngine` (ADR-0013), scoped to answer "can we host an isolated-world
content-script + MV3 background SW + the `chrome.*` subset a wallet needs, and at
what compatibility ceiling" — the same evaluate-then-build shape this exploration
used. It is NOT a task on the wallet build spec. This recommendation is the input
story 6's build plan records as "which are their OWN explorations (a WebExtensions
runtime especially)."

---

## 3. Non-interactive signature classes (ADR-0015 decision 4 + thesis §3/§4)

The thesis's core security claim (thesis §3, ADR-0011): **authorization fatigue is
itself a security risk** — prompting the user for low-risk actions too often trains
them to blindly accept the dangerous ones. So reducing prompts for the classes
where a prompt adds NO security is a security IMPROVEMENT, not a convenience
trade-off. ADR-0015 d.4 makes non-interactive signatures a first-class UX goal and
asks this exploration to RECOMMEND how wezig RECOGNISES + safely AUTOMATES them.
This section does that, naming the standard SHAPE without committing the wire
format (that is the build spec's job; ADR-0015 "Note").

There are TWO non-interactive classes, in a superset relationship (thesis §4): a
request qualifies if EITHER an origin-check OR verifier-injected-unforgeable-data
makes a manual confirmation add no security.

### 3.1 Class 1 — Origin-bound automatic DECRYPTION

**The rule (thesis §3a).** wezig may non-interactively DECRYPT data whose encoded
allowed-origin(s) MATCH the requesting document's origin. Justification: if the app
at origin O encrypted the data for origin O, then a malicious VERSION of that same
app (same origin) already had the plaintext — so a decryption prompt adds no
security, only fatigue. (Because the origin is the CONTENT-ADDRESSED origin —
ADR-0015 d.1 — "the same app" means "the same verified bytes," a STRONGER
guarantee than a DNS-origin equality check: an attacker cannot be the same origin
without being the same content.)

**How wezig RECOGNISES it.** The decrypt request carries the ciphertext's
encoded allowed-origin(s); the broker compares them (exact match, content-origin
equality per ADR-0015 d.1/d.2) against the requesting document's origin as
determined by the browser ITSELF (not asserted by the page). Match → decrypt
without a prompt; no match → this is CROSS-origin data transfer, which stays
behind an explicit user prompt (thesis §3: "cross-origin data transfer stays
behind an explicit user prompt"). The **encrypt-for-a-FUTURE-origin** case
(thesis §2 / ADR-0015 d.1 ENS-repoint carry-forward) is the same mechanism with
the allowed-origin set including a future content hash the app names — the build
spec ties this to the vault AEAD class from §1.3.

### 3.2 Class 2 — Non-interactive AUTHENTICATION-signature envelope

**The rule (thesis §4).** A great many dapps authenticate a user by asking the
wallet to sign a message proving control of an address (replacing password login).
Done naively (static message, always-confirm) this both fatigues the user AND is
replay-vulnerable. A dedicated AUTHENTICATION-signature class lets wezig RECOGNISE
such a request and sign it WITHOUT a confirmation popup, safely, when the verifier
injects **unforgeable data** (a CSRF-token-like server-generated nonce/challenge)
so the signature cannot be replayed and there is nothing for the user to verify by
hand (the payload is verifier-generated, not attacker-chosen). Confirming it would
add no security — only fatigue.

**The standard SHAPE (named, not wire-committed).** The recognisable envelope is a
**typed-data (EIP-712) auth envelope**: a dedicated EIP-712 `domain` + a dedicated
auth `type` whose fields include the requesting origin (binding it to the content
origin — ADR-0015 d.4 origin-bound) AND the verifier-injected unforgeable data
(nonce/challenge/expiry). Because it is EIP-712, it is:

- **Origin-bindable** — the domain/struct carries the origin, so the same request
  also satisfies Class-3.3's origin check (this is the superset relationship of
  thesis §4: origin-check OR unforgeable-data — an auth envelope can carry BOTH).
- **Contract-wallet compatible** — verification via **ERC-1271** (`isValidSignature`
  for smart-contract accounts) and its predecessor **ERC-1654**, so the SAME
  envelope works for EOAs and smart-contract wallets. Named per ADR-0015 d.4 /
  thesis §4; the exact field layout / EIP-712 type strings are the BUILD SPEC's to
  commit (ADR-0015 "Note").

**Why a standard is needed, not a heuristic.** wezig must not guess "this looks
like a login" from an arbitrary `personal_sign` string (guessing is a security
hole — an attacker crafts a string that looks like a login but isn't). Recognition
must be STRUCTURAL: the request is an auth signature IFF it arrives as the
recognised EIP-712 auth envelope type carrying verifier-injected data. Anything
that does not match the envelope is NOT auto-signed — it falls back to the normal
approval path (§3.5). This keeps the default SAFE: automation is opt-in by
structure, never by fuzzy match.

### 3.3 The origin-check that underlies both (ADR-0015 d.4)

Both classes rest on the browser (not the page, not the user) determining the
requesting origin and enforcing the binding — the EIP-712 origin check of
ADR-0015 d.4. This is what defeats the "Bob's app mimics Alice's app" cross-app
signature-confusion attack (ADR-0015 threat summary): a malicious app at origin B
cannot obtain a signature bound to origin A, because the browser stamps the ACTUAL
origin, and cannot present origin-A-encrypted data to itself, because the content
origin can't be forged (ADR-0015 d.1). The user is not in the loop for this check
BY DESIGN — putting them in it is what causes the fatigue the thesis warns against.

### 3.4 The recognition predicate (how the broker decides — a description, not a new gate)

Pulling §3.1–3.3 together, the broker applies this NON-INTERACTIVE PREDICATE to an
incoming request; if it holds, the broker performs the action WITHOUT a popup;
otherwise it routes to the normal out-of-page approval (ADR-0015 d.4 signing
split). The predicate is a DESCRIPTION of the decision the broker already owns, not
a new user-facing flag or status:

> A request is auto-performed WITHOUT a confirmation prompt IFF it is one of the
> recognised low-fatigue classes AND the browser-determined origin authorises it:
> (a) a DECRYPT whose encoded allowed-origin set matches the requesting content
> origin (§3.1); OR (b) an AUTH-SIGNATURE that arrives as the recognised EIP-712
> auth envelope, is origin-bound to the requesting content origin, and carries
> verifier-injected unforgeable data (§3.2). EVERYTHING ELSE — every
> `eth_sendTransaction`, every free-form `personal_sign`/`eth_signTypedData`, every
> cross-origin decrypt, every chain switch — takes the normal, prompted,
> origin-bound approval path (ADR-0015 d.4).

Read-only methods (`eth_call`, `eth_chainId`, …) are ungated regardless (ADR-0015
d.4) and are not part of this predicate — they neither sign nor disclose nor
change state.

### 3.5 Threat analysis of the automation (why it does NOT lose security)

- *Replay:* mitigated by verifier-injected unforgeable data (§3.2) — a captured
  auth signature is worthless because the next challenge differs. This is a
  PROPERTY OF THE ENVELOPE, so wezig gets it by requiring the envelope, not by
  trusting the app.
- *Cross-app signature confusion:* mitigated by the browser-enforced origin
  binding (§3.3, ADR-0015 d.4) — automation does not weaken this; it RELIES on it.
- *Silently signing something dangerous:* mitigated by STRUCTURAL recognition
  (§3.2) — only the recognised envelope / matching-origin decrypt is automated;
  a transaction or a free-form sign never matches, so it is never auto-signed. The
  default is prompt; automation is the narrow, structurally-proven exception.
- *Fatigue (the meta-threat, thesis §3 / ADR-0015 threat summary):* mitigated —
  the high-frequency, zero-added-security prompts (logins, same-origin decrypts)
  disappear, so the prompts that REMAIN (transactions, cross-origin transfers) are
  higher-signal and less likely to be blindly accepted.
- *Interaction with biometric/lock custody policy (§1.2):* the automation removes
  the CONFIRMATION prompt, it must NOT silently remove a KEY-ACCESS gate the user
  set (e.g. "require biometric to use this key"). If a key is biometric-gated, an
  auto-signature may still require the biometric to UNLOCK the key — the fatigue
  reduction is about the "do you approve this payload?" dialog, not about
  weakening key access. This is a build-spec policy the custody tier (§1) and the
  predicate (§3.4) share; flagged so it is not lost.

---

## 4. What the build spec can now commit against (the "done" check)

From THIS document alone, a follow-on wallet BUILD spec can commit:

- **Custody:** the three-tier stack (hardware first-class / OS keychain software
  default / encrypted-at-rest fallback), the per-platform keychain bindings
  (`libsecret`, Keychain Services, Android Keystore), the fallback's primitive
  CLASS (memory-hard KDF + AEAD from a vetted/bound library, never hand-rolled),
  and each tier's threat profile + default role (§1). All behind the broker
  (ADR-0015 d.5).
- **WebExtensions:** native-first; extension wallet-compat is its OWN later
  exploration+build track gated behind a bound JS engine (ADR-0013), with the
  cost (a full WebExtensions runtime) and the ceiling (unbounded `chrome.*`
  fidelity + a model that doesn't deliver wezig's thesis) written down (§2). No
  runtime built.
- **Non-interactive signatures:** the two classes (origin-bound decrypt +
  EIP-712 auth envelope with ERC-1271/1654 for contract wallets), STRUCTURAL
  (not heuristic) recognition, the non-interactive predicate (§3.4), and the
  threat analysis showing it reduces fatigue WITHOUT losing security (§3.5) —
  wire format deliberately deferred to the build spec (ADR-0015 "Note").

Each recommendation is traced to ADR-0015 (d.3/d.4/d.5), the thesis finding
(§1/§2/§3/§4), ADR-0011, or an observed platform/EIP fact. Nothing is a real key
in real custody; this is a written recommendation. This document is markdown under
`work/notes/`, so the v0 gate (`zig fmt --check . && zig build && zig build test`)
is unaffected and stays green.

---

## Decisions

Recorded here per the work-contract's decision rule (a choice a reviewer/another
task might be surprised was made here), linked from the done record via this doc.

1. **Placement: this deliverable is a `work/notes/findings/` finding, not a second
   `docs/*-exploration-findings.md`.** *Chosen because* the acceptance criteria +
   prompt call it "a findings doc," and story 6
   (`web3-capabilities-findings-and-build-plan`) explicitly lists this task as an
   INPUT it will synthesize into the single `docs/` exploration findings doc — so
   emitting a competing top-level `docs/` doc would duplicate/fork the synthesis.
   *Alternative considered:* write it directly under `docs/` like
   `docs/shell-exploration-findings.md`. *Rejected* because that doc is the
   WHOLE-exploration synthesis (story 6), and this is one component recommendation
   feeding it — putting it under `docs/` now would pre-empt and split story 6.
   *Touches:* `web3-capabilities-findings-and-build-plan` (story 6) reads this file;
   no code, no seam, no other task's scope.
2. **The "non-interactive predicate" (§3.4) is named as a DESCRIPTION, not a new
   gate/flag/status.** *Chosen* to give the broker's automate-vs-prompt decision a
   referable name for the build spec, using only existing ADR-0015 d.4 concepts
   (signing split, origin-bound) + thesis §3/§4 (the two classes). *Alternative:*
   introduce a new user-facing "auto-sign" setting/flag. *Rejected* here as a
   build-spec UX decision, not this doc's to coin — automation is opt-in by
   STRUCTURE (the recognised envelope / matching origin), not by a new toggle, so no
   new named concept enters the glossary. *Touches:* the wallet build spec's
   approval-path design; consistent with ADR-0015 d.4's existing split.
3. **The custody probe ORDER (hardware → keychain → encrypted-at-rest) and
   "software default = keychain" are stated as a recommended policy.** *Chosen*
   because ADR-0015 d.3 fixes the tiers + "least crypto we own" but not the
   selection order; this order follows directly from the threat analysis (least
   owned-crypto path is the default; most owned-crypto path is last-resort).
   *Alternative:* leave order entirely to the build spec. *Rejected* as under-serving
   the "a reader can commit the custody stack from this doc alone" done-bar, while
   still leaving the EXACT primitive pick + UX to the build spec. *Touches:* the
   wallet build spec's account-creation flow; does not introduce a new error or a
   user-visible default beyond the ordering the ADR already implies.
