---
title: review-gate non-blocking nits for 'mobile-verification-legs-ci' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: mobile-verification-legs-ci
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'mobile-verification-legs-ci' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: the iOS RUN proof (renderer-proof.sh) was MOVED out of mobile-ios.yml (job ios-renderer-proof removed) into the new nightly mobile-verify.yml, changing mobile-ios.yml behaviour (it now runs only the fast BUILD/launch proof on the hot path). Cross-task interaction, correctly recorded in the decisions note. Coherent and reversible.
  (git diff mobile-ios.yml removes ios-renderer-proof; decisions note item 1. No dangling refs to ios-renderer-proof remain.)
- Ratify: Android emulator uses reactivecircus/android-emulator-runner@v2 rather than hand-rolled avdmanager/emulator. Task What-to-build names avdmanager/emulator; the Prompt + spec Q6 explicitly permit a maintained emulator action, so this is in-scope. Note item 3 records it.
  (mobile-verify.yml android-emulator step; spec Q6 line 21 permits it via the Prompt allowance.)
- emulator-options carries -accel on and force-avd-creation:false, which are slightly non-idiomatic for android-emulator-runner (it manages accel/AVD itself). Low impact, self-correcting when the nightly leg first runs; not blocking.
  (mobile-verify.yml:144-145)
