# iOS Renderer backend reaches WKWebView through a C-ABI ops table (design decision)

_2026-07-18 — task `ios-renderer-backend-oneshot` (spec `explore-mobile-shell`, story 4)._

Durable record of the load-bearing choice made building the iOS `Renderer`
backend, linked from the done record. Recorded here (rather than only in code)
because a reviewer/another mobile task could be surprised by HOW the Zig backend
reaches the `WKWebView`, and it touches the shared `mobile_abi.zig` C-ABI + the
downstream `mobile-web3-hooks-parity` task.

## Decision: the iOS backend is a Zig `Renderer` impl that drives WKWebView via a C-ABI `WkPlatform` ops table

**What I chose.** `src/ios_webview_renderer.zig` (`IosWebviewRenderer`) implements
the pinned `Renderer` VTable in **Zig** (the twin of the desktop
`SystemWebviewRenderer`). But unlike desktop — where the backend `@cInclude`s
WebKitGTK and calls its C symbols inline in the same translation unit — the iOS
backend holds a small **C-ABI ops table** (`WkPlatform`: navigate/reload/…/view)
that the **Swift** shell installs at construction, and the `WKNavigationDelegate`
callbacks flow BACK into the backend (via exported thunks in `mobile_abi.zig`),
which maps them to the seam's `LifecycleEvent`s. The physical `WKWebView` calls
live in exactly one Swift file (`mobile/ios/Sources/RendererProof.swift`).

**Why.** The pinned iOS toolchain (task `ios-toolchain-crosslink`, spec §Q2) has
**Swift own the `WKWebView`** and **Zig own the portable core over a C-ABI**
(`src/mobile_abi.zig`). The Zig backend therefore cannot call WebKit inline the
way the GTK backend does; the ops table is the boundary that lets the backend
stay the sole driver of the webview while the actual Obj-C/Swift calls sit on the
native side of the FFI the toolchain already pinned.

**Alternatives considered.**
- _Call the Obj-C runtime directly from Zig_ (`objc_msgSend` on `WKWebView`).
  Rejected: fights the settled toolchain (Swift owns the webview + its delegate,
  Info.plist, config), duplicates the delegate wiring, and is far more brittle
  than a typed C-ABI ops table.
- _Make the backend live in Swift entirely_ (no Zig `Renderer` impl on iOS).
  Rejected: the acceptance criterion is that the backend implements the **pinned
  `Renderer` VTable** (a Zig seam), and keeping the seam impl in Zig is what keeps
  the chrome / provider / IPFS above the seam backend-agnostic and swappable to
  `WezigRenderer` later.

**What it touches.**
- `src/mobile_abi.zig` — adds the `wezig_ios_proof_*` / `wezig_ios_on_load_state`
  export thunks (the Swift↔Zig proof C-ABI). The `abi_version` was NOT bumped:
  the toolchain shell's surface (`wezig_abi_version`/`wezig_greeting`) is
  unchanged; the proof thunks are additive story-4 scaffolding, not a contract
  the toolchain shell links.
- `mobile-web3-hooks-parity` (downstream) — `setScriptMessageHandler` and
  `registerScheme` are left as inert no-ops in the iOS backend for now (they need
  `WKScriptMessageHandler`/`WKURLSchemeHandler` wiring that task owns); the ops
  table already carries `injectUserScript`/`evaluateScript` so the boundary is
  pinned for it.

## Boundary shape (for the reviewer)

- The end-to-end iOS proof runs on a **dedicated `ios-renderer-proof` CI leg**
  (macos-14, iOS 17 simulator), OUT of `zig build test` — spec Q6 / ADR-0007
  discipline, exactly like the desktop `shell-test` webview leg.
- The **seam-contract** portion (backend maps a nav-delegate sequence to a
  `.finished` seam event; `view()` returns the opaque handle) runs headlessly in
  `zig build test` via a fake `WkPlatform`, mirroring `renderer.zig`'s
  `FakeRenderer` tests.
