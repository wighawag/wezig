# Web3-capabilities exploration: findings + de-risked, sliced build plan

This is the CONFIDENCE deliverable of the `explore-web3-capabilities` exploration
(story 6): a durable, grounded report of what the exploration's tasks LEARNED
about attaching wezig's two differentiators — a native Ethereum provider and
native IPFS resolution — at the pinned `Renderer` seam, plus a de-risked, SLICED
build plan for the follow-on wallet + IPFS BUILD specs. An exploration's "done"
is CONFIDENCE + a plan, not a shipped wallet or a production IPFS stack (the
wallet is the most security-critical part of the whole project, and "native IPFS"
means several very different things), so THIS document — not the spike code — is
what a human or agent reads to author those build specs with the model already
DECIDED and the risky parts already de-risked.

It is the web3 analogue of `docs/native-renderer-exploration-findings.md` and
`docs/shell-exploration-findings.md` (which fed the native-renderer and desktop
shell build plans respectively); it matches their shape. The load-bearing
DECISIONS the exploration settled are NOT re-decided here — they are pinned in
**ADR-0015** (the origin model, the origin-keyed wallet, the signing broker, the
provider surface, the IPFS depth ladder, the `ipfs://`-secure-origin trait) and
in **ADR-0016** (how `ipfs://` service-worker HOSTING is delivered on the
webview backend). This document points AT those decisions and folds each spike's
observed outcome into a plan. The root anchor for every decision is **ADR-0011**
(wezig is a general browser for a post-trusted-server web) and its most concrete
expression, the author's ratified web3-UX thesis
(`work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`).

Every claim below traces to something a task actually observed — a spike that
proved a case in the display-free `zig build test` gate, a landed module, a
verified finding, or a live-leg observation. Where a task DELIBERATELY did not
settle something (correctly, being exploration-scoped), it is flagged as a
build-plan input, not dressed as a finding. Where a spike STOPPED on a stale
premise (the SW-hosting blocker), the ADR that resolved it is cited.

The exploration's tasks, and what each delivered:

- `spike-wallet-broker-eip6963-provider` (story 1): the page→broker→page
  round-trip, the signing-broker process/sandbox boundary, the EIP-6963 provider
  shape, and ONE origin-bound `eth_requestAccounts`, all behind the `Renderer`
  seam. Landed as `src/wallet_broker.zig` (+ the live out-of-process leg
  `src/wallet_broker_spike.zig`).
- `spike-ipfs-fetch-verify-and-secure-origin-seam` (stories 2, 4): one `ipfs://`
  CID fetched + hash-verified through the interception hook, and the
  scheme-security-traits seam extension that marks `ipfs://` a secure origin.
  Landed as `src/ipfs_scheme.zig` + the `Renderer.declareSchemeSecurity` seam
  method. The depth ladder is recorded in
  `work/notes/findings/ipfs-depth-ladder-and-verified-gateway-2026-07-19.md`.
- `pin-content-origin-and-wallet-link-model` (stories 1, 3, 5): the ENS→IPFS
  origin model, the per-ORIGIN (not per-tab) wallet link, the ENS-repoint
  carry-forward, and the seam's per-origin provider binding. Landed as
  `src/web3_origin.zig`.
- `evaluate-custody-and-extension-compat` (story 3): the threat-analysed custody
  stack, the honestly-costed WebExtensions-compat verdict, and the
  non-interactive-signature classes. Landed as the finding
  `work/notes/findings/wallet-custody-webextensions-and-non-interactive-signatures-2026-07-19.md`.

Two tasks are REFERENCED but were not blockers for this synthesis, and their
decided direction is folded in from the ADRs rather than waited on:
`spike-webkitgtk-sw-scheme-patch` (the heavy fork-patch cost spike) and the
SW-hosting story it proves, both pinned in **ADR-0016**.

---

## 1. The load-bearing model is DECIDED (ADR-0015): the content-addressed origin

The exploration's real product is a DECIDED, threat-analysed security model, so
the build does not start on guesses. That model is pinned in **ADR-0015** and
grounded in the author's web3-UX thesis; this section states it as the plan's
spine so nothing below is misread (read ADR-0015 + the thesis finding for the full
rationale + threat analysis). It is not re-decided here.

- **The origin IS the content hash — the STRONGEST origin (ADR-0015 d.1).** The
  security origin wezig binds ALL per-origin state to is the IPFS content address
  (CID), NOT a DNS domain and NOT an ENS name. It is stronger than a domain
  because the app owner cannot change the content or logic without changing the
  origin — the browser verifies the bytes hash to it (`net.ContentAddress.verify`,
  ADR-0011). ENS is a mutable POINTER that resolves TO a content origin; a
  repoint is a NEW origin the user may ACCEPT to carry data forward.
- **ONE origin = ONE trust boundary; the wallet link is ORIGIN-keyed (ADR-0015
  d.2).** localStorage, wallet permissions/link, encryption scope, and signature
  origin-binding are the SAME boundary keyed by the content hash. Two tabs on one
  origin SHARE a wallet link; two origins are independent. The provider binding
  the seam carries is therefore per-ORIGIN, not per-tab and not a single global
  channel.
- **Custody: OS keychain primary / encrypted-at-rest fallback / hardware-wallet
  first-class (ADR-0015 d.3);** WebExtensions wallet-compat EVALUATED, not built.
- **Provider surface: EIP-6963 discovery, signing-vs-read-only split,
  origin-bound signatures, multi-EVM-chain, non-interactive signatures a
  first-class UX goal (ADR-0015 d.4).**
- **The provider↔wallet boundary is a DEDICATED signing broker in its own
  process/sandbox (ADR-0015 d.5).** The page never sees key material.
- **IPFS: support all depths, default verified-gateway first, in-browser node
  later; `ipns://` in scope (ADR-0015 d.6);** and **`ipfs://` is a first-class
  SECURE origin so it can host service workers (ADR-0015 d.7).**

Two framing facts the build plan inherits and MUST NOT re-litigate:

- **wezig is a GENERAL browser, not a wallet-with-a-viewport (ADR-0011).** The
  wallet + IPFS are a CONSEQUENCE of the don't-trust-the-server thesis, not the
  reason to exist. Every slice below must keep the normal server-web working; the
  web3 capabilities ride on top, first-class rather than extension-grafted.
- **The security-critical build must not start on guesses.** The exploration's
  whole point is that the model is decided AND the seam attachment is proven
  before a real key is ever custodied. No spike touched real custody: the broker
  spike used a fixed THROWAWAY test key
  (`wallet_broker.FakeBroker.throwaway_test_privkey`, a non-secret constant), and
  the custody stack is a written recommendation, never code.

---

## 2. The wallet broker boundary + EIP-6963 provider, PROVEN behind the seam

`spike-wallet-broker-eip6963-provider` proved the two security-critical boundary
halves the wallet build starts from — the signing-broker boundary and the
EIP-6963 provider shape — on the NARROWEST real case: ONE origin-bound
`eth_requestAccounts` round-trip. Ground truth: `src/wallet_broker.zig` (the
contract + the fake broker, proven headlessly in the display-free `zig build
test` gate) and `src/wallet_broker_spike.zig` (the LIVE out-of-process leg,
`zig build wallet-broker-roundtrip-test`, a dedicated `wallet-broker` CI leg
mirroring `networking`/`harfbuzz`/`webview`). No real key exists in either.

**The broker boundary is a MESSAGE boundary — a `Broker` seam value (ADR-0015
d.5).** Key custody + the "decide + return accounts/sign" step live behind a
`Broker` `{ ptr, vtable }` value, the SAME shape as `Renderer`/`net.Fetcher`. Its
ONE method is `handle(request_line) -> response_line`: a JSON request LINE in, a
JSON response LINE out. Key material is confined behind `ptr` and CANNOT cross the
vtable — the page-world provider only REQUESTS; it holds NO reference to a key.
Because the boundary is a STRING boundary, the SAME seam abstracts over WHERE the
broker runs:

- `FakeBroker` satisfies it IN-PROCESS for the core-gate contract test.
- `ChildProcessBroker` (the live proof, `wallet_broker_spike.zig`) satisfies it
  with a SEPARATE child PROCESS that owns the throwaway key in its OWN address
  space; the parent (page/provider side) frames request/response lines over the
  child's stdio and NEVER has the key.

This is the load-bearing structural finding: **the signing broker's own-process/
sandbox boundary (ADR-0015 d.5) is a real, proven boundary, not a diagram** — and
it holds identically after the `WezigRenderer` swap because it is expressed at the
seam (a single-process `WezigRenderer` still routes signing to the out-of-page
broker over the same message contract). The shell exploration already observed
that the wallet's custody must be a native-side concern, not the page-world bridge
(`docs/shell-exploration-findings.md` §4); this spike REALISES that as a working
process boundary.

**The IPC envelope is DECIDED (recorded at the choice site, not re-opened here).**
The provider↔broker wire is line-delimited JSON: request
`{ id, origin, method, params }`, response `{ id, result }` or
`{ id, error: { code, message } }` — exactly the EIP-1193 shape the page already
speaks, so the provider forwards the page's `request({method, params})` almost
verbatim, adding only the trusted `origin` stamp (the full rationale +
alternative is the DECISION block in `src/wallet_broker.zig`). The load-bearing
addition over raw EIP-1193 is the `origin` field: it is stamped by TRUSTED native
(the provider), NEVER by the page. **The wallet build inherits this envelope**
(it adds signing methods + an approval field and MAY promote it to JSON-RPC 2.0).

**EIP-6963 discovery, proven (ADR-0015 d.4).** The provider is advertised via
EIP-6963 (`eip6963:announceProvider` / re-announce on `eip6963:requestProvider`),
NOT a bare `window.ethereum`, so it coexists with extension wallets and is
discovered per origin. The injected page-world announce script + the four-field
`Eip6963ProviderInfo` (`uuid`/`name`/`icon`/`rdns`) are settled; the test asserts
the injected script announces a provider and does NOT define `window.ethereum`.

**ONE origin-bound `eth_requestAccounts` round-trips (the story-1 proof).** A
`PageProvider` drives the full page→broker→page round-trip through the seam's
script bridge (`FakeRenderer`): the page's `request(...)` posts on the origin's
channel, the provider stamps the requesting content origin, the broker decides
and returns the disclosed ACCOUNTS (public addresses only — the test asserts the
key is NEVER disclosed), and the grant is recorded on THAT origin's shared
`WalletLink`. The tests prove: the request the broker sees is origin-bound
(stamped by native, not the page); two tabs on the SAME origin share the grant
while different origins are independent; and a DECLINED grant rejects the page
promise (EIP-1193 `4001`) disclosing nothing.

**What the spike deliberately did NOT build (wallet-build inputs).** Real custody
(keychain / encrypted-at-rest / hardware — §5); the signing/state-changing
methods and their out-of-page APPROVAL UX (the `eth_requestAccounts` here
auto-grants WITHOUT a prompt — it proves the boundary + message shape, not the
approval policy); multi-chain switching; and persistence. `eth_requestAccounts`
is the only method proven; every other method returns EIP-1193 `4200`.

**The `Renderer`-seam gap this spike touched: none new — one confirmed.** The
broker boundary needed no seam change (it rides the existing script-message
bridge). It surfaces the SAME per-origin-channel insufficiency the model task
pins (§4): a single-provider spike uses ONE channel and is unaffected, but
multiple concurrent origins need the WebKitGTK backend to recover the channel
name it hardcodes today.

---

## 3. `ipfs://` fetch+verify + the secure-origin seam extension, PROVEN

`spike-ipfs-fetch-verify-and-secure-origin-seam` proved native content-addressed
resolution on the narrowest real case and added the one confirmed seam extension
`ipfs://` needs. Ground truth: `src/ipfs_scheme.zig` (fetch+verify through the
hook, proven OFFLINE + deterministically in the display-free `zig build test`
gate with a `net.FakeFetcher` + `FakeRenderer`); the live WebKitGTK secure-origin
leg is `zig build ipfs-secure-origin-test` under Xvfb.

**The fetch+verify path, proven (ADR-0015 d.6 depth (i)).** `IpfsSchemeHandler`
serves ONE `ipfs://` CID through the `Renderer` seam's `registerScheme`
interception hook: it fetches the CID's bytes from an untrusted transport (a
gateway) via the landed `net.Fetcher` + `net.fetchVerified`, HASH-VERIFIES them
locally against the content address, and serves the verified bytes as a
`SchemeResponse` — or REJECTS on mismatch (`error.HashMismatch` → a
`rejection_body`, never the bad bytes), so the page NEVER observes unverified
content-addressed bytes. **The REJECTION is the thesis** (ADR-0011): content is
trusted because it hashes to its address, not because a gateway served it, so a
malicious or buggy gateway can only fail — never forge. This reuses the verify
half the native-renderer exploration already landed
(`docs/native-renderer-exploration-findings.md` §3); this spike proves the ATTACH
through the hook, it does not rebuild verification.

**The scheme-security-traits seam extension, added (ADR-0015 d.7).** `ipfs://` is
registered as a first-class SECURE origin (its bytes are hash-verified — the
strongest origin) via a NEW seam method `Renderer.declareSchemeSecurity(scheme,
traits)` with `secure_origin_traits = { secure = true, cors = true }` (secure +
CORS, NOT local). The live leg proves WebKitGTK's `WebKitSecurityManager` marks
the origin secure. This is a DECIDED extension shape recorded at the choice site
(`work/notes/observations/scheme-security-traits-are-a-sibling-optional-seam-method-2026-07-19.md`):
it is a SIBLING, OPTIONAL vtable method, NOT extra fields on `registerScheme` —
because security traits map to a DIFFERENT WebKitGTK API than the request
callback, `registerScheme` has ~8 call sites a signature change would break, and
an optional method lets backends that cannot honour traits leave the hook null
(ADR-0016 d.5's "the trait declaration is uniform; whether a backend honours it
varies"). `FakeRenderer` + `SystemWebviewRenderer` implement it; mobile/native
backends leave it null for their own follow-on. A `WezigRenderer` reproduces the
secure-origin semantics through this method.

**The depth ladder, recorded (ADR-0015 d.6) — the build plan's IPFS input.**
Ground truth: `work/notes/findings/ipfs-depth-ladder-and-verified-gateway-2026-07-19.md`.
The verify CONTRACT is identical across every depth ("the bytes must hash to the
content address, or REJECT"); only HOW a `ContentAddress` is constructed and HOW
bytes are SOURCED changes:

1. **(i) Verified gateway — the DEFAULT, and the rung this spike PROVED.** Fetch
   from an untrusted HTTP(S) gateway, hash-verify locally. Lowest friction (no
   node, no DHT), already built end-to-end here — the shipping default.
2. **(ii) Bound external node — always allowed, the power-user path.** Point wezig
   at a node the user runs (kubo over its API/gateway). SAME fetch+verify code;
   the "gateway" URL is just the user's node. Always allowed regardless of the
   default (ADR-0015 d.6).
3. **(iii) In-browser full node — the aspirational later default.** Embed a node
   (DHT, bitswap, datastore) so resolution needs no external gateway. The heaviest
   rung, its own subsystem; explicitly NOT v1, may become the default later.

Recommended ordering (from the finding): ship (i) + (ii) first — the SAME
fetch+verify code differing only in the configured source URL — then schedule
(iii) as a later opt-in that may be promoted to default once its resource cost is
acceptable. **`ipns://` is IN SCOPE**: it resolves an IPNS name to a current CID,
then the SAME fetch+verify applies — the mutability lives only in the NAME→CID
step.

**⚠ The SW-hosting blocker (ADR-0016) — folded in, NOT blocking this synthesis.**
The secure-origin trait declaration above is NECESSARY but NOT SUFFICIENT for
`ipfs://` to HOST a service worker. The sibling
`spike-ipfs-secure-origin-service-worker` STOPPED on a verified stale premise
(`work/notes/observations/webkitgtk-service-worker-hard-restricted-to-http-https-2026-07-19.md`):
stock WebKitGTK 6.0 HARD-REJECTS `navigator.serviceWorker.register()` on any
non-HTTP(S) scheme at the WebCore engine level
(`ServiceWorkerContainer.cpp` ~L194–200), with NO public API to allowlist a
scheme (unlike Chromium/Electron's `registerSchemeAsPrivileged`; the same limit
is tracked upstream for Tauri). This falsified the two-layer finding's premise
that scheme security traits ALONE decide SW-hosting — there is a SECOND,
backend-level protocol allowlist gate with no knob. **ADR-0016 decides the way
through:** carry a MINIMAL WebKitGTK fork patch that opts an
embedder-registered secure scheme into SW-hosting (a `WebKitSecurityManager`-style
`register_uri_scheme_as_service_worker_capable`, a policy relaxation behind an
explicit opt-in), propose it upstream but do NOT depend on acceptance, and treat
`WezigRenderer` (its own scheme registry, no patch needed) as the eventual
restriction-free home. The fork commitment is GATED behind a cost-measuring spike
(`spike-webkitgtk-sw-scheme-patch`) that first proves the patch + measures its
standing cost (build time, rebase friction across WebKit releases). This is a
Linux/WebKitGTK-only capability until `WezigRenderer` or a per-platform
equivalent lands (WKWebView is Apple's unpatchable binary; WebView2 has a
different mechanism). **The build plan (§6) carries SW-hosting as its own spike +
a per-backend story, not a fetch+verify rung.**

**What the spike deliberately did NOT build (IPFS-build inputs).** The full CID
GRAMMAR (multibase/multihash/codec/version decode of an `ipfs://…`/`ipns://…`
string into a `ContentAddress` — only SHA-256 exists in the verifier today; the
CID decoder adds the other multihash algorithms behind the UNCHANGED verify
contract); the IPNS resolver + its name-record freshness/verification story; and
the subresource / mixed-content policy (a verified `ipfs://` page fetching an
unverifiable `http://` subresource is the IPFS analogue of https→http mixed
content — the strong origin only covers hash-verified bytes; ADR-0015 threat
analysis; thesis §1).

---

## 4. The content-origin + per-origin wallet-link model, PINNED

`pin-content-origin-and-wallet-link-model` turned ADR-0015 decisions 1–3 into a
TYPED, TESTABLE model + confirmed the seam's per-origin binding. Ground truth:
`src/web3_origin.zig` — pure Zig behind the `Renderer` seam (imports only
`renderer.zig`, never a webview/GTK binding), so its tests run in the display-free
`zig build test` gate like `renderer_swap.zig`. It pins the model + binding SHAPE;
it does NOT build the wallet, storage, encryption, or multi-chain switching.

**The ENS→IPFS origin model (ADR-0015 d.1).** `ContentOrigin` wraps the IPFS
content address (CID text). An ENS name is NOT a `ContentOrigin` — it is a mutable
pointer that resolves TO one (`fromEns` documents the direction; the resolution
itself is the follow-on build's job). Two ENS names resolving to the same CID are
the SAME origin: the CID, not the name, is what wezig keys trust on. (Decoding a
real CID grammar is the IPFS subsystem's job — see §3 — the same string-form
boundary `net.ContentAddress` uses.)

**The per-ORIGIN (not per-tab) wallet link (ADR-0015 d.2).**
`WalletLinkStore.linkFor` guarantees same-origin-shares / cross-origin-isolates:
two tabs on one content origin resolve to the SAME `WalletLink` (same accounts,
grant, selected chain); two origins get INDEPENDENT links (each possibly a
different EVM chain). A `WalletLink` here is an INERT data record, never real
custody. The store is deliberately IN-MEMORY only (persistence entails the storage
subsystem + encryption-at-rest, ADR-0015 d.3, both out of scope — ratified in the
module's DECISION block and the review nit).

**The ENS-repoint carry-forward (ADR-0015 d.1).** `WalletLinkStore.acceptRepoint`
models the user-authorised origin-to-origin data carry-forward: when an ENS name
is repointed to a NEW hash (a new app version = a NEW origin), the user may ACCEPT
the new origin and CONTINUE with their existing data (localStorage, wallet
link, …). This is the concrete realisation of the thesis's "encrypt data for a
FUTURE origin so a trusted app can upgrade its hash without re-authorising" (§2 of
the thesis; the vault AEAD class of §5 is the primitive this reuses).

**The seam's per-origin provider binding, CONFIRMED (story 5).**
`OriginProviderBinding` expresses per-origin binding over the seam's
script-message bridge: each concurrent origin gets its OWN named channel (the
channel name IS the content origin, using a `wezig:` prefix + the CID — an
in-scope wire default ratified in the review nit), replacing the single hardcoded
`"wezig"` channel. It drives ONLY seam methods (`setScriptMessageHandler` with a
per-origin channel name; the seam's `ScriptMessageCallback` `name` parameter to
identify the origin), so a `WezigRenderer` reproduces it by delivering the message
under the origin's channel name — proven headlessly through `FakeRenderer`.

**The ONE confirmed `Renderer`-seam insufficiency (the carry-forward).** The seam
INTERFACE already carries the channel `name` and needs no change. The
INSUFFICIENCY is in the WebKitGTK BACKEND: `system_webview_renderer.zig`
`onScriptMessage` HARDCODES the channel name `"wezig"` because the `JSCValue` it
receives does not carry the channel name (the sharp edge the shell exploration
flagged, `docs/shell-exploration-findings.md` §1). For the per-ORIGIN binding to
work with MULTIPLE concurrent origins on that backend, the backend must recover
the channel name it registered under (connect the per-detail
`script-message-received::<name>` signal so `<name>` is recoverable) and pass it
as the callback `name`. A single-provider spike is unaffected (one channel). This
is a backend-impl fix the wallet build must land BEFORE multiple concurrent
origins work on the webview backend — but it does NOT widen the pinned seam.

---

## 5. Custody + WebExtensions + non-interactive signatures, RECOMMENDED

`evaluate-custody-and-extension-compat` delivered the highest-judgement,
security-critical EVALUATE-and-RECOMMEND deliverable — a written, threat-analysed
recommendation the wallet build commits against, NOT wallet code, NOT crypto, NOT
a WebExtensions runtime. Ground truth:
`work/notes/findings/wallet-custody-webextensions-and-non-interactive-signatures-2026-07-19.md`
(traced to ADR-0015 d.3/d.4/d.5, the thesis, ADR-0011, and observed
platform-API / EIP facts). No real key was stored to produce it.

**The custody stack (ADR-0015 d.3), threat-analysed per tier.** At account
creation the broker probes backends in this order and uses the first available
per account, recording which backend holds each key (the ORDER + "software
default = keychain" is a recommended policy the finding adds — ADR-0015 fixes the
tiers + "least crypto we own" but not the order; ratified in the finding's
Decisions #3). All three tiers sit BEHIND the broker (§2): the page never holds
key material regardless of tier.

1. **Hardware wallet — first-class (Tier A).** The key never enters wezig's
   address space; the broker is a transport + policy layer, not a custodian. The
   smallest exfiltration surface (gold standard), the weakest coverage (needs a
   device — so not the default). It is first-class because it is the SHAPING case:
   it forces the broker's signing interface to be async + refusable from day one,
   which the software tiers also satisfy.
2. **OS keychain / keystore — the software DEFAULT (Tier B).** Bound (never
   reimplemented): `libsecret`/Secret Service on Linux/BSD, Keychain Services on
   macOS/iOS, Android Keystore on Android. On enclave/TEE/StrongBox hardware a key
   can be non-exportable (sign-only). The LOWEST owned-crypto residual of the
   software tiers ("least crypto we own"), hence the default. Caveat the build must
   plan for: Secret Service can be ABSENT on a headless/minimal Linux session —
   the exact trigger for the Tier C fallback.
3. **Encrypted-at-rest vault — fallback ONLY (Tier C).** Where no keychain is
   available and no hardware wallet is used. The CLASS is fixed (a memory-hard KDF
   + an AEAD from a vetted/bound library — libsodium / @noble-family class, NEVER
   hand-rolled crypto; ADR-0015 d.3); the EXACT primitive pick is the build spec's.
   The LARGEST residual owned-crypto surface (the ciphertext is a readable file →
   security reduces to passphrase entropy + KDF hardness + AEAD integrity), which
   is precisely why it is the fallback, not a co-default. The same AEAD class is
   reused by the ENS-repoint "encrypt for a future origin" carry-forward (§4).

**WebExtensions wallet-compat: NATIVE-FIRST; it is its OWN later exploration
(ADR-0015 d.3).** Supporting real MetaMask-class extension wallets requires a full
WebExtensions RUNTIME — `manifest.json`/MV3 parsing, a background service-worker
host, the `chrome.*`/`browser.*` API surface, isolated-world content-script
injection, a permissions/consent model, and an extension store/update path — a
browser-SUBSYSTEM's worth of work, most of it (isolated worlds, a bound JS engine
at all, an extension lifecycle host) sitting on foundations wezig has NOT built.
Its compatibility ceiling never reaches 1.0 (unbounded bug-for-bug `chrome.*`
fidelity against a vendor-driven moving target), and — the decisive point — an
imported extension wallet brings its OWN (DNS-origin, always-prompt) model, NOT
wezig's content-addressed-origin-bound, low-fatigue model, so it does NOT deliver
the differentiator wezig exists to build. **Recommendation: build the NATIVE
wallet first; treat WebExtensions wallet-compat as a SEPARATE, LATER exploration +
build track, gated behind a bound `ScriptEngine` (ADR-0013, not yet bound), NOT a
task on the wallet build spec.** EIP-6963's multi-provider discovery leaves the
door OPEN (adding extension-hosted providers later is additive, not a
re-architecture), so native-first forecloses nothing. This is the plan's "which
are their OWN explorations" input (§6).

**Non-interactive signatures: TWO classes, STRUCTURALLY recognised (ADR-0015 d.4
+ thesis §3/§4).** The thesis's core security claim: authorization fatigue is
ITSELF a security risk (over-prompting trains users to blindly accept the
dangerous prompts), so removing prompts where a prompt adds NO security is a
security IMPROVEMENT. Two non-interactive classes, in a superset relationship
(qualify if EITHER an origin-check OR verifier-injected-unforgeable-data makes a
manual confirmation add no security):

- **Class 1 — origin-bound automatic DECRYPTION (thesis §3a).** wezig may decrypt
  without a prompt data whose encoded allowed-origin(s) MATCH the requesting
  content origin (as determined by the BROWSER, not asserted by the page): if the
  app at origin O encrypted for O, a malicious VERSION of that same app already had
  the plaintext, so a prompt adds nothing. No match → cross-origin transfer → stays
  behind an explicit prompt.
- **Class 2 — the non-interactive AUTHENTICATION-signature envelope (thesis §4).**
  A typed-data (EIP-712) auth envelope carrying the requesting origin (origin-bound)
  AND verifier-injected unforgeable data (a CSRF-token-like nonce/challenge), so
  the signature cannot be replayed and there is nothing for the user to verify by
  hand. Recognition is STRUCTURAL (the recognised EIP-712 type), never a fuzzy
  match on a `personal_sign` string — automation is opt-in BY STRUCTURE, so the
  default stays SAFE. Contract-wallet compatible via ERC-1271/ERC-1654.

The broker applies a **non-interactive predicate** (a DESCRIPTION of the decision
it already owns, not a new user-facing flag/gate/status — ratified in the
finding's Decisions #2): auto-perform WITHOUT a prompt IFF the request is one of
these recognised classes AND the browser-determined origin authorises it;
EVERYTHING ELSE (every `eth_sendTransaction`, every free-form sign, every
cross-origin decrypt, every chain switch) takes the normal, prompted, origin-bound
approval path. Read-only methods (`eth_call`, `eth_chainId`, …) are ungated
regardless. The threat analysis shows this reduces fatigue WITHOUT losing security
(replay ← unforgeable data; cross-app confusion ← browser-enforced origin binding;
silent-dangerous-sign ← structural recognition), and it must NOT silently bypass a
KEY-ACCESS gate the user set (a biometric-gated key may still require the biometric
to UNLOCK even when the confirmation prompt is skipped). The exact WIRE format is
deliberately the build spec's (ADR-0015 "Note").

---

## 6. The de-risked, SLICED BUILD PLAN

This section states the follow-on wallet + IPFS BUILD specs — their scope,
ordering, and which are their OWN explorations — so each can be authored and
tasked ATOMICALLY from THIS document alone (a follow-on `to-spec` could work from
it), mirroring how `docs/native-renderer-exploration-findings.md` §7 fed the
native-renderer build and `docs/shell-exploration-findings.md` §6 fed the desktop
build. Everything below is grounded in a finding above; the "DECIDE" points are
the load-bearing choices the exploration surfaced but (correctly, being out of
scope) did NOT settle. The slice names are a PROPOSAL the human authoring the
follow-on specs adopts and may re-cut — not pinned interfaces.

### What the build already knows (de-risked by the exploration)

- The full security model is DECIDED + threat-analysed (ADR-0015): content-origin
  as the trust key, origin-keyed wallet link, the custody stack, the EIP-6963 +
  signing-split provider surface, the broker boundary, the IPFS depth ladder, the
  `ipfs://`-secure-origin trait (§1).
- The signing-broker boundary is a PROVEN message boundary (`Broker` seam), works
  in-process AND out-of-process, holds after the `WezigRenderer` swap, and the
  page never gets a key (§2).
- EIP-6963 discovery + ONE origin-bound `eth_requestAccounts` round-trip through
  the script bridge are proven; the JSON IPC envelope is decided (§2).
- `ipfs://` fetch+verify through the interception hook is proven (reject-on-mismatch
  is the trust core), and the `Renderer.declareSchemeSecurity` seam extension marks
  `ipfs://` a secure origin — an OPTIONAL sibling method a `WezigRenderer`
  reproduces (§3).
- The content-origin + per-ORIGIN wallet-link model + the ENS-repoint
  carry-forward + the per-origin provider binding are pinned + proven headlessly
  (§4).
- The custody stack, the WebExtensions native-first verdict, and the two
  non-interactive signature classes + the predicate are recommended + threat-
  analysed (§5).
- The build builds AGAINST the pinned seams (`Renderer` + its script-bridge /
  scheme-interception / `declareSchemeSecurity` hooks, `net.Fetcher`, the new
  `Broker` seam), never around them — each capability is an additive backend value
  behind a seam (ADR-0005/0006/0015).

### The confirmed `Renderer`-seam feedback (decide BEFORE a second backend hardens)

The exploration fed TWO confirmed seam requirements back (ADR-0015 Consequences);
both are best landed before `WezigRenderer` hardens, consistent with the
input/scroll-forwarding gap the shell + native-renderer findings already flagged:

- **Scheme security traits — ALREADY LANDED as `Renderer.declareSchemeSecurity`**
  (§3), an OPTIONAL sibling method. The build inherits it; it must ensure a
  `WezigRenderer` honours it (native has no restriction) and the SW-hosting patch
  path (below) plugs into it on WebKitGTK.
- **Per-ORIGIN provider binding — the seam INTERFACE already carries the channel
  `name`; the WebKitGTK BACKEND must recover it** (stop hardcoding `"wezig"`, §4).
  A wallet-build obligation before multiple concurrent origins work on that
  backend — a backend-impl fix, not a seam widening.

### Slicing (recommended follow-on specs, in dependency order)

The wallet and native IPFS are far bigger than one atomically-taskable spec each;
they slice into the specs below. Slices that touch disjoint code can proceed in
parallel; ordering constraints are called out per slice.

**Slice W0 — `build-wallet-broker-and-custody` (the wallet foundation; do FIRST).**
Grow the proven `Broker` boundary (§2) into the real signing broker with real
custody (§5). **Contains:** the three-tier custody stack — hardware first-class,
OS keychain (`libsecret` / Keychain Services / Android Keystore) as the software
default, encrypted-at-rest vault (a pinned memory-hard KDF + AEAD from a bound
vetted library) as the fallback; the broker's own process/sandbox (promote the
`ChildProcessBroker` shape to a real long-lived broker); the async + refusable
signing interface the hardware tier shapes; the per-account backend record + the
user's see/migrate view. **Bar:** a real (test-network) key is custodied per tier
behind the broker and NEVER reaches the page/content process; `eth_requestAccounts`
round-trips as the spike proved but now against real custody. **Must DECIDE:** the
EXACT KDF + AEAD primitive pick for the vault (the finding fixes the CLASS, not the
instance); the biometric/lock policy per method; whether to promote the JSON IPC
envelope to JSON-RPC 2.0 proper (§2). The vault AEAD choice is ALSO the primitive
the ENS-repoint carry-forward inherits (§4) — pick once.

**Slice W1 — `build-wallet-signing-and-approval-ux` (after W0).** Grow the
provider from the one auto-granted `eth_requestAccounts` into the full
signing-vs-read-only method surface (ADR-0015 d.4). **Contains:** the
signing/state-changing/disclosure methods (`eth_sendTransaction`, `personal_sign`,
`eth_signTypedData_v4`, `wallet_switchEthereumChain`, `eth_accounts`) with their
out-of-page, origin-bound APPROVAL UX; read-only methods (`eth_call`,
`eth_chainId`, …) supported ungated; the origin stamp enforced on every request
(§2). **Bar:** a signing method requires an out-of-page approval bound to the
requesting content origin; a read-only method does not; the "Bob's app mimics
Alice's app" cross-app confusion is defeated by the browser-stamped origin.
**Must DECIDE:** the approval-UX shape (native dialog vs a chrome surface) and how
it renders the payload truthfully (esp. blind-signing surfacing for hardware, §5).

**Slice W2 — `build-wallet-multichain` (after W1, parallel with W3).** Multi-EVM-
chain from the design (ADR-0015 d.4): per-origin selected chain (the `WalletLink`
already carries it, §4), chain switching via `wallet_switchEthereumChain`,
per-chain RPC endpoints. **Bar:** two origins can hold DIFFERENT selected chains
independently; a chain switch is an origin-bound, prompted action. **Must DECIDE:**
the chain-metadata source (bundled list vs user-added) and the RPC-endpoint trust
posture (ADR-0011: is the RPC node an untrusted transport like a gateway?).

**Slice W3 — `build-wallet-non-interactive-signatures` (after W1, parallel with
W2).** Implement the two non-interactive classes (§5): origin-bound automatic
decryption + the EIP-712 auth-signature envelope, both STRUCTURALLY recognised,
gated by the non-interactive predicate. **Contains:** the concrete EIP-712 auth
envelope WIRE format (domain + type + origin + verifier-injected unforgeable
data); the decrypt-allowed-origin match against the browser-determined origin;
ERC-1271/1654 verification for contract wallets; the predicate wired so ONLY the
recognised classes skip the prompt. **Bar:** a recognised auth signature / a
same-origin decrypt is performed WITHOUT a prompt; everything else prompts; a
biometric-gated key still unlocks even when the confirmation is skipped. **Must
DECIDE:** the exact envelope wire format + EIP-712 type strings (ADR-0015 "Note"
deferred these to here).

**Slice I0 — `build-ipfs-cid-decoder-and-verified-gateway` (the IPFS foundation;
independent of the wallet slices, can run in parallel).** Grow the proven
fetch+verify attach (§3) into the real depth-(i)+(ii) IPFS path. **Contains:** the
CID GRAMMAR — decode a real `ipfs://…` string (multibase/multihash/codec/version)
into a `ContentAddress`, adding the non-SHA-256 multihash algorithms behind the
UNCHANGED verify contract; the bound-external-node source (rung (ii) — same
fetch+verify, the user's node URL) + always-allow-your-own-node; the
subresource/mixed-content policy for a verified page fetching unverifiable
subresources. **Bar:** a real `ipfs://<cid>` renders through the hook via
fetch+verify (gateway default + a bound node option); a hash mismatch rejects;
mixed content is handled per the decided policy. **Must DECIDE:** the
mixed-content policy exactly (block / downgrade-indicator / prompt); the default
gateway list + the user-node config surface.

**Slice I1 — `build-ipns-resolution` (after I0).** `ipns://` in scope (ADR-0015
d.6): resolve an IPNS name to a current CID, then reuse I0's fetch+verify
UNCHANGED. **Contains:** the IPNS resolver (DHT / a resolver endpoint) + its
name-record freshness/verification story. **Bar:** an `ipns://<name>` resolves to
a CID and renders via the same verify core. **Must DECIDE:** the resolver trust +
freshness policy for the mutable name→CID step (the CID→bytes step is already
trust-solid).

**Slice I2 — `build-ipfs-in-browser-node` (LATER, opt-in; after I0).** Rung (iii)
(§3): embed an IPFS full node (DHT participation, bitswap, datastore) so
resolution needs no external gateway. The heaviest rung — its own subsystem with a
resource budget. **Bar:** wezig resolves a CID from its OWN embedded node via the
SAME verify contract; opt-in, off by default. **Must DECIDE:** the node
implementation (bind a node vs a Zig-native one) and the resource-budget / lifecycle
policy; whether/when it is promoted to the default (ADR-0015 d.6 leaves this open).

### Its OWN explorations (NOT wallet/IPFS build slices)

Two capabilities are explicitly their OWN explorations, not tasks on the specs
above — the exploration's "which are their own explorations" verdict:

- **`explore-webextensions-runtime` (a WebExtensions runtime — the big one).**
  MetaMask-class extension wallet-compat is a full WebExtensions RUNTIME, its own
  large subsystem, HARD-gated behind a bound `ScriptEngine` (ADR-0013 — not yet
  bound) because extensions ARE JS with isolated worlds (§5). It is the
  evaluate-then-build shape THIS exploration used, scoped to answer "can we host an
  isolated-world content-script + MV3 background SW + the `chrome.*` subset a
  wallet needs, and at what compatibility ceiling." NATIVE-first means this pays
  for nothing now and EIP-6963 keeps it additive later (§5). NOT a wallet-build
  task.
- **`spike-webkitgtk-sw-scheme-patch` (the `ipfs://` SW-hosting fork spike;
  ADR-0016).** The heavy, time-boxed spike that PROVES the minimal WebKitGTK fork
  patch hosts one SW on a secure `ipfs://` page end-to-end AND MEASURES its
  standing cost, so the keep-as-fork commitment is ratified on data, not
  speculation (§3). SW-hosting is Linux/WebKitGTK-first via the carried patch;
  other platforms defer to `WezigRenderer` or a per-platform equivalent; the seam
  trait declaration is common to all. This is a BACKEND-capability spike, not a
  fetch+verify rung and not on the IPFS build spec.

### Ordering summary (the critical path)

The wallet and IPFS tracks are INDEPENDENT and can proceed in parallel. On the
WALLET track, **W0 (broker + real custody)** is the foundation everything hangs
off; then **W1 (signing + approval UX)**, after which **W2 (multichain)** and
**W3 (non-interactive signatures)** can run in parallel. On the IPFS track,
**I0 (CID decoder + verified-gateway + bound node)** is the foundation; then
**I1 (IPNS)** and, LATER/opt-in, **I2 (in-browser node)**. The WebKitGTK backend
per-origin-channel fix (§4) is a W0/W1 obligation before multiple concurrent
origins work on that backend. The `explore-webextensions-runtime` exploration is
gated behind a bound `ScriptEngine` and is EXPLICITLY out of this plan;
`spike-webkitgtk-sw-scheme-patch` gates the `ipfs://`-SW-hosting capability on the
webview backend and runs on its own timeline (the IPFS build starts from a
per-backend SW-hosting story, ADR-0016, not a guess).

## Decisions recorded by this deliverable

This is a documentation task, but it makes judgement calls worth ratifying
(recorded here so a reviewer + the human can ratify or reverse them):

- **This findings doc lives at `docs/web3-capabilities-exploration-findings.md`,
  alongside `docs/native-renderer-exploration-findings.md` and
  `docs/shell-exploration-findings.md`,** NOT under `docs/adr/`. *Rationale:* it
  is a report + plan (a reference document), not a single decision; ADRs stay
  short (`work/protocol/ADR-FORMAT.md`), and the load-bearing DECISIONS are
  already pinned in the per-decision ADRs the exploration produced (ADR-0015,
  ADR-0016). This is the exact precedent the sibling explorations set
  (`docs/shell-exploration-findings.md` + ADR-0007;
  `docs/native-renderer-exploration-findings.md` + ADR-0014). *Alternative
  considered:* fold everything into one long ADR — rejected because it violates
  the "an ADR can be a single paragraph" norm and buries the plan. *Touches:* no
  code, no seam, no other task; the doc-drift guard (`src/docs.zig`) covers only
  `docs/v0-subset.md`, so a new `docs/` file leaves the v0 gate green.

- **NO new companion ADR is authored by this task.** *Rationale:* the task brief
  says point TO ADR-0015 for the decisions rather than re-deciding them, and the
  web3 exploration's load-bearing decisions were already pinned in ADR-0015
  (the model) + ADR-0016 (the SW-hosting story) by the spike tasks themselves —
  unlike the native-renderer exploration, whose findings doc authored its
  companion ADR-0014 because no single prior ADR captured its outcome. Adding an
  ADR-0017 that only points here would duplicate ADR-0015's role. *Alternative
  considered:* author a companion "exploration outcome" ADR mirroring ADR-0014 —
  rejected as redundant with ADR-0015 (which already records the outcome + the
  build inputs in its Consequences). *Touches:* the ADR sequence (leaves 0017
  free); if a human wants an explicit outcome-ADR later, this doc is the body it
  would point to.

- **The web3 build is SLICED into the wallet specs (W0–W3) + the IPFS specs
  (I0–I2) of §6, plus two SEPARATE explorations, not one spec.** *Rationale:* the
  spec's Out-of-Scope separates the wallet from the IPFS stack, and
  `evaluate-custody-and-extension-compat` explicitly calls WebExtensions its own
  exploration; "task a spec atomically or split it" forbids one spec mixing the
  custody foundation with the non-interactive-signature slice. The slicing +
  ordering is a PROPOSAL the human authoring the follow-on specs adopts and may
  re-cut; it is not a pinned interface. *Touches:* the plan's shape only, flagged
  for ratification rather than silently assumed.

## Cross-references

- **ADR-0015** — the pinned web3 security model + build inputs (origin model,
  origin-keyed wallet, custody direction, EIP-6963 + signing split, signing
  broker, IPFS depth ladder, `ipfs://`-secure-origin trait). The load-bearing
  decisions this doc synthesizes rather than re-decides (§1).
- **ADR-0016** — how `ipfs://` service-worker HOSTING is delivered on the webview
  backend (a carried WebKitGTK fork patch, gated behind a cost spike;
  `WezigRenderer` the eventual restriction-free home) (§3, §6).
- **ADR-0011** — the general-browser, post-trusted-server thesis every web3
  decision is anchored on; the content-addressed origin is its most concrete
  expression.
- **ADR-0005/0006** — the `Renderer`/`Toolkit` seams the broker + IPFS attach at
  and that survive the `WezigRenderer` swap.
- **ADR-0013** — the `ScriptEngine` seam a WebExtensions runtime is hard-gated
  behind (§5, §6).
- **`src/wallet_broker.zig` / `src/wallet_broker_spike.zig`** — the proven broker
  boundary + EIP-6963 provider + the live out-of-process round-trip (§2).
- **`src/ipfs_scheme.zig`** + **`Renderer.declareSchemeSecurity`** — the proven
  `ipfs://` fetch+verify + the secure-origin seam extension (§3).
- **`src/web3_origin.zig`** — the content-origin + per-ORIGIN wallet-link model +
  the ENS-repoint carry-forward + the per-origin provider binding (§4).
- **`work/notes/findings/web3-origin-and-signature-ux-thesis-wighawag-blog.md`** —
  the author's ratified web3-UX thesis, the design intent every decision realises.
- **`work/notes/findings/ipfs-depth-ladder-and-verified-gateway-2026-07-19.md`** —
  the IPFS depth ladder + the verified-gateway default (§3).
- **`work/notes/findings/wallet-custody-webextensions-and-non-interactive-signatures-2026-07-19.md`**
  — the threat-analysed custody stack, the WebExtensions verdict, the
  non-interactive signature classes (§5).
- **`docs/shell-exploration-findings.md`** / **`docs/native-renderer-exploration-findings.md`**
  — the sibling exploration deliverables this mirrors (and the seam gaps §2/§4
  inherit: the wallet-broker-is-native-side observation, the hardcoded-channel
  sharp edge).
- **Spec `explore-web3-capabilities`** — story 6, the exploration deliverable
  this answers.
