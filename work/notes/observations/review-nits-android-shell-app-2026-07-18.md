---
title: review-gate non-blocking nits for 'android-shell-app' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: android-shell-app
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'android-shell-app' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- CMakeLists.txt comment + FATAL_ERROR message still say the Zig lib is built OUTSIDE Gradle by build-zig-libs.sh (run build-zig-libs.sh first), but decision 4 moved that into Gradles buildZigLibs task which the native build now depends on. Stale doc-drift; harmless but misleading to the next maintainer. Ratify or fix the comment.
  (mobile/android/app/src/main/cpp/CMakeLists.txt header + the missing-lib message; app/build.gradle now owns buildZigLibs and CI legs dropped the script step)
- Ratify decision 3: the instrumented ShellSeamTest constructs a SECOND WezigShellController for the restore leg, which overwrites the module-level android_shell (and shim g_shell_ctx) while the first is still alive, then tears both down. The agent flagged this as within the single-instance contract (first shells chrome goes inert once clobbered). Load-bearing only if a real app ever runs two shells; matches ios_shell/mobile_abi single-instance discipline. Confirm one-shell-at-a-time is the intended app contract for Slice A.
  (src/android_shell.zig module-level android_shell + wezig_shell_jni.c g_shell_ctx; decisions note section 3; ShellSeamTest step 4)
- Ratify decision 2: wezig_android_shell_start DIVERGES from iOS (which takes flat WkPlatform ops and builds the renderer itself) by taking the shim-owned *AndroidWebviewRenderer handle instead of re-taking the CJavaBridge, to keep the renderers global-ref lifecycle owned end-to-end by the shim. Reasonable and leak-avoiding, but a deliberate cross-platform asymmetry worth a human nod.
  (src/android_shell.zig wezig_android_shell_start; decisions note section 2)
