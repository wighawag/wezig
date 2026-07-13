---
title: HTML parse — fixed subset to DOM
slug: html-parse-subset
spec: wezig-browser
blockedBy: [diagnostics-sink]
covers: [1]
---

## What to build

Turn a fixed, allowlisted subset of HTML into a DOM tree, behind a `Tokenizer | TreeBuilder` seam so a WHATWG tokenizer can later replace the naive one without rewriting the tree builder or DOM. The tokenizer emits a token stream (start-tag, end-tag, text, comment) and stays dumb except for one documented exception: it treats `<style>` content as raw text (so `{}`/`:` inside it are not tokenized as HTML). The tree builder consumes tokens, enforces the element/attribute allowlist, and produces DOM nodes that carry parent pointers (needed later for descendant-selector matching). Both `<style>` blocks and the `style=""` attribute are captured on the DOM (their CSS is parsed in the cascade task, not here). Non-allowlisted elements produce a `non_allowlisted_element` diagnostic and are skipped; parsing continues.

## Acceptance criteria

- [ ] A `Tokenizer` emits a token stream; `<style>` content is tokenized as raw text.
- [ ] A `TreeBuilder` consumes tokens and builds a DOM enforcing the allowlist; nodes carry parent pointers.
- [ ] `<style>` block text and `style=""` attribute values are captured on the DOM for the cascade task to consume.
- [ ] Non-allowlisted elements emit `non_allowlisted_element` and are skipped (parsing continues).
- [ ] Tests at the DOM seam: given fixture HTML, assert the DOM structure AND the collected diagnostic codes.
- [ ] Tests cover the new behaviour, mirroring the repo's test style.

## Blocked by

- `diagnostics-sink` (the tree builder pushes `non_allowlisted_element` diagnostics).

## Prompt

> Goal: parse a FIXED, documented subset of HTML into a DOM tree. Decisions already made (do not re-litigate): (1) the subset is an explicit element/attribute ALLOWLIST, not a WHATWG-conformant parser — anything outside the list is a diagnostic, not handled. (2) The parser is split at a `Tokenizer | TreeBuilder` seam with a token stream as the currency, so a real WHATWG tokenizer can drop in later against the same tokens while the tree builder grows toward the insertion-mode state machine independently. (3) The allowlist POLICY lives in the tree builder; the tokenizer stays dumb EXCEPT it special-cases `<style>` as raw-text mode (a documented exception, mirroring WHATWG's own raw-text handling). (4) v0 supports BOTH `<style>` blocks and the `style=""` attribute — capture their text on the DOM here; the CSS parsing/cascade is a SEPARATE later task.
>
> DOM nodes must carry parent pointers (a later task's descendant-combinator matcher walks ancestors). Non-allowlisted elements emit `non_allowlisted_element` via the `Diagnostics` sink (already built) and are skipped without aborting. Test at the DOM seam: fixture HTML in, assert DOM structure + collected diagnostic codes — do NOT assert internal tokenizer state (the seam is the DOM).
>
> Domain vocabulary (HTML parser, DOM, `<style>`, `style=""`): `CONTEXT.md`. The `Diagnostics` type is from the `diagnostics-sink` task. "Done" = fixture HTML parses to the expected DOM with the expected diagnostics, and the tokenizer/tree-builder boundary is a clean swappable seam.
>
> RECORD non-obvious decisions durably: the exact allowlist you settle on (element + attribute set) is the seed of the v0-limits doc (`document-v0-subset-limits` task) — write it where that task can pick it up (a doc comment or the done record).
