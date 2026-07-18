---
title: review-gate non-blocking nits for 'android-renderer-reinject-and-globalref-fix' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: android-renderer-reinject-and-globalref-fix
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'android-renderer-reinject-and-globalref-fix' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Cross-task handoff gap: the C-shim follow-up (add deleteView/teardown fields to WezigCJavaBridge in wezig_renderer_jni.c so field order matches CJavaBridge, and fix the intentionally-leaked EmbedCtx free in wezig_embedding_jni.c) lives ONLY in the observation note's Decision 1, NOT in the android-shell-app task body. Built from its file alone (self-contained-prompt rule), android-shell-app would leave the JNI shim one revision behind (a latent ABI/field-order mismatch) and the EmbedCtx leak — an explicit acceptance clause of THIS task — unfixed. Recommend adding an acceptance clause to android-shell-app so the receiving task OWNS this.
  (work/notes/observations/android-renderer-globalref-teardown-scope-2026-07-18.md Decision 1/2 vs work/tasks/ready/android-shell-app.md (no deleteView/teardown/EmbedCtx clause))
- Ratify Decision 1: this task's acceptance says 'frees the EmbedCtx global-ref on teardown', but the literal EmbedCtx (in mobile/android/**/wezig_embedding_jni.c, another task's file scope) is deferred; the renderer instead frees its OWN JavaCtx via a new teardown op. Sound given the in-file constraint, but it is a partial non-delivery of a literal clause — confirm.
  (EmbedCtx defined at wezig_embedding_jni.c:140 (intentionally leaked); renderer-side analogue JavaCtx freed via bridge.teardown in android_renderer.zig deinit)
- Ratify Decision 3: a user script longer than max_injected_source (8192) is injected once but silently NOT remembered/re-issued on later .started events (fixed in-struct buffer, no allocator). Fine for marker/provider sources but a silent size cap on the document-start contract.
  (injectUserScript in android_renderer.zig: span.len<=max_injected_source else injected_source=null)
