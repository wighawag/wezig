---
source: The `spike-networking-fetch-verify` spike itself (src/networking.zig + src/networking_spike.zig + build.zig `networking-fetch-test`), verified against libcurl 8.14.1 (OpenSSL/3.5.6 TLS backend, HTTP/2 via nghttp2) bound through Zig 0.16 C interop on the dev box, with the offline hash-verify thesis proven in the display-free `zig build test` gate.
---

# Networking HTTP + TLS pick: **libcurl** (bound, never write TLS) — for `native-renderer-findings-and-build-plan`

Verified while running the `spike-networking-fetch-verify` spike (spec
`explore-native-renderer`, story 2 + story 6, decision 2). Decision 2 pins the
networking direction as **"a BOUND HTTP+TLS stack, NEVER write TLS."** This spike
settles the concrete pick and proves it on the narrowest real case: ONE ordinary
`https://` fetch (the compatibility floor) AND ONE hash-verified
content-addressed fetch (the thesis), both behind one small seam.

## The pick

- **HTTP client + TLS: libcurl.** Its TLS is terminated by a vetted TLS library
  chosen at curl's build time — **OpenSSL** on the dev box/CI
  (`OpenSSL/3.5.6`), with GnuTLS / BoringSSL / wolfSSL as drop-in curl backends.
  wezig writes **zero TLS**, exactly what decision 2 requires. libcurl is a
  mature, ubiquitously-vetted C HTTP stack (HTTP/1.1 + HTTP/2 via nghttp2 here,
  redirects, connection reuse, timeouts) and binds cleanly through Zig's C
  interop — the same C-library-binding strategy the repo already uses for
  Skia/FreeType/HarfBuzz/SDL (`CONTEXT.md`).

## Why libcurl over the alternatives (recorded so it is not re-litigated)

- **Zig std `std.http.Client` + a bound TLS lib.** Zig ships an HTTP client, but
  its TLS story is in flux across Zig versions and a from-scratch/std TLS path
  cuts AGAINST decision 2's "never write/own TLS" — the whole point is to lean on
  a battle-tested TLS implementation, not track Zig std's evolving one. Rejected
  for the compatibility floor; may be revisited for niche in-process fetches.
- **A Rust HTTP client (reqwest/hyper) + rustls.** Vetted and modern, but pulls a
  Rust toolchain + a second FFI boundary into a Zig-C project whose binding
  strategy is already C libraries. Heavier integration for no floor-level gain.
  Not chosen now; not foreclosed for a future component.
- **Hand-rolled HTTP over a raw TLS lib (OpenSSL/BoringSSL directly).** More code
  to own (HTTP semantics: redirects, chunked/keep-alive, HTTP/2) for no benefit
  over libcurl, which already wraps a vetted TLS lib. Rejected.

libcurl is the smallest, most-vetted way to satisfy "bind HTTP + a vetted TLS
lib" today; the seam (below) keeps the choice reversible.

## What the spike proved (and where the seam is)

- **The seam is `net.Fetcher`** (`src/networking.zig`): a `{ ptr, vtable }`
  boundary in the SAME shape as `PaintBackend` (ADR-0002) and `Renderer`
  (ADR-0005). A future `WezigRenderer` / `explore-web3-capabilities` fetch
  THROUGH this, so the plain fetch and the content-addressed fetch extend one
  boundary, not scattered call sites.
- **The thesis is `ContentAddress.verify` + `fetchVerified`** (same file): the
  content is trusted because it **hashes to its address** (SHA-256, the multihash
  default for IPFS CIDv1 raw), not because a server served it (ADR-0011). On a
  hash mismatch the fetched bytes are freed and `error.HashMismatch` is returned,
  so a caller can NEVER observe unverified content-addressed bytes. This half is
  PURE ZIG (std crypto) and runs OFFLINE in the display-free `zig build test`
  gate with a fake in-memory fetcher — the load-bearing proof does not depend on
  network reachability.
- **The bound stack is `CurlFetcher`** (`src/networking_spike.zig`): satisfies the
  same `net.Fetcher` seam over the real network. Its live proof — one `https://`
  fetch of `example.com` through libcurl+TLS, plus a content-address
  verify/reject over the same bound transport — runs in the dedicated
  `zig build -Dnetworking-live networking-fetch-test` step / the `networking` CI
  leg, NOT the core gate (it needs `libcurl4-openssl-dev` + egress). This mirrors
  the `harfbuzz` and `webview` provisioned legs (ADR-0007): provisioned/live
  proofs stay off the display-free gate; libcurl is linked ONLY into the spike's
  test exe, never the `wezig` `mod` or the mobile cross-compiles.

## Scope / what is explicitly NOT settled here (for the build plan)

This is the narrowest-case SPIKE, not the networking or IPFS subsystem. The
following are follow-on BUILD concerns, deliberately out of scope:

- **The full IPFS story.** This spike models the LOAD-BEARING half of an
  `ipfs://` address ("the address is the hash of the content, verify it"), NOT
  real CID grammar (multibase/multihash/codec/version decoding) nor gateway-vs-
  native-DHT resolution. The `ContentAddress` + `HashAlgo` enum are shaped so
  the CID parser and extra hashes (SHA-512/BLAKE3) slot in WITHOUT changing the
  `verify` contract. `explore-web3-capabilities` owns native `ipfs://`.
- **The full networking layer.** Caching, cookies, a real redirect/proxy policy,
  connection pooling as a first-class API, streaming to the parser, request
  cancellation, and the async/event-loop integration are the networking BUILD
  spec's job. `CurlFetcher` here is a blocking one-shot GET — enough to prove the
  pick + the seam.
- **The TLS trust-store / pinning policy.** The floor uses curl's default TLS
  verification (on). How wezig's trust posture (ADR-0011) shapes cert policy,
  and whether content-addressed fetches relax origin trust because verification
  moves to the hash, is a design decision for the build plan, not this spike.

## Recommendation for the build plan

Pin **libcurl (bound, vetted-TLS backend, never write TLS)** as the networking
HTTP+TLS stack, entered through the `net.Fetcher` seam, with content-addressed
fetches verified via `ContentAddress`/`fetchVerified`. Sequence the networking
build AFTER the seam is in place (it already is, from this spike): the first
networking milestone grows `CurlFetcher` into the real client behind the same
seam, and the content-addressed path grows a real CID decoder that constructs a
`ContentAddress` from an `ipfs://…` string — the verify contract this spike
proved is reused unchanged.
