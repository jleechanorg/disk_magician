# Snapshot Measurement Budget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure the allowlist snapshot completes inside the 35-minute cadence even when individual filesystem walks stall.

**Architecture:** Keep measurement in the existing `dir_size_kb` boundary. Use the installed parallel `dua` utility first, cap each path by a shared per-path ceiling and remaining global measurement deadline, and allow `du` only as a compatibility fallback within the same path deadline. Preserve the existing config allowlist, allocated-byte semantics, timeout/null reporting, and dedup pass.

**Tech Stack:** Bash, `dua`, platform `du`, `timeout`, Python JSON assertions.

## Global Constraints

- Base is current `origin/main` at `6bb839cc11d4eb68d91be55975134fa2e1f72a7c`.
- Do not stop the running snapshot, delete data, or reload unrelated launchd jobs.
- Do not modify PR 10 or its worktree.
- Write and observe RED tests before production code.
- Do not sync/package/version/deploy until independent review approves the root diff.
- Commit often, push, open a PR, and never merge.

---

### Task 1: Bounded allowlist measurement

**Files:**
- Modify: `tests/test_snapshot_audit_coverage.sh`
- Modify: `scripts/disk_snapshot.sh`

**Interfaces:**
- Consumes: config `timeout`, `DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS`, and `DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS`.
- Produces: existing integer/null directory values plus additive measurement-budget metadata.

- [ ] Add a test fixture whose fake `dua` and `du` both stall; assert `dua` runs first, each path stays within the per-path cap, the total run stays within its global budget, and unmeasured keys remain null.
- [ ] Add a real-utility fixture with a sparse file and hard link; assert the snapshot value equals `du -sk` and dedup output remains valid.
- [ ] Run the new section and observe the expected RED failures.
- [ ] Parse the last numeric `dua` row, switch it to primary, and bound both utilities by one path deadline and the remaining global deadline.
- [ ] Apply the remaining global budget to glob and container measurements without adding new paths.
- [ ] Emit budget seconds, elapsed seconds, and exhaustion state in snapshot metadata.
- [ ] Run targeted and safety tests; commit and push the root diff.

### Task 2: Independent review gate

**Files:**
- Review only: `scripts/disk_snapshot.sh`
- Review only: `tests/test_snapshot_audit_coverage.sh`

**Interfaces:**
- Produces: approve/block verdict covering timeout correctness, size parity, dedup preservation, and protected-path scope.

- [ ] Dispatch an independent mid-tier reviewer against the exact commit.
- [ ] Address blockers with RED/GREEN tests and push a new commit.
- [ ] Re-review until no blocking findings remain.

### Task 3: Package, deploy, and live proof

**Files:**
- Modify after review: `pyproject.toml`
- Generate after review: `src/disk_magician/scripts/disk_snapshot.sh`

**Interfaces:**
- Produces: version-bumped uv deployment whose script hash matches root/package/deployed copies.

- [ ] Bump the package patch version and run `scripts/sync_package_tree.sh`.
- [ ] Run package parity and full targeted tests; commit and push.
- [ ] Force-reinstall the uv tool without stopping the in-flight snapshot.
- [ ] Verify root/package/deployed hashes and exercise a sandboxed bounded snapshot.
- [ ] Open an unmerged PR and report exact commits, tests, deployment evidence, and tier.
