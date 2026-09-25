---
title: Verifier/review lanes should use git worktree, not full clone (~/.claude/state)
hostname: jeffreys-macbook-pro.local
date: 2026-09-23
status: active
paths:
  - ~/.claude/state
safety_rule: none yet — in-repo fix approved, not yet implemented (bead disk_magician-orchestrator-worktree-not-clone-2nw)
---

## What

Interactive orchestrator sessions' codex/agy verifier lanes create full
`git clone` copies (including `node_modules`) of the target repo under
`~/.claude/state`, one per verifier task, with no cleanup on exit. Measured
+15.6 GiB born 2026-09-15..09-22 (34.1 GiB total at measurement time), one of
the top producers behind the +103 GiB/7-day disk-fill root cause (bead
disk_magician-isw). An unattributed later actor manually removed ~18 GiB of
these, which is not a durable fix — the pattern keeps recurring because the
producer (orchestrator lane spawning) is unchanged.

## Why it matters

Each verifier lane pays a full clone + `node_modules` install (~5 GiB each)
for work that only needs read access to a specific ref plus the ability to
run tests — a `git worktree add <path> <ref>` against the existing checkout
gets the same isolation at a fraction of the disk cost and removes cleanly
via `git worktree remove`. The exact placement matters: spec section A2
(see Guards / governance) went through several corrections before landing
on `/private/var/tmp/agent-worktrees` as the default root, after finding
that both `/private/tmp/agent-scratch` (subject to size-budget eviction and
a Stop hook, neither worktree-aware) and plain `/private/tmp` (scanned and
archive-purged by `cleanup_tmp.sh --large`) risked deleting a worktree with
unpushed work inside this repo's 7-day protection window — see A2's own
text for the current authoritative default before implementing against
this finding.

## Guards / governance

PR #74 (bead disk_magician-isw) adds a *reactive* sweeper
(`cleanup_claude_state.sh`, 7-day floor) for the symptom. The producer-side
fix was originally scoped as a cross-repo, approval-gated bead against a
separate orchestrator repo — that framing was **redesigned and corrected
2026-09-24** (spec section A2,
docs/superpowers/specs/2026-09-23-disk-fill-prevention-and-scheduled-cleanup-design.md):
there is no separate owning orchestrator repo; the clones are produced by ad
hoc interactive Claude Code/Codex sessions spawning verifier lanes, and the
fix ships **in this repo** as `scripts/lib/agent_worktree.sh`
(`agent_worktree_create <label> <ref> <repo>`) — an in-repo helper any such
session can call instead of `git clone`. Tracked by beads disk_magician-9n1
(TEST) and disk_magician-orchestrator-worktree-not-clone-2nw (IMPL, approved
2026-09-24). Not yet implemented as of this doc's last update — no
`scripts/lib/agent_worktree.sh` exists on main yet.

## History

- 2026-09-22 — +15.6 GiB growth measured, root-caused to ad hoc full clones
  by verifier lanes.
- 2026-09-23 — finding documented; producer-side fix originally scoped as a
  cross-repo approval-gated bead (framing later found incorrect).
- 2026-09-24 — fix redesigned in-repo (spec section A2): no separate
  orchestrator repo exists; ships as `scripts/lib/agent_worktree.sh` in this
  repo instead. Approved, not yet implemented.
