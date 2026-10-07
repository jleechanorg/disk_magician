# Situational Assessment & Roadmap Update: Disk Cleanups & Automation Gaps (2026-10-03)

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Current Disk Capacity & 90-Day Floor Attribution](#current-disk-capacity--90-day-floor-attribution)
3. [Triage Actions & Reclaimed Capacity](#triage-actions--reclaimed-capacity)
4. [Root Causes: Why Cleanups Were Not Automated](#root-causes-why-cleanups-were-not-automated)
5. [Automated Remediation & Engineering Lanes](#automated-remediation--engineering-lanes)
6. [Beads Tracking & Next Steps Queue](#beads-tracking--next-steps-queue)

---

## Executive Summary
Following acute workstation disk pressure (99% capacity, 875 GiB used, 13 GiB free), an empirical forensic investigation and multi-lane cleanup was executed. Reclaimed **+21 GiB net**, reducing disk use to 854 GiB and increasing available free capacity to **27 GiB**.

Key accomplishments:
- **11.5 GiB freed**: Purged 11 orphaned shadow checkouts and review-council test clones in `~/.cache/wiki-publish`, and permanently integrated the directory into `scripts/cleanup_dev_caches.sh` and `config/sweeper_roots.txt` ([disk_magician-wd4](https://github.com/jleechanorg/disk_magician/issues/wd4)).
- **4.89 GiB freed**: Compacted `~/.codex/logs_2.sqlite` online via `PRAGMA incremental_vacuum` and `PRAGMA wal_checkpoint(TRUNCATE)`, shrinking the database from 5.3 GiB to 410 MiB without session locks ([disk_magician-oh2](https://github.com/jleechanorg/disk_magician/issues/oh2)).
- **2.07 GiB freed**: Purged 22 dormant ($\ge 7$d) state workdirs in `~/.claude/state` while preserving 21 active, stashed, and unpushed branches ([disk_magician-7a3](https://github.com/jleechanorg/disk_magician/issues/7a3)).
- **3.1 GiB freed**: Pruned Colima Docker containers and ran in-VM `fstrim -av` to shrink the host sparse disk.
- **Safety Invariants Enforced**: Audited 136 linked worktrees across `~/projects`; all 136 were preserved (ahead of main, dirty, untracked, or <7d). Inspected 9 worktree venvs; all 9 were preserved (8 base repositories, 1 <7d).

---

## Current Disk Capacity & 90-Day Floor Attribution

### Floor Measurement
- **90-day ledger floor**: 672.6 GiB used (commit `e04291d` on 2026-08-03).
- **Valid-coverage snapshot floor**: 715 GiB used @ 71.3% coverage (commit `03a17fe` on 2026-09-13).
- **Pre-clean used**: 875 GiB.
- **Pre-clean delta over 90d floor**: **+194.4 GiB**.
- **Post-clean used**: **854 GiB** (net reclaimed: **21 GiB**).

### Delta Attribution Breakdown
| Directory | Pre-Clean Size | Net Growth vs Floor | Primary Drivers |
| :--- | :--- | :--- | :--- |
| `~/projects` | 275.6 GiB | +111.1 GiB | 571 linked agent worktrees, dirty checkouts, unmerged branches |
| `~/.codex` | 54.4 GiB | +51.9 GiB | SQLite incremental vacuum bloat in `logs_2.sqlite` (4.88 GiB) + active `thread_history_1.sqlite` (11 GiB) |
| `~/.claude/state` | 20.9 GiB | +20.9 GiB | Per-task workdirs lacking launchd sweeper automation |
| `~/.cache` | 36.4 GiB | +16.5 GiB | Unregistered shadow checkouts and test clones in `~/.cache/wiki-publish` (11.5 GiB) |
| `~/.dark-factory/runs` | 14.9 GiB | +14.9 GiB | Accumulated test suite trace artifacts |

---

## Triage Actions & Reclaimed Capacity

1. **Wiki-Publish Scratch & Shadow Clones**:
   - Identified 11 disposable clones created during PR #29 tests and `/advice` review council runs.
   - Preserved `advice/` PR review records (3.7 MB).
   - Purged `deploy-mac`, `local-ci`, `rc`, `rc-ga`, `rc-gb`, `rc-gc`, `rc-gm`, `rc-rs`, `rc-wa`, `shadow`, `wt`, and `wt-resolve`.
   - **Reclaimed**: **11.5 GiB**.

2. **Codex SQLite Online Compaction**:
   - `logs_2.sqlite` had 1,280,277 freelist pages (4.88 GiB).
   - Executed `PRAGMA busy_timeout=30000; PRAGMA incremental_vacuum;` followed by `PRAGMA wal_checkpoint(TRUNCATE);`.
   - Shrunk `logs_2.sqlite` from 5.3 GiB to 410 MiB and WAL from 4.7 GiB to 1.5 MiB.
   - **Reclaimed**: **4.89 GiB**.

3. **Claude State Workdirs**:
   - Ran `scripts/cleanup_claude_state.sh --clean`.
   - Purged 22 dormant dirs ($\ge 7$d inactive); preserved 21 active checkouts.
   - **Reclaimed**: **2.07 GiB**.

4. **Colima VM Trim & Routine Dev Caches**:
   - Trimmed Colima datadisk (+3.1 GiB).
   - Cleaned Aside browser sessions (+200 MB), Antigravity brain logs (+157 MB), and Node build caches (+43 MB).
   - **Reclaimed**: **~3.5 GiB**.

---

## Root Causes: Why Cleanups Were Not Automated

1. **Worktree Hygiene (`cleanup_worktrees.sh`)**:
   - The launchd job `com.jleechanorg.disk-magician-worktree-hygiene.plist` is intentionally configured as **REPORT-ONLY** (`--skip-push --skip-gh`). Automated deletions are disabled to avoid destroying in-progress human or agent work.
   - In addition, all 136 worktrees on disk failed the required merge/cleanliness safety gates (unmerged branches, unpushed commits, or uncommitted files).

2. **Worktree Venvs (`cleanup_worktree_venvs.sh`)**:
   - Automated via `com.disk-magician.worktree-venvs.plist`, but scheduled only once every 7 days (`StartInterval=604800`). Venvs created mid-week persist until the next run.
   - Preserves base repositories (8 found) and worktrees active within 7 days.

3. **Claude State (`cleanup_claude_state.sh`)**:
   - Created under bead `disk_magician-isw` as a manual CLI script requiring `CLAUDE_STATE_APPROVED=1`.
   - **No launchd job was ever configured**, leading to 20+ GiB of unchecked accumulation.

4. **Wiki-Publish Scratch Caches (`~/.cache/wiki-publish`)**:
   - Unregistered staging path created by new publishing tooling on Oct 2.
   - Omitted from `scripts/cleanup_dev_caches.sh` and `config/sweeper_roots.txt`.

5. **Codex SQLite Database Compaction**:
   - `~/.codex` is protected under the hard `never_delete` invariant.
   - Hermes has an automated vacuum sweeper, but no sweeper existed for Codex SQLite DBs, leaving freelist pages uncompacted.

---

## Automated Remediation & Engineering Lanes

### Lane 1: Wiki-Publish Cache Sweeper Integration (Complete)
- Added `~/.cache/wiki-publish` section to `scripts/cleanup_dev_caches.sh`.
- Added `$HOME/.cache/wiki-publish` to `config/sweeper_roots.txt`.
- Verified 14/14 tests pass in `tests/test_check_uncovered_roots.py`.
- Closed bead `disk_magician-wd4`.

### Lane 2: Codex SQLite Compaction Sweeper (In Progress via Subagent 1)
- Building `scripts/cleanup_codex_db.sh` to safely inspect freelist pages and run non-blocking `incremental_vacuum` and `wal_checkpoint(TRUNCATE)`.
- Adding `launchd/com.disk-magician.codex-vacuum.plist.template` and test suite `tests/test_cleanup_codex_db.sh`.
- Tracking under bead `disk_magician-oh2`.

### Lane 3: Claude State Launchd Automation (In Progress via Subagent 2)
- Building `launchd/com.disk-magician.claude-state.plist.template` with `CLAUDE_STATE_APPROVED=1`.
- Registering job in `scripts/install_launchd_sweepers.sh` and verifying with `check-launchd-fleet`.
- Addressing wrapper test failure coverage (`disk_magician-p0v`).
- Tracking under bead `disk_magician-7a3`.

---

## Beads Tracking & Next Steps Queue

| Bead ID | Priority | Status | Component | Action |
| :--- | :--- | :--- | :--- | :--- |
| `disk_magician-wd4` | P2 | closed | `cleanup_dev_caches.sh` | Registered `~/.cache/wiki-publish` in dev cache sweeper & sweeper roots |
| `disk_magician-oh2` | P2 | open | `cleanup_codex_db.sh` | Implement automated Codex SQLite vacuum sweeper & launchd job |
| `disk_magician-7a3` | P2 | open | `cleanup_claude_state.sh` | Wire launchd sweeper for Claude state to close launchd gap |
| `disk_magician-p0v` | P3 | open | `test_cleanup_claude_state.sh` | Test standalone failure handling in wrapper |
| `disk_magician-8to` | P2 | open | Colima swap & datadisk | Investigate VM swapfile growth and automated Colima pressure sweep |
