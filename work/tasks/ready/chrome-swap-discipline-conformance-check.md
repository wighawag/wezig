---
title: Conformance check — chrome imports neither the webview binding nor GTK directly
slug: chrome-swap-discipline-conformance-check
spec: explore-webview-shell
blockedBy: [renderer-seam-and-toolkit-seam]
covers: [9]
---

## What to build

A test (or lint) that enforces the swap-cheapness discipline from ADR-0005: the CHROME module must talk ONLY to the seams, so it must import NEITHER the WebKitGTK binding NOR the GTK toolkit directly. Only the `SystemWebviewRenderer` implementation may import `webkit`, and only the GTK toolkit-seam implementation may import `gtk`. This is the same kind of machine-enforced discipline `src/docs.zig` already provides for the v0-subset doc: it fails the build if the boundary is violated, so a future direct-webkit/gtk call in the chrome is caught rather than silently eroding the swap.

Implement it in the style the repo already uses for such guards (a Zig test that inspects the chrome module's imports, or a small build-step check). It is file-orthogonal to the seam work, so it can be built independently once the seams exist.

## Acceptance criteria

- [ ] A check fails the build if the chrome module imports the WebKitGTK binding directly.
- [ ] The same check fails if the chrome module imports the GTK toolkit directly.
- [ ] The check PASSES for the current seam-respecting chrome (from `renderer-seam-and-toolkit-seam`), and would FAIL a deliberately-introduced direct import (demonstrate both directions).
- [ ] The check is wired so a violation is caught by the gate (mirroring how `src/docs.zig` guards the subset doc).
- [ ] Tests cover the new behaviour, mirroring the repo's test style; no display needed (this is a static import check).

## Blocked by

- `renderer-seam-and-toolkit-seam` (the seams + the seam-respecting chrome must exist to guard).

## Prompt

> Goal: make the "chrome talks only to the seams" discipline (ADR-0005) MACHINE-ENFORCED, so the content-backend swap and the chrome-toolkit swap stay cheap over time. Add a check that FAILS if the chrome module imports the WebKitGTK binding directly OR imports GTK directly — only `SystemWebviewRenderer` may import `webkit`, only the GTK toolkit-seam impl may import `gtk`.
>
> Model it on the existing `src/docs.zig` drift-guard (a Zig test / build-step check that fails the build on a boundary violation). Prove it both ways: it passes for the current seam-respecting chrome, and fails if a direct `webkit`/`gtk` import is introduced into the chrome. This is a STATIC import check, so it needs no display and can go in the normal gate.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0005, and the ADR from `renderer-seam-and-toolkit-seam`. This is exploration-supporting infrastructure. "Done" = the discipline is enforced by the gate and demonstrated to catch a direct import in either direction; the v0 gate stays green.
