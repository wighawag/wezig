# v0 builds a thin HTML/CSS subset behind swappable seams

For the v0 rendering slice we build our OWN thin implementation of each pillar (HTML subset parser, CSS parser + cascade, selector matcher, block/inline layout, paint) rather than adopting an existing Zig project wholesale, but we place each behind a deliberate seam so a mature replacement is a backend swap, not a rewrite. The seams: a `Tokenizer | TreeBuilder` split (token stream as the currency) so a WHATWG tokenizer can later replace the naive subset tokenizer; a `Selector`-AST matcher so child/sibling/attribute/pseudo selectors are additive; a real (if small) cascade algorithm (origin tier → specificity → source order + inheritance) so it grows by adding properties/selectors, not by re-sorting; and a single `PaintBackend`/`Canvas` interface (`measureRun`, `drawRun`, `fillRect`, `drawBorder`, `beginFrame`/`present`) with shaping AND raster BELOW the seam, so the v0 light backend (SDL3 + stb_truetype + software raster) can be replaced by the mature stack (SDL + FreeType + HarfBuzz + Skia) with zero caller changes.

Why: v0's committed payoff is small (a fixed HTML/CSS subset, Latin/LTR text, authored fixtures), so pulling in the full C stack or an external pipeline up front front-loads the hardest integration against the smallest benefit and risks the "green gate from day one" promise (headless Skia/HarfBuzz builds are a common CI pain). Building thin behind seams keeps v0 small and testable while making the eventual maturation additive.

## Considered Options

- **Full mature stack from v0** (SDL + FreeType + HarfBuzz + Skia, a WHATWG parser): correct long-term picks, but four-plus C libraries and a conformance-grade parser for a v0 whose text/HTML needs are minimal — rejected as premature.
- **Adopt `zss` (Zig CSS parser + layout + renderer) and/or `zigquery` as the v0 foundation**: genuinely attractive and explicitly on the table, but adopting `zss` would fold our cascade/layout/paint seams into its design and is a strategic fork deserving real evaluation, not a v0 default. Recorded as a DEFERRED evaluation at its own milestone, not committed now.

## Consequences

- The v0 stb/software text path and naive tokenizer are deliberately throwaway relative to their mature replacements; that is expected, not debt to apologise for.
- Golden-image tests target the `PaintBackend` interface output (offscreen surface), so they survive the backend swap.
- "shaped text" in v0 via stb_truetype is not true shaping (no complex scripts / full kerning); acceptable for the v0 Latin/LTR subset.
