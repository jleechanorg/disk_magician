# 2026-10-27: Wave 4 All-Time Low `552 GiB Used` (`-26 GiB` net `df` / `52.67 GiB` physical / `-255 GiB` Cumulative) — Colima Datadisk Re-anchor & Sparse Trim, Custom DerivedData Sweeps, Expanded Sparse-Checkout Exclusions, and C14 Intermediate Video Capture Pruning

- **Date**: 2026-10-27
- **Beads**: `disk_magician-1q58`, `disk_magician-4b7q`
- **Host Volume (`/System/Volumes/Data`)**:
  - Wave 4: **`578 GiB -> 552 GiB Used`** (**`-26 GiB` net `df` Used / `+27 GiB` Avail**, with **`52.67 GiB`** physical files reclaimed)
  - Cumulative across Waves 1–4: **`807 GiB -> 552 GiB Used`** (**`-255 GiB` Used / `+292 GiB` Avail**)

---

## 1. Colima Datadisk Re-anchor & Sparse Host Reclaim (`14.70 GiB -> 5.19 GiB`, `-9.51 GiB` host reclaim)

### Problem
- The host sparse disk image at `/Users/jleechan/.colima/_lima/_disks/colima/datadisk` had expanded to `14.70 GiB` (`15,413,256 KB`), holding duplicate untagged images (e.g. `85ee354ef6df` `3.38 GB`) and dead test containers.
- The datadisk was locked by Lima (`limactl disk unlock colima`).
- Standard docker prune inside the VM does not reclaim APFS host sparse disk allocations without an in-guest block discard (`fstrim`).

### Fix & Verification
- Unlocked datadisk with `limactl disk unlock colima`.
- Re-anchored `/ezgha-image-anchor` in Colima to `ezgha-runner:latest` to prevent prune safety violations.
- Pruned untagged duplicate image `85ee354ef6df` and unused build caches via Docker daemon.
- Executed in-guest `sudo fstrim -av`, trimming `9.8 GiB` of discardable blocks.
- Host APFS sparse datadisk shrunk from `14.70 GiB` to `5.19 GiB` (**`-9.51 GiB`** / `9,968,240 KB` physical host reclaim).

---

## 2. Custom DerivedData & Simulator Temporary Sweeps (`-10.07 GiB`)

### Problem
- In `/private/tmp`, custom DerivedData directories (`derived` `2.10 GiB` + `derived_debug` `2.60 GiB`) and shutdown simulator temporary caches accumulated from local and CI test runs.

### Fix & Verification
- Ran canonical `scripts/cleanup_xcode.sh --clean`, safely removing `4.70 GiB` of custom DerivedData builds in `/private/tmp` and `5.36 GiB` of inactive CoreSimulator temporary caches (**`-10.07 GiB`** total).

---

## 3. Dev Caches & Stale PR Review Scratch (`-12.08 GiB`)

### Problem
- Aged PR review clones in `/private/tmp/advice10927.HWkTSy` (`3.69 GiB`) and `/private/tmp/pr317-r9.*` (`1.88 GiB`) remained after review completion.
- Multi-profile Chrome Service Worker CacheStorage (`2.09 GiB`), `~/.cache/codex-runtimes` (`1.60 GiB`), Aside browser components (`981 MiB`), and Ghostty zig cache (`965 MiB`) accumulated unmonitored disk space.

### Fix & Verification
- Ran canonical `scripts/cleanup_dev_caches.sh --clean` (**`-6.50 GiB`**).
- Ran canonical `scripts/cleanup_tmp.sh --clean` (**`-5.58 GiB`**).
- Removed `/Users/jleechan/Documents/Codex/2026-10-03/task-13` (`782 MiB`) and 14 empty aged task dirs via `scripts/cleanup_codex_documents.sh` (**`-0.76 GiB`**).
- Pruned obsolete `/Users/jleechan/.local/share/cursor-agent/versions/2026.10.16-e3cb207` (**`-0.58 GiB`**).
- Swept `~/.cache/gh` logs and Aside/Chrome WebKit caches (**`-4.16 GiB`**).

---

## 4. Expanded Sparse-Checkout Exclusions & Intermediate Video Capture Pruning (`-16.97 GiB`)

### Problem
- While Wave 3 established `.git/objects/info/alternates` object deduplication, worktrees across `~/.worktrees` and `~/projects` still checked out large auxiliary directories: `evidence/`, `screenshots/`, `roadmap/`, and `backups/`.
- In `~/project_worldaiclaw/worldai_claw/docs/ios_evidence`, 25 gitignored intermediate video captures (`*_raw*.mp4` and `*_trim.mp4` from 2026-08-02) totaled `2.80 GiB`.

### Fix & Verification
- Extended `scripts/slim_worktree_checkouts.sh` to configure sparse-checkout exclusion patterns for `evidence,screenshots,roadmap,backups` across 328 worktrees alongside alternates linking (**`-8.63 GiB`** / `9,051,760 KB`).
- Stripped 432 dependency directories (`target`, `node_modules`, `__pycache__`) in `/Users/jleechan/projects_other/ez-gh-actions` and dormant worktrees via `scripts/cleanup_worktree_deps.sh` (**`-3.62 GiB`** / `3,799,000 KB`).
- Pruned 25 gitignored intermediate `*_raw*.mp4` and `*_trim.mp4` captures in `~/project_worldaiclaw/worldai_claw/docs/ios_evidence` via canonical C14 `quarantine_remove --kind ephemeral` (**`-2.80 GiB`** / `2,936,772 KB`).
- Removed 17 eligible clean, merged/pushed repo-local worktrees via `scripts/cleanup_worktrees.sh` (**`-1.91 GiB`** / `2,004,068 KB`).
