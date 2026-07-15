---
title: review-gate non-blocking nits for 'seam-script-bridge-and-interception' (Gate 2 approve)
date: 2026-07-15
status: open
reviewOf: seam-script-bridge-and-interception
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'seam-script-bridge-and-interception' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- The captured note is filed in work/notes/observations/ but is verified EXTERNAL ground truth about WebKitGTK 6.0 (SW registration data-category, WebKitSecurityManager scheme-security APIs, the two interception layers), carries a source: field, and even declares kind: finding in its own frontmatter. Per WORK-CONTRACT bucket polarity (observation = spotted/unverified; finding = verified external/domain ground truth with a source:), this belongs in work/notes/findings/. Recommend re-filing so shell-findings-and-build-plan finds it as durable reference knowledge, not an append-only observation.
  (work/notes/observations/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md frontmatter kind: finding, source: ...; WORK-CONTRACT.md lines 84-86)
- Ratify in-scope decision: build.zig replaced the smoke boolean selector with a mode string (interactive/smoke/bridge/scheme) plus a ShellBuild helper and a verify_steps loop, adding two new build steps (shell-bridge-test, shell-scheme-test). This touches the pre-existing shell-test step's construction. The refactor preserves the smoke path and is clean, but the PR description carried no ## Decisions block recording it.
  (build.zig diff: ShellBuild.make + VerifyStep loop; shell_main.zig Mode enum)
- Ratify in-scope decision: the WebKitGTK backend hardcodes the script-message channel name as 'wezig' in onScriptMessage (the JSCValue does not carry the channel name), so today only one page->native channel is meaningfully supported. Documented in-code, but worth ratifying since explore-web3-capabilities may want more channels.
  (src/system_webview_renderer.zig onScriptMessage: cb.onMessage(cb.ctx, 'wezig', ...))
