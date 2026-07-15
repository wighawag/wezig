---
title: webview shell needs xvfb provisioning + a translate-c shim for @cImport(webkit.h)
date: 2026-07-15
status: open
kind: follow-up
reviewOf: webview-hello-window
---

Three things surfaced building the `webview-hello-window` tracer bullet (ADR-0005), recorded here so the follow-on build spec and CI provisioning inherit them.

## 1. `xvfb` is not provisioned (blocks `zig build shell-test`)

`zig build shell-test` wraps the smoke binary in `xvfb-run -a`, but `xvfb-run` is NOT installed on the dev box or in CI (the task's PROVISIONING note called this out). The step therefore fails today with `xvfb-run FileNotFound`. The binding, the interactive `zig build shell`, and the smoke logic itself are all verified working: with a real display present I ran the smoke binary directly and it PASSED (page load-finished fired, snapshot non-blank). Action for whoever provisions CI: `apt-get install xvfb` (Debian package `xvfb`, provides `xvfb-run`), then `zig build shell-test` goes green with no code change.

## 2. Bare `@cImport(@cInclude("webkit/webkit.h"))` does not work on Zig 0.16

The task specified binding via `@cImport(@cInclude("webkit/webkit.h"))` (+ GTK4). On Zig 0.16.0's translate-c that fails for two reasons intrinsic to the GObject/GTK headers, NOT to our code: (a) `G_DECLARE_FINAL_TYPE` puts `_Pragma("GCC diagnostic ...")` in declaration position (via `G_GNUC_*_IGNORE_DEPRECATIONS`), which translate-c cannot lower; and (b) `glib_typeof` makes `g_object_ref(x)` a result-casting macro whose discarded cast inside GLib's `g_set_object`/`g_set_weak_pointer` static-inline helpers becomes a result-typeless `@ptrCast` translate-c rejects. Resolved with a thin `src/webkit_c.h` that includes the SAME real system headers but neutralises exactly those two constructs first (empty the deprecation-pragma macros; `#undef glib_typeof`), plus two importer defines (`__GI_SCANNER__`, `GTK_COMPILATION`). Full rationale is in `src/webkit_c.h`'s header comment. This shim is the reusable entry the real `SystemWebviewRenderer` seam task should build on, not re-derive.

## 3. `spec:` path in the task body is stale (harmless drift)

`work/tasks/ready/webview-hello-window.md`'s `spec:` field text points at `work/specs/ready/explore-webview-shell.md`, but the spec actually lives at `work/specs/tasked/explore-webview-shell.md` (status = folder). The slug (`explore-webview-shell`) is correct and unambiguous, so this did not block the work; noting it in case the cross-reference is ever resolved by literal path.
