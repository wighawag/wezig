---
title: Odin instead of Zig? — evaluated against ADR-0017's own criteria; Odin loses on the exact axis that made Zig win (C/C++ interop) and does NOT buy the safety Rust would, so it is a worse trade than either incumbent-Zig or the Rust escape hatch
slug: odin-vs-zig-implementation-language-evaluated
---

A follow-on to ADR-0017 (the implementation-language decision) and to the
Rust-vs-Zig conclusion it records. Asked 2026-07-20: "we concluded Zig stays the
glue with Rust available behind a seam if needed — but what about **Odin** instead
of Zig?" This is an IDEA (pre-spec): it changes no code. It records the evaluation
so Odin is not re-raised from scratch, and so the answer is a reason, not a reflex.

Odin appears NOWHERE else in the repo before this note — it is a genuinely new
candidate, not a re-litigation. The verdict below falls straight out of ADR-0017's
existing decision criteria applied to Odin's actual properties (ground-truth as of
Odin 1.0, released Nov 2025).

## The short answer

**No — Odin is a worse trade than keeping Zig, and it does not open the door Rust
would.** ADR-0017 chose Zig on a specific hierarchy of reasons; Odin is *weaker*
on the top reason (C/C++ interop, the whole strategy), *equal* on the reason that
mattered second (manual memory fits the DOM's GC-shaped object graph), and buys
*nothing* on the axis where the only serious case against Zig lives (compile-time
memory safety — the LLM-authorship argument). A move that is worse-or-equal on
every load-bearing axis and better on none is not worth the cost of discarding the
validated Zig foundation (~16k green lines, the seams, the mobile cross-compiles).

## Mapped onto ADR-0017's own criteria

ADR-0017 did not pick Zig for taste; it picked it on a ranked set of reasons.
Score Odin on the SAME ones:

1. **C/C++ interop — Zig's single biggest, most defensible edge, and the whole
   strategy (bind Skia/HarfBuzz/SDL/libcurl/WebKitGTK/wgpu-native/SpiderMonkey).**
   Odin is WORSE than Zig here, and this is decisive:
   - Odin binds C via `foreign import` + `foreign` blocks with **hand-declared
     prototypes** (`proc(...) -> ... ---`). There is **no `@cImport(@cInclude(...))`
     equivalent** — no "point at the header, get the bindings". That is the exact
     friction ADR-0017 held AGAINST Rust ("Rust needs `bindgen`/`cxx` and
     non-trivial glue"). Odin sits on the same wrong side of that line as Rust,
     just with lighter syntax — it is manual-binding, not header-import.
   - **Odin binds C only, not C++** ("but not C++ code, unless wrapped" — its own
     docs). wezig binds C++ engines (Skia, wgpu-native/Dawn, SpiderMonkey). That is
     precisely the C++-interop weakness on which ADR-0017 **rejected Swift**. Odin
     inherits Swift's disqualifier here. Zig can `@cImport` C headers directly and
     link C++ through a C shim with far less ceremony than a from-scratch wrapper
     per engine.
   - Net: on the reason ADR-0017 ranked FIRST, Odin is a downgrade, not a peer.

2. **Zig is also a C/C++ compiler + cross-compiler + build system (`zig build`,
   `zig cc`) — the mobile cross-compile story.**
   Odin has cross-compilation but it is rougher (its own tracker documents
   cross-link gaps, e.g. non-erroring exit codes for unsupported targets), and it
   does NOT ship a bundled C/C++ cross-compiler the way `zig cc` does. wezig
   already cross-compiles SDL3 + the mobile static libs through the Zig toolchain;
   Odin would push that back onto external toolchains — the same fiddliness
   ADR-0017 counted against Rust. Another downgrade.

3. **Manual/arena memory fits the web platform's deep-inheritance + GC-shaped
   object graph (the exact reason Ladybird rejected Rust in 2024).**
   Here Odin is **EQUAL to Zig** — Odin is a manual-memory language (with a
   context/allocator system comparable in spirit to Zig's allocator-as-value). So
   Odin keeps this Zig advantage. But keeping an advantage you already have is not
   a reason to SWITCH; it is a reason the switch buys nothing here.

4. **`comptime` / legibility / no-hidden-control-flow.**
   Roughly a wash: Odin is also simple, explicit, no hidden allocation, with its
   own compile-time facilities. Neither clearly beats the other for wezig's shape.
   No switch justification.

5. **The ONLY serious case against Zig (ADR-0017's LLM-authorship lens): Rust's
   borrow checker is an INDEPENDENT compile-time adversary that catches the
   use-after-free / aliasing class LLMs produce.**
   Odin does **NOT** provide this. Odin is manual-memory, not-memory-safe-by-
   default — the SAME safety posture as Zig. So switching to Odin pays the full
   cost of abandoning the Zig foundation and gets ZERO of the one benefit that
   motivated even considering a move (compile-time safety). If the memory-safety
   posture ever proves insufficient, the pre-agreed answer in ADR-0017 is "move the
   hotspot to **Rust** behind a seam" — because Rust is what actually buys safety.
   Odin is not on that path; it is a lateral move that solves nothing Zig doesn't.

## Where Odin is genuinely nice (and why it still doesn't move the needle)

Honest credit so this isn't a strawman: Odin has real strengths — a pleasant,
Go-flavoured syntax, first-class SoA/array-of-struct + fixed-array/slice/
multi-pointer types, a batteries-included `vendor` collection, and it hit **1.0**
(a stability milestone Zig has NOT — ADR-0017 explicitly banks the "pre-1.0 churn
tax" as an accepted, mitigated cost). The 1.0 point is the strongest single thing
Odin has over Zig: no breaking-minor churn, and (relevant under LLM authorship)
less risk of the model writing code against a stale language version.

But that one advantage does not clear the bar to SWITCH:
- It is a maturity/ergonomics win, not a capability win — and ADR-0017 already
  chose to pay Zig's churn tax with eyes open (pinned toolchain + version guard).
- It is dwarfed by the interop regression (#1) and the cross-compile regression
  (#2), both of which hit wezig CONSTANTLY (every bound engine, every mobile
  target), whereas the churn tax is a bounded per-bump cost.
- It does nothing for safety (#5), so it is not even a partial answer to the one
  real critique of the Zig choice.

## Conclusion / recommendation

**Keep Zig; do not switch to Odin.** The ADR-0017 decision is unchanged. The
language reversibility that matters is already recorded: the seams are the escape
hatch, and the pre-agreed escape target is **Rust behind a seam** (it buys
compile-time safety), not Odin (it buys nothing Zig lacks while costing the
interop edge that IS the strategy).

If a future reader wants to record this durably in the decision log rather than as
a pre-spec note, the natural home is a one-line "Considered alternatives" addition
to ADR-0017 alongside Rust / C++ / Swift:

> **Odin.** Manual-memory like Zig (so it keeps Zig's object-graph fit) but with
> hand-declared C bindings and no C++ interop (the Swift disqualifier) and rougher
> cross-compilation — worse on interop/cross-compile, equal on memory model, and
> zero memory-safety gain over Zig. It is a lateral move that surrenders Zig's
> biggest edge without buying Rust's biggest one; rejected.

This note changes no code and pins no ADR by itself; promoting the paragraph into
ADR-0017 is a human/`to-spec` call.
