---
date: 2026-07-19
---

Decision recorded while building `spike-ipfs-fetch-verify-and-secure-origin-seam`
(the secure-origin seam extension, ADR-0015 d.7). The two-layer finding
(`sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`) explicitly
left OPEN whether a scheme's SECURITY TRAITS (secure/CORS/local) belong as EXTRA
FIELDS on the seam's existing `registerScheme` call or as a SIBLING call. I chose
a **sibling, OPTIONAL vtable method** `Renderer.declareSchemeSecurity(scheme,
traits)` (`src/renderer.zig`), NOT extra fields on `registerScheme`.

Why sibling (not extra fields on `registerScheme`): (1) security traits are a
distinct CONTEXT/security-layer concern — on WebKitGTK they map to a DIFFERENT API
(`WebKitSecurityManager` register-as-secure/cors/local) than the request callback
(`webkit_web_context_register_uri_scheme`); (2) `registerScheme` is called at ~8
sites across every backend (webkitgtk, wezig_renderer, ios, android + its C
backend, mobile_abi, ios_shell) — changing its signature would ripple a breaking
edit through all of them, whereas a sibling method is purely additive; (3) not
every scheme declares traits.

Why OPTIONAL (`?*const fn …` on the vtable, forwarder no-ops when null): ADR-0016
d.5 says the seam expresses the trait declaration UNIFORMLY but "whether a given
backend can honour it varies". An optional vtable method models exactly that — a
backend that cannot honour traits leaves the hook null and callers stay
backend-agnostic. So ONLY the two backends this task needs implement it today:
`FakeRenderer` (core-gate contract) and `SystemWebviewRenderer` (WebKitGTK). The
mobile/native/ios backends leave it null for now (their secure-origin story is
their own follow-on), which is safe because the forwarder no-ops.

Touches: the `Renderer` seam (`src/renderer.zig`), `SystemWebviewRenderer`
(`src/system_webview_renderer.zig`), and `src/ipfs_scheme.zig`
(`secure_origin_traits`). Does NOT touch `registerScheme`'s signature, so no
other backend's scheme registration changed. Alternative considered + rejected:
extra fields on `registerScheme` (breaking ripple, conflates two backend layers).
