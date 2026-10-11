# Disk-Fill Durable Control Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the disk-use loop with a `diskm` budget governor: df-zone admission at creation, owner-lifecycle reclaim, and df-verified receipts. Success is spec §9: 7-day minimum free ≥ 30 GiB, zero samples under 15 GiB free, and a daily used trough ≤ 790 GiB, on two consecutive weekly checks.

**Architecture:**
- A 10-minute `diskm govern` tick writes the df zone to `budget.json` first, then measures one du class (round-robin), runs the birth audit, and runs actuators for classes in act mode. Each actuator writes a receipt with `df_delta_bytes`.
- `diskm admit` runs its own `df` for the zone and reads only class overage from `budget.json`.
- `main_sweeper` and `pressure-sweep` stay installed and unchanged.
- Leases (PR #148, on main) gain a `kind` and are released at session exit. Removal goes only through `wrh_removal_verdict` / `wrh_remove_now`.

**Tech Stack:** Bash (scripts/, scripts/lib/), Python 3 stdlib, launchd templates, shell tests under `tests/`, unittest/pytest for Python.

**Spec:** `docs/superpowers/specs/2026-10-11-disk-fill-durable-control-design.md`
**Base:** origin/main `688fff6`, version 0.2.197. Usable capacity about 895 GiB (df used + avail).

---

## Global Constraints

- **Entry point.** Every operation is a `diskm` subcommand in `src/disk_magician/disk_magician.sh`; mirror with `scripts/sync_package_tree.sh` and check with `--check` in review.
- **Removal path.** Worktrees only via `wrh_removal_verdict` / `wrh_remove_now` (`scripts/worktree_remove_hook.sh`); scratch only via `scratch_budget_evict_root`. No ad-hoc `rm`. Never touch never-delete paths.
- **Recency** only through `scripts/lib/worktree_recency.sh`, fail closed, with a test that the unmeasurable case is protected.
- **Unknowns.** Unknown owner = alive = keep. Unknown class measurement = drop that class's overage term only. df failure = admission fails open with an `admission_blind` receipt.
- **Existing jobs.** Do not uninstall or modify the schedule of `main_sweeper` or `pressure-sweep`. The governor takes each actuator's existing lock and records `skipped_lock` when it is held.
- **ZFC.** Class membership comes from the fixed governed-root table; the hook matches literal syntax. No keyword scoring.
- **Plists.** Never `plutil -extract` without `-o -`. Templates use `@HOME@` / `@REPO_ROOT@` via `scripts/install_launchd_sweepers.sh`.
- **Deploy.** Each merged PR bumps `pyproject.toml` and runs `tools/deploy_uv_tool.sh` from clean origin/main; verify `deployed.json` and one scheduled receipt before calling it live.
- **PR size.** At most 150 production lines per PR, or the size-tiered merge gate.
- **Approvals.** No task sets `WORKTREE_APPROVED`, writes `worktree_reap.remove_approved`, or records a standing decision on the user's behalf. Each is written only **after** the user's literal approval phrase appears in a live user message, and the phrase is recorded verbatim.

## Review Focus

1. **No existing cleanup stops.** main_sweeper (snapshot_commit, tiers, health) and pressure-sweep plists are unchanged; tmp/colima/codex actuators run in govern act mode without D1.
2. **Admission cannot go blind on du.** The zone comes from df on every tick and every admit call; a du timeout only ages one class.
3. **Every removal path is gated** through `wrh_removal_verdict` and byte-verified removal. No owner-null 24 h tier exists.
4. **`diskm admit` never runs du and never blocks when df fails.** Exit codes 0, 10, 75, 76.
5. **Receipts stay backward-compatible.** Old receipts without `df_delta_bytes` validate; `govern_*` receipts require it.
6. **Standing decisions** have no expiry field, revoke works, phrase recorded verbatim.
7. **Disk-full behaviour.** A tick at about 5 GiB free writes `budget.json` and receipts; ENOSPC keeps the previous file.

## TDD Plan Check

| Task | RED test (fails before change) | GREEN condition | Layer |
|---|---|---|---|
| 0 | n/a (operations with existing code and open PRs) | df free next morning ≥ today + 40 GiB, per-step df deltas recorded | live df |
| 1 | `tests/test_job_receipt.py::TestDfDelta::test_finish_records_df_delta` | `df_delta_bytes = free_bytes_after − free_bytes_before`; `govern_*` with missing delta → `error`/`null_df_delta` | unit |
| 2 | `tests/test_govern.sh` "zone written before du", "du timeout keeps zone fresh", "5 GiB free stress", "ENOSPC keeps previous budget.json" | zone fresh each tick; class `stale_s` grows; state and receipts written at 5 GiB free | shell integration |
| 3 | `tests/test_sweeper_health.sh` new alert cases | each `ALERT:<code>` printed first, exit 1 | shell integration |
| 4 | `tests/test_worktree_lease.sh` "kind round-trips" | `kind` present, default `worktree` | unit (shell) |
| 5 | `tests/test_scratch_new.sh` "detach shares objects; refuses outside root" | detached entry, `.git` is a file, rc 2 outside root | shell integration |
| 6 | `tests/test_disk_budget.py` policy table + `tests/test_admit.sh` "du stub hangs, admit still refuses in RED" | rc per zone/overage; stale class drops overage only; df failure → 0 + `admission_blind` | unit + shell |
| 7 | `tests/test_worktree_new.sh` "wtn_admit delegates" | rc 75 in RED under `refuse_red`; GREEN creates | shell |
| 8 | `tests/test_policy.sh` | approve/revoke/no-expiry; reaper remove gate accepts decision | shell |
| 9 | `tests/test_govern.sh` "per-class act mode" + `tests/test_worktree_reap.sh` "owner-null young kept" | tmp/colima/codex act without D1; worktrees nominate without D1; T3 runs only with D1b; owner-null < 3 d → parked | shell integration |
| 10 | `tests/test_lease_release_session.sh` | only that session's leases released | shell |
| 11 | `tests/test_birth_audit.sh` incl. `$TMPDIR/advice-primary-pair-*` | adopted once, `bypass` increments, no double count | shell |
| 12 | `tests/test_disk_admission_hook.sh` incl. `cd x && git clone`, `git -C r worktree add`, `FOO=1 git clone` | deny on rc 75 for each form; allow otherwise | shell |
| 13 | `tests/test_worktree_new.sh` "reuse-first" + negatives incl. ignored `.env` and non-rebuildable ignored file | lease transferred, no new dir; each negative creates fresh | shell integration |

## Dependencies on in-flight work (do not duplicate)

| Item | Status (verified 2026-10-11 22:1xZ) | Relationship |
|---|---|---|
| PR #148: leases, reaper, `wtn_admit` | merged 10-11T13:01Z, deployed | Base for Tasks 4, 7, 9, 10, 11, 13. Read the code (`scripts/lib/worktree_lease.sh`, `scripts/worktree_reap.sh`, `scripts/worktree_new.sh:179-201`, `scripts/worktree_remove_hook.sh`); the 10-10 lease design doc is not on origin. Owner-exit thresholds are in bead `7u9t` |
| PR #149: pressure-sweep tmp within budget | merged | Unchanged; pressure-sweep keeps running |
| PR #150: Colima stopped-VM guard + stale lima lock | open | Merge and deploy before Task 9 enables the colima actuator; Task 3 `colima_stopped` alert and D8 self-heal reuse it |
| PR #151: `diskm cleanup-codex-documents` | open | Merge and deploy before Task 9 enables `codex_documents` |
| PR #152: `cleanup_tmp.sh` descends into active tmp containers under `--large` | open | Changes the `tmp_containers` actuator; merge and deploy before Task 2's actuator stubs are frozen and before Task 9 |
| PR #153: hygiene reuses rebuildable-ignored allowlist | open | Task 13 and spec §7.3 use the same allowlist (`scripts/lib/worktree_ignored.sh`) |
| Bead `7u9t` | open, needs user | D1 |
| Beads `oyt4`, `67xj`, `i2o`, `d45` | open | Closed by Tasks 9/10, PR #150, Task 9 (tmp actuator), Task 11 |

---

### Task 0: Stage 0. Same-day floor drop with existing machinery (no code)

**Preconditions.** Merges follow the size-tiered merge gate (`/green` + `/advice`, or the user's merge approval). The reap step needs D1: write `~/.disk_magician_state/worktree_reap.remove_approved` and the bead `7u9t` comment **only after** the user's literal approval phrase, quoting it. Without D1, skip step 2.

**Step 1: Baseline.** `df -k /System/Volumes/Data` and `./disk_magician.sh check-launchd-fleet`. Record `available_kb` and fleet status; report an unhealthy fleet first.
**Step 2 (D1 only): Reap.** `diskm worktree-reap --mode remove --deadline-seconds 1500`. Record the receipt `df_delta_bytes`.
**Step 3: Land actuator fixes.** Merge and deploy #150, #151, #152, #153 (one version bump per merge). Between CI jobs, `colima stop && colima start` then `colima ssh -- sudo fstrim -av`. Run `diskm cleanup-codex-documents --clean`.
**Step 4: Verify.** Re-run `df -k`; report each step's df delta, not du.

Expected: about 40–70 GiB with D1, plus the Colima trim. The success test is df free the next morning.

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
**Step 3:** In `finish`, if the postcondition lacks `df_delta_bytes` and both `free_bytes_before` (precondition or postcondition) and `free_bytes_after` are integers, set `df_delta_bytes = after − before`. For job names starting `govern_`, a still-missing delta forces `outcome="error"`, `reason="null_df_delta"`. Reuse the keys `worktree_reap.sh` writes; add no new key names.
**Step 4:** Run the whole `tests/test_job_receipt.py`. Expected: PASS.
**Step 5:** Commit `feat: receipts derive df_delta_bytes; governor receipts require it`.

---

### Task 2: `diskm govern` observe mode, zone-first `budget.json` (C1, C10)

**Files:**
- Create: `scripts/govern.sh`, `scripts/disk_budget.py`, `scripts/lib/disk_budget.sh`, `launchd/com.jleechanorg.disk-magician-govern.plist.template`
- Modify: `src/disk_magician/config.json.template` (`budgets` block with the spec §7.2 class table), `src/disk_magician/disk_magician.sh` (`govern` and `budget` cases next to `worktree-reap`), `scripts/install_launchd_sweepers.sh` (add the govern template; remove nothing), `scripts/job_inventory.py`
- Test: `tests/test_govern.sh`, `tests/test_disk_budget.py`

**Interfaces:**
- `disk_budget.py zone --free-gb N` → `GREEN|ORANGE|RED|BLACK`.
- `disk_budget.py tick --out <budget.json>`: (1) df → write zone + `zone_at` atomically; (2) next class in round-robin with `measure: du` → `timeout 60 du -skx`, on timeout keep prior `used_gb` and increase `stale_s`; (3) `measure: observer` classes read the latest `disk_observer.jsonl` line (`colima.root_allocated_kb`); (4) rewrite atomically.
- `scripts/lib/disk_budget.sh`: `budget_get <class> used_gb|budget_gb|stale_s`, `budget_zone`.
- `govern.sh [--mode observe|act] [--deadline-seconds 540]`; in observe mode no actuator runs.
- Atomic write = temp file in the same directory + `os.replace`; on any write error the previous file stays and the tick exits 3 with one stderr line (the tick log captures it).

**Step 1:** Write `tests/test_govern.sh` with `DISK_MAGICIAN_STATE_DIR=$(mktemp -d)`, `DISK_MAGICIAN_DF_BIN` (fake df), `DISK_MAGICIAN_DU_BIN` (stub), `DISK_MAGICIAN_GOVERN_ACTUATOR_DIR` (stub actuators). Cases:
- **zone before du:** du stub sleeps 120 s; after the tick `zone_at` is fresh and `zone` matches the fake df.
- **du timeout keeps zone fresh:** three ticks with a hanging du stub; zone fresh each time; that class's `stale_s` grows; no `admission_blind` receipt.
- **round-robin:** three ticks measure three different du classes.
- **observe mode:** no actuator invoked.
- **5 GiB free stress:** fake df reports 5 GiB free (BLACK); `budget.json` and the tick receipt are written and valid.
- **ENOSPC:** `DISK_MAGICIAN_STATE_DIR` on a 2 MiB `hdiutil create -size 2m -fs APFS` image filled to under 4 KiB free (skip with a printed reason off macOS); the tick exits 3 and the previous `budget.json` is unchanged and parseable.

**Step 2:** `bash tests/test_govern.sh`. Expected: FAIL (`govern.sh` missing).
**Step 3:** Implement the minimum; plist `StartInterval 600`, `diskm govern --mode observe`.
**Step 4:** `bash tests/test_govern.sh && python3 -m pytest tests/test_disk_budget.py -v && bash scripts/sync_package_tree.sh --check && bash tests/test_install_launchd_sweepers_preflight.sh`. Expected: PASS, and main-sweeper/pressure-sweep templates still installed.
**Step 5:** Commit `feat: diskm govern observe tick with zone-first budget.json`, bump, deploy. This starts the **pilot week** (spec §7.4).

---

### Task 3: Liveness and trough alerts (C12)

**Files:** Modify `scripts/sweeper_health_check.sh`, `scripts/disk_status.py` (alerts first). Test: `tests/test_sweeper_health.sh`.

**Step 1:** Add failing cases with fixture receipts and observer lines; each must print `ALERT:<code>` before any accounting and exit 1:

| Code | Fixture |
|---|---|
| `govern_stale` | last `govern` tick older than 30 min |
| `admission_blind` | `admission_blind` receipt in the last 24 h |
| `class_stale` | a class `stale_s` > 10800 |
| `actuator_dead` | 3 consecutive `govern_<class>` receipts with `df_delta_bytes` ≤ 0 while over budget |
| `colima_stopped` | `colima status` stub stopped for > 1 h |
| `main_sweeper_error` | 2 consecutive `main_sweeper` error receipts |
| `trough_rise` | 7-day daily-min trough > 15 GiB above the 30-day trough |
| `parked_large` | parked set > 20 GiB |

**Step 2:** `bash tests/test_sweeper_health.sh`. Expected: FAIL on the new cases.
**Step 3:** Implement; trough from `disk_observer.jsonl{,.1,.2}` `host_disk.used_kb`, reusing `history_diff.py`'s observer-fallback parse.
**Step 4:** Re-run plus `bash tests/test_sweeper_health_dispatch.sh`. Expected: PASS.
**Step 5:** Commit `feat: governor liveness and trough-rise alerts`.

---

### Task 4: Lease kinds (C3, part 1)

**Files:** Modify `scripts/lib/worktree_lease.sh` (`lease_write` line 170, `_lease_emit_json` line 206). Test: `tests/test_worktree_lease.sh`.

**Step 1:** Test that `lease_write <path> --kind scratch` yields `"kind":"scratch"`; no `--kind` and pre-existing leases read as `worktree`; `--kind bogus` → rc 2.
**Step 2:** Run. Expected: FAIL.
**Step 3:** Add optional `--kind` (`worktree|clone|scratch|evidence`) and `--published`.
**Step 4:** `bash tests/test_worktree_lease.sh`. Expected: PASS.
**Step 5:** Commit `feat: lease kind field`.

---

### Task 5: `diskm scratch-new --detach` (C3, part 2)

**Files:** Create `scripts/scratch_new.sh`. Modify `src/disk_magician/disk_magician.sh`, `scripts/evidence_push.sh` (`lease_write --published` on success). Test: `tests/test_scratch_new.sh`.

**Interface:** `diskm scratch-new <repo-path> <purpose> [--kind scratch|evidence] [--detach <sha>]` prints the path; calls `diskm admit --class worktrees --est-gb 1` first (propagates 75/76); `--detach` runs `git -C <repo> worktree add --detach ~/.worktrees/<repo>/scratch-<purpose>-<UTC ts> <sha>`; writes a lease; rc 2 if the path resolves outside `~/.worktrees/<repo>/` or `<purpose>` fails `^[a-z0-9-]{1,40}$`.

**Step 1:** Test against a temp repo with `HOME` overridden: path exists and `.git` is a file; lease kind `scratch`; `../x` → rc 2.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement, reusing `wtn_main_repo` / `wtn_repo_name`. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: diskm scratch-new with detached worktrees`.

---

### Task 6: `diskm admit` and `diskm budget status` (C1, C2)

**Files:** Create `scripts/admit.sh`. Modify `scripts/disk_budget.py` (`admit`, `status`), `src/disk_magician/disk_magician.sh`. Test: `tests/test_disk_budget.py`, `tests/test_admit.sh`.

**Policy table** (stage from `budgets.enforcement`: `observe|warn|refuse_red|refuse_orange`, default `observe`; zone from a live `df` call):

| Zone | Class over budget (fresh ≤ 3 h) | observe | warn | refuse_red | refuse_orange |
|---|---|---|---|---|---|
| GREEN | any | 0 | 0 | 0 | 0 |
| ORANGE | no, or class stale / df_delta_only | 0 | 10 | 10 | 10 |
| ORANGE | yes | 0 | 10 | 10 | 75 |
| RED | any | 0 | 10 | 75 | 75 |
| BLACK | any | 0 | 10 | 76 (`retry_after_s=600`) | 76 |
| df fails | n/a | 0 + `admission_blind` receipt | same | same | same |

`budget.json` missing or stale affects only the overage column.

**Step 1:** Parametrized pytest over the full table. Shell tests: (a) `diskm admit --class worktrees --est-gb 1` under 200 ms with a `DISK_MAGICIAN_DU_BIN` stub that fails if invoked; (b) **du timeouts do not blind admission:** `budget.json` 2 h old with every class stale, fake df in RED, stage `refuse_red` → rc 75 and no `admission_blind` receipt; (c) fake df exits 1 → rc 0 plus `admission_blind`.
**Step 2:** Run. Expected: FAIL.
**Step 3:** Implement. `budget status` prints zone, per-class used/budget/stale age, birth rate, parked total and alert lines. `--weekly-check` evaluates exactly the six spec §9 rows and exits 0 only if all pass.
**Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: diskm admit (df zone) and budget status`.

---

### Task 7: `wtn_admit` delegates to `diskm admit`

**Files:** Modify `scripts/worktree_new.sh:179-201`. Test: `tests/test_worktree_new.sh`.

**Step 1:** Fake df in RED, stage `refuse_red`: `diskm worktree-new` exits 75 with the existing reuse message; GREEN creates.
**Step 2:** Run. Expected: FAIL in RED (old gate refuses only below `WORKTREE_ADMIT_MIN_GB=10`).
**Step 3:** `wtn_admit` calls `bash "$SCRIPT_DIR/admit.sh" --class worktrees --est-gb 1`; keep the env thresholds only as the fallback when `admit.sh` is missing.
**Step 4:** `bash tests/test_worktree_new.sh`. Expected: PASS.
**Step 5:** Commit `refactor: worktree-new admission via diskm admit`.

---

### Task 8: Standing-decision record (C11)

**Files:** Create `scripts/policy.sh`. Modify `scripts/safety_lib.sh` (`decision_approved <id>`), `src/disk_magician/disk_magician.sh` (`policy`), `scripts/worktree_reap.sh:98` (decision `worktree_reap_remove` is an alternative to the marker file), `scripts/main_sweeper.sh:376,389` and `scripts/worktree_hygiene.sh` (decision `worktree_cleanup` as an alternative to `WORKTREE_APPROVED=1`), `scripts/cleanup_claude_state.sh` (decision `claude_state_cleanup`). Test: `tests/test_policy.sh`.

**Interface:** `diskm policy approve <id> --phrase '<text>'` writes `{id, phrase, approved_at, approved_by:"user", revoked_at:null}` atomically to `~/.config/disk-magician/standing_decisions.json` (override `DISK_MAGICIAN_POLICY_FILE`); `revoke <id>`; `list`. Fixed ids: `worktree_reap_remove` (D1), `worktree_cleanup` (D1b), `admission_enforcement` (D2), `budgets` (D3), `ci_autopause` (D4), `colima_selfheal` (D8), `claude_state_cleanup`.

**Step 1:** Tests: unknown id → rc 2; empty phrase → rc 2; approve → `decision_approved` 0; revoke → 1; no expiry field; reaper remove mode with the decision and no marker passes line 98; main_sweeper Tier 6 runs `cleanup_worktrees.sh --clean` with `worktree_cleanup` approved and skips without it.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement.
**Step 4:** `bash tests/test_policy.sh && bash tests/test_worktree_reap.sh && bash tests/test_main_sweeper.sh`. Expected: PASS.
**Step 5:** Commit `feat: diskm policy standing decisions (revocable, no expiry)`. The decisions themselves are recorded only by the user's phrase (Global Constraints).

---

### Task 9: Govern act mode per class, T3 activation, parked set, CLAUDE.md (C9, C10)

**Precondition:** #150, #151, #152 merged and deployed; Task 8 merged.

**Files:**
- Modify: `scripts/govern.sh` (per-class `act` from config: `always`, or a decision id; worktrees actuator runs `worktree_reap.sh --mode remove` only with `worktree_reap_remove`, otherwise `--mode nominate`; runs `cleanup_worktrees.sh --clean` only with `worktree_cleanup`), `scripts/worktree_reap.sh` (append kept items to `$STATE/parked.jsonl` with sizes; owner-null worktrees are **not** removed by the reaper), launchd govern template (`--mode act`), `CLAUDE.md` (T1 owner-exit exception text from spec §7.3, quoting D1)
- Test: `tests/test_govern.sh`, `tests/test_worktree_reap.sh`

**Step 1:** Failing cases:
- No decisions recorded, act mode, over-budget tmp_containers, codex_documents (RED), colima → those actuators run; worktrees actuator runs in nominate mode; `cleanup_worktrees.sh` not invoked.
- `worktree_cleanup` approved → `cleanup_worktrees.sh --clean` invoked under its own lock.
- Actuator lock held → `skipped_lock` receipt, next actuator still runs.
- Owner-null, clean, pushed worktree idle 25 h → `kept:*`, listed in `parked.jsonl` (no T2).
- Each `govern_<class>` receipt has non-null `df_delta_bytes`.

**Step 2:** Run. Expected: FAIL. **Step 3:** Implement; reuse `verdict_for` unchanged.
**Step 4:** `bash tests/test_govern.sh && bash tests/test_worktree_reap.sh && bash tests/test_worktree_reap_dispatch.sh && bash tests/test_cleanup_worktrees_merged_fastpath.sh`. Expected: PASS.
**Step 5:** Commit `feat: govern act mode per class and parked set`, deploy, and check next-morning df and `govern_*` receipts. The `CLAUDE.md` edit ships in this PR only if D1 is recorded; otherwise the worktrees class stays nominate and the edit waits for D1.

---

### Task 10: Session-exit lease release (C8)

**Files:** Modify `scripts/lib/worktree_lease.sh` (`lease_release_owner_session <id>` iterating `lease_dir`, calling `lease_release` where `owner.session == id`), `src/disk_magician/disk_magician.sh` (`lease-release --owner-session`). Create `hooks/session-end-lease-release.sh` (template; reads `session_id` from hook JSON). Test: `tests/test_lease_release_session.sh`.

**Step 1:** Two leases (sessions A, B); releasing A marks only A; unknown session → rc 0, no change.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: session-exit lease release`.

**Outside this repo (D6):** install the hook under SessionEnd and SubagentStop in `~/.claude/settings.json`; one paragraph in `superpowers-using-git-worktrees`, `draft-first-pr`, `evidence-standards`: create via `diskm worktree-new`/`scratch-new`, `git push -u origin HEAD` before exit (never force), `diskm evidence-push`.

---

### Task 11: Birth audit and adoption, including `$TMPDIR` (C7)

**Files:** Create `scripts/birth_audit.sh`. Modify `scripts/govern.sh` (audit each tick), `scripts/worktree_reap.sh` (`adopt` at line 132 accepts `--kind`). Test: `tests/test_birth_audit.sh`.

**Step 1:** Fixtures without leases: `/private/tmp/<repo>/advice-src-x` (via `DISK_MAGICIAN_TMP_ROOT`), `$TMPDIR/advice-primary-pair-abc` (via `DISK_MAGICIAN_USER_TMPDIR`), `~/Documents/Codex/2026-10-11/task-1`. After one audit each has a `scratch` lease, `bypass.tmp_containers == 1`, `bypass.tmpdir_scratch == 1`; a second audit does not double-count.
**Step 2:** Run. Expected: FAIL. **Step 3:** Implement; resolve `$TMPDIR` via `getconf DARWIN_USER_TEMP_DIR`. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: birth audit adopts unleased governed artifacts incl. TMPDIR`.

---

### Task 12: Admission hook (C6), `/advice` admission, narrow conversions (C4)

**Files:** Create `hooks/disk-admission.sh` (PreToolUse Bash template). Test: `tests/test_disk_admission_hook.sh`.

**Step 1:** Feed hook JSON on stdin with a stub `diskm admit` rc:
- rc 75 → deny with reuse message for each of: `git worktree add ~/.worktrees/r/n`, `cd /repo && git clone url /private/tmp/r/x`, `git -C /repo worktree add ../n` (resolved against `-C`), `FOO=1 git clone url /private/tmp/r/y`, `cp -R a ~/.worktrees/r/z`.
- Same commands with rc 0 → allow. `ls` → allow without calling admit. Destination outside governed roots → allow without calling admit.

**Step 2:** Run. Expected: FAIL. **Step 3:** Implement the segment split, env-assignment strip, `cd`/`-C` base tracking and literal match from spec C6. Forms it still misses (subshells, `eval`, scripts) are covered by the birth audit, not the hook. **Step 4:** Run. Expected: PASS.
**Step 5:** Commit `feat: disk admission PreToolUse hook template`.

**Outside this repo (D6, D2):**
- Install the hook in observe stage.
- `/advice` `run_primary_pair.py`: before `create_clone`, call `diskm admit --class tmpdir_scratch --est-gb <2 × source size>`; on 75 stop with the admit message; on 76 sleep `retry_after_s` once then stop. Keep `git clone --no-local`, origin removal and `shutil.rmtree` exactly as they are. Test in `test_run_primary_pair.py` with a stub admit.
- Convert gate-prep and split-gates to `diskm scratch-new --detach <sha>` only if Task 11's adoption counts show their clones survive runs, they run no full-permission agent in the checkout, and they write outputs outside it. Release via `diskm worktree-release`.

---

### Task 13: Reuse-first worktree-new (C5) and CI admission (C13)

**Files:**
- Modify `scripts/worktree_new.sh` (`wtn_main`): before `wtn_create`, find a recyclable worktree meeting every spec C5 condition (owner dead/released via `lease_owner_state`; clean incl. untracked; no assume-unchanged/skip-worktree; no ignored secret-like file and no non-rebuildable ignored data via `scripts/lib/worktree_ignored.sh`; HEAD on origin; `worktree_is_recently_active_minutes 120` false; no `wrh_live_cwd_reason`; not locked; not AO). Then `git switch --detach`, `git switch -c <branch> <base>`, rewrite the lease.
- Add `scripts/ci_admit.sh`: ezgha pre-job hook calls `diskm admit --class ci --est-gb 20`; in RED/BLACK the governor prints `launchctl bootout gui/$UID/<ezgha label>`; auto-pause only with `decision_approved ci_autopause`.
- Test: `tests/test_worktree_new.sh` (reuse positive; negatives: dirty, untracked, ahead, live cwd, ignored `.env`, ignored non-rebuildable file such as `data/notes.db`).

Steps 1–5 in RED/GREEN form. Commits `feat: reuse-first worktree-new` and `feat: CI admission check`.

---

## Sequencing (fastest measurable floor drop first)

| Order | Tasks | PR | Gated on | Measurable effect |
|---|---|---|---|---|
| 0 | Task 0 | merges of #150–#153 (ops) | D1 for the reap; merge gate | df next morning |
| 1 | Tasks 1, 2, 3 | PR-A (receipts + govern observe), PR-B (alerts) | none | pilot week starts; everything measurable |
| 2 | Tasks 6, 7, 8 | PR-C (admit), PR-D (policy) | none to ship; D2 for stages | births/day in RED |
| 3 | Task 9 | PR-E (act mode) | #150–#152 deployed; D1/D1b for worktree removal only | class stock, df trough |
| 4 | Tasks 4, 5, 10, 11, 12 | PR-F (lease kind + scratch-new), PR-G (release + audit), PR-H (hook), external PRs | D5, D6 | bypass %, `$TMPDIR` stock |
| 5 | Task 13 | PR-I | D4 for auto-pause | births/day, CI burst depth |

**Pilot gate.** Enforcement stays `observe` for the 7-day pilot that Task 2 starts, then `warn`. `refuse_red` requires D3 recorded with pilot-measured budgets satisfying spec §7.4; `refuse_orange` follows 7 days later. Each stage change is a config edit recorded with `diskm policy approve admission_enforcement`.

## Verification after each deploy

1. `diskm status --json`: no `ALERT:` lines first; if any appear, report them first.
2. `~/.disk_magician_state/receipts/govern_*.json`: last entry < 15 min old with non-null `df_delta_bytes`; `budget.json` `zone_at` < 15 min old.
3. `launchctl list | grep -E 'main-sweeper|pressure-sweep|govern'` shows all three loaded.
4. Weekly: `diskm budget status --weekly-check`. Close the workstream bead after two consecutive passes.
