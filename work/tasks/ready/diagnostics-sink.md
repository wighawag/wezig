---
title: Diagnostics sink — structured, testable
slug: diagnostics-sink
blockedBy: [build-scaffold-green-gate]
covers: []
---

## What to build

This is a self-contained infrastructure task (no `spec`/`covers`): the structured `Diagnostics` sink that every subset boundary in v0 reports through. Story 6 (the written subset limits, `document-v0-subset-limits`) depends on it but this task covers no story on its own. A collector type with `add(severity, code, span, msg)`, a small stable `code` enum, and two severities: `warning` (the offending input was skipped and processing continued) and `error` (could not produce output at all). Callers (parse, cascade, layout — later tasks) push into it; tests assert on the collected codes; the app logs each diagnostic via `std.log`. This lands early and standalone because the parser, cascade, and layout tasks all depend on it. Include an initial set of codes the later tasks will use: `unsupported_important`, `unknown_property`, `unsupported_selector`, `non_allowlisted_element`, `unsupported_unit` (extendable).

## Acceptance criteria

- [ ] A `Diagnostics` type collects entries via `add(severity, code, span, msg)`.
- [ ] A stable `code` enum exists with the initial v0 codes; severity is `warning` | `error`.
- [ ] A source-span type (or optional span) is carried per entry so a diagnostic can point at input.
- [ ] Tests: add several diagnostics and assert the exact collected `(code, severity)` sequence.
- [ ] An app-facing helper logs collected diagnostics via `std.log` (so the app "errors" visibly while tests assert structurally).
- [ ] Tests cover the new behaviour, mirroring the repo's test style.

## Blocked by

- `build-scaffold-green-gate` (needs the build/test loop).

## Prompt

> Goal: build the one diagnostics channel every v0 subset boundary reports through, so "wezig errors visibly on unsupported input" is a TESTABLE behaviour rather than scattered `std.log` calls. Design decision (already made): a structured `Diagnostics` sink, NOT ad-hoc logging and NOT error-union returns — because unsupported-but-recoverable input must be collected (many per run) while processing continues, and tests must assert on exactly which diagnostics an input produced.
>
> Build a `Diagnostics` collector with `add(severity, code, span, msg)`; a stable `code` enum seeded with `unsupported_important`, `unknown_property`, `unsupported_selector`, `non_allowlisted_element`, `unsupported_unit` (later tasks add more); severities `warning` (skipped + continued) and `error` (no output). Carry an optional source span per entry. Provide an app helper that logs collected entries via `std.log`. Test at the sink's own seam: push a known sequence, assert the collected codes/severities exactly.
>
> Domain vocabulary: `CONTEXT.md`. This type is a dependency of the HTML-parse, CSS-cascade, and layout tasks — keep the `code` enum easy to extend. "Done" = the sink is unit-tested and ready for those tasks to push into.
>
> RECORD any non-obvious decision (span representation, whether severity is per-code or per-call) in the done record or a doc comment.
