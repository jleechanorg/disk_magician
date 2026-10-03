# Snapshot Timeout Reliability: Implementation Plan

Spec: `docs/superpowers/specs/2026-10-03-snapshot-timeout-reliability-design.md`. TDD order: each task's RED commit (failing tests only) precedes its implementation commit. Commits under 300 LOC, separate test and code commits. Python 3 via `python3`; bash tests via `bash tests/<file>.sh`; pytest via `python3 -m pytest tests/<file>.py -q`.

Setup (before Task 1): `git fetch origin` (when an `origin` remote exists) `&& git worktree add ../dm-snapshot-reliability -b snapshot-timeout-reliability origin/main`; `git log origin/main -3 -- pyproject.toml`; record the highest `version` across `origin/main` and open PRs (`gh pr list --json number,title`; #77/#80/#81/#84/#85/#86/#87/#89 use 0.2.120-0.2.122 and some touch `disk_snapshot.sh`; #80 is the likely conflict, so rebase onto it or origin/main at Task 6). Work only in the new worktree; the main tree has unrelated untracked files and must not be touched.

## Task 0: Baseline and worker benchmark (read-only, no code)

Files: none committed; raw output to `/tmp/dm-sq-bench/`.
1. Baseline: `python3` over `~/.disk_magician_backup` snapshot history reproducing the stats in the spec table (coverage, `snapshot_metadata.measurement_elapsed_seconds`, `len(timeout_keys)`); save as `/tmp/dm-sq-bench/baseline.json`.
2. (Executed inside Task 4, after the orchestrator exists.) 
Gate: the benchmark must not run while `kern.memorystatus_vm_pressure_level` = 4.

## Task 1: Honest timeout budget (RED then GREEN)

Files: test `tests/test_snapshot_path_budget.sh` (new); code `scripts/disk_snapshot.sh`.
RED tests:
- `test_zero_clamp_honors_config_timeout`: stub `dua`/`du` with a script that sleeps 1 s; config timeout 10, `DISK_MAGICIAN_MEASURE_PATH_MAX_SECONDS=0` -> measured value non-null. Fails today because default clamp 20 and validation rejects 0 (`:430`).
- `test_positive_clamp_still_applies`: clamp 1, stub sleep 3 -> null. All whole-script tests pin the load factor by env (`DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE`) so live load cannot make them nondeterministic.
- `test_load_scale_budget`: sourcing the function with a stubbed load1/cores ratio of 2 yields budget `config*2` capped at 240 (config 100 -> 200; config 200 -> 240).
- `test_every_key_retries_once`: first call times out, second succeeds -> value present though the config entry has no `retry_timeout` (retry in the serial path only; the parallel path's phase-2 retry is tested in Task 4).
- `test_containers_budget_nonzero_when_clamp_zero`: with clamp 0, `lc_*` keys are still produced (guards `:542`); `test_metadata_reports_unclamped`.
- Rewrite only the old clamp/retry assertions in `tests/test_snapshot_audit_coverage.sh` (these assert the removed 20 s default, not the disk_audit.sh gate; they must change for the suite to pass), including the dua limit at `:449` and the retry log at `:525-531`, (`:414`, `:520`, `:513-518`) to the new contract in this same RED commit, and add `bash tests/test_snapshot_audit_coverage.sh` to the Task 1 regression run.
- `test_user_config_snapshot_measure_overrides` (env > `DISK_MAGICIAN_USER_CONFIG` file > default; workers 0 and path_max_seconds 20 restore legacy behavior; reads the user file, never the packaged template).
Run: `bash tests/test_snapshot_path_budget.sh` (expect failures). Commit `test: RED honest per-path timeout budget`.
GREEN: default `MEASURE_PATH_MAX_SECONDS=0` meaning no clamp; validation at `:430` accepts `>=0`; `dir_size_kb` computes `path_budget = min(240, to * load_factor)`, applies the clamp only when `max_seconds > 0`; extract `load_factor()` into `scripts/lib/snapshot_budget.sh` (sourceable, since `disk_snapshot.sh` is not; reads `sysctl -n vm.loadavg`, `hw.ncpu`, clamps 1..3); generic serial-path retry in the dir loop (`:483`) when remaining budget permits; every reader of the clamp (`:430`, `:486`, `:542`, `:987`) gets the explicit 0 meaning from the spec; `snapshot_measure` reader on `${DISK_MAGICIAN_USER_CONFIG:-$HOME/.config/disk-magician/config.json}`; `DISK_MAGICIAN_STATE_DIR` override (`:~276`). Re-run the test (expect pass) plus `bash tests/test_snapshot_freshness.sh`.

## Task 2: Carry-forward store (RED then GREEN)

Files: test `tests/test_snapshot_carry_forward.py`; code new `scripts/snapshot_carry.py`.
RED tests: `test_update_only_fresh_non_null`, `test_atomic_write_survives_kill` (write to tmp then rename; simulate interruption), `test_carry_within_72h_tagged_with_age`, `test_expired_carry_becomes_unmeasured_not_zero`, `test_corrupt_file_moved_aside_treated_empty`, `test_path_change_invalidates_carry` (key's configured path differs from stored path -> not carried), `test_never_emits_zero_for_missing`, `test_lc_and_glob_keys_never_carried`, `test_72h_retention_and_48h_alert_age`. The `--fresh JSON` contract is `{key: {"kb": kb|null, "path": path}}` (so `update` can persist `path` and `merge` can detect a changed configured path) produced from `$DIRS_TEMP_FILE` TSV by a 10-line converter in `snapshot_carry.py` (`from-tsv` subcommand, tested), so Task 3 does not depend on Task 4.
API: `snapshot_carry.py merge --state FILE --fresh JSON --now ISO --max-age-hours 72 --config CONFIG` prints `{fresh:{}, carried:{key:{kb,age_hours}}, unmeasured:[]}`; `snapshot_carry.py update --state FILE --fresh JSON --now ISO`.
Commits: `test: RED carry-forward store`, then `feat: carry-forward store for last-good measurements`. Run `python3 -m pytest tests/test_snapshot_carry_forward.py -q`.

## Task 3: Coverage fields and warning (RED then GREEN)

Files: test `tests/test_snapshot_coverage_fields.sh`; code `scripts/disk_snapshot.sh` (coverage block `:~743-760`, JSON writer `:1005-1030`).
RED tests (use `--output` with a fixture `last_good_measurements.json` and a stubbed measurer so one key times out):
- `test_fresh_pct_equals_legacy_snapshot_coverage_pct`.
- `test_carried_key_in_carried_keys_with_age_and_null_in_directories`.
- `test_no_null_directory_without_carried_or_unmeasured_entry` (G2 invariant).
- `test_effective_equals_fresh_plus_carried`; `test_schema_version_still_2`.
- `test_warning_low_coverage_uses_effective`; `test_warning_degraded_carry_when_carry_over_24h`.
- `test_dedup_does_not_double_count_carried_child_of_fresh_parent`; `test_two_carried_overlapping_keys_count_once` (carried `claude_root` + carried `claude_projects`); `test_null_or_carried_parent_does_not_hide_fresh_child`; `test_timeout_gap_and_unconfigured_split`.
- `test_frontier_pct_present_only_when_age_le_36h`.
Commit `test: RED fresh/carried/unmeasured coverage fields`. GREEN: call `snapshot_carry.py merge` after the measurement loop; feed carried entries into the existing dedup trie flagged carried; export `SNAP_COVERAGE_FRESH_PCT`, `SNAP_COVERAGE_CARRIED_PCT`, `SNAP_COVERAGE_EFFECTIVE_PCT`, `SNAP_COVERAGE_TIMEOUT_GAP_PCT`, `SNAP_COVERAGE_UNCONFIGURED_PCT`, `SNAP_COVERAGE_FRONTIER_PCT`, `SNAP_CARRIED_KEYS`, `SNAP_UNMEASURED_KEYS`, `SNAP_FRESH_KEYS_COUNT`, `SNAP_TOTAL_KEYS_COUNT` into the Python JSON writer; leave `snapshot_coverage_pct` fresh-only. Then `snapshot_carry.py update`. Regression: `bash tests/test_snapshot_freshness.sh tests/test_snapshot_audit_coverage.sh tests/test_residual_drilldown_gate.sh` (run each separately) and `python3 -m pytest tests/test_disk_snapshot_frontier_precedence.py -q`.

## Task 4: Parallel orchestrator (RED then GREEN)

Files: test `tests/test_snapshot_measure_parallel.py`; code new `scripts/snapshot_measure.py`, `--measure-one` mode in `scripts/disk_snapshot.sh`, call site in the dir loop.
RED tests:
- `test_worker_count_policy` (cores 14: load/core 0.5 -> 4; 5 -> 2; pressure 4 or <4 GB free -> 1; env override capped at 6).
- `test_never_exceeds_max_concurrency` (fake `--measure-one` that records concurrent count via lock files; peak <= N).
- `test_merge_order_matches_config_order_regardless_of_completion`.
- `test_disjoint_outputs_one_file_per_key`.
- `test_global_budget_respected` (remaining budget 3 s -> remaining keys returned null with `timed_out`, run ends <= budget + grace).
- `test_worker_crash_yields_null_not_zero`.
- `test_real_script_worker_not_rejected_by_reentry_guard`: runs the REAL `disk_snapshot.sh --measure-one` with `DISK_MAGICIAN_SNAPSHOT_REENTRY_DEPTH=1` inherited and asserts a numeric kb (not exit 75, not empty); `test_nested_full_snapshot_still_rejected`; `test_worker_receives_deadline_epoch`; `test_dua_threads_pinned_to_1`.
- `test_phase2_retry_only_with_leftover_time_and_no_inflation`; `test_orchestrator_deadline_is_min_of_640_and_measurement_deadline`; `test_640s_orchestrator_deadline_kills_descendant_tree` (uses the real GNU `timeout` so the setpgid escape is exercised; asserts no surviving `timeout`/`sleep` pids after a descendant-tree walk; workers use `timeout --foreground` and the 640 s deadline epoch); `test_null_glob_key_listed_in_unmeasured`; `test_unstarted_keys_run_before_retries`; `test_measure_one_exports_deadline_epoch_under_set_u`; `test_serial_remainder_bounded_by_860s_measurement_deadline`; `test_frontier_and_lc_run_before_globs`; `test_shortest_timeout_first_order`; `test_wall_time_model_on_template_config` (51 keys with fake measurers sleeping at configured timeouts finish <= 640 s deadline + grace (the 640/860 s values are env-scalable via `DISK_MAGICIAN_PHASE_SCALE` so the test runs in seconds), and with the stubbed serial remainder total <= 900 s). `--measure-one KEY PATH TIMEOUT OUTPUT_FILE` writes the worker JSON to OUTPUT_FILE.
- `test_serial_fallback_on_orchestrator_failure` (shell-level, in `tests/test_snapshot_measure_fallback.sh`: orchestrator replaced by `exit 3` -> serial loop still produces a snapshot with `measure_mode=serial_fallback`).
Commit `test: RED bounded parallel measurement`. GREEN as in spec Section 1; `snapshot_metadata` gains `measure_mode`, `measure_workers`. Run pytest file and the fallback script. Then the worker benchmark (formerly Task 0 step 2): workers in {1,2,4,6}, 3 runs each, `DISK_MAGICIAN_STATE_DIR=/tmp/dm-sq-bench/state DISK_MAGICIAN_MEASURE_WORKERS=N bash scripts/disk_snapshot.sh --output /tmp/dm-sq-bench/w$N-$i.json`, holding the production snapshot mkdir lock (announce the ~5 h production-history gap first; the long-lived driver script must write its own PID into the lock, because `snapshot_commit.sh` steals a lock only when it is >90 min old AND the stored PID is dead) (`~/.disk_magician_state/snapshot.lock`) for the series, `uptime` captured before each, sequential only. Also compare shortest-first vs longest-first scheduling on fresh coverage. Default = fewest workers within 10% of the best median wall time; record in the commit message and the spec Assumptions table.

## Task 5: Sustained-degradation alert (RED then GREEN)

Files: test `tests/test_coverage_streak_alert.sh`; code `scripts/disk_usage_alert.sh` (`:15-110`). `scripts/disk_audit.sh` is NOT changed (spec Out of scope).
Step 0: `launchctl list | grep disk-magician` and `plutil -p` on the matching plists to record whether `disk_usage_alert.sh` runs on a schedule; if it does not, record that and wire it into an existing template only as a separate bead (out of scope here).
RED tests: `test_no_escalation_for_isolated_low_run`; `test_escalates_after_6_consecutive_effective_below_60`; `test_escalates_when_carry_older_than_48h` (carry age 49 h with 72 h retention); `test_escalates_when_carry_expires_to_unmeasured`; `test_same_snapshot_not_double_counted`; `test_old_schema_streak_file_reset_with_log_line`; `test_falls_back_to_legacy_field_when_effective_missing`; `test_silence_file_suppresses`. Commit `test: RED sustained coverage alert`. GREEN: ring buffer of last 12 in `coverage_streak.json` keyed by snapshot timestamp; demote per-run low_coverage log to INFO. Acceptance 5 check: ad hoc python3 script in `/tmp` feeding the Task 7 snapshots plus a synthetic series, not committed.

## Task 6: Docs, version, mirror, deploy (code complete first)

Files: `pyproject.toml`, `src/disk_magician/**` (generated), `config.json.template` (no timeout changes), `roadmap`-free; no new README.
1. `git fetch origin && git rebase origin/main`; resolve conflicts (likely #80 in `disk_snapshot.sh`).
2. Version = max(origin/main version, highest version in any open PR from a fresh `gh pr list`, 0.2.122) + 1, and >= 0.2.123.
3. `bash scripts/sync_package_tree.sh` then `bash scripts/sync_package_tree.sh --check` (exit 0).
4. Full suite: `python3 -m pytest tests -q` and each `bash tests/test_*.sh` touched; `python3 -m pytest tests/test_check_version_monotonic.py -q`.
5. After merge and authorization: `uv tool install --force --reinstall /Users/jleechan/projects_other/disk_magician`; verify deployed tree: `cmp scripts/snapshot_measure.py "$(find ~/.local/share/uv/tools/disk-magician -name snapshot_measure.py | head -1)"`, `grep -c measure_mode` in the deployed `disk_snapshot.sh`, `./disk_magician.sh check-launchd-fleet` healthy (use `plutil -p`, never bare `plutil -extract`).
6. Next scheduled snapshot: confirm new fields in `~/.disk_magician_backup/snapshots/disk_snapshot.json`.

## Task 7: Acceptance run (last, once, on the final deployed SHA)

20 back-to-back runs to `/tmp/dm-sq-accept/run-$i.json` with `DISK_MAGICIAN_STATE_DIR=/tmp/dm-sq-accept/state` (seeded from a copy of the production carry file) while holding the production snapshot mkdir lock (announce the ~5 h production-history gap first; the long-lived driver script must write its own PID into the lock, because `snapshot_commit.sh` steals a lock only when it is >90 min old AND the stored PID is dead) (sequential, `uptime` captured each, background with timeout 5.5 h and captured log). Evaluate with a python3 heredoc against spec criteria 1-5; save `/tmp/dm-sq-accept/summary.json`. Report numbers, not a pass/fail adjective. Failure branches in the spec Acceptance section.

## Rollback

Fast path (no redeploy): merge `"snapshot_measure": {"workers": 0, "path_max_seconds": 20}` into `~/.config/disk-magician/config.json` (python/jq edit that preserves existing keys). The snapshot launchd job has no env block or repo template, so env knobs are not a rollback path. Full: `git revert` the merge commit, bump to the next patch version (uv caches by version), `uv tool install --force --reinstall`, verify deployed tree. New JSON fields and `last_good_measurements.json` are inert if ignored.

## Timeline (one engineer plus agents; elapsed)

| step | work | est. |
|---|---|---|
| T0 | baseline + setup | 0.5 h |
| T1, T2 in parallel | RED/GREEN | 1.5 h |
| T3 (needs T2) | RED/GREEN | 1.5 h |
| T4 (needs T1) | RED/GREEN + benchmark | 2.5 h |
| T5 | RED/GREEN | 1.5 h (parallel with T3/T4) |
| T6 | rebase, version, mirror, full suite | 1 h |
| T7 | acceptance (20 runs at <= 15 min) | up to 5 h wall, mostly unattended |

Critical path: T0 -> T1 -> T4 -> T6 -> T7 (about 10 h wall).

## Independent lanes (disjoint files)

| lane | tasks | files owned |
|---|---|---|
| A | T2 | `scripts/snapshot_carry.py`, `tests/test_snapshot_carry_forward.py` |
| B | T5 | `scripts/disk_usage_alert.sh`, `tests/test_coverage_streak_alert.sh` |
| C | T1 then T4 | `scripts/disk_snapshot.sh` (measure/budget region), `scripts/snapshot_measure.py`, their tests |
| D | T3 | `scripts/disk_snapshot.sh` (coverage + JSON writer region), `tests/test_snapshot_coverage_fields.sh` |

Lanes A and B run fully in parallel with C. D shares `disk_snapshot.sh` with C: run D after C's T1 commit lands (or in a separate worktree and merge regions; edits are in different functions, but serialize the final merge). T6 and T7 are serial and last. Concurrency of benchmark runs: one at a time only (snapshot lock, load).

## Self-review checklist (done before handoff)

- Every spec requirement maps to a task: Q1 -> T4, Q2 -> T1/T2/T3, Q3 -> T3 (`coverage_frontier_pct`), Q4 -> T3, Q5 -> T5, Q6 -> T6, acceptance -> T7, rollback -> section above.
- Each GREEN names the tests it must pass; each RED names its failing reason.
- No task edits `history_diff.py`, ledgers, or `sweeper_health_check.sh` (they never read the changed fields).
