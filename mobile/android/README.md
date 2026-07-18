# wezig Android shell (toolchain proof)

The narrowest-real-case Android shell for the `explore-mobile-shell` exploration
(task `android-toolchain-ndk-crosslink`, spec Q2/stories 1,3): a minimal Gradle
project that cross-links the wezig Zig **static library** (including its
`stb_truetype` C dep) against the **NDK sysroot** for both ABIs, packages it into
an APK via a JNI shim, and shows one `android.webkit.WebView`.

## What this proves (and what it does NOT)

- **Proves:** the pure-Zig `wezig` core cross-compiles to `aarch64-linux-android`
  and `x86_64-linux-android`, and its `stb_truetype` C dep links once the NDK
  sysroot supplies bionic's libc headers (`math.h`, `<asm/*>`); a JNI shim loads
  the Zig core and calls a Zig `export fn`; the APK builds to an installable
  artifact and shows one WebView.
- **Floor:** Android **API 26**; ABIs **arm64-v8a** (device) + **x86_64**
  (emulator). This task's floor is: it BUILDS to an installable APK. The
  on-emulator RUN proof is delegated to the CI verification-legs task
  (`mobile-verification-legs-ci`) on a KVM Linux runner.

## The C-libc gap and how it is closed (pinned)

The pure-Zig library cross-compiles to Android with **no NDK**. The single gap is
that the `stb_truetype` C dependency needs Android/bionic libc headers from the
NDK sysroot:

- `<math.h>`, `<stdlib.h>`, … live under `<sysroot>/usr/include`.
- **arch-specific** headers (`<asm/types.h>`, reached via `<linux/types.h>`) live
  under `<sysroot>/usr/include/<triple>` (e.g. `usr/include/aarch64-linux-android`).

The Zig static lib is built with BOTH include roots wired in:

```
zig build android-lib \
  -Dmobile-target=aarch64-linux-android.26 \
  -Dmobile-sysroot="$NDK/toolchains/llvm/prebuilt/<host>/sysroot" \
  -Dmobile-sysroot-arch-include=aarch64-linux-android
```

(`.26` = the API-level floor; the arch-include is the `usr/include/<triple>`
subdir.) Both ABIs produce a `current ar archive` static lib.

## Pinned toolchain

- **NDK:** r26d (LLVM sysroot). Provisioned user-local (no root); recorded in CI
  via `android-actions/setup-android`.
- **Zig target triples:** `aarch64-linux-android.26`, `x86_64-linux-android.26`.
- **Division of labour:** Zig owns the portable core (static `.a`); the NDK/CMake
  links it into `libwezigshell.so` behind a small JNI shim; Gradle owns
  packaging (APK, `WebView` Activity).
- **compileSdk 34 / minSdk 26 / targetSdk 34**; AGP 8.5, Gradle 8.7.

## The `Renderer` backend (spec story 5) and its findings

The Android `Renderer` seam backend (`android-renderer-backend-oneshot`) is
implemented as a Zig↔Java bridge over JNI, satisfying the SAME pinned `Renderer`
interface as the desktop `SystemWebviewRenderer` (WebKitGTK):

- **Zig side** (`src/android_renderer.zig`, in the linked static core): the
  `AndroidWebviewRenderer` `Renderer` VTable. Pure Zig — imports NO `jni.h` and
  NO `android.webkit.*`, so its seam-contract tests run headlessly inside
  `zig build test` (unlike the desktop backend, which links native GTK/WebKit
  and is shell-exe-only). Down-calls go through a `JavaBridge` fn-pointer table;
  up-calls arrive at C-ABI `wezig_android_on_*` entry points.
- **Java side** (`WezigWebViewController.java`): the ONLY code that touches
  `android.webkit.*`. Drives one `WebView` + a `WebViewClient`/`WebChromeClient`
  whose load callbacks it maps to the seam's `LifecycleEvent` union.
- **JNI shim** (`wezig_renderer_jni.c`): the mechanical glue — the ONLY place
  `jni.h` meets the Zig C-ABI. Down-calls call Java `do*` methods; up-calls
  convert the jstring and forward to the Zig entry points.
- **Proof:** the local floor (backend + wiring compile, the contract holds) is
  the headless Zig tests + the full native link
  (`libwezigshell.so` = shim + Zig core links, all JNI symbols resolve). The
  real one-page proof (navigate + `.finished` seam event + non-blank bitmap) is
  the instrumented `RendererSeamTest` run on a KVM-accelerated x86_64 emulator by
  the dedicated `mobile-verify` workflow — see "Verification legs" below.

### FINDING — the thread contract (spec Q5, the KNOWN GAP)

`WebViewClient` callbacks (`onPageStarted`/`onPageFinished`/…) and
`shouldInterceptRequest` run on NON-UI (binder) threads, but the seam's
`LifecycleCallback` is single-sink and expected on one thread (the desktop
backend emits on the GTK main loop). **Resolution:** `WezigWebViewController`
marshals EVERY `WebViewClient`/`WebChromeClient` callback onto the UI thread (a
`Handler(Looper.getMainLooper())` post) BEFORE it crosses into the Zig up-call.
So the native `android_renderer.zig` performs no cross-thread work and the chrome
sees lifecycle events serialized exactly as on desktop. This is the same gap the
iOS backend does NOT have (`WKNavigationDelegate` already fires on the main
queue); it is Android-specific and load-bearing for the web3-hooks task
(`shouldInterceptRequest` marshalling for `ipfs://`).

### DECISIONS (recorded for the reviewer / downstream tasks)

- **Opaque `ViewHandle` = a JNI global ref to the `WebView`** (spec Q3), created
  in `bridge_view`. Carried opaquely across the seam exactly like the desktop
  `GtkWidget`; only the Android embedding code downcasts it. The Q3 lifetime/
  thread-affinity risk (a JNI ref is not a raw pointer) is confirmed carryable
  by the opaque contract for the navigate-one-page case; the
  embedding-proof task (`mobile-viewhandle-embedding-proof`) exercises hosting
  — CONFIRMED sufficient (see "The ViewHandle-embedding proof" below).
- **Down-calls behind a `JavaBridge` fn-pointer table** (not a hard `@extern`
  to the shim): this is what lets the backend be driven by a FAKE bridge in
  `zig build test`, mirroring `FakeRenderer`. Alternative (direct extern) was
  rejected because it would force JNI into every headless test.
- **The two web3 hooks are honest no-ops here.** `injectUserScript`/
  `setScriptMessageHandler`/`evaluateScript`/`registerScheme` satisfy the pinned
  VTable but do nothing; this task is the CONTENT-seam proof only. They are
  wired (`addJavascriptInterface`/`evaluateJavascript` + `shouldInterceptRequest`)
  by `mobile-web3-hooks-parity` (spec stories 8,9). Recorded so a reader is not
  surprised the hooks are stubs.
- **Load-event codes are a stable JNI integer enum** (`AndroidLoadEvent`,
  0=started/1=committed/2=finished/3=failed) kept in lock-step between
  `WezigWebViewController` and `android_renderer.zig`, decoupled from the seam
  enum's declaration order so the JNI boundary carries a fixed contract.

## Verification legs (which workflow runs what, and when)

Two distinct triggers, mirroring how the desktop keeps its fast gate separate
from the expensive Xvfb `shell-*` proofs (spec Q6 / ADR-0007):

- **`mobile-android` (`.github/workflows/mobile-android.yml`) — the fast BUILD
  leg, on the hot path.** `workflow_dispatch` + a path-filtered `push`. Proves
  the Zig→Android cross-link (both ABIs, NDK sysroot) and that it packages into
  an installable APK containing `libwezigshell.so`. No emulator — cheap enough
  for the hot path.
- **`mobile-verify` (`.github/workflows/mobile-verify.yml`) — the dedicated RUN
  leg, OFF the hot path.** `workflow_dispatch` + a nightly `schedule` (NOT
  per-push). Its `android-emulator` job enables KVM, cross-compiles the Zig
  libs, assembles the debug + androidTest APKs, then boots a headless
  KVM-accelerated x86_64 emulator (API 26, `-no-window`) via
  `reactivecircus/android-emulator-runner` and runs
  `gradle connectedDebugAndroidTest` — the instrumented `RendererSeamTest`
  (navigate + `.finished` seam event + non-blank bitmap). This is the Android
  analogue of the desktop Xvfb `shell-test` leg. Read a run with
  `gh run list --workflow mobile-verify.yml` → `gh run view <id> --log`.

**Why the emulator RUN lives in CI, not locally:** GitHub's Linux runners expose
`/dev/kvm`, so the x86_64 emulator is hardware-accelerated; the nested-virt-less
Hetzner dev box cannot run it. That is exactly why the emulator RUN proof was
delegated from `android-renderer-backend-oneshot` to this CI verification leg.
The core `zig build test` gate stays device-free — no emulator dependency leaks
into it.
## The ViewHandle-embedding proof (spec Q3/story 6) and its finding

The embedding proof (`mobile-viewhandle-embedding-proof`) resolves ADR-0007's
flagged cross-toolkit-embedding spike on Android — the SHARP mobile risk. It
hosts the renderer's `WebView` through the mobile chrome-surface `embedView`
seam and shows a page, driven THROUGH the seam (not a direct `addView`):

- **Zig side** (`src/mobile_chrome_surface.zig`, `MobileChromeSurface`): the
  chrome-surface half of the split `Toolkit` (ADR-0008) for the mobile host. Its
  `embedView` forwards the OPAQUE `ViewHandle` unchanged to a native embed op via
  a C-ABI `EmbedPlatform` ops table (mirroring `WkPlatform`/`CJavaBridge`). Pure
  Zig — no `jni.h`, no `android.webkit.*` — so its seam-contract tests run
  headlessly in `zig build test`.
- **JNI shim** (`wezig_embedding_jni.c`): the mechanical glue. Its `embed_view`
  op downcasts the opaque handle back to the `WebView` jobject and calls the Java
  controller's `doEmbedView`. The ONLY place the opaque handle is interpreted.
- **Java side** (`WezigEmbeddingController.java`): owns the container `ViewGroup`
  and `doEmbedView(WebView)` = `container.addView(webView)`. The only view-
  hierarchy toucher.
- **Proof:** the instrumented `EmbeddingProofTest` gets the renderer's opaque
  handle from the `Renderer` seam (`wezig_android_renderer_view`, a JNI global-
  ref), embeds it THROUGH `ChromeSurface.embedView`, and asserts the WebView
  became a child of the container AND the container draws the page non-blank.
  **Execution:** the on-emulator RUN is delegated to the KVM x86_64-emulator leg
  `mobile-verification-legs-ci` stands up (its `connectedAndroidTest` picks this
  test up automatically); this change's `mobile-android.yml` only builds the APK.
  So here Android is proven by construction + the headless Zig seam-contract
  tests + this ready-to-run instrumented test; the live-emulator confirmation
  lands with that leg (see the finding note's "Confidence status").

### FINDING — the opaque `ViewHandle` is CONFIRMED sufficient on Android (spec Q3)

The opaque `*anyopaque` contract cleanly carries the JNI global-ref across the
chrome-surface↔renderer boundary:

- **Lifetime:** the handle is a JNI GLOBAL ref (`NewGlobalRef` in `bridge_view`),
  so it survives past the JNI call that produced it and stays valid while the
  chrome holds the view — exactly what a raw-pointer handle would. The opaque
  contract need not know it is a ref: the bits are copied through untouched and
  the native side (which OWNS the ref lifetime) downcasts them. No typed-handle /
  handle-with-vtable refinement is needed.
- **Thread-affinity:** the embed itself (`ViewGroup.addView`) must run on the UI
  thread — an Android view-hierarchy constraint, NOT a seam-contract gap. It is
  the caller's responsibility (the test embeds inside `runOnMainSync`), the same
  way the desktop backend's `embedView` runs on the GTK main loop. The seam
  carries the opaque handle regardless of thread; interpretation happens on the
  thread the platform requires. So thread-affinity is a native-side rule, not a
  missing contract at `ChromeSurface.embedView`.

**Verdict:** ADR-0006's opaque `ViewHandle` is sufficient across a non-GTK
toolkit↔backend boundary on BOTH mobile platforms; ADR-0007's flagged
cross-toolkit-embedding spike is resolved (confirmed, not refined). Recorded
durably in
`work/notes/findings/viewhandle-crosses-mobile-toolkit-boundary-2026-07-18.md`
and fed back to the mobile ADR by `mobile-adr-and-build-plan`.

## Layout

- `app/src/main/cpp/wezig_jni.c` — the JNI shim: `System.loadLibrary` entry that
  calls the Zig C-ABI (`wezig_abi_version`/`wezig_greeting`) and returns the
  greeting to Java.
- `app/src/main/cpp/wezig_renderer_jni.c` — the `Renderer` backend JNI bridge
  (Zig↔Java, both directions) for the story-5 seam proof.
- `app/src/main/cpp/wezig_embedding_jni.c` — the chrome-surface embedding JNI
  bridge (spec Q3/story 6): downcasts the opaque `ViewHandle` and calls
  `doEmbedView`.
- `app/src/main/java/.../WezigEmbeddingController.java` — the Android
  chrome-surface embedding host (owns the container, implements `doEmbedView`).
- `app/src/androidTest/java/.../EmbeddingProofTest.java` — the instrumented
  ViewHandle-embedding assertion (embed via the seam + page shows non-blank).
- `app/src/main/java/.../WezigWebViewController.java` — the Android `Renderer`
  backend's Java half (the sole `android.webkit.*` toucher).
- `app/src/androidTest/java/.../RendererSeamTest.java` — the instrumented
  reference assertion (navigate + `.finished` seam event + non-blank snapshot),
  the mobile analogue of the desktop `shell-test`.
- `app/src/main/cpp/CMakeLists.txt` — links the prebuilt Zig static lib (per ABI)
  into `libwezigshell.so`.
- `app/src/main/java/dev/wighawag/wezig/MainActivity.java` — loads the lib and
  shows one `WebView` with HTML embedding the Zig greeting.
- `build-zig-libs.sh` — cross-compiles the Zig static lib for both ABIs into the
  per-ABI `jniLibs`-adjacent staging dir the CMake build reads.
- `build.gradle` / `settings.gradle` / `app/build.gradle` — the minimal Gradle
  project (NDK + CMake externalNativeBuild).
