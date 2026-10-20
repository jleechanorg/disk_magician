# Disk Magician Unified Cleanup (`diskm --cleanup`) & Fast C14 Governor Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

- **Date:** 2026-10-17
- **Spec Reference:** `/Users/jleechan/projects_other/worktree_dropbox/docs/superpowers/specs/2026-10-17-diskm-unified-cleanup-and-governor-redesign-design.md`
- **Goal:** Unify all 4 cleanup orchestrators (`diskm --cleanup`/`clean`, `disk_audit.sh --clean`, `pressure_sweep.sh`, and `govern.sh`) onto `scripts/main_sweeper.sh` with immediate `df` reclaim for rebuildable/clone targets, explicit opt-in gates for worktree/Claude-state tiers, and an `fcntl.flock`-serialized SQLite lease store + crash-safe chunked quarantine sidecar.
- **Architecture:**
  1. Route `--cleanup`, `cleanup`, `clean`, `disk_audit.sh --clean`, `pressure_sweep.sh` (`--pressure-only`), and `govern.sh` (`--tier <tier>`) through `scripts/main_sweeper.sh`, enabling `LARGE_TMP_APPROVED=1` and `CODE_SIGN_CLONES_APPROVED=1` for `--cleanup` / `clean-all` while keeping `WORKTREE_APPROVED=1` (`--with-worktrees`) and `CLAUDE_STATE_APPROVED=1` (`--with-claude-state`) strictly opt-in.
  2. Replace the 19,000 loose JSON files in `worktree_leases/` with an authoritative SQLite store (`<lease_dir>/.lease_index.sqlite`) serialized by `fcntl.flock` on `<lease_dir>/.lease.lock` (draining any legacy `*.json` lease files into SQLite under `LOCK_EX` and holding `LOCK_EX` across `phase1` final lease verification and `os.rename` so no TOCTOU window or unindexed in-place JSON edit is possible). Replace per-file `os.fsync()` in `scripts/quarantine_rename.py phase2` with chunked (`K=64`) sidecar checkpoints + `SIGKILL`-safe idempotent `ENOENT` recovery while preserving full SHA256 content checks and per-candidate `lsof`.
  3. Close C14 false-positive gaps (`kind="ephemeral"` in `cleanup_dev_caches.sh` and `cleanup_codex_documents.sh`, and `_disk_magician_archive` retention metadata) and run immediate Phase-2 quarantine unlink (`--grace-seconds 0`) on `rebuildable` and `code_sign_clone` targets.
- **Tech Stack:** Bash 3.2+ (`set -euo pipefail`, ShellCheck clean), Python 3.11+ (`unittest`, `sqlite3`, `fcntl`, stdlib only).

---

## File Structure & Responsibility Map

- `/Users/jleechan/projects_other/worktree_dropbox/disk_magician.sh` — Add `--cleanup` and `cleanup` CLI aliases; route `clean` / `--cleanup` / `cleanup` to `scripts/main_sweeper.sh` with `--clean` default.
- `/Users/jleechan/projects_other/worktree_dropbox/src/disk_magician/cli.py` — Register `--cleanup` and `cleanup` in Python entrypoint (`COMMAND_SCRIPTS` / `main()`).
- `/Users/jleechan/projects_other/worktree_dropbox/scripts/main_sweeper.sh` — Single canonical orchestrator supporting `--clean`, `--dry-run`, `--pressure-only`, `--tier <tier>`, `--with-worktrees` (`WORKTREE_APPROVED=1`), and `--with-claude-state` (`CLAUDE_STATE_APPROVED=1`); wires all 7 tiers and final `quarantine reconcile`, and emits pre/post `df -k /System/Volumes/Data` delta.
- `/Users/jleechan/projects_other/worktree_dropbox/scripts/disk_audit.sh`, `/Users/jleechan/projects_other/worktree_dropbox/scripts/pressure_sweep.sh`, & `/Users/jleechan/projects_other/worktree_dropbox/scripts/govern.sh` — Delegate cleanup execution to `scripts/main_sweeper.sh` instead of maintaining separate per-script lists.
- `/Users/jleechan/projects_other/worktree_dropbox/scripts/c14_probe.py` & `/Users/jleechan/projects_other/worktree_dropbox/scripts/lib/worktree_lease.sh` — Authoritative SQLite `.lease_index.sqlite` synchronized by `fcntl.flock` on `<lease_dir>/.lease.lock`, with automatic drain/import of any legacy `*.json` lease files under `LOCK_EX`.
- `/Users/jleechan/projects_other/worktree_dropbox/scripts/quarantine_rename.py` — Hold `<lease_dir>/.lease.lock` (`LOCK_EX`) across final lease re-verification and `os.rename` in `phase1`; checkpoint sidecar every `K=64` unlinked entries and in `finally:` in `phase2`; handle mid-chunk `SIGKILL` recovery idempotently when previously unlinked entries are already `ENOENT` in `.dm-quarantine/<id>/payload`.
- `/Users/jleechan/projects_other/worktree_dropbox/scripts/lib/quarantine.sh` — Trigger immediate Phase-2 reap (`--grace-seconds 0`) for `rebuildable` and `code_sign_clone` removals.
- `/Users/jleechan/projects_other/worktree_dropbox/scripts/lib/artifact_verdict.sh` — Honor `LARGE_TMP_ARCHIVE_RETENTION_HOURS` in `c14_archive_origin`.
- `/Users/jleechan/projects_other/worktree_dropbox/scripts/cleanup_dev_caches.sh` & `/Users/jleechan/projects_other/worktree_dropbox/scripts/cleanup_codex_documents.sh` — Pass `--kind ephemeral` to `c14_remove` instead of `kind=""`.
- `/Users/jleechan/projects_other/worktree_dropbox/tests/test_cli_cleanup_unified.sh` — Regression test suite for `--cleanup` / `cleanup` / `clean` CLI contract, non-TTY execution, and opt-in `WORKTREE_APPROVED` / `CLAUDE_STATE_APPROVED` preservation.
- `/Users/jleechan/projects_other/worktree_dropbox/tests/test_c14_fast_path.py` — Regression test suite for `flock`-serialized SQLite lease store (`O(log N)` lookup, legacy JSON drain, `phase1` lease-creation TOCTOU prevention under `.lease.lock`), SHA256 content mismatch rejection, per-candidate `lsof` open-file rejection, chunked sidecar `fsync` bound, and mid-batch `SIGKILL` partial-unlink recovery.

---

## Task 1: Unify CLI Entrypoint (`diskm --cleanup`, `diskm cleanup`, `diskm clean`) & Enforce Opt-In Approval Boundaries

**Files:**
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/disk_magician.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/src/disk_magician/cli.py`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/disk_audit.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/main_sweeper.sh`
- Create: `/Users/jleechan/projects_other/worktree_dropbox/tests/test_cli_cleanup_unified.sh`

- [ ] **Step 1: Write the failing test (`tests/test_cli_cleanup_unified.sh`)**
  Create `/Users/jleechan/projects_other/worktree_dropbox/tests/test_cli_cleanup_unified.sh` asserting both positive and negative cases:
  1. `bash disk_magician.sh --cleanup --dry-run` and `bash disk_magician.sh cleanup --dry-run` exit `0` (instead of `Unknown command: --cleanup`).
  2. `python3 -m disk_magician.cli --cleanup --help` exits `0`.
  3. Running `bash disk_magician.sh --cleanup` in a non-TTY subshell (`< /dev/null`) passes `--clean` (not `--dry-run`) to `scripts/main_sweeper.sh` without requiring `DISK_MAGICIAN_AUTO_CLEAN=1`, sets `LARGE_TMP_APPROVED=1` and `CODE_SIGN_CLONES_APPROVED=1`, and **keeps `WORKTREE_APPROVED=0` and `CLAUDE_STATE_APPROVED=0` by default** unless `--with-worktrees` / `WORKTREE_APPROVED=1` or `--with-claude-state` / `CLAUDE_STATE_APPROVED=1` is explicitly passed.
- [ ] **Step 2: Run the test to verify it fails (RED)**
  Run: `bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_cli_cleanup_unified.sh`
  Expected: `FAIL` with `Unknown command: --cleanup` (`rc=1`).
- [ ] **Step 3: Implement `--cleanup` / `cleanup` dispatch and explicit approval flags**
  - In `/Users/jleechan/projects_other/worktree_dropbox/disk_magician.sh` and `/Users/jleechan/projects_other/worktree_dropbox/src/disk_magician/cli.py`, accept `--cleanup`, `cleanup`, and `clean`, routing to `scripts/main_sweeper.sh` with `--clean` unless `--dry-run` is present in `"$@"`.
  - In `/Users/jleechan/projects_other/worktree_dropbox/scripts/main_sweeper.sh`, parse `--with-worktrees` (`WORKTREE_APPROVED=1`) and `--with-claude-state` (`CLAUDE_STATE_APPROVED=1`), keeping both `0` by default when unset.
  - In `/Users/jleechan/projects_other/worktree_dropbox/scripts/disk_audit.sh`, delegate `--clean` / `clean-all` tier execution to `scripts/main_sweeper.sh --clean` with `LARGE_TMP_APPROVED=1`.
- [ ] **Step 4: Run the test to verify it passes (GREEN)**
  Run: `bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_cli_cleanup_unified.sh`
  Expected: `PASS (0 failures)`.

---

## Task 2: `flock`-Synchronized Authoritative SQLite Lease Store & `SIGKILL`-Safe Chunked Sidecar (`c14_probe.py`, `worktree_lease.sh`, `quarantine_rename.py`)

**Files:**
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/c14_probe.py`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/lib/worktree_lease.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/quarantine_rename.py`
- Create: `/Users/jleechan/projects_other/worktree_dropbox/tests/test_c14_fast_path.py`

- [ ] **Step 1: Write the failing unit test (`tests/test_c14_fast_path.py`)**
  Create `/Users/jleechan/projects_other/worktree_dropbox/tests/test_c14_fast_path.py` asserting:
  1. **Authoritative SQLite Lease Store + Legacy JSON Drain + `O(log N)` Lookup:**
     - Populate `lease_dir` with `2,000` legacy `*.json` lease files. First `lease_scan` acquires `.lease.lock` (`LOCK_EX`), drains all `2,000` loose `.json` files into `.lease_index.sqlite`, and removes the loose `.json` files (recording any corrupt `.json` as a fail-closed `corrupt` row).
     - Subsequent `lease_scan` calls complete in `<25ms` (`O(log N)` indexed SQLite query) and immediately reflect `lease-upsert` / `lease-delete` updates (`0s` staleness).
  2. **`flock` Serialization Across `phase1` Lookup & Rename (TOCTOU Prevention):**
     - Hold `LOCK_EX` on `<lease_dir>/.lease.lock` in `quarantine_rename.py phase1` across the final SQLite lease check and `os.rename(target, quarantine_payload)`. Prove that if a lease covering `target` is inserted into `.lease_index.sqlite` (or dropped as a `.json` file in `lease_dir`) after `c14_probe.py inventory` but before `phase1` acquires `.lease.lock`, `phase1` rejects with `kept:active-lease` and leaves `target` untouched.
  3. **Content SHA256 & Open-File `lsof` Preservation (Negative Safety Tests):** Modifying 1 byte of a file in a candidate directory after `c14_probe.py inventory` (even if file size and `mtime_ns` are restored via `os.utime`) causes `quarantine_rename.py phase1` and `phase2` to reject with `kept:inventory-mismatch`, and an open file handle detected by `lsof` immediately before `phase1` or `phase2` rejects with `kept:open-files`.
  4. **Chunked Sidecar `fsync` Bound:** `quarantine_rename.py phase2` on a 200-file quarantined directory calls `os.fsync` at most `8` times total (chunk size `64` -> `ceil(200/64) * 2` = `8`, down from `400+`).
  5. **Mid-Batch `SIGKILL` Partial-Unlink Recovery:** Simulate an abrupt `SIGKILL` after unlinking 30 of 200 files in `.dm-quarantine/<id>/payload` before `sidecar.json` was updated (`unlinked_entries` still empty). Re-running `quarantine_rename.py phase2` recovers idempotently, records the 30 already-unlinked files and unlinks the remaining 170 files + directories, returning `reaped`.
- [ ] **Step 2: Run the test to verify it fails (RED)**
  Run: `python3 -m unittest /Users/jleechan/projects_other/worktree_dropbox/tests/test_c14_fast_path.py`
  Expected: `FAIL` (`.lease_index.sqlite` not created; `phase1` does not re-check leases under `.lease.lock`; `os.fsync` called `400+` times; mid-batch unrecorded unlink fails on resume).
- [ ] **Step 3: Implement `flock`-synchronized `.lease_index.sqlite`, `phase1` locked lease re-check, chunked sidecar checkpointing (`K=64`), and `SIGKILL` recovery**
  - In `/Users/jleechan/projects_other/worktree_dropbox/scripts/c14_probe.py` and `/Users/jleechan/projects_other/worktree_dropbox/scripts/lib/worktree_lease.sh`:
    - Add `lease-upsert`, `lease-delete`, and `_drain_and_query_leases(target, lease_dir)` acquiring `fcntl.flock(lock_fd, fcntl.LOCK_EX)` on `<lease_dir>/.lease.lock`, draining any loose `*.json` files into `<lease_dir>/.lease_index.sqlite`, and querying `SELECT payload_json FROM leases WHERE ...` via `idx_leases_root`.
  - In `/Users/jleechan/projects_other/worktree_dropbox/scripts/quarantine_rename.py`:
    - Keep full SHA256 content verification and per-candidate `lsof`.
    - In `phase1`, acquire `LOCK_EX` on `<lease_dir>/.lease.lock`, run `_drain_and_query_leases(target, lease_dir)` to verify no active/corrupt lease appeared since `inventory`, and execute `os.rename(target, payload_path)` before releasing `.lease.lock`.
    - In `phase2`, flush `update_sidecar(sidecar_path, sidecar)` every `64` unlinked entries and inside `finally:`.
    - When resuming `phase2` on a quarantine directory where `os.lstat(full)` raises `FileNotFoundError` for a `file`/`symlink` entry inside `.dm-quarantine/<id>/payload`, record `relpath` in `sidecar["unlinked_entries"]` and continue unlinking remaining entries.
- [ ] **Step 4: Run the test to verify it passes (GREEN)**
  Run: `python3 -m unittest /Users/jleechan/projects_other/worktree_dropbox/tests/test_c14_fast_path.py && bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_quarantine.sh`
  Expected: `OK` and `0 failed`.

---

## Task 3: Close C14 Ephemeral / Archive False-Positives & Enable Immediate Reap for Rebuildable Targets

**Files:**
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/lib/artifact_verdict.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/lib/quarantine.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/cleanup_dev_caches.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/cleanup_codex_documents.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/cleanup_tmp.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/tests/test_artifact_verdict.sh`

- [ ] **Step 1: Write failing regression tests in `tests/test_artifact_verdict.sh`**
  Add both positive and negative test cases verifying:
  1. A `.c14-origin.json` archive receipt with `LARGE_TMP_ARCHIVE_RETENTION_HOURS=4` passes `c14_archive_origin` once aged `>4h`, while an archive receipt aged `<4h` is rejected with `kept:recent-activity`.
  2. `quarantine_remove` with `--kind rebuildable` or `--kind code_sign_clone` executes both `phase1` and `phase2 --grace-seconds 0` (removing the quarantined directory completely in one call), whereas `--kind ephemeral` without grace expiry remains in `.dm-quarantine` (`quarantined`) until grace elapses.
  3. `cleanup_dev_caches.sh` (`~/.gemini/tmp/*/chats`) and `cleanup_codex_documents.sh` pass `--kind ephemeral` (reclaiming aged clean scratch while preserving `<4h` or secret-containing dirs).
- [ ] **Step 2: Run the tests to verify they fail (RED)**
  Run: `bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_artifact_verdict.sh`
  Expected: `FAIL` on the new test cases.
- [ ] **Step 3: Implement the C14 & Immediate-Reap fixes**
  - Update `/Users/jleechan/projects_other/worktree_dropbox/scripts/lib/artifact_verdict.sh` (`c14_archive_origin`), `/Users/jleechan/projects_other/worktree_dropbox/scripts/lib/quarantine.sh`, `/Users/jleechan/projects_other/worktree_dropbox/scripts/cleanup_dev_caches.sh`, `/Users/jleechan/projects_other/worktree_dropbox/scripts/cleanup_codex_documents.sh`, and `/Users/jleechan/projects_other/worktree_dropbox/scripts/cleanup_tmp.sh`.
- [ ] **Step 4: Run the tests to verify they pass (GREEN)**
  Run: `bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_artifact_verdict.sh && bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_cleanup_tmp_archive_purge.sh`
  Expected: `PASS (0 failed)`.

---

## Task 4: Unify All 4 Orchestrators (`main_sweeper.sh`, `disk_audit.sh`, `pressure_sweep.sh`, `govern.sh`) & Verify End-to-End Safety Invariants

**Files:**
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/main_sweeper.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/pressure_sweep.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/scripts/govern.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/tests/test_main_sweeper.sh`
- Modify: `/Users/jleechan/projects_other/worktree_dropbox/tests/test_pressure_sweep.sh`

- [ ] **Step 1: Write failing regression tests in `tests/test_main_sweeper.sh` and `tests/test_pressure_sweep.sh`**
  Add positive and negative end-to-end assertions that:
  1. `scripts/main_sweeper.sh --clean` runs `cleanup_task_scratch.sh`, `cleanup_codex_documents.sh`, `cleanup_code_sign_clones.sh`, and `cleanup_dirs_cleaner.sh` in default `--clean` mode.
  2. `scripts/main_sweeper.sh --clean` skips `cleanup_worktrees.sh`, `cleanup_worktree_venvs.sh`, `cleanup_worktree_deps.sh`, and `cleanup_claude_state.sh` when `WORKTREE_APPROVED` and `CLAUDE_STATE_APPROVED` are unset/`0`, and runs them when `--with-worktrees` / `WORKTREE_APPROVED=1` and `--with-claude-state` / `CLAUDE_STATE_APPROVED=1` are set.
  3. **End-to-End Safety Matrix through `main_sweeper.sh --clean --with-worktrees` (Positive + Negative):**
     - **3d/7d Recency Floors:** A clean merged worktree aged `>4d` has its worktree/deps removed (positive), while a clean merged worktree aged `<2d` is preserved (negative); a dormant worktree venv aged `>8d` is stripped (positive), while a worktree venv aged `<5d` is preserved (negative).
     - **Git Reachability & Dirty Check:** A dirty or unpushed worktree/task-scratch repo aged `>10d` is preserved (negative), while a clean pushed repo aged `>10d` is removed (positive).
     - **Secret-Like Files:** A candidate containing `.env.secret` or `credentials.json` is preserved (`kept:secret-like`, negative).
     - **AO Worktree Protection:** A dormant `>10d` worktree under an AO `worktreeDir` (or with an unreadable `DISK_MAGICIAN_AO_CONFIG`) is preserved (`ao-owned` / `ao-config-unreadable`, negative).
     - **`never_delete` Invariant:** Canary files placed under mocked `$HOME/.codex/sessions`, `$HOME/.codex/state_5.sqlite`, `$HOME/.codex/log`, and `$HOME/.claude/projects` remain 100% untouched after `main_sweeper.sh --clean --with-worktrees --with-claude-state` (negative).
  4. `scripts/pressure_sweep.sh` and `scripts/govern.sh` delegate their cleanup tier execution through `scripts/main_sweeper.sh` (`--pressure-only` / `--tier`), run a final `quarantine_reconcile` pass, and record `df_before_free_gb`, `df_after_free_gb`, and `df_reclaimed_gb`.
- [ ] **Step 2: Run the tests to verify they fail (RED)**
  Run: `bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_main_sweeper.sh && bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_pressure_sweep.sh`
  Expected: `FAIL`.
- [ ] **Step 3: Implement unified 7-tier execution across `main_sweeper.sh`, `pressure_sweep.sh`, and `govern.sh`, and sync `src/disk_magician/`**
  - Update `/Users/jleechan/projects_other/worktree_dropbox/scripts/main_sweeper.sh`, `/Users/jleechan/projects_other/worktree_dropbox/scripts/pressure_sweep.sh`, and `/Users/jleechan/projects_other/worktree_dropbox/scripts/govern.sh`.
  - Run `bash /Users/jleechan/projects_other/worktree_dropbox/disk_magician.sh sync-package-tree`.
- [ ] **Step 4: Run full verification suite (GREEN)**
  Run:
  ```bash
  bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_main_sweeper.sh
  bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_pressure_sweep.sh
  bash /Users/jleechan/projects_other/worktree_dropbox/tests/test_cli_cleanup_unified.sh
  python3 -m unittest /Users/jleechan/projects_other/worktree_dropbox/tests/test_c14_fast_path.py
  bash /Users/jleechan/projects_other/worktree_dropbox/disk_magician.sh sync-package-tree --check
  bash /Users/jleechan/projects_other/worktree_dropbox/disk_magician.sh check-version
  ```
  Expected: All tests and package sync gates exit `0`.

---

## TDD Plan Check

- [x] Every code-changing task (Tasks 1–4) follows strict `Write failing test (RED) -> Verify failure -> Implement minimal fix -> Verify pass (GREEN)`.
- [x] Exact file paths (`/Users/jleechan/projects_other/worktree_dropbox/...`) and runnable test commands are specified for every task.
- [x] Positive and negative tests are explicitly included in Tasks 1–4 for: `WORKTREE_APPROVED` / `CLAUDE_STATE_APPROVED` opt-in gates (Task 1 & Task 4), 4-orchestrator unification across `main_sweeper.sh`/`disk_audit.sh`/`pressure_sweep.sh`/`govern.sh` (Task 1 & Task 4), `flock`-serialized SQLite lease store with legacy JSON drain and `phase1` lookup-to-rename TOCTOU prevention (Task 2), SHA256 content mismatch even with restored `mtime_ns` (Task 2), per-candidate `lsof` open-file rejection (Task 2), mid-batch `SIGKILL` recovery (Task 2), archive/quarantine retention windows (Task 3), and end-to-end 3d/7d recency, git reachability, secret-like, AO ownership, and `never_delete` protections through `main_sweeper.sh` (Task 4).

## Implementation Preconditions

1. **Isolated Worktree for Implementation:** Start implementation in a fresh isolated worktree created via `diskm worktree-new` (or `git worktree add`) from `origin/main` after the current wave of bugfix PRs (`#186`, `#188–#205`) is reviewed/merged.
2. **Package Sync & Deploy After Merge:** Once merged to `origin/main`, bump `pyproject.toml`, run `scripts/sync_package_tree.sh`, and run `tools/deploy_uv_tool.sh` so `~/.local/share/uv/tools/disk-magician/bin/diskm` and launchd jobs run the unified code.
