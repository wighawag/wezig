---
title: review-gate non-blocking nits for 'pin-scriptengine-seam' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: pin-scriptengine-seam
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'pin-scriptengine-seam' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: EvalResult is modelled as a tagged union (completed | threw) rather than a Zig error, deliberately so a thrown JS exception does not collapse into the host-cannot-run channel. In-scope design choice, documented at src/script_engine.zig; sound and reversible.
  (src/script_engine.zig EvalResult doc comment; new error/outcome shape a future bound engine inherits.)
- Ratify: the host-binding surface is pinned as a single exposeHostBinding hook with a coarse string->string HostBinding ABI, with the wide DOM/GC/event-loop surface deliberately deferred to the follow-on build. In-scope default; coherent with the ADR-0006 pin-minimal discipline.
  (src/script_engine.zig HostBinding + exposeHostBinding; caveat block documents the deferral.)
- Minor: on dupe OOM, evaluate falls back to returning the borrowed input slice as .completed while last_source stays null; harmless for the stub but worth noting if a caller ever relies on last_source after evaluate.
  (src/script_engine.zig evaluate: self.last_source = dupe catch null; returns self.last_source orelse slice.)
