---
title: review-gate non-blocking nits for 'spike-ipfs-fetch-verify-and-secure-origin-seam' (Gate 2 approve)
date: 2026-07-19
status: open
reviewOf: spike-ipfs-fetch-verify-and-secure-origin-seam
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'spike-ipfs-fetch-verify-and-secure-origin-seam' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- The PR/commit body is empty (no '## Decisions' block). The in-scope design choices were instead captured in work/notes/observations/scheme-security-traits-are-a-sibling-optional-seam-method-2026-07-19.md — human should ratify: (a) declareSchemeSecurity as a SIBLING, OPTIONAL vtable method rather than extra fields on registerScheme; (b) secure_origin_traits = secure+CORS, NOT local.
  (Decision is well-reasoned (WebKitSecurityManager is a distinct API; registerScheme has ~8 call sites; additive vs breaking). Recorded, just not in a Decisions block.)
- resolve() maps error.MalformedAddress to the .hash_mismatch variant, collapsing a malformed-address error into the same rejection bucket as a genuine hash mismatch. Ratify this conflation for the spike.
  (src/ipfs_scheme.zig resolve(): both surface a safe rejection placeholder so no unverified bytes reach the page; only the test-observable variant differs. Acceptable for a spike.)
- The live off-core-gate leg (shell.zig onIpfsRequest) serves a hardcoded marker HTML body and ignores the URI — it does NOT drive IpfsSchemeHandler / fetch+verify. Confirm this is the intended split.
  (Acceptance criterion 3 scopes the live leg to proving WebKitSecurityManager marks the origin secure; the fetch+verify math is proven in the core gate (ipfs_scheme.zig). Build.zig/CI comments describe it accurately, so no overclaim.)
