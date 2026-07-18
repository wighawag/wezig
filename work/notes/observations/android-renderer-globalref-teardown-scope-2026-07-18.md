# Android renderer re-injection + global-ref lifecycle — design decisions (task `android-renderer-reinject-and-globalref-fix`)

_2026-07-18 — durable record of the load-bearing / potentially-surprising choices
made implementing the two Zig-side fixes in `src/android_renderer.zig` (spec
`build-mobile-shell`, stories 8/10; ADR-0009 §Consequences hazard + §3
re-injection gap). Recorded here so the reviewer + the downstream
`android-shell-app` task can ratify or reverse; linked from the done record._

## 1. `EmbedCtx` free is left to the shell task; the renderer frees its OWN native ctx

The task says "free the `EmbedCtx` global-ref on teardown" AND "everything stays
INSIDE `src/android_renderer.zig`". Those pull apart: the literal `EmbedCtx`
lives in a DIFFERENT seam/file — `mobile/android/app/src/main/cpp/wezig_embedding_jni.c`,
owned by the chrome-surface path (`wezig_android_chrome_surface_deinit` in
`src/mobile_chrome_surface.zig`), NOT the renderer. It cannot be freed from
`android_renderer.zig` without editing the embedding shim (which is the
`android-shell-app` task's `mobile/android/**` scope).

**Chosen:** implement the renderer-side lifecycle fully inside the backend file —
(a) cache ONE view global-ref (lazy, returned unchanged), (b) delete it on
teardown via a new `deleteView` bridge op, and (c) free the RENDERER's own native
context (the JNI shim's per-renderer `JavaCtx`: cached `JavaVM` + controller
global-ref, currently leaked because `wezig_android_renderer_deinit` only freed
the Zig `CBackend`) via a new `teardown` bridge op. The renderer's `JavaCtx` is
the renderer-side analogue of the embedding shim's `EmbedCtx`; fixing it is the
in-file, headless-testable half of the ADR-0009 "leaked native ctx" hazard.

**Left to `android-shell-app`** (logical dependant, edits `mobile/android/**`):
wire the two new C-ABI ops in `wezig_renderer_jni.c` (a `bridge_delete_view` =
`DeleteGlobalRef`, a `bridge_teardown` = free the `JavaCtx` + `DeleteGlobalRef`
its controller) and fix the actual `EmbedCtx` free in `wezig_embedding_jni.c`'s
`nativeDestroySurface` (today intentionally leaked). Those are C-shim mirrors of
the seam-level lifecycle proven here; they do not change the Zig gate.

**Alternative considered:** reach into `mobile_chrome_surface.zig` /
`wezig_embedding_jni.c` from this task to free the literal `EmbedCtx`. Rejected:
violates the "inside `android_renderer.zig`" + "nothing above the seam changes"
constraint and collides with `android-shell-app`'s file scope. **Touches:**
`android-shell-app`, `wezig_renderer_jni.c`, `wezig_embedding_jni.c`,
`mobile_chrome_surface.zig`.

## 2. Two new bridge ops (`deleteView`, `teardown`) extend `JavaBridge` + `CJavaBridge`

New named ops on the pinned-per-backend bridge tables (NOT the `Renderer` seam —
the seam signature is unchanged, so nothing above the seam and `chrome_conformance`
are untouched). `CJavaBridge` is the C-ABI struct the JNI shim mirrors
("field order MUST match"), so the checked-in `wezig_renderer_jni.c`
`WezigCJavaBridge` is now one revision behind until `android-shell-app` adds the
two fields. This does NOT break the Zig gate (`zig build` / `zig build test` never
compile the `.c` shim; only Gradle does, in the shell task). Recorded so the
mismatch is expected, not a surprise regression.

**Coherence check:** `deleteView`/`teardown` reuse the existing ops-table /
`CJavaBridge` pattern (the same shape as `view`/`registerScheme`), name nothing
in the CONTEXT.md glossary, and re-mean nothing — they are the delete/free duals
of the existing `view`/construction ops, at the RIGHT layer (the JNI bridge, not
the backend-agnostic seam). No new seam concept, flag, or status.

## 3. Re-injected source is copied into an in-struct fixed buffer (no allocator)

`injectUserScript` only LENDS `source` for the call (the real JNI path frees the
`GetStringUTFChars` copy right after). To re-issue on each `.started`, the backend
must OWN it. `AndroidWebviewRenderer` takes no allocator (headless tests + the C
path construct it without one), so the source is copied into a
`[max_injected_source:0]u8` in-struct buffer — matching the module's existing
fixed-buffer style (the scheme/title C-observer buffers). `max_injected_source`
= 8192; a longer source is still injected once but NOT remembered (cannot be
re-issued). Fine for the marker/provider-bridge sources this is built for.
**Alternative:** thread an allocator through `init`. Rejected as a wider ripple
than the fixed buffer, for a bounded input. **Touches:** nothing outside the
backend file.
