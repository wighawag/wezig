---
title: Build scaffold — green verify gate
slug: build-scaffold-green-gate
spec: browser
blockedBy: []
covers: [5]
---

## What to build

The thinnest possible task that turns the `verify` gate green and establishes the acceptance loop. Add a `build.zig` (and `build.zig.zon`) plus a minimal library entrypoint (e.g. `src/root.zig`) exposing one trivial function, and one passing unit test wired into `zig build test`. No C dependencies, no HTML/CSS/layout/paint. When done, `zig fmt --check . && zig build && zig build test` (the `.dorfl.json` verify gate, currently red because no `build.zig` exists) passes end to end. Everything else in v0 builds on top of this.

## Acceptance criteria

- [ ] `zig build` succeeds from a clean checkout.
- [ ] `zig build test` runs and a trivial unit test passes.
- [ ] `zig fmt --check .` passes (all committed Zig is formatted).
- [ ] The full `verify` gate `zig fmt --check . && zig build && zig build test` is green.
- [ ] No C library is linked (pure Zig; the first C binding is a later task).
- [ ] Tests cover the new behaviour (the trivial function has a passing test), mirroring the repo's test style.
- [ ] Both name identifiers are defined once, each swappable by a single-line edit, and no other file hard-codes either literal (see `CONTEXT.md` § Naming): a `code_name` constant (`wezig` today) matched by `build.zig.zon`'s `.name`, and an `app_name` constant for the user-facing display name — e.g. both in `src/branding.zig`.

## Blocked by

- None — can start immediately.

## Prompt

> Goal: give wezig a working Zig build + test acceptance loop from day one. The repo is a clean-slate Zig project pinned to Zig `0.16.0` via zvm (the verify gate calls `zvm run 0.16.0 ...`, so it uses the pinned compiler regardless of the global zvm default); there is no `build.zig` yet, so the `.dorfl.json` verify gate (`zvm run 0.16.0 fmt --check . && zvm run 0.16.0 build && zvm run 0.16.0 build test`) is RED by design. Your job is to make it green with the absolute minimum: a `build.zig`, a `build.zig.zon`, a minimal library/module entrypoint with one trivial function, and one passing unit test wired into `zig build test`. Do NOT add any C dependency, HTML/CSS parsing, layout, or paint — those are separate later tasks that depend on this one.
>
> Domain vocabulary is in `CONTEXT.md`; the work contract is `work/protocol/WORK-CONTRACT.md`. Per `CONTEXT.md` § Naming there are TWO swappable name identifiers, both of which can change later: the CODE NAME (`wezig` today — `build.zig.zon`'s `.name`, matched by a `code_name` constant) and the user-facing DISPLAY NAME (an `app_name` constant). Define each once (e.g. both in `src/branding.zig`) and never hard-code either literal elsewhere, so a future rename of either is a one-line change. Keep it idiomatic for the pinned Zig version (`zvm run 0.16.0 version`; the build API changes between Zig releases, so match what `0.16.0` expects). "Done" = a fresh checkout runs the verify gate (`zvm run 0.16.0 build` and `zvm run 0.16.0 build test`) green and `zvm run 0.16.0 fmt --check .` is clean.
>
> FIRST, check this task against current reality (it is a launch snapshot and may have DRIFTED): confirm no `build.zig` exists yet and the gate is still red for the reason stated. If something already landed a build, reconcile rather than clobber.
>
> Note on `build.zig` as a shared file: later tasks register their modules and (for paint) link SDL3 in this same `build.zig`. Structure it so adding a module/dependency later is an additive edit, not a rewrite — this keeps `build.zig` from becoming a merge-conflict point if tasks are ever built off the strict linear chain.
>
> RECORD non-obvious in-scope decisions durably (module layout choice, the `build.zig` structure you adopt for this Zig version) — a short `## Decisions` note in the done record or a module doc comment is enough; reach for an ADR only if a choice is hard to reverse and surprising.
