---
title: Snapshot coverage below gate is a global-budget exhaustion, fixed by sharded measurement
hostname: jeffreys-macbook-pro
date: 2026-10-20
status: mitigated
paths:
  - ~/.disk_magician_backup/snapshots/disk_snapshot.json
  - ~/.disk_magician_state/last_good_measurements.json
  - ~/projects
  - ~/.worktrees
  - /private/var
  - /private/tmp
safety_rule: none
---

## What

The 2026-10-20T05:56Z snapshot reported coverage 41.8% (gate 70%), `measurement_status=partial`,
147/196 paths ok, `measurement_budget_exhausted=true`, 2 workers. `measurement_path_max_seconds` was 0,
so the recorded cause (a 20 s per-path cap) was not what happened. Of 88 failed attempts across 44
keys, 85 were `orchestrator_deadline` (the run ran out of its overall 1500 s budget before the key got
time) and only 3 were `backend_timeout` (`nvm`, `projects_reference`, `library_home`). The failed keys
carry about 471.5 GiB of last-good size; those at or above 20 GiB are worktrees_dot (104.3), projects
(57.3), private_var (55.1), applications (30.3), library_app_support (23.3), colima (23.1),
system_data_volume (21.3), library_cloudstorage (20.0). Each was measured as one serial whole-root
`du`, so a few huge roots starved every key queued behind them.

## Why it matters

Floors and per-path deltas are unusable below 70% coverage. Raising a single per-path cap only moves the
starvation; the work has to be split into independently bounded pieces that run concurrently.

## Guards / governance

`scripts/snapshot_measure.py` now measures a root as parallel depth-1 shards when its last-good size is
at least 20 GiB, it timed out last run, or its whole-root probe timed out. Shards run with a short
timeout (`DISK_MAGICIAN_SHARD_TIMEOUT_SECONDS`, default 30) and a pool of 4 (`DISK_MAGICIAN_MEASURE_WORKERS`),
capped at half the cores and 1 under memory pressure >= 3 or 5-minute load > 4x cores. The parent sums the
shards; a timed-out shard keeps its last-good value (state in `~/.disk_magician_state/shard_last_good.json`)
flagged stale, and the parent appears in `snapshot_metadata.measurement_failures` with `status=partial`
and `timed_out_shards`. Tests: `tests/test_snapshot_measure_sharded.py`. Bead
disk_magician-snapshot-coverage-below-gate-0c4f. Consecutive sub-70% alert already exists
(`scripts/disk_status.py`, commit 8b7fd28; tests in `tests/test_disk_status.py`).

## History

- 2026-10-20 - discovered the budget-exhaustion cause from snapshot metadata; sharded measurement added.
