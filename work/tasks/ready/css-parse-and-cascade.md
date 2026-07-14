---
title: CSS parse + cascade — computed styles on the DOM
slug: css-parse-and-cascade
spec: browser
blockedBy: [html-parse-subset]
covers: [2]
---

## What to build

Parse the fixed CSS subset and cascade it onto the DOM so nodes have computed styles. The CSS parser has TWO entry points: `parseStylesheet(text)` (for `<style>` blocks, and external CSS later) and `parseDeclarationList(text)` (for `style=""`). Selectors are matched through a `Selector`-AST + matcher supporting the v0 set: type, `.class`, `#id`, universal `*`, the descendant combinator, and grouping (`a, b`) — everything else emits `unsupported_selector` and the rule is skipped. The cascade is the REAL algorithm on a small property set: order by origin tier (inline `style=""` wins over author `<style>` rules) → selector specificity (the id/class/type triple) → source order; apply inheritance (each supported property declares `inherited: bool`); fill unset properties from initial values; and seed each element's default `display` from a hardcoded per-element table (no full UA stylesheet). `!important` emits `unsupported_important` (and is ignored); unknown properties emit `unknown_property`. Output: computed styles attached to DOM nodes.

## Acceptance criteria

- [ ] `parseStylesheet(text)` and `parseDeclarationList(text)` both exist and are used for `<style>` and `style=""` respectively.
- [ ] A `Selector` AST + matcher supports type / class / id / `*` / descendant / grouping, behind a seam that admits new selector kinds later; unsupported selectors emit `unsupported_selector` and skip the rule.
- [ ] Cascade orders by origin tier → specificity → source order; inline `style=""` beats author `<style>` rules.
- [ ] Inheritance works (per-property `inherited` flag); unset properties take initial values; each element gets a default `display` from a hardcoded table.
- [ ] `!important` → `unsupported_important` (ignored); unknown property → `unknown_property`.
- [ ] Tests: given HTML+CSS fixtures, assert computed styles on target nodes AND the collected diagnostic codes.
- [ ] Tests cover the new behaviour, mirroring the repo's test style.

## Blocked by

- `html-parse-subset` (needs the DOM, its parent pointers, and the captured `<style>`/`style=""` text).

## Prompt

> Goal: give DOM nodes computed styles by parsing the fixed CSS subset and running the real cascade. Decisions already made (do not re-litigate): (1) TWO parser entry points — `parseStylesheet(text)` for `<style>`/external, `parseDeclarationList(text)` for `style=""`. (2) Selector subset = type / `.class` / `#id` / `*` / descendant combinator / grouping, behind a `Selector`-AST seam so child/sibling/attribute/pseudo selectors are additive later; unsupported selectors → `unsupported_selector`, rule skipped. (3) The cascade is the REAL algorithm, small property set: origin tier (inline `style=""` > author `<style>`) → specificity (id/class/type triple, compared left-to-right) → source order; plus inheritance (each property carries `inherited: bool`), initial values for unset, and a HARDCODED per-element default `display` table (NOT a full UA stylesheet cascade tier). (4) v0 has NO `!important` (emit `unsupported_important`, ignore) and unknown properties emit `unknown_property`.
>
> Matching the descendant combinator requires walking ancestors — the DOM's parent pointers (from `html-parse-subset`) support this. Push all boundary diagnostics through the `Diagnostics` sink. Test at the computed-style seam: given an HTML+CSS fixture, assert the computed styles on specific nodes AND the collected diagnostic codes — prefer this over asserting internal parser structures.
>
> Domain vocabulary (CSS cascade, computed/inherited values, specificity): `CONTEXT.md`. Keep the supported-property set small and each property's `inherited` flag explicit — the `document-v0-subset-limits` task reads this to write the limits doc. NOTE: reusing the `zss` project for CSS/layout is a DEFERRED evaluation, NOT part of this task — build the thin v0 subset in-house behind the seam. "Done" = fixtures produce correct computed styles + expected diagnostics.
>
> RECORD non-obvious in-scope decisions (the exact supported-property set, specificity tie-break details, the default-`display` table) durably and linked from the done record — they feed the limits doc.
