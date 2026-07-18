---
title: review-gate non-blocking nits for 'mobile-verify-legs-real-app' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: mobile-verify-legs-real-app
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'mobile-verify-legs-real-app' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: the 3 iOS seam proofs (embedding/bridge/scheme) were folded into a NEW WezigShellTests XCTest bundle driven by xcodebuild test, rather than repointing each *-proof.sh to a per-proof app target. Recorded in the disposition note; matches the Android precedent (proofs as instrumented tests in the real app test target). Reasonable and reversible.
  (work/notes/observations/mobile-verify-real-app-disposition-2026-07-18.md; mobile/ios/App/Tests/*, WezigShell.xcodeproj test target A1000007000000000000FT01)
- Ratify: the bespoke proof C-ABI entry points (wezig_ios_{embed,bridge,scheme}_proof_*) in mobile_abi.zig / mobile_chrome_surface.zig were KEPT (not removed) since the XCTest cases now drive them against the real lib. Recorded; correct — removing them would delete the assertions.
  (src/mobile_abi.zig:253-413, src/mobile_chrome_surface.zig:196-283; disposition note last section)
