# 2026-10-26: All-Time Low `636 GiB Used / 224 GiB Avail (74%)` — Dropbox FileProvider Duplicate Prune, Sub-24h `/private/tmp` C14 Fixes, 29-Repo Worktree Slimming, Open-FD Log Truncation & `/learn` Wiki Push Invariant

- **Date**: 2026-10-26
- **Bead**: `disk_magician-h0it`
- **PR Reference**: [PR #275](https://github.com/jleechanorg/disk_magician/pull/275)
- **Host Volume (`/System/Volumes/Data`)**:
  - Session start: `807 GiB Used / 50 GiB Avail (95%)`
  - Wave 1 post-sweep: `704 GiB Used` -> regrew under active multi-agent load to `749 GiB Used`
  - Wave 2 post-sweep (All-Time Low): **`636 GiB Used / 224 GiB Avail (74%)`** (`667,342,992 KiB` Used)
  - Net physical delta: **`-113.04 GiB` Used in Wave 2** / **`-171 GiB` Used across the session**, **`26.51 GiB` below the 30-day floor of `662.94 GiB`**.

---

## 1. Mechanism 1 — Un-Uploaded Dropbox FileProvider Duplicate Prune (`40.24 GiB` physical / `-48 GiB` `df` Used, PR #275)

### Root Cause
- `/Applications/Dropbox.app` (`PID 1590`) was suspended (`SIGSTOP` / state `T`) and Dropbox cloud storage was at `100%` quota (`2.006 TiB / 2.006 TiB`).
- As a result, `54,864` files (`48.00 GiB`) in `/Users/jleechan/Library/CloudStorage/Dropbox/conversation-backups` were stuck in `SKIP:upload_error` / `SKIP:uploading` and could not be evicted by `fileproviderctl evict`.
- In addition, `/Users/jleechan/Library/Application Support/FileProvider/C565AFA3-62F4-41F2-9ABE-2C80BFE53167/wharf/wharf/ingest` held `8.52 GiB` across `37,795` orphaned staging chunks (`19–390d` old, `0` open FDs).

### Fix & Verification
- Extended `/Users/jleechan/projects_other/worktree_disk_trim/scripts/evict_fileprovider.sh` with `--prune-unuploaded-local-duplicates`:
  - Verifies byte-for-byte identity (`cmp -s` for raw `.jsonl` and `gzip.open` stream comparison for `.jsonl.gz`) against canonical local primaries in `/Users/jleechan/.codex/sessions`, `/Users/jleechan/.codex/sessions_archive/*.jsonl.gz`, and `/Users/jleechan/.claude/projects`.
  - Pruned `25,098` verified duplicate files (`40.24 GiB`) while preserving `29,766` sole-copy `.jsonl.zst` archives (`7.76 GiB`) and 100% of local primary session files.
- Extended `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_dev_caches.sh` to sweep `wharf/wharf/ingest` chunks `>14d` with `0` open FDs (`8.52 GiB` reclaimed).

---

## 2. Mechanism 2 — Sub-24h `/private/tmp` Growth & C14 Quarantine Fixes (`36.50 GiB` freed)

### Root Cause
`/private/tmp` grew to `67.09 GiB` from `<24h` artifacts missed by depth-1 / 24h filters:
1. `/private/tmp/worldarchitect-lifecycle-advice.cHLQ2f/native-lifecycle-raw.mp4.sb-620f589e-OKEQ8O`: `15.76 GiB` orphaned macOS sandbox atomic-write temp file (`*.sb-????????-??????`).
2. `11` depth-2 unbaselined git clones in `/private/tmp/background-pr-reviews.7RqR1x/*` (`14.2 GiB`, `9.4h–14.1h` old) created without git remotes (`rem=[]`), causing `c14_repo_pushed_ok` to return `kept:not-pushed` even though 100% of their HEAD commits existed in `/Users/jleechan/projects/worldarchitect.ai` and `/Users/jleechan/project_worldai_frontend/worldai_frontend`.
3. Dormant `>=10h` subdirectories under `/private/tmp/worldai_frontend` (`evidence/*`, `pr312-native-runtime-20261026`) and `/private/tmp/worldarchitect.ai` (`6.0 GiB`).
4. `12` dormant `>=4h` non-git working-tree copies `/private/tmp/pr10901-*` (`3.92 GiB`).

### Fix & Verification
- Added `_c14_backed_by_local_main_repo()` to `/Users/jleechan/projects_other/worktree_disk_trim/scripts/lib/artifact_verdict.sh` to verify commit reachability in local canonical repos when `origin` remote is absent.
- Ignored `"type": "admin"` merge-inventory rows in `/Users/jleechan/projects_other/worktree_disk_trim/scripts/quarantine_rename.py` (`phase1` `kept:identity-mismatch`).
- Added `stat.S_ISSOCK` socket support to `/Users/jleechan/projects_other/worktree_disk_trim/scripts/c14_probe.py` and `/Users/jleechan/projects_other/worktree_disk_trim/scripts/quarantine_rename.py`.
- Added Sections `0a` (`*.sb-????????-??????` `>60m`), `0b` (`*.bundle` `>4h`), and `0c` (depth-2 clones & `>=100 MiB` scratch dirs) to `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_tmp.sh`.

---

## 3. Mechanism 3 — Worktree Repo Discovery, Sparse-Checkout Slimming, Deps & Lossless `git gc` (`40.8 GiB` Wave 2 + `63.5 GiB` Wave 1)

- Extended `/Users/jleechan/projects_other/worktree_disk_trim/scripts/slim_worktree_checkouts.sh` (`docs,packages/mobile/docs,backup` sparse-checkout exclusion across `143` dormant worktrees and standalone clones = `20.54 GB`).
- Fixed `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_worktrees.sh` basename filter (`wf_*`, `lane_*`, etc.) and auto-discovered all `29` parent repos (`55` worktrees removed in Wave 2 = `10.84 GB`, `406` in Wave 1 = `42.84 GiB`).
- Stripped `508` build/dep dirs + untracked `Podfile.lock` in `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_worktree_deps.sh` (`6.99 GB`).
- Ran lossless `git gc --prune=7.days.ago` on `/Users/jleechan/.hermes/checkpoints/store` (`1.48 GB` freed) and `/Users/jleechan/projects/worldarchitect.ai/.git` (`3,225` packfiles consolidated).

---

## 4. Mechanism 4 — Open-FD Log Truncation, Stale Backups & Simulator Protection (`24.59 GiB` freed)

- **Open-FD In-Place Log Truncation**: In `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_supervisor_logs.sh`, truncated `/Users/jleechan/.cmuxterm/workstream.jsonl` in place keeping the last `50 MiB` on the same inode so `cmux` `FD 327w` remains valid (`5.27 GiB` freed).
- **Stale Backups**: Extended `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_claude_state.sh` to prune `>30d` `/Users/jleechan/.beads_backup_202608*` (`2.75 GiB`), `/Users/jleechan/.claude/backups/*` (`0.67 GiB`), and `/Users/jleechan/.beads-retirement-backups/*` (`0.39 GiB`).
- **Xcode DerivedData & Simulator Protection**: Cleaned `15.27 GiB` of custom Xcode DerivedData in `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_xcode.sh`, and hardened `remove_device()` so `--delete-device <udid>` refuses any `Shutdown` simulator modified `<60m` ago or with open files (`lsof +D`).

---

## 5. Mechanism 5 — `/learn` & `/wiki-ingest` Origin-Main Push Invariant

- Updated `learn/SKILL.md` and `wiki-ingest/SKILL.md` across `/Users/jleechan/.claude/skills/`, `/Users/jleechan/.codex/skills/`, `/Users/jleechan/.gemini/config/skills/`, and `/Users/jleechan/projects/jleechan-skills/.claude/skills/` so every `/learn` and `/wiki-ingest` execution commits all `/Users/jleechan/llm_wiki` changes, pushes to `origin/main`, and verifies `HEAD == origin/main`.
