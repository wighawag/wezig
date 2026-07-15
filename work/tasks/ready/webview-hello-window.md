---
title: WebKitGTK hello-window — one real page loads and is interactive
slug: webview-hello-window
spec: explore-webview-shell
blockedBy: []
covers: [4]
---

## What to build

The tracer bullet that proves the whole webview approach: a minimal GTK4 window embedding a `WebKitWebView` that loads one real URL and is interactive (scroll, click a link, type into a field). This is the first real WebKitGTK 6.0 binding in the project. Add the `webkitgtk-6.0` dependency to `build.zig` linked into a NEW shell executable ONLY (mirroring how SDL3 is linked into the app exe per ADR-0003) — do NOT touch the existing `sdl.zig` / v0 `main.zig` render path; the v0 SDL window and the golden tests stay exactly as they are. Add a new `zig build shell` step that launches this window. Bind WebKitGTK/GTK via `@cImport` (`<webkit/webkit.h>` + GTK4), linking the system library with `linkSystemLibrary` (this is a system dep, unlike SDL's from-source build — see the provisioning note).

Include an automated smoke test that does NOT require a physical display: run under a virtualized display (`xvfb-run`), load a page, and assert a load-finished signal fired and a `webkit_web_view_get_snapshot()` of the page is non-blank. WebKitGTK has NO native headless mode and `GtkOffscreenWindow` does not work with a WebView (WebKit bug #76911), so a virtual display (Xvfb) is the supported headless-CI approach. Keep this shell test in a SEPARATE build step (e.g. `zig build shell-test`), NOT in the truly-display-free `zig build test` gate, so the core `verify` gate stays display-free and fast.

## Acceptance criteria

- [ ] `build.zig` links `webkitgtk-6.0` (GTK4) into a NEW shell executable only; the existing `wezig` exe, `sdl.zig`, and the golden tests are untouched and still green.
- [ ] `zig build shell` opens a GTK4 window with a `WebKitWebView` that loads a real URL and is interactive (scroll, click, type verified interactively).
- [ ] A separate `zig build shell-test` runs under `xvfb-run`, loads a page, and asserts load-finished + a non-blank `webkit_web_view_get_snapshot`. It is NOT part of `zig build test`.
- [ ] The core gate (`zig fmt --check . && zig build && zig build test`) stays display-free and green (the webkit shell path is excluded from it).
- [ ] Tests cover the new behaviour, mirroring the repo's test style.

## Blocked by

None — can start immediately.

## Prompt

> Goal: prove WebKitGTK 6.0 renders one real, interactive page from Zig, as the tracer bullet for the webview-shell exploration (spec `explore-webview-shell`, ADR-0005). Decisions already made (do not re-litigate): WebKitGTK **6.0 / GTK4** is the binding (confirmed installed on the dev box as `libwebkitgtk-6.0-dev` 2.52.3; `pkg-config webkitgtk-6.0` gives `-lwebkitgtk-6.0 -lgtk-4 ...`). Link it into a NEW shell executable ONLY, like SDL3 is linked into the app exe (ADR-0003); the v0 SDL render path and the headless golden tests must be left completely untouched and still green.
>
> Bind via `@cImport(@cInclude("webkit/webkit.h"))` (+ GTK4), `linkSystemLibrary("webkitgtk-6.0")` (a SYSTEM dependency — see provisioning). Add a `zig build shell` step that opens the window. Add a SEPARATE `zig build shell-test` step that runs headless under `xvfb-run` (WebKitGTK has no native headless mode; `GtkOffscreenWindow` does not work with a WebView — WebKit bug #76911 — so Xvfb is the supported CI approach) and asserts a load-finished signal + a non-blank `webkit_web_view_get_snapshot`. Keep it OUT of `zig build test` so the core gate stays display-free.
>
> PROVISIONING: the build needs `libwebkitgtk-6.0-dev` (installed here) and the shell TEST needs `xvfb` (`xvfb-run`), which is NOT yet installed on this box or in CI — the interactive `zig build shell` works without it, but `zig build shell-test` needs it. If Xvfb is unavailable, still deliver the interactive `shell` step + the test target, and note the Xvfb requirement rather than faking a headless pass.
>
> Domain vocabulary: `CONTEXT.md`; the seam framing is ADR-0005. This is exploration: a hello-window tracer bullet, NOT a browser. "Done" = `zig build shell` shows a real interactive page, `zig build shell-test` verifies it headlessly under Xvfb, and the v0 gate is untouched and green.
