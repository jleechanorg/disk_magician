# Disk-Fill Durable Control Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the disk-use loop with a `diskm` budget governor: admission at creation, owner-lifecycle reclaim, and df-verified receipts. The aim is a 7-day free-space minimum of at least 80 GiB, which replaces the cycle of reclaiming space and watching it refill.

**Architecture:**
- A 10-minute `diskm govern` tick measures df and per-class usage, writes `budget.json`, and runs the existing actuators in order of class overage. Each actuator writes a receipt with `df_delta_bytes`.
- `diskm admit` reads `budget.json` at creation time.
- Leases (from #148) are generalized to all artifact kinds and released at session exit. Removal still goes only through `wrh_removal_verdict` / `wrh_remove_now`.

**Tech Stack:** Bash (scripts/, scripts/lib/), Python 3 stdlib (scripts/*.py), launchd templates, shell tests under `tests/`, and pytest for the Python twins.

**Spec:** `docs/superpowers/specs/2026-10-11-disk-fill-durable-control-design.md`
**Base:** origin/main `688fff6`, version 0.2.197. Live `df` at plan time: **7.2 GiB free**.

---

## Global Constraints

- **Entry point.** Every operation is a `diskm` subcommand added to `src/disk_magician/disk_magician.sh`. Mirror the change with `scripts/sync_package_tree.sh` and check it with `--check` in review. Do not add a second dispatcher.
- **Removal path.** Worktrees are removed only via `wrh_removal_verdict` / `wrh_remove_now` (`scripts/worktree_remove_hook.sh`). Scratch is removed only via `scratch_budget_evict_root` (`scripts/lib/scratch_budget.sh`). Write no ad-hoc `rm`. Never touch never-delete paths.
- **Recency.** Measure it only through `scripts/lib/worktree_recency.sh`. Fail closed. Every new staleness check gets a test that the unmeasurable case is protected.
- **Unknown values.** An unknown owner means alive, which means keep. An unknown measurement means admission fails open with an `admission_blind` receipt.
- **Zero Framework Cognition.** Class membership comes from a fixed governed-root path table. Hooks match literal command syntax. Neither applies keyword scoring or semantic classification.
- **Plists.** Never run `plutil -extract` without `-o -`. Templates use the `@HOME@` / `@REPO_ROOT@` substitutions handled by `scripts/install_launchd_sweepers.sh`.
- **Deploy.** Each merged PR must bump `pyproject.toml` and run `tools/deploy_uv_tool.sh` from clean origin/main. Verify `deployed.json` and one scheduled receipt before claiming the change is live.
- **PR size.** Each PR is at most 150 production lines, or it goes through the size-tiered merge gate.
- **Approvals.** No task sets `WORKTREE_APPROVED`, the remove marker, or a standing decision on the user's behalf. Only `diskm policy approve` with a literal user phrase does.

## Review Focus

1. **Every removal path is gated.** Check that each one still passes through `wrh_removal_verdict` and the byte-verified remove. Look for any new code path that deletes something.
2. **T2 cannot remove dirty, ahead-of-origin, secret-bearing, live-cwd, locked or AO items.** This is the owner-null plus 24 h inactivity tier. Each of those cases needs a negative test.
3. **The `diskm admit` hot path never runs du and never blocks when blind.** Review the exit-code table: 0, 10, 75, 76.
4. **The receipt schema change stays backward-compatible.** Old receipts without `df_delta_bytes` must still validate, while new governor receipts must have a non-null value.
5. **The standing-decision file has the right shape.** There is no expiry field, revoke works, and the literal phrase is recorded verbatim.
6. **`scratch-new --detach` stays inside the standard root.** It must refuse paths outside `~/.worktrees/<repo>/`.

## TDD Plan Check

| Task | RED test (fails before change) | GREEN condition | Layer |
|---|---|---|---|
| 0 | n/a (operations only, using existing code) | df free next morning ≥ today + 40 GiB | live df |
| 1 | `tests/test_job_receipt.py::test_finish_records_df_delta` | `df_delta_bytes` = end − start, null rejected for governor jobs | unit |
| 2 | `tests/test_govern.sh` case "observe tick writes budget.json and receipt" | `budget.json` zone and classes present, receipts carry `df_delta_bytes` | shell integration |
| 3 | `tests/test_sweeper_health.sh` new cases: stale tick, blind admit, trough rise, Colima stopped | each alert line printed first, exit 1 | shell integration |
| 4 | `tests/test_worktree_lease.sh` case "kind field round-trips" | lease JSON has `kind`, default `worktree` | unit (shell) |
| 5 | `tests/test_scratch_new.sh` "detach shares object store; refuses outside root" | `git worktree list` shows detached entry, `.git` is a file, rc 2 outside root | shell integration |
| 6 | `tests/test_disk_budget.py` zone table + `tests/test_admit.sh` rc table | rc 0/10/75/76 per zone and overage; blind → 0 + receipt | unit + shell |
| 7 | `tests/test_worktree_new.sh` "wtn_admit delegates to diskm admit" | rc 75 preserved, warn passthrough | shell |
| 8 | `tests/test_policy.sh` approve/revoke/no-expiry | JSON record, revoke flips, `decision_approved` true/false | shell |
| 9 | `tests/test_worktree_reap.sh` T2 cases (+ 6 negatives) | owner-null clean pushed idle≥24h → remove; each negative → kept:* | shell integration |
| 10 | `tests/test_lease_release_session.sh` | `lease-release --owner-session` marks only that session's leases | shell |
| 11 | `tests/test_birth_audit.sh` | unleased entry adopted, `bypass` counter increments | shell |
| 12 | `tests/test_disk_admission_hook.sh` | deny JSON on rc 75 for `git worktree add`/`git clone` into governed root; allow otherwise | shell |
| 13 | `tests/test_worktree_new.sh` "reuse-first recycles eligible" | lease transferred, no new dir created | shell integration |

## Dependencies on in-flight work (do not duplicate)

| Item | Status | Relationship |
|---|---|---|
| PR #148: lease, `wtn_admit`, `worktree_reap.sh` | merged, deployed v0.2.196+ | Base for Tasks 4, 7, 9, 10, 13. The lease design spec (`2026-10-10-worktree-lease-teardown-design.md`) is on branch `docs/worktree-lease-design` and is not on main. Read it from that branch |
| PR #149: pressure-sweep tmp within budget | merged | Task 2 calls the pressure-sweep steps as-is |
| PR #150: Colima stale-lock restart guard | open | Stage 0 merges it. The Task 3 Colima-stopped alert depends on it, and D8 self-heal reuses it |
| PR #151: `diskm cleanup-codex-documents` | open | Stage 0 merges it. Task 2 registers it as the `codex_documents` actuator |
| "PR #152" | does not exist | none |
| Bead `7u9t` (owner-exit exception) | open, needs user | D1. It gates Task 0 removal and Task 9 remove mode |
| Beads `oyt4`, `67xj`, `i2o`, `d45` | open | Closed by Tasks 9/10, PR #150, Task 2 (tmp budget actuator) and Task 11 respectively |

---

### Task 0: Stage 0. Same-day floor drop with existing machinery (no code)

**Files:** none. This task runs existing `diskm` commands only.

**Preconditions:** D1 is recorded. Until Task 8 exists, record it as a bead `7u9t` comment quoting the user's literal phrase, and write the marker `~/.disk_magician_state/worktree_reap.remove_approved`. Without D1, run steps 1, 3 and 4 only.

**Step 1: Baseline.** Run `df -k /System/Volumes/Data` and `./disk_magician.sh check-launchd-fleet`. Record `available_kb` and the fleet status.
**Step 2 (D1 only): Reap.** Run `diskm worktree-reap --mode remove --deadline-seconds 1500`. The reaper already handles dead and released owners (`scripts/worktree_reap.sh:194` onward). Record the receipt `freed_bytes` and the df delta.
**Step 3: Colima and Codex Documents.** Merge #150 after `/green` and `/advice`. Run `colima stop && colima start`, then `colima ssh -- sudo fstrim -av`. Merge #151 and run `diskm cleanup-codex-documents --clean`.
**Step 4: Verify.** Re-run `df -k`. Report each step's df delta. Do not report du.

Expected: about 40–70 GiB off `~/.worktrees` plus the Colima trim. The success test is df free the next morning.

---

### Task 1: Receipts carry df delta (C10, part 1)

**Files:**
- Modify: `scripts/job_receipt.py` (`finish` near line 431, `validate_receipt_dict`)
- Test: `tests/test_job_receipt.py`

**Step 1: Write the failing test**

```python
def test_finish_records_df_delta(tmp_path, monkeypatch):
    monkeypatch.setenv("DISK_MAGICIAN_STATE_DIR", str(tmp_path))
    store = ReceiptStore("govern_tmp_containers")
    rid = store.begin(precondition={"start_free_bytes": 10_000})
    store.finish(rid, outcome="success", postcondition={"end_free_bytes": 15_000})
    r = store.get_last_receipt()
    assert r["postcondition"]["df_delta_bytes"] == 5_000

def test_governor_receipt_null_delta_is_error(tmp_path, monkeypatch):
    monkeypatch.setenv("DISK_MAGICIAN_STATE_DIR", str(tmp_path))
    store = ReceiptStore("govern_worktrees")
    rid = store.begin(precondition={})
    store.finish(rid, outcome="success", postcondition={})
    assert store.get_last_receipt()["outcome"] == "error"
```

Reuse the existing class name and constructor in `job_receipt.py`. Adapt the test to the real signature and do not rename it.

**Step 2:** Run `python3 -m pytest tests/test_job_receipt.py -k df_delta -v`. Expected: FAIL (KeyError `df_delta_bytes`).
**Step 3:** In `finish`, when the precondition has `start_free_bytes` and the postcondition has `end_free_bytes`, set `df_delta_bytes = end - start`. For job names starting with `govern_`, a missing delta forces `outcome="error"` with `reason="null_df_delta"`. Older jobs are unchanged.
**Step 4:** Run the whole `tests/test_job_receipt.py`. Expected: PASS.
**Step 5:** Commit `feat: receipts record df_delta_bytes; governor receipts require it`.

---

### Task 2: `diskm govern` in observe mode, plus `budget.json` (C1 measurement, C10)

**Files:**
- Create: `scripts/govern.sh`, `scripts/disk_budget.py`, `scripts/lib/disk_budget.sh`, `launchd/com.jleechanorg.disk-magician-govern.plist.template`
- Modify: `src/disk_magician/config.json.template` (add a `budgets` block), `src/disk_magician/disk_magician.sh` (add `govern` and `budget` cases next to `worktree-reap` at line 402), `scripts/install_launchd_sweepers.sh`, `scripts/job_inventory.py`
- Test: `tests/test_govern.sh`, `tests/test_disk_budget.py`

**Interfaces:**
- `disk_budget.py measure --out <budget.json>` uses df plus per-class du. The du for each class is bounded by `timeout 60`. On timeout the class keeps its prior value with `stale_s`.
- `disk_budget.py zone <free_gb>` prints one of `GREEN|ORANGE|RED|BLACK`.
- `scripts/lib/disk_budget.sh` provides `budget_get <class> used_gb|budget_gb|stale_s` and `budget_zone`.
- `govern.sh [--mode observe|act] [--deadline-seconds 540]`. Per actuator it runs `timeout 300 <actuator>`, takes its own `mkdir` lock, and calls `job_receipt.py begin/finish` with job `govern_<class>`, `start_free_bytes` and `end_free_bytes`.

Actuator table, fixed and ordered by overage:

| Class | Governed root(s) | Actuator |
|---|---|---|
| worktrees | `~/.worktrees/*/*` | `worktree_reap.sh` (mode from the standing decision) |
| tmp_containers | `/private/tmp/<repo>/*` | `cleanup_tmp.sh --clean` plus `scratch_budget_evict_root` |
| tmpdir_scratch | `$TMPDIR` | `tmp_scratch_sweep.sh` |
| codex_documents | `~/Documents/Codex` | `diskm cleanup-codex-documents --clean` (#151) |
| claude_codex_state | `~/.claude/state`, `~/.codex` (excluding never-delete) | `cleanup_claude_state.sh`, `cleanup_codex_db.sh` |
| colima | `~/.colima/_lima` | `cleanup_colima.sh` (fstrim) |

**Step 1:** Write `tests/test_govern.sh`. It sets `DISK_MAGICIAN_STATE_DIR=$(mktemp -d)`, fakes df via `DISK_MAGICIAN_DF_BIN`, and stubs actuators via `DISK_MAGICIAN_GOVERN_ACTUATOR_DIR`. It asserts:
- `budget.json` has `zone` and `classes.worktrees.used_gb`.
- In observe mode, no actuator is invoked.
- In act mode, the overage order is respected.
- An actuator hung for longer than its deadline is recorded as `timeout` and does not stop the next actuator.

**Step 2:** Run `bash tests/test_govern.sh`. Expected: FAIL (`govern.sh` missing).
**Step 3:** Implement the minimum: the three files, the dispatch cases, and the plist (StartInterval 600, `diskm govern --mode observe`). Plists for main-sweeper and pressure-sweep stay installed until Task 9 switches govern to act mode. Then remove those two from `install_launchd_sweepers.sh` in that same PR, so that one job replaces two.
**Step 4:** Run `bash tests/test_govern.sh && python3 -m pytest tests/test_disk_budget.py -v && bash scripts/sync_package_tree.sh --check`. Expected: PASS.
**Step 5:** Commit `feat: diskm govern observe tick and budget.json`, bump the version, and deploy.

---

### Task 3: Liveness and trough alerts (C12)

**Files:**
- Modify: `scripts/sweeper_health_check.sh`, and `scripts/disk_status.py` (alert lines printed first)
- Test: `tests/test_sweeper_health.sh`

**Step 1:** Add the failing cases below, using fixture receipts and observer lines in a temp state dir. Each must print `ALERT:<code>` before any accounting and exit 1.

| Code | Fixture |
|---|---|
| `govern_stale` | last `govern_*` receipt older than 30 min |
| `admission_blind` | `admission_blind` receipt in the last 24 h |
| `actuator_dead` | 3 consecutive receipts for a class with `df_delta_bytes` ≤ 0 while the class is over budget |
| `colima_stopped` | `colima status` stub says stopped for more than 1 h |
| `main_sweeper_error` | 2 consecutive `main_sweeper` error receipts |
| `trough_rise` | observer 7-day daily-min trough is more than 15 GiB above the 30-day trough |
| `parked_large` | `budget.json` parked set is over 20 GiB |

**Step 2:** Run `bash tests/test_sweeper_health.sh`. Expected: FAIL on the new cases.
**Step 3:** Implement. Compute the trough from `disk_observer.jsonl{,.1,.2}` `host_disk.used_kb` daily minimum, using the same parse as `history_diff.py`'s observer fallback.
**Step 4:** Run the test again. Expected: PASS. The existing `test_sweeper_health_dispatch.sh` must also pass.
**Step 5:** Commit `feat: governor liveness and trough-rise alerts`.

---

### Task 4: Lease kinds (C3, part 1)

**Files:**
- Modify: `scripts/lib/worktree_lease.sh` (`lease_write` at line 170, `_lease_emit_json`)
- Test: `tests/test_worktree_lease.sh`

**Step 1:** Add a test that `lease_write <path> --kind scratch` produces JSON with `"kind":"scratch"`, and that a lease without `--kind` reads back as `worktree`. Old leases with no field must also read as `worktree`.
**Step 2:** Run it. Expected: FAIL.
**Step 3:** Add an optional `--kind` argument, validated against `worktree|clone|scratch|evidence`, with any other value giving rc 2. Add `--published` for evidence leases.
**Step 4:** Run `bash tests/test_worktree_lease.sh`. Expected: PASS.
**Step 5:** Commit `feat: lease kind field`.

---

### Task 5: `diskm scratch-new --detach` (C3, part 2)

**Files:**
- Create: `scripts/scratch_new.sh`
- Modify: `src/disk_magician/disk_magician.sh` (`scratch-new` case), `scripts/evidence_push.sh` (call `lease_write --published` on success)
- Test: `tests/test_scratch_new.sh`

**Interface:** `diskm scratch-new <repo-path> <purpose> [--kind scratch|evidence] [--detach <sha>]`
- Prints the created path on stdout.
- Calls `diskm admit --class worktrees --est-gb 1` first and propagates rc 75/76.
- With `--detach`, runs `git -C <repo> worktree add --detach ~/.worktrees/<repo>/scratch-<purpose>-<UTC ts> <sha>`.
- Writes a lease with the given kind.
- Returns rc 2 if the resolved path is outside `~/.worktrees/<repo>/` or `<purpose>` fails `^[a-z0-9-]{1,40}$`.

**Step 1:** Write the test against a temp repo with `HOME` overridden. Assert three things: the path exists and `.git` is a file (shared objects), the lease kind is `scratch`, and `../x` gives rc 2.
**Step 2:** Run it. Expected: FAIL.
**Step 3:** Implement the minimal script. Reuse `wtn_main_repo` and `wtn_repo_name` from `scripts/worktree_new.sh`.
**Step 4:** Run it. Expected: PASS.
**Step 5:** Commit `feat: diskm scratch-new with detached shared-object worktrees`.

---

### Task 6: `diskm admit` and `diskm budget status` (C1 enforcement, C2)

**Files:**
- Create: `scripts/admit.sh`
- Modify: `scripts/disk_budget.py` (add `admit` and `status`), `src/disk_magician/disk_magician.sh`
- Test: `tests/test_disk_budget.py`, `tests/test_admit.sh`

**Policy table.** It is fixed. The enforcement stage comes from `budgets.enforcement` (`observe|warn|refuse_red|refuse_orange`, default `observe`).

| Zone | Class over budget | observe | warn | refuse_red | refuse_orange |
|---|---|---|---|---|---|
| GREEN | any | 0 | 0 | 0 | 0 |
| ORANGE | no | 0 | 10 | 10 | 10 |
| ORANGE | yes | 0 | 10 | 10 | 75 |
| RED | any | 0 | 10 | 75 | 75 |
| BLACK | any | 0 | 10 | 76 (`retry_after_s=600`) | 76 |
| budget.json missing or stale (>30 min) | n/a | 0 + `admission_blind` receipt | same | same | same |

**Step 1:** Write a parametrized pytest over the full table, plus a shell test that `diskm admit --class worktrees --est-gb 1` runs in under 200 ms with no `du` in the process tree (use a `DISK_MAGICIAN_DU_BIN` stub that fails if invoked).
**Step 2:** Run both. Expected: FAIL.
**Step 3:** Implement. `budget status` prints the zone, per-class used/budget/stale age, the birth rate, the parked total and the alert lines. `--weekly-check` evaluates the spec's section 9 metrics and exits 0 or 1.
**Step 4:** Run both. Expected: PASS.
**Step 5:** Commit `feat: diskm admit and budget status`.

---

### Task 7: `wtn_admit` delegates to `diskm admit`

**Files:**
- Modify: `scripts/worktree_new.sh:185-201`
- Test: `tests/test_worktree_new.sh`

**Step 1:** Add a test that sets a stub `budget.json` in RED with enforcement `refuse_red`. `diskm worktree-new` must exit 75 with the existing "reuse an existing worktree" message. In GREEN it must create the worktree.
**Step 2:** Run it. Expected: FAIL in RED. The old gate uses `WORKTREE_ADMIT_MIN_GB=10` and admits at 20 GiB free.
**Step 3:** Change `wtn_admit` to call `bash "$SCRIPT_DIR/admit.sh" --class worktrees --est-gb 1`. Keep the old env thresholds as the fallback only when `admit.sh` is missing.
**Step 4:** Run `bash tests/test_worktree_new.sh`. Expected: PASS.
**Step 5:** Commit `refactor: worktree-new admission via diskm admit`.

---

### Task 8: Standing-decision record (C11)

**Files:**
- Create: `scripts/policy.sh`
- Modify: `scripts/safety_lib.sh` (add `decision_approved <id>`), `src/disk_magician/disk_magician.sh` (`policy` case), `scripts/worktree_reap.sh:98` (accept `decision_approved worktree_reap_remove` as an alternative to the marker file), `scripts/main_sweeper.sh:376` and `scripts/worktree_hygiene.sh:18` (read `decision_approved worktree_cleanup` in addition to `WORKTREE_APPROVED`)
- Test: `tests/test_policy.sh`

**Interface:**
- `diskm policy approve <id> --phrase '<text>'` writes `{id, phrase, approved_at, approved_by:"user", revoked_at:null}` atomically to `~/.config/disk-magician/standing_decisions.json`. Override the path with `DISK_MAGICIAN_POLICY_FILE`.
- `diskm policy revoke <id>` sets `revoked_at`.
- `diskm policy list` lists the decisions.
- Valid ids are fixed: `worktree_reap_remove` (D1), `worktree_cleanup` (D1), `admission_enforcement` (D2), `ci_autopause` (D4), `colima_selfheal` (D8).

**Step 1:** Write tests for: an unknown id gives rc 2; an empty phrase gives rc 2; approve then `decision_approved` returns 0; revoke then it returns 1; the record has **no** expiry field; the reaper in remove mode with the decision but no marker file proceeds past the line 98 gate.
**Step 2:** Run it. Expected: FAIL.
**Step 3:** Implement.
**Step 4:** Run `bash tests/test_policy.sh && bash tests/test_worktree_reap.sh`. Expected: PASS.
**Step 5:** Commit `feat: diskm policy standing decisions (revocable, no expiry)`.

---

### Task 9: Reclaim tier T2 and the parked set; govern switches to act mode (C9)

**Files:**
- Modify: `scripts/worktree_reap.sh`. Add a `none)` branch: when `decision_approved worktree_reap_remove` holds and `worktree_is_recently_active_minutes "$real" 1440` reports not-recent, fall through to `verdict_for` with quiet 1440. Write kept items to `$STATE/parked.jsonl` with their sizes.
- Modify: `scripts/govern.sh` (switch to `--mode act` when `decision_approved worktree_reap_remove` holds), `scripts/install_launchd_sweepers.sh` (retire the main-sweeper and pressure-sweep plists)
- Test: `tests/test_worktree_reap.sh`

**Step 1:** Add a positive case: owner-null, clean, HEAD on origin, content idle 25 h. The result must be `remove`, with a byte-verified receipt.

Add these negative cases. Each must give `kept:*` and appear in parked:
- dirty
- untracked file
- ahead of origin
- `.env` ignored file
- a live process cwd inside the worktree (use the `wrh_live_cwd_reason` stub)
- locked
- under `ao/data/worktrees`
- idle 23 h
- recency unmeasurable

**Step 2:** Run it. Expected: the positive case fails, because owner-null is skipped today.
**Step 3:** Implement the branch. It must reuse `verdict_for` unchanged.
**Step 4:** Run the reap tests, then `bash tests/test_worktree_reap_dispatch.sh`. Expected: PASS.
**Step 5:** Commit `feat: owner-null T2 reclaim and parked set`, deploy, and check the next morning's df and the `govern_worktrees` receipts.

---

### Task 10: Session-exit lease release (C8)

**Files:**
- Modify: `scripts/lib/worktree_lease.sh` (add `lease_release_owner_session <session_id>`, which iterates `lease_dir` and calls `lease_release` where `owner.session == id`), `src/disk_magician/disk_magician.sh` (`lease-release` case with `--owner-session`)
- Create: `hooks/session-end-lease-release.sh` (template; reads `session_id` from the hook JSON on stdin and calls `diskm lease-release --owner-session`)
- Test: `tests/test_lease_release_session.sh`

**Step 1:** Write a test with two leases owned by sessions A and B. Releasing A marks only A as `released`. An unknown session gives rc 0 with no changes.
**Step 2:** Run it. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run it. Expected: PASS.
**Step 5:** Commit `feat: session-exit lease release`.

**Outside this repo (D6).** These are separate PRs in their own repos:
- Install the hook in `~/.claude/settings.json` under SessionEnd and SubagentStop.
- Add one paragraph to each of the skills `superpowers-using-git-worktrees`, `draft-first-pr`, `evidence-standards` and `advice`: create through `diskm worktree-new` or `diskm scratch-new`, and before exit run `git push -u origin HEAD` (never a force-push) and `diskm evidence-push`.

---

### Task 11: Birth audit and adoption (C7)

**Files:**
- Modify: `scripts/govern.sh` (call the audit at the start of each tick), `scripts/worktree_reap.sh` (`adopt` at line 132, generalized to non-worktree kinds via `--kind`)
- Create: `scripts/birth_audit.sh`
- Test: `tests/test_birth_audit.sh`

**Step 1:** Write a test with fixture dirs: `/private/tmp/<repo>/advice-src-x` (via `DISK_MAGICIAN_TMP_ROOT`) and `~/Documents/Codex/2026-10-11/task-1`, neither with a lease. After an audit, each has a lease of kind `scratch`, `budget.json.bypass.tmp_containers == 1`, and a second audit does not double-count.
**Step 2:** Run it. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run it. Expected: PASS.
**Step 5:** Commit `feat: birth audit adopts unleased governed artifacts`.

---

### Task 12: Admission hook (C6) and producer conversions (C4)

**Files:**
- Create: `hooks/disk-admission.sh` (PreToolUse Bash template)
- Test: `tests/test_disk_admission_hook.sh`

**Step 1:** Write tests that feed hook JSON on stdin with a stub `diskm admit` rc:
- `git worktree add /Users/x/.worktrees/r/n` with rc 75 must give a deny JSON with a reuse message.
- The same command with rc 0 must be allowed.
- `git clone url /private/tmp/r/advice-src-1` with rc 75 must be denied.
- `ls` must be allowed, and admit must not be called.
- A blind admit (rc 0 plus a receipt) must be allowed.

**Step 2:** Run it. Expected: FAIL. **Step 3:** Implement the literal regex `^(git (worktree add|clone)|cp -R) ` plus a target under a governed root. **Step 4:** Run it. Expected: PASS.
**Step 5:** Commit `feat: disk admission PreToolUse hook template`.

**Outside this repo (D6, D2).**
- Install the hook in observe mode.
- Change `run_primary_pair.py` (the advice skill) and the gate-prep and split-gates producers from `git clone` to `diskm scratch-new --detach <sha>`. Their existing `shutil.rmtree` becomes `diskm worktree-release <path>` (an existing subcommand). The governor's reaper then removes released, clean, pushed scratch after the 30-minute `REAP_RELEASED_QUIET_MINUTES`. Agents gain no removal authority, and the `protect-worktrees.sh` regex is unchanged.
- Measure: per-instance du before and after on one /advice run. That verifies or revises the 7× saving.

---

### Task 13: Reuse-first worktree-new (C5) and CI admission (C13)

**Files:**
- Modify: `scripts/worktree_new.sh` (`wtn_main`). Before `wtn_create`, look for a recyclable worktree via `lease_owner_state` = dead or released, plus `worktree_has_unsaved_work` false, HEAD on origin, `worktree_is_recently_active_minutes 120` false, and no `wrh_live_cwd_reason`. Then run `git switch --detach` and `git switch -c <branch> <base>`, and rewrite the lease to the new owner.
- Modify: `scripts/post_job_docker_prune.sh` neighbour, or add `scripts/ci_admit.sh`: the ezgha pre-job hook calls `diskm admit --class ci --est-gb 20`. In RED/BLACK the governor prints the pause command, `launchctl bootout gui/$UID/<ezgha label>`. Auto-pause only with `decision_approved ci_autopause`.
- Test: `tests/test_worktree_new.sh` (reuse cases plus negatives for dirty, ahead and live cwd)

Follow steps 1–5 in the standard RED/GREEN form. Commit `feat: reuse-first worktree-new` and `feat: CI admission check`.

---

## Sequencing (fastest measurable floor drop first)

| Order | Tasks | PR | Gated on | Measurable effect |
|---|---|---|---|---|
| 0 | Task 0 | none (ops), plus merges of #150 and #151 | D1 for the reap | df next morning |
| 1 | Tasks 1, 2, 3 | PR-A (receipts plus govern observe), PR-B (alerts) | none | every later step becomes measurable |
| 2 | Tasks 4, 5, then 12 conversions | PR-C (lease kind plus scratch-new), external PRs | D6 | /private/tmp class stock |
| 3 | Tasks 6, 7 | PR-D (admit) | D2 and D3 for enforcement stages | births/day in RED |
| 4 | Tasks 8, 9, 10, 11, 12 hook | PR-E (policy), PR-F (T2 plus act mode), PR-G (release plus audit), PR-H (hook) | D1, D5, D6 | worktrees class ≤ 40 GiB |
| 5 | Task 13 | PR-I | D4 for auto-pause | births/day, CI burst depth |

Enforcement rollout for `budgets.enforcement`:
1. `observe` for 3 days.
2. `warn`.
3. `refuse_red`, once the 7-day minimum free is at least 30 GiB.
4. `refuse_orange`, after a further 7 days.

Each stage change is a one-line config edit recorded with `diskm policy approve admission_enforcement`.

## Verification after each deploy

1. Run `diskm status --json`. The first lines must contain no `ALERT:` lines. If any appear, report them first.
2. `~/.disk_magician_state/receipts/govern_*.json` must have a last entry less than 15 minutes old with non-null `df_delta_bytes`.
3. Run `diskm budget status --weekly-check`. It exits 0 only when every metric in spec section 9 passes. Close the workstream bead after two consecutive weekly passes.
