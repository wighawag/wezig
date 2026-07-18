---
title: Build the mobile shell — one real app skeleton per platform on the settled seams (iOS + Android)
slug: build-mobile-shell
humanOnly: true
needsAnswers: true
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks. (The technical-detail sections below are trimmed by `to-task` once the work is tasked — they move into tasks/ADRs and this spec settles to its durable framing: Problem / Solution / User Stories / Out of Scope.)

> **This is the FIRST mobile BUILD spec (Slice A of the `explore-mobile-shell` build plan).** It turns the per-platform exploration SPIKES into ONE real, maintainable app skeleton per platform, hosting the mobile `Renderer` + `ChromeSurface` on the settled seams — a genuine app you launch, type a URL into, and navigate, with page state surviving background/foreground. It is NOT the full mobile chrome (tabs, gestures, settings, permissions — that is Slice B, `build-mobile-chrome`) and NOT signing/store delivery (Slice C, `deliver-mobile-signing-and-store`). It inherits the exploration's proven seams, pinned toolchain, and recorded findings as FIXED POINTS (ADR-0008, ADR-0009, `docs/mobile-exploration-findings.md`) and does not re-litigate them.

<!-- open-questions -->
<!--
  TRANSIENT BLOCK — stripped by the apply rung on full resolution.
  While the spec has unresolved questions blocking autonomous tasking:
    1. Set `needsAnswers: true` in the frontmatter above.
    2. List the questions under the `## Open questions` heading below.
    3. Clear the flag (and let apply strip this block) once they are answered.
  Delete the whole fenced block — markers and all — if the spec launches fully resolved.
-->

## Open questions

These are the load-bearing decisions the exploration deliberately DEFERRED to this slice (ADR-0009 §"Must decide", `docs/mobile-exploration-findings.md` §"What every mobile build slice must DECIDE"). They are here, not silently pre-answered, because each touches the pinned `Renderer` seam or a `WezigRenderer` obligation — the wrong call is expensive to reverse. Tasking waits on these.

1. **Does the `Renderer` seam gain lifecycle methods (suspend/resume/state-restore), or is app lifecycle a HOST-ONLY concern above the seam?** Mobile OSes suspend/kill/restore the process; the shell must survive a background→foreground round-trip without losing page state. The choice: (a) add `suspend()`/`resume()`/state save-restore to the `Renderer` interface — so a future `WezigRenderer` MUST reproduce them and the behaviour is backend-identical — versus (b) keep lifecycle a host concern that drives the existing `Renderer` methods (`stop`/`navigate`/`setViewportSize`) plus native `WKWebView`/`WebView` state save-restore, leaving the seam unchanged. This must be decided BEFORE a second mobile feature depends on it, and it directly shapes what `WezigRenderer` owes on mobile. (Prefer the lightest option that keeps the seam honest; record the decision in the mobile ADR and, if (a), in an addendum to ADR-0006.)

2. **Where does Android re-inject `injectUserScript` (the document-start-injection gap)?** Android's WebView has no `WKUserScript(.atDocumentStart)` equivalent, so a provider/user script must be re-injected on EACH page start (finding `mobile-web3-hooks-parity-decisions-2026-07-18.md`). The choice: which host hook owns re-injection (`WebViewClient.onPageStarted` is the candidate) and whether that re-injection is driven from the seam (the Zig backend re-issues `injectUserScript` on the `.started` lifecycle event, keeping the injection contract seam-uniform) or is a native-side shell responsibility. This shell only injects a trivial marker script (no real provider yet — that is `explore-web3-capabilities`), but the shell's `onPageStarted` wiring is where the mechanism must land, so decide it here.

<!-- /open-questions -->

## Problem Statement

The `explore-mobile-shell` exploration proved the mobile browser is buildable on wezig's two pinned seams: minimal iOS (`WKWebView`) and Android (`android.webkit.WebView`) `Renderer` backends drove a real page, both web3 hooks round-tripped, and the opaque `ViewHandle` carried a native view across a non-GTK `ChromeSurface`↔`Renderer` boundary — all THROUGH the seams, with no signature change (ADR-0009). But every one of those proofs is a SPIKE: a hand-assembled build script (`mobile/ios/build-and-run.sh`, `mobile/android/build-zig-libs.sh` + a bare Gradle project), a single-page harness that wires the seams directly and never instantiates a real chrome, and a knowingly-leaked JNI global-ref per `view()` call that "a build must fix." There is no app a person can install, open, type a URL into, and navigate — and no maintainable project that builds the Zig core as a normal step instead of a bespoke shell script. Before the full mobile chrome (tabs/gestures/settings/permissions) or store delivery can be built, the spikes must become ONE real app skeleton per platform, on the settled seams, with the known hazards fixed.

## Solution

Build the foundation, not the whole app. Per platform, stand up a single real, maintainable project that hosts the mobile `Renderer` + `ChromeSurface` on the settled seams and gives the user a genuine (if minimal) browser:

- **Real project, not a spike script.** Replace the hand-assembled build scripts with a maintainable iOS project (Xcode/SwiftPM) and Android Gradle project that build the Zig static lib as a normal build step. The `mobile-verify` proof legs (and the release-artifact jobs) drive the REAL project, not the bespoke scripts.
- **A single-page chrome over `ChromeSurface`.** A URL field + back/forward, driven through the mobile `ChromeSurface` half of the split `Toolkit` (ADR-0008) exactly as the desktop `chrome.zig` drives `GtkToolkit` — the chrome logic stays backend-agnostic; only the native embed op interprets the opaque handle. One visible page (N-context tabs are Slice B).
- **App-lifecycle + state restoration.** Wire the `UIViewController`/`Activity` host so a background→foreground round-trip preserves page state, resolving Open Question 1 (whether the seam gains lifecycle methods or lifecycle stays host-only).
- **Fix the carried-forward hazards.** Cache ONE JNI global-ref per view and delete it on teardown (the spike's per-embed ref leak, ADR-0009 §Consequences); fix the embedding shim's `EmbedCtx` global-ref leak at teardown. Thread the iOS scheme set into each `WKWebViewConfiguration` at build time (the config-ordering finding) even though this shell registers only the trivial marker scheme.
- **Keep the proofs green.** The `mobile-verify` assertions (navigate + `.finished` + non-blank snapshot) stay green against the REAL app, and the core `zig build test` gate stays device-free (only `Fake*` seam contracts).

Everything the exploration pinned — the seams (ADR-0006/0008), the Zig-static-lib + thin-native-shell toolchain, the iOS-16/Android-26 floor, the verification strategy, the per-platform findings — is inherited as a fixed point, not re-decided.

## User Stories

1. As a wezig user on iOS, I want to install a wezig app on the iOS Simulator, open it, and see a browser with a URL field and back/forward buttons, so that wezig is a real (if minimal) mobile browser, not a demo harness.
2. As a wezig user on Android, I want to install the wezig APK on an emulator/device, open it, and see the same minimal browser, so that both platforms reach the same baseline.
3. As a user, I want to type a URL and navigate, and use back/forward, so that the single-page chrome actually browses — driven through the `ChromeSurface` seam, not a one-off native control.
4. As a user, I want the page I was on to still be there after the app goes to the background and comes back, so that switching apps doesn't lose my browsing (app-lifecycle state restoration).
5. As a user, I want the URL field to reflect the current page and the back/forward buttons to enable/disable correctly, so that the chrome mirrors the renderer's lifecycle events exactly as desktop does.
6. As a wezig maintainer, I want each platform to build from a REAL, maintainable project (Xcode/SwiftPM + Gradle) that compiles the Zig core as a normal build step, so that the mobile build is not a bespoke shell script that rots.
7. As a wezig maintainer, I want the `mobile-verify` proof legs (navigate + `.finished` + non-blank snapshot) to run against the real app, so that a regression in the real shell is caught, not just in the spike harness.
8. As a wezig maintainer, I want the Android renderer to hold ONE JNI global-ref per view (created lazily, deleted on teardown) instead of leaking one per `view()` call, so that the shell does not leak native references — the hazard the spike flagged.
9. As a wezig maintainer, I want the app lifecycle→seam mapping decided and recorded (does `Renderer` gain suspend/resume, or is lifecycle host-only?), so that a future `WezigRenderer` on mobile knows exactly what it must reproduce.
10. As a wezig maintainer, I want the Android `injectUserScript` re-injection point wired (via `onPageStarted`), so that `explore-web3-capabilities`'s provider injection on Android has a proven mechanism to build on — even though this shell only injects a trivial marker script.
11. As a wezig maintainer, I want the core `zig build test` gate to stay device-free and the desktop `chrome_conformance` guard to stay green, so that the mobile foundation adds no coupling into the display-free gate or the chrome's binding-free discipline.
12. As a wezig maintainer, I want the mobile artifact release jobs (`android-apk`, `ios-simulator-app`) to build from the REAL project rather than the spike scripts, so that the downloadable artifacts track the maintained app.

### Autonomy notes (the two gate axes — set the frontmatter flags accordingly)

- **`humanOnly: true` (DECIDED).** A human must drive the TASKING of this spec. Rationale: this is the first BUILD slice, and its 3-way slicing (`build-mobile-shell` → `build-mobile-chrome` → `deliver-mobile-signing-and-store`) is a PROPOSAL the human authoring the follow-on specs adopts and may re-cut (ADR-0009 §"Decisions recorded"); the boundary between this slice and Slice B/C is a human call, not an auto-task. (This does NOT propagate to the tasks' gates — the tasker sets each task's gate from its own build-nature; the per-platform shell tasks are expected to be normal agent-buildable tasks.)
- **`needsAnswers: true` (DISCOVERED).** The two Open Questions above (lifecycle→seam mapping; Android re-injection point) block autonomous tasking until answered. They are genuine design decisions the exploration deferred, not gaps an agent should guess; each shapes the `Renderer` seam or a `WezigRenderer` obligation. Answer them (in this body), clear the flag, then task.

## Implementation Decisions

Inherited fixed points (do NOT re-derive — see ADR-0008, ADR-0009, `docs/mobile-exploration-findings.md`):

- **Seams:** the split `Toolkit` (ADR-0008) — mobile implements `ChromeSurface` only (`embedView`/`setUrlText`/`setBackEnabled`/`setForwardEnabled`/`setChromeCallback`); the OS is the host/loop. The `Renderer` seam (ADR-0005/0006) is unchanged except possibly by Open Question 1. `src/chrome.zig` stays unchanged; `chrome_conformance` stays green.
- **Toolchain:** Zig STATIC LIBRARY + thin native shell per platform. iOS: `aarch64-ios` / `aarch64-ios-simulator`, Swift↔Zig over the C-ABI header. Android: `aarch64-linux-android` / `x86_64-linux-android` via the NDK sysroot, JNI shim. Floor: iOS 16.0, Android API 26; ABIs arm64 + x86_64. The mobile lib builds ReleaseSafe + strip (the debug-symbolication/stack-check link constraints, ADR-0009 / the `mobile` build fixes).
- **The native backends are the sole `android.webkit.*` / `WKWebView` touchers** (`src/android_renderer.zig`, `src/ios_webview_renderer.zig`, `src/mobile_chrome_surface.zig`); the chrome logic reaches only the seams.
- **The per-platform findings the shell must honour:** iOS `WKURLSchemeHandler` config-ordering (install the scheme set on the config BEFORE the webview is created); Android non-UI-thread callbacks (marshal load/bridge callbacks to the UI thread; `shouldInterceptRequest` answers synchronously on the binder thread and must be thread-safe); Android custom-scheme opaque-origin trait (relevant to a later `ipfs://`, NOT this shell — no real scheme content here); the embed op runs on the UI thread.

New for this slice (seed for tasking, trimmed at tasking-time):

- **Real projects replace the spike scripts.** An Xcode/SwiftPM project and a Gradle project (extending the existing `mobile/android` skeleton into a real app module) that build the Zig lib as a normal build phase/task. The `mobile-verify` legs and the release jobs point at these.
- **Single-page chrome.** The mobile shell instantiates a real chrome loop over `ChromeSurface` (a Zig `MobileChrome`, the mobile analogue of `chrome.zig`, OR `chrome.zig` reused with the host-loop half absent — decide at tasking whether the shared `Chrome` can be driven host-loop-free). URL field + back/forward + URL-bar/button reflection from `Renderer` lifecycle events.
- **Lifecycle wiring** per the resolved Open Question 1.
- **JNI global-ref lifecycle:** one ref per view, cached lazily, deleted on teardown; `EmbedCtx` ref freed on teardown.

## Testing Decisions

- **The `mobile-verify` assertions carry over to the REAL app:** navigate + a `.finished` lifecycle event reaching a seam subscriber + a non-blank snapshot, now driven from the maintained project (iOS Simulator via `simctl`; Android via a KVM emulator `connectedAndroidTest`).
- **A NEW lifecycle assertion:** a background→foreground round-trip preserves page state (the URL/page after resume equals before) — the story-4 bar.
- **Seam-contract tests stay headless in `zig build test`** (the `Fake*`/`MobileChromeSurface` contracts); no device dependency leaks into the core gate.
- **Leak checks:** an assertion (instrumented or via a native-side counter) that the Android renderer holds exactly one global-ref per live view and none after teardown.
- Prior art: the desktop `shell-test`/`shell-bridge-test`/`shell-scheme-test` legs and the existing mobile spike proofs (`RendererProof`/`RendererSeamTest`, `EmbeddingProof`/`EmbeddingProofTest`) are the shape to mirror.

## Out of Scope

Deliberately NOT in this slice (each lives in a named follow-on):

- **Full mobile chrome — tabs, gestures (back-swipe, pull-to-refresh), settings, permissions UX** → Slice B, `build-mobile-chrome` (the N-`PageContext` presentation model, ADR-0007).
- **Code signing, provisioning, App Store / Play Store delivery** → Slice C, `deliver-mobile-signing-and-store`. This shell stays Simulator/unsigned-debug, exactly as the exploration and the current release artifacts do.
- **The web3 provider + `ipfs://` on mobile** → `explore-web3-capabilities`'s follow-on, which inherits the cross-platform-validated hook contract + the Android non-secure-origin / non-document-start-injection gaps (ADR-0009 §3). This shell injects only a trivial marker script and registers only the trivial marker scheme.
- **`WezigRenderer` on mobile** → downstream of `explore-native-renderer`; when it lands it satisfies the SAME `Renderer` seam these backends do (and whatever Open Question 1 resolves).
- **macOS/Windows DESKTOP targets** → unrelated (goreleaser matrix), tracked in `.goreleaser.yaml`.

## Further Notes

- **Cross-references:** ADR-0008 (Toolkit split), ADR-0009 (mobile exploration outcome), `docs/mobile-exploration-findings.md` §6 (the build plan this slice realises), and the findings under `work/notes/findings/` (`viewhandle-crosses-mobile-toolkit-boundary`, `ios-wkurlschemehandler-registration-ordering`, `android-webviewclient-nonui-thread-marshalling`, `android-custom-scheme-nonui-thread-and-opaque-origin`, `mobile-web3-hooks-parity-decisions`). The load-bearing decisions this slice makes (esp. Open Question 1) should land in a new ADR (or an addendum to ADR-0006 if the seam gains lifecycle methods).
- **Slicing is a proposal.** ADR-0009 flags the 3-way split as a human-ratified proposal; the human tasking this spec may re-cut the Slice A/B boundary (e.g. pull a single gesture forward, or push lifecycle to B). This spec captures the boundary as the plan drew it; adjust at tasking if warranted.
- **The parity framing.** "Parity with desktop" for THIS slice means: a real app that browses one page through the same seams with the URL-bar/back-forward chrome reflecting lifecycle events — the mobile equivalent of the desktop `shell` app. Full feature parity (tabs, web3, native renderer) is explicitly downstream.
