---
title: Spike real text shaping (HarfBuzz) behind the PaintBackend seam on one string
slug: spike-harfbuzz-shaping
spec: explore-native-renderer
blockedBy: []
covers: [2, 6]
---

## What to build

Prove that real text shaping via HarfBuzz (PINNED) works behind the existing
`PaintBackend` seam (ADR-0002) on the NARROWEST real case — ONE non-trivial
string whose correct rendering v0's `stb`-only path cannot produce. This is a
de-risking spike, not the text subsystem: it proves the pinned library choice
and that the seam can host real shaping.

- Bind HarfBuzz and shape ONE string that genuinely needs shaping (e.g. a script
  with contextual/complex shaping, or ligatures/kerning) — one that demonstrably
  differs from v0's `stb_truetype` glyph-by-glyph path.
- Drive the shaped run through the `PaintBackend` seam so it paints into the
  offscreen `Surface` (the same target the v0 goldens use), keeping `stb` as the
  v0/fallback path (do NOT rip it out).
- Note whether FreeType glyph rasterization is needed yet to pair with HarfBuzz
  (LEAN FreeType per decision 2) — an observation for the findings task, decided
  by what this spike actually needs.

## Acceptance criteria

- [ ] HarfBuzz is bound and shapes one non-trivial string behind the
      `PaintBackend` seam, painting into the offscreen `Surface`.
- [ ] The spike demonstrates a rendering v0's `stb` path cannot produce
      (proving the shaping path is load-bearing), verified by a test/golden.
- [ ] The v0 `stb` path remains as the v0/fallback path (not removed); the v0
      build gate stays green.
- [ ] A note is captured (for `native-renderer-findings-and-build-plan`) on
      whether FreeType is needed yet to pair with HarfBuzz.
- [ ] Tests cover the new behaviour and mirror the repo's golden/test style;
      any on-screen/display path stays out of the display-free gate.

## Blocked by

- None — can start immediately.

## Prompt

> Goal: spike real text shaping with HarfBuzz behind the `PaintBackend` seam on
> ONE non-trivial string (spec `explore-native-renderer`, story 2, decision 2).
> HarfBuzz is PINNED; this spike proves it works behind the seam and that v0's
> `stb_truetype` glyph-by-glyph path is insufficient for real shaping — it is
> de-risking, NOT the text subsystem.
>
> Where to look: the `PaintBackend` seam (ADR-0002) and the paint layer
> (`src/paint.zig`), the v0 text path using `stb_truetype` (`src/vendor/`), and
> the offscreen `Surface` the goldens target (ADR-0003). Shape ONE string that
> needs real shaping (contextual shaping / ligatures / kerning) and paint it
> through the seam into the offscreen `Surface`. Keep `stb` as the v0/fallback
> path — do not remove it. While here, OBSERVE whether FreeType rasterization is
> needed yet to pair with HarfBuzz (decision 2 LEANs FreeType) and capture a note
> for the findings task.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0001/0002/0003. This is
> exploration on the NARROWEST case (story 6): one string, prove-and-note, do NOT
> build a shaping subsystem or migrate v0 text. "Done" = one non-trivial string
> shapes via HarfBuzz behind `PaintBackend` and paints correctly (differing from
> the `stb` path), proven by a test, with the FreeType note captured and the v0
> gate green.
