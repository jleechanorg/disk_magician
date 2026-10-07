# Snapshot Timeout Reliability: Design Spec

Date: 2026-10-03. Scope: `scripts/disk_snapshot.sh` (`com.jleechanorg.disk-magician` job, plist `StartInterval` 1800 s) and its coverage/alert consumers. No implementation in this document.

## Problem

`snapshot_coverage_pct` is bimodal run to run (1,595 snapshots, 2026-08-15..10-03):

| mode | coverage | median runtime | timeout keys | residual |
|---|---|---|---|---|
| high | ~70% | 193 s | ~1 | ~250 GB |
| low | 15-40% | 622 s | ~18 | ~659 GB |

Corr(coverage, timeout-key count) = -0.75; corr with disk used/free ~ 0. Not deploy drift (deployed 0.2.118 matched the repo checkout at investigation time; origin/main `pyproject.toml` was 0.2.120 when this was reviewed). Trigger is host load (loadavg 96-187 on 14 cores while a Colima VM burns ~446% CPU); high runs cluster in idle hours.

Mechanism, verified in code:

1. `MEASURE_PATH_MAX_SECONDS` defaults to 20 (`disk_snapshot.sh:28`). `dir_size_kb` (`:111-146`) does `path_budget = min(config timeout, max_seconds, remaining)`, so the 120-600 s per-dir timeouts in `config.json.template` (e.g. `projects` 300, `projects_other` 180, `claude_root` 120) are silently overridden by 20 s. Only entries with `retry_timeout` get a second attempt (`:483-527`); `projects_other` has none.
2. `add_entry` (`:470-481`) stores `null` on timeout and excludes it from `tracked_total_kb`; `coverage_pct = 100 * tracked_total_kb_deduped / disk_used_kb` (`:~743`), so a timed-out path counts as zero bytes.
3. Measurements are serial (`while read ... dir_size_kb`), so total time is the sum of per-path times under load.
4. `snapshot_warning=low_coverage` (`:755`) fires at coverage < 70, i.e. on most runs; `disk_usage_alert.sh` coverage streak file is stale (streak 1, last update 2026-09-27). The alarm is noise.
5. The nightly frontier scan (gdu_one_pass, 8 workers, ~554 s, exit 0) measures 836.6 of 892.5 GB (residual ~56 GB, 6%) but is embedded only as `topdown_coverage`, never in `coverage_pct`.

Result: the headline coverage and residual measure host load, not the disk, which makes floor/delta analysis (CLAUDE.md methodology step 1) unreliable.

## Goals

- G1: Snapshot wall time bounded and lower under load (target: no run > 900 s, median <= 400 s under current load).
- G2: A timeout never becomes a silent zero. Every key is reported as fresh, carried (with age), or unmeasured.
- G3: Headline coverage is stable run to run and means "how much of used space we have an honest number for".
- G4: Alerts fire only on sustained degradation.
- G5: Zero breakage for `schema_version` 2 consumers; changes are additive.

Non-goals: deploying the root-privileged frontier job (`disk_frontier_scan.py` missing from `/usr/local/libexec/disk-magician/`, exits 2; the ~56 GB blind spot: `.Spotlight-V100`, `.DocumentRevisions-V100`, `.fseventsd`); reducing host load; replacing du/dua.

Out of scope (follow-up): `scripts/disk_audit.sh` keeps gating on fresh `snapshot_coverage_pct` and is not changed here; gating it on `coverage_effective_pct` requires rendering `carried_keys` (tagged with age) in its top-20 table so carried big keys are not silently dropped, tracked as a separate bead.

## Approaches considered

A. Raise `MEASURE_PATH_MAX_SECONDS` only. One-line, but serial runs then exceed the 1500 s budget under load and the null-as-zero lie remains.
B. Use frontier gdu totals as the numerator. Rejected: frontier `measured` (1,235 entries, keyed by `/System/Volumes/Data/...` leaf buckets) has no totals for `~/.claude`, `~/projects_other`, `~/Library/Caches`; summing descendants adds a second dedup problem and couples a 35-min job to a nightly artifact up to 36 h old.
C (recommended). Bounded load-aware parallel measurement + honest timeouts + carry-forward with age + additive fresh/carried/unmeasured coverage + sustained-degradation alert. Frontier stays as a side-by-side figure only.

## Design

### 1. Bounded, load-aware parallel measurement (Q1)

New `scripts/snapshot_measure.py` (orchestrator) runs per-path measurements through a `ThreadPoolExecutor`; each worker spawns `disk_snapshot.sh --measure-one KEY PATH TIMEOUT` (new internal mode that reuses `dir_size_kb`, dua, and the du fallback, so there is no second du implementation). `--measure-one` is parsed before the re-entry guard at `disk_snapshot.sh:11-20` (which otherwise exits 75 because the parent exported `DISK_MAGICIAN_SNAPSHOT_REENTRY_DEPTH=1`), while full nested snapshots stay rejected. The orchestrator passes an absolute `MEASUREMENT_DEADLINE_EPOCH` to each worker (`remaining_measurement_seconds` at `:89` reads it; unset it aborts under `set -u` with an unbound-variable error, so `--measure-one` must export it before calling `dir_size_kb`) and sets `DUA_THREADS=1` so dua's internal thread pool does not multiply the pool size. `--measure-one` takes a 4th argument `OUTPUT_FILE`; each worker writes its own `<tmpdir>/<key>.json` (`{key, kb|null, path, elapsed_s, timed_out}`), so outputs are disjoint; the orchestrator merges in config order, giving deterministic `directories` ordering regardless of completion order.

Concurrency, per `parallelize-to-ceiling` (resource bound first): du is IO/syscall bound but the host is CPU-saturated, so extra workers can only help while the scheduler still grants them time. Policy: `workers = clamp(2, 6, floor(cores/3))` (14 cores -> 4); if `load1/cores > 4` use 2; if `kern.memorystatus_vm_pressure_level >= 4` or available RAM (vm_stat) < 4 GB use 1. Env override `DISK_MAGICIAN_MEASURE_WORKERS`. Hard cap 6, never unbounded forks, no shell-level `&` loops. Scheduling is shortest-configured-timeout first so cheap keys are never starved by a few huge ones; big keys get whatever wall time remains. GNU `timeout` (coreutils 9.7) calls `setpgid(0,0)` and so escapes a `killpg` of the worker's group (verified by a reviewer). Cleanup therefore does not rely on process groups: workers invoke `timeout --foreground`, receive the orchestrator's 640 s deadline (not the 860 s one) as their `MEASUREMENT_DEADLINE_EPOCH` so every inner `timeout` self-terminates, and at the deadline the orchestrator snapshots the descendant tree of each worker (`ps -axo pid=,ppid=` walk) and SIGKILLs every pid in it, then re-walks once to verify none survive. Tests use the real `timeout`. Globs (`glob_size_kb`, `:160-175`) and the dynamic `lc_*` Library/Containers keys (`:535-555`) stay in the existing serial code path and are excluded from carry-forward (their key set changes run to run). Plan Task 0 benchmarks 1/2/4/6 workers under the live load and the chosen defaults are recorded from data, not from this paragraph.

The global `SNAPSHOT_BUDGET_SECONDS` (1500) deadline stays; workers read the remaining budget at start.

### 2. Honest timeouts and carry-forward (Q2)

- The 20 s clamp was a deliberate July decision (commit `adb8a84`, `docs/superpowers/plans/2026-07-14-snapshot-measurement-budget.md`) to fit the 35-minute cadence while measurements were serial. It is reversed here because it silently overrides the configured 120-600 s budgets and turns load into missing data; parallelism plus a hard wall-clock deadline (below) replaces it as the cadence protection. `tests/test_snapshot_audit_coverage.sh` asserts the old behavior (`:414`, `:520` expect `measurement_path_max_seconds == 20`; `:513-518` expect `slow_a`/`slow_b` null with no retry) and is rewritten in Task 1's RED commit.
- `MEASURE_PATH_MAX_SECONDS` default changes from 20 to 0 meaning "no clamp". Every reader of the variable gets an explicit meaning for 0: validation `:430` (accept `>=0`); `dir_size_kb` `:129-135`; the retry gate `:486` (compare against the effective budget, not the raw 0); the Library/Containers budget `:542` (`containers_budget = min(remaining, containers_cap)` with its own default 20 s cap, otherwise 0 would skip the du and drop every `lc_*` key); and the metadata field `measurement_path_max_seconds` `:1033` (reports 0 = unclamped).
- Wall-time model (replaces the earlier untested claim): the 51 configured timeouts sum to ~7,320 s, so G1 cannot come from per-path budgets; it comes from hard deadlines that also cover the serial remainder (library frontier up to 120 s, `lc_*` 20 s, 3 globs up to 30 s each). `MEASUREMENT_DEADLINE_EPOCH = start + 860 s` bounds every measurement, parallel or serial (`remaining_measurement_seconds` already clips each one), so the serial remainder can never push total measurement past 860 s. The 640/860 s constants share one documented override, `DISK_MAGICIAN_PHASE_SCALE` (multiplier, used by tests). Each `coverage_streak.json` ring entry holds `{snapshot_ts, effective_pct, carried:{key:age_hours}, unmeasured:[keys]}` so the carry-expiry trigger can compare consecutive runs. The orchestrator's own deadline is `min(start + 640 s, measurement deadline)` (so a small `SNAPSHOT_BUDGET_SECONDS` in tests is honored), leaving >= 220 s for the serial remainder. Phase 1: all keys, in shortest-timeout-first order, per-path budget `min(config_timeout * load_factor, 240)` where `load_factor = clamp(load1/cores,1,3)` is applied in exactly one place, `dir_size_kb` (the orchestrator passes the raw config timeout in `--measure-one KEY PATH TIMEOUT OUTPUT_FILE`, so the factor is never applied twice). Phase 2 (until the orchestrator deadline): one retry (budget = the key's `retry_timeout` if configured, else its config timeout, both load-scaled in `dir_size_kb`), in descending size-estimate order from the carry file, only for keys that timed out and only with leftover time (no 1.5x inflation). Keys unfinished at the deadline are carried or unmeasured and reported as such. `SNAPSHOT_BUDGET_SECONDS` stays 1500 as the outer safety net; the measurement deadline is `start + min(SNAPSHOT_BUDGET_SECONDS, 860)` and `measurement_budget_seconds` keeps reporting `SNAPSHOT_BUDGET_SECONDS` (1500) so the existing `:519` assertion is unchanged. There is no separate phase-1 time boundary: all keys are attempted first, and retries only use time left after every key has been attempted. Scheduling is shortest-timeout-first by default and Task 4's benchmark also compares longest-first, since criterion 4 depends on the big keys (`projects`, 600 s keys) getting fresh values. Glob keys (`glob_size_kb`) are never carried, so a null glob appears in `unmeasured_keys` (G2). Serial remainder allowance: globs run per matched directory (e.g. `~/worktree_*`, `actions-runner*`) scaled by load, so they are capped by the shared 860 s deadline rather than a per-item allowance; the library frontier and `lc_*` run before globs in the new order so they are not starved.
- State file `~/.disk_magician_state/last_good_measurements.json`: `{key: {kb, measured_at, path, source:"du"}}`, atomically updated (tmp + rename) only with fresh non-null results, under the snapshot mkdir lock when invoked via `snapshot_commit.sh:24-47` (not taken by `disk_snapshot.sh` itself; direct runs rely on tmp + rename alone). Written even on partial runs. The state directory is overridable with `DISK_MAGICIAN_STATE_DIR` (snapshot mode has no `STATE_DIR` today; `:276` is inside `--discover` and `frontier_last.json` is hardcoded at `:874`, so this is new code in snapshot mode) so benchmarks and acceptance runs use a scratch carry file, not production state.
- A key that times out is carried from this file when its age <= 72 h (`CARRY_MAX_AGE_HOURS`); otherwise it is unmeasured. Retention (72 h) is deliberately longer than the alert thresholds (24/48 h) so the alert can observe a stale carry before it expires. A carried value is never presented as fresh.
- `directories[key]` keeps v2 semantics: fresh value, or `null` when not freshly measured (so `history_diff`, ledgers, and cleanup scripts never see stale numbers as current).

### 3. Frontier (Q3)

Per-path du stays authoritative. Frontier is not substituted into the numerator. The snapshot reports `coverage_frontier_pct` (derived from the existing `topdown_coverage.measured_total_kb`, only when `age_hours <= 36`) beside the new fields, giving readers a second, independent estimate and exposing the ~56 GB blind spot honestly. Using frontier leaves as a carry source is deferred to a bead (needs descendant-sum plus dedup design).

### 4. Coverage metric and schema compatibility (Q4)

Additive top-level fields (schema_version stays 2):

```
coverage_fresh_pct       100 * fresh_kb_deduped / used            (== today's snapshot_coverage_pct)
coverage_carried_pct     100 * carried_kb_deduped / used
coverage_effective_pct   fresh + carried
coverage_timeout_gap_pct 100 * (configured keys neither fresh nor carried, last-good kb or 0) / used   (estimate; 0 when no history)
coverage_unconfigured_pct max(0, 100 - effective - timeout_gap); timeout_gap is deduped against fresh entries and clamped at 0   (space no configured path covers; shown separately so load is not conflated with config gaps)
coverage_frontier_pct    from topdown_coverage when fresh
carried_keys             [{key, kb, age_hours}]
unmeasured_keys          [key]
fresh_keys_count / total_keys_count
```

`snapshot_coverage_pct` and `snapshot_metadata.coverage_pct` keep their current meaning (fresh only, deduped), so no consumer silently changes behavior. One deliberate exception: the existing trie keeps null (timed-out) parents in its path set (`:709-716`), so a timed-out `claude_root` hides a fresh `claude_projects` today. The new rule (a null or carried parent never hides a fresh child) fixes that, and can raise `snapshot_coverage_pct` and `residual_gb` on such runs; `test_fresh_pct_equals_legacy_snapshot_coverage_pct` therefore uses fixtures with no null parent. Dedup rule: the trie (`:634-737`) first dedups fresh entries among themselves, as today. A carried entry is then admitted only if it does not overlap (parent or child) any fresh entry; fresh always wins, so a carried or null `claude_root` never hides a fresh `claude_projects`, and a carried child under a fresh parent is dropped. Carried entries are then deduped against each other through the same trie (shallowest path wins), so a carried `claude_root` and a carried `claude_projects` count `~/.claude/projects` once. This undercounts rather than double counts. `residual_gb` and `residual_delta_gb` stay fresh-based and are documented as such.

Consumers enumerated (verified by grep for `coverage_pct|low_coverage|coverage_streak|timeout_keys|measurement_status|topdown_coverage`):

| consumer | reads | impact |
|---|---|---|
| `scripts/disk_usage_alert.sh` (streak, `:46-110`) | `snapshot_coverage_pct`, `snapshot_warning` | switched to `coverage_effective_pct` with fallback to old fields (Section 5) |
| `scripts/disk_audit.sh` (`:75-133`) | `SNAP_COVERAGE = snapshot_coverage_pct` gated at hard floor 50 and `DISK_MAGICIAN_MIN_COVERAGE` 65, plus `snapshot_warning` | unchanged in this work (fresh semantics preserved). A rejected snapshot only prints "Snapshot not usable ... Run snapshot task first" (`:274-279`); the `du` calls at `:303-343` run regardless. Effective-coverage gating deferred (see Out of scope) |
| `scripts/residual_drilldown.sh` (`:117-120`) | `snapshot_coverage_pct` / `snapshot_metadata.coverage_pct` | unchanged (fresh semantics preserved) |
| `scripts/snapshot_lib.sh` (`:48-49`) | presence of `snapshot_coverage_pct` | unchanged |
| `scripts/disk_history.sh` (`:144`) | `snapshot_coverage_pct` | unchanged |
| `scripts/disk_inventory.py` (`:169,185`) | own `coverage_pct` field | unchanged |
| `scripts/history_diff.py`, `scripts/render_topdown_ledger.py`, `scripts/check_ledger_freshness.sh`, `scripts/sweeper_health_check.sh` | no coverage keys (grep: 0 hits; render reads `topdown_coverage` only in a comment) | unchanged; `directories` stays fresh-only so they cannot ingest carried data |
| `growth_top10` | no such file in `scripts/` | n/a (stated so the list is complete) |

`snapshot_warning=low_coverage` is now computed on `coverage_effective_pct < 70`; new value `degraded_carry` when any key is carried > 24 h. `snapshot_warning` holds one value: `low_coverage` wins when both apply (`disk_audit.sh:133` substring-matches `low_coverage`). `disk_usage_alert.sh` must actually be scheduled for any of Section 5 to matter; Task 5 first checks for its launchd job (`launchctl list | grep disk-magician`) and records the answer.

### 5. Alerting (Q5)

`disk_usage_alert.sh` coverage streak is redefined on `coverage_effective_pct` with history in `coverage_streak.json` (ring of last 12 values, keyed by snapshot timestamp so reruns do not double count). It escalates only when one of:

- `coverage_effective_pct < 60` for 6 consecutive distinct snapshots (~3 h of snapshots at the 30 min interval; observed latency is up to ~6 h because `disk_usage_alert.sh` runs hourly), or
- any key carried with `age_hours > 48`, or any key newly `unmeasured` after having had a last-good value (carry expired at 72 h) -- measurement permanently failing for that path, or
- no new snapshot for > 2 h (already covered by `check_ledger_freshness`; reused, not duplicated).

It reuses the existing silence file and alert channel. The stale streak file is migrated (old schema detected and reset, with a log line). The per-run `low_coverage` log line is demoted to INFO.

### 6. Deploy path (Q6)

Per repo CLAUDE.md (two consumers): the 35-min job runs the uv-tool-packaged copy, so repo-root edits are not live until packaged. Steps: `scripts/sync_package_tree.sh` (picks up `scripts/*.py` and `scripts/*.sh`, so `snapshot_measure.py` is mirrored), bump `pyproject.toml` version to >= 0.2.123, `uv tool install --force --reinstall <repo>`, then verify the deployed tree (`~/.local/share/uv/tools/disk-magician/.../disk_magician/scripts/snapshot_measure.py` exists and `cmp` matches the repo; `disk-magician --version`). Merge-order awareness: open PRs #77, #80, #81, #84, #85, #86, #87, #89 (re-list with `gh pr list` at implementation start) touch versions 0.2.120-0.2.122 and some touch `disk_snapshot.sh`/`sweeper_health_check.sh` (#80 additive snapshot signals is the likely `disk_snapshot.sh` conflict). Rebase on origin/main at implementation start; take `max(origin version, highest version in any open PR, 0.2.122) + 1` (>= 0.2.123); run `scripts/check_version_monotonic` tests. Do not bump on a stale base.

## Failure modes and rollback

- Orchestrator crash or missing python: `disk_snapshot.sh` falls back to the existing serial loop when `DISK_MAGICIAN_MEASURE_WORKERS=0` or the orchestrator exits non-zero (logged as `measure_mode=serial_fallback` in `snapshot_metadata`).
- Corrupt `last_good_measurements.json`: treated as empty (all timeouts become unmeasured, never zero); a bad file is moved aside with a timestamp.
- Rollback: `uv tool install --force --reinstall` of the previous version tag (bump to a new patch number since uv caches by version). Redeploy-free kill switch: the snapshot job `com.jleechanorg.disk-magician` runs `~/.local/bin/disk-magician snapshot` from `~/Library/LaunchAgents/com.jleechanorg.disk-magician.plist`, which has no `EnvironmentVariables` and no template in `launchd/` (`install_launchd_sweepers.sh:206` only installs `com.jleechanorg.disk-magician-*.plist.template`), so env knobs cannot be set from the repo. Instead the script reads a `snapshot_measure` object from the fixed user-owned file `${DISK_MAGICIAN_USER_CONFIG:-$HOME/.config/disk-magician/config.json}` (the packaged `REPO_ROOT/config.json` is the template and is replaced on every reinstall, so it is not a kill-switch location; `disk_snapshot.sh` does not read the user file today and gains this reader; the file may already hold `state_repo_path`, so edit it by merging the key, not overwriting), e.g. `{"snapshot_measure": {"workers": 0, "path_max_seconds": 20}}`, precedence env > user config > default; the reader checks only `DISK_MAGICIAN_USER_CONFIG` if set, otherwise `$XDG_CONFIG_HOME/disk-magician/config.json` (default `~/.config/...`), with no fallthrough to `resolve_config.py`'s state-repo copy or the packaged template; setting workers 0 and path_max_seconds 20 restores the old serial 20 s clamp; the generic retry, load scaling, the 860 s deadline and carry-forward remain (they are additive and individually inert). Edit config.json with python/jq, never `plutil -extract` without `-o -`. New JSON fields are additive and can be ignored.

## Acceptance criteria (measured)

Over 20 consecutive snapshot runs (back-to-back to scratch `--output` paths with `DISK_MAGICIAN_STATE_DIR` pointing at a scratch dir seeded with a copy of the production carry file; hold the production `~/.disk_magician_state/snapshot.lock` via the same mkdir protocol for the whole series (accepted cost: up to ~5 h gap in production snapshot history, which can trip the 2 h freshness check; announce it before starting) so launchd runs skip instead of overlapping and adding load; record loadavg per run), all of:

1. `coverage_effective_pct` >= 65 in every run and max-min spread <= 10 points (baseline spread: 15-70).
2. Total measurement wall time (including the serial remainder: library frontier, `lc_*`, globs) <= 900 s for every run and median <= 400 s (baseline low-mode median 622 s).
3. `unmeasured_keys` has <= 5 entries in every run, and no key is ever `null` in `directories` without appearing in `carried_keys` or `unmeasured_keys`.
4. `coverage_fresh_pct` median >= 50 (baseline low mode median ~25) under load; reported, not gated, if load is idle.
5. Alert: feeding the 20 new snapshots plus a synthetic series (6 consecutive effective < 60; a key carried 49 h; a carry expiry) through the streak logic escalates exactly on the synthetic triggers and never on the 20 real runs unless criterion 1 itself fails. (Historical snapshots lack the new fields, so replaying them would only test the old metric; `STREAK_ESCALATE_AT=3` also means today's alert is not one per run.)

If criterion 2 fails, tune workers from Task 0 data; if criterion 1 fails because fresh coverage is low and carry ages out, the shortfall is reported as unmeasured, which is the intended honest result, and a bead tracks the load source.

## Assumptions and Recommended Defaults (auto-picked)

| # | Question | Auto-picked | Rationale |
|---|---|---|---|
| 1 | Parallelize measurements? | Yes, bounded load-aware pool (2-6, default 4, 2 when load/core > 4, 1 under memory pressure), via Python orchestrator calling a `--measure-one` mode | du is IO bound; sum of serial timeouts is the runtime; reuse `dir_size_kb`; disjoint per-key outputs, config-order merge. Defaults finalized by Task 0 benchmark |
| 2 | Timeouts | Default clamp 20 s -> 0 (honor config), load-scale x1-3 capped 240 s per path (applied once, in `dir_size_kb`), retry every key once, carry forward last-good with age (<= 72 h retention; alert at > 48 h), never null-as-zero | The clamp contradicts config and causes the bimodality |
| 3 | Use frontier totals? | No for numerator; report `coverage_frontier_pct` side by side | Frontier has no totals for big dirs, up to 36 h old, double-dedup risk |
| 4 | Metric | Add fresh/carried/effective/unmeasured fields; keep old fields as fresh-only | schema_version 2 consumers unchanged |
| 5 | Alerting | Sustained: effective < 60 for 6 snapshots, or carry age > 48 h; `low_coverage` flag on effective < 70 | Removes always-on noise |
| 6 | Deploy | Version >= 0.2.123 after rebase, sync_package_tree, uv reinstall, verify deployed tree | CLAUDE.md two-consumer rule; open PR version collisions |
| 10 | Rollback kill switch | `snapshot_measure` object in `~/.config/disk-magician/config.json` (env > user config > default) | The snapshot plist has no env block or template; the packaged config is a template wiped on reinstall, the user config is not |
| 7 | Where to store carry state | `~/.disk_magician_state/last_good_measurements.json` | State dir already holds `frontier_last.json`, `coverage_streak.json`; not the git-backed backup repo |
| 8 | Carry max age | 72 h (alert at carried > 48 h) | Retention must exceed the alert threshold or the alert can never see a stale carry |
| 9 | Python vs bash for orchestrator | Python | ZFC-neutral mechanical code; bash 3.2 on macOS lacks `wait -n` |

## Implementation Preconditions

None blocking. Task 0 requires running timing benchmarks on the live host (read-only du; no deletion). Deploy and launchd reinstall require the standard post-merge authorization and are outside this planning run.
