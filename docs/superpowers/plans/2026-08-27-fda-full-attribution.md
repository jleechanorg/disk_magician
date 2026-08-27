# FDA Full Attribution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Disk Magician publish and attribute only a current, FDA-verified full 5-GiB ledger.

**Architecture:** The frontier scanner emits an FDA and coverage envelope; the renderer accepts only a fresh complete envelope. History diff shares the snapshot state-repo resolver.

**Tech Stack:** Python 3, Bash, Git state repository, launchd.

---

### Task 1: Unify history state-repository resolution

**Files:**
- Modify: `scripts/history_diff.py`
- Test: `tests/test_history_diff.py`

1. Write a failing test with a configured `state_repo_path` distinct from XDG.
2. Run `python3 tests/test_history_diff.py`; expect failure.
3. Invoke `resolve_state_repo_path.py` from `history_diff.py` when no override is supplied.
4. Re-run the test; expect pass.
5. Commit the focused change.

### Task 2: Add scanner-process FDA evidence

**Files:**
- Modify: `scripts/disk_frontier_scan.py`
- Test: `tests/test_frontier_scan.sh`

1. Write a failing fixture asserting MobileSync, Mail, and Messages preflight statuses appear in JSON.
2. Run the focused test; expect failure.
3. Add read-only stat/list preflight with readable, denied, and missing outcomes.
4. Re-run the test; expect pass.
5. Commit the focused change.

### Task 3: Gate mega-table publication on complete coverage

**Files:**
- Modify: `scripts/render_topdown_ledger.py`, `scripts/snapshot_commit.sh`
- Test: `tests/test_render_topdown_ledger.py`, `tests/test_snapshot_commit.sh`

1. Write failing tests for partial-envelope rejection and complete-envelope acceptance.
2. Run focused tests; expect failure.
3. Persist the explicit status and prevent a partial report from replacing a complete ledger.
4. Re-run tests; expect pass.
5. Commit the focused change.

### Task 4: Package, deploy, and capture live evidence

**Files:**
- Modify: `pyproject.toml`

1. Run `scripts/sync_package_tree.sh`.
2. Bump the package version and reinstall with `uv tool install --force --reinstall .`.
3. Run the FDA-enabled frontier job under its 2,700-second cap.
4. Validate `ledger/topdown-5g.json`, run `history diff --days 7` and `--days 30`, and record the raw outputs.
5. Run `/er` against the exact deployed result; do not call attribution full unless its coverage envelope passes.
