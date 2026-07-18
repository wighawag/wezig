---
title: review-gate non-blocking nits for 'mobile-shell-lifecycle-adr' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: mobile-shell-lifecycle-adr
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'mobile-shell-lifecycle-adr' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- The ADR asserts the native webviews restore page, scroll position AND history across the lifecycle transition; the spec phrases this more cautiously as the OS-mandated state save-restore. Is the stronger 'history' claim intended, or should it track the spec wording?
  (docs/adr/0010 'Why host-only' para: 'the OS persists and re-materialises the webviews page, scroll position, and history'. Accurate for WKWebView/WebView restorable state, not load-bearing to the decision.)
