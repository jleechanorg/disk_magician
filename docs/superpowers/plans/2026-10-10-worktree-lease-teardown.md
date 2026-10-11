# Worktree Lease Teardown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record an owner lease for every worktree under `~/.worktrees`. Reap the safe ones once the owner process exits, refuse new worktrees when disk is critically low, and report all of it in `diskm status`.

**Architecture:** A bash lease library writes JSON lease files to `~/.disk_magician_state/worktree_leases/`.
- `worktree_new.sh` and `worktree_create_hook.sh` write the leases.
- A new `worktree_reap.sh`, dispatched as `diskm worktree-reap` and run by launchd every 30 min, checks owner liveness by pid plus `lstart`. It then applies a removal verdict extracted from the existing `wrh_main`.
- Removal is gated by `DISK_MAGICIAN_REAP_MODE` (`nominate` by default).

**Tech Stack:** bash 3.2-compatible shell, python3 stdlib for JSON, git, launchd. Tests are self-contained bash scripts under `tests/` using the repo's `ok`/`bad` style.

**Spec:** `docs/superpowers/specs/2026-10-10-worktree-lease-teardown-design.md`

## Global Constraints

- Lease dir: `~/.disk_magician_state/worktree_leases/<sha256(realpath)[:16]>.json`, `schema_version` 1, written via temp file plus `mv`.
- Owner runtimes (basename match): `claude`, `codex`, `agy`, `cursor-agent`, `hermes`. With no runtime ancestor, `owner` is null and the lease is never owner-reaped.
- Lease TTL: `ttl_hours` default 24, report-only (`kept:owner-alive-expired`). Removal candidates are only `dead` (quiet `REAP_QUIET_MINUTES` 30) or `released` (quiet `REAP_RELEASED_QUIET_MINUTES` 30). An alive owner is never removed.
- Pushed proof for the reaper: `wrh_removal_verdict ... origin-or-merged-pr`, meaning either HEAD is contained in `refs/remotes/origin/*` after `GIT_TERMINAL_PROMPT=0 git -c gc.auto=0 -c maintenance.auto=false fetch --quiet --prune origin`, or HEAD equals a gh-verified MERGED PR head via `scripts/lib/worktree_merged_pr.sh` (Task 3b).
- Reason tokens (fixed set): `not-registered`, `live-cwd`, `cwd-unknown`, `ao-owned`, `ao-config-unreadable`, `not-a-directory`, `git-status-failed`, `recent-activity`, `dirty`, `hidden-state`, `ignored-data`, `not-pushed`, `remote-unverified`, `locked`, `safety-local`, `owner-alive-expired`, `lease-unreadable`, `remove-failed`.
- Leases carry `admin_id` and `admin_birth_epoch` (`stat -f %B` of `<main>/.git/worktrees/<id>`). A mismatch with the live admin dir marks the lease stale, and it is re-adopted with `owner: null`. The reaper and the remove hook delete the lease after a successful removal; `cleanup_worktrees.sh` removals are retired by prune plus the incarnation check.
- Base: `main` at or after `b776e56`; the remove hook there has the live-cwd, AO, recency, hidden-state and ignored-data checks.
- Dead ⇔ the pid field is a valid integer and `ps` returns rc 1 with empty stderr. Anything else is `unknown` (keep), or `lease-unreadable` for an invalid pid.
- Owner start time: `LC_ALL=C TZ=UTC ps -p <pid> -o lstart=` parsed with `%a %b %d %H:%M:%S %Y` to a UTC epoch, stored as `start_epoch`. Alive ⇔ the epochs differ by ≤2 s. Never compare raw `lstart` strings. If `ps` fails, the state is unknown, which means keep.
- Hermes owner match: a `python*` process whose script argument's basename starts with `hermes`.
- Reaper quiet period for a dead owner: `REAP_QUIET_MINUTES` default 30. One bounded `git fetch --quiet --prune origin` (60 s) per repo per run; a failed fetch means `kept:remote-unverified`. `scripts/safety_check.sh <path>` must pass. Interval 1800 s. `DISK_MAGICIAN_REAP_MODE` ∈ {`nominate` (default), `remove`}.
- Admission: `WORKTREE_ADMIT_WARN_GB` default 25 (warn only), `WORKTREE_ADMIT_MIN_GB` default 10 (0 disables), refusal exit code 75. The gate never calls the reaper.
- Status degraded when the root is >60 GiB, or when owner-dead `kept:*` leases number >100.
- Never `git worktree remove --force`. Only delete `worktree-*` branches, and only when they are not checked out elsewhere.
- All entry points go through `disk_magician.sh` / `diskm`. No new standalone runner.
- After script changes: `scripts/sync_package_tree.sh`, bump `pyproject.toml` version, then deploy with `tools/deploy_uv_tool.sh` from a clean `origin/main` checkout.
- Never run `plutil -extract` without `-o -`.

## Review Focus

1. **pid reuse.** The owner pid has been reused by an unrelated process. The `lstart` mismatch must count as dead, not alive. Tested in Task 2.
2. **Sibling handoff, or a long-lived session coming back.** The owner died (or its lease expired) but an agent is still editing the worktree. The quiet period or the live cwd check must keep it. Tested in Task 5.
3. **Corrupt or unreadable lease JSON.** The reaper must keep the worktree, log it, and continue with the others. Tested in Task 5.
4. **Worktree deleted outside diskm.** The lease is pruned and the reaper doesn't error. Tested in Task 5.
5. **Admission gate when `df` fails.** `worktree-new` must not refuse because of an unmeasurable disk (fail open for creation, logged). Tested in Task 7.

## TDD Plan Check

| Task | Sequence checked |
|---|---|
| 1 | RED `test_worktree_recency.sh` cases 6–7 → impl → GREEN plus the existing cases |
| 2 | RED `test_worktree_lease.sh` → impl → GREEN |
| 3 | Behavior-preserving refactor: new direct-call case RED (function missing) → extract → GREEN, with all existing remove-hook assertions still passing |
| 3b | RED `test_worktree_merged_pr.sh` → move the logic into the library → GREEN, with existing `cleanup_worktrees` suites unchanged |
| 4 | RED lease-written assertions in `test_worktree_new.sh` / `test_worktree_create_hook.sh` → impl → GREEN |
| 5 | RED `test_worktree_reap.sh` → impl → GREEN |
| 6 | RED dispatch and template assertions → impl → GREEN |
| 7 | RED admission cases → impl → GREEN |
| 8 | RED `test_disk_status.py` worktrees section → impl → GREEN |
| 9 | Conditional on P1. RED: the template test expects `remove` → template and CLAUDE.md change → GREEN |
| 10 | TDD: N/A (deploy). Verification: the `deployed.json` revision equals the merge SHA, and a reaper receipt exists ≤35 min after install |

## Implementation Preconditions

- **P1 (user).** Approval of the narrow CLAUDE.md "Worktree 7-day rule" exception in spec §8. Task 9 runs only after it.
- **P2.** [PR #146](https://github.com/jleechanorg/disk_magician/pull/146) is merged, and this branch is rebased on `main` before Task 5.
- **P3.** If [PR #131](https://github.com/jleechanorg/disk_magician/pull/131) lands first, `has_ignored_user_data` lives in `scripts/lib/worktree_ignored.sh`. Task 3's extraction sources that file instead of moving the function. #131 and #146 touch the same functions in `cleanup_worktrees.sh` and `worktree_remove_hook.sh`, so rebase whichever merges second.

---

### Task 1: Minute-granularity recency

**Files:**
- Modify: `scripts/lib/worktree_recency.sh`
- Test: `tests/test_worktree_recency.sh`

**Interfaces:**
- Produces: `worktree_is_recently_active_minutes <path> <min_minutes> [now]`. rc 0 means too young (keep), rc 1 means old enough. An unmeasurable path gives rc 0.

- [ ] **Step 1: Write the failing tests.**
  - Case 6: a fixture worktree whose newest file is 45 min old gives `worktree_is_recently_active_minutes "$wt" 30` → rc 1, and `... 60` → rc 0.
  - Case 7: a nonexistent path → rc 0.
  - Use the `now` argument for determinism, like the existing cases.
- [ ] **Step 2: Run** `bash tests/test_worktree_recency.sh`. Expected: cases 6 and 7 FAIL (function not found).
- [ ] **Step 3: Implement.** Reuse `worktree_last_activity_epoch`; compare `now - epoch` against `min_minutes*60`. Fail closed when the epoch is empty.
- [ ] **Step 4: Run** `bash tests/test_worktree_recency.sh`. Expected: all PASS.
- [ ] **Step 5: Commit** `feat: minute-granularity worktree recency helper`.

### Task 2: Lease library

**Files:**
- Create: `scripts/lib/worktree_lease.sh`
- Test: `tests/test_worktree_lease.sh`

**Interfaces:**
- Produces:
  - `lease_dir` prints the lease directory (honors `DISK_MAGICIAN_STATE_DIR`).
  - `lease_path_for <worktree_path>` prints the lease file path.
  - `lease_resolve_owner [start_pid]` prints `pid<TAB>start_epoch<TAB>comm` of the nearest runtime ancestor, or `-<TAB>-<TAB>-` when none (the lease is then written with `owner: null`).
  - `lease_write_pending <target_path> <owner_tsv>` writes a pending lease with `creator: "guard"`. rc 1 and nothing written if the path exists, or if a lease exists for an existing worktree. It replaces a lease whose path no longer exists.
  - `lease_matches_incarnation <lease_file>` returns rc 0 when `admin_id` and `admin_birth_epoch` match the live admin dir; rc 1 otherwise.
  - `lease_write <worktree_path> <repo> <branch> <creator>`: atomic write with the owner resolved from `$$`. rc 0 on success.
  - `lease_owner_state <lease_file> [now_epoch]` prints `none|released|dead|alive|alive-expired|unknown|unreadable`. `unreadable` (non-integer pid or bad JSON) maps to `kept:lease-unreadable`.
    - Precedence: `none` (owner null) > `released` > a `ps` check.
    - The `ps` check gives `dead`, or `unknown` when `ps` fails other than "no such process".
    - Otherwise it gives `alive-expired` when `created_at + ttl_hours` has passed, else `alive`.
  - `lease_release <worktree_path>` sets `released_at`. rc 1 if there is no lease.
  - `lease_set_verdict <lease_file> <verdict>` updates `last_verdict` and `last_checked_at`.
- Test hook: `DISK_MAGICIAN_PS_BIN` overrides `ps` for the tests.

- [ ] **Step 1: Write failing tests.**
  - `lease_write` creates valid JSON with `schema_version==1` and the given `path`, `branch` and `creator`.
  - `lease_owner_state` returns:
    - `alive` when a fake `ps` echoes the same start time
    - `alive` when the lease is written under `TZ=America/Los_Angeles LANG=fr_FR.UTF-8` and checked under `TZ=UTC LANG=C` (the real `ps` with `$$`)
    - `dead` when the fake `ps` exits 1
    - `dead` when the fake `ps` returns a start time 10 s different (pid reuse, Review Focus 1)
    - `unknown` when the fake `ps` exits 2 with no output (treat any non-1 failure as unknown)
    - `none` for an `owner: null` lease
  - `lease_resolve_owner`, given a fake ps tree `500 sh → 400 claude → 1 launchd`, returns pid 400 / comm `claude`. With no runtime in the chain it returns `-`, and `lease_write` stores `owner: null`.
  - A lease created 25 h ago with an alive owner returns `alive-expired`. After `lease_release`, the state is `released`.
  - A fake ps tree `600 Python /opt/hermes/hermes_gateway.py → 1` resolves the owner to pid 600.
  - `lease_owner_state` with pid field `99999999999` and a fake `ps` printing `ps: process id too large` (rc 1) → `unknown`, not `dead`. A pid field `abc` → `unreadable`.
  - `lease_write` records `admin_id` and `admin_birth_epoch` matching `stat -f %B` of the fixture's admin dir, plus integer `created_epoch`.
  - `lease_write_pending` on an existing path, or when a lease already exists → rc 1 and the existing lease is byte-identical afterwards.
- [ ] **Step 2: Run** `bash tests/test_worktree_lease.sh`. Expected: FAIL (file missing).
- [ ] **Step 3: Implement.** Use python3 for JSON reads and writes. Write to `mktemp` in the lease dir, then `mv`.
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `feat: worktree lease library`.

### Task 3: Extract `wrh_removal_verdict`

**Files:**
- Modify: `scripts/worktree_remove_hook.sh` (also delete the lease after a successful removal when `scripts/lib/worktree_lease.sh` is present)
- Test: `tests/test_worktree_remove_hook.sh`

**Interfaces:**
- Produces:
  - `wrh_removal_verdict <real_path> <recency_spec> [pushed_scope]`, where `recency_spec` is `days:N` or `minutes:N` and `pushed_scope` is `all-remotes` (the hook's default), `origin`, or `origin-or-merged-pr`. `origin-or-merged-pr` calls `worktree_head_is_merged_pr` from Task 3b. It prints `remove` or `kept:<token>` from the Global Constraints token set, and always returns rc 0.
  - `wrh_main` maps each token to its existing prose log line, so the hook's log output is unchanged.
  - `wrh_remove_now <real_path>` runs the existing `git worktree remove` plus `worktree-*` branch deletion. rc 0 if removed.
- `wrh_main` becomes: parse stdin → standard-root check → `wrh_removal_verdict "$real" days:7` → log → `wrh_remove_now`.

- [ ] **Step 0:** Confirm the base is `main` ≥ `b776e56`: `git merge-base --is-ancestor b776e56 HEAD`.
- [ ] **Step 1: Write the failing test.** A new case sources the script and calls `wrh_removal_verdict`:
  - a clean pushed fixture aged 10 days with `days:7` → `remove`
  - a fixture last touched 5 min ago with `minutes:30` → `kept:recent-activity`
  - a fixture whose HEAD is only on a `fork` remote, with `origin` scope → `kept:not-pushed`
- [ ] **Step 2: Run** `bash tests/test_worktree_remove_hook.sh`. Expected: the new case FAILS and every existing assertion still passes.
- [ ] **Step 3: Implement** the extraction. Keep the check order and log text unchanged.
- [ ] **Step 4: Run** the test. Expected: all PASS, and the existing log-line assertions are unchanged.
- [ ] **Step 5: Commit** `refactor: extract wrh_removal_verdict from remove hook`.

### Task 3b: Extract the merged-PR-head proof

**Files:**
- Create: `scripts/lib/worktree_merged_pr.sh`
- Modify: `scripts/cleanup_worktrees.sh` (replace the inline merged-PR logic in `classify_content_and_merge` and the `populate_repo_pr_cache` body with calls into the library)
- Test: `tests/test_worktree_merged_pr.sh` (new), plus the existing `tests/test_cleanup_worktrees_merged_fastpath.sh` and `tests/test_cleanup_worktrees_repo_local.sh`

**Interfaces:**
- Produces:
  - `worktree_pr_cache_populate <main_repo>` (the same gh query and cache file as today)
  - `worktree_head_is_merged_pr <main_repo> <branch> <head_sha>`: looks up PRs by `headRefName` (as `populate_repo_pr_cache` does today). rc 0 only when a gh-verified MERGED PR for that branch has exactly that head; rc 1 otherwise, including on gh failure or an empty branch (detached HEAD), so it fails closed.
  - The library owns its cache dir (`${DISK_MAGICIAN_STATE_DIR:-~/.disk_magician_state}/pr_cache/`, files named by owner_repo, TTL 1 h) instead of the caller's `RUN_TMP`.

- [ ] **Step 1: Write failing tests.** With a mocked `gh` on PATH returning one MERGED PR with head `abc123` and one OPEN PR:
  - `abc123` → rc 0
  - the OPEN PR's head → rc 1
  - `gh` exiting 1 → rc 1
  - an empty branch (detached HEAD) → rc 1 without calling `gh`
- [ ] **Step 2: Run** `bash tests/test_worktree_merged_pr.sh`. Expected: FAIL (file missing).
- [ ] **Step 3: Implement** by moving the existing lookup logic into the library under the new signature; `cleanup_worktrees.sh` sources it and passes the branch it already has. Sourcing the library must run no top-level code.
- [ ] **Step 4: Run** the new test plus `test_cleanup_worktrees_merged_fastpath.sh`, `test_cleanup_worktrees_repo_local.sh` and `test_cleanup_worktrees_single_age_walk.sh`. Expected: all PASS, with unchanged verdicts for the sqmatch/sqdiff fixtures.
- [ ] **Step 5: Commit** `refactor: extract merged-PR-head proof into scripts/lib`.

### Task 4: Write leases at creation

**Files:**
- Modify: `scripts/worktree_new.sh` (after a successful `wtn_create` in `wtn_main`), `scripts/worktree_create_hook.sh` (in `wth_main`, after the path is created), and `scripts/worktree_guard.py` (on an allowed, statically resolved `git worktree add`, write a pending lease through the lease library resolved from `os.path.dirname(__file__)`, not the cwd; fail open)
- Test: `tests/test_worktree_guard.py`
- Test: `tests/test_worktree_new.sh`, `tests/test_worktree_create_hook.sh`

**Interfaces:**
- Consumes: `lease_write` (Task 2).
- `creator` values: `worktree-new` and `worktree-create-hook`.

- [ ] **Step 1: Write failing tests.**
  - After `worktree_new.sh <repo> feat/x`, `lease_path_for <printed path>` exists with `creator=="worktree-new"`.
  - After the create hook, `creator=="worktree-create-hook"`.
  - A failing lease write (read-only lease dir) still prints the path and exits 0, logging `lease write failed`.
  - The guard, given `git worktree add ~/.worktrees/r/x -b x` under a fake ps tree with `claude`, writes a pending lease with `creator=="guard"` and the claude pid. An unresolvable target writes nothing. The guard's allow/deny output is unchanged.
- [ ] **Step 2: Run** both tests. Expected: the new assertions FAIL.
- [ ] **Step 3: Implement.** Call `lease_write ... || log`. Stdout must stay exactly the path.
- [ ] **Step 4: Run** both tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat: write worktree lease on creation`.

### Task 5: Reaper

**Files:**
- Create: `scripts/worktree_reap.sh`
- Test: `tests/test_worktree_reap.sh`

**Interfaces:**
- Consumes:
  - `lease_*` (Task 2)
  - `wrh_removal_verdict ... origin-or-merged-pr` and `wrh_remove_now` (Task 3, Task 3b)
  - `worktree_is_recently_active_minutes` (Task 1)
  - `scripts/job_receipt.py` (existing; the same `begin`/`finish` calls as `pressure_sweep.sh`)
  - The pressure sweep's stale-lock aging pattern
- Produces:
  - CLI `worktree_reap.sh [--mode nominate|remove] [--deadline-seconds N]` (default 1500). The `--mode` flag overrides `DISK_MAGICIAN_REAP_MODE`.
  - Receipt job `worktree_reap`, whose `candidates` hold counts per verdict and `postcondition.freed_bytes` from the `df` delta.
  - Lock dir `$STATE/worktree_reap.lock`.

- [ ] **Step 1: Write failing tests.** Use fixtures under a temp `STANDARD_WORKTREE_ROOT`, a fake `ps`, and a temp `DISK_MAGICIAN_STATE_DIR`.
  - Unleased registered worktree → a lease is created with `creator=="adopt"` and `owner==null`, and it is not removed.
  - Owner alive → kept, `last_verdict` unchanged, worktree present.
  - Owner dead, clean, pushed, quiet 40 min:
    - nominate mode → `last_verdict=="remove"` and the worktree is present
    - remove mode → the worktree is gone and the lease is deleted
  - Owner dead, dirty → `kept:dirty`, present in both modes.
  - Owner dead, quiet 5 min → `kept:recent-activity` (Review Focus 2).
  - Lease expired with the owner alive, quiet 7 h → `kept:owner-alive-expired` in both modes.
  - Released lease with the owner alive, quiet 40 min → `remove` verdict. Quiet 5 min → `kept:recent-activity`.
  - `owner: null` lease, clean and pushed, in **remove** mode → still present, not reaped.
  - HEAD only on a `fork/*` ref → `kept:not-pushed`. HEAD equal to a mocked gh MERGED PR head with the branch deleted → `remove` verdict.
  - A pending guard lease plus a registered worktree whose admin-dir birth time is ≥ the lease's `created_epoch` → promoted, `creator` stays `guard`, owner kept. Include a same-second case: birth equal to `created_epoch` → promoted.
  - A pending lease whose `created_epoch` is greater than the admin-dir birth time fails promotion (the worktree predates it); the worktree is adopted with `owner: null`.
  - Path reuse: a lease with a dead owner exists for path P; P is removed and recreated with a new admin dir → the lease is detected stale and re-adopted with `owner: null`, never nominated.
  - Removal in remove mode deletes the lease file.
  - A worktree locked via `git worktree lock` → `kept:locked` (a new check, stricter than the current hook).
  - Receipt `candidates` include `fetch_ok`, `fetch_failed`, `gh_ok` and `gh_failed` counters.
  - A pending lease 2 h old with no worktree → deleted.
  - A stale lock dir with a dead pid, older than the TTL → reclaimed, the run proceeds.
  - A run sent TERM mid-loop → lock released, and the next run is not `skipped_lock`.
  - `--deadline-seconds 1` with 3 candidates → stops between candidates, receipt `outcome="partial"`, lock released.
  - Fake `git fetch` failing for the repo → `kept:remote-unverified`.
  - Path listed in a temp `safety.local.json` `never_delete` → `kept:safety-local`.
  - Owner dead, a live process cwd inside the worktree (spawn `sleep` with that cwd) → kept, live-cwd reason.
  - Corrupt lease JSON → logged `kept:lease-unreadable`, and other leases are still processed (Review Focus 3).
  - Lease for a path that no longer exists → lease deleted, rc 0 (Review Focus 4).
  - A second concurrent run while the lock is held → exits 0 with `skipped_lock`.
  - The receipt `last_terminal.outcome` is `success` with verdict counts.
- [ ] **Step 2: Run** `bash tests/test_worktree_reap.sh`. Expected: FAIL (script missing).
- [ ] **Step 3: Implement** the adopt → owner check → quiet → verdict → mode → prune → receipt order from spec D2. Removal happens only when the mode is `remove`.
- [ ] **Step 4: Run** the test, plus `tests/test_worktree_remove_hook.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: worktree lease reaper (nominate by default)`.

### Task 6: Dispatch, launchd job, package

**Files:**
- Modify: `disk_magician.sh` (help text near line 58; case arm next to `worktree_remove_hook|worktree-remove-hook)` at line 376)
- Modify: `scripts/install_launchd_sweepers.sh` (job list near line 114)
- Create: `launchd/com.jleechanorg.disk-magician-worktree-reap.plist.template` (copy the pressure-sweep template shape: `ProgramArguments` `@HOME@/.local/bin/diskm worktree-reap`, `StartInterval` 1800, log `@HOME@/Library/Logs/disk-magician-worktree-reap.log`, no `DISK_MAGICIAN_REAP_MODE` env, so `nominate` applies)
- Modify: `scripts/check_launchd_fleet.sh` expected-job list, if it enumerates labels
- Modify: the `sweeper-health` job table (grep `pressure_sweep` in `scripts/sweeper_health*` / `scripts/disk_status.py`) to include the `worktree_reap` receipt
- Test: `tests/test_worktree_reap_dispatch.sh` (new, modeled on `tests/test_sweeper_health_dispatch.sh`)

**Interfaces:**
- Consumes: `scripts/worktree_reap.sh` (Task 5).
- Produces: the `diskm worktree-reap` and `diskm worktree-release <path>` subcommands. `worktree-release` calls `lease_release` and never deletes.

- [ ] **Step 1: Write failing tests.**
  - `bash disk_magician.sh worktree-reap --mode nominate` with a temp state dir exits 0 and writes `receipts/worktree_reap.json`.
  - `bash disk_magician.sh worktree-release <leased path>` exits 0 and the lease has `released_at`. On an unleased path it exits 1 with `no lease`.
  - `plutil -lint` passes on the rendered template.
  - The template has no `DISK_MAGICIAN_REAP_MODE` key, read with `plutil -p` only.
  - The template's `EnvironmentVariables.PATH` contains `@HOME@/.local/bin` and `/opt/homebrew/bin`. `GIT_TERMINAL_PROMPT` is `0` and `GIT_SSH_COMMAND` contains `BatchMode=yes`.
  - Running `env -i HOME=$HOME PATH=<template PATH> bash disk_magician.sh worktree-reap --mode nominate` resolves `gh` and `timeout` (the receipt's `gh_failed` is 0 against a mocked repo with a cached PR).
  - `bash disk_magician.sh sweeper-health` output lists `worktree_reap` with its last outcome.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement** the arm, help line, template and installer entry. Run `scripts/sync_package_tree.sh`.
- [ ] **Step 4: Run** the new test and `scripts/sync_package_tree.sh --check`. Expected: PASS, 0 drift.
- [ ] **Step 5: Commit** `feat: diskm worktree-reap dispatch and launchd job`.

### Task 7: Admission gate

**Files:**
- Modify: `scripts/worktree_new.sh` (`wtn_main`, before `wtn_create`)
- Test: `tests/test_worktree_new.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Test hook: `DISK_MAGICIAN_FREE_GB_OVERRIDE` (same name as the pressure sweep).

- [ ] **Step 1: Write failing tests.**
  - Free 50 → creates, no warning.
  - Free 20 → creates; stderr has `low disk (20 GiB free)` and stdout is still exactly the path.
  - Free 5 → exit 75. Stderr contains `disk low (5 GiB free): reuse an existing worktree`, and no worktree dir is created.
  - `WORKTREE_ADMIT_MIN_GB=0` with free 5 → creates.
  - Free measurement fails (override `x`) → creates and logs `free-space unmeasurable` (Review Focus 5).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Use `df -kP` on `$STANDARD_WORKTREE_ROOT` (or `/System/Volumes/Data`). Warnings and the refusal go to stderr only.
- [ ] **Step 4: Run** `bash tests/test_worktree_new.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: free-space admission gate for worktree-new`.

### Task 8: Status reporting

**Files:**
- Modify: `scripts/disk_status.py`
- Test: `tests/test_disk_status.py`

**Interfaces:**
- Produces: a `status --json` key `worktrees`, holding:
  - `leases` (counts by `owner_state`)
  - `verdicts` (counts by `last_verdict`)
  - `coverage` (share of leases with a non-null owner, by creator)
  - `created_per_day_7d` (float)
  - `root_gb` (from the latest observer/snapshot bucket for `~/.worktrees`, or null)
  - `degraded_reasons` (list)

- [ ] **Step 1: Write failing tests.**
  - With fixture leases (3 alive, 120 dead with `kept:dirty`) and `root_gb` 70: `degraded_reasons` contains `worktree_root_over_60gb` and `owner_dead_kept_over_100`, and the overall status is `degraded`.
  - With 0 leases and `root_gb` null: no `worktrees` degraded reason.
- [ ] **Step 2: Run** `python3 -m pytest tests/test_disk_status.py -q -k worktrees`. Expected: FAIL.
- [ ] **Step 3: Implement**, reading lease files with the stdlib `json` module and skipping unreadable files with a counter.
- [ ] **Step 4: Run** the full `tests/test_disk_status.py`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: worktree lease section in diskm status`.

### Task 9 (conditional on P1): Enable remove mode

**Files:**
- Modify: `launchd/com.jleechanorg.disk-magician-worktree-reap.plist.template` (add `EnvironmentVariables.DISK_MAGICIAN_REAP_MODE=remove`)
- Modify: `CLAUDE.md` § "Worktree 7-day rule (hard)": append the approved exception text verbatim from spec §8 P1, with the approval date.
- Test: `tests/test_worktree_reap_dispatch.sh`

- [ ] **Step 1:** Flip the template assertion to expect `DISK_MAGICIAN_REAP_MODE` = `remove`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3:** Edit the template and CLAUDE.md, then run `scripts/sync_package_tree.sh`.
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Commit** `feat: enable owner-exit worktree removal (user-approved <date>)`.

### Task 10: Deploy and verify

TDD: N/A. This task deploys; verification is listed below.

- [ ] Bump the `pyproject.toml` version, then merge through the normal `/green` + `/advice` gates.
- [ ] From a clean checkout equal to `origin/main`, run `tools/deploy_uv_tool.sh` and then `bash scripts/install_launchd_sweepers.sh`.
- [ ] **Verify:**
  - `diskm check-launchd-fleet` shows `com.jleechanorg.disk-magician-worktree-reap` loaded.
  - `~/.disk_magician_state/deployed.json` revision equals the merge SHA.
  - Within 35 min, `receipts/worktree_reap.json` has `last_terminal.outcome=="success"`, `fetch_ok > 0`, and `gh_ok > 0` (or `gh_failed == 0` when no candidate needed the merged-PR proof).
  - `diskm status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["worktrees"])'` shows lease counts.
- [ ] After 7 days in nominate mode, record projected reclaim (`verdicts.remove` × measured sizes) on bead `disk_magician-oyt4` as P1 decision input.
