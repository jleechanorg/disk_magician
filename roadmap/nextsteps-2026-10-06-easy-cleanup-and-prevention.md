# Nextsteps — disk_magician — 2026-10-06

## Table of contents

- [Executive summary](#executive-summary)
- [Context](#context)
- [Bead index](#bead-index)
- [Work queue](#work-queue)
- [Timeline and parallel lanes](#timeline-and-parallel-lanes)
- [PR / merge state](#pr--merge-state)
- [Learnings pointer](#learnings-pointer)
- [Roadmap pointer](#roadmap-pointer)

## Executive summary

- **Outcomes**: Reclaimed **+63.0 GiB** net disk space, dropping used space from 879 GiB to 816 GiB and expanding available headroom from **8.7 GiB (100% capacity)** to **74 GiB (92% capacity)**. Merged and deployed PR #110 (`v0.2.137`) for squash-merged worktree eligibility and closed bead `disk_magician-ueh`. Un-wedged Colima VM and recovered guest-level I/O error (`-EIO`), then executed in-VM `fstrim -av` to discard 11.5 GiB of sparse datadisk blocks. Ran full 6-tier routine cleanup stack (`diskm clean`) sweeping 510 worktrees, pruning eligible merged worktrees, stripping dormant `.venv`s, and clearing dev caches.
- **Root Cause & Fast-Fill Attribution**: Fast fill is driven by 3 vectors: (1) 6 local GitHub Actions runner containers executing CI inside Colima whose sparse datadisk expands on write but never auto-shrinks on delete; (2) agent worktree generation velocity (235 worktrees created in last 7 days = ~94 GiB inflow, held by the 7-day safety floor); (3) monotonic agent session/SQLite growth (`thread_history_1.sqlite` at 13 GiB with 1.64M rows; `~/.codex/sessions` added 17 GiB in September and 5.9 GiB in October).
- **Easy Stuff Focus**: Prioritizing immediate, low-friction, high-yield preventive automations:
  1. Automate periodic in-VM `fstrim` in main sweeper (`disk_magician-mux`).
  2. Shorten recency floor for *verified squash-merged* PR worktrees from 7d to 3d (`disk_magician-plf`).
  3. Bound depth-4 agent worktree discovery in `cleanup_worktree_venvs.sh` (`disk_magician-9h3`).
  4. Add post-job workspace pruning in `ezgha-runner` (`disk_magician-d5m`).
- **Beads**:
  - [disk_magician-mux](https://github.com/jleechanorg/disk_magician/issues) (P1: Automate periodic Colima fstrim in main sweeper)
  - [disk_magician-plf](https://github.com/jleechanorg/disk_magician/issues) (P1: Shorten verified-merged worktree floor 7d → 3d)
  - [disk_magician-9h3](https://github.com/jleechanorg/disk_magician/issues) (P2: Bound cleanup_worktree_venvs discovery loop)
  - [disk_magician-d5m](https://github.com/jleechanorg/disk_magician/issues) (P2: ezgha-runner post-job prune hook)
  - [disk_magician-ueh](https://github.com/jleechanorg/disk_magician/issues) (P2: Closed — PR #110 merged & deployed)

## Context

This work block resolved an emergency disk-fill crisis on `/System/Volumes/Data` where available space had fallen to 8.7 GiB (100% capacity). The session landed PR #110 to enable squash-merged PR worktree eligibility, deployed package version `0.2.137`, repaired launchd plists from templates, diagnosed the guest-level `chmod /var/lib/docker: input/output error` inside Colima, recovered the VM via `colima stop && colima start`, and executed in-VM `fstrim -av` to reclaim 11.5 GiB directly back to APFS host blocks. A full execution of `./disk_magician.sh clean` reclaimed an additional 51.5 GiB across all 6 tiers. Analysis of telemetry revealed the root causes of fast refill, and this roadmap establishes the high-yield, low-friction preventive safeguards.

## Bead index

| Bead | Title | Priority | Status | Link |
|---|---|---|---|---|
| `disk_magician-mux` | Colima: automate periodic in-VM fstrim in main sweeper to prevent sparse datadisk ballooning | P1 | OPEN | `br show disk_magician-mux` |
| `disk_magician-plf` | Worktrees: shorten verified-merged PR recency floor from 7d to 3d in cleanup_worktrees.sh | P1 | OPEN | `br show disk_magician-plf` |
| `disk_magician-9h3` | cleanup_worktree_venvs: replace unbounded depth-4 find with shallow repo traversal | P2 | OPEN | `br show disk_magician-9h3` |
| `disk_magician-d5m` | ezgha-runner: add post-job workspace and cache prune to prevent Colima datadisk fill | P2 | OPEN | `br show disk_magician-d5m` |
| `disk_magician-ueh` | cleanup_worktrees.sh: classify squash-merged PR worktrees as eligible | P2 | CLOSED | `br show disk_magician-ueh` |

## Work queue

1. **Automate Periodic Colima `fstrim` in Main Sweeper** — tracks [`disk_magician-mux`](#bead-index)
   - **Goal**: Prevent Colima sparse datadisk (`~/.colima/_lima/_disks/colima/datadisk`) from ever exceeding ~5–8 GiB by periodically issuing `colima ssh -- sudo fstrim -av` (or via active Lima SSH mux socket) in `scripts/main_sweeper.sh` / `scripts/pressure_sweep.sh`.
   - **Acceptance Criteria**:
     - Main sweeper checks if Colima VM and Docker socket are responsive.
     - Runs `fstrim -av` if datadisk allocated size > 8 GiB or during pressure sweeps.
     - Logs trimmed bytes into sweeper receipt.
     - Never hangs if Colima is stopped or paused (bounds timeout to 30s).
   - **Files**: `scripts/main_sweeper.sh`, `scripts/pressure_sweep.sh`, `scripts/cleanup_colima.sh`.
   - **Dependencies**: None. Can be implemented immediately.

2. **Shorten Verified-Merged PR Worktree Recency Floor (7d $\rightarrow$ 3d)** — tracks [`disk_magician-plf`](#bead-index)
   - **Goal**: Reclaim ~30–45 GiB of disk space by reducing the retention of *verified squash-merged* PR worktrees from 7 days to 3 days, while preserving unpushed, active, or open PR worktrees for the full 7-day floor.
   - **Acceptance Criteria**:
     - When `classify_candidate` in `scripts/worktree_hygiene.sh` and `classify_repo_local_worktree` in `scripts/cleanup_worktrees.sh` confirm that a worktree has a GitHub-verified merged PR with identical `headRefOid`, apply a minimum stale floor of 3 days instead of 7 days.
     - If the PR is not merged, head differs, branch has unpushed commits, or working tree is dirty, strictly enforce the full 7-day protection floor.
     - Unit test in `tests/test_cleanup_worktrees_repo_local.sh` asserting a 4-day-old merged worktree is ELIGIBLE while a 4-day-old unmerged worktree is PRESERVED.
   - **Files**: `scripts/cleanup_worktrees.sh`, `scripts/worktree_hygiene.sh`, `tests/test_cleanup_worktrees_repo_local.sh`.
   - **Dependencies**: Builds on PR #110 (`disk_magician-ueh`).

3. **Bound `cleanup_worktree_venvs.sh` Agent Worktree Discovery Loop** — tracks [`disk_magician-9h3`](#bead-index)
   - **Goal**: Eliminate the 16-minute stall in `cleanup_worktree_venvs.sh` caused by line 239 traversing deep `node_modules` and `.git` subtrees looking for `*/.claude/worktrees`.
   - **Acceptance Criteria**:
     - Replace recursive `find "$root" -mindepth 1 -maxdepth 4 -type d -path '*/.claude/worktrees'` with bounded shallow traversal (`for repo in "$root"/*; do ... "$repo/.claude/worktrees"`), matching PR #106 (`worktree_repo_discovery.sh`).
     - Reduce discovery phase execution time from >900s to <2s.
   - **Files**: `scripts/cleanup_worktree_venvs.sh`, `tests/test_cleanup_worktree_venvs.sh`.
   - **Dependencies**: None.

4. **Ephemeral CI Runner Workspace and Cache Prune** — tracks [`disk_magician-d5m`](#bead-index)
   - **Goal**: Prevent local GitHub Actions runners from accumulating multi-gigabyte build artifacts inside Colima datadisk between jobs.
   - **Acceptance Criteria**:
     - In `ezgha-runner` container entrypoint / post-job handler, wipe `/home/runner/_work/*` following successful or failed job completion.
     - Ensure container exit or idle transition discards temporary checkout trees.
   - **Files**: Runner deployment configuration, `scripts/post_job_docker_prune.sh`.
   - **Dependencies**: None.

## Timeline and parallel lanes

| Elapsed estimate | Lane / owner | Scope / dependencies | Deliverable / proof |
|---|---|---|---|
| +15m | Lane A (Colima fstrim automation) | `scripts/cleanup_colima.sh`, `scripts/main_sweeper.sh` | Main sweeper executes automated fstrim; verified by test run |
| +20m | Lane B (Merged PR 3d floor) | `scripts/cleanup_worktrees.sh`, `tests/test_cleanup_worktrees_repo_local.sh` | 3d floor applied to merged worktrees; test suite green |
| +10m | Lane C (Venv discovery bound) | `scripts/cleanup_worktree_venvs.sh` | Discovery time drops from 16m to <2s; tests pass |
| +30m | Integration & Verification | Package sync (`sync_package_tree.sh`), bump to `0.2.138`, deploy | `tools/deploy_uv_tool.sh` verified on clean origin/main |

- **Critical Path**: Lane B (worktree policy) $\rightarrow$ Integration & deploy.
- **Concurrency Ceiling**: 3 independent coder subagents can run Lanes A, B, and C in parallel without file collisions.
- **Milestones**:
  - +20m: Lanes A & C complete and verified locally.
  - +40m: Lane B test suite complete.
  - +60m: Hourly rollup; PR opened, CI green, package deployed.

## PR / merge state

- https://github.com/jleechanorg/disk_magician/pull/110 — MERGED (`32ff7b5c3d3ed5987c12024cd5b086e99740723c`, squash-merged worktree eligibility)
- https://github.com/jleechanorg/disk_magician/pull/108 — MERGED (`b5f6d303580832e8e36094ca7206f0accde3f1ae`, single unified main disk sweeper)
- https://github.com/jleechanorg/disk_magician/pull/109 — MERGED (`9b5963fc2330a84d4128feea74cce9b1f5e88849`, converge apfs/docker/antigravity scripts)
- https://github.com/jleechanorg/disk_magician/pull/112 — MERGED (`33620005a7678560000a6ee92cce53a5160c8859`, worktree guard destination naming)

## Learnings pointer

- `/Users/jleechan/roadmap/learnings-2026-10.md` — section `2026-10-06 — Colima VM guest I/O wedging and APFS sparse datadisk reclaim`
  - Documents that APFS sparse datadisks never auto-shrink on guest file deletion without `fstrim -av`, and that 100% host disk fullness causes guest overlayfs `-EIO` wedging that requires VM restart.

## Roadmap pointer

- Appended `/Users/jleechan/projects_other/disk_magician/roadmap/activity/2026-10-06.md`
- Added `[2026-10-06](activity/2026-10-06.md)` to `/Users/jleechan/projects_other/disk_magician/roadmap/README.md`
