# Android shell (real app module) — recorded design decisions

Decisions taken while building the real Android Gradle app module (task
`android-shell-app`, spec `build-mobile-shell`, stories 2/3/4/5/6). Recorded here
(and linked from the done record) so a reviewer/human can ratify or reverse them;
none is load-bearing/hard-to-reverse enough to STOP on, but each is a choice
another task / a user / a reviewer might be surprised was decided in-flight.

## 1. New `wezig_android_shell_*` C-ABI (a new named surface) — `src/android_shell.zig`

CHOSE: a dedicated Android shell C-ABI (`wezig_android_shell_start` + intent
relay thunks) for the real app, the exact twin of `src/ios_shell.zig`'s
`wezig_ios_shell_*`, SEPARATE from the exploration proof thunks
(`wezig_android_*` in `android_renderer.zig` / `mobile_chrome_surface.zig`).
WHY: mirrors the settled iOS shell shape (the human ratified `ios_shell.zig` as
the pattern); the proofs each assert ONE fact with a bespoke module-level sink,
the app drives the shared `MobileChrome` continuously. Reusing a proof thunk
would overload it. **Touches:** the Java `WezigShellController` + `wezig_shell_jni.c`
(the shim that fills the `CEmbedPlatform` and calls this C-ABI); no seam change
(`MobileChrome`/`MobileChromeSurface`/`AndroidWebviewRenderer` are reused as-is).
**Coherence:** `shell` is already the desktop app's name (`shell.zig`,
`shell_main.zig`) and the iOS shell's; this reuses it at the SAME layer (the
real-app composition over the seams), not re-meaning it.

## 2. `wezig_android_shell_start` takes the SHIM-OWNED renderer handle, not a fresh `CJavaBridge`

CHOSE: the shell entry point takes the already-constructed
`*AndroidWebviewRenderer` handle (the one the `WezigWebViewController` built via
`wezig_android_renderer_init` over its `CJavaBridge`) + the chrome-surface
`CEmbedPlatform` ops, and composes the surface + `MobileChrome` over it. It does
NOT re-take the renderer's `CJavaBridge`.
WHY: this DIVERGES from iOS, where `wezig_ios_shell_start` takes the flat
`WkPlatform` ops and constructs the `IosWebviewRenderer` itself. The Android
renderer's construction/lifetime is DIFFERENT: the JNI shim owns the renderer's
storage (`wezig_android_renderer_init` heap-allocates the `CBackend`;
`wezig_android_renderer_deinit` frees it) AND its JNI global-ref lifecycle (the
one cached view ref + the `JavaCtx`, deleted via the new `deleteView`/`teardown`
bridge ops). Re-taking the `CJavaBridge` in the shell would DUPLICATE that
construction and split the renderer's lifecycle across two owners — exactly the
leak-prone shape this task is fixing. Passing the handle keeps the renderer's
global-ref lifecycle owned end-to-end by the shim (constructed by
`WezigWebViewController`, torn down by its `destroy()`), and the shell only
composes the two seam VALUES the chrome drives. **Touches:** `wezig_shell_jni.c`
(passes `renderer.nativeHandle()` in), `WezigWebViewController` (owns the
renderer). **Alternative considered:** re-take the `CJavaBridge` for iOS parity —
rejected: it forks the renderer lifecycle and reintroduces the leak surface.

## 3. Single-instance shell state (module-level `android_shell` + shim `g_shell_ctx`)

CHOSE: one shell at a time — `android_shell.zig` holds a module-level
`android_shell` value; `wezig_shell_jni.c` tracks one `g_shell_ctx`. Starting a
new shell overwrites/frees the prior.
WHY: matches the spec ("one visible page; N-context tabs are Slice B"), the iOS
shell's `ios_shell` module-level value, and the existing shims' single-instance
discipline (`g_observer_ctx`/`g_msg_observer_ctx`/`g_scheme_observer_ctx` in
`wezig_renderer_jni.c`). **Touches:** nothing outside these two files.
**Note:** the instrumented `ShellSeamTest`'s background→foreground path
constructs a SECOND shell (the restore), which overwrites the Zig
`android_shell` while the first is still alive; the test then tears both down.
This is within the single-instance contract (the first shell's chrome is
inert once clobbered) and is why the test destroys in a defined order.

## 4. The Zig static lib is built by a Gradle `buildZigLibs` task; CI legs drop the standalone script

CHOSE: fold `build-zig-libs.sh`'s logic into a Gradle `buildZigLibs` task in
`app/build.gradle` (derive the NDK sysroot from `android.ndkDirectory` + the
per-ABI Zig triple, run `zig build android-lib` per ABI into `app/.cxx-zig/`),
make the native (CMake) build depend on it, and REMOVE the standalone
`mobile/android/build-zig-libs.sh` step from the three CI legs
(`mobile-android.yml`, `mobile-verify.yml`, `release.yml`) so a plain
`gradle assembleDebug` builds everything (spec criterion 4).
WHY: the acceptance requires the Zig lib to be a NORMAL Gradle step, not an
out-of-band script. The script is KEPT as a standalone convenience (its logic is
mirrored by the task) rather than deleted, to avoid breaking any local/manual
use. **Touches:** the three CI workflows (their `build-zig-libs.sh` step + a
comment on the Zig setup step). **Alternative considered:** invoke the shell
script from Gradle via `Exec` — rejected: it couples the Gradle build to a bash
shell + `ANDROID_NDK_HOME` env (the task resolves the NDK via Gradle's own
`android.ndkDirectory`, more robust on CI), and the acceptance explicitly
permits an equivalent Gradle step.

## 5. Inherited JNI-shim lifecycle wiring (the deferred backend-task half)

WIRED here (per the added acceptance clause + the backend task's decision note
`android-renderer-globalref-teardown-scope-2026-07-18.md`):
- `wezig_renderer_jni.c`: added `deleteView` + `teardown` fields to
  `WezigCJavaBridge` IN THE SAME FIELD ORDER as the Zig `CJavaBridge` (between
  `view`/`setViewportSize` and as the LAST field, respectively), implemented by
  `bridge_delete_view` (`DeleteGlobalRef` the cached view ref) and
  `bridge_teardown` (free the per-renderer `JavaCtx` + `DeleteGlobalRef` its
  controller); wired both into the `nativeCreate` bridge initializer. Field
  order verified against `src/android_renderer.zig`'s `CJavaBridge`.
- `wezig_embedding_jni.c`: `nativeDestroySurface` now frees the `EmbedCtx`
  (tracked shim-side via `g_embed_ctx`, since `..._deinit` frees the Zig side
  that held it) — the literal `EmbedCtx` free deferred from the backend task.
- Added `WezigWebViewController.nativeDestroy` → `wezig_android_renderer_deinit`
  (the destructor already runs the teardown ops) so the app/test can drive
  renderer teardown; `WezigShellController.destroy()` frees the shell ctx too.
Net: zero leaked JNI global-refs (view ref + renderer `JavaCtx` + `EmbedCtx`)
after teardown. Proven headlessly (one-ref-per-view + zero-after-teardown) in
`android_renderer.zig`; the real `DeleteGlobalRef` path is exercised by
`ShellSeamTest`'s teardown on the emulator leg.

## Semantic gaps recorded (acceptance clause 8)

- **Lifecycle/state-restoration:** host-only (ADR-0010) via
  `onSaveInstanceState`/`onRestoreInstanceState` + `WebView.saveState`/
  `restoreState`; no `Renderer` seam method added. Caveat: `WebView.saveState`
  returns null (persists nothing) if the WebView has no navigable history yet;
  the shell navigates a real page on start so state exists by the time the OS
  backgrounds it. The emulator leg validates the round-trip.
- **Thread-marshalling:** unchanged from the backend — the Java controller
  marshals every `WebViewClient`/`WebChromeClient` callback onto the UI thread
  before it crosses the seam; `shouldInterceptRequest` answers synchronously on
  the binder thread (the one off-UI seam callback). The shell adds no new
  cross-thread path (the shell C-ABI's intents/lifecycle all run on the UI
  thread the Activity drives).
