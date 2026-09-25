---
title: Verifier/review lanes should use git worktree, not full clone (~/.claude/state)
hostname: jeffreys-macbook-pro.local
date: 2026-09-23
status: active
paths:
  - ~/.claude/state
safety_rule: none — cross-repo fix, not enforceable from this repo
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
run tests — a `git worktree add <path> <ref>` against the existing checkout,
combined with a shared/symlinked dependency cache (this repo's own
`scripts/symlink-shared-venvs.sh` is the existing in-repo pattern for the
analogous Python-venv case), gets the same isolation at a fraction of the
disk cost and removes cleanly via `git worktree remove`.

## Guards / governance

None yet in the owning orchestrator repo(s) — disk_magician has no write
access to that code and cannot enforce this fix itself. PR #74 (bead
disk_magician-isw) adds a *reactive* sweeper (`cleanup_claude_state.sh`,
7-day floor) for the symptom; this finding is the *producer-side* fix,
tracked as a separate approval-gated bead against the orchestrator repo(s)
per docs/superpowers/plans/2026-09-23-disk-fill-prevention-and-scheduled-cleanup.md
Task 5 / spec section A2.

## History

- 2026-09-22 — +15.6 GiB growth measured, root-caused to ad hoc full clones
  by verifier lanes.
- 2026-09-23 — finding documented; producer-side fix scoped as a
  cross-repo approval-gated bead (not implemented in disk_magician).
