---
title: the app-entrypoint demo paints text flush against the window top (no UA margin)
date: 2026-07-14
status: open
kind: polish
relatesTo: [paint-sdl3-stb-window, document-v0-subset-limits]
---

## What was noticed

Running the app (`zvm run 0.16.0 build run`) opens the `wezig` window and paints "wezig paints text" correctly, BUT the text sits flush against the very top edge of the window, with its ascent right at `y=0` and a large empty area below. It reads as clipped/broken even though it is not.

## Why it happens (NOT a bug)

The paint math is correct: `paintBox` draws a run's baseline at `box.dims.y + box.ascent` (`src/paint.zig` ~line 293), so the ascent is accounted for. The text is flush at the top because the demo fixture is `<body><p>wezig paints text</p></body>` (`src/paint.zig` ~line 362) and v0 has **no user-agent stylesheet** (documented limit in `docs/v0-subset.md` §2): real browsers give `body` an 8px margin and `p` a top margin, but v0 does not, so the first line box starts at `y=0`. This is faithful to the documented v0 subset, not a rendering defect.

## Suggested polish (cosmetic, optional)

Make the DEMO look like a browser without changing the engine or v0 semantics: give the app-entrypoint fixture explicit inline margins/padding using only SUPPORTED v0 properties, e.g.

    <body style="padding: 8px"><p style="margin: 8px">wezig paints text</p></body>

`padding`/`margin` are in the v0 supported-property set and resolve in `px`, so this needs no engine change; it only makes the entrypoint demo render with breathing room. Leaving it as-is is also fine (it is honest about "no UA stylesheet"); this is a demo-presentation tweak, deliberately NOT scope creep into a UA-stylesheet feature.

If a real UA-default-margin behaviour is ever wanted, that is a separate feature (a small hardcoded UA-like margin table, analogous to the default-`display` table), which would be a v0.1 task, not this note.
