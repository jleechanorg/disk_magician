---
title: 30-Day Floor Delta Attribution and Reservoir Cleanups
hostname: jeffreys-macbook-pro.local
date: 2026-08-31
status: mitigated
paths:
  - /private/tmp/_disk_magician_archive
  - ~/Library/Application Support/Cursor/snapshots
  - ~/.openclaw/repo-backups
  - ~/llm_wiki.worktrees/beads-rust-bootstrap/target
safety_rule: needs_decision, DEFAULT_HOT_DIRS
---

## What

Top-down comparison between the 30-day disk usage floor (2026-08-03, 672.61 GiB used) and the live state (841 GiB used) identified four massive growth reservoirs:
1. `/private/tmp/_disk_magician_archive` (52.0 GiB): 130 archived directories of temporary PR analyzer/scratch trees created during pressure-sweep runs.
2. `~/Library/Application Support/Cursor/snapshots` (28.4 GiB): Cursor codebase checkpoints and stores.
3. `~/.openclaw/repo-backups` (17.3 GiB): One-time full repository snapshots from historical migration runs (2026-08-01 and 2026-08-27).
4. `~/llm_wiki.worktrees/beads-rust-bootstrap/target` (6.7 GiB): Rust debug compilation artifacts.

Total space reclaimed across all four reservoirs: **~102.4 GiB** (used space dropped from 841 GiB to 739 GiB).

## Why it matters

Without active pruning and observation:
- The quarantine archive in `/private/tmp/_disk_magician_archive` accumulates ~50 GiB within 24 hours of automated sweep runs.
- Cursor snapshot storage grows unboundedly across workspace checkouts.
- Cargo target builds consume 5-10 GiB per active Rust worktree.
- Abandoned migration snapshots in `~/.openclaw/repo-backups` persist indefinitely.

## Guards / governance

1. **Quarantine Archive Purge**: `scripts/cleanup_tmp.sh` now purges aged archives during standard sweeps without waiting for `--large`.
2. **Cursor Snapshot Hygiene**: Governed in `safety.local.json` under periodic review when Cursor is closed.
3. **OpenClaw Backups**: Tracked under `needs_decision` in `safety.local.json.template` and observed in `DEFAULT_HOT_DIRS`.
4. **Rust Target Builds**: Cargo worktree target directories are tracked and scrubbed on demand via `cargo clean`.
5. **Disk Observer**: All four paths are monitored via `DEFAULT_HOT_DIRS` in `scripts/disk_observer.py`.

## History

- 2026-08-31 — Investigated 30-day floor delta (+185 GiB gap). Purged 52.0 GiB tmp archives, 28.4 GiB Cursor snapshots, 17.3 GiB OpenClaw backups, and 6.7 GiB Cargo target build artifacts (+102 GiB reclaimed).
