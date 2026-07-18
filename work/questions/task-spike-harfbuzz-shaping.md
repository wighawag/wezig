<!-- dorfl-sidecar: item=task:spike-harfbuzz-shaping type=task slug=spike-harfbuzz-shaping allAnswered=false -->

## Q1

**'task:spike-harfbuzz-shaping' was bounced — how should we proceed?**

> PR/code review (Gate 2) blocked this work:
> - The spike folds harfbuzz-shape-test into the default zig build test gate (build.zig test_step.dependOn(run_hb_spike_tests)) and links harfbuzz via linkSystemLibrary('harfbuzz') pkg-config resolution, but the CI gate job in .github/workflows/ci.yml runs 'zig fmt --check . && zig build && zig build test' on a bare ubuntu-latest with NO system-dependency install step (harfbuzz-dev is never provisioned anywhere in .github/). The local/dev-box gate is green only because harfbuzz-10.2.0 is present on the dev box. On CI, zig build test will fail to resolve/link harfbuzz, redding the repo's own acceptance gate on the next push. Either provision libharfbuzz-dev in the gate job, or move the spike test into its own provisioned CI leg. (.github/workflows/ci.yml gate job (lines 31-44) has no apt install; dorfl.json verify = 'zig fmt --check . && zig build && zig build test'; build.zig folds run_hb_spike_tests into test_step; note says pkg-config harfbuzz 'on the dev box'.)
> - Coherence/layer: the established pattern in this repo is that system-library proofs needing provisioning get a DEDICATED CI leg, NOT the display-free test gate (the WebKitGTK shell proofs shell-test/shell-bridge-test/shell-scheme-test live in a separate webview job that apt-installs libwebkitgtk-6.0-dev). The module note justifies putting harfbuzz IN test because it is display-free, but display-freeness is not the discriminator the pattern uses; needing a provisioned system dep is. harfbuzz is a system dep needing provisioning just like WebKitGTK, so folding it into the plain test gate sits at the wrong layer versus the repo's own convention. (src/harfbuzz_spike.zig module note '...belongs IN the zig build test gate — unlike the WebKitGTK shell proofs, which need Xvfb'; ci.yml keeps shell-* out of test in a provisioned webview job.)
> PR/code review (Gate 2) did not reach a unanimous approve across reviewMaxRounds=2 round(s) (a block is terminal and is never re-rolled); forcing needs-attention (never silently merged or looped).

<!-- q1 fields: id=q1 kind=stuck -->

**Your answer** (write below this line):
