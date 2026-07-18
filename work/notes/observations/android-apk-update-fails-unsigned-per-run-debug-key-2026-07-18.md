# Android release APK can't be UPDATED in place — must uninstall first (per-run debug key)

_2026-07-18 — observed installing the v0.1.0 release APK over an installed v0.0.1._

## Symptom

Installing `wezig_v0.1.0_android_debug_unsigned.apk` over an already-installed
`wezig_v0.0.1_android_debug_unsigned.apk` FAILS to update ("App not installed" /
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). Uninstalling v0.0.1 first, then installing
v0.1.0, works.

## Cause (expected, not an app bug)

Android only allows an in-place update when the new APK's **signing certificate
matches** the installed one. The release APK is built with `gradle assembleDebug`
and `mobile/android/app/build.gradle` declares **no `signingConfig`**, so Gradle
signs it with its **auto-generated debug keystore**. That keystore is created
fresh on each CI runner (ephemeral `~/.android/debug.keystore`), so every release
run signs with a DIFFERENT debug key. v0.0.1 and v0.1.0 were built on different
runs → different signatures → Android refuses the update and requires an
uninstall (which drops the old signature).

`versionCode`/`versionName` are unrelated here — the block is purely the
signature mismatch.

## Scope / where it belongs

This is INHERENT to the current unsigned / per-run-keystore approach, which is
DELIBERATE for `build-mobile-shell` (spec Out of Scope: "Code signing,
provisioning, App Store / Play Store delivery -> Slice C,
`deliver-mobile-signing-and-store`"; artifacts stay unsigned/Simulator-emulator).
So it is NOT a defect to fix in this slice.

## What Slice C should do (deliver-mobile-signing-and-store)

- Introduce a STABLE signing key (a committed-or-secret debug/release keystore,
  or a CI secret) and a `signingConfigs` block wired to the release variant, so
  successive releases share one signature and update in place (no uninstall).
- Bump `versionCode` monotonically per release (the shell currently ships a
  fixed `versionCode`/`versionName` — a real update stream needs an increasing
  `versionCode`).
- Until then, the release notes should tell testers to UNINSTALL a prior wezig
  build before installing a newer unsigned APK.

Source: hands-on install of the two GitHub Release APKs (v0.0.1 -> v0.1.0);
`mobile/android/app/build.gradle` has no signingConfig (debug auto-key).
