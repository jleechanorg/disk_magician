# Fast Scanner Redesign & Automated Scratch Cleanup Root-Cause Specification

**Date:** 2026-11-26
**Status:** Proposed (`/sq` autonomous design)
**Repository:** `jleechanorg/worktree_disk_quick_clean` (Disk Magician)
**Related Beads / PRs:** `disk_magician-5fba` (top-down ledger `ledger/topdown-5g.json`), PR #430 (macOS APFS metadata skip in `scratch_expired`), PR #433 (native capacity history), PR #434 (Linux `/proc` open-file scan)

---

## 1. Problem Statement & Empirical Root-Cause Breakdown

Live measurements on **2026-11-26** across both macOS (`jeffreys-macbook-pro.local`, `/Volumes/diskm-scratch`, ~149 GiB volume used / 107.4 GiB non-hidden top-level indexed) and Linux (`jeff-ubuntu`, `/home/jleechan/Scratch`, ~176 GiB `du -xh` / 111.3 GiB top-level indexed) show that automated Scratch cleanup is **not** failing due to `scratch-expired` timeouts (`timed_out: false` on every run: 79.8s–119.3s on Mac, 22.9s–25.4s on Linux, well under the 600s `EXPIRED_SWEEP_DEADLINE`).

Instead, four distinct root causes compound to keep ~149 GiB (Mac) and ~176 GiB (Linux) uncleaned while leaving `disk_magician-5fba` (`ledger/topdown-5g.json`) unpopulated:

### Root Cause 1: Mixed-Age Umbrella Directories Pin Stale Children (Primary Byte Driver)
`rust/src/scratch_expired.rs::candidates()` judges every direct child of Scratch as one atomic unit (only `runs/<date>/<repo>/<run>` descends to depth 4). A single fresh file (<12h) inside a shared container pins the entire directory as `kept:fresh`:
- **Mac:**
  - `tmp/`: **34.88 GiB total**, of which **33.76 GiB (96.8%) is stale ≥12h** (`vv6` 20.21 GiB @ 18.5h, `vv4` 7.39 GiB @ 20.8h, `gate25-redact.SG812c` 2.42 GiB @ 13.5h, `vv` 1.24 GiB @ 22.1h), pinned by 1.12 GiB of fresh children (newest 1.9h).
  - `worldarchitect.ai/`: **9.38 GiB total**, of which **8.33 GiB (88.8%) is stale ≥12h** (`living-world-mvp-present-cast` 4.32 GiB @ 84.7h, `codex_deepseek-...` 2.00 GiB @ 92.0h), pinned by 1.06 GiB of fresh children (newest 2.1h).
  - **Combined Mac pinned stale bytes:** **42.09 GiB** trapped solely by whole-parent freshness.
- **Linux:**
  - `worldarchitect.ai/`: **33.47 GiB** (`du` 34G), with ≥8.69 GiB stale ≥12h pinned by a 5.4h fresh child and a nested `evidence/` folder (2.07 GiB).
  - `tmp/`: **13.64 GiB** (`du` 14G), pinned as `kept:fresh` (2.7h).

### Root Cause 2: Protective Holds & Global `blind` Blast Radius
Latest `scratch_sweep` (`expired: true`) receipts show `removed: 0`, `status: partial` (exit 75):
- **Mac** (`18ebb326a6b94ef0-40467-18ebb33939dd5930.json`, 79.8s, `timed_out: false`):
  - `kept:fresh`: 737
  - `kept:protected-subtree:kept:evidence-run`: 59
  - `kept:protected-descendant:evidence`: 54 (+ 3 subtree `evidence`, e.g., `evidence/` 5.18 GiB @ 35.6h)
  - `kept:protected-descendant:incomplete-alternates-scan`: 21 (+ 11 subtree) — **fragility:** a single unreadable/transient entry anywhere in Scratch sets `known.blind = true` (`blind |= !seen.complete`), blocking all 32 git-containing stale candidates in that run. On the prior clean run (`18ebafc7a0e8ba90-83252-18ebafe0717a9648.json`, 106.6s), those 32 were: 17 `git-unrecovered-commits`, 9 `git-probe-failed`, 6 `git-linked-worktree`.
  - `kept:protected-subtree:kept:live-or-unknown-owner`: 8; `deferred:lease-unavailable`: 5; `deferred:open-file`: 2 (`codex-compact-test`, `gates11053`).
- **Linux** (`18ebb21d6487de9a-852220-18ebb222ba5f995c.json`, 22.9s, `timed_out: false`):
  - `kept:fresh`: 419; `kept:protected-descendant:evidence`: 62 (+ 1 subtree `evidence` = 6.55 GiB); `kept:protected-descendant:git-unrecovered-commits`: 19 (+ 3 subtree); `kept:protected-subtree:kept:evidence-run`: 11; `git-probe-failed`: 3; `deferred:lease-unavailable`: 3; `git-alternates-dependent`: 2; `git-external-worktree`: 1; `git-linked-worktree`: 1; `deferred:open-file`: 2 (`idle-slice1-jre`, `nl-optin`).
  - Largest stale Linux trees (`mirrors/` 30.52 GiB @ 13.1h, `mirror-output/` 13.19 GiB @ 24.9h, `mirror/` 1.41 GiB @ 43.4h = **45.12 GiB**) are held by git/evidence protection rules.

### Root Cause 3: Pressure Sweeper (`scratch-pressure` / `scratch-reclaim`) Throughput Bottleneck
- `rust/src/scratch_sweep.rs` defaults `Options::limit = 20` and operates on **individual files** under `runs/` only.
- On Mac, `com.jleechanorg.disk-magician-scratch-pressure` runs every 20 minutes (32.9s–51.0s per run), removes **20 files** (`volume_used_delta_bytes: -1,155,072` = 1.1 MiB), and leaves `unchecked: 179,470`. At 20 files / 20 min, draining the queue takes **124 days**.
- On Linux, `diskm-scratch-reclaim.service` runs 30.3s every 20 minutes, hits `kept:repository-use-worktree-route` on files inside `runs/*/repo/`, and exits 75 with `status: pressure_unresolved`, `removed: 0`.

### Root Cause 4: Single-Threaded Scanner, 3.2 GiB SQLite Index Bloat, and Missing `frontier` Producer (`disk_magician-5fba`)
- **Single-threaded traversal:** `rust/Cargo.toml` has zero concurrency crates (`libc`, `rusqlite`, `serde`, `serde_json`, `sha2` only). Both `scan.rs` and `scratch_expired.rs::walk()` execute sequential single-threaded `read_dir` + `lstat`.
  - **Measured benchmark on Mac `/Volumes/diskm-scratch` (~2.30M entries, 120 GB):**
    - `dua 2.38.0` (installed at `/opt/homebrew/bin/dua`, parallel Rust `jwalk` engine): **24.15s** wall time.
    - `diskm scratch-expired` (single-threaded Rust): **79.8s–119.3s** wall time (**3.3x–4.9x slower**).
    - `diskm scratch-index refresh` on Linux (~2.60M entries): **63s–119s** CPU time.
- **Permanent `coverage_complete: false` on Mac `scratch-index`:** `scan.rs` does not skip the 5 unreadable macOS APFS volume metadata directories (`.DocumentRevisions-V100`, `.Spotlight-V100`, `.TemporaryItems`, `.Trashes`, `.fseventsd`). Every hourly `scratch-index refresh` records exactly those 5 `readdirectory` gaps and publishes `scan_complete = 0`.
- **SQLite index bloat:** `scratch-age.sqlite3` stores every individual file (2.30M rows Mac, 2.60M rows Linux) with 5 B-tree indexes, consuming **3.23 GiB on Mac** and **3.29 GiB on Linux**, and rewriting all rows in one transaction hourly (already triggered `diskm: scratch index SQLite error: database or disk is full` on Mac).
- **Missing `frontier` producer (`disk_magician-5fba`):** Commit `30057f8e3` deleted `scripts/disk_frontier_scan.py` (which used one-pass `gdu` / GNU `du` + `dua` fallback to write `ledger/topdown-5g.json` with `mode: "complete"`). Rust `diskm` has no `frontier` subcommand; `diskm snapshot` only records `scope: "capacity_only"`, so `diskm history` has no `mode: "complete"` top-down ledger updates.

---

## 2. OSS Tool Inventory & Evaluation

| Tool | Mac Status | Linux (`jeff-ubuntu`) Status | Engine / Capability | Fit for Disk Magician |
|---|---|---|---|---|
| `dua` (`dua-cli`) | Installed (`/opt/homebrew/bin/dua`, v2.38.0) | Not installed | Parallel Rust (`jwalk`), 24.15s for 2.3M entries on Mac | Great benchmark oracle; subprocess output lacks mtime/ctime, `.git`/`evidence` detection, and gap taxonomy. Embedding parallel Rust traversal achieves `dua`-class speed natively with zero subprocess fragility. |
| `gdu` (GNU `du`) | Installed (`/opt/homebrew/bin/gdu`, coreutils 9.7) | Native `/usr/bin/du` | Single-threaded C `fts` | Previously used by Python `disk_frontier_scan.py` for one-pass NUL-delimited postorder size inventory; single-threaded and lacks mtime/git/evidence in one pass. |
| `fd` / `fdfind` | Not installed | Installed (`/usr/bin/fdfind`, v9.0.0) | Parallel Rust (`ignore`) | Name search only; does not aggregate directory sizes or inode-deduped allocated blocks. |
| `ncdu` | Not installed | Installed (`/usr/bin/ncdu`, v1.19) | Single-threaded C | Interactive TUI; slower than parallel Rust. |
| `rg` | Installed (v15.1.0) | Installed (v14.1.0) | Parallel Rust (`ignore`) | Content search, not filesystem metadata inventory. |

**Architectural Decision:** Embed bounded parallel traversal directly in Rust `diskm` rather than shelling out to `dua` or `gdu`.
- **Phase 1 (Zero-dependency MVP, fits inside 14,300 Rust prod LOC budget — currently 14,201 / 14,300):** Use `std::thread::scope` + `AtomicUsize` work queue across candidates in `scratch_expired.rs::plan()` and share `is_unreadable_macos_volume_metadata()` between `scan.rs` and `scratch_expired.rs`. Zero new Cargo crates, zero external binary dependencies on Mac or Linux, deterministic output ordering.
- **Phase 4 (Full-disk `frontier` + `scan.rs` parallelization):** Evaluate adding `jwalk` (or reusing a bounded `std::thread::scope` directory work-stealing pool in `scan.rs`) to power both `diskm scan` and a native `diskm frontier` subcommand that emits `ledger/topdown-5g.json` (`mode: "complete"`), closing `disk_magician-5fba` on both Mac and Linux without requiring `gdu` or `dua` to be pre-installed.

---

## 3. Target Architecture (4 Phased Milestones)

### Phase 1 — Parallel Candidate Observation & APFS Metadata Parity (MVP — Ready to Ship)
1. **Shared APFS volume-metadata skip helper (`scan.rs` + `scratch_expired.rs`):**
   - Move `is_unreadable_macos_volume_metadata(path, name)` to `pub(crate) fn` in `scan.rs`, handling both `PermissionDenied` (`EACCES`) and `EPERM` (`Operation not permitted`, raw os error 1 — which `.DocumentRevisions-V100`, `.Spotlight-V100`, `.TemporaryItems`, `.Trashes` return on macOS!).
   - Skip those 5 root-level metadata dirs in `scan.rs::scan_internal()` when `parent == 0` (root) so `diskm scratch-index refresh` and `diskm scan /Volumes/diskm-scratch` achieve `coverage_complete: true` instead of permanently failing with 5 root metadata gaps.
   - Reuse the same helper in `scratch_expired.rs` (eliminating duplicate code).
2. **Bounded parallel `observe()` in `scratch_expired.rs::plan()`:**
   - Replace the sequential `for (path, judged) in it { observe(...) }` loop with a bounded `std::thread::scope` worker pool (`workers = std::thread::available_parallelism().map_or(4, |n| n.get()).clamp(1, 8)`).
   - Workers claim indices from an `AtomicUsize` work counter, call `observe(&path, run.device, run.deadline)`, and store results by original index.
   - After the scope joins, results are collected in exact original index order so `units`, `alts`, `stores`, and `blind` are 100% deterministic and identical to sequential execution.
   - **LOC impact:** Net **+20 to +40 Rust prod lines** (stays comfortably under `14,300` cap: ~14,230 / 14,300).

### Phase 2 — Umbrella-Container Granularity & Pressure Sweeper Retirement (Policy-Gated)
1. **Configurable umbrella containers (e.g., `tmp/`, `worldarchitect.ai/`, `mirrors/`):**
   - Under `GEMINI.md` (operator decision 2026-11-22), `scratch_expired` currently only descends into `runs/<date>/<repo>/<run>`.
   - Extend candidate discovery with an explicit, operator-approved umbrella allowlist (or `runs/` migration) so direct children of `tmp/` and `worldarchitect.ai/` are judged independently instead of pinned by one fresh sibling. This immediately unlocks **42.09 GiB** on Mac (`tmp/` 33.76 GiB + `worldarchitect.ai/` 8.33 GiB).
2. **Retire or batch-fix `scratch-pressure` / `scratch-reclaim`:**
   - Replace the 20-file-per-20-min individual-file throttle (`Options::limit = 20`) with whole-unit candidate removal or raise batch size to 2,000+ when removing individual build artifacts, and stop re-scanning `runs/*/repo/` files that always return `kept:repository-use-worktree-route`.

### Phase 3 — Compact Directory-First Index (Eliminate 3.3 GiB SQLite Bloat)
- Store directory-level rollups (down to 100 MiB / candidate boundaries) instead of all 2.6M individual leaf files with 5 B-tree indexes.
- Reduces `scratch-age.sqlite3` from **~3.3 GiB to <50 MiB**, eliminates `database or disk is full` failures, and cuts hourly refresh write I/O by >95%.

### Phase 4 — Native Parallel `diskm frontier` (`disk_magician-5fba`)
- Add `diskm frontier [--root PATH] [--threshold-mib 100] [--output PATH] [--deadline-ms N]` powered by a parallel work-stealing `scan.rs` traversal.
- Emits `ledger/topdown-5g.json` matching `rust/src/history.rs::qualifying_sample()` (`mode: "complete"`, `captured_at`, `disk_used_kb`, `scope: { root, hostname }`, inode-deduplicated allocation, 100 MiB itemization floor, and localized permission-gap attribution).
- Re-enables 7d and 30d full-disk history in `diskm history` on both Mac and Linux without Python or external `gdu`/`dua` binaries.
- Note: Phase 4 requires a reviewed Rust LOC budget adjustment (above 14,300) or concurrent deletion of retired legacy code in `preview.rs` / `scratch_sweep.rs`.

---

## 4. Assumptions and Recommended Defaults

| Considered Question | Selected Default | Rationale |
|---|---|---|
| Shell out to `dua`/`gdu` vs native Rust parallelism? | **Native Rust parallelism** (`std::thread::scope` in Phase 1; work-stealing pool or `jwalk` in Phase 4). | `dua` is missing on Linux and lacks mtime/git/evidence/gap semantics; `gdu` is single-threaded. Native Rust runs identically on Mac & Linux in a single pass with zero subprocess parsing bugs. |
| Add `rayon`/`jwalk` in Phase 1 vs `std::thread::scope`? | **`std::thread::scope` in Phase 1** (0 new crates). | `scratch_expired::plan()` already has ~800 independent top-level/run candidates; a 25-line `std::thread::scope` pool achieves near-linear speedup with zero `Cargo.lock` churn and fits the 99-LOC headroom. |
| Change `scratch_expired` umbrella-directory policy in Phase 1? | **No — defer to Phase 2 pending operator policy signoff.** | `GEMINI.md` explicitly states "Candidates are only direct children of the Scratch root and run directories under `runs/<date>/<repo>/<run>`, each judged whole." Changing candidate scope is a policy change, not a pure scanner optimization. |
| Fix `EPERM` (`Operation not permitted`) alongside `PermissionDenied` in APFS metadata skip? | **Yes — match both `PermissionDenied` and `raw_os_error() == Some(libc::EPERM)`.** | Live Mac `scratch-age.sqlite3` proved 4 of 5 APFS metadata gaps return `os error 1` (`EPERM`), while `.fseventsd` returns `os error 13` (`EACCES`). Rust maps `EPERM` to `ErrorKind::PermissionDenied` on Unix, and matching `PermissionDenied` covers both cleanly; we verify both with unit tests. |
| Worker concurrency cap? | **`clamp(1, 8)` threads.** | Prevents APFS/ext4 metadata lock contention and respects host CPU/I/O headroom while matching `dua`'s throughput. |

---

## 5. Implementation Preconditions

- **Phase 1 (MVP):** Ready immediately; no new authority, credentials, or LOC budget increase required (`<=14,300` Rust prod LOC).
- **Phase 2:** Requires explicit operator approval to amend the `GEMINI.md` whole-candidate rule for shared umbrella directories (`tmp/`, `worldarchitect.ai/`, `mirrors/`).
- **Phase 3 & Phase 4:** Require operator approval if total Rust prod LOC exceeds `14,300` (or must be paired with legacy code deletion in `scratch_sweep.rs` / `preview.rs`).
