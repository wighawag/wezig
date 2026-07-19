<!-- dorfl-sidecar: item=task:spike-webkitgtk-sw-scheme-patch-locate-and-draft type=task slug=spike-webkitgtk-sw-scheme-patch-locate-and-draft allAnswered=false -->

## Q1

**'task:spike-webkitgtk-sw-scheme-patch-locate-and-draft' was bounced — how should we proceed?**

> PR/code review (Gate 2) blocked this work:
> - The task record was moved to work/tasks/done/spike-...-locate-and-draft.md, but its three deliverable sidecar files (webkitgtk-sw-scheme-capable.patch, patch-size-and-footprint.md, upstream-proposal-draft.md) were CREATED under work/tasks/ready/spike-...-locate-and-draft/ — the OLD status folder. So a done task's acceptance artifacts are stranded in ready/, splitting one item across two status folders. This violates the status=folder / one-item-one-location contract and leaves the deliverables sitting in a claimable-looking location. Relocate the sidecar dir to done/ (or wherever the task .md lives) so status is coherent. Fix is a git mv; files are reachable via glob today so content is intact. (git show a3b862a: rename ready->done for the .md, but new-file adds for the sidecar under work/tasks/ready/spike-.../)
> PR/code review (Gate 2) did not reach a unanimous approve across reviewMaxRounds=2 round(s) (a block is terminal and is never re-rolled); forcing needs-attention (never silently merged or looped).

<!-- q1 fields: id=q1 kind=stuck -->

**Your answer** (write below this line):
