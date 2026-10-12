# Disk-Fill Durable Control Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the disk-use loop with a `diskm` budget governor: reservation-based admission at creation, a stage-independent BLACK/floor emergency, owner-lifecycle reclaim behind one final per-artifact check, and df-verified receipts. Success is spec §9: 7-day minimum free ≥ 30 GiB, zero samples under 15 GiB free, and a daily used trough ≤ 790 GiB, on two consecutive weekly checks.

**Architecture:**
- `diskm admit` runs its own `df`, takes an `fcntl.flock` on the reservation ledger, computes `projected = df_free − reserved − est`, decides by the policy table, and records a reservation on 0/10.
- A 10-minute `diskm govern` tick (global `govern.lock`) writes the df zone first, kickstarts pressure-sweep in BLACK/FLOOR, measures one du class, runs the birth audit, and runs act-mode actuators through a time-sliced, rotating scheduler. Each actuator writes a receipt with `df_delta_bytes`.
- Every removal calls `artifact_removal_verdict` immediately before the destructive call.
- `main_sweeper` and `pressure-sweep` stay installed and unchanged.

**Tech Stack:** Bash (scripts/, scripts/lib/), Python 3 stdlib (`fcntl`, `subprocess` timeouts), launchd templates, shell tests under `tests/`, unittest/pytest.

**Spec:** `docs/superpowers/specs/2026-10-11-disk-fill-durable-control-design.md` (revision 3)
**Base:** origin/main `688fff6`, version 0.2.197. Usable capacity about 895 GiB (df used + avail).

---

## Global Constraints

- **Entry point.** Every operation is a `diskm` subcommand in `src/disk_magician/disk_magician.sh`; mirror with `scripts/sync_package_tree.sh` and check with `--check` in review.
- **Removal gate.** Every removal calls `artifact_removal_verdict` (Task 12) immediately before `wrh_remove_now` or `scratch_budget_evict_root`'s delete. No ad-hoc `rm`. Never touch never-delete paths.
- **Recency** only through `scripts/lib/worktree_recency.sh`, fail closed, with a test that the unmeasurable case is protected.
- **Owner liveness** only through `lease_owner_state` (pid + `start_epoch`). TTL expiry and quiet time never make an owner dead. `unknown`/`unreadable` = alive = keep.
- **Unknowns.** Unknown class measurement = drop that class's overage term only. df failure or an unexpected admit rc = proceed with an `admission_blind` receipt.
- **Existing jobs.** Do not uninstall or reschedule `main_sweeper` or `pressure-sweep`. The governor takes each actuator's existing lock and records `skipped_lock` when held; it may `launchctl kickstart` pressure-sweep.
- **ZFC.** Class membership comes from the fixed governed-root table; the hook matches literal syntax. No keyword scoring.
- **Portability on macOS.** No `flock(1)` or `timeout(1)`: use Python `fcntl.flock` and `subprocess.run(timeout=)`.
- **Plists.** Never `plutil -extract` without `-o -`. Templates use `@HOME@` / `@REPO_ROOT@` via `scripts/install_launchd_sweepers.sh`.
- **Deploy.** Each merged PR bumps `pyproject.toml` and runs `tools/deploy_uv_tool.sh` from clean origin/main; verify `deployed.json` and one scheduled receipt with progress before calling it live.
- **PR size.** At most 150 production lines per PR, or the size-tiered merge gate.
- **Approvals.** No task sets `WORKTREE_APPROVED`, writes `worktree_reap.remove_approved`, or records a standing decision on the user's behalf. Decisions are written by `diskm policy approve --from-transcript` only after the user's literal phrase appears in a live user message.

## Assumptions

| Assumption | Default used by this plan | If wrong |
|---|---|---|
| Callers can release reservations | Every caller releases in an EXIT trap; TTL 30 min and dead-pid cleanup cover crashes | Over-refusal for ≤ 30 min, alert `admission_ledger_reset` only on corruption |
| `--est-gb` per caller | worktree-new / scratch-new 1; evidence 1; `/advice` 2 × source checkout; CI 20 | Pilot compares est to df delta per class; D3 retunes |
| Governor runs as the user under launchd | `getconf DARWIN_USER_TEMP_DIR` resolves `$TMPDIR` | Birth audit test asserts the unset-`TMPDIR` path |
| Hook JSON carries `session_id` and the runtime pid is resolvable | `lease_resolve_owner` (PR #148) | Release skips and reports; nothing deleted |

## Implementation Preconditions

| Gate | Needed before | Recorded by |
|---|---|---|
| D2 (`admission_enforcement`) | Any non-zero admit rc in production (emergency rows first) | `diskm policy approve` (Task 2) |
| D6 | Task 8 external edits, Task 13 hook install | user phrase |
| D1 (`worktree_reap_remove`) + merged `CLAUDE.md` amendment + Tasks 12, 13 deployed | First T1 removal (Task 14) | user phrase, Task 14 PR |
| D1b (`worktree_cleanup`) + Task 12 deployed | T3 unattended (Task 15) | user phrase |
| D3 + §7.5 SLO passing | Stage beyond `warn` | user phrase after pilot |
| D4 (`ci_autopause`) | CI auto-pause (Task 16) | user phrase |
| #150, #151, #152 deployed | Task 15 enabling colima / codex_documents / tmp actuators | merge gate |

## Review Focus

1. **No existing cleanup stops.** main_sweeper and pressure-sweep plists are unchanged.
2. **Concurrent admission cannot oversubscribe** (Task 4's 20-process test) and **never goes blind on du**.
3. **Every removal path calls `artifact_removal_verdict`**, proven behaviorally and by the call-site lint (Task 12).
4. **Owner death is pid + start epoch only** (Task 13); release deletes nothing.
5. **Every caller handles 0, 10, 75, 76 and an unexpected rc** (shared contract helper, Tasks 5, 7, 8, 16).
6. **Prevention lands before the pilot**; the pilot cannot start until Tasks 3–10 are live.
7. **No actuator starves** (Task 15) and **`CLAUDE.md` precedes T1** (Task 14).
8. **Disk-full behaviour.** A tick at about 5 GiB free writes `budget.json` and receipts; ENOSPC keeps the previous file.

## TDD Plan Check

| Task | RED test (fails before change) | GREEN condition | Layer |
|---|---|---|---|
| 0 | n/a (ops with merged/open PRs; no removal) | per-step df deltas recorded | live df |
| 1 | `tests/test_job_receipt.py::TestDfDelta` | `df_delta_bytes = after − before`; `govern_*` missing delta → `error`/`null_df_delta` | unit |
| 2 | `tests/test_policy.sh` incl. "phrase absent from transcript" | approve only with phrase in a `type:user` message; revoke; no expiry | shell |
| 3 | `tests/test_disk_budget.py` policy table + `tests/test_admit.sh` "du stub hangs, RED still refuses" | rc per zone/stage/D2; stale class drops overage only; df failure → 0 + `admission_blind` | unit + shell |
| 4 | `tests/test_admit_reservations.sh` "20 concurrent × 10 GiB at 105 GiB free" | exactly the predicted admits; Σ reserved ≤ df_free − 30; dead/expired/released entries dropped | shell integration |
| 5 | `tests/test_worktree_new.sh` admit contract (0/10/75/76/rc 3) | 0, 10 create (10 warns); 75 exits 75; 76 retries once then 75; rc 3 creates + `admission_blind` | shell |
| 6 | `tests/test_worktree_lease.sh` "kind round-trips" | `kind` present, default `worktree` | shell |
| 7 | `tests/test_scratch_new.sh` contract + "detach shares objects; refuses outside root"; evidence kind | admit called first; detached `.git` file; evidence dir under `/private/tmp/<repo>/evidence` | shell integration |
| 8 | `tests/test_disk_admission_hook.sh` (all forms × all rc); `test_run_primary_pair.py` admit cases | hook deny on 75/76, allow+warn on 10; advice stops on 75, retries once on 76 | shell + unit |
| 9 | `tests/test_govern.sh` zone-first, du timeout, round-robin, daily du carry-forward, overlapping tick, BLACK kickstart, 5 GiB, ENOSPC | zone fresh; `skipped_tick_lock`; kickstart once per BLACK tick | shell integration |
| 10 | `tests/test_birth_audit.sh` incl. `$TMPDIR` unset, foreign entry, bytes | adopted once; `bypass` births+bytes; foreign counted not adopted; nothing deleted | shell |
| 11 | `tests/test_sweeper_health.sh` new alerts + `--weekly-check` coverage | each `ALERT:<code>` first, exit 1; `insufficient_data` fails | shell integration |
| 12 | `tests/test_artifact_verdict.sh` matrix + `tests/test_removal_sites.sh` lint + race | each unsafe fixture `kept:*`; every removal site calls C14; mid-run dirtying keeps | shell integration |
| 13 | `tests/test_worktree_reap.sh` owner-proof cases + `tests/test_lease_release_session.sh` | expired-TTL live/suspended owner kept; pid reuse = dead; only own-runtime leases released | shell |
| 14 | n/a (policy text + ops) | `CLAUDE.md` merged before first remove-mode receipt | live df |
| 15 | `tests/test_govern.sh` scheduler + per-class act cases | 10 slow actuators all run within 2 ticks; T3 only with D1b | shell integration |
| 16 | `tests/test_worktree_new.sh` reuse-first incl. branch cases, concurrency; `tests/test_ci_admit.sh` | merged old branch `-d`'d; unmerged → fresh, branch intact; one claimant | shell integration |

## Dependencies on in-flight work (do not duplicate)

| Item | Status (verified 2026-10-11 22:1xZ) | Relationship |
|---|---|---|
| PR #148: leases, reaper, `wtn_admit` | merged 10-11T13:01Z, deployed | Base for Tasks 5, 6, 10, 12, 13, 16. Owner-exit thresholds are in bead `7u9t` |
| PR #149: pressure-sweep tmp within budget | merged | Unchanged; kickstarted in BLACK |
| PR #150: Colima stopped-VM guard + stale lima lock | open | Deploy before Task 15 enables colima; Task 11 `colima_stopped` and D8 reuse it |
| PR #151: `diskm cleanup-codex-documents` | open | Deploy before Task 15 enables `codex_documents` |
| PR #152: `cleanup_tmp.sh` descends into active tmp containers | open | Deploy before Task 12 wires C14 into it and before Task 15 |
| PR #153: hygiene reuses rebuildable-ignored allowlist | open | C14 and Task 16 use `scripts/lib/worktree_ignored.sh` |
| Beads `7u9t`, `oyt4`, `67xj`, `i2o`, `d45` | open | D1; Tasks 13/15; PR #150; Task 15; Task 10 |

**Shared test helper.** `tests/lib/admit_contract.sh` provides `run_admit_contract <caller-cmd>`: a stub `DISK_MAGICIAN_ADMIT_BIN` returning 0, 10, 75, 76 (then 76 or 0), and 3, with `DISK_MAGICIAN_ADMIT_RETRY_CAP_S=0`. Expected per caller: 0 → proceed and `--release` called; 10 → proceed, one `disk-admission: warn` stderr line; 75 → stop with the admit message, nothing created; 76 → one retry, then stop if still 76 or proceed on 0; 3 → proceed + `admission_blind` receipt.

---

### Task 0: Stage 0. Same-day floor drop with existing machinery (no code, no removal)

**Step 1: Baseline.** `df -k /System/Volumes/Data` and `./disk_magician.sh check-launchd-fleet`; report an unhealthy fleet first.
**Step 2: Land actuator fixes.** Merge and deploy #150, #151, #152, #153 (size-tiered gate; one version bump each). Between CI jobs, `colima stop && colima start`, then `colima ssh -- sudo fstrim -av`. Run `diskm cleanup-codex-documents --clean`.
**Step 3: Verify.** Re-run `df -k`; report each step's df delta, not du.

The T1 reap is not here: it waits for the `CLAUDE.md` amendment and C14 (Task 14). Expected: the Colima trim plus codex documents; success test is df free the next morning.

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

### Task 2: Standing-decision record with transcript provenance (C11)

**Files:** Create `scripts/policy.sh`, `scripts/policy_provenance.py`. Modify `scripts/safety_lib.sh` (`decision_approved <id>`), `src/disk_magician/disk_magician.sh` (`policy`), `scripts/worktree_reap.sh:98` (decision `worktree_reap_remove` as an alternative to the marker file), `scripts/main_sweeper.sh:376,389` and `scripts/worktree_hygiene.sh` (decision `worktree_cleanup` as an alternative to `WORKTREE_APPROVED=1`), `scripts/cleanup_claude_state.sh`. Test: `tests/test_policy.sh`.

**Interface:** `diskm policy approve <id> --phrase '<text>' --from-transcript <session.jsonl>` writes `{id, phrase, transcript, approved_at, revoked_at:null}` atomically to `~/.config/disk-magician/standing_decisions.json` (override `DISK_MAGICIAN_POLICY_FILE`); `revoke <id>`; `list`. Fixed ids: `worktree_reap_remove` (D1), `worktree_cleanup` (D1b), `admission_enforcement` (D2), `budgets` (D3), `ci_autopause` (D4), `colima_selfheal` (D8), `claude_state_cleanup`.

**Step 1:** Fixture transcripts: one with the phrase in a `type:user` message, one with it only inside a `tool_result`. Tests: unknown id → rc 2; empty phrase → rc 2; phrase only in tool result → rc 2, file unchanged; approve → `decision_approved` 0; revoke → 1 and the reaper/main_sweeper skip again; no expiry field; reaper remove gate accepts the decision without the marker; main_sweeper Tier 6 runs `cleanup_worktrees.sh --clean` only with `worktree_cleanup`.
**Step 2:** `bash tests/test_policy.sh`. Expected: FAIL. **Step 3:** Implement.
**Step 4:** `bash tests/test_policy.sh && bash tests/test_worktree_reap.sh && bash tests/test_main_sweeper.sh`. Expected: PASS.
**Step 5:** Commit `feat: diskm policy standing decisions with transcript provenance`. The spec states this is procedural, not a security boundary.

---

### Task 3: Budget config, zones and `diskm admit` (C1, C2 single caller)

**Files:** Create `scripts/admit.sh`, `scripts/disk_budget.py`, `scripts/lib/disk_budget.sh`. Modify `src/disk_magician/config.json.template` (`budgets` block with the spec §7.2 class table, `enforcement: observe`), `src/disk_magician/disk_magician.sh` (`admit`, `budget`). Test: `tests/test_disk_budget.py`, `tests/test_admit.sh`.

**Policy table** (stage from `budgets.enforcement`; admission zone from `projected`; emergency rows apply only when `decision_approved admission_enforcement`, otherwise they return 10):

| Admission zone | Class over budget (fresh ≤ 3 h) | observe | warn | refuse_red | refuse_orange |
|---|---|---|---|---|---|
| GREEN ≥ 100 | any | 0 | 0 | 0 | 0 |
| ORANGE 60–100 | no, stale, or df_delta_only | 0 | 10 | 10 | 10 |
| ORANGE | yes | 0 | 10 | 10 | 75 |
| RED 30–60 | any | 0 | 10 | 75 | 75 |
| BLACK 15–30 | any | 76 | 76 | 76 | 76 |
| FLOOR < 15 | any | 75 | 75 | 75 | 75 |
| df fails | n/a | 0 + `admission_blind` | same | same | same |

`disk_budget.py zone --free-gb N` and `admit --class C --est-gb N` implement it; `admit.sh` is the thin shell entry. Task 3 computes `projected = df_free − est` (reservations arrive in Task 4).

**Step 1:** Parametrized pytest over every row × stage × D2 on/off, plus `est` pushing GREEN into BLACK (`--est-gb 80` at 105 free → 76) and an oversized request (`--est-gb 200` → 75). Shell: (a) admit under 200 ms with a `DISK_MAGICIAN_DU_BIN` stub that fails if invoked; (b) `budget.json` 2 h old, every class stale, fake df RED, `refuse_red` → 75, no `admission_blind`; (c) fake df exits 1 → 0 + `admission_blind`.
**Step 2:** Run. Expected: FAIL (`admit.sh` missing).
**Step 3:** Implement. `budget status` prints zone, per-class used/budget/stale age, reserved bytes, parked total and alert lines.
**Step 4:** `python3 -m pytest tests/test_disk_budget.py -v && bash tests/test_admit.sh && bash scripts/sync_package_tree.sh --check`. Expected: PASS.
**Step 5:** Commit `feat: diskm admit on projected free with emergency rows`.

---

### Task 4: Reservation ledger (C2 concurrency)

**Files:** Modify `scripts/disk_budget.py` (`reserve`, `release`, `prune`), `scripts/admit.sh` (`--release <id>`, `--owner`, `--ttl-min`, owner pid = `$PPID`). Test: `tests/test_admit_reservations.sh`.

**Interface:** ledger `~/.disk_magician_state/admission/reservations.json`, lock `reservations.lock` via `fcntl.flock(LOCK_EX)`. Inside one lock: prune (released, `expires_at` past, or `lease_owner_state`-style pid + `start_epoch` dead), sum, decide, append on 0/10, atomic replace. Print `reservation_id=<id>` on 0/10. Corrupt ledger → rename to `reservations.json.corrupt-<ts>`, write `admission_ledger_reset` receipt, continue empty.

**Step 1:** Cases, all with fake df at 105 GiB free and D2 recorded:
- **20 concurrent, `refuse_red`:** launch 20 `diskm admit --class worktrees --est-gb 10` in background, `wait`. Expected exactly 4 × rc 10 (projected 95, 85, 75, 65: ORANGE, not over budget) and 16 × rc 75 (projected 55: RED); ledger has 4 entries totalling 40 GiB.
- **20 concurrent, `observe`:** exactly 7 × rc 0 (projected 95 … 35) and 13 × rc 76 (projected 25: BLACK); Σ reserved = 70 ≤ 105 − 30.
- **Release:** `--release <id>` drops it; a following admit sees the space.
- **Expiry:** entry with `expires_at` in the past is pruned.
- **Crash:** caller SIGKILLed after admit; next admit prunes it (pid dead); a reused pid with a different `start_epoch` also prunes.
- **Corrupt ledger:** garbage JSON → moved aside, alert receipt, admit returns per table.
**Step 2:** Run. Expected: FAIL (no ledger: all 20 admitted).
**Step 3:** Implement. **Step 4:** Run plus Task 3 tests. Expected: PASS.
**Step 5:** Commit `feat: flock'd admission reservation ledger`.

---

### Task 5: `wtn_admit` delegates, with the caller contract

**Files:** Modify `scripts/worktree_new.sh:179-201`. Create `tests/lib/admit_contract.sh`. Test: `tests/test_worktree_new.sh`.

**Step 1:** `run_admit_contract "diskm worktree-new <repo> <branch>"` (all five outcomes) plus: fake df RED, `refuse_red`, real admit → exit 75 with the existing reuse message; GREEN creates and the reservation is released after creation.
**Step 2:** Run. Expected: FAIL (old gate refuses only below `WORKTREE_ADMIT_MIN_GB=10`; no 10/76 handling).
**Step 3:** `wtn_admit` calls `admit.sh --class worktrees --est-gb 1`, handles each rc per the contract, and releases in an EXIT trap. The env thresholds remain only when `admit.sh` is missing (with `admission_blind`).
**Step 4:** `bash tests/test_worktree_new.sh`. Expected: PASS.
**Step 5:** Commit `refactor: worktree-new admission via diskm admit`.

---

### Task 6: Lease kinds (C3, part 1)

**Files:** Modify `scripts/lib/worktree_lease.sh` (`lease_write` line 170, `_lease_emit_json` line 206). Test: `tests/test_worktree_lease.sh`.

**Step 1:** `lease_write <path> --kind scratch` yields `"kind":"scratch"`; no `--kind` and pre-existing leases read as `worktree`; `--kind bogus` → rc 2; `--published` sets `published_at`.
**Step 2:** Run. Expected: FAIL. **Step 3:** Add `--kind` (`worktree|clone|scratch|evidence`) and `--published`.
**Step 4:** `bash tests/test_worktree_lease.sh`. Expected: PASS. **Step 5:** Commit `feat: lease kind field`.

---

### Task 7: `diskm scratch-new` (C3, part 2), after admit exists

**Files:** Create `scripts/scratch_new.sh`. Modify `src/disk_magician/disk_magician.sh`, `scripts/evidence_push.sh` (`lease_write --published` after a successful upload receipt). Test: `tests/test_scratch_new.sh`.

**Interface:** `diskm scratch-new <repo-path> <purpose> [--kind scratch|evidence] [--detach <sha>] [--est-gb N]` prints the path. It calls `admit.sh` first (class `worktrees`, or `tmp_containers` for `--kind evidence`) under the shared contract. `--detach` runs `git -C <repo> worktree add --detach ~/.worktrees/<repo>/scratch-<purpose>-<UTC ts> <sha>`; `--kind evidence` creates `/private/tmp/<repo>/evidence/<purpose>-<UTC ts>` (plain dir). Writes a lease; rc 2 if the path resolves outside its root or `<purpose>` fails `^[a-z0-9-]{1,40}$`.

**Step 1:** `run_admit_contract "diskm scratch-new <repo> p --detach HEAD"`; detached path exists and `.git` is a file; lease kind `scratch`; `../x` → rc 2; `--kind evidence` creates the tmp dir with an evidence lease; `evidence-push` stub success sets `published_at`.
**Step 2:** Run. Expected: FAIL (`scratch_new.sh` missing; `admit.sh` exists from Task 3, so the failure is the intended one).
**Step 3:** Implement, reusing `wtn_main_repo` / `wtn_repo_name`. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: diskm scratch-new (detached worktrees, evidence dirs)`.

---

### Task 8: Prevention points before the pilot: hook, `/advice`, evidence producers (C6, §7.5)

**Files:** Create `hooks/disk-admission.sh` (PreToolUse Bash template). Test: `tests/test_disk_admission_hook.sh`.

**Step 1:** Hook JSON on stdin with a stub admit. For each form — `git worktree add ~/.worktrees/r/n`, `cd /repo && git clone url /private/tmp/r/x`, `git -C /repo worktree add ../n`, `FOO=1 git clone url /private/tmp/r/y`, `cp -R a ~/.worktrees/r/z` — rc 0 → allow; 10 → allow with a warning `systemMessage`; 75 → deny with reuse message; 76 → deny naming `retry_after_s`; 3 → allow + `admission_blind`. `ls` and destinations outside governed roots → allow without calling admit.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement the segment split, env strip, `cd`/`-C` tracking and literal match. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: disk admission PreToolUse hook template`.

**Outside this repo (D6, D2), each with its own test, all before Task 9 deploys:**
- Install the hook (`~/.claude/settings.json` PreToolUse Bash); verify one live deny/allow with a stub stage.
- `/advice` `~/.claude/skills/advice/scripts/run_primary_pair.py`: before `create_clone`, `diskm admit --class tmpdir_scratch --est-gb <2 × source size> --owner advice-<run>`; 0/10 proceed (10 logs), 75 stop with the admit message, 76 sleep `retry_after_s` once then stop, other rc proceed with a warning; release after clones exist. Keep `git clone --no-local`, origin removal and `shutil.rmtree` unchanged. Tests in `test_run_primary_pair.py` for all five outcomes.
- Evidence producers: `evidence-standards`, `ui-video-evidence`, `tmux-video-evidence` skill text creates bundle dirs with `diskm scratch-new <repo> <name> --kind evidence` and publishes with `diskm evidence-push`.

---

### Task 9: `diskm govern` observe tick with BLACK emergency (C1, C10)

**Files:** Create `scripts/govern.sh`, `launchd/com.jleechanorg.disk-magician-govern.plist.template`. Modify `scripts/disk_budget.py` (`tick`), `src/disk_magician/disk_magician.sh` (`govern`), `scripts/install_launchd_sweepers.sh` (add template; remove nothing), `scripts/job_inventory.py`. Test: `tests/test_govern.sh`.

**Interfaces:** `govern.sh [--mode observe|act] [--deadline-seconds 540]` takes `$STATE/govern.lock` (mkdir lock with pid; stale-pid takeover as in `worktree_reap.sh` `lock_dead`). `disk_budget.py tick --out budget.json`: (1) df → zone + `zone_at` atomically; if BLACK/FLOOR, run `$DISK_MAGICIAN_LAUNCHCTL_BIN kickstart gui/$UID/com.jleechanorg.disk-magician-pressure-sweep` once and record `govern_emergency`; (2) next du class, 60 s subprocess timeout, keep prior value and grow `stale_s` on timeout; (3) first tick after 03:00 local: each `df_delta_only` class du with 120 s timeout into `accounting_used_gb`, carry forward on timeout; (4) observer classes from `disk_observer.jsonl`; (5) atomic rewrite. Write error → previous file kept, exit 3.

**Step 1:** `DISK_MAGICIAN_STATE_DIR=$(mktemp -d)`, fake df, du stub, launchctl stub, stub actuators. Cases: zone before du (du sleeps 120 s, `zone_at` fresh); du timeout ×3 keeps zone fresh and grows `stale_s`, no `admission_blind`; round-robin across three classes; daily du runs once per day and carries forward on timeout; observe mode runs no actuator; overlapping tick (lock held by live pid) → `skipped_tick_lock`, no receipts; stale lock (dead pid) taken over; BLACK → kickstart called exactly once and zone written first; 5 GiB free → files valid; ENOSPC on a 2 MiB `hdiutil` APFS image (skip with reason off macOS) → exit 3, previous `budget.json` parseable.
**Step 2:** `bash tests/test_govern.sh`. Expected: FAIL (`govern.sh` missing).
**Step 3:** Implement; plist `StartInterval 600`, `diskm govern --mode observe`.
**Step 4:** `bash tests/test_govern.sh && bash scripts/sync_package_tree.sh --check && bash tests/test_install_launchd_sweepers_preflight.sh`. Expected: PASS; main-sweeper/pressure-sweep templates still installed.
**Step 5:** Commit `feat: diskm govern observe tick with BLACK emergency`.

---

### Task 10: Birth audit, detection only (C7)

**Files:** Create `scripts/birth_audit.sh`. Modify `scripts/govern.sh` (audit each tick), `scripts/worktree_reap.sh` (`adopt` at line 132 accepts `--kind`). Test: `tests/test_birth_audit.sh`.

**Step 1:** Unleased fixtures: `/private/tmp/<repo>/advice-src-x` (`DISK_MAGICIAN_TMP_ROOT`), `$TMPDIR/advice-primary-pair-abc` with a `.git`, `$TMPDIR/com.apple.foo` (foreign), `~/Documents/Codex/2026-10-11/task-1`. After one audit: three `scratch` leases, `bypass.tmp_containers.births == 1`, `bypass.tmpdir_scratch.births == 1`, bytes recorded (du stub; a hanging stub → `bytes_unknown`), `foreign == 1` and no lease on it; a second audit adds nothing; every fixture still exists. With `TMPDIR` unset, the root equals a stubbed `getconf DARWIN_USER_TEMP_DIR`.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement; producer prefixes from the fixed table only. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: birth audit adopts unleased governed artifacts (detection)`, bump, deploy.

**Pilot start.** When Tasks 3–10 are deployed and each has a scheduled receipt, record the pilot start time in `budget.json`; the 7-day pilot (spec §7.4) runs from there in `observe` with emergency rows per D2.

---

### Task 11: Liveness, coverage and trough alerts; weekly check (C12, §9)

**Files:** Modify `scripts/sweeper_health_check.sh`, `scripts/disk_status.py` (alerts first), `scripts/disk_budget.py` (`status --weekly-check`). Test: `tests/test_sweeper_health.sh`.

**Step 1:** Fixture receipts and observer lines; each prints `ALERT:<code>` before any accounting and exits 1: `govern_stale` (tick > 30 min), `admission_blind` (24 h), `admission_ledger_reset`, `class_stale` (> 10800 s), `actuator_dead` (3 non-positive deltas over budget **and** zero candidates removed; 3 non-positive deltas with removals reported → no alert), `actuator_starved` (deferred/timeout 3 ticks running), `bypass_high` (24 h births or bytes ≥ 10%), `colima_stopped` (> 1 h), `main_sweeper_error` (2 running), `trough_rise` (7-day trough > 15 GiB above 30-day), `parked_large` (> 20 GiB). `--weekly-check` with 90% observer coverage → `insufficient_data`, exit 1; full coverage and passing rows → exit 0.
**Step 2:** Run. Expected: FAIL on new cases.
**Step 3:** Implement; trough from `disk_observer.jsonl{,.1,.2}` `host_disk.used_kb` reusing `history_diff.py`'s parse.
**Step 4:** Re-run plus `bash tests/test_sweeper_health_dispatch.sh`. Expected: PASS.
**Step 5:** Commit `feat: governor liveness, coverage and trough alerts`.

---

### Task 12: `artifact_removal_verdict`, the one final check (C14)

**Files:** Create `scripts/lib/artifact_verdict.sh`. Modify `scripts/worktree_reap.sh` (remove path), `scripts/cleanup_worktrees.sh` (before each `git worktree remove`), `scripts/lib/scratch_budget.sh` (before each delete, next to the lsof recheck). Test: `tests/test_artifact_verdict.sh`, `tests/test_removal_sites.sh`.

**Interface:** `artifact_removal_verdict <path>` prints `remove` or `kept:<reason>`, rc 0; any internal failure → `kept:check-failed`. Branches per spec C14: registered linked worktree → `wrh_removal_verdict "$p" minutes:30 origin-or-merged-pr` plus the branch `wrh_remove_now` would delete is contained in a remote ref; standalone repo (any `.git` at or below the path, found with `find -name .git -prune`) → status/hidden/ignored checks and `git rev-list --all --not --remotes` empty, per nested repo; non-git → no live cwd, no open file (lsof), content mtime ≥ 60 min, no unpublished evidence lease. All kinds: `safety_check.sh` not protected; lease owner `unknown`/`unreadable` → kept.

**Step 1:** Fixture matrix, each expecting `kept:*`: dirty; untracked file; assume-unchanged entry; ignored `.env`; ignored `data/notes.db`; HEAD not on remote; nested clone inside a tmp container with an unpushed local tag; nested clone with a stash only; non-git dir with a background process holding a file open; a process with cwd inside; content 10 min old; evidence lease without `published_at`; lease owner `unknown` (ps stub fails). Each matching safe fixture → `remove`. Wiring: with a fixture C14 keeps (open file held), `worktree_reap.sh --mode remove`, `cleanup_worktrees.sh --clean` and `scratch_budget_evict_root` all leave it. **Race:** `DISK_MAGICIAN_TEST_AFTER_NOMINATE` writes an untracked file between nomination and removal → kept. **Lint:** `tests/test_removal_sites.sh` parses each of the four files and fails if a function containing `git worktree remove`, `wrh_remove_now` or the scratch delete lacks a preceding `artifact_removal_verdict` call.
Disposable-copy fixtures (spec §11), using an `advice-primary-pair-*` dir with a runner `receipt.json`:
- runner dead, 3h idle, no commits beyond the recorded SHA → `remove`
- an extra local commit → `kept:not-pushed`
- runner pid alive → `kept:live-owner`
- missing receipt → `kept:check-failed`
- an ignored `.env` outside `.advice-review-documents/` → `kept:hidden-state`
**Step 2:** Run. Expected: FAIL (helper missing; `cleanup_worktrees.sh` removes the open-file fixture).
**Step 3:** Implement and wire. **Step 4:** Run plus `bash tests/test_worktree_reap.sh && bash tests/test_cleanup_worktrees_merged_fastpath.sh && bash tests/test_scratch_budget.sh`. Expected: PASS.
**Step 5:** Commit `feat: artifact_removal_verdict gates every removal`.

---

### Task 13: Owner proof and session-exit release (C8, §7.3)

**Files:** Modify `scripts/worktree_reap.sh` (`verdict_for`: T1 eligible only for `lease_owner_state` `dead`/`released` + 30 min quiet; TTL-expired with owner alive → `kept:expired_owner_alive`), `scripts/lib/worktree_lease.sh` (`lease_release_owner_session <id> <runtime_pid> <runtime_start_epoch>`), `src/disk_magician/disk_magician.sh` (`lease-release --owner-session`). Create `hooks/session-end-lease-release.sh` (reads `session_id`, resolves the runtime pid via `lease_resolve_owner`). Test: `tests/test_worktree_reap.sh`, `tests/test_lease_release_session.sh`.

**Step 1:** Reap: live owner with TTL expired 30 h ago → kept; `SIGSTOP`ped owner → kept; lease pid alive with a different `start_epoch` (reuse) → dead → proceeds to C14; ps stub error → `unknown` → kept; owner dead but a child process with cwd inside → C14 keeps. Release: leases A (session S, owner = ending runtime), B (session S, other live pid), C (session T); releasing S marks only A, reports B as `release_skipped_live_owner`; unknown session → rc 0, no change; the released worktree still exists.
**Step 2:** Run. Expected: FAIL (current reaper treats TTL expiry + 6 h quiet as eligible). **Step 3:** Implement. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: owner death by pid+start epoch only; scoped session release`.

**Outside this repo (D6):** install the hook under SessionEnd and SubagentStop; one paragraph in `superpowers-using-git-worktrees`, `draft-first-pr`, `evidence-standards`: create via `diskm worktree-new`/`scratch-new`, `git push -u origin HEAD` before exit (never force), `diskm evidence-push`.

---

### Task 14: `CLAUDE.md` amendment, then the first T1 removal (D1)

**Precondition:** D1 recorded through Task 2; Tasks 12 and 13 deployed.
**Step 1:** PR amending `CLAUDE.md` "Worktree 7-day rule" with the spec §7.3 T1 text, quoting D1 verbatim; merge under the merge gate.
**Step 2:** After merge, `diskm worktree-reap --mode remove --deadline-seconds 1500`. Record the receipt `df_delta_bytes` and the `kept:*` histogram.
**Step 3:** `df -k`; report the delta. No remove-mode receipt may predate the amendment's merge commit time (checked in review).

---

### Task 15: Govern act mode per class with a fair scheduler (C9, C10)

**Precondition:** #150, #151, #152 deployed; Task 12 deployed.

**Files:** Modify `scripts/govern.sh` (per-class `act`: `always` or a decision id; worktrees actuator runs `worktree_reap.sh --mode remove` only with `worktree_reap_remove`, else `--mode nominate`; `cleanup_worktrees.sh --clean` only with `worktree_cleanup`; scheduler per spec C10 with `$STATE/govern_sched.json` holding `last_ran_at` and `deferred_ticks`), `scripts/worktree_reap.sh` (append kept items to `$STATE/parked.jsonl` with sizes), govern template (`--mode act`). Test: `tests/test_govern.sh`, `tests/test_worktree_reap.sh`.

**Step 1:** Cases: no decisions, over-budget tmp_containers, codex_documents (RED), colima → those run; worktrees nominate; `cleanup_worktrees.sh` not invoked. `worktree_cleanup` approved → invoked under its own lock. Actuator lock held → `skipped_lock`, next still runs. Three actuators each sleeping 400 s → each killed at its 180 s slice with a `timeout` receipt. Ten slow actuators → nine run at 60 s, the tenth `deferred`, and runs first next tick (all ten within 2 ticks). Zone RED → BLACK between ticks → BLACK order by 7-day df delta, except an actuator deferred 3 ticks runs first. Owner-null clean pushed worktree idle 25 h → `parked.jsonl`. Every `govern_<class>` receipt has non-null `df_delta_bytes`.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement.
**Step 4:** `bash tests/test_govern.sh && bash tests/test_worktree_reap.sh && bash tests/test_worktree_reap_dispatch.sh`. Expected: PASS.
**Step 5:** Commit `feat: govern act mode with time-sliced rotating scheduler`, deploy, check next-morning df and `govern_*` receipts.

---

### Task 16: Reuse-first worktree-new (C5) and CI admission (C13)

**Files:** Modify `scripts/worktree_new.sh` (`wtn_main`): before `wtn_create`, pick a candidate (same repo, owner `dead`/`released`, `worktree_is_recently_active_minutes 120` false), claim it with `lease_write_pending` (fails if another claimant holds it), re-run `artifact_removal_verdict`, then resolve the old local branch: delete with `git branch -d` after switching away only if merged into `origin/main` or its tip equals the live `git ls-remote` tip; otherwise drop the claim and create fresh. Then `git switch --detach`, `git switch -c <branch> <base>`, rewrite the lease. Any git failure between steps restores the claim to the previous owner state and creates fresh. Add `scripts/ci_admit.sh` (ezgha pre-job: `diskm admit --class colima --est-gb 20` under the contract; prints `launchctl bootout gui/$UID/<ezgha label>` in RED/BLACK; auto-pause only with `decision_approved ci_autopause`). Test: `tests/test_worktree_new.sh`, `tests/test_ci_admit.sh`.

**Step 1:** Reuse positive with a merged old branch → recycled, old branch gone, no new dir. Old branch with an unpushed commit → fresh dir, old branch and worktree intact. Untracked file → fresh, file intact (no `git clean`). Ignored `.env` and `data/notes.db` → fresh. Live cwd → fresh. Two concurrent `worktree-new` calls → one recycles, the other creates fresh. Dirtied between claim and switch → fresh. CI: `run_admit_contract "bash scripts/ci_admit.sh"`.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run. Expected: PASS.
**Step 5:** Commits `feat: reuse-first worktree-new` and `feat: CI admission check`.

---

## Sequencing (prevention before pilot, policy before T1)

| Order | Tasks | PR | Gated on | Measurable effect |
|---|---|---|---|---|
| 0 | Task 0 | merges of #150–#153 (ops) | merge gate | df next morning |
| 1 | Tasks 1, 2 | PR-A (receipts), PR-B (policy) | none | decisions recordable |
| 2 | Tasks 3, 4, 5 | PR-C (admit), PR-D (reservations), PR-E (worktree-new) | D2 for non-zero rc | reserved bytes, refusals |
| 3 | Tasks 6, 7, 8 | PR-F (kind + scratch-new), PR-G (hook) + external PRs | D6 | prevention coverage |
| 4 | Tasks 9, 10 | PR-H (govern observe), PR-I (audit) | none | **pilot starts** when 3–10 are live |
| 5 | Task 11 | PR-J (alerts) | none | alerts first in status |
| 6 | Tasks 12, 13 | PR-K (C14), PR-L (owner proof + release) | #152 deployed | safe removal path |
| 7 | Task 14 | PR-M (`CLAUDE.md`) + ops | D1 | first T1 df delta |
| 8 | Task 15 | PR-N (act + scheduler) | #150–#152; D1b for T3 | class stock, df trough |
| 9 | Task 16 | PR-O | D4 for auto-pause | births/day, CI burst depth |

**Pilot gate.** Enforcement stays `observe` (emergency rows active with D2) for 7 days from the pilot start, then `warn`. `refuse_red` requires D3 recorded with pilot-measured budgets satisfying spec §7.4 (max-swing `W` × 1.25) and the §7.5 bypass SLO; `refuse_orange` follows 7 days later. Each stage change is a config edit recorded with `diskm policy approve admission_enforcement`.

## Verification after each deploy

1. `diskm status --json`: no `ALERT:` lines first; if any appear, report them first.
2. `~/.disk_magician_state/receipts/govern_*.json`: last entry < 15 min old with non-null `df_delta_bytes` and progress (not only `skipped_*`); `budget.json` `zone_at` < 15 min old.
3. The govern, main-sweeper and pressure-sweep jobs each have a receipt newer than their interval (loaded is not enough).
4. `diskm budget status` shows reserved bytes consistent with `reservations.json`.
5. Weekly: `diskm budget status --weekly-check`. Close the workstream bead after two consecutive passes.
