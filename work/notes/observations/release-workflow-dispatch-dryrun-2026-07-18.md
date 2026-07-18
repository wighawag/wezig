# release.yml: workflow_dispatch dry-run mode for the mobile artifacts (2026-07-18)

Task `mobile-release-artifacts-real-app` (spec `build-mobile-shell`, story 12).

## What was found

By the time this task ran, the mobile release jobs' BUILD invocations already
resolved to the REAL apps: `android-shell-app` had swapped `mobile/android` for
the real app module (and removed the out-of-band `build-zig-libs.sh` release
step, folding it into the `buildZigLibs` Gradle task), and
`ios-shell-xcode-project` had rewritten `mobile/ios/build-and-run.sh` to drive
the real `WezigShell.xcodeproj`. So `gradle assembleDebug` and
`build-and-run.sh BUILD_ONLY=1` already built the maintained shells. What was
still spike-shaped was (a) the release.yml comments/labels (they described the
spike path) and (b) there was NO way to dry-run the workflow — it only triggered
`on: push: tags: v*`.

## Decision recorded (a user-visible workflow trigger + upload path — DESIGN, not a factual gap)

Added `workflow_dispatch` to `release.yml` so the mobile artifacts can be built +
verified WITHOUT publishing a release (the acceptance criterion's
"dry-run/`workflow_dispatch` equivalent"). The chosen shape:

- **goreleaser** runs `release --clean` on a tag (unchanged, byte-for-byte) and
  `release --snapshot --clean` on a dispatch (builds locally, publishes nothing)
  so the desktop path stays green + the mobile jobs' `needs: goreleaser` gate is
  still satisfied on a dispatch. The desktop release job is therefore UNAFFECTED
  on the tag path.
- **Each mobile job** builds the real-app artifact, then a validate step asserts
  it is a valid package (APK carries `libwezigshell.so` for both ABIs; the iOS
  zip carries `WezigShell.app`'s `Info.plist` + binary — mirroring the
  `mobile-android.yml` BUILD-leg check), then uploads it:
  - on a **tag** → `gh release upload` (attach to the release — unchanged intent);
  - on a **dispatch** → `actions/upload-artifact` (a downloadable workflow
    artifact), so the dry-run proves a valid downloadable package end-to-end.

**Alternative considered:** verify ONLY by cutting a real test tag (the
pre-existing `on: push: tags` path already supports this) and add no dispatch
mode. Rejected because the acceptance criterion explicitly offers the
`workflow_dispatch` equivalent, and a dry-run that publishes nothing is safer to
run repeatedly than pushing throwaway `v*` tags (each of which would cut a real
GitHub Release + changelog).

**What it touches:** the `release` workflow's trigger surface and the goreleaser
step (now split tag/snapshot). It does not touch `.goreleaser.yaml`, the desktop
archives, or any other workflow.

## Verification boundary (NOT executed here)

The end-to-end CI RUN (dispatch or test tag) could not be executed from the build
sandbox: it needs the change on a GitHub branch first (the runner owns the
commit/push — this task must not do git ops), plus macOS + Android SDK runners.
Local verification done instead: the repo gate is green (`zig fmt --check` +
`zig build` + `zig build test`), the YAML parses with all three jobs + both
triggers intact, and the two package-validation greps were checked against
realistic `unzip -l` listings. The live dispatch run should be triggered after
integration via the Actions tab / `gh workflow run release.yml`, then read with
`gh run view <id> --log` and `gh run download <id>`.
