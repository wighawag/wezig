---
title: review-gate non-blocking nits for 'webview-hello-window' (Gate 2 approve)
date: 2026-07-15
status: open
reviewOf: webview-hello-window
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'webview-hello-window' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- No `## Decisions` block in the PR/commit body; several in-scope decisions were recorded in the observation note instead. Please ratify: (1) the `src/webkit_c.h` translate-c shim deviating from the task-specified bare @cImport(webkit/webkit.h) because that does not compile on Zig 0.16; (2) non-blank defined as not-every-pixel-identical; (3) https://example.com for interactive vs a self-contained data: page for the smoke test; (4) 1024x768 window and a 30s load timeout.
  (git log body is only the subject line; decisions live in work/notes .../webview-xvfb-provisioning-and-cimport-shim-2026-07-15.md)
- `zig build shell-test` fails today because xvfb-run is not installed on the dev box or in CI, so the automated headless assertion (AC3) does not actually run yet. The task explicitly permitted this fallback (deliver the target + note the requirement, do not fake a pass), and the note records apt-get install xvfb as the one-step fix. Confirm the provisioning follow-up is tracked so the gate goes green with no code change.
  (observation note section 1; build.zig wraps the smoke exe in xvfb-run -a with expectExitCode(0))
- Coherence nit (pre-existing, not introduced here): CONTEXT.md Naming mandates the display name live in one `app_name` constant, but branding.zig exposes `display_name` and shell.zig reads wezig.branding.display_name. This diff only consumes the existing symbol, so it is not this task's defect; flagging so the term gets reconciled when branding is next touched.
  (CONTEXT.md Naming vs src/branding.zig:19)
