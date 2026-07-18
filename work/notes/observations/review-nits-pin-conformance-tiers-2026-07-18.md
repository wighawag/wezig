---
title: review-gate non-blocking nits for 'pin-conformance-tiers' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: pin-conformance-tiers
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'pin-conformance-tiers' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: the agent pinned EXACT WPT thresholds and specific WPT directory subsets (T1 >=90% html/syntax/parsing + >=70% core-CSS areas; T2 >=85%/>=80%; T3 >=75% dom/fetch) that the task did not specify (it asked only for 'a WPT-subset bar' per tier). Reasonable and reversible, but a human should confirm these numbers/areas are the intended bars.
  (docs/conformance-tiers.md T1-T3 WPT-subset bar sections; task acceptance only required a WPT-subset bar exists per tier.)
- Ratify: the T0 content-addressed floor is framed as the authored v0 fixture loaded through the content-addressed resolution seam, standing in for an ipfs://-served document, because v0 has no networking. This is an honest reconciliation of the 'every tier names an ipfs:// page' requirement against v0 reality rather than a real CID fetch. Confirm this stand-in framing is acceptable for T0.
  (docs/conformance-tiers.md T0 'Content-addressed floor' bullet; docs/v0-subset.md confirms v0 networking is out of scope.)
- Ratify: concrete exemplar sites were pinned (motherfuckingwebsite.com, MDN, Wikipedia, web.dev) as representative pages. Task asked for representative pages with a pinnable exemplar; the doc correctly labels them representative-not-exhaustive and allows build-spec substitution. Confirm the exemplar choices are fine.
  (docs/conformance-tiers.md T1/T2 page checklists; doc notes exemplars are representative and a build spec MAY add pages but MUST NOT drop categories without a new ADR.)
