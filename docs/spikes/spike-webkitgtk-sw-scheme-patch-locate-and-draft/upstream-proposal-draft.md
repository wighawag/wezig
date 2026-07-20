# DRAFT upstream proposal — allow embedder-registered schemes to host service workers

> **Status: DRAFT, not filed.** Filing a WebKit bug / merge request is a human
> action (ADR-0016 decision 3). This is the argument + corroboration, ready to
> paste into a bugs.webkit.org report or a WebKit GitHub PR when a human decides
> to submit it. wezig ships the carried patch regardless of upstream's decision.

## Title

Allow secure, embedder-registered URI schemes to host service workers (opt-in
GLib API), mirroring the existing `register_uri_scheme_as_secure` surface.

## Summary

`ServiceWorkerContainer::addRegistration` hard-rejects
`navigator.serviceWorker.register()` for any scriptURL/scopeURL whose protocol is
not in the HTTP family (unless the page is a service-worker page). This is
correct as a DEFAULT, but there is no way for an embedder to opt a scheme it owns
into service-worker hosting, even when that scheme is already registered as a
secure origin via `WebKitSecurityManager` (`register_uri_scheme_as_secure` /
`_as_cors_enabled`). We propose a narrow, default-off opt-in that admits an
embedder-registered scheme through that gate.

## Motivation

A content-addressed scheme (e.g. `ipfs://`, where the URL *is* the SHA-256 of the
bytes) is, if anything, a STRONGER secure context than `https://`: its integrity
does not depend on a live TLS handshake with a trusted server — the bytes are
verified locally against the address, so an active network attacker cannot corrupt
them. Such an origin has exactly the property service workers assume (a stable,
tamper-evident origin), yet it cannot host one. Embedders building
content-addressed or app-scheme browsers therefore cannot offer offline/SW-backed
apps on their own secure schemes, even though every other secure-context feature
(via `register_uri_scheme_as_secure`) is already reachable.

This is NOT a request to relax the default. It is a request for a
parallel opt-in to the one that already exists for "secure" and "CORS-enabled":
the scheme must be EXPLICITLY registered by the embedding application, so a stock
browser and any app that does not call the new API are completely unaffected.

## Proposed change

1. `LegacySchemeRegistry`: add `registerURLSchemeAsServiceWorkerCapable` /
   `shouldTreatURLSchemeAsServiceWorkerCapable`, matching the existing
   secure/CORS-enabled registry pairs (thread-safe, lock-guarded set).
2. `ServiceWorkerContainer::addRegistration`: widen BOTH the scriptURL and
   scopeURL protocol checks to also admit
   `LegacySchemeRegistry::shouldTreatURLSchemeAsServiceWorkerCapable(protocol)`.
   (Two added `&&` clauses; the existing http/https + service-worker-page
   allowances are unchanged.)
3. WebKitGTK GLib API: add
   `webkit_security_manager_register_uri_scheme_as_service_worker_capable` and
   `..._uri_scheme_is_service_worker_capable`, plumbed through `WebProcessPool`
   to every web process exactly like `register_uri_scheme_as_secure` (so late
   web processes inherit the registration via the creation parameters).

The full located+sized diff is in `webkitgtk-sw-scheme-capable.patch` (this
sidecar): ~105 added / 2 changed lines across 9 files, almost entirely a mirror
of the existing per-trait plumbing.

## Why an opt-in (not a blanket relaxation), and why it is safe

- **Default-off.** No behaviour changes unless an app calls the new registration
  API. The stock browser gate is untouched.
- **Secure-context still required.** The opt-in admits the scheme through the
  PROTOCOL gate only; the origin must still be a secure context (the embedder is
  expected to also register it as secure). SW hosting on an insecure origin
  remains impossible.
- **Same trust boundary as `register_uri_scheme_as_secure`.** An embedder that
  can already declare a scheme secure is trusted to declare it SW-capable; this
  adds no new trust surface beyond the one WebKit already grants embedders.

## Corroborating demand

- **Tauri #13031** (github.com/tauri-apps/tauri#13031, "status: upstream"): Tauri
  apps hit the identical wall — custom app schemes registered as secure cannot
  host service workers because of this exact WebCore gate — and the issue is
  tracked as needing an upstream change. This proposal is precisely the upstream
  hook that would unblock it, and generalizes beyond wezig's `ipfs://` case to
  any embedder with a secure custom scheme.

## Non-goals / scope

- No change to the default http/https policy.
- No new rendering behaviour; this is a policy/registry change only.
- Cross-platform: the WebCore + `LegacySchemeRegistry` change is engine-wide; the
  GLib API is WebKitGTK-specific. A WPE equivalent is trivial (same pattern);
  Cocoa (WKWebView) would need its own SPI/API surface and is out of scope for
  this proposal.
