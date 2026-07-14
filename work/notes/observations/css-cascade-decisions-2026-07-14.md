---
title: where the css-parse-and-cascade v0 decisions are recorded
date: 2026-07-14
status: open
reviewOf: css-parse-and-cascade
---

## Pointer note (discoverability for `document-v0-subset-limits`)

The non-obvious in-scope decisions this task made are recorded authoritatively in the `src/css.zig` module doc-comment header (same convention html-parse-subset used for its allowlist; see the html-parse-subset review nit about that convention gap). The `document-v0-subset-limits` task should read them there. In summary:

- **Supported property set** (each with an explicit `inherited` flag): `display` (false), `color` (true), `background-color` (false), `font-family` (true), `font-size` (true), `font-weight` (true), `width` (false), `height` (false), `margin` (false), `padding` (false). Anything else emits `unknown_property` and is ignored. Chosen to cover exactly what the block/inline layout task needs (box model + resolved font on text runs + `display`) and nothing more.
- **Values are raw trimmed strings** in v0. The cascade decides which declaration wins (origin/specificity/order) and inheritance; it does NOT parse lengths/colours. Unit/`%` interpretation and the `unsupported_unit` diagnostic are the layout task's job, which reads these computed strings. Touches: `layout-block-inline` (it consumes these strings), `document-v0-subset-limits`.
- **Specificity** = the classic (id, class, type) triple; `*` adds nothing; compounds sum their parts; descendant selectors sum across compounds; triples compare left-to-right (id, then class, then type); an exact tie falls through to source order (later wins).
- **`!important`**: a declaration carrying it emits `unsupported_important` and is DROPPED ENTIRELY (not stripped-and-kept at normal priority), so no accidental application. Considered alternative: strip `!important` and apply the value at normal priority; rejected because it silently changes which declaration wins, which is more surprising than dropping it.
- **Default `display` table** (hardcoded per element, NOT a UA cascade tier): block = `html body div p h1 h2 h3 h4 h5 h6 ul ol li`; everything else (including `span a strong em b i br`) defaults to `inline` (the CSS initial). It seeds `display` BEFORE the cascade so author/inline rules still override it.

These are also linked from the task done record via this note.
