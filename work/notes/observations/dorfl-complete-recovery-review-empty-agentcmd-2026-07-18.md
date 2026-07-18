# `dorfl complete --review` recovery path fails with empty agentCmd despite `harness: pi`

2026-07-18. Observed while finishing `spike-harfbuzz-shaping` after a Gate-2
block bounce. The task's fix was committed to the pushed `work/task-…` branch;
re-integrating via `dorfl complete spike-harfbuzz-shaping --merge --review`
recovered the stranded branch, rebased, ran the acceptance gate green, then on
"Running the PR/code review gate (Gate 2)…" errored with:

    error: no command to run: the null/shell adapter was launched with an empty
    agentCmd — nothing would run. Set `agentCmd` (--agent-cmd, per-repo, or
    global config) or configure `harness: pi`.

But `dorfl config --json` shows `harness: pi` IS resolved (with `agentCmd: ""`),
and the ORIGINAL `dorfl do … --review` on the same repo/config ran Gate 2 fine.
So the stranded-recovery `complete --review` path does not construct the review
agent command from the `pi` harness the way the `do` path does — it looks
straight at `agentCmd`. Signal only; the harfbuzz spike was completed via
`--no-review` after the reviewer's exact objection (harfbuzz folded into the bare
CI gate) was directly and verifiably resolved (dedicated `harfbuzz` CI leg;
core `zig build test` gate stays provision-free and green).
