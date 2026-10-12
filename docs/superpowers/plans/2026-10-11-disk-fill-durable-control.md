# Disk-Fill Durable Control Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the disk-use loop with a `diskm` budget governor: admission at creation on projected free space, a stage-independent BLACK/floor emergency, owner-lifecycle reclaim behind one final provenance check, and df-verified receipts. Success is spec §9: 7-day minimum free ≥ 30 GiB, zero samples under 15 GiB free, and a daily used trough ≤ 790 GiB, on two consecutive non-overlapping weekly checks.

**Architecture:**
- `diskm admit` takes `state.lock`, reads `df`, decides on `zone(df_free − est − margin)` by the policy table, appends one line to `admission/events.jsonl`, and returns a decision rc. It never runs a command and keeps no reservations (spec §7.1; ledger deferred to spec §12). Callers (`worktree-new`, `scratch-new`, the PreToolUse hook, `/advice`, evidence producers, the CI job-started hook) run their command only after admit returns.
- A 10-minute `diskm govern` tick (`govern.lock`) writes the df zone first, measures one du class, runs the birth audit, and runs act-mode actuators through a time-sliced, rotating, progress-tracking scheduler. A separate 03:00 job measures every class. Both merge into `budget.json` under `state.lock`. Pressure-sweep is kickstarted in BLACK/FLOOR only once C14 is active.
- Every removal calls `artifact_removal_verdict` (positive provenance) immediately before the destructive call; every decision-gated site also calls `removal_activation_ok`.
- `main_sweeper` and `pressure-sweep` stay installed and unchanged.

**Tech Stack:** Bash (scripts/, scripts/lib/), Python 3 stdlib (`fcntl`, `subprocess` timeouts, `ctypes` for `renamex_np`), launchd templates, shell tests under `tests/`, unittest/pytest.

**Spec:** `docs/superpowers/specs/2026-10-11-disk-fill-durable-control-design.md` (revision 6)
**Base:** origin/main `7837d36`, version 0.2.198. Usable capacity about 895 GiB (df used + avail).

---

## Global Constraints

- **Entry point.** Every operation is a `diskm` subcommand in `src/disk_magician/disk_magician.sh`; mirror with `scripts/sync_package_tree.sh` and check with `--check` in review.
- **Removal gate.** Every removal calls `artifact_removal_verdict` (Task 11) immediately before the destructive call, on every path in the spec §7.2 delete-path table. Decision-gated sites also call `removal_activation_ok <id>` (Task 2), which fails closed until Task 11 is deployed. No ad-hoc `rm`. Never touch never-delete paths.
- **No destructive triggering before C14.** No task runs `--clean`, remove mode, or a governor kickstart of pressure-sweep on a path before Task 11 has wired C14 into it. The kickstart checks `artifact_removal_verdict --self-test` at run time.
- **Recency** only through `scripts/lib/worktree_recency.sh`, fail closed, with a test that the unmeasurable case is protected.
- **Owner liveness** only through `lease_owner_state` (pid + `start_epoch`, from `LC_ALL=C ps -o lstart=`). TTL expiry and quiet time never make an owner dead. `unknown`/`unreadable` = alive = keep.
- **One state lock.** `state.lock` (`fcntl.flock`) is taken by every writer of `budget.json` and `admission/events.jsonl` (admit, tick, daily measure, log rotation); each holder rereads inside the lock and never holds it across du, `git fetch` or an actuator.
- **Exit-code channel.** `diskm admit` rc is the decision only. A caller exits 75 only when admission refused and its command never started (after a `disk-admission: refused` stderr line); otherwise it exits with its command's rc. A 76 retry happens once and only before the command starts.
- **Unknowns.** Unknown class measurement drops that class's overage term only. df failure or an unexpected admit rc = `admission_degraded:*` (rc 10 or the stale-tick decision, never 0), counted as bypass.
- **Existing jobs.** Do not uninstall or reschedule `main_sweeper` or `pressure-sweep`. The governor takes each actuator's existing lock and records `skipped_lock` when held.
- **ZFC.** Class membership comes from the fixed governed-root table; the hook matches literal syntax. No keyword scoring.
- **Portability on macOS.** No `flock(1)` or `timeout(1)`: Python `fcntl.flock` and `subprocess.Popen(start_new_session=True)` with group SIGTERM → SIGKILL.
- **Plists.** Never `plutil -extract` without `-o -`. Templates use `@HOME@` / `@REPO_ROOT@` via `scripts/install_launchd_sweepers.sh`.
- **Deploy.** Each merged PR bumps `pyproject.toml` and runs `tools/deploy_uv_tool.sh` from clean origin/main; verify `deployed.json` and the stage-appropriate receipt (see "Verification after each deploy").
- **PR size.** At most 150 production lines per PR, or the size-tiered merge gate.
- **Approvals.** No task sets `WORKTREE_APPROVED`, writes `worktree_reap.remove_approved`, or records a decision on the user's behalf. Decisions are written by `diskm policy approve --from-transcript` only after the user's literal phrase appears in a live user message.

## Assumptions

| Assumption | Default used by this plan | If wrong |
|---|---|---|
| **r6-A:** v1 needs no reservation ledger | Admission = fresh df − est − margin under `state.lock`; overshoot within one tick accepted, bounded (margin, 15 GiB hard floor, BLACK) and measured as `admit_burst_bytes` (Task 10). Rationale: round-4 non-approvals were mostly ledger defects; deleting the ledger deletes them | `burst_over_margin` after D3 raised the margin once → build spec §12 against its acceptance criteria |
| **r6-B:** only positive provenance proves disposability | C14 keeps all non-git content without a manifest-matched producer receipt/lease, a published-evidence receipt, or the #153 rebuildable allowlist; `rev-list --all --reflog --not --remotes` after a bounded fetch; conditional `update-ref -d`. Rationale: age and location prove nothing; reflogs hold work; check-then-delete races | Reclaim falls (more `kept:unproven-content`); fix by adding producer receipts, never by loosening C14 |
| **r6-C:** each remaining round-4 bug is closed by the smallest change | Kickstart gated on C14; one `state.lock`; quarantine sidecar + `RENAME_EXCL` rollback; `B_est` excluded from pass/fail; births from event log + audit; no release paths | The named test in Tasks 3, 8, 9, 10, 11, 15 fails |
| Claude Code runs the original Bash input when a PreToolUse hook allows without `updatedInput` | Hook emits `permissionDecision` only (https://code.claude.com/docs/en/hooks, PreToolUse) | Task 7 live probe shows a changed field; record it and stop before D2 |
| Estimate per producer | Defaults: worktree-new / scratch-new 1; evidence 1; `/advice` 2 × source checkout; CI 20; hook `git clone` 2, `cp -R` source du (5 s) | `estimates.json` raises each to 1.25 × p95 of audited births (Task 9); the pilot reports under-estimation per producer |
| Governor runs as the user under launchd | `getconf DARWIN_USER_TEMP_DIR` resolves `$TMPDIR` | Birth audit test asserts the unset-`TMPDIR` path |
| Hook JSON carries `session_id`; the runtime pid is resolvable | `lease_resolve_owner` (PR #148) | Release skips and reports; nothing deleted |
| ezgha runner exposes a job-started hook | `ACTIONS_RUNNER_HOOK_JOB_STARTED` | Each CI job start counts as bypass in the SLO |
| macOS exposes `renamex_np(RENAME_EXCL)` | Python `ctypes` call from `scripts/lib/quarantine.sh` helper | Rollback refuses whenever the original path exists (`lstat` check) and alerts; never overwrites |

## Implementation Preconditions

| Gate | Needed before | Recorded by |
|---|---|---|
| D2 (`admission_enforcement`) + live emergency probe | Any non-zero admit rc in production; pilot start | `diskm policy approve` (Task 2), `diskm admit --probe` |
| D6 | Task 7 external edits, Task 12 hook install | user phrase |
| D1 (`worktree_reap_remove`) + merged `CLAUDE.md` amendment + Tasks 11, 12 deployed | First T1 removal (Task 13); enforced by `removal_activation_ok` | user phrase, Task 13 PR |
| D1b (`worktree_cleanup`) + Task 11 deployed | T3 unattended (Task 14); enforced by `removal_activation_ok` | user phrase |
| D3 + §7.5 births SLO + `floor_margin_ok` | Stage beyond `warn` | user phrase after pilot |
| D4 (`ci_autopause`) | CI auto-pause | user phrase |
| #150 deployed; #151 and #152 merged **after** Task 11 with C14 in their delete paths | Task 14 enabling colima / codex_documents / tmp actuators; any `--clean` of codex documents | merge gate |

## Review Focus

1. **No existing cleanup stops.** main_sweeper and pressure-sweep plists are unchanged.
2. **Admission is honest about concurrency.** Decisions are ordered and logged under `state.lock`; the overshoot is measured, not claimed away (Tasks 3, 10).
3. **Every delete path in spec §7.2 calls `artifact_removal_verdict`, which keeps unproven content and reflog-only commits** (Task 11), and **no decision activates removal without `removal_activation_ok`** (Task 2); the governor triggers nothing destructive before Task 11 (Task 8).
4. **Owner death is pid + start epoch only** (Task 12); release deletes nothing.
5. **Every caller keeps admission rc and command rc apart** and handles 0, 10, 75, 76 and an unexpected rc; the hook's output is valid host JSON without `updatedInput` (Task 7).
6. **Prevention, CI admission, D2 and the emergency probe land before the pilot**; pilot validity is machine-checked (Task 10).
7. **Reclaim, not just dispatch, makes progress** inside the tick deadline, with process-group teardown (Task 14).
8. **Disk-full behaviour.** A tick at about 5 GiB free writes `budget.json` and receipts; ENOSPC keeps the previous file; an event-log ENOSPC never changes a decision.

## TDD Plan Check

| Task | RED test (fails before change) | GREEN condition | Layer |
|---|---|---|---|
| 0 | n/a (observe and dry-run only; no `--clean`, no remove mode) | baseline df, fleet health, dry-run candidate lists; Colima trim df delta | live df |
| 1 | `tests/test_job_receipt.py::TestDfDelta` | `df_delta_bytes = after − before`; `govern_*` missing delta → `error`/`null_df_delta` | unit |
| 2 | `tests/test_policy.sh` incl. "phrase absent", "phrase omits decision id"; `tests/test_removal_activation.sh` | approve only with a phrase naming the decision in a `type:user` message; C14 lib absent / no amendment → nominate + `activation_blocked` | shell |
| 3 | `tests/test_disk_budget.py` policy table + margin; `tests/test_admit.sh` "du stub hangs, RED still refuses", "20 concurrent", "event-log ENOSPC" | rc per zone/stage/D2; 20 ordered, complete event lines; ENOSPC → same rc + `admission_degraded:log`; df failure never 0 | unit + shell |
| 4 | `tests/test_worktree_new.sh` admit contract incl. exit-channel cases | refusal → 75 with nothing created; git failing with 75/76/10 → that rc, no retry, no refusal line | shell |
| 5 | `tests/test_worktree_lease.sh` "kind, producer, source, manifest round-trip" | fields present; default kind `worktree` | shell |
| 6 | `tests/test_scratch_new.sh` contract + "detach shares objects; refuses outside root"; evidence kind | admit called first; detached `.git` file; evidence dir under `/private/tmp/<repo>/evidence` | shell integration |
| 7 | `tests/test_disk_admission_hook.sh` (all forms × all rc, schema, no `updatedInput`); `test_run_primary_pair.py`; `tests/test_ci_admit.sh` | 0/10 → `allow` without `updatedInput`; 75/76 → `deny`, exit 0; clone failure is not treated as admission | shell + unit |
| 8 | `tests/test_govern.sh` zone-first, du timeout, round-robin, daily-measure interleaving, overlapping tick, kickstart gate, 5 GiB, ENOSPC | zone fresh; no lost fields under interleaving; kickstart only with C14 self-test passing | shell integration |
| 9 | `tests/test_birth_audit.sh` incl. `$TMPDIR` unset, foreign, event-log births, 20 GiB between ticks, unknown entry over budget | admitted births from the log even if gone; bypass from audit; unknown charged and labelled estimate; nothing deleted | shell |
| 10 | `tests/test_sweeper_health.sh` alerts, `--weekly-check`, `--pilot-check`, exposure and burst fixtures | each `ALERT:<code>` first, exit 1; no reservation cancellation; no reclaim receipt → `margin_unknown` | shell integration |
| 11 | `tests/test_artifact_verdict.sh` matrix incl. reflog-only commit, unique `notes.txt`, custom-named secret, unpublished output, quarantine provenance and conflict; `tests/test_removal_sites.sh` | each unproven fixture `kept:*`; manifest-proven fixture survives quarantine recheck and is removed; recreated path never overwritten | shell integration |
| 12 | `tests/test_worktree_reap.sh` owner-proof cases + `tests/test_lease_release_session.sh` | expired-TTL live/suspended owner kept; pid reuse = dead; only own-runtime leases released | shell |
| 13 | n/a (policy text + ops) | `CLAUDE.md` merged before first remove-mode receipt | live df |
| 14 | `tests/test_govern.sh` scheduler, deadline incl. overhead, orphan child, resumable reclaim, escalation | tick ≤ 540 s with ten slow actuators; orphan killed; `reclaim_starved` at 3, next tier at 6 | shell integration |
| 15 | `tests/test_worktree_new.sh` reuse-first incl. branch moved at the `update-ref` boundary | merged old branch deleted conditionally; moved branch kept and checkout restored; one claimant | shell integration |

## Dependencies on in-flight work (do not duplicate)

| Item | Status (verified 2026-10-12 via `gh pr view`) | Relationship |
|---|---|---|
| PR #148: leases, reaper, `wtn_admit` | merged 10-11T13:01Z, deployed | Base for Tasks 4, 5, 9, 11, 12, 15. Owner-exit thresholds are in bead `7u9t` |
| PR #149: pressure-sweep tmp within budget | merged | Unchanged; kickstarted in BLACK once C14 is active |
| PR #150: Colima stopped-VM guard + stale lima lock | open | No artifact removal; may deploy in Task 0. Before Task 14 enables colima; Task 10 `colima_stopped` and D8 reuse it |
| PR #151: `diskm cleanup-codex-documents` | open | New delete path: rebased to call C14, merges after Task 11, before Task 14 enables `codex_documents`. Only `--dry-run` before then |
| PR #152: `cleanup_tmp.sh` descends into active tmp containers | open | Widens an unattended delete path: rebased onto Task 11 so its descent calls C14 in the same PR; merges after Task 11 |
| PR #153: rebuildable-ignored allowlist | merged 2026-10-12T00:35Z | C14 provenance (c) and Task 15 use `scripts/lib/worktree_ignored.sh` |
| Beads `7u9t`, `oyt4`, `67xj`, `i2o`, `d45` | open | D1; Tasks 12/14; PR #150; Task 14; Task 9 |

**Shared test helper.** `tests/lib/admit_contract.sh` provides `run_admit_contract <caller-cmd>`: a stub `DISK_MAGICIAN_ADMIT_BIN` returning 0, 10, 75, 76 (then 76 or 0), and 3, with `DISK_MAGICIAN_ADMIT_RETRY_CAP_S=0`, and a stub command that appends one line to a marker file. Expected per caller: 0 → command runs once; 10 → runs once plus one `disk-admission: warn` stderr line; 75 → exit 75, `disk-admission: refused` line, marker empty; 76 → one retry, then exit 75 if still 76 or run once on 0; 3 → run once plus `admission_degraded:caller`. **Exit-channel cases:** admit 0 and the command itself exits 10, 75, 76 or 3 → the caller exits with that rc, the marker has exactly one line (no retry), and no `disk-admission: refused` line is printed.

---

### Task 0: Stage 0. Observe and dry-run only (no artifact removal)

**Step 1: Baseline.** `df -k /System/Volumes/Data` and `./disk_magician.sh check-launchd-fleet`; report an unhealthy fleet first.
**Step 2: Non-removal fixes and dry runs.** Merge and deploy #150 (removes no artifact). Between CI jobs, `colima stop && colima start`, then `colima ssh -- sudo fstrim -av` (excluded from C14: no host artifact); record guest trimmed bytes and host df now and 10 min later. Run `diskm cleanup-codex-documents --dry-run` from the #151 branch and `bash scripts/cleanup_tmp.sh --large` (dry-run default) from the #152 branch; save both candidate lists to `/tmp/disk_magician/evidence/stage0/` as the baseline Task 11's fixtures are checked against.
**Step 3: Verify.** Re-run `df -k`; report the Colima df delta (immediate and lagged), not du. Confirm no `--clean` or remove-mode receipt exists from Task 0.

---

### Task 1: Receipts carry df delta (C10, part 1)

**Files:** Modify `scripts/job_receipt.py` (`JobReceiptStore.finish` at line 431). Test: `tests/test_job_receipt.py`.

**Step 1: Write the failing test** (unittest style, matching the file):

```python
class TestDfDelta(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.store = job_receipt.JobReceiptStore(state_dir=self.tmp)

    def test_finish_records_df_delta(self):
        rid = self.store.begin("govern_tmp_containers", precondition={"free_bytes_before": 10_000})
        self.store.finish("govern_tmp_containers", rid, "success",
                          postcondition={"free_bytes_after": 15_000})
        r = job_receipt.get_last_receipt("govern_tmp_containers", state_dir=self.tmp)
        self.assertEqual(r["postcondition"]["df_delta_bytes"], 5_000)

    def test_governor_receipt_null_delta_is_error(self):
        rid = self.store.begin("govern_worktrees", precondition={})
        self.store.finish("govern_worktrees", rid, "success", postcondition={})
        r = job_receipt.get_last_receipt("govern_worktrees", state_dir=self.tmp)
        self.assertEqual((r["outcome"], r["reason"]), ("error", "null_df_delta"))

    def test_existing_df_delta_is_kept(self):  # worktree_reap.sh already computes it
        rid = self.store.begin("worktree_reap")
        self.store.finish("worktree_reap", rid, "success",
                          postcondition={"df_delta_bytes": 7, "free_bytes_before": 1, "free_bytes_after": 8})
        self.assertEqual(job_receipt.get_last_receipt("worktree_reap", state_dir=self.tmp)["postcondition"]["df_delta_bytes"], 7)
```

**Step 2:** `python3 -m pytest tests/test_job_receipt.py -k DfDelta -v`. Expected: FAIL (`KeyError: 'df_delta_bytes'`, outcome `success`).
**Step 3:** In `finish`, if the postcondition lacks `df_delta_bytes` and both `free_bytes_before` and `free_bytes_after` are integers, set the difference. For `govern_*` jobs a still-missing delta forces `outcome="error"`, `reason="null_df_delta"`. Old receipts without the key still validate.
**Step 4:** Whole `tests/test_job_receipt.py`, plus `python3 -m pytest tests/test_history_diff.py` and `bash tests/test_sweeper_health.sh` (old receipt schemas parse). Expected: PASS.
**Step 5:** Commit `feat: receipts derive df_delta_bytes; governor receipts require it`.

---

### Task 2: Standing-decision record and the activation gate (C11, spec §7.3)

**Files:** Create `scripts/policy.sh`, `scripts/policy_provenance.py`, `scripts/lib/removal_activation.sh`. Modify `scripts/safety_lib.sh` (`decision_approved <id>`), `src/disk_magician/disk_magician.sh` (`policy`), and each decision-gated site so the decision path goes **only** through `removal_activation_ok <id>`: `scripts/worktree_reap.sh:98` (`worktree_reap_remove`), `scripts/main_sweeper.sh:376,389` and `scripts/worktree_hygiene.sh` (`worktree_cleanup`), `scripts/cleanup_claude_state.sh` (`claude_state_cleanup`). Marker-file and `WORKTREE_APPROVED=1` paths are unchanged. Test: `tests/test_policy.sh`, `tests/test_removal_activation.sh`.

**Interface:** `diskm policy approve <id> --phrase '<text>' --from-transcript <session.jsonl>` writes `{id, phrase, transcript, approved_at, revoked_at:null}` atomically to `~/.config/disk-magician/standing_decisions.json` (override `DISK_MAGICIAN_POLICY_FILE`); `set-amendment <id> <sha>` (Task 13); `revoke <id>`; `list`. Ids and labels: `worktree_reap_remove` D1, `worktree_cleanup` D1b, `admission_enforcement` D2, `budgets` D3, `ci_autopause` D4, `colima_selfheal` D8, `claude_state_cleanup`. `removal_activation_ok <id>` returns 0 only if the decision is approved, `scripts/lib/artifact_verdict.sh` exists beside it and `artifact_removal_verdict --self-test` prints `ok`, and (for `worktree_reap_remove`) `amendment_commit` is an ancestor of local `origin/main` and `git show <sha>:CLAUDE.md` contains `policy:worktree_reap_remove`. Otherwise it prints `activation_blocked:<missing>` and returns 1.

**Step 1:** Fixture transcripts: phrase in a `type:user` message; only in a `tool_result`; in a user message naming no decision. Tests: unknown id → rc 2; empty phrase → rc 2; tool-result-only → rc 2, file unchanged; no `D1`/id → rc 2; approve → `decision_approved` 0; revoke → 1; no expiry field. Activation (temp repo, stub `origin/main`): D1 approved, no `artifact_verdict.sh` → nominate + `activation_blocked:c14_missing`; lib present, no amendment → `activation_blocked:amendment_missing`; amendment not an ancestor → blocked; all present → remove mode. D1b approved without the lib → main_sweeper Tier 6 does not run `cleanup_worktrees.sh --clean`.
**Step 2:** `bash tests/test_policy.sh && bash tests/test_removal_activation.sh`. Expected: FAIL. **Step 3:** Implement.
**Step 4:** Step 2 plus `bash tests/test_worktree_reap.sh && bash tests/test_main_sweeper.sh`. Expected: PASS; with no decisions, behaviour is byte-identical to today.
**Step 5:** Commit `feat: diskm policy decisions; removal_activation_ok gate`.

---

### Task 3: Budget config, zones, `diskm admit` and the event log (C1, C2)

**Files:** Create `scripts/admit.sh`, `scripts/disk_budget.py`, `scripts/lib/disk_budget.sh`. Modify `src/disk_magician/config.json.template` (`budgets` block with the spec §7.2 class table, `concurrency_margin_gb: 10`, `enforcement: observe`), `src/disk_magician/disk_magician.sh` (`admit`, `budget`). Test: `tests/test_disk_budget.py`, `tests/test_admit.sh`.

**Policy table** (stage from `budgets.enforcement`; admission zone = `zone(df_free − est − margin)`; emergency rows apply only when `decision_approved admission_enforcement`, otherwise they return 10):

| Admission zone | Class over budget (fresh ≤ 3 h) | observe | warn | refuse_red | refuse_orange |
|---|---|---|---|---|---|
| GREEN ≥ 100 | any | 0 | 0 | 0 | 0 |
| ORANGE 60–100 | no, stale, or df_delta_only | 0 | 10 | 10 | 10 |
| ORANGE | yes | 0 | 10 | 10 | 75 |
| RED 30–60 | any | 0 | 10 | 75 | 75 |
| BLACK 15–30 | any | 76 | 76 | 76 | 76 |
| FLOOR < 15, or `df_free − est` < 15 (hard floor) | any | 75 | 75 | 75 | 75 |
| df fails | n/a | last tick's free if ≤ 15 min old, else 10 + `admission_degraded:blind` (75/76 if last zone ≤ 60 min was FLOOR/BLACK) | same | same | same |

**Interface:** `diskm admit --class C (--est-gb N | --producer K) [--dest P] [--source S] [--dry-run|--probe]`. Under `state.lock`: `df` with a 5 s timeout, decide, append `{at, class, producer, source, est_bytes, dest, decision, df_free_bytes}` to `admission/events.jsonl` (not for `--dry-run`), release. An append failure keeps the decision and writes `admission_degraded:log` to stderr. `--producer K` reads `est` from `admission/estimates.json` (written by Task 9). `diskm budget set-stage <s>` records the prior stage for rollback; `budget status` prints zone, per-class used/budget/stale age, birth counts, parked total and alert lines.

**Step 1:** Parametrized pytest over every row × stage × D2 on/off; margin: 105 free, `--est-gb 70`, margin 10 → zone(25) BLACK → 76, and margin 0 → zone(35) RED; hard floor: `--est-gb 95` at 105 free → 75; oversized `--est-gb 200` → 75. Shell: (a) admit under 200 ms with a `DISK_MAGICIAN_DU_BIN` stub that fails if invoked; (b) `budget.json` 2 h old, every class stale, fake df RED, `refuse_red` → 75, no `admission_degraded`; (c) fake df exits 1, `budget.json` 5 min old at RED → RED with `admission_degraded:stale_df`; 30 min old GREEN → 10 + `admission_degraded:blind`; 30 min old BLACK → 76; (d) `set-stage refuse_red` then `set-stage warn` → RED returns 10 again, BLACK still 76; (e) **20 concurrent** `admit --est-gb 10` at a fixed fake 105 free in `observe` → all 20 rc 0 (the documented v1 overshoot), `events.jsonl` has exactly 20 complete, parseable lines in lock order; (f) `events.jsonl` on a full 2 MiB `hdiutil` image (skip with reason off macOS) → same rc as with space, `admission_degraded:log`.
**Step 2:** Run. Expected: FAIL (`admit.sh` missing).
**Step 3:** Implement. **Step 4:** `python3 -m pytest tests/test_disk_budget.py -v && bash tests/test_admit.sh && bash scripts/sync_package_tree.sh --check`. Expected: PASS.
**Step 5:** Commit `feat: diskm admit on projected free with margin, emergency rows and event log`.

---

### Task 4: `wtn_admit` delegates, with the caller contract

**Files:** Modify `scripts/worktree_new.sh:179-201`. Create `tests/lib/admit_contract.sh`. Test: `tests/test_worktree_new.sh`.

**Step 1:** `run_admit_contract "diskm worktree-new <repo> <branch>"` (five outcomes plus the exit-channel cases with the stub command in place of `git worktree add`); fake df RED, `refuse_red`, real admit → exit 75 with the existing reuse message and no directory.
**Step 2:** Run. Expected: FAIL (old gate refuses only below `WORKTREE_ADMIT_MIN_GB=10`; no 10/76 handling).
**Step 3:** `wtn_admit` calls `diskm admit --class worktrees --producer worktree-new:<repo> --dest <path> --source worktree-new`, handles each rc per the contract, then runs `git worktree add` and exits with its rc. The env thresholds remain only when `admit.sh` is missing (with `admission_degraded:caller`).
**Step 4:** `bash tests/test_worktree_new.sh`. Expected: PASS. **Step 5:** Commit `refactor: worktree-new admission via diskm admit`.

---

### Task 5: Lease kinds and provenance fields (C3, part 1)

**Files:** Modify `scripts/lib/worktree_lease.sh` (`lease_write` line 170, `_lease_emit_json` line 206). Test: `tests/test_worktree_lease.sh`.

**Step 1:** `lease_write <path> --kind scratch --producer gate-prep --source 'git:<url>@<sha>' --manifest <file>` round-trips all four fields; no `--kind` and pre-existing leases read as `worktree` with no provenance; `--kind bogus` → rc 2; `--published <url>` sets `published_at` and `published_url`.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement. **Step 4:** `bash tests/test_worktree_lease.sh`. Expected: PASS.
**Step 5:** Commit `feat: lease kind and provenance fields`.

---

### Task 6: `diskm scratch-new` (C3, part 2)

**Files:** Create `scripts/scratch_new.sh`. Modify `src/disk_magician/disk_magician.sh`, `scripts/evidence_push.sh` (`lease_write --published` after a successful upload receipt). Test: `tests/test_scratch_new.sh`.

**Interface:** `diskm scratch-new <repo-path> <purpose> [--kind scratch|evidence] [--detach <sha>] [--est-gb N]` admits first (class `worktrees`, or `tmp_containers` for `--kind evidence`) under the shared contract, then creates and prints the path. `--detach` runs `git -C <repo> worktree add --detach ~/.worktrees/<repo>/scratch-<purpose>-<UTC ts> <sha>` and records `source` = repo URL + sha; `--kind evidence` creates `/private/tmp/<repo>/evidence/<purpose>-<UTC ts>`. Writes a lease; rc 2 if the path resolves outside its root or `<purpose>` fails `^[a-z0-9-]{1,40}$`.

**Step 1:** `run_admit_contract "diskm scratch-new <repo> p --detach HEAD"`; detached path exists and `.git` is a file; lease kind `scratch` with `source`; `../x` → rc 2; `--kind evidence` creates the dir with an evidence lease; `evidence-push` stub success sets `published_at`.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement, reusing `wtn_main_repo` / `wtn_repo_name`. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: diskm scratch-new (detached worktrees, evidence dirs)`.

---

### Task 7: Prevention points before the pilot: hook, `/advice`, evidence producers, CI (C6, C13, spec §7.5)

**Files:** Create `hooks/disk-admission.sh` (PreToolUse Bash template), `scripts/ci_admit.sh`. Test: `tests/test_disk_admission_hook.sh`, `tests/test_ci_admit.sh`.

**Step 1:** Hook JSON on stdin with a stub admit. For each form — `git worktree add ~/.worktrees/r/n`, `cd /repo && git clone url /private/tmp/r/x`, `git -C /repo worktree add ../n`, `FOO=1 git clone url /private/tmp/r/y`, `cp -R a ~/.worktrees/r/z` — assert exit 0 and stdout JSON valid against the PreToolUse output schema; admit called with the right class, `--dest` and producer key (`hook:git-clone:<remote host/path>`, `hook:git-worktree-add:<repo>`, `hook:cp-R`) and `--source hook`. rc 0 → `permissionDecision: "allow"`; 10 → `allow` plus `systemMessage`; 3 → `allow` plus `admission_degraded:caller`; 75 → `deny` with the reuse reason; 76 → `deny` naming `retry_after_s`. **No input rewriting:** for input `tool_input` `{command, description, timeout: 600000, run_in_background: true, x_future: 1}` the output has no `updatedInput` key in any case. `ls`, destinations outside governed roots → no output, admit not called. CI: `run_admit_contract "bash scripts/ci_admit.sh"` with `--producer ci --source ci`; no `--completed` mode exists; RED/BLACK prints `launchctl bootout gui/$UID/<ezgha label>`; auto-pause only with `decision_approved ci_autopause`.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement the segment split, env strip, `cd`/`-C` tracking and literal match. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: disk admission hook and CI admission`.

**Outside this repo (D6, D2), each with its own test, all before Task 8 deploys:**
- Install the hook (`~/.claude/settings.json` PreToolUse Bash). **Live probe:** in a scratch session, `git clone <small repo> /private/tmp/probe/x` with `timeout` and `description` set runs with both fields honoured, and `events.jsonl` gains one `source: hook` line for `/private/tmp/probe/x`.
- `/advice` `~/.claude/skills/advice/scripts/run_primary_pair.py`: before the clone step, once per run, `diskm admit --class tmpdir_scratch --producer advice --est-gb <2 × source size> --dest <run dir> --source advice`; 0/10 proceed (10 logs), 75 stop with the admit message, 76 sleep `retry_after_s` once and re-admit, other rc proceed with a warning. A clone-step failure is reported as a clone failure and never retried as admission. Write `receipt.json` with source repo, resolved SHA, runner pid + `start_epoch` and the overlay manifest. Keep `git clone --no-local`, origin removal and `shutil.rmtree`. Tests in `test_run_primary_pair.py`: the five admit outcomes, a clone stub exiting 75 after admit 0 (no retry, reported as clone failure), and the manifest matching the overlay files.
- Evidence producers: `evidence-standards`, `ui-video-evidence`, `tmux-video-evidence` skill text creates bundle dirs with `diskm scratch-new <repo> <name> --kind evidence` and publishes with `diskm evidence-push`.
- ezgha: register `ci_admit.sh` as the job-started hook; one live job shows a `source: ci` event line.

---

### Task 8: `diskm govern` observe tick, daily measure and the C14-gated kickstart (C1, C10)

**Files:** Create `scripts/govern.sh`, `launchd/com.jleechanorg.disk-magician-govern.plist.template`, `launchd/com.jleechanorg.disk-magician-govern-measure.plist.template`. Modify `scripts/disk_budget.py` (`tick`, `daily_measure`, `state_update`), `src/disk_magician/disk_magician.sh` (`govern`), `scripts/install_launchd_sweepers.sh` (add templates; remove nothing), `scripts/job_inventory.py`. Test: `tests/test_govern.sh`.

**Interfaces:** `govern.sh [--mode observe|act] [--deadline-seconds 540]` takes `$STATE/govern.lock` (mkdir lock with pid; stale-pid takeover as in `worktree_reap.sh` `lock_dead`). `disk_budget.py tick`: (1) df → zone + `zone_at` via `state_update` (take `state.lock`, reread `budget.json`, merge only the caller's own keys, atomic replace, release); if BLACK/FLOOR: when `artifact_removal_verdict --self-test` prints `ok` from the running tree, `$DISK_MAGICIAN_LAUNCHCTL_BIN kickstart gui/$UID/com.jleechanorg.disk-magician-pressure-sweep` once and record `govern_emergency`, else record `kickstart_blocked:c14_missing` and call nothing; (2) next du class, 60 s timeout outside the lock, `skipped_measure_lock` while `measure.lock` is held; (3) observer classes; (4) `state_update` with the results. Write error → previous file kept, exit 3. `govern.sh --daily-measure` (03:00, `measure.lock`, 900 s) measures every class (du 60 s, `df_delta_only` 120 s), marks timeouts `carried`, and writes through `state_update`.

**Step 1:** `DISK_MAGICIAN_STATE_DIR=$(mktemp -d)`, fake df, du stub, launchctl stub, stub actuators. Cases: zone before du (du sleeps 120 s, `zone_at` fresh); du timeout ×3 keeps zone fresh and grows `stale_s`; round-robin across three classes; daily job runs every class once and marks timeouts `carried`; **interleaving:** `DISK_MAGICIAN_TEST_PAUSE_BEFORE_MERGE` holds the daily job after its scans, a tick writes BLACK and new births, the daily job resumes → final file has BLACK, the births and the daily values (and the reverse order); **kickstart gate:** BLACK with no `artifact_verdict.sh` → launchctl stub never called, `kickstart_blocked:c14_missing`; with a self-test stub printing `ok` → called exactly once, zone written first; observe mode runs no actuator; overlapping tick → `skipped_tick_lock`, no receipts; stale lock taken over; 5 GiB free → files valid; FLOOR → `floor_breach` receipt with top growing roots and stubbed `tmutil listlocalsnapshots /`; ENOSPC on a 2 MiB `hdiutil` image (skip off macOS) → exit 3, previous `budget.json` parseable; slowest 03:00 tick (every stub at its timeout while the daily job holds `measure.lock`) finishes within 540 s.
**Step 2:** `bash tests/test_govern.sh`. Expected: FAIL (`govern.sh` missing).
**Step 3:** Implement; plists `StartInterval 600` (`diskm govern --mode observe`) and 03:00 (`diskm govern --daily-measure`).
**Step 4:** `bash tests/test_govern.sh && bash scripts/sync_package_tree.sh --check && bash tests/test_install_launchd_sweepers_preflight.sh`. Expected: PASS; main-sweeper/pressure-sweep templates still installed.
**Step 5:** Commit `feat: diskm govern observe tick; kickstart gated on C14`.

---

### Task 9: Birth audit and birth counting, detection only (C7)

**Files:** Create `scripts/birth_audit.sh`. Modify `scripts/govern.sh` (audit each tick, 120 s du budget), `scripts/worktree_reap.sh` (`adopt` at line 132 accepts `--kind`), `scripts/disk_budget.py` (`estimates`: rewrite `admission/estimates.json` from measured admitted births). Test: `tests/test_birth_audit.sh`.

**Step 1:** Unleased fixtures: `/private/tmp/<repo>/advice-src-x` (`DISK_MAGICIAN_TMP_ROOT`), `$TMPDIR/advice-primary-pair-abc` with a `.git`, `$TMPDIR/com.apple.foo` (foreign), `~/Documents/Codex/2026-10-11/task-1`, plus one entry matching an admit event `dest`. After one audit: the matched entry counts as admitted (not bypass) and its measured size is recorded for `estimates.json`; three `scratch` leases on the others; `bypass.tmp_containers.births == 1`, `bypass.tmpdir_scratch.births == 1`; `foreign == 1`, no lease; a second audit adds nothing; every fixture still exists. **Short-lived:** an admit event for a 20 GiB `dest` that is created and deleted between two ticks → counted once as an admitted birth from the log; the same tree created and deleted with no admit event → not counted, and the day's report states coverage as "admitted or persistent ≥ one tick". An admit event whose `dest` never appears → `admitted_unconfirmed`; with 10 bypass and 40 confirmed + 60 unconfirmed admitted births, the births ratio is reported as 9.1% and 20% and fails (both must pass). **Unknown size:** a hanging du stub on a bypass entry → `bytes_unknown`, charged `max(class budget_gb, largest measured birth in that class)`, labelled `estimate`, retried on the next 3 audits and replaced on success; an entry measured later at 3 × its class budget raises the class's largest-birth value for later charges. Audit du stops at 120 s per tick, leaving the rest for the next tick. With `TMPDIR` unset, the root equals a stubbed `getconf DARWIN_USER_TEMP_DIR`. Calibration: 20 measured admitted births for `hook:git-clone:example` at 3 GiB → `estimates.json` 3.75 GiB; fewer than 20 → default.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement; producer prefixes from the fixed table only. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: birth audit and event-log birth counting`, bump, deploy.

**Pilot start.** When Tasks 3–10 are deployed with scheduled receipts or event lines, D2 is recorded, the hook live probe passed, and the emergency probe (spec §7.4) returned the expected row, record `pilot_start` in `budget.json`. `diskm budget status --pilot-check` (Task 10) decides validity; an invalid pilot restarts from a new `pilot_start`.

---

### Task 10: Alerts, weekly check and pilot validity (C12, spec §7.4–§7.6, §9), before the pilot

**Files:** Modify `scripts/sweeper_health_check.sh`, `scripts/disk_status.py` (alerts first), `scripts/disk_budget.py` (`status --weekly-check`, `--pilot-check`). Test: `tests/test_sweeper_health.sh`.

**Step 1:** Fixture receipts, event lines and observer lines; each prints `ALERT:<code>` before any accounting and exits 1: `floor_breach` (with the spec §7.6 runbook lines), `govern_stale` (> 30 min), `admission_degraded` (24 h), `activation_blocked`, `kickstart_blocked`, `quarantine_conflict`, `class_stale` (> 10800 s), `actuator_dead` (3 non-positive deltas over budget **and** zero removed; with removals → none), `actuator_starved`, `reclaim_starved`, `archive_overcap_kept`, `bypass_high` (24 h births ratio ≥ 10%), `burst_over_margin`, `colima_stopped` (> 1 h), `main_sweeper_error` (2 running), `trough_rise`, `parked_large` (> 20 GiB). `--weekly-check`: fixed calendar weeks; 90% observer coverage → `insufficient_data`, exit 1; full coverage and passing rows → exit 0; two passes count only for adjacent, non-overlapping weeks. `--pilot-check`: a passing fixture week → `pilot_valid` with `W_est`, `B_est` (labelled `estimate`), `r_peak`, `admit_burst_bytes` and `floor_margin_ok`; one fixture per invalidation rule (5 qualifying days; `deployed.json` admission hash changed; stage changed; fleet unhealthy 3 h) → `pilot_invalid:<rule>`, exit 1; a `B_est` far off does not change pass/fail. **Exposure (hand-computed):** samples every 60 s; a 12 GiB rise in one 600 s window, `T_reclaim` 240 s, `admit_burst_bytes` 10 GiB → exposure 0.02 × 900 + 10 = 28 GiB, `false`; the same rise **while** 12 GiB of unrelated admits land in the same window → `r_peak` still 0.02 GiB/s (nothing subtracted); a 3 GiB rise, burst 2 GiB → 0.005 × 900 + 2 = 6.5 GiB, `true`; no zone tick with a positive receipt → `margin_unknown`, fails. **Burst:** admits of 4 × 5 GiB within 600 s and margin 10 → `admit_burst_bytes` 20 GiB, `burst_over_margin`. **Bytes ratio:** 90 admitted births with est 45 GiB, 9 bypass births 3 GiB, 1 `bytes_unknown` in `tmp_containers` (budget 15, largest measured 4) → 18 / 63 = 28.6%, labelled `estimate`; 6 unknown of 100 births → `estimate_unbounded`. Output names every unit (`B/s`, `s`, `B`).
**Step 2:** Run. Expected: FAIL on new cases.
**Step 3:** Implement; trough from `disk_observer.jsonl{,.1,.2}` `host_disk.used_kb` reusing `history_diff.py`'s parse.
**Step 4:** Re-run plus `bash tests/test_sweeper_health_dispatch.sh`. Expected: PASS.
**Step 5:** Commit `feat: governor alerts, weekly and pilot validity checks`.

---

### Task 11: `artifact_removal_verdict` on every delete path (C14)

**Files:** Create `scripts/lib/artifact_verdict.sh` (with `--self-test`), `scripts/lib/quarantine.sh`, `scripts/quarantine_rename.py` (`renamex_np` with `RENAME_EXCL` via `ctypes`). Modify every path in the spec §7.2 delete-path table: `scripts/worktree_reap.sh` (remove path), `scripts/cleanup_worktrees.sh` (each `git worktree remove`; antigravity `rm -r -f` at line 676), `scripts/lib/scratch_budget.sh`, `scripts/cleanup_tmp.sh` (`remove_path` line 316, `purge_aged_archives` lines 675 and 705; the over-cap purge no longer bypasses guards), `scripts/cleanup_code_sign_clones.sh` (line 256, kind `os_clone`), `scripts/cleanup_codex_documents.sh` (#151). Test: `tests/test_artifact_verdict.sh`, `tests/test_removal_sites.sh`.

**Interface:** `artifact_removal_verdict <path> [--kind os_clone] [--context <sidecar.json>]` prints `remove` or `kept:<reason>`, rc 0; any internal failure → `kept:check-failed`. Rules per spec §7.2 "C14 rules": bounded fetch (cached per repo per tick) then `git rev-list --all --reflog --not --remotes` empty; registered worktrees also `wrh_removal_verdict "$p" minutes:30 origin-or-merged-pr`; every non-git file proven by manifest, published-evidence receipt, or the #153 allowlist; liveness, mtime, `safety_check.sh` and owner checks. `quarantine_remove <path>` writes the sidecar (original path, device + inode, producer, lease/receipt id, manifest), renames into `<parent>/.dm-quarantine/<id>` (same device only), re-runs the verdict with `--context`, deletes on `remove`, otherwise renames back with `RENAME_EXCL`; on `EEXIST` it leaves the artifact quarantined and writes `quarantine_conflict`.

**Step 1:** Fixture matrix, each expecting `kept:*`: **reflog-only commit** (clean clone; commit X, `git reset --hard origin/main`; X only in the reflog) → `kept:not-pushed`; **unique `notes.txt`** (90 min old, no lease or receipt, under a producer prefix such as `$TMPDIR/advice-x/`, and in a root past any retention) → `kept:unproven-content`; **custom-named secret** (`deploy_backup.txt` holding a token, not matching any secret-like pattern, no manifest) → `kept:unproven-content`; **unpublished output** (`results.json` under `evidence/` with no `published_at`) → kept; **stale remote-tracking ref** (commit only on `origin/feat` locally, then `feat` deleted on the bare remote; and a force-push variant) → `kept:not-pushed`; **fetch failure** (missing remote path; a stub sleeping past 60 s) → `kept:remote-unverified`, no prompt; dirty; untracked file; assume-unchanged entry; ignored `.env`; ignored `data/notes.db`; HEAD not on remote; unpushed local tag; stash only; non-git dir with an open file; a process with cwd inside; content 10 min old; idle live lease owner; owner `unknown` (ps stub fails). Positive fixtures → `remove`: a lease whose manifest lists every file with matching sha256 (one changed byte → `kept:unproven-content`); a published-evidence dir; ignored `node_modules/` in an otherwise pushed clean worktree (allowlist); a released lease with a live pid. `/advice` disposable-copy fixtures (spec §11): runner dead, 3 h idle, nothing beyond the SHA (incl. `--reflog`), source has the SHA → `remove`; extra commit → `kept:not-pushed`; runner alive → `kept:live-owner`; no receipt → `kept:check-failed`; source deleted → `kept:source-missing`; overlay without manifest, an extra `notes.md` or one changed byte → `kept:overlay-unproven`. **Quarantine:** a manifest-proven root survives rename and recheck and is removed; `DISK_MAGICIAN_TEST_AFTER_QUARANTINE` opens a file inside → rollback; the same hook also recreates the original path → original untouched, artifact still in `.dm-quarantine/`, `quarantine_conflict`; a quarantine parent on another device (`hdiutil` image; skip off macOS) → `kept:cross-device`, nothing copied. **Wiring:** with a fixture C14 keeps, every modified script leaves it; an over-cap archive entry C14 keeps survives `purge_aged_archives` and raises `archive_overcap_kept`. **Race:** `DISK_MAGICIAN_TEST_AFTER_NOMINATE` writes an untracked file between nomination and removal → kept. **Lint:** `tests/test_removal_sites.sh` scans every §7.2 file (and files they `source` or exec for deletion) and fails if `rm -r`, `rm -rf`, `rmtree`, `find … -delete`, `git worktree remove` or `wrh_remove_now` is not preceded in the same function by `artifact_removal_verdict` or `quarantine_remove` on the same variable; a planted unguarded `rm -rf` makes it fail.
**Step 2:** Run. Expected: FAIL (helper missing; `cleanup_worktrees.sh` removes the open-file fixture; the over-cap purge deletes the kept archive).
**Step 3:** Implement and wire. **Step 4:** Run plus `bash tests/test_worktree_reap.sh && bash tests/test_cleanup_worktrees_merged_fastpath.sh && bash tests/test_scratch_budget.sh && bash tests/test_cleanup_tmp_archive_purge.sh && bash tests/test_cleanup_tmp_open_files.sh && bash tests/test_cleanup_code_sign_clones.sh`. Expected: PASS.
**Step 5:** Commit `feat: artifact_removal_verdict gates every delete path`. Then rebase #151 and #152 onto it, add the C14 call to each new delete path with a fixture from the Task 0 dry-run lists that C14 keeps, and merge them (merge gate). Deploying this task enables the Task 8 kickstart; record that in the pilot report.

---

### Task 12: Owner proof and session-exit release (C8, spec §7.3)

**Files:** Modify `scripts/worktree_reap.sh` (`verdict_for`: T1 only for `lease_owner_state` `dead`/`released` + 30 min quiet; TTL-expired with owner alive → `kept:expired_owner_alive`), `scripts/lib/worktree_lease.sh` (`lease_release_owner_session <id> <runtime_pid> <runtime_start_epoch>`), `src/disk_magician/disk_magician.sh` (`lease-release --owner-session`). Create `hooks/session-end-lease-release.sh`. Test: `tests/test_worktree_reap.sh`, `tests/test_lease_release_session.sh`.

**Step 1:** Reap: live owner with TTL expired 30 h ago → kept; `SIGSTOP`ped owner → kept; pid alive with a different `start_epoch` → dead → proceeds to C14; ps error → `unknown` → kept; owner dead but a child with cwd inside → C14 keeps. Release: leases A (session S, owner = ending runtime), B (session S, other live pid), C (session T); releasing S marks only A, reports B as `release_skipped_live_owner`; unknown session → rc 0, no change; the released worktree still exists.
**Step 2:** Run. Expected: FAIL (current reaper treats TTL expiry + 6 h quiet as eligible). **Step 3:** Implement. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: owner death by pid+start epoch only; scoped session release`.

**Outside this repo (D6):** install the hook under SessionEnd and SubagentStop; one paragraph in `superpowers-using-git-worktrees`, `draft-first-pr`, `evidence-standards`: create via `diskm worktree-new`/`scratch-new`, `git push -u origin HEAD` before exit (never force), `diskm evidence-push`.

---

### Task 13: `CLAUDE.md` amendment, then the first T1 removal (D1)

**Precondition:** D1 recorded through Task 2; Tasks 11 and 12 deployed.
**Step 1:** PR amending `CLAUDE.md` "Worktree 7-day rule" with the spec §7.3 T1 text, quoting D1 verbatim and containing `<!-- policy:worktree_reap_remove -->`; merge under the merge gate; then `diskm policy set-amendment worktree_reap_remove <merge sha>`.
**Step 2:** Before `set-amendment`, `diskm worktree-reap --mode remove` must produce `activation_blocked:amendment_missing` and nominate only (recorded in the PR). After it, `diskm status` shows no `activation_blocked`; run `diskm worktree-reap --mode remove --deadline-seconds 1500`; record `df_delta_bytes` and the `kept:*` histogram.
**Step 3:** `df -k`; report the delta. Review confirms no remove-mode receipt predates the amendment.

---

### Task 14: Govern act mode with progress-tracking scheduler (C9, C10)

**Precondition:** #150 deployed; #151 and #152 merged with C14 after Task 11; Task 11 deployed (a class whose delete paths are not C14-wired stays nominate).

**Files:** Modify `scripts/govern.sh` (per-class `act`; worktrees run `worktree_reap.sh --mode remove` only with `worktree_reap_remove`, else nominate; `cleanup_worktrees.sh --clean` only with `worktree_cleanup`; scheduler per spec C10 with `$STATE/govern_sched.json`; process-group launch and teardown; `--deadline-seconds` + `$STATE/cursor_<class>` passed to `worktree_reap.sh`, `cleanup_worktrees.sh`, `cleanup_tmp.sh`, `cleanup_codex_documents.sh`), `scripts/worktree_reap.sh` (append kept items to `$STATE/parked.jsonl` with sizes), govern template (`--mode act`). Test: `tests/test_govern.sh`, `tests/test_worktree_reap.sh`.

**Step 1:** No decisions, over-budget tmp_containers, codex_documents (RED), colima → those run; worktrees nominate; `cleanup_worktrees.sh` not invoked; `worktree_cleanup` approved but `removal_activation_ok` failing → still not invoked; passing → invoked under its own lock. Actuator lock held → `skipped_lock`, next still runs. **Deadline:** ten actuators that each use their full slice → wall time ≤ 540 s including measure, audit, receipts and teardown grace; eight run at 60 s, two `deferred` and run first next tick. **Process tree:** a stub whose shell spawns a `sleep 1000` grandchild and exits → after its slice no process in its group survives, `orphan_survivors` recorded, lock taken over next tick; SIGTERM arrives only between units (a stub mid-delete finishes that unit). **Reclaim progress:** a stub needing a 120 s scan per deletion, one artifact per unit, fake df rising per delete, 60 s slices → ≥ 1 removal and `df_delta_bytes > 0` within 3 ticks via the cursor; without cursor support → `reclaim_starved` at tick 3, exclusive 300 s slice at tick 4, next tier at tick 6. RED → BLACK: order by 7-day df delta, except an actuator deferred 3 ticks runs first. Owner-null clean pushed worktree idle 25 h → `parked.jsonl`. Every `govern_<class>` receipt has non-null `df_delta_bytes` and `removed_count`. Colima: df rises only at the next tick → `df_delta_bytes` 0, `df_delta_bytes_lagged` > 0, no `actuator_dead`/`reclaim_starved`.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement.
**Step 4:** `bash tests/test_govern.sh && bash tests/test_worktree_reap.sh && bash tests/test_worktree_reap_dispatch.sh`. Expected: PASS.
**Step 5:** Commit `feat: govern act mode with progress-tracking scheduler`, deploy, check next-morning df and `govern_*` receipts with `removed_count > 0`.

---

### Task 15: Reuse-first worktree-new (C5)

**Files:** Modify `scripts/worktree_new.sh` (`wtn_main`): before `wtn_create`, pick a candidate (same repo, owner `dead`/`released`, `worktree_is_recently_active_minutes 120` false), claim it with `lease_write_pending`, re-run `artifact_removal_verdict`, record the old branch tip `T` and continue only if `git merge-base --is-ancestor T origin/main` or `T` equals the live `git ls-remote` tip; `git switch --detach`; `git update-ref -d refs/heads/<old> T` (conditional on the ref still being `T`); `git switch -c <branch> <base>`; rewrite the lease. On any failure: `git switch <old>` if the branch still exists, restore the claim, create fresh. Test: `tests/test_worktree_new.sh`.

**Step 1:** Merged old branch → recycled, old branch gone, no new dir. Unpushed commit on the old branch → fresh dir, branch and worktree intact. Untracked file → fresh, file intact (no `git clean`). Ignored `.env` and `data/notes.db` → fresh. Live cwd → fresh. Two concurrent calls → one recycles, the other creates fresh. **Final-boundary race:** `DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF` commits to the old branch after detach → `update-ref` fails, the branch keeps the new commit, the checkout is back on `<old>`, a fresh dir is created.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: reuse-first worktree-new with conditional branch delete`.

---

## Sequencing (gate before act, prevention before pilot, policy before T1)

| Order | Tasks | PR | Gated on | Measurable effect |
|---|---|---|---|---|
| 0 | Task 0 | #150 merge + observe/dry-run ops (no `--clean`) | merge gate | Colima trim df delta; dry-run baselines |
| 1 | Tasks 1, 2 | PR-A (receipts), PR-B (policy + `removal_activation_ok`) | none | decisions recordable; every decision path nominate |
| 2 | Tasks 3, 4 | PR-C (admit + event log), PR-D (worktree-new) | D2 for non-zero rc | refusals, event log |
| 3 | Tasks 5, 6, 7 | PR-E (lease fields + scratch-new), PR-F (hook + CI) + external PRs | D6 | prevention coverage incl. CI |
| 4 | Tasks 8, 9, 10 | PR-G (govern observe), PR-H (audit), PR-I (alerts + pilot check) | D2 + emergency probe + hook probe | **pilot starts**; kickstart still blocked |
| 5 | Tasks 11, 12 | PR-J (C14 on every delete path), then #151 and #152 with C14; PR-K (owner proof + release) | none | kickstart and codex-documents / tmp-descent reclaim begin |
| 6 | Task 13 | PR-L (`CLAUDE.md`) + `set-amendment` + ops | D1 | first T1 df delta |
| 7 | Task 14 | PR-M (act + scheduler) | #150; #151 and #152 with C14; D1b for T3 | class stock, df trough |
| 8 | Task 15 | PR-N | none | births/day |

Tasks 11–12 may land during the pilot: they touch removal code and the emergency kickstart, not admission, audit, hook or measurement, so they do not invalidate it; the pilot report records when the kickstart became active.

**Pilot gate.** Enforcement stays `observe` (emergency rows active with D2) until `--pilot-check` reports `pilot_valid`, then `warn`. `refuse_red` requires D3 with pilot-measured budgets and margin, the §7.5 births SLO and `floor_margin_ok`; `refuse_orange` follows 7 days later. Each stage change is recorded with `diskm policy approve admission_enforcement`; `diskm budget set-stage <previous>` rolls back without touching the emergency rows (tested in Task 3).

## Verification after each deploy (by stage)

1. Always: `diskm status --json`; any `ALERT:` lines are reported first. The govern, main-sweeper and pressure-sweep jobs each have a receipt newer than their interval (loaded is not enough).
2. From Task 3: the last `events.jsonl` line parses and matches the decision just made by a `diskm admit --dry-run` probe's zone.
3. From Task 8: `govern_*` receipt < 15 min old and `budget.json` `zone_at` < 15 min old. Observe mode has no actuator progress; that is expected.
4. From Task 14: act-mode receipts show non-null `df_delta_bytes` and progress (not only `skipped_*`) within a day.
5. Unattended gate: `deployed.json` hash equals the merged origin/main tree, the installed plist matches its template (`plutil -p`, never bare `-extract`), `artifact_removal_verdict --self-test` prints `ok` from the deployed tree (from Task 11), and `diskm policy list` shows the expected decision state. A manual run is not evidence.
6. Weekly: `diskm budget status --weekly-check`. Close the workstream bead after two consecutive non-overlapping passing weeks.
