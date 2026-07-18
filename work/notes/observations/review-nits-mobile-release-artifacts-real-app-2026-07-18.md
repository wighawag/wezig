---
title: review-gate non-blocking nits for 'mobile-release-artifacts-real-app' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: mobile-release-artifacts-real-app
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'mobile-release-artifacts-real-app' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify the workflow_dispatch dry-run design: the agent added a new user-visible trigger, split goreleaser into tag (release --clean) vs dispatch (release --snapshot --clean), and routed mobile artifacts to gh release upload on a tag vs actions/upload-artifact on a dispatch. This is an in-scope design choice, recorded in the observation note Decisions block. Reversible and the tag path is byte-for-byte unchanged, so non-blocking — human to ratify.
  (work/notes/observations/release-workflow-dispatch-dryrun-2026-07-18.md; release.yml goreleaser step split + upload-artifact fallback)
- On a workflow_dispatch run GITHUB_REF_NAME is the branch name (e.g. main), so the dry-run artifact is named wezig_main_android_debug_unsigned.apk rather than a version tag. Harmless for a workflow artifact but the label no longer reads as a version. Consider a dispatch-only name if the label matters.
  (release.yml: OUT=wezig_${GITHUB_REF_NAME}_... used in both tag and dispatch paths)
- Acceptance criterion 5 (live end-to-end tag/dispatch CI run) was not executed in-sandbox; the note flags it needs GitHub macOS+Android runners and a pushed branch first. This is an honest verification boundary, not a diff defect, but the live dispatch run is still owed post-integration.
  (observation note Verification boundary section)
