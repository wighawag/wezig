# `zig build ios-lib` fails on this box without `-Dmobile-sysroot` (stb's `<math.h>`)

Noticed 2026-07-18 while checking the `spike-harfbuzz-shaping` change did not
leak HarfBuzz into the mobile cross-compile. `zig build ios-lib` (and by
extension `android-lib`) fails at `src/vendor/stb_truetype.h:441` with
`'math.h' file not found` because the iOS SDK sysroot is not provided — exactly
what `-Dmobile-sysroot=$(xcrun --sdk iphonesimulator --show-sdk-path)` supplies
(build.zig documents this). Confirmed pre-existing (fails identically on the
unmodified tree), unrelated to this task, and NOT a HarfBuzz leak — the failing
command references only stb + `root.zig`. Just capturing the dev-box gap.
