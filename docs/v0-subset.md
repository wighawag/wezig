# The wezig v0 HTML/CSS subset and its limits

This is the written CONTRACT for what `wezig` v0 renders and what it rejects (spec `browser`, story 6). v0 is a deliberately small, fixed subset: enough HTML structure and CSS to exercise block/inline layout and paint a real page fragment to a window, and nothing more. Anything outside the subset is either reported through the structured `Diagnostics` sink and skipped, or silently dropped, as noted per case below.

The doc is the reference that makes "v0 works" testable rather than vibes: a reader (human or agent) should be able to tell from this file alone exactly what HTML/CSS v0 accepts and what it does not. It tracks REALITY, so it lists what the code actually enforces (`src/html.zig`, `src/css.zig`, `src/layout.zig`, `src/diagnostics.zig`). A test guard (`src/docs.zig`) keeps this doc from silently drifting from the code: it fails if the allowlist, supported-property set, default-`display` table, or diagnostic-code set grows without this doc being updated.

This is NOT an aspirational superset. Where a limit is enforced by a diagnostic, the diagnostic `code` is named. See the [diagnostic-code map](#diagnostic-code-map) at the end for the full code-to-limit table.

## How v0 reports the boundary

Every subset boundary in v0 reports through one structured `Diagnostics` sink (`src/diagnostics.zig`), not scattered logging. Each entry carries a stable `code`, a severity (`warning` = the offending input was skipped and processing continued; `err` = could not produce output at all), an optional source `span`, and a borrowed human-readable message. In v0 every subset-boundary diagnostic is a `warning`: the offending piece is skipped and rendering continues. Tests assert on the exact collected `code` sequence; the app surfaces them via `std.log`.

## 1. HTML: the element + attribute allowlist

v0's HTML parser is NOT a WHATWG-conformant parser. The subset is an explicit element/attribute allowlist (the policy lives in the tree builder); anything outside it is reported or dropped, never "handled".

### Allowlisted elements

Only these element tag names are accepted (ASCII, case-insensitive):

| Group | Elements |
| --- | --- |
| Document structure | `html`, `head`, `body` |
| Stylesheet | `style` |
| Block containers / text blocks | `div`, `p` |
| Headings | `h1`, `h2`, `h3`, `h4`, `h5`, `h6` |
| Lists | `ul`, `ol`, `li` |
| Inline | `span`, `a`, `strong`, `em`, `b`, `i` |
| Line break (void) | `br` |

`br` is the only void element in v0: it has no end tag and no children. `style` is the only raw-text element: the tokenizer reads its content verbatim (so CSS punctuation such as `{`, `}`, `:` inside a stylesheet is not misread as HTML).

Any element NOT in this list is out of the v0 subset. A non-allowlisted element emits `non_allowlisted_element` (severity `warning`) and is SKIPPED: the element itself never appears in the DOM, but its allowlisted descendants are still parsed and re-parented to the skipped element's parent. Parsing continues. This covers, among others, `script`, `img`, `table`, `form`, `input`, `svg`, `canvas`, and any custom/unknown tag.

### Allowlisted attributes

| Attribute | Allowed on |
| --- | --- |
| `id` | any allowlisted element |
| `class` | any allowlisted element |
| `style` | any allowlisted element |
| `href` | `a` only |

`id`, `class`, and `style` are the global attributes; `href` is allowed on `a` only (a `href` on any other element is dropped). Both the `<style>` block's text content and the `style=""` attribute value are captured onto the DOM here; their CSS is parsed and cascaded by the CSS stage (section 2), not by the HTML parser.

Any attribute NOT in this list (for example `onclick`, `src`, `width`, `data-*`, `href` on a non-`a` element) is SILENTLY DROPPED in v0. Non-allowlisted attributes have **no diagnostic code** in v0: they are not element boundaries, and no `code` is emitted for them. A later task may add one.

### Not part of the v0 DOM

- Comments (`<!-- ... -->`) are tokenized but are not part of the DOM.
- Doctype and other bogus `<! ... >` declarations are consumed and dropped.
- Character-reference/entity decoding (`&amp;` etc.) is not performed in v0; text is captured verbatim.

## 2. CSS: supported properties, selectors, and cascade limits

v0's CSS engine is NOT a CSS-conformant engine, but the cascade it runs on the supported subset is the REAL algorithm (origin tier -> specificity -> source order, plus inheritance and initial values). There are two parser entry points sharing one declaration parser: `parseStylesheet` for `<style>` blocks (a list of `selectors { declarations }` rules) and `parseDeclarationList` for the `style=""` attribute (a bare declaration list).

### Supported properties (with `inherited` flags)

Exactly these ten properties are supported. Each carries an explicit `inherited` flag and a CSS initial value:

| Property | `inherited` | Initial value |
| --- | --- | --- |
| `display` | no | `inline` (but seeded per element by the default-`display` table, below) |
| `color` | yes | `black` |
| `background-color` [^box-colour] | no | `transparent` |
| `font-family` | yes | `serif` |
| `font-size` | yes | `16px` |
| `font-weight` | yes | `normal` |
| `width` | no | `auto` |
| `height` | no | `auto` |
| `margin` | no | `0` |
| `padding` | no | `0` |

Any other property name (e.g. `border`, `border-width`, `display: flex`'s peers, `position`, `float`, `overflow`, `text-align`, `line-height`, `background-image`) emits `unknown_property` (severity `warning`) and that declaration is ignored.

Values are carried through the cascade as RAW trimmed strings. The cascade resolves WHICH declaration wins and inheritance; it does not parse lengths, colours, or units. Length/unit interpretation (and the `unsupported_unit` diagnostic) happens in layout (section 3), which reads these computed strings.

Note: `margin` and `padding` are the box-model shorthands; there are no per-side longhands (`margin-top`, `padding-left`, ...) in the supported-property set, and there is no `border-width` property, so borders are 0 in v0 (the box model reserves the field for later).

[^box-colour]: **`background-color` is parsed and cascaded, but NOT painted from the cascade in v0** (and the same holds for `color` as a BOX fill). The painter draws only TEXT from computed styles; block / inline / anonymous boxes are left transparent (`src/paint.zig`, `paintBox`). A real `<div style="background-color: red">` does NOT paint red from the cascade alone in v0. Box background and border colours must be supplied above the paint seam (`PaintStyle` / the golden fixtures); they are not yet resolved from computed styles end-to-end. See the layout exclusion in section 3.

### Supported selectors

The `Selector`-AST matcher supports exactly this set (everything else is rejected):

| Selector kind | Example |
| --- | --- |
| Type (tag name) | `div` |
| Class | `.box` |
| Id | `#main` |
| Universal | `*` |
| Descendant combinator (whitespace) | `.box p` |
| Grouping (selector list) | `h1, .box p` |
| Compound (of the above, no combinator between) | `div.box#main` |

Any other selector syntax is unsupported and emits `unsupported_selector` (severity `warning`); that selector is dropped. This includes the child (`>`), adjacent-sibling (`+`), and general-sibling (`~`) combinators, attribute selectors (`[href]`), and pseudo-classes/elements (`:hover`, `::before`). In a grouping (`a, b`), each member is judged independently: an unsupported member is dropped with a diagnostic while supported members still apply; a rule whose selectors are ALL unsupported is skipped entirely.

### Cascade and its limits

The cascade is the real algorithm on the supported property set:

1. **Origin tier.** Inline `style=""` beats author `<style>` rules. There is no user-agent stylesheet tier and no user tier in v0.
2. **Specificity.** The classic `(id, class, type)` triple, compared left-to-right. `#id` adds to id, `.class` to class, a type name to type, `*` adds nothing; a compound sums its parts and a descendant selector sums across its compounds.
3. **Source order.** On an exact specificity tie, the later declaration wins.

Then inheritance (each property's `inherited` flag, above), then initial values for anything still unset.

Cascade limits, explicitly:

- **No `!important`.** A declaration carrying `!important` emits `unsupported_important` (severity `warning`) and the WHOLE declaration is dropped (the `!important` marker is not stripped and re-applied at normal priority, so it never accidentally wins).
- **No full UA stylesheet.** There is no user-agent stylesheet cascade tier. The one piece of UA-like default behaviour is the hardcoded default-`display` table below, which merely SEEDS each element's `display` before the cascade runs (so an author rule or inline style still overrides it normally). It is not a cascade tier.

### The hardcoded default-`display` table

Before the cascade runs, each element's `display` is seeded from this fixed per-element table (NOT a UA cascade tier):

| Default `display` | Elements |
| --- | --- |
| `block` | `html`, `body`, `div`, `p`, `h1`, `h2`, `h3`, `h4`, `h5`, `h6`, `ul`, `ol`, `li` |
| `inline` | `span`, `a`, `strong`, `em`, `b`, `i`, `br`, and any element not listed as block |

An author rule or inline `style` can override the seeded `display` normally. Any element not in the block list defaults to `inline` (the CSS initial for `display`).

## 3. Layout: block + inline flow, box model, units, and exclusions

v0's layout turns the styled DOM into a box tree with real positions and sizes. It is a thin, deliberately-throwaway implementation behind the `PaintBackend` seam.

### What layout supports

- **Block flow.** Block-level boxes stack vertically, each filling its containing block's content width unless `width` says otherwise.
- **Inline flow with wrapping.** Text and inline boxes flow into line boxes and WRAP at the containing block's content width. Line boxes are baseline-aligned (a line's height is `max(ascent) + max(descent)` over its runs). A `<br>` forces a line break. Whitespace-only text between block boxes is collapsed away (generates no box).
- **The full box model.** Content, padding, border, and margin edges are all honoured, plus `width` and `height`. (Border WIDTHS are 0 in v0 because there is no `border-width` property; the edges exist in the box model for later. Box background and border COLOURS are not painted from the cascade either; see the exclusion below.)
- **Text runs carry their resolved font.** A text run crossing the paint seam carries its resolved `Font` (family / size / weight) from the cascade's computed styles; shaping and measurement live below the seam, and layout never re-resolves font properties.

### Supported units

- **`px`** (and a bare unitless number, treated as `px` in v0) for any length.
- **`%`** for `width` only, resolved against the containing block's content width.

Any other unit (`em`, `rem`, `vw`, `vh`, `ch`, `pt`, ...), and a `%` used where v0 does not support it (see below), emits `unsupported_unit` (severity `warning`) and falls back:

- a length falls back to `auto` (for `width`) or `0` (for `height`, `margin`, `padding`);
- a `font-size` falls back to the `16px` default;
- a non-numeric `font-size` keyword (e.g. `larger`) is also `unsupported_unit` and falls back to `16px`.

The `unsupported_unit` contract is uniform across the length and font-size paths.

### Explicit layout exclusions (v0 limits)

These are NOT supported in v0. Where a construct is expressed as an unsupported property value or unit, the relevant diagnostic is named; where it is simply an absent feature, there is no diagnostic (the property that would trigger it is itself `unknown_property`, or the value is ignored).

- **No margin collapsing.** Adjacent vertical margins simply ADD; they do not collapse.
- **No floats / `clear`.** `float` and `clear` are unsupported properties (`unknown_property`); there is no float layout.
- **Static positioning only.** `position` is an unsupported property (`unknown_property`); there is no relative / absolute / fixed / sticky positioning. Everything is in normal static flow.
- **No flex / grid / table layout.** `display: flex`, `display: grid`, and table layout do not exist; `display` values other than `block` / `inline` are carried as strings but produce inline/block flow only (any element whose `display` is not `block` is laid out inline). There is no `<table>` element in the HTML allowlist either.
- **No overflow scrolling.** `overflow` is an unsupported property (`unknown_property`); content is neither clipped nor scrolled.
- **Box background-color and border colours are not cascaded end-to-end.** Only TEXT is painted from computed styles in v0. The painter (`src/paint.zig`, `paintBox`) leaves block / inline / anonymous boxes transparent; `background-color` is parsed and cascaded (section 2) but never reaches the raster from the cascade, and there is no `border-*` colour property at all. Box background and border colours the golden fixtures show are supplied above the paint seam (`PaintStyle`), NOT resolved from the box's computed styles. So a `<div style="background-color: red">` renders transparent in v0. This is a known v0 limit, not a bug (threading box colours through layout into the box tree is scoped as a v0.1 follow-up); it has no diagnostic code (the property parses and cascades cleanly, it is simply not consumed by the painter).
- **No `%` height, and no `%` for `margin` / `padding`.** `%` is honoured for `width` only. A `%` `height`, `margin`, or `padding` is not supported and resolves to the fallback (`auto`/`0`); a `%` on a non-`width` length does not raise `unsupported_unit` (it is a supported unit used in an unsupported place, and falls back silently).

## 4. Diagnostic-code map

Every stable diagnostic `code` in `src/diagnostics.zig` and the v0 limit it represents. All are severity `warning` in v0 (the offending input is skipped and rendering continues):

| `code` | Stage | The limit it represents |
| --- | --- | --- |
| `non_allowlisted_element` | HTML parse | An HTML element outside the allowlist (section 1). The element is skipped; its allowlisted descendants survive. |
| `unknown_property` | CSS cascade | A CSS property outside the supported set (section 2). The declaration is ignored. Also how absent features like `border`, `position`, `float`, and `overflow` surface. |
| `unsupported_selector` | CSS cascade | A CSS selector outside the supported set (section 2): child/sibling combinators, attribute selectors, pseudo-classes/elements. The selector is dropped. |
| `unsupported_important` | CSS cascade | `!important` is not supported (section 2). The whole declaration is dropped. |
| `unsupported_unit` | Layout | A CSS unit outside `px` / `%`-width (section 3): `em`, `rem`, `vw`, `vh`, `ch`, `pt`, a keyword `font-size`, etc. The length falls back to `auto`/`0` and a `font-size` to `16px`. |

Limits with NO diagnostic code (they are silent drops or absent features, not reported boundaries):

- **Non-allowlisted attributes** (section 1) are silently dropped; there is no code for them in v0.
- **No margin collapsing** (section 3) is a layout behaviour, not a rejected input.
- **`%` height / margin / padding** (section 3) fall back silently (a supported unit used where v0 does not apply it), without `unsupported_unit`.
- **Box background / border colours not cascaded end-to-end** (sections 2 and 3): `background-color` parses and cascades cleanly, it is simply not consumed by the painter, so no diagnostic fires.
