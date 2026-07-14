---
title: Diagnostics sink — structured, testable
slug: diagnostics-sink
blockedBy: [build-scaffold-green-gate]
covers: []
---

## What to build

This is a self-contained infrastructure task (no `spec`/`covers`): the structured `Diagnostics` sink that every subset boundary in v0 reports through. Story 6 (the written subset limits, `document-v0-subset-limits`) depends on it but this task covers no story on its own. A collector type with `add(severity, code, span, msg)`, a small stable `code` enum, and two severities: `warning` (the offending input was skipped and processing continued) and `error` (could not produce output at all). Callers (parse, cascade, layout — later tasks) push into it; tests assert on the collected codes; the app logs each diagnostic via `std.log`. This lands early and standalone because the parser, cascade, and layout tasks all depend on it. Include an initial set of codes the later tasks will use: `unsupported_important`, `unknown_property`, `unsupported_selector`, `non_allowlisted_element`, `unsupported_unit` (extendable).

## Acceptance criteria

- [x] A `Diagnostics` type collects entries via `add(severity, code, span, msg)` (allocator threaded per call, per 0.16.0's unmanaged `ArrayList`).
- [x] A stable `code` enum exists with the initial v0 codes; severity is `warning` | `err` (`error` is a Zig keyword, see Decisions).
- [x] A source-span type (optional `Span` = half-open `[start, end)`) is carried per entry so a diagnostic can point at input.
- [x] Tests: add several diagnostics and assert the exact collected `(code, severity)` sequence.
- [x] An app-facing helper (`logAll`) logs collected diagnostics via `std.log` (so the app "errors" visibly while tests assert structurally).
- [x] Tests cover the new behaviour, mirroring the repo's test style (7/7 pass, verify gate green).

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

## Decisions

- **Severity is PER-CALL, not per-code.** `add` takes `severity` as an argument; the same boundary can be a recoverable `warning` in one context and a fatal `err` in another, so it is not baked into `Code`.
- **Severity spelled `err`, not `error`.** `error` is a reserved keyword in Zig, so the enum variant is `Severity.err` (`warning | err`). The task wording said `error`; this is the only faithful spelling.
- **Span = optional half-open byte range `[start, end)`** (`?Span`, `Span{ start, end }`) into the input. Optional because some diagnostics have no meaningful location.
- **`msg` is borrowed, not owned.** The sink stores the `[]const u8` slice without copying; callers keep message strings alive for the sink's lifetime (v0 messages are string literals, so free).
- **Allocator threaded per call (0.16.0 unmanaged `ArrayList`).** `Diagnostics` holds `std.ArrayList(Entry)` initialised `.empty`; `add`/`deinit` take the `gpa`. This matches the 0.16.0 std API (managed `ArrayList` was removed).
- **`Code` enum is append-only.** Later parse/cascade/layout tasks ADD variants; keeping additions at the end preserves existing `@intFromEnum` values.
- **Extra helper `hasError()`** added for callers/tests that need a quick fatal check; cheap and used by the tests.

Lives in `src/diagnostics.zig`, re-exported as `wezig.diagnostics` from `src/root.zig`.
