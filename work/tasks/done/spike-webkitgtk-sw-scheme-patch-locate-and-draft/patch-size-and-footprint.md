# WebKitGTK SW-scheme patch: size + file/function footprint

Measured against WebKit **main** source, read-only (the dev box cannot build
WebKitGTK — see the findings note). The two load-bearing WebCore predicates and
the sibling GLib/registry/IPC layers were located and pinned line-for-line
against the upstream files (fetched 2026-07-19); the patch is
`webkitgtk-sw-scheme-capable.patch` in this sidecar.

## Size (from the patch's own diffstat)

- **9 files** touched across **3 layers**.
- **~105 inserted lines, 2 modified lines** (the 2 WebCore predicate widenings),
  ~0 deletions of behaviour. The bulk (~90 lines) is MECHANICAL glue that mirrors
  an existing surface (`_as_cors_enabled`), not new logic.
- The actual POLICY change is **2 predicate clauses** (one added `&&` term each,
  scriptURL + scopeURL) + **one registry pair** (~20 lines). Everything else is
  plumbing that carries that decision out to the GLib API.

## File / function footprint by layer

### Layer 1 — WebCore policy predicate (the real change)
`Source/WebCore/workers/service/ServiceWorkerContainer.cpp`
- `ServiceWorkerContainer::addRegistration` — TWO sibling predicates widened:
  - `scriptURL` gate (~L196): add
    `&& !LegacySchemeRegistry::shouldTreatURLSchemeAsServiceWorkerCapable(jobData.scriptURL.protocol())`
  - `scopeURL` gate (~L213): the same term on the scopeURL check.
- `LegacySchemeRegistry.h` is ALREADY `#include`d here (verified in main), so no
  new include is needed. 2 lines changed, 0 added in this file.

### Layer 2 — the scheme registry (the query the predicate calls)
`Source/WebCore/platform/LegacySchemeRegistry.{h,cpp}`
- New pair mirroring `registerURLSchemeAsCORSEnabled` / `shouldTreatURLSchemeAsCORSEnabled`:
  `registerURLSchemeAsServiceWorkerCapable` + `shouldTreatURLSchemeAsServiceWorkerCapable`,
  backed by a lock-guarded `serviceWorkerCapableSchemes()` `URLSchemesMap`
  (the file's established idiom). ~4 header lines + ~20 impl lines.

### Layer 3 — WebKitGTK public API glue (the embedder opt-in)
`Source/WebKit/UIProcess/API/glib/WebKitSecurityManager.{h,cpp}`
- `SecurityPolicy` enum: +1 value (`SecurityPolicyServiceWorkerCapable`).
- `registerSecurityPolicyForURIScheme` + `checkSecurityPolicyForURIScheme`:
  +1 `case` each (both call the registry AND `processPool->…` to sync).
- Two new public functions mirroring `_as_secure`/`_is_secure`:
  `webkit_security_manager_register_uri_scheme_as_service_worker_capable` +
  `..._uri_scheme_is_service_worker_capable` (~46 lines incl. gtk-doc comments).
- Header: 2 declarations (~12 lines with the doc-block formatting).

### Layer 3b — UI-process → Web-process registry sync (the subtle extra layer)
`Source/WebKit/UIProcess/WebProcessPool.{h,cpp}`,
`Source/WebKit/WebProcess/WebProcess.{messages.in,cpp}`
- The GLib call keeps the UI-process `LegacySchemeRegistry` in sync AND must
  propagate to every web process (that is where `addRegistration` runs). The
  existing `_as_secure`/`_as_cors_enabled` do this via
  `WebProcessPool::registerURLSchemeAs…` → `m_schemesToRegisterAs…` +
  `sendToAllProcesses(Messages::WebProcess::RegisterURLSchemeAs…)`, replayed for
  late-launched processes through `WebProcessCreationParameters`. The patch
  mirrors that: +1 pool method, +1 IPC message, +1 web-process receiver
  (~20 lines total). **This is the footprint most likely to grow on rebase** —
  the creation-parameters replay list is the one spot a naive "just widen the
  predicate" patch forgets, so it is called out explicitly for the build task.

## Footprint summary (for ADR-0016 decision 6 ratification data)

| Layer | Files | Lines | Nature |
|-------|-------|------:|--------|
| WebCore predicate | 1 | 2 changed | the real policy relaxation |
| WebCore registry  | 2 | ~24 added | mirror of the CORS pair |
| GLib API glue     | 2 | ~58 added | mirror of `_as_secure` |
| UI↔Web IPC sync   | 4 | ~20 added | mirror of `_as_secure` propagation |
| **total**         | **9** | **~105 added, 2 changed** | mostly mechanical mirroring |

**Rebase-friction read:** the patch touches only files that ALREADY carry an
identical per-trait surface (secure/CORS), so every hunk has a stable, well-known
anchor. The rebase risk is bounded — a per-release rebase re-anchors on the CORS
sibling next to it. The one non-obvious hunk (the creation-parameters replay) is
flagged above so the build-and-measure task does not miss it. Actual build time +
observed rebase deltas across 1–2 releases are the deferred task's to MEASURE;
this task establishes the LOWER-BOUND footprint (small, localized, mirrors
existing code).

> Not built here (environment constraint). The `.patch` line numbers are
> approximate anchors against main; the build-and-measure follow-on rebases onto
> the exact tag it compiles and records the true final diffstat + build cost.
