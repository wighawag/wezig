---
title: The mobile confidence deliverable — ADR of decisions/findings + a sliced mobile build plan
slug: mobile-adr-and-build-plan
spec: explore-mobile-shell
blockedBy: [mobile-toolkit-seam-split, android-toolchain-ndk-crosslink, ios-toolchain-crosslink, android-renderer-backend-oneshot, ios-renderer-backend-oneshot, mobile-viewhandle-embedding-proof, mobile-web3-hooks-parity, mobile-verification-legs-ci]
covers: [11, 12, 13]
---

## What to build

Produce the exploration's CONFIDENCE deliverable (spec stories 11,12,13): capture the load-bearing decisions + the spikes' findings in an ADR, and emit a de-risked, SLICED mobile BUILD PLAN — the whole reason this exploration exists. This is the fan-in task: it runs after every spike has landed, synthesising what they proved (or disproved) into durable direction.

- **ADR** (`docs/adr/`): record the settled decisions (target floor iOS 16 / Android API 26; Zig-static-lib + thin-native-shell toolchain; the `Toolkit` split; the opaque-`ViewHandle` outcome; the two-hook parity + per-platform gaps; the CI-on-GitHub-runners verification strategy) AND the findings the spikes surfaced — especially the `ViewHandle`/JNI-ref result (Q3) and any seam refinement fed back to ADR-0006/0007. If a spike revised a decision, the ADR records the revision and why.
- **Sliced build plan** (a doc, e.g. under `docs/`): the follow-on mobile BUILD spec(s) — packaging pipeline, app lifecycle/state restoration, full mobile chrome (tabs, gestures, settings), permissions, code signing + store delivery — their scope, ordering, and the bar each must hit, WITH the seam + toolchain now proven. This is the input from which the follow-on build spec(s) are authored (mirrors how `docs/shell-exploration-findings.md` fed the desktop build plan).

## Acceptance criteria

- [ ] An ADR records the mobile decisions AND the spikes' findings (toolchain, `Toolkit` split, `ViewHandle` outcome, hook parity + gaps, verification strategy), noting any decision a spike revised.
- [ ] A written, SLICED mobile build plan names the follow-on build spec(s), their scope + ordering + per-slice bar, with signing/store delivery explicitly placed there (out of the exploration).
- [ ] The `ViewHandle` result (Q3) is stated unambiguously: confirmed-sufficient, or the pinned insufficiency + the seam refinement proposed to ADR-0006/0007.
- [ ] The plan is authorable-into-a-spec on its own (a follow-on `to-spec` could work from it alone), mirroring `docs/shell-exploration-findings.md`.
- [ ] Cross-references are correct: the ADR/plan link the sibling explorations (`explore-web3-capabilities` inherits the hook parity; `explore-native-renderer` inherits the mobile-webview-only scope), and the spec's Out-of-Scope boundaries are respected.
- [ ] No code gate change; this is a documentation/decision deliverable. The desktop v0 gate stays green.

## Blocked by

- ALL mobile spike tasks (`mobile-toolkit-seam-split`, `android-toolchain-ndk-crosslink`, `ios-toolchain-crosslink`, `android-renderer-backend-oneshot`, `ios-renderer-backend-oneshot`, `mobile-viewhandle-embedding-proof`, `mobile-web3-hooks-parity`, `mobile-verification-legs-ci`) — this synthesises their outcomes, so it fans in after every one.

## Prompt

> Goal: produce the confidence deliverable for the mobile exploration (spec `explore-mobile-shell`, stories 11,12,13) — an ADR of the decisions + findings, and a de-risked, sliced mobile BUILD PLAN. This is the fan-in synthesis task: it runs only after every mobile spike has landed, so its content is grounded in what they actually proved, not in the launch-time plan.
>
> Write the ADR (`docs/adr/`) recording the settled decisions (iOS 16 / Android API 26 floor; Zig-static-lib + thin-native-shell per platform; the `Toolkit` chrome-surface/host-loop split; the opaque-`ViewHandle` outcome; the two-hook parity + iOS scheme-ordering / Android threading + scheme-security-trait gaps; CI-on-GitHub-runners verification) and the spikes' FINDINGS — call out the `ViewHandle`/JNI-ref result (Q3) explicitly and any seam refinement fed back to ADR-0006/0007. If a spike revised a decision, record the revision + why. Then write the sliced build plan (a doc, the mobile analogue of `docs/shell-exploration-findings.md`): the follow-on mobile BUILD spec(s), their scope/ordering/bar, with packaging + app lifecycle + full chrome + permissions + code-signing/store-delivery placed THERE (out of this exploration). It must be authorable into a follow-on spec on its own.
>
> Read: the spec (its Resolved decisions + Out of Scope), every mobile spike task's done-record, the sibling explorations (`explore-web3-capabilities`, `explore-native-renderer`) for cross-references, `docs/shell-exploration-findings.md` + ADR-0007 as the format precedent, the ADR-FORMAT.md. This is a documentation/decision deliverable — no code gate change; the desktop v0 gate stays green. "Done" = an ADR pins the mobile decisions + findings (esp. the ViewHandle outcome), and a sliced build plan makes the mobile browser a known quantity to build.
