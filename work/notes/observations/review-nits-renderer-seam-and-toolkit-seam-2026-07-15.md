---
title: review-gate non-blocking nits for 'renderer-seam-and-toolkit-seam' (Gate 2 approve)
date: 2026-07-15
status: open
reviewOf: renderer-seam-and-toolkit-seam
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'renderer-seam-and-toolkit-seam' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- toolkit.zig doc-comment lists getUrlText in the widget set, but no getUrlText method exists in the Toolkit VTable (only setUrlText). FakeToolkit.urlText() is a test helper, not a seam method. Fix the doc comment or drop the mention.
  (src/toolkit.zig:25 vs the VTable which has only setUrlText)
- Ratify: setViewportSize ships as a no-op for the webview backend (GTK layout tracks the embedded WebView size). Deliberate and recorded in ADR-0006 as the MINIMAL-start choice; the seam method exists for WezigRenderer later. Human to ratify.
  (src/system_webview_renderer.zig setViewportSize no-op; ADR-0006 records it)
- Ratify: chrome copies URLs onto a fixed 2048-byte stack buffer and SILENTLY drops navigation if the URL is longer (returns without error). A user-visible default/edge behaviour not in the task. Human to ratify (data: URLs can exceed 2048).
  (src/chrome.zig onChromeIntent + setUrlBar: if url.len >= buf.len return)
- Ratify: the minimal chrome deliberately keeps a FIXED window title and ignores title_changed events (comment says title reflected only in interactive path). In-scope default choice; human to ratify.
  (src/chrome.zig onRendererEvent .title_changed branch is a no-op)
