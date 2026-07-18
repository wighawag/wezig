# mobile-verify legs — design decisions (task mobile-verification-legs-ci)

Date: 2026-07-18
Task: `mobile-verification-legs-ci` (spec `explore-mobile-shell`, Q6/story 10)

Durable record of the load-bearing-but-reversible choices made while standing up
the dedicated mobile verification CI legs. Linked from the done-record so a
reviewer / downstream task (esp. `mobile-adr-and-build-plan`, which synthesises
this) can ratify or reverse them. The workflow header comments in
`.github/workflows/mobile-verify.yml` and the "Verification legs" sections of
`mobile/{ios,android}/README.md` carry the same content at the choice site.

## What was built

`.github/workflows/mobile-verify.yml` — ONE dedicated workflow, the mobile
analogue of the desktop Xvfb `shell-*` steps in `ci.yml`. `workflow_dispatch` +
nightly `schedule` (`cron: "17 3 * * *"`), NEVER push/PR.

- **iOS leg** (`ios-simulator`, `macos-14`): runs `mobile/ios/renderer-proof.sh`
  (boot iOS 17 Simulator via `simctl`, install + launch the WKWebView proof,
  assert navigate + `.finished` seam event + non-blank `takeSnapshot`).
- **Android leg** (`android-emulator`, `ubuntu-latest`, KVM): enable KVM →
  JDK/SDK/NDK/Zig → `build-zig-libs.sh` → assemble debug + androidTest APKs →
  boot headless x86_64 emulator (API 26, `-no-window`) via
  `reactivecircus/android-emulator-runner@v2` → `gradle
  connectedDebugAndroidTest` (the instrumented `RendererSeamTest`: navigate +
  `.finished` seam event + non-blank bitmap).

Core `zig build test` gate untouched + device-free (verified green locally).

## Decisions

1. **Coherence: the iOS RUN proof MOVED out of `mobile-ios.yml` into
   `mobile-verify.yml`.** `mobile-ios.yml` previously had an `ios-renderer-proof`
   job running the SAME `renderer-proof.sh`, but on a path-filtered `push`
   trigger — i.e. on the hot path, contradicting this task's decided "nightly /
   on-demand, NOT per-push" shape (spec Q6). Two homes for one proof on
   conflicting triggers is the muddled-concept case the coherence check guards.
   Resolution: `mobile-ios.yml` / `mobile-android.yml` keep only the fast BUILD
   proofs (cross-link + launch/APK) on the hot path; the expensive RUN proofs
   live ONLY in nightly `mobile-verify`. Touches: `mobile-ios.yml` (job removed),
   `mobile-verify.yml` (new home). Alternative (duplicate the proof in both)
   rejected.

2. **`mobile-verify` is a NEW workflow, not a job in `ci.yml`.** `ci.yml` is the
   release-blocking device-free `gate` + the desktop Xvfb `webview` leg; adding a
   macOS/emulator job there would put device-dependent cost on the per-PR path.
   A separate `schedule` + `workflow_dispatch` workflow is the right layer — the
   same "dedicated leg" discipline ADR-0007 set for the desktop webview proofs,
   one tier down for mobile.

3. **Android emulator via `reactivecircus/android-emulator-runner@v2`, not
   hand-rolled `avdmanager`/`emulator`.** Spec Q6 explicitly permits "a
   maintained emulator action"; the action is the community-standard KVM-aware
   wrapper (owns AVD creation, boot-wait, adb readiness), less flaky than
   hand-rolling. An explicit KVM-enable step precedes it (GitHub's documented
   requirement for `-accel` on Linux runners). Headless opts: `-no-window
   -no-snapshot -no-audio -no-boot-anim -gpu swiftshader_indirect -accel on`.

4. **Nightly cron at a non-round minute (`17 3 * * *`).** Off-peak UTC, off the
   top-of-hour to dodge GitHub's scheduler stampede. Purely operational.
