---
title: review-gate non-blocking nits for 'spike-networking-fetch-verify' (Gate 2 approve)
date: 2026-07-19
status: open
reviewOf: spike-networking-fetch-verify
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'spike-networking-fetch-verify' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: the live network legs SKIP-and-pass unless -Dnetworking-live is set; the load-bearing proof (seam contract + hash-verify thesis) is the OFFLINE test in src/networking.zig that runs in the core gate. Is making the live https fetch non-load-bearing (green without egress) the intended de-risking posture?
  (networking_spike.zig liveEnabled() returns build_options.networking_live; LIVE tests return error.SkipZigTest when off. CI networking leg passes -Dnetworking-live so the real fetch runs there. Disclosed in module docs + the finding note.)
- Ratify: the spike models only the LOAD-BEARING half of a CID (HashAlgo + expected digest) and hard-codes SHA-256; real multibase/multihash/codec CID decoding, extra hashes, TLS trust-store/pinning policy, and the full networking layer are explicitly deferred to native-renderer-findings-and-build-plan / explore-web3-capabilities. Correct scope boundary for a spike?
  (src/networking.zig ContentAddress doc + finding note 'Scope / what is NOT settled' section. HashAlgo enum + verify contract shaped so the CID parser slots in without changing verify.)
- Minor doc nit: build.zig comment says 'Force the option on for the step itself' but the step only does dependOn — a bare `zig build networking-fetch-test` (no -Dnetworking-live) SKIPS the live legs. No functional impact (the CI leg passes the flag), but the comment overstates what the step does.
  (build.zig lines ~303-305; net_spike_step.dependOn(&run_net_spike_tests.step) with no forced option.)
