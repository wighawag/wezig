---
title: Android shell app — real app module browsing one page through the seams
slug: android-shell-app
spec: build-mobile-shell
blockedBy: [mobile-chrome-loop-zig, android-renderer-reinject-and-globalref-fix]
covers: [2, 3, 4, 5, 6]
---

## What to build

Turn the Android spike (the bare Gradle project + single-page harness) into a REAL, maintainable Android app module that a person installs and browses with: an `Activity` hosting the mobile `Renderer` (`android.webkit.WebView`) + `ChromeSurface` driven by the shared mobile chrome (`mobile-chrome-loop-zig`), with a URL field + back/forward toolbar, and background→foreground page-state restoration.

End-to-end: the `Activity` builds the WebView-backed `Renderer` + the `MobileChromeSurface`, constructs the shared mobile chrome over them, lays out a URL field + back/forward buttons + the embedded WebView, and wires:
- **URL entry → navigate**, **back/forward buttons → goBack/goForward**, all THROUGH the chrome/seams (not raw WebView calls);
- **lifecycle events → widgets** (URL text + button enabled-state) via the chrome;
- **app lifecycle → state restoration (HOST-ONLY, Resolved decision 1):** on background/foreground (`onSaveInstanceState`/`onRestoreInstanceState` + `WebView.saveState`/`restoreState`), the current page survives without a seam change.

The Gradle project builds the Zig static lib as a normal Gradle task (not a bespoke shell script invoked out-of-band). Keep it Simulator/emulator + unsigned-debug (signing is Slice C).

## Acceptance criteria

- [ ] A real Android app module (`Activity` + layout) hosts the WebView `Renderer` + `ChromeSurface` via the shared mobile chrome; a URL field + back/forward toolbar drive navigation THROUGH the chrome/seams (no raw `android.webkit.*` calls outside the backend).
- [ ] The URL field reflects the current page and back/forward enable/disable correctly from `Renderer` lifecycle events (via the chrome).
- [ ] A background→foreground round-trip preserves the current page (host-only: `onSaveInstanceState`/`WebView.saveState` etc.); no `Renderer` seam method was added.
- [ ] The Gradle build compiles the Zig static lib as a normal build step (a Gradle task/dependency), not an out-of-band script; `mobile/android/build-zig-libs.sh`'s logic is invoked as part of the Gradle build or replaced by an equivalent Gradle step.
- [ ] The app builds to an installable (unsigned-debug) APK carrying `libwezigshell.so` for both ABIs (arm64-v8a + x86_64); it stays Simulator/emulator-only (no signing).
- [ ] The desktop v0 gate is untouched and green; the Android backend remains the sole `android.webkit.*` toucher.
- [ ] **JNI-shim lifecycle wiring inherited from `android-renderer-reinject-and-globalref-fix`** (that task deferred the `mobile/android/**`-side half to here — see `work/notes/observations/android-renderer-globalref-teardown-scope-2026-07-18.md`): (a) add the two new C-ABI ops `deleteView` (`DeleteGlobalRef` of the cached view ref) and `teardown` (free the per-renderer `JavaCtx` + `DeleteGlobalRef` its controller) as fields on `WezigCJavaBridge` in `mobile/android/app/src/main/cpp/wezig_renderer_jni.c`, in the SAME field order as the Zig `CJavaBridge` (the Zig struct now carries these fields; the checked-in shim is one revision behind until this task adds them — a latent field-order/ABI mismatch until wired); and (b) fix the intentionally-leaked `EmbedCtx` global-ref free in `wezig_embedding_jni.c`'s `nativeDestroySurface` so the embed ctx is released on teardown (the literal `EmbedCtx` clause from the backend task, deferred to this file's scope). Net: zero leaked JNI global-refs (view ref, renderer `JavaCtx`, and `EmbedCtx`) after teardown, exercised by the instrumented/emulator leg.
- [ ] Any semantic gap found (lifecycle/state-restoration, thread-marshalling) is recorded as a finding or in the done-record.

## Blocked by

- `mobile-chrome-loop-zig` — hosts the shared chrome the Activity constructs.
- `android-renderer-reinject-and-globalref-fix` — a LOGICAL dependency: the shell must build on the corrected Android backend (fixed re-injection + one-ref-per-view), not the leaky spike backend. (This is NOT a file conflict: this task edits `mobile/android/**` while that task edits `src/android_renderer.zig`; the dependency is that the shell relies on the backend's fixed behaviour, so it is sequenced after.)

## Prompt

> Goal: turn the Android spike into a REAL, maintainable Android app module (spec `build-mobile-shell`, stories 2/3/4/5/6): an `Activity` hosting the WebView `Renderer` + `ChromeSurface` driven by the shared mobile chrome, with a URL field + back/forward toolbar and background→foreground page-state restoration (HOST-ONLY per Resolved decision 1 — no `Renderer` seam change). The Gradle project must build the Zig static lib as a NORMAL Gradle step, not a bespoke out-of-band shell script.
>
> Read: `mobile/android/**` (the existing Gradle project + JNI shim + `build-zig-libs.sh` to fold into the Gradle build), `src/android_renderer.zig` (the WebView `Renderer` backend), `src/mobile_chrome_surface.zig` (`MobileChromeSurface`), the shared mobile chrome from `mobile-chrome-loop-zig`, `docs/mobile-exploration-findings.md` + ADR-0008/0009, and the findings on Android non-UI-thread callbacks + the embed-on-UI-thread rule. IMPORTANT — inherit the JNI-shim lifecycle half deferred by `android-renderer-reinject-and-globalref-fix` (read `work/notes/observations/android-renderer-globalref-teardown-scope-2026-07-18.md`): the Zig `CJavaBridge` gained two ops (`deleteView`, `teardown`) that the C shim's `WezigCJavaBridge` in `wezig_renderer_jni.c` must now mirror IN THE SAME FIELD ORDER (else a silent ABI/field-order mismatch), and the intentionally-leaked `EmbedCtx` free in `wezig_embedding_jni.c` `nativeDestroySurface` must be fixed here. These are the `mobile/android/**`-scoped half of the backend task's global-ref-leak fix; wiring them is part of THIS task (see the added acceptance clause). Keep the Android backend the SOLE `android.webkit.*` toucher; drive navigation only through the chrome/seams. Stay unsigned-debug/emulator-only (signing is Slice C). Wire background→foreground via `onSaveInstanceState`/`WebView.saveState`. "Done" = a real Android app module browses one page through the seams with a URL-bar/back-forward chrome, survives a background/foreground round-trip, builds the Zig lib as a normal Gradle step into an installable APK, desktop gate untouched.
