# `CBackend.view` maps a null WebView ref to `undefined` (garbage non-null pointer)

_2026-07-18 — noticed while building `mobile-viewhandle-embedding-proof` (spec `explore-mobile-shell` Q3/story 6)._

In `src/android_renderer.zig`, `CBackend.view` (the C-boundary adapter) does
`return self.cbridge.view(self.cbridge.ctx) orelse undefined;`. If the JNI
`bridge_view` ever returns NULL (e.g. the WebView global-ref creation failed),
`view()` yields an `undefined` (garbage NON-null) pointer rather than a null the
callers can guard on. The new embedding path routes this through
`wezig_android_embed_view`, whose `view orelse return` cannot catch a
garbage-non-null value.

Pre-existing and edge-case only (the WebView is always non-null in the spike), so
NOT fixed here (outside this task's scope). If the mobile BUILD spec makes
`view()` fallible or the WebView can legitimately be absent, `CBackend.view`
should propagate null honestly instead of `orelse undefined`.
