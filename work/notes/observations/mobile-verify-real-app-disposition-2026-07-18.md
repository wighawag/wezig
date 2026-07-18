# mobile-verify legs → real apps: per-proof disposition (task mobile-verify-legs-real-app)

Date: 2026-07-18
Task: `mobile-verify-legs-real-app` (spec `build-mobile-shell`, stories 7/11)

Durable record of the load-bearing-but-reversible disposition chosen for each
mobile seam proof when repointing the `mobile-verify` legs from the spike
scripts to the REAL platform apps. Linked from the done record so a reviewer /
human can ratify or reverse. None is hard-to-reverse enough to STOP on; each is
a choice a reviewer might be surprised was decided in-flight.

## Starting state (what the blocking tasks already landed)

- `ios-shell-xcode-project` built the real Xcode app (`mobile/ios/App/…`) and
  ADDED an `ios-shell` job + `mobile/ios/shell-verify.sh` + `ShellVerify.swift`
  that already folds the **renderer RUN proof + the NEW story-4
  background→foreground state-restoration assertion** into the real app
  (navigate + `.finished` reaching the chrome + non-blank snapshot + page
  survives bg/fg). But it left the spike `*-proof.sh` + `Sources/*Proof.swift`
  and their `mobile-verify` jobs (`ios-simulator`, `ios-embedding-proof`,
  `ios-bridge-proof`, `ios-scheme-proof`) in place, as a parallel hand-assembled
  (`swiftc`) proof path.
- `android-shell-app` built the real Android app **module** whose instrumented
  test target already carries `ShellSeamTest` (renderer + bg/fg restoration) plus
  `RendererSeamTest` / `EmbeddingProofTest` / `BridgeSeamTest` / `SchemeSeamTest`,
  all driving the REAL renderer/embedding controllers (`WezigWebViewController` /
  `WezigEmbeddingController` in the app module's `main/java`), compiled by the
  real Gradle build against the real Zig lib and run by `connectedDebugAndroidTest`.
  So on Android every seam proof is ALREADY a test in the real app's test target.

## Per-proof disposition

### iOS
- **renderer + state-restoration → FOLDED into the real app** (already, via
  `ShellVerify.swift` under `--wezig-verify`, driven by the `ios-shell` job).
  The old `ios-simulator` job ran `renderer-proof.sh` against a hand-assembled
  `RendererProof.swift` binary — a **dead duplicate** of the real-app renderer
  RUN proof. REMOVED. The renderer RUN proof now lives ONLY in the real-app
  `ios-shell` job (renamed conceptually to be THE iOS renderer leg).
- **embedding, bridge, scheme → FOLDED into the real app's XCTest target**
  (`WezigShellTests`, a `com.apple.product-type.bundle.unit-test` bundle added to
  `WezigShell.xcodeproj` with `TEST_HOST` = the WezigShell app). Each is an
  XCTest case (`EmbeddingProofTests` / `BridgeProofTests` / `SchemeProofTests`)
  that drives the SAME already-exported proof C-ABI entry points the spike Swift
  drove (`wezig_ios_embed_proof_*`, `wezig_ios_bridge_proof_*`,
  `wezig_ios_scheme_proof_*` — all already compiled into the real
  `libwezig_mobile.a` the app links), but now compiled + linked by the REAL
  Xcode project (its "Build Zig static lib" phase) and run via `xcodebuild test`.
  The standalone `*-proof.sh` + `Sources/{Embedding,Bridge,Scheme}Proof.swift`
  are DELETED. WHY XCTest rather than 3 more app targets: it is the exact Android
  precedent (proofs as instrumented tests in the real app's test target), one
  build of the Zig core, one host app, no parallel hand-assembled binary.
  ALTERNATIVE considered: repoint each `*-proof.sh` to `xcodebuild` a per-proof
  app target — rejected: 3 extra app targets duplicate the app scaffold vs one
  test bundle, and diverges from the Android shape.

### Android
- **renderer + state-restoration, embedding, bridge, scheme → ALREADY FOLDED**
  into the real app module's instrumented-test target by `android-shell-app` /
  the backend tasks. The `android-emulator` job runs `connectedDebugAndroidTest`,
  which runs ALL of them (`ShellSeamTest` + the four `*SeamTest`/`*ProofTest`s)
  against the real APK. No Android spike script remains (only
  `build-zig-libs.sh`, a manual convenience mirror of the Gradle `buildZigLibs`
  task — kept, per the `android-shell-app` decision note, not a CI proof path).
  Nothing to repoint; the job already builds + installs the REAL app module APK.

## Net workflow shape after this task

- `mobile-verify.yml`: iOS = `ios-shell` (real app, renderer+finished+non-blank+
  state-restoration) + `ios-seam-proofs` (real app XCTest: embedding+bridge+
  scheme). Android = `android-emulator` (real APK `connectedDebugAndroidTest`,
  all seam proofs + state-restoration). No spike-script job remains.
- `mobile-ios.yml` / `mobile-android.yml`: fast BUILD legs already build the real
  projects (`build-and-run.sh` drives the real `.xcodeproj`; Gradle builds the
  real module) — left as-is, verified they no longer touch spike scripts.
- Core `zig build test` gate: unchanged, device-free (ci.yml never references
  mobile).

## Files removed (dead spike proof paths)

`mobile/ios/renderer-proof.sh`, `bridge-proof.sh`, `scheme-proof.sh`,
`embedding-proof.sh`; `mobile/ios/Sources/{Renderer,Bridge,Scheme,Embedding}Proof.swift`.
`build-and-run.sh` is KEPT (it already builds the REAL project and is the fast
iOS BUILD leg + release packaging path). `mobile/ios/Info.plist` is KEPT (still
used by `build-and-run.sh`? — checked: no; the real app uses `App/Info.plist`.
Info.plist at `mobile/ios/Info.plist` was the shared PROOF plist only → removed).

The bespoke proof C-ABI entry points in `mobile_abi.zig` /
`mobile_chrome_surface.zig` are KEPT: they are the seam-contract surface the
XCTest cases now drive against the real app, still retained/emitted into the
real `libwezig_mobile.a` and still covered by the headless `zig build test`
seam-contract tests. Removing them would delete the very assertions the folded
proofs run.
