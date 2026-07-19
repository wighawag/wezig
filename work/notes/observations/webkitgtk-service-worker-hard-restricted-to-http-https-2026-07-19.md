---
date: 2026-07-19
kind: observation
spotted-during: spike-ipfs-secure-origin-service-worker
---

WebKitGTK 6.0 (2.52.3, this dev box) HARD-REJECTS `navigator.serviceWorker.register()`
on any non-HTTP(S) scheme, EVEN when the scheme is registered as a secure origin via
`webkit_security_manager_register_uri_scheme_as_secure`. Observed live: an `ipfs://`
page served through the seam's custom-scheme hook, with `ipfs://` declared secure +
CORS-enabled, calling `serviceWorker.register('sw.js')` fails with the exact WebKit
error: "serviceWorker.register() must be called with a script URL whose protocol is
either HTTP or HTTPS".

Root cause is a WebCore-engine-level gate, NOT a WebKitGTK-API gap:
`Source/WebCore/workers/service/ServiceWorkerContainer.cpp` (~L194–200) checks the
PROTOCOL of the SW page and rejects anything but http/https. Secure-origin
registration is NECESSARY for a secure context but NOT SUFFICIENT for SW hosting on a
custom scheme. WebKitGTK 6.0 exposes no public API to allowlist a scheme for service
workers (the way Electron/Chromium expose `protocol.registerSchemeAsPrivileged`); the
`WebKitSecurityManager` surface is secure/CORS/local/no-access/display-isolated/
empty-document only. Same limitation is tracked upstream for Tauri
(github.com/tauri-apps/tauri#13031, "status: upstream").

Consequence for the two-layer finding
`work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`:
its premise that "whether content served by our native scheme interception can host a
service worker is decided by how we register the scheme's SECURITY TRAITS" is
INCOMPLETE for the WebKitGTK backend — the traits are one gate, the http(s)-protocol
allowlist is a SECOND, backend-level gate with no public knob. This drifts
`spike-ipfs-secure-origin-service-worker`'s "host ONE service worker on an `ipfs://`
page end-to-end on the webview backend" acceptance criterion. Reported via TASK-STOP
for a human to re-scope (see that task's stop report).
