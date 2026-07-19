---
title: Memory-safety posture — sandbox + fuzz every attacker-facing component (the obligation Zig-not-safe-by-default creates)
slug: memory-safety-posture-sandbox-and-fuzz-attacker-facing-components
---

A pre-spec design constraint the `WezigRenderer` build + the wallet build MUST
carry, recorded as the concrete consequence of ADR-0017 (implementation language
= Zig, which is NOT memory-safe by default) meeting ADR-0011 (wezig parses the
most hostile input on the web and does not trust the origin). Raised with the
"is Zig the right choice?" question 2026-07-19. This is an IDEA (pre-spec): it
does not change current code; it puts the safety posture on the charter of the
follow-on builds so it is designed in, not bolted on.

## The core obligation

Zig gives `defer`, safety-checked builds (`ReleaseSafe`, UBSan), and
allocator-as-value discipline, but it is NOT memory-safe by default the way Rust
is (or Swift, which is why Ladybird moved to it — ADR-0017). For MOST of wezig
that is an acceptable trade (the commodity engines that eat the scariest input —
the JS VM, Skia, HarfBuzz — are BOUND, mature, and fuzzed by their own upstreams,
not owned). But for the small surface wezig DOES own that eats
ATTACKER-CONTROLLED bytes across a trust boundary, the language choice obliges an
explicit, mandatory posture — process isolation + continuous fuzzing — as the
substitute for compile-time memory safety.

## Which components are attacker-facing (the scope)

The rule: any code that PARSES bytes wezig did not author, ESPECIALLY across a
trust boundary. Concretely:

- **The wallet BROKER's wire parser.** It receives request lines from the
  untrusted page/content process (ADR-0015 d.5). It already runs in its OWN
  process/sandbox (the topological win is pinned), but its PARSER of the
  request envelope is attacker-reachable and must be fuzzed. (The spike used a
  hand-rolled flat-JSON parser, flagged for `std.json` in the build — that swap is
  part of this posture: a vetted parser + a fuzz harness, never a hand-rolled one
  on the security boundary.)
- **The content PARSERS wezig owns in `WezigRenderer`** — the HTML tokeniser/tree
  builder, the CSS tokeniser/parser, and any URL/CID/IPNS decoder. These eat
  arbitrary page bytes; a memory bug here is a browser-class RCE.
- **Any custom-scheme handler body path** (`ipfs://` served bytes are
  hash-VERIFIED, which helps — but the decoder that turns an `ipfs://…` string
  into a `ContentAddress` still parses untrusted input).

NOT in scope (bound + upstream-fuzzed): SpiderMonkey/JSC (JS), Skia (paint),
HarfBuzz (shaping), libcurl+TLS (network) — their memory safety is their
upstreams' job; wezig's job is to keep them behind seams and updated.

## The posture (what the build specs must adopt)

1. **Process isolation first.** Attacker-controlled parsing must not share an
   address space with SECRETS. The broker is already isolated (ADR-0015 d.5);
   generalise it — the owned content engine should run parsing under OS sandboxing
   where the platform allows (seccomp/bubblewrap on Linux, the platform sandbox
   elsewhere), so a parser memory bug cannot directly reach key material or the
   filesystem. A crash is contained, not a compromise.
2. **Continuous FUZZING of every owned attacker-facing parser.** A fuzz harness
   (coverage-guided; Zig's build can drive libFuzzer/AFL-style targets or Zig's
   own fuzzing as it matures) run in CI as a DEDICATED leg (like the other
   provisioned legs, ADR-0007), seeded with a corpus + the crashers it finds. This
   is the substitute for the compile-time safety Zig doesn't give: find the memory
   bugs before an attacker does.
3. **Safety-checked builds on the security paths.** Ship the broker + the parsers
   built `ReleaseSafe` (safety checks ON, not `ReleaseFast`) so an out-of-bounds /
   overflow traps deterministically instead of becoming an exploit primitive.
   Accept the perf cost on these paths; it is the right trade for a trust boundary.
4. **Never hand-roll crypto or security-critical parsers** (already pinned for
   crypto, ADR-0015 d.3) — bind vetted primitives; use `std.json`-class parsers,
   not bespoke ones, on the boundary.

## Why this is in-thesis (not paranoia)

ADR-0011 makes "don't trust the origin" wezig's whole reason to exist. A browser
that mistrusts the SERVER but has a memory-unsafe parser eating the server's bytes
has moved the trust problem, not solved it. The safety posture is the
implementation-level expression of the same thesis: verify + isolate what you
cannot trust. It is also the honest answer to "why Zig despite no default
memory-safety" (ADR-0017) — the safety is RECOVERED for the small owned surface by
isolation + fuzzing, which is a defensible engineering position ONLY if it is
actually designed in. Hence this note, so the follow-on builds cannot forget it.

## Scope / status

- IDEA, pre-spec. It adds a design constraint the `WezigRenderer` build spec and
  the wallet build spec must carry (a fuzzing CI leg + a sandbox posture +
  ReleaseSafe on the security paths + no hand-rolled boundary parsers). It does NOT
  change current code.
- Referenced by ADR-0017 (the language decision's memory-safety consequence). When
  the `WezigRenderer` / wallet build specs are authored, fold this in as explicit
  acceptance criteria and discharge this note.
