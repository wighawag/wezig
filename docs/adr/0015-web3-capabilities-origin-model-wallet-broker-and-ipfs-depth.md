# Native web3 capabilities: content-addressed origin model, an origin-keyed wallet with a dedicated signing broker, and layered IPFS depth

Status: accepted

This ADR pins the SECURITY MODEL and the load-bearing decisions for wezig's
native web3 capabilities (the `explore-web3-capabilities` exploration; ADR-0011's
don't-trust-the-origin thesis in its most concrete form). It is the DECISION the
exploration exists to make before any security-critical code is written; the
exploration's spikes prove the narrowest real case behind the `Renderer` seam
(ADR-0005/0006), they do not build the wallet or a production IPFS stack. The
design intent this ADR realises is captured in
`work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`
(the author's published web3-UX thesis, ratified in-session 2026-07-19).

## Context

wezig treats a native Ethereum provider and native IPFS resolution as first-class
(not extension-grafted). The wallet is the most security-critical part of the
project, and "native IPFS" has several very different meanings, so the model must
be DECIDED and threat-analysed, not guessed. The seam spikes already landed the
attachment surface (script-message bridge + custom-scheme interception) and the
verify-half of content-addressing (`net.Fetcher` + `ContentAddress.verify`), so
this ADR builds on proven ground.

## Decisions

### 1. The origin IS the content-addressed (IPFS) address — the strongest origin

The security origin wezig binds all per-origin state to is the **content hash**
(IPFS CID), NOT a DNS domain and NOT an ENS name. A content-addressed origin is a
STRONGER origin than a domain because the app owner cannot change the content or
logic without changing the origin (the browser verifies the bytes hash to it).
This is the concrete realisation of ADR-0011.

- **ENS is a mutable POINTER to a content origin.** A site reached via an ENS name
  has its ENS name resolve TO an IPFS origin; the origin wezig keys trust on is
  that IPFS origin, not the ENS name.
- **ENS-repoint is a NEW origin the user may ACCEPT to carry data forward.** When
  an ENS name is repointed to a new hash (a new app version), that is a new origin;
  the browser offers the user an explicit "accept the new origin and continue with
  your existing data (localStorage, wallet link, …)" flow — a user-authorised
  origin-to-origin data carry-forward (and, for a trusted app, the previous version
  can encrypt data FOR the future origin so the upgrade needs no re-authorisation
  beyond the app's own confirmation).

### 2. ONE origin = ONE trust boundary for everything; the wallet link is origin-keyed

All per-origin state shares ONE boundary keyed by the content hash: localStorage,
wallet permissions/link, encryption scope, and signature origin-binding. In
particular the **wallet link is keyed by ORIGIN, not by tab**: two tabs on the
same content origin SHARE one wallet link (same accounts, grant, selected chain);
two tabs on different origins get INDEPENDENT links (each possibly a different EVM
chain). Tabs multiplex onto the origin they belong to.

### 3. Wallet custody: OS keychain primary, encrypted-at-rest fallback, hardware-wallet first-class; extension-compat evaluated, not built

- **Primary: the OS keychain/keystore** (Secret Service/libsecret, macOS/iOS
  Keychain, Android Keystore) — OS-hardened, biometric-gatable, least crypto we own.
- **Fallback: encrypted-at-rest** (a vetted KDF + AEAD; @noble-family / libsodium
  class libraries, never hand-rolled crypto — consistent with the C-library-binding
  ethos) for platforms/contexts where a keychain is unavailable.
- **Hardware wallets are first-class** (not a bolt-on) as a custody option.
- **WebExtensions (Chrome/Firefox) wallet-compatibility is an EVALUATED option, not
  built here.** Supporting real extension wallets (ideally MetaMask-compatible) is
  attractive but requires a WebExtensions RUNTIME (`manifest.json`, background
  service workers, `chrome.*` APIs, content-script injection) — its own large
  subsystem, arguably its own exploration. This ADR records it as a recommended
  FUTURE path with its cost + compatibility ceiling; the exploration spikes the
  NATIVE broker path (decision 5), and a follow-on spec owns any WebExtensions
  runtime.

### 4. Provider surface: EIP-6963 discovery; signing vs read-only split; origin-bound; multi-EVM-chain

- **Advertise via EIP-6963 (Multi Injected Provider Discovery)**, NOT a bare
  `window.ethereum`. EIP-6963's multi-provider design is what lets wezig's native
  provider coexist with extension wallets and lets each origin discover a provider
  cleanly (and aligns with the per-origin binding of decision 2).
- **Split the method surface by risk:**
  - **Signing / state-changing / disclosure methods** (`eth_requestAccounts`,
    `eth_accounts`, `eth_sendTransaction`, `personal_sign`, `eth_signTypedData_v4`,
    `wallet_switchEthereumChain`) require an explicit, out-of-page (native-side)
    approval and are **ORIGIN-BOUND** (the browser binds the signature/permission to
    the requesting content origin — EIP-712 origin check — so a malicious app cannot
    trick the user into signing data destined for another app).
  - **Read-only methods** (`eth_call`, `eth_chainId`, block/state reads) wezig also
    supports and does not gate behind signing approval.
- **Multi-EVM-chain** from the design start (chain switching via
  `wallet_switchEthereumChain`), mainnet-first for the proof.
- **Non-interactive signatures are a first-class UX goal** (the blog thesis):
  origin-bound automatic decryption, and an authentication-signature class wezig can
  recognise and perform without a confirmation popup when the verifier injects
  unforgeable data — reducing authorization fatigue WITHOUT reducing security. The
  exploration RECOMMENDS how wezig recognises/automates these classes; the spike may
  prove one interactive round-trip first.

### 5. Provider ↔ wallet boundary: a DEDICATED signing broker (own process/sandbox)

Key custody + signing runs in a **dedicated broker with its own process/sandbox**,
separate from the page-world provider and from the content/renderer process. The
page-world provider (untrusted, in the content process) posts a `request` over the
script bridge; the broker (trusted) decides, signs, and replies. **The page never
receives key material — only the ability to REQUEST via the bridge.** This boundary
holds identically after the `WezigRenderer` swap because it is expressed at the
seam (a single-process `WezigRenderer` still routes signing to the out-of-page
broker). The exploration SPIKES this broker boundary (one `eth_requestAccounts`
round-trip through it against a THROWAWAY test key — never real custody).

### 6. IPFS: support all resolution depths, default to verified-gateway first, in-browser node later; `ipns://` in scope

- **Support ALL depths** — (i) verified gateway (fetch a CID from an HTTP gateway,
  then hash-verify LOCALLY: the gateway is untrusted transport, the math is the
  trust — already built as `net.Fetcher` + `ContentAddress.verify`), (ii) bind an
  existing node (e.g. kubo over its API), (iii) an IN-BROWSER full node.
- **Default to (i) verified-gateway FIRST**, with the **in-browser node as an option
  that may become the default later**, and **always let the user run their OWN node
  separately** (point wezig at an external node). The verify contract is identical
  across depths; only how a `ContentAddress` is constructed and how bytes are
  sourced changes.
- **`ipns://` is in scope** (mutable content-addressed naming) alongside `ipfs://`.

### 7. `ipfs://` is a first-class SECURE origin (service workers must work)

`ipfs://` content must be able to host **service workers**, so `ipfs://` is
registered as a **secure origin** (the strongest — its bytes are hash-verified). The
`Renderer` seam's scheme-registration must therefore let the backend declare a
scheme's SECURITY TRAITS (secure / CORS / local), not just serve a body+content-type
(today `registerScheme` carries only body+content-type; see the two-layer finding
`work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`).
This is a seam extension the exploration confirms is needed.

## Consequences

- The `Renderer` seam gains two confirmed requirements the exploration feeds back:
  **per-ORIGIN provider binding** (decision 2 — not the single hardcoded `"wezig"`
  channel) and **scheme security traits** (decision 7). Both are breaking-ish
  additions best decided before a second backend hardens, consistent with the
  input/scroll-forwarding gap the shell findings already flagged.
- The wallet build spec starts from a DECIDED model (custody, method split,
  origin-binding, EIP-6963, broker boundary) + a threat analysis, never guesses.
- The IPFS build spec starts with verified-gateway (already proven) and grows a real
  CID/IPNS decoder + optional in-browser node behind the unchanged verify contract.
- Content-addressed origin as the trust key makes localStorage, permissions, wallet
  link, and signature-binding ONE coherent boundary — the browser can safely
  automate same-origin actions (decryption, origin-bound auth signatures), which is
  the usability-through-security thesis.

## Threat analysis (summary)

- **Key exfiltration:** mitigated by the broker boundary (decision 5) — keys never
  enter the page/content/renderer process; the page holds only request capability.
- **Cross-app signature confusion** ("Bob's app mimics Alice's app"): mitigated by
  origin-bound signatures (decision 4) enforced by the BROWSER, not the user.
- **Authorization fatigue** (users blindly accepting prompts): mitigated by
  non-interactive same-origin decryption + recognised auth-signature class
  (decision 4) — fewer, higher-signal prompts.
- **Malicious ENS repoint** (app owner swaps content under a name): surfaced by the
  content-addressed origin CHANGING (decision 1) — the user is asked to accept the
  new origin, so a silent logic swap cannot ride an unchanged origin.
- **Untrusted gateway serving wrong bytes:** mitigated by local hash-verification
  (decision 6) — a gateway cannot forge content for a CID.
- **Mixed content** (verified content fetching unverifiable subresources): flagged
  as requiring the same care as https→http mixed content (finding §1); the strong
  origin only covers hash-verified bytes.
- **Encrypted-at-rest fallback** is the largest residual owned-crypto surface;
  restricted to keychain-unavailable contexts and built on vetted primitives, never
  hand-rolled.

## Note

This ADR records the DECIDED model + its rationale; the details (exact KDF/AEAD,
the auth-signature envelope, the broker IPC shape, the CID grammar) are settled by
the follow-on BUILD specs this exploration de-risks. No real private key is stored
or used in the exploration.
