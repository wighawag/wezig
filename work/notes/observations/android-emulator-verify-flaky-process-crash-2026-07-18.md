# Android mobile-verify emulator leg: one flaky "Process crashed"

_2026-07-18 — observed while shepherding `mobile-verify.yml` green for the
`mobile-verify-legs-real-app` task._

The `android-emulator` job (`connectedDebugAndroidTest` on the KVM x86_64 API-26
`google_apis` emulator) failed ONCE with:

```
Starting 5 tests on emulator-5554 - 8.0.0
Finished 5 tests on emulator-5554 - 8.0.0   (~4s later)
Test run failed to complete. Instrumentation run failed due to Process crashed.
```

No per-test results, no assertion output — a hard native/process crash mid-run,
finishing in ~4s (vs the normal ~30s+). An identical-code RE-RUN passed all 5
tests clean, so this was NON-DETERMINISTIC emulator/instrumentation
infrastructure flakiness, not a code regression (the same run also hit a
transient `Could not resolve host: github.com` on the iOS checkout — a bad-runner
signal).

Hardening ideas if it recurs (NOT done here — the leg is green):
- Capture `adb logcat` (and any tombstone) on failure so a real native crash
  (e.g. a JNI `DeleteGlobalRef` double-free in the `destroy()`/`teardown`/
  `EmbedCtx`-free path, which the emulator exercises for real) is diagnosable
  rather than opaque.
- Consider `reactivecircus/android-emulator-runner`'s retry, or a small
  boot-settle, to absorb transient emulator instability.

Source: run 29651029704 (crash) vs 29651291425 (clean re-run), same HEAD fd52f7a.
