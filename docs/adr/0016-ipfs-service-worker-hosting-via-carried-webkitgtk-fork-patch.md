---
status: accepted
---

# `ipfs://` service-worker hosting: carry a minimal WebKitGTK fork patch (propose upstream, don't depend on acceptance); `WezigRenderer` is the eventual home

wezig wants `ipfs://` to be a first-class SECURE origin that can host service
workers (ADR-0015 decision 7). The `spike-ipfs-secure-origin-service-worker`
exploration verified LIVE that this is IMPOSSIBLE on stock WebKitGTK today, so
this ADR decides HOW we get the capability without either blocking on our own
engine or abandoning the webview-first strategy: we carry a MINIMAL WebKitGTK
fork patch that opts a secure embedder-registered scheme into SW-hosting, propose
that patch upstream, but do NOT depend on upstream accepting it — and treat
`WezigRenderer` (our own engine) as the eventual, restriction-free home.

## Context — the verified blocker

`spike-ipfs-secure-origin-service-worker` STOPPED on a load-bearing stale premise
(see `work/notes/observations/webkitgtk-service-worker-hard-restricted-to-http-https-2026-07-19.md`).
On WebKitGTK 6.0 (2.52.3), registering `ipfs://` as a secure origin via
`webkit_security_manager_register_uri_scheme_as_secure` (+ `_as_cors_enabled`) is
NECESSARY but NOT SUFFICIENT: WebKit additionally hard-rejects
`navigator.serviceWorker.register()` on any non-HTTP(S) scheme at the WebCore
engine level (`Source/WebCore/workers/service/ServiceWorkerContainer.cpp`
~L194–200), with no public API to allowlist a scheme for SWs (unlike
Chromium/Electron's `protocol.registerSchemeAsPrivileged`). The same limitation
is tracked upstream for Tauri (github.com/tauri-apps/tauri#13031, "status:
upstream"). This falsifies the two-layer finding's premise that scheme SECURITY
TRAITS alone decide SW-hosting — there is a SECOND, backend-level protocol
allowlist gate with no public knob.

This is a backend limitation, NOT an architecture problem: ADR-0005 never picked
WebKitGTK as THE engine — it picked it as the FIRST, DISPOSABLE
`SystemWebviewRenderer` behind the `Renderer` seam, precisely so a limit like
this cannot corner us. The chrome/wallet/IPFS talk only to the seam
(`chrome_conformance` enforces zero `webkit_`/`gtk_` reach), so swapping or
patching the backend costs one file, never a rewrite.

## Decision

1. **WebKitGTK stays the first backend; the SW-hosting limit does not change
   that.** The choice was Linux-driven (the dev+CI platform) and deliberately
   REVERSIBLE. The blocker argues about a backend capability, not the
   system-webview-behind-a-seam architecture, which remains sound.

2. **Get `ipfs://` SW-hosting via a MINIMAL carried WebKitGTK fork patch.** The
   blocker is a single localized policy predicate ("http/https") in one WebCore
   function. The patch WIDENS it to "http/https OR a scheme the embedder
   explicitly registered as SW-capable", exposed as an opt-in the embedder must
   set (a `WebKitSecurityManager`-style
   `register_uri_scheme_as_service_worker_capable`, mirroring the existing
   `_as_secure`/`_as_cors_enabled` surface). It is a POLICY RELAXATION behind an
   explicit opt-in, not a rendering change.

3. **Propose the patch upstream, but do NOT depend on acceptance.** We carry the
   patch in our own build and ship it; we also submit it upstream (with the Tauri
   thread as corroborating demand). wezig's capability is NEVER gated on upstream
   merging it. This is the standard serious-embedder stance (Tauri/Electron/distro
   pattern).

4. **`WezigRenderer` is the eventual, restriction-free home.** Our own engine owns
   its scheme registry, so `ipfs://`-SW-hosting there needs no patch at all — it
   is a native capability. The fork patch is the BRIDGE that delivers the
   capability on the shipping webview backend during the multi-year `WezigRenderer`
   build, not a permanent commitment.

5. **The capability is BACKEND-SPECIFIC and that asymmetry is accepted
   consciously.** The patch fixes Linux/WebKitGTK only. WKWebView (macOS/iOS, same
   WebKit core but Apple's UNPATCHABLE binary) and WebView2 (Windows, Chromium —
   `registerSchemeAsPrivileged` exists, a different mechanism) are separate
   surfaces. So `ipfs://`-SW-hosting-on-the-webview-backend is a Linux-first
   capability until `WezigRenderer` (all platforms) or a per-platform equivalent
   lands. The `Renderer` seam already abstracts this: the seam's
   scheme-security-traits extension (below) is the same everywhere; only whether a
   given backend can honour SW-hosting varies.

6. **Commit to the fork ONLY after a de-risking spike measures its cost.** We do
   NOT sign up for a WebKit fork's maintenance tail on speculation. A time-boxed
   spike (`spike-webkitgtk-sw-scheme-patch`) first PROVES the patch works
   (patched WebKitGTK hosts one SW on a secure `ipfs://` page end-to-end) and
   MEASURES the standing cost (build time, patch size vs current `main`, rebase
   friction across 1–2 recent WebKit releases, the upstream-proposal draft). The
   keep-as-fork commitment is ratified AFTER that data exists.

## Consequences

- **The `Renderer` seam gains a scheme-security-traits extension regardless of the
  fork.** Declaring `ipfs://` a secure origin (secure/CORS/local) at the seam so a
  `WezigRenderer` reproduces it is ADR-0015 decision 7's ask and is INDEPENDENT of
  the SW-hosting patch — it is a clean, self-contained deliverable. The re-scoped
  `spike-ipfs-fetch-verify-and-secure-origin-seam` task delivers exactly that
  (CID fetch+verify through the interception hook + the secure-origin seam
  extension, proven in the core gate), with NO SW-end-to-end criterion.
- **Owning a WebKit build is a real, non-trivial cost** (multi-hour C++ build,
  packaging/distribution, per-release rebase) — it PARTLY re-introduces the
  "own an engine" burden ADR-0005 defers. This is why decision 6 gates the
  commitment behind a cost-measuring spike, and why the standing position remains
  "system `libwebkitgtk` unless/until the fork is ratified as worth it".
- **Distribution changes if we ship the fork** (bundled/own-packaged
  `libwebkitgtk` instead of the system one). Scoped to the
  `SystemWebviewRenderer`/build, never the chrome.
- **The build spec for real IPFS starts from a DECIDED SW-hosting story per
  backend**, not a guess: Linux via the carried patch, other platforms deferred to
  `WezigRenderer` or a per-platform equivalent, the seam extension common to all.

## Considered options (and why rejected as the primary path)

- **Defer ALL `ipfs://`-SW-hosting to `WezigRenderer`.** Clean, but starves the
  capability for the multi-year engine build. Kept as the eventual home (decision
  4), not the near-term answer.
- **https-loopback shim** (serve `ipfs://` content over a local `https://`
  origin so WebKit's allowlist is satisfied). A real workaround others use, but it
  fabricates an origin that is NOT the content-addressed one — in tension with
  ADR-0011's "the content hash IS the origin" (localStorage/wallet-link/signature
  binding would key on the loopback origin, not the CID). Recorded as a FALLBACK
  if the fork proves too costly, not the preferred path.
- **Switch Linux to a Chromium embedding (CEF) instead of WebKitGTK.** CEF exposes
  `registerSchemeAsPrivileged`, so no patch — but swapping the whole engine is a
  far larger decision than "which webview", drags in CEF's own weight, and is
  premature before the minimal-patch cost is even measured. Not chosen now.
- **Depend on upstream WebKitGTK adding the API.** Rejected: it makes a
  first-class wezig capability hostage to an external roadmap. We propose it
  (decision 3) but never depend on it.

## Note

This ADR records the DECIDED direction + the gate (a cost-measuring spike before
the fork commitment). The patch's exact shape, the fork/build/distribution
mechanics, and the keep-vs-defer-vs-shim final call are settled by
`spike-webkitgtk-sw-scheme-patch` and its follow-on. No real custody/secret/
release path is touched by any of this.
