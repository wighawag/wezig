# iOS shell (real Xcode project) — recorded design decisions

Decisions taken while building the real iOS Xcode/SwiftPM shell (task
`ios-shell-xcode-project`, spec `build-mobile-shell`). Recorded here (and linked
from the done record) so a reviewer/human can ratify or reverse them; none is
load-bearing/hard-to-reverse enough to STOP on, but each is a choice another
task / a user / a reviewer might be surprised was decided in-flight.

## 1. New `wezig_ios_shell_*` C-ABI (a new named surface) — `src/ios_shell.zig`

CHOSE: a dedicated shell C-ABI (`wezig_ios_shell_start` + intent/lifecycle/scheme
relay thunks) for the real app, SEPARATE from the exploration proof thunks
(`wezig_ios_proof_*` / `_embed_proof_*` / `_bridge_proof_*` / `_scheme_proof_*`
in `mobile_abi.zig` / `mobile_chrome_surface.zig`).
WHY: the proofs each assert ONE fact with a bespoke sink; the app drives the
shared `MobileChrome` over both seams and needs intent + lifecycle relay the
proofs don't have. Re-using a proof entry point would muddle "single-fact proof"
with "the app's wiring."
COHERENCE: this parallels the Android shell task's own shell entry
(`libwezigshell.so`) — file-orthogonal (`mobile/ios/**` vs `mobile/android/**`),
same layer (the real app's C boundary), no re-meaning of the proof surface.
ALTERNATIVE: extend a proof entry point — rejected (conflates proof vs app).
TOUCHES: `src/root.zig` (registers the module), `mobile/ios/Sources/wezig_mobile.h`
(the matching C decls), `build.zig`'s `ios-lib` (emits the exports via the
existing comptime-retention pattern).

## 2. Marker scheme name is `wezig://` (app) vs `wezig-test://` (scheme proof)

CHOSE: the real shell registers the trivial marker scheme `wezig://`; the
exploration scheme PROOF keeps `wezig-test://`.
WHY: `wezig-test` reads as a test-only name; the shipped app's marker is `wezig`.
Both are genuinely-custom (iOS forbids re-registering http/https/file/data/…), so
the ordering wiring is exercised either way. This shell serves only a trivial
marker body — there is NO real scheme content here (spec: "registers only the
trivial marker scheme").
TOUCHES / DOWNSTREAM: `explore-web3-capabilities` will add the REAL scheme
(`ipfs://`) on a per-`PageContext` webview; it must thread that scheme into EACH
config at build time (the finding). The `wezig` marker name is not load-bearing —
the real scheme is a genuinely different name.

## 3. `setViewportSize` is a no-op on the iOS shell backend ops

CHOSE: the app's `wkSetViewportSize` op is inert (unlike the proofs, which set
`webView.frame`).
WHY: the real app lays the embedded `WKWebView` out with Auto Layout inside the
content container (it fills the container), so the seam's viewport hint is
advisory on iOS — the OS owns the frame. Honouring it by setting `.frame` would
fight the constraints. `MobileChrome.build` still CALLS `setViewportSize` through
the seam (the seam path is complete); iOS just interprets it as a no-op, exactly
as the backend absorbs platform differences (ADR-0006).
TOUCHES: nothing above the seam; purely the iOS platform op's interpretation.

## 4. The mobile-verify iOS SHELL leg self-checks INSIDE the real app

CHOSE: the real app self-checks the mobile-verify assertions (navigate + a
`.finished` event reaching the chrome + a non-blank snapshot) PLUS the new
story-4 background→foreground assertion under a `--wezig-verify` launch arg
(`App/Sources/ShellVerify.swift`), rather than a separate proof harness.
WHY: spec story 7 — "the `mobile-verify` proof legs run against the REAL app."
Driving the SAME seams a user drives (a URL-field-equivalent navigate through the
chrome) is a truer regression signal than a parallel harness.
TOUCHES: `.github/workflows/mobile-verify.yml` (a new `ios-shell` job) +
`mobile/ios/shell-verify.sh`. The pre-existing `renderer-proof.sh` /
`*-proof.sh` legs (the exploration spikes) are untouched.
