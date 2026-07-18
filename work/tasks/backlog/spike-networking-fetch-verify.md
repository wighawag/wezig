---
title: Spike networking — fetch one normal resource AND one hash-verified content-addressed resource
slug: spike-networking-fetch-verify
spec: explore-native-renderer
blockedBy: []
covers: [2, 6]
---

## What to build

Prove the PINNED networking direction — **BIND a vetted HTTP + TLS stack, never
write TLS** — on the NARROWEST real case: TWO fetches. This is a de-risking
spike, not the networking subsystem.

- **Normal server resource (compatibility floor):** bind a vetted HTTP + TLS
  stack (e.g. curl, or a Zig/Rust HTTP client + a vetted TLS lib) and fetch ONE
  ordinary `https://` resource successfully.
- **Hash-verified content-addressed resource (the thesis):** fetch ONE
  content-addressed resource (an `ipfs://`-style fetch) and HASH-VERIFY it —
  the fetched bytes must be checked against the content address, proving the
  verifiable-resource stance (ADR-0011), not merely fetched.

Both go behind a small networking seam/module so a future `WezigRenderer` /
`explore-web3-capabilities` can build on the same boundary. Record the concrete
library pick the spike settled (which HTTP client + which TLS lib) as an
observation/ADR input for the findings task.

## Acceptance criteria

- [ ] One ordinary `https://` resource is fetched successfully through a bound,
      vetted HTTP + TLS stack (no hand-written TLS).
- [ ] One content-addressed resource is fetched AND hash-verified against its
      content address (fetch fails/rejects on a hash mismatch), proven by a test.
- [ ] The two fetches sit behind a small networking module/seam (not scattered
      call sites), so later work can extend the same boundary.
- [ ] The concrete HTTP + TLS library pick is recorded for
      `native-renderer-findings-and-build-plan`.
- [ ] Tests cover both paths (a live-network leg may be gated/mocked per the
      repo's test conventions); the v0 build gate stays green. If any test writes
      to a shared/global location (a cache/config dir), it isolates that location
      to a temp dir and asserts the real one is untouched.

## Blocked by

- None — can start immediately.

## Prompt

> Goal: spike networking on the narrowest case — fetch ONE normal `https://`
> resource AND ONE hash-verified content-addressed resource (spec
> `explore-native-renderer`, story 2, decision 2). The pinned direction is BIND a
> vetted HTTP + TLS stack, NEVER write TLS. This is de-risking, not the
> networking subsystem.
>
> Bind a vetted HTTP client + TLS lib (e.g. curl, or a Zig/Rust HTTP client + a
> vetted TLS lib). Prove the compatibility floor (one ordinary server resource)
> AND the thesis (one `ipfs://`-style content-addressed resource whose bytes are
> HASH-VERIFIED against the content address — reject on mismatch). Put both behind
> a small networking module/seam so `WezigRenderer` and
> `explore-web3-capabilities` can extend the same boundary. Record which HTTP
> client + TLS lib you picked for the findings task.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0011 (verifiable/content-addressed
> resources, post-trusted-server), and the interception/custom-scheme note from
> the shell exploration (`work/notes/findings/`) for how `ipfs://` will later be
> served. This is exploration on the NARROWEST case (story 6): one + one fetch,
> prove-and-record; do NOT build the full networking layer or the IPFS subsystem.
> Keep live-network legs gated/mocked per repo convention and the v0 gate green.
> "Done" = both fetches work (normal + hash-verified) behind a small seam, the
> library pick is recorded, tests pass, v0 gate green.
