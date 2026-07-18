---
title: review-gate non-blocking nits for 'ios-shell-xcode-project' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: ios-shell-xcode-project
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'ios-shell-xcode-project' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Doc-vs-code drift: ios_shell.zig, WKWebViewShellController and wezig_mobile.h all describe wezig_ios_shell_on_uri / _on_title as fed by KVO on WKWebView.URL / WKWebView.title, but the Swift backend never installs any KVO observer. on_uri is fired ONLY from the didFinish delegate callback, and on_title is never called from Swift at all. Functionally the URL-reflection criterion is still met (didFinish updates the field, and re-fires on back/forward), and on_title is inert by design (the mobile chrome keeps no title) — so no user-visible defect. Recommend correcting the comments (or wiring the KVO observers) so the next author does not trust a wiring that is not there.
  (src/ios_shell.zig:203,212; wezig_mobile.h:238,241; WKWebViewBackend.swift:77 (on_uri only in didFinish; no addObserver/observeValue anywhere).)
- Ratify 4 in-scope decisions the agent made and recorded in work/notes/observations/ios-shell-decisions-2026-07-18.md (NOT in a PR ## Decisions block — the commit body is empty). All look sound and non-load-bearing: (1) a NEW wezig_ios_shell_* C-ABI separate from the proof thunks; (2) marker scheme name wezig:// for the app vs wezig-test:// for the proof — downstream explore-web3-capabilities threads the real ipfs:// scheme per-config; (3) wkSetViewportSize is a no-op on iOS (Auto Layout owns the frame; ADR-0006 lets the backend absorb platform diffs); (4) the mobile-verify iOS leg self-checks INSIDE the real app under --wezig-verify rather than a separate harness (spec story 7). None re-means a load-bearing concept or sits at the wrong layer.
  (Decisions live in an observations note, not the PR body; each is a cross-task/default choice a human should nod at.)
