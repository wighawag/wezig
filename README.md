# wezig

**A from-scratch web browser written in Zig, built as a browser should be.** Beyond rendering the standard web, wezig's reason to exist is treating capabilities a complete browser ought to have as first-class rather than leaving them to extensions: a native **Ethereum** provider (EIP-1193) for connecting to and signing for on-chain apps, and native **IPFS** content resolution. It binds mature C libraries (Skia / FreeType / HarfBuzz / SDL, Dawn or wgpu-native) rather than reimplementing rasterization, font shaping, or the GPU stack.

> **Status: very early (v0).** Today wezig renders a *fixed subset* of HTML/CSS to a window: parse → CSS cascade → block/inline layout → software paint (text, backgrounds, borders). It is NOT yet a usable browser: no networking, no JavaScript, no Ethereum/IPFS. Those are the direction, not the current state. See [What works today](#what-works-today) for the honest line between the two.

## Try it

```sh
# Requires Zig 0.16.0 (see build.zig.zon `minimum_zig_version`).
zig build run          # opens a window and paints a v0 page fragment
zig build test         # headless golden-image + unit tests (no display needed)
```

The first build compiles SDL3 from source (no system SDL needed), so it takes a while; later builds are fast.

## What works today

v0 is a deliberately small, fixed subset, precisely documented in **[docs/v0-subset.md](docs/v0-subset.md)** (that doc is the contract, kept honest by a test guard). In short, wezig v0 can:

- **Parse a fixed HTML subset to a DOM** (an element/attribute allowlist; anything outside it is reported and skipped) — `src/html.zig`.
- **Parse CSS and run the real cascade** (`<style>` blocks + `style=""`, a small selector set with the descendant combinator and grouping, specificity, inheritance, initial values) → computed styles on the DOM — `src/css.zig`.
- **Lay out block + inline boxes** (line-breaking with text measurement, the full box model, `px` and `%`-width) — `src/layout.zig`.
- **Paint to a window** (SDL3 window; stb_truetype glyphs + software rasterization; text, backgrounds, borders) — `src/paint.zig`, `src/sdl.zig`.

Every subset boundary is reported through one structured `Diagnostics` sink, and each diagnostic code maps to a documented limit. What v0 deliberately does NOT do (no margin collapsing, no floats, static positioning only, no flex/grid/table, no UA stylesheet, one embedded font, etc.) is enumerated in [docs/v0-subset.md](docs/v0-subset.md). It is a subset, not an aspirational superset.

## Architecture

wezig is built as swappable seams so each subsystem can be replaced without rewriting the others:

- A `Tokenizer | TreeBuilder` seam in the parser (so a WHATWG-conformant tokenizer can drop in later).
- A `PaintBackend` seam between layout and paint (so the software backend can be replaced by an SDL+FreeType+HarfBuzz+Skia/GPU backend behind the same interface), with the engine painting into an offscreen `Surface` that the golden-image tests assert on — no display required.

The rationale for each non-obvious decision lives in the ADRs:

- [ADR-0001](docs/adr/0001-v0-thin-subset-behind-swappable-seams.md) — v0 builds a thin HTML/CSS subset behind swappable seams.
- [ADR-0002](docs/adr/0002-paintbackend-seam-and-v0-layout.md) — the `PaintBackend` seam and the v0 layout box model.
- [ADR-0003](docs/adr/0003-v0-paint-c-linking-and-goldens.md) — SDL3 + stb_truetype linking, and the golden-image format.
- [ADR-0004](docs/adr/0004-windowing-sdl-as-v0-leaf-native-as-target.md) — windowing: SDL as the v0 leaf, native per-OS windowing as the target (a native X11 prototype lives in `prototypes/`).

## Requirements

- **Zig 0.16.0** (pinned in `build.zig.zon`; the local gate runs it via `zvm`, CI pins it with `setup-zig`).
- A display to run `zig build run` (on Linux, Wayland or X11). The **tests need no display** (they render offscreen and compare golden PNGs in memory), so `zig build test` runs in CI.

## Contributing / building

The acceptance gate is `zig fmt --check . && zig build && zig build test` (mirrored in CI on every push/PR). Changes use conventional-commit subjects (`feat:`, `fix:`, …); releases and the changelog are generated from that history by GoReleaser on a `v*` tag. See `CONTEXT.md` (domain vocabulary + conventions) and `docs/adr/` (decisions).

## License

[GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only).
