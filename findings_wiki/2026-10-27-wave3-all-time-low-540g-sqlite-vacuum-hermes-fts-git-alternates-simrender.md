# 2026-10-27: Wave 3 All-Time Low `540 GiB Used` (`-105.55 GiB` Wave 3 / `-267 GiB` Cumulative) — SQLite `btreeIncrVacuum` $O(N^2)$ Fast `VACUUM`, Hermes v23 External-Content FTS5, `.git/objects/info/alternates` Dedup & Non-`.git` C14 Recency, and `SimRenderServer` Raw Video Sweep

- **Date**: 2026-10-27
- **Bead**: `disk_magician-1q58`
- **Host Volume (`/System/Volumes/Data`)**:
  - Wave 3: **`646 GiB -> 540 GiB Used`** (**`-105.55 GiB` Used / `+112.55 GiB` Avail**)
  - Cumulative across Waves 1–3: **`807 GiB -> 540 GiB Used`** (**`-267 GiB` Used**)

---

## 1. SQLite `btreeIncrVacuum` $O(\text{freelist\_count}^2)$ Tail-Scan Trap & Guarded Fast `VACUUM` (`scripts/cleanup_codex_db.sh`, `25.33 GiB -> 2.08 GiB`, `-23.25 GiB`)

### Root Cause
- When `freelist_count` reaches multi-million pages (`5.75M` pages = `90.6%` of `/Users/jleechan/.codex/thread_history_1.sqlite`), SQLite's `PRAGMA incremental_vacuum` calls `allocateBtreePage(..., iLastPg, BTALLOC_EXACT)` for every tail page, scanning the ~5,700-page freelist trunk chain on each relocation ($O(\text{freelist\_count}^2)$, taking ~18 hours).
- Additionally, macOS SQLite clamps `MAX_MMAP_SIZE` to `0x7fff0000` (`2,147,418,112` B).

### Fix & Verification
- In `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_codex_db.sh`:
  - Prune expired projection threads (`thread_items`, `thread_turns`, `thread_realtime_items`, `thread_history_projection_state`) from `thread_history_*.sqlite`.
  - Configure `PRAGMA cache_size = -1048576; PRAGMA mmap_size = 2147418112; PRAGMA temp_store = MEMORY; PRAGMA synchronous = NORMAL;`.
  - When `freelist_count >= 500,000` and `>= 50%` of `page_count` (with `>= max(4 * live_bytes, 15 GiB)` free disk headroom), run a guarded `VACUUM` + `PRAGMA wal_checkpoint(TRUNCATE)` (falling back to chunked `incremental_vacuum` if a reader pins the DB).
  - Result: Copied only the `2.08 GiB` of live pages in `39 seconds` while preserving the inode, `auto_vacuum = 2`, and `journal_mode = WAL` (`25.33 GiB -> 2.08 GiB`, `-23.25 GiB`).

---

## 2. Hermes `state.db` Legacy Inline FTS5 Triplication -> v23 External-Content Compaction (`scripts/vacuum_hermes_state.sh`, `14.63 GiB -> 2.73 GiB`, `-11.90 GiB`)

### Root Cause
- Legacy v22 `messages_fts` (`2.79 GiB`) and `messages_fts_trigram` (`7.05 GiB`, including `4.96 GiB` in `messages_fts_trigram_data`) in `/Users/jleechan/.hermes/state.db` were created without `content='messages'`, storing 3 full copies of every message alongside `697,668` (`67.2%`) messages older than 14 days.

### Fix & Verification
- `/Users/jleechan/projects_other/worktree_disk_trim/scripts/vacuum_hermes_state.sh --clean` (`--retention-days=14`):
  - Drops legacy inline v22 FTS tables and triggers.
  - Prunes `>14d` messages.
  - Recreates `messages_fts` (`content='messages'`) and `messages_fts_trigram` (`content='messages_fts_trigram_src'` excluding `role = 'tool'`) with `fts_storage_version = 1`.
  - Rebuilds FTS5 in C and runs a headroom-guarded `VACUUM` + `PRAGMA wal_checkpoint(TRUNCATE)` (`14.63 GiB -> 2.73 GiB`, `-11.90 GiB`).

---

## 3. Lossless `.git/objects/pack` Deduplication via `.git/objects/info/alternates` (`scripts/slim_worktree_checkouts.sh`, `-24.08 GiB`) & C14 Non-`.git` Content Recency (`scripts/c14_probe.py`, `scripts/cleanup_codex_documents.sh`, `-6.10 GiB`)

- **Lossless Object Store Deduplication**: Secondary standalone clones across `~/projects*`, `~/repos`, `~/Documents/Codex`, and `~/wf_*` duplicated `27+ GiB` of `.git/objects/pack` already present in canonical host repos; linking `.git/objects/info/alternates` + `git repack -a -d -l -q && git prune-packed -q` (preserving `.git` and `.git/objects` mtimes) in `/Users/jleechan/projects_other/worktree_disk_trim/scripts/slim_worktree_checkouts.sh` reclaimed `-24.08 GiB` losslessly.
- **Non-`.git` C14 Content Recency**: In `/Users/jleechan/projects_other/worktree_disk_trim/scripts/c14_probe.py` (`newest_mtime`) and `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_task_scratch.sh` (`dir_newest_mtime_epoch`), measuring age from non-`.git` working-tree content (falling back to `.git` only when no working-tree files exist) prevents `git status` / `git sparse-checkout` index rewrites from making 9-to-90-day-old clones appear `<12h` active (`-6.10 GiB` reclaimed via `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_codex_documents.sh`).

---

## 4. Runaway Orphaned `SimRenderServer` Raw Video Producer (`~3.5 GB/hour`) & Closed `*-raw*.private.mp4` Sweeping (`scripts/cleanup_tmp.sh`, `-42.26 GiB`)

- **Root Cause**: Orphaned `SimRenderServer` (`PPID 1`) processes continuously encoding raw simulator video into `/private/tmp/worldai_frontend/evidence/.../*-raw.private.mp4` (`11.82 GiB` per file) consumed `~3.5 GB/hour` and wedged `xcrun simctl`.
- **Fix**: Stopped orphaned `SimRenderServer` writers (`0` active test runners) and swept closed `*-raw*.private.mp4` files (`>= 1 GiB`, `>60m` idle) in `/Users/jleechan/projects_other/worktree_disk_trim/scripts/cleanup_tmp.sh`, reclaiming `25.23 GiB` of raw video (`-42.26 GiB` total in `/private/tmp`).
