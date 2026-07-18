---
title: review-gate non-blocking nits for 'mobile-chrome-loop-zig' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: mobile-chrome-loop-zig
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'mobile-chrome-loop-zig' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- MobileChrome handles two intents the task did not name — reload maps to renderer.reload() and closed is a deliberate no-op. Ratify: both are sensible (exhaustive switch forces them; the closed no-op is correct since the OS owns teardown and is documented). No Decisions block was written, but these are minor.
  (src/mobile_chrome.zig onChromeIntent: .reload and .closed arms)
- Default content viewport is hardcoded content_w=1024 content_h=768, reported to setViewportSize in build(). Ratify: a sane non-zero placeholder the native shell overrides via the seam once it knows real bounds, matching desktop chrome.zig's window_w/h. User-visible only if a shell forgets to override.
  (src/mobile_chrome.zig content_w/content_h consts + build())
