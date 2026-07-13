---
title: Document the v0 HTML/CSS subset and its limits
slug: document-v0-subset-limits
spec: wezig-browser
blockedBy: [css-parse-and-cascade, layout-block-inline]
covers: [6]
---

## What to build

Write down, in `docs/`, exactly what v0 supports and where it stops, so "it works for v0" is unambiguous and testable. Enumerate: the HTML element/attribute allowlist (from `html-parse-subset`); the supported CSS properties and their `inherited` flags, the selector set, and the cascade limits — no `!important`, no full UA stylesheet, the hardcoded default-`display` table (from `css-parse-and-cascade`); the layout support and limits — block+inline with wrapping, box model, `px`+`%`-width, and the exclusions: no margin-collapse, no floats, static-only positioning, no flex/grid/table, no overflow-scroll (from `layout-block-inline`); and the mapping from each diagnostic `code` (`unsupported_important`, `unknown_property`, `unsupported_selector`, `non_allowlisted_element`, `unsupported_unit`, …) to the limit it represents. This is the human-and-agent reference for the v0 boundary; it should track what the code and its diagnostics actually enforce.

## Acceptance criteria

- [ ] A `docs/` file enumerates the HTML allowlist (elements + attributes) v0 accepts.
- [ ] It lists supported CSS properties (with `inherited` flags), the selector set, and cascade limits (no `!important`, no UA sheet, the default-`display` table).
- [ ] It states the layout support and every documented limit (no margin-collapse/floats/positioning/flex/grid/table/overflow-scroll; `px`+`%`-width only).
- [ ] It maps each diagnostic `code` to the limit it represents, matching the codes the parser/cascade/layout actually emit.
- [ ] The doc matches reality (spot-checked against the implemented allowlist/property set/diagnostics), not an aspirational superset.

## Blocked by

- `css-parse-and-cascade` and `layout-block-inline` (the doc records the subsets those tasks actually implement).

## Prompt

> Goal: produce the written, unambiguous statement of the v0 HTML/CSS subset and its limits (spec story 6) — the reference that makes "v0 works" testable rather than vibes. This is a documentation task; its value is that it matches REALITY, so read what `html-parse-subset`, `css-parse-and-cascade`, and `layout-block-inline` actually implemented (their done records / doc comments should carry the exact allowlist, property set, and default-`display` table) and record it faithfully.
>
> Cover: (1) the HTML element/attribute allowlist; (2) the CSS supported-property set with `inherited` flags, the selector set (type/class/id/`*`/descendant/grouping), and cascade limits (no `!important`, no full UA stylesheet, the hardcoded default-`display` table); (3) layout support (block+inline with wrapping, box model, `px`+`%`-width) and the explicit exclusions (no margin-collapse, no floats/`clear`, static-only positioning, no flex/grid/table, no overflow-scroll); (4) a table mapping each diagnostic `code` to the limit it represents. Where a limit is enforced by a diagnostic, name the code.
>
> Domain vocabulary: `CONTEXT.md`. Do NOT describe an aspirational superset — the doc is the CONTRACT for what v0 accepts, and it must line up with the diagnostics the code emits. "Done" = a reader (human or agent) can tell from this doc alone exactly what HTML/CSS v0 renders and what it rejects, and it agrees with the code.
