# disk_magician: from cleanup engine to producer-admission system (convergence design)

- **Date:** 2026-10-19
- **Author:** Claude Code (`claude-fable-5-1`), `/sq`
- **Status:** Proposed design, planning only (no implementation in this invocation). Revision 9 after eight `/advice` rounds (Opus NOT APPROVED on rev 1–8, 2026-10-19, each round narrower; rev 7 found the catalog is on an unmerged branch, rev 8 found `cleanup_dev_caches.sh` missing from every list; ChatGPT via /web-advice: approve-with-changes on rev 5; Codex lane unavailable, usage limit until 2026-10-26; Gemini 3.8 Flash via /web-advice: approve-with-changes on rev 4): zone measure is `df` Available and all pilot targets use it; two pilot windows; only five scripts fold into `dir_prune` (uv_cache, dark_factory, sessions stay bespoke); the ezgha `TempDir` leak fix is precondition P0 before W1; Colima tick gates on class budget only; D6 is the C11 decision `external_edits` and the shim patch is hash-checked; absorbed launchd rows keep their cadence through the existing C10 trigger table plus one `every_min` key (no second trigger table); Colima is a diagnosis of why the existing overage row does not fire; the ezgha leak fix is a direct PR under cross-repo authority; `external_edits` covers only the two user-owned files; W1's start gate counts live checkouts only and times out at 48 h; goals, Q8 and the PR titles are consistent with §7.6 and §9; the venv merge keeps the 7-day floor (Task A8); W1 reports bytes reclaimed per producer; six jobs with `routine` at 30 min, `every_min` per row, fsevents watcher kept, installer asserts no cadence regression; deploy moved into PR-A close-out; PR-0 (merge the deployed-but-unmerged branch that carries the catalog) precedes PR-A; liveness watchdog lives in the observer, not in a job it watches; the third venv actuator is folded; `dev_caches` restored as the first row; the single probe covers all 22 `lsof` sites; the shared argument parser is deferred to PR-D; W1 has a stop rule with `--restore-absorbed` rollback; snapshot watches the observer; reap_orphans checks for a live owner; the admit rc matrix is explicit at every call site.
- **Repository:** `jleechanorg/disk_magician` at `/Users/jleechan/projects_other/worktree_dropbox`
- **Supersedes nothing. Builds on:** `docs/superpowers/specs/2026-10-11-disk-fill-durable-control-design.md` (controls C1–C14, decisions D1–D8) and `docs/superpowers/specs/2026-10-17-diskm-unified-cleanup-and-governor-redesign-design.md` (`main_sweeper.sh`, lease store, C14 gaps). This document does not redesign those controls; it names why they are not acting and specifies the smallest set of cuts, wirings, and activations that make them act.

---

## 1. Why (evidence, 2026-10-19)

### 1.1 The disk refills every day regardless of cleanup

`~/.disk_magician_state/disk_observer.jsonl` (df every ~60 s), last 12 days, host used GiB:

| day | min | max | swing | Colima datadisk swing |
|---|---|---|---|---|
| 10-09 | 805 | 886 | 80 | 14 |
| 10-10 | 831 | 885 | 54 | 15 |
| 10-11 | 839 | 894 | 55 | 19 |
| 10-12 | 851 | 894 | 43 | 11 |
| 10-13 | 839 | 883 | 43 | 0 |
| 10-14 | 777 | 887 | 109 | 11 |
| 10-15 | 830 | 895 | 65 | 15 |
| 10-16 | 844 | 874 | 30 | 1 |
| 10-17 | 812 | 864 | 52 | 13 |
| 10-18 | 708 | 873 | 166 | 32 |
| 10-19 | 718 | 868 | 151 | 29 |

Volume is ~926 GiB. Used peaks at 885–895 GiB on 9 of 12 days. Colima explains 10–30 GiB of each swing; the remainder is not Colima.

### 1.2 Who produces the rest

Committed snapshots (`~/.disk_magician_backup`, `snapshots/disk_snapshot.json`, coverage 75–77 %) between the 10-18 peak (07:22, 870 GiB) and trough (11:46, 707 GiB):

| snapshot key | delta | meaning |
|---|---|---|
| `tmp_private` | 88 GiB | `/private/tmp`: 10,031 entries; 266 `ezgha-lima-*` runner tempdirs (209 under 1 day old, 57 at 1–3 days), 165 `git-header-pr-*`, PR advice/bundle scratch |
| `projects` | 47 GiB | `~/projects` task-scratch containers and clones |
| `library_developer` | 19 GiB | Xcode DerivedData |
| `worktrees_dot` | 8 GiB | `~/.worktrees` births |

Writers: the `ez-gh-actions` **test suite** (`src/lima_convergence.rs` `mod tests::fake_home()` creates `ezgha-lima-{}-{}-{}` under the system temp dir and relies on `TempDir` drop; a killed or crashed test run leaks it), run repeatedly by five long-running `pi` agent dev lanes (1.4 days uptime at observation); Xcode builds; and agent sessions creating worktrees/clones. The 57 `ezgha-lima-*` dirs aged 1–3 days are past the `tmp` actuator's 24-hour tier and still present, so this is a **reclaim gap** as well as a producer: the tier is not removing them (cause to be measured in PR-A, Task A7). The Colima VM (`com.apple.Virtualization`) was at 117 % CPU and the 5-minute load average was 90 on 14 cores while this was measured: the producers run continuously.

### 1.3 The controls exist and are not acting

The 10-11 spec built an admission system. Its state on 2026-10-19:

| control | built | acting | why not |
|---|---|---|---|
| C2 `diskm admit` (`scripts/disk_budget.py`) | yes | observe only | `policy_provenance.py approved admission_enforcement` → rc 1; `diskm policy list` shows **zero** recorded decisions (D1–D8 all unrecorded) |
| C6 `hooks/disk-admission.sh` (PreToolUse Bash) | yes | no | not present in `~/.claude/settings.json` (only `guard-worktree-add`, `worktree-create-hook`, `worktree-remove-hook` are) |
| C13 `scripts/ci_admit.sh` (ezgha job-started hook) | yes | no | no reference in `~/projects_other/ez-gh-actions` |
| worktree birth via `~/.local/bin/guards/git` shim | shim exists | placement only | shim enforces `~/.worktrees/<repo>/<name>`; it never calls `admit_gate` |
| admission events, last 7 days | 2,386 events | — | 221 `admit` events, **all** from `worktree-new` and **all** decision 10 (warn, proceed); 0 from hook, CI, or git shim; 105 `floor_breach` (govern tick saw `df` free < 15 GiB, `disk_budget.py:936`), 218 `govern_emergency`, 114 `kickstart_blocked:c14_missing` (C14 self-test now passes from the installed 0.2.245 tree; the blocks predate it) |
| C10 `diskm govern` | yes | ticks | zone ORANGE at observation; emergency rows cannot refuse because D2 is unrecorded |

So the system measures its own failure 105 times a week and has no door through which to refuse anything.

### 1.4 The response so far has been accretion

Repo on `origin/main` (`bc35f2d`): 75 shell + 38 Python scripts, 47,318 lines, 26 `cleanup_*.sh`/`prune_*.sh` actuators, 24 launchd templates, 245 releases. `lsof` is invoked from 24 files (bead `disk_magician-ulr0` names four divergent live-cwd parsers); `--clean`/dry-run argument handling is copied in 25 scripts; 7 of 25 cleanup scripts do not source `safety_lib.sh` (`cleanup_antigravity_brain`, `cleanup_apfs_snapshots`, `cleanup_colima`, `cleanup_dirs_cleaner`, `cleanup_docker`, `cleanup_downloads_evidence`, `cleanup_llm_inspector`). `main_sweeper.sh` (10-17 Task 4) was added to *consolidate* eight launchd jobs but runs **alongside** them: the eight still exist. `/cs` on 2026-10-19 returned Ponytail **FAIL** (compensator accretion) and Root-cause-first **FAIL** (producer gate has no callers).

`roadmap/nextsteps-2026-09-11-disk-recurrence.md` reached the same conclusion five weeks ago ("every reset in 30 days was an operator session; automation reclaimed ~0 per cycle"); its coder lanes died at spawn and the follow-ups added scripts.

## 2. Goals

1. The disk stops reaching the near-full band daily, measured in `df` Available (the zone measure, §7.5a): window W1 keeps Available ≥ 60 GiB every day (never RED) with intraday swing < 60 GiB; window W2 holds W1's headroom plus the measured Colima gain with swing < 40 GiB (§9).
2. Every birth in a governed class (`worktrees`, `tmp_containers`, `tmpdir_scratch`, `codex_documents`, `colima`) passes through `diskm admit`, from every producer, with refusals possible in RED/BLACK/FLOOR.
3. Reclaim is one table-driven pipeline with one orchestrator, one live-file probe, one argument contract, and one safety gate on every delete path.
4. The launchd fleet is small enough to be checked by eye: 6 jobs, with no absorbed job running less often than today.
5. Net code goes down. Target: delete ≥ 9 scripts and ≥ 18 launchd templates; no new orchestrator module.

## 3. Non-goals

- Re-deriving C1–C14 or D1–D8. They stand as specified in the 10-11 document; this spec wires and activates them.
- A Python rewrite of the bash actuators (10-17 Approach C, already rejected).
- Changing the 7-day/3-day recency floors, the never-delete list, or `WORKTREE_APPROVED` semantics.
- Auto-pausing or killing CI runners or agents (D4 default: alert + pause command, no auto-pause).
- Deleting any ledger, snapshot, observer, or admission history.

## 4. Anti-goals (must not happen)

- A new `diskm reclaim` module that duplicates `main_sweeper.sh` + `disk_audit.sh` routine (Ponytail rung 2). The table replaces the hard-coded `if [[ -f cleanup_x.sh ]]` ladder inside `disk_audit.sh`; it does not add a third orchestrator.
- Enforcement activated by code default or by an agent-written decision record. Only `diskm policy approve <id> --phrase '<literal user text>' --from-transcript <jsonl>` (C11) activates refusals; this planning invocation records nothing.
- Editing user-owned wrappers (`~/.local/bin/guards/git`, `~/.bashrc`) or `~/.claude/settings.json` without the D6 decision recorded. (Repository PRs in `ez-gh-actions` are ordinary cross-repo disk-maintenance work and go through that repo's own merge gate.)
- A second trigger table or dispatcher beside `eligible_actuators()` in `disk_budget.py`.
- Any removal path that bypasses `artifact_removal_verdict` (C14) or `safety_gate`.

## 5. Constraints

- `diskm` is the single operational entry point (repo `CLAUDE.md`); scheduled jobs call installed `diskm` subcommands, never repo scripts directly.
- Deploy is the uv-tool package built from `src/disk_magician/` after `scripts/sync_package_tree.sh` and a `pyproject.toml` version bump (`tools/deploy_uv_tool.sh`).
- Linux twin (`jeff-ubuntu`, systemd `disk-magician-routine-clean` and `disk-magician-snapshot` timers) must keep working with the same table.
- CI (`.github/workflows/ci.yml`, macos-15): sync-check, version monotonicity, ShellCheck, Python tests, `tests/test_removal_sites.sh` audit of every removal site.

## 6. Approaches considered

**A. Third greenfield redesign (new `diskm reclaim` driver, new table format, new scheduler).** Rejected: it is the accretion pattern applied to design documents. Two prior designs already specify the control model; a third would add a parallel module.

**B. Convergence: cut, wire, activate (recommended).** Delete the duplicated actuators and jobs, promote the existing `CATALOG_RULES` table to the one source of reclaim targets, route the three real producers through the existing `admit_gate`, and make the recorded-decision gate the only thing standing between observe and refuse. Smallest diff; every piece reuses something already in-tree.

**C. Enforcement only (record D2/D6, install the hook, leave the 26 scripts).** Rejected as incomplete: it fixes births but leaves the 24-job fleet that `check-launchd-fleet` has found dead or flapping four times; the reclaim side stays unreviewable.

## 7. Chosen design

### 7.1 One reclaim table (`scripts/lib/reclaim_catalog.py`)

**Provenance (Opus review, rev 7):** `scripts/disk_report_html.py` and its `CATALOG_RULES` (40 rows) are **not on `origin/main`** (`bc35f2d`). They live on branch `feat/worktree-lease-reap-rebased` (pushed as `origin/feat/unified-mac-linux-0.2.240`), 9 commits ahead of `origin/main` (`4adc369` v0.2.243 adds the report, `e1ca589` v0.2.244, `5289a8e` v0.2.245), with no open PR. That branch is what this session deployed to both machines as 0.2.245, so production already runs unmerged code (the stale-deploy class of incident in `CLAUDE.md` § Deployment). **PR-0** therefore precedes PR-A: open the PR for that branch, drive it green, merge it; PR-A is based on the merged result. Reviewers reading `origin/main` will not find the catalog until PR-0 lands.

Move `CATALOG_RULES` out of `scripts/disk_report_html.py` into `scripts/lib/reclaim_catalog.py`, imported by the report (unchanged rendering) and read by `disk_audit.sh` via `python3 -m` JSON export. Each row gains three fields the routine needs:

```
key, bucket (safe|gated|protected|system), category, name, path, command,
explanation, checked,
+ actuator   : one of {dev_caches, tmp, worktrees, worktree_deps, colima, xcode,
               codex_db, claude_state, task_scratch, pr_scratch,
               antigravity_brain, codex_documents, apfs_snapshots, uv_cache,
               dark_factory, sessions, dir_prune}
+ age_days   : integer floor passed to the actuator (dir_prune uses it directly;
               bespoke actuators may only raise their own floor)
+ class      : admission class whose budget this row counts against, or null
+ every_min  : cadence floor for rows with class == null, run by `routine`
               (main_sweeper, every 30 min) when the row's last receipt is older
               than every_min; never set higher than the launchd interval the
               row replaces (§7.5 table)
```

Triggers for **class rows** are not a catalog field. `scripts/disk_budget.py:210–262` already owns a fixed C10 `ACTUATORS` table and `eligible_actuators()`, driven per class by `budgets.classes[<class>].trigger` (`always | zone | overage`) in `config.json` (Opus review, rev 4). The catalog row's `class` links it to that existing table; the class config gains one optional key, `every_min`, honored for `trigger: always` so an absorbed hourly job does not run every 10-minute tick. **Rows without a class** (the `dir_prune` rows, xcode, codex_db, claude_state, apfs_snapshots …) have no C10 entry; they are run by the existing `main_sweeper.sh` (today every 30 min) and carry the same single key, `every_min`, on the catalog row. One key, two existing dispatchers that already exist today (govern for class rows, main_sweeper for the rest); no new dispatcher.

`disk_audit.sh --routine` iterates `bucket == safe` rows in table order and calls `run_category "$name" <actuator> $clean_arg --min-age "$age_days"`, replacing the hard-coded `if [[ -f "$SCRIPT_DIR/cleanup_*.sh" ]]` ladder (`scripts/disk_audit.sh:533–706`, including its `SESSIONS_APPROVED` and `AO_PLAYWRIGHT_DEDUP_APPROVED` gates, which become row gates). `$clean_arg` keeps today's semantics: dry-run unless `diskm clean --routine` is invoked with the existing opt-in (`DISK_MAGICIAN_AUTO_CLEAN=1` or `--clean`); the mode is passed to every row, and a row that cannot parse it fails visibly in the receipt rather than skipping silently. The first row stays `dev_caches` (`cleanup_dev_caches.sh`, Tier 1 in `CLAUDE.md`, 3–15 GiB): it was missing from rev 8's lists (Opus review) and is a kept bespoke actuator. `gated` rows run only when their row's gate (`WORKTREE_APPROVED=1`, recorded decision id) holds. `protected`/`system` rows are never actuated. The 7 cleanup scripts that currently skip `safety_lib.sh` either become `dir_prune` rows (which source it once) or are deleted.

### 7.2 One generic actuator: `scripts/reclaim_dir_prune.sh`

Five scripts are the same program: "under path P, remove entries older than N days unless open, live-cwd, or protected". They become table rows for one actuator: `cleanup_llm_inspector.sh`, `cleanup_downloads_evidence.sh`, `cleanup_supervisor_logs.sh`, `prune_aside_sessions.sh`, `cleanup_agent_artifacts.sh`. Three that looked similar are **not** folded because each carries reachability or live-reference logic that a path-plus-age row would drop (Opus review, rev 2): `cleanup_uv_cache.sh` delegates to `uv cache prune --force` (removes only entries no installed environment references; an age prune could delete wheels in use), `cleanup_dark_factory.sh` scans live systemd units, `bin/` symlinks and `/proc/*/fd` for references and guards symlinked roots, and `cleanup_sessions.sh` walks several Hermes roots with per-root rules. They stay bespoke rows. The actuator sources `safety_lib.sh`, calls `artifact_removal_verdict` on every candidate, uses the single live-file probe (§7.3), and emits the same receipt as other actuators (`scripts/lib/actuator_receipt.sh`). Aside's static-asset hardlink dedup (the one non-prune behavior in `prune_aside_sessions.sh`) stays as a `--dedup` flag on the row.

Deleted outright (target proven phantom, empty, or duplicated): `cleanup_code_sign_clones.sh` (APFS clone phantom, `findings_wiki/2026-10-17-codesign-clone-du-is-phantom-when-versions-match.md`), `cleanup_ollama.sh` (8 KB on this host), `cleanup_docker.sh` (subset of `cleanup_colima.sh`), `cleanup_dirs_cleaner.sh` (becomes `diskm check-system-residual --clean`, already the documented path).

Kept as bespoke actuators (they have real per-target logic): `cleanup_dev_caches.sh`, `cleanup_tmp.sh`, `cleanup_worktrees.sh`, `cleanup_worktree_venvs.sh` + `cleanup_worktree_deps.sh` + `scripts/reclaim_worktree_venvs.sh` (a third venv actuator already called from `disk_audit.sh`; all three merge into one `worktree_deps` actuator with a **per-dependency-class floor**: `.venv`/`venv` keep the 7-day floor the repo `CLAUDE.md` mandates, `node_modules`/`target`/`.mypy_cache` keep the 3-day floor; the merge may never lower either; plan Task A8), `cleanup_colima.sh`, `cleanup_xcode.sh`, `cleanup_codex_db.sh`, `cleanup_claude_state.sh`, `cleanup_task_scratch.sh`, `cleanup_pr_scratch.sh`, `cleanup_antigravity_brain.sh` (compaction, not prune), `cleanup_codex_documents.sh`, `cleanup_apfs_snapshots.sh`, `cleanup_uv_cache.sh`, `cleanup_dark_factory.sh`, `cleanup_sessions.sh`. Result: 27 (26 `cleanup_*`/`prune_*` plus `reclaim_worktree_venvs.sh`) → 17 actuator scripts (16 bespoke + `reclaim_dir_prune.sh`), all table-dispatched. Manifest: delete 5 folded + 4 phantom/duplicate + `cleanup_worktree_venvs.sh` + `reclaim_worktree_venvs.sh` = 11; add 1; 27 − 11 + 1 = 17.

### 7.3 One live-file probe (bead `disk_magician-ulr0`)

`artifact_verdict.sh` already owns `_av_open_file` and the Linux/macOS `lsof` flag parity fixed in 0.2.245. Promote it to the public `artifact_open_files <path>` and `artifact_live_cwd <path>` (returning PIDs). **Scope is all 22 `lsof` call sites** in `scripts/*.sh` and `scripts/lib/*.sh` (Opus review, rev 8), not the four named in bead `ulr0`: 7 of them are in scripts this spec deletes or folds and leave with them; the remaining 15 (`cleanup_worktrees.sh`, `worktree_hygiene.sh`, `worktree_reap.sh`, `cleanup_tmp.sh`, `cleanup_xcode.sh`, `cleanup_colima.sh`, `pressure_sweep.sh`, `worktree_remove_hook.sh`, `scripts/lib/worktree_safety.sh`, `scripts/lib/scratch_budget.sh`, `scripts/lib/lsof_linux.sh`, and the rest of the grep output on the PR-A base) are routed through the two calls. Acceptance: `grep -l lsof scripts/*.sh scripts/lib/*.sh` returns `scripts/lib/artifact_verdict.sh` only; `disk_observer.py` (reports, never deletes) is the only Python exception.

### 7.4 One argument contract (deferred to PR-D, after the pilot)

A shared `actuator_args.sh` replacing the 25 private flag parsers moves no W1 metric and would widen a safety-critical −2,500/+600 diff right before the window meant to measure it (Opus review, rev 8). It is deferred to PR-D (§12). In PR-A, the new `reclaim_dir_prune.sh` parses its own four flags inline, and existing actuators keep their parsers; the only cross-actuator contract PR-A relies on is the one `disk_audit.sh` already passes (`$clean_arg`, `--min-age N`).

### 7.5 Six launchd jobs, no cadence regression

Folding a job into another never lowers how often its work runs (Opus review, rev 6: a nightly `routine` would have cut main-sweeper 30 min → 24 h and downloads-evidence 6 h → 24 h, a W1 failure of this design's own making). Each absorbed job keeps its interval as `every_min` on its row; `install_launchd_sweepers.sh` asserts, for every deleted label, `old StartInterval ≥ new effective interval` (plan A6).

| job | cadence | runs | absorbs (old interval → `every_min`) |
|---|---|---|---|
| `observer` | continuous (`KeepAlive`) | `diskm observe` | unchanged |
| `fsevents-projects` | continuous (`KeepAlive` watcher) | `scripts/watch_projects_fsevents.sh` | unchanged: a watcher cannot be batched (finding `2026-10-17-fsevents-state-cache-unbounded-growth.md`) |
| `observer` (same job as above) | continuous (`KeepAlive`) | `diskm observe` | **`sweeper-health` liveness**: the watchdog moves into the one job that cannot be silently unloaded without the observer log stopping (`check-launchd-fleet` logic runs every 30 min inside the observer loop and pushes the existing C12 Slack/SMTP alert on any missing label or stale receipt). It must not live inside `snapshot` or `routine`, the jobs it exists to catch dying (Opus review, rev 7; `CLAUDE.md` records that failure three times). |
| `snapshot` | 30 min | `diskm snapshot` (+ ledger commit) | `govern-measure` daily measure |
| `govern` | 10 min | `diskm govern` | `pressure-sweep` (30 → zone rows every tick at ≤ RED, as today), `worktree-reap` (30 → 30), `tmp-scratch` (60 → 60) via the **existing** `eligible_actuators()` rows: `budgets.classes.tmp_containers` becomes `trigger: always, every_min: 60` (today hourly) and `budgets.classes.worktrees` `trigger: always, every_min: 30` (today every 30 min); `eligible_actuators()` gains one check, "skip an `always` row whose last receipt is younger than `every_min`". Zone rows stay as they are. Folding a job into the tick never lowers its frequency (Opus review, rev 3: the zone trigger fires only at RED/BLACK/FLOOR). `worktree-hygiene` (6 h) has no C10 adapter and moves to `routine` at `every_min: 360`. |
| `routine` | **30 min** (main-sweeper's cadence today) | `main_sweeper.sh`: snapshot phase unchanged, then every `class == null` catalog row whose last receipt is older than its `every_min` | `main-sweeper` (30 → 30), `cursor-logs-watchdog` (60 → 60), `drilldown` (240 → 240), `downloads-evidence` (360 → 360), `worktree-hygiene` (360 → 360), `code-sign-clones` (deleted, phantom), `worktree-venvs` (daily → 1440, now the `worktree_deps` venv class), `codex-vacuum` (1440 → 1440), `claude-state` (daily report → 1440), `colima-prune` (daily → govern overage row), `hermes-vacuum`, `playwright-dedup`, `apfs-snapshots` (calendar daily → 1440) |
| `frontier-root` | nightly 02:00 | `diskm frontier --root` via the FDA launcher | `frontier-nightly` |

Templates for the 18 absorbed jobs are deleted; `scripts/install_launchd_sweepers.sh` boots out **exactly the 18 named labels** (an explicit allowlist in the script, never a prefix wildcard) so stale plists cannot flap, and refuses to install if any absorbed label's old interval is shorter than its row's `every_min`. `check-launchd-fleet` expects exactly six labels. `systemd/` on Linux mirrors the same six units. **Mutual watch:** the observer carries the fleet watchdog (above), and the `snapshot` job checks observer freshness (last observer record < 5 min old) and pushes the same C12 alert if it is stale, so neither watcher's death is silent. **Rollback:** `install_launchd_sweepers.sh --restore-absorbed` re-installs the 18 templates from the previous release's package tree (`uv tool install disk-magician==<prev>` then the installer), and is the W1 stop action (§9). The `apfs_snapshots` row runs at `every_min: 360` instead of daily, since local snapshots and purgeable space are what sit between used and `df` Available on breach days (§7.5a).

### 7.5a What admission can and cannot do in the pilot (zone basis)

Zones are computed from **`df` Available** (`disk_budget.py:8`, `:933–936`, column 4): GREEN ≥ 100 GiB, ORANGE 60–100, RED 30–60, BLACK 15–30, FLOOR < 15. On APFS, Available is **not** capacity minus used: the week's 105 `floor_breach` events (Available < 15 GiB) happened while the observer's used figure never exceeded 895 of 926 GiB (31 GiB by subtraction). Purgeable space, local snapshots and the Colima sparse file sit between the two. Consequences: (a) every pilot target is stated in `df` Available, the measure the zones use; used-GiB swing is reported alongside as context only; (b) with only D2 recorded, refusals happen at BLACK (76, queue) and FLOOR (75), RED stays `warn`, so admission acts only in the bottom 30 GiB. Swing and headroom improvements are therefore *reclaim-cadence* outcomes (owned by PR-A and the ezgha leak fix), the *door* metrics are coverage (admit events by source, bypass rate), and the *backstop* metric is `floor_breach = 0`. Class-overage refusals at ORANGE (`refuse_orange` with `over_budget`, already in `decide()`) arrive only with D3 after the pilot. Two windows keep each PR's effect attributable (§8 Q12).

### 7.6 Three doors for the three producers

All three use the existing caller contract (`scripts/lib/admit_caller.sh`: `admit_gate <class> <est> <producer> <dest> <source>`), with the full exit-code matrix stated at every call site, never collapsed to `|| exit 75` (ChatGPT review): rc 0 → run; rc 10 → print the warning line, run; rc 76 → wait `retry_after_s` once (default 600 s), re-admit, then run on 0/10 or refuse on 75/76; rc 75 → print `disk-admission: refused …`, do not run, exit 75; any other rc or a missing `diskm` → `admission_degraded:caller`, run (counted as bypass). For the CI hook, where a non-zero hook exit fails the job, the 76 wait happens **inside** the hook, bounded by one `retry_after_s`, so a job is delayed rather than failed.

**Door 1 — worktree and clone birth.** Two call sites, both already intercept the command:
- `hooks/disk-admission.sh` (C6) installed as a PreToolUse Bash hook in `~/.claude/settings.json` by `diskm setup --hooks` (new idempotent subcommand that edits the hooks array in place and is covered by `tests/test_disk_admission_hook.sh`). This covers Claude Code sessions.
- `~/.local/bin/guards/git` shim: after its placement check succeeds for `git worktree add` / `git clone`, call `admit_gate worktrees - git-shim "$dest" shim`; rc 75 → print the refusal line and exit 75 without running git. This covers every CLI (codex, pi, agy, cursor, bare shells). The shim is user-owned; the edit is conditional on D6 (§10).

**Door 2 — `/private/tmp` and `$TMPDIR` scratch.** The dominant writer is the ez-gh-actions test suite's `fake_home()` tempdir, leaked when a test run is killed. 209 of the 266 dirs are under a day old, so no 24-hour tier can touch most of them: the leak fix is the only control that changes W1, and it is a plain bug fix that needs no admission. It is therefore the **first** external edit requested (precondition P0, §10), ahead of PR-A's window. Three parts, in order of effect:
1. *Lifecycle fix in ez-gh-actions (P0, a plain bug fix in the user's own repo):* `fake_home()` creates under a single governed container `/private/tmp/ezgha-tests/` (depth-1 root the birth audit already counts, class `tmp_containers`), keeps the `TempDir` guard alive for the test's scope, and the test harness reaps any `ezgha-lima-*` sibling that is older than 1 h **and** has no live owner (no process with cwd or an open file inside it, checked immediately before removal; a sibling whose owner is alive is skipped, so concurrent test runs cannot delete each other's homes — ChatGPT review). This repo's `CLAUDE.md` ("Cross-repo authority") already authorizes disk-maintenance edits in other repos, so this is opened **directly as a PR in `ez-gh-actions`** from a `diskm worktree-new` worktree, not shipped as a patch file or gated on a decision (Opus review, rev 4: the gate was ceremony delaying the biggest lever). The `external_edits` decision stays for the two user-owned files only (§10). **Propagation:** the fix reaches a producer once its checkout has it. After merge to ez-gh-actions `main`, each *live* checkout (one with a running `cargo test` or `pi` process whose cwd is inside it, per `artifact_live_cwd`) is merged from `main` by its lane owner (branch-ownership rule; never edit another agent's worktree). W1 starts when no live checkout lacks `reap_orphans`; dormant worktrees are not in the gate.
2. *Reclaim gap in this repo (PR-A, no decision):* the `tmp` actuator's 24-hour tier must remove an `ezgha-lima-*` dir that has no live cwd and no open file. Task A7 measures why the 57 aged dirs survived (lsof timeout → fail-closed, C14 `kept:<reason>`, or birth-audit lease) and fixes that cause, with a regression test.
3. *CI jobs (ez-gh-actions PR, same cross-repo authority):* `scripts/ci_admit.sh` (C13) is wired into the runner's job-started hook with `--class tmp_containers` for the workspace birth (the bytes land under `tmp_private`, not the Colima datadisk; the current `colima` class is wrong) and `--class colima` only for image pulls. At BLACK/FLOOR the job waits (76) instead of being born into a full disk.
Scratch born by agents directly under `/private/tmp` is already counted by the birth audit (C7) and reclaimed by the `tmp` actuator tiers; no new control.

**Door 3 — Colima.** `~/.colima/default/colima.yaml` already caps the datadisk at 100 GiB, the budget class `colima` is 30 GiB, and the live config already has `colima: trigger overage → cleanup_colima.sh --clean` in the C10 table. So the overage trigger **exists and is not firing**. The observer shows the datadisk allocation swinging 10–42 GiB and sitting at ~24 GiB when measured, so the likely cause is that `used_gb` rarely exceeds the 30 GiB budget, with `class_stale` (measurement older than 3 h) as the second candidate. This door is a **diagnosis**, not a feature: read the govern receipts and `budget.json` `classes.colima` for the last 7 days, name the cause, and fix that one thing (a budget of 15 GiB if the cause is threshold; the measure cadence if it is staleness). No new trigger path. Recovery of a wedged VM (`colima stop && colima start`) stays behind D8.

**Pausing producers at RED.** Per D4 the tick does not stop runners. The existing C12 RED alert (`sweeper_health_check.sh` / `diskm status`) gains one line naming the top class by overage and the exact pause command (`ezgha` supervisor stop, `colima stop`); no new event type (a second alert channel would duplicate C12). At BLACK/FLOOR admit refuses new births (75/76), which is the pause that needs no decision. The operator pauses; the agent asks before pausing CI runners (repo `CLAUDE.md`).

### 7.7 Activation sequence (C11)

Code ships with the gate closed. Nothing in this design changes a default from observe to refuse. Activation is the user recording, in order:

1. `admission_enforcement` (D2) — emergency rows refuse at once; ORANGE/RED rows stay at `warn` until D3.
2. `worktree_cleanup` (D1b) — `cleanup_worktrees.sh --clean` runs unattended under `routine` and `govern`, behind C14.
3. `budgets` (D3) — after the 7-day pilot validates `pilot_floor_ok`.

D6 is recorded the same way under a new C11 id `external_edits`, added to `policy_provenance.py` `IDS` in PR-B; it covers exactly two user-owned files, `~/.local/bin/guards/git` and `~/.claude/settings.json`; the shim and hook installers call `diskm policy approved external_edits` and refuse otherwise. Edits inside `ez-gh-actions` need no decision (cross-repo authority in `CLAUDE.md`). A CLI flag is not a decision. `apply_git_admit.sh` also compares the live shim's SHA256 with the hash the patch was cut against and refuses on mismatch, since the shim is user-owned and may change.

Each is `diskm policy approve <id> --phrase '<literal user text>' --from-transcript <session.jsonl>`. An unrecorded decision leaves that row in observe; the system reports which decisions are unrecorded first in `diskm status` (C12 already does this).

## 8. Assumptions and recommended defaults (auto-picked by `/sq`)

| # | Question | Auto-picked answer | Rationale |
|---|---|---|---|
| Q1 | New `diskm reclaim` driver or extend `main_sweeper.sh` + `disk_audit.sh`? | Extend; the table replaces the `if`-ladder inside `disk_audit.sh` | Ponytail rung 2; 10-17 Task 4 already named `main_sweeper.sh` the single orchestrator |
| Q2 | Where does the table live? | `scripts/lib/reclaim_catalog.py`, imported by the report, exported as JSON for bash | Report already encodes bucket/command/explanation; one source for UI and routine |
| Q3 | Which scripts are deleted vs folded? | Delete 4 (phantom/empty/duplicate), fold 5 into `dir_prune`, merge the three venv/deps scripts, keep 16 bespoke + 1 generic = 17 | Each deletion cites a finding or a byte count; bespoke scripts have target-specific logic (git state, SQLite, VM) |
| Q4 | How many launchd jobs? | 6 (observer, fsevents watcher, snapshot, govern, routine every 30 min, frontier-root) | Root/FDA launcher cannot share a plist with user jobs; a KeepAlive watcher cannot be batched; everything else is a cadence expressed as `every_min`, never lower than today |
| Q5 | Enforcement stage at activation | `refuse_red` for emergency rows only (D2 default), `warn` elsewhere until D3 | Matches 10-11 §8 "emergency rows at once; other rows phased" |
| Q6 | Live-file probe home | Promote `_av_open_file` in `artifact_verdict.sh`; no new lib | It already has the 0.2.245 flag parity and is on every C14 path |
| Q7 | git shim: edit or wrap? | Edit the shim (one `admit_gate` call), conditional on D6 | A second wrapper in front of a wrapper is the pattern this spec removes |
| Q8 | Colima: smaller fixed disk or a new trigger? | Neither; keep the 100 GiB cap and diagnose why the existing `colima: overage` row in the C10 table does not fire (§7.6 Door 3) | The trigger exists; a smaller disk wedges the guest (memory 2026-07-15) |
| Q9 | Auto-pause runners at RED? | No (D4). Recommend + refuse births at BLACK/FLOOR | Repo `CLAUDE.md`: ask before pausing CI runners |
| Q10 | PR shape | 3 coarse PRs: cut, doors, activate-and-pilot | `pr-quantity-control`: ≤ 3 open per scope; each is independently green |
| Q11 | Linux twin | Same table, same six units | 0.2.245 already deployed there; divergence is a second accretion axis |
| Q12 | One pilot or two? | Two 7-day windows: W1 after PR-A deploy (cut only, no decisions), W2 after PR-B + D2/D6 (doors) | Opus review 2026-10-19: a single window cannot attribute a pass or fail to the fleet cut vs the doors, and a job that was quietly the only reclaimer of a path shows up only as a slow floor rise |
| Q13 | Which class for CI workspace births? | `tmp_containers` | The bytes are measured under `tmp_private`; charging `colima` would never trip the right budget |
| Q14 | Where do triggers live? | In the existing `budgets.classes[].trigger` + `eligible_actuators()`; the catalog adds none | A second trigger table beside the C10 one is the parallel module this spec exists to remove (Opus, rev 4) |
| Q15 | How is the ezgha leak fixed? | Direct PR in ez-gh-actions now, no decision, no patch file | `CLAUDE.md` cross-repo authority already covers it; a gate would only delay the dominant producer's fix |
| Q16 | Why isn't the Colima overage row firing? | Diagnose from receipts before changing anything; budget threshold is the leading hypothesis | The trigger exists; re-specifying it would be accretion |

## 9. Success metrics (two 7-day windows)

All targets below are in **`df` Available** (the zone measure); the observer's used-GiB swing is logged alongside for context.

**W1 — cadence (after the ezgha leak fix P0 and the PR-A deploy).** Owner: ezgha `TempDir` fix, table-driven routine, tmp tier fix (A7), six jobs with no cadence regression. The other two measured producers are already table rows and are reported per producer below: `~/projects` scratch containers (`task_scratch` row, 1-day floor, `cleanup_task_scratch.sh`) and Xcode DerivedData (`xcode` row, `cleanup_xcode.sh`; its DerivedData floor drops from 7 to 2 days in PR-A since DerivedData is rebuildable and is the third-largest producer at +19 GiB/day). **Stop rule:** if any W1 day's minimum `df` Available breaches RED (< 60 GiB), or the 30-day floor (`daily_min_used`) rises on two consecutive days, W1 halts, `install_launchd_sweepers.sh --restore-absorbed` runs the same day, and the report names the producer from the per-producer table; a week-long regression is halted, not merely reported (Opus review, rev 8). **Start rule:** W1 starts when the live ez-gh-actions checkouts carry P0, or 48 h after the P0 merge, whichever is first; if a live lane has not merged by then, W1 starts anyway and its report lists the lane and counts `ezgha-lima-*` bytes separately so the headroom number is not misread. **Attribution:** every W1 day reports bytes reclaimed per producer (from actuator receipts: `tmp` tier, `ezgha-tests` container, `task_scratch`, `xcode`, `dir_prune` rows, `routine` total) next to the headroom number, so a missed headroom target names the producer that outran reclaim instead of reading as "the cut failed".

| metric | now | W1 target | source |
|---|---|---|---|
| min `df` Available per day | < 15 GiB on breach days (105 events / 7 d) | ≥ 60 GiB every day (never RED) | govern tick `df_free_bytes`, observer |
| max intraday Available swing | — (used swing 30–166 GiB) | < 60 GiB | observer |
| `ezgha-lima-*` dirs present at any snapshot | 266 (209 < 1 d) | < 10, none older than 1 h | ledger `tmp_private` hot dirs |
| 30-day floor (`budget.json` `daily_min_used`) | — | does not rise during W1 (no deleted job was a sole reclaimer) | `diskm budget status` |
| bytes reclaimed per producer per day (`tmp`, `ezgha-tests`, `task_scratch`, `xcode`, `dir_prune`, `routine`) | not reported | reported every day; each producer's reclaim ≥ its measured daily growth, or named as the shortfall | actuator receipts (`actuator_receipt.sh`), ledger deltas |

**W2 — doors and backstop (after PR-B deploy + D2 and D6 recorded).** Owner: hook, shim, CI wiring, Colima tick. W2 does not claim a GREEN-every-day target: admission refuses only at BLACK/FLOOR and the Colima tick explains 10–30 GiB at most, so W2's headroom target is W1's result plus what the Colima tick measurably adds. The door metrics are the point of W2.

| metric | now | W2 target | source |
|---|---|---|---|
| min `df` Available per day | W1 result | W1 result + the Colima reduction measured in W2 (expected +10–20 GiB); never below W1's floor | govern tick, observer |
| max intraday Available swing | W1 result | < 40 GiB | observer |
| `floor_breach` events / 7 d | 105 | 0 | `admission/events.jsonl` |
| admit events by source | `worktree-new` only | `hook`, `shim`, `ci` each > 0; `admission_degraded:caller` < 5 % of admits | events.jsonl |
| Colima datadisk swing / day | 10–30 GiB | < 10 GiB | observer `colima.root_allocated_kb` |

**Structural (PR-A merge).**

| metric | now | target | source |
|---|---|---|---|
| actuator scripts | 27 | 17 | `ls scripts/cleanup_*.sh scripts/prune_*.sh scripts/reclaim_*.sh` |
| launchd templates / loaded labels | 24 / 16 | 6 / 6 | `diskm check-launchd-fleet` |
| absorbed jobs running less often than before | — | 0 (installer assertion) | `install_launchd_sweepers.sh --dry-run` |
| files invoking `lsof` for deletion decisions | 24 | 1 | `grep -l lsof scripts/*.sh scripts/lib/*.sh` |
| `ci_admit.sh` workspace class | `colima` | `tmp_containers` | `tests/test_ci_admit.sh` |
| cleanup scripts without `safety_lib.sh` | 7 | 0 | grep |
| `tests/test_removal_sites.sh` | passes | passes with the reduced site list | CI |

## 10. Implementation preconditions (user decisions, unchanged from 10-11 §10)

| ID | needed by | status 2026-10-19 |
|---|---|---|
| D2 admission enforcement | any refusal (§7.7 step 1) | **unrecorded** |
| **PR-0** merge of `feat/worktree-lease-reap-rebased` (the deployed 0.2.245, carrying the catalog) | PR-A's base | **unmerged, no PR open**; needs `MERGE APPROVED` at its size |
| **P0** ezgha test-tempdir lifecycle fix | W1 (the dominant producer) | **no decision needed** (cross-repo authority); a PR in ez-gh-actions, merge gate there as usual |
| D6 (C11 id `external_edits`): `~/.claude/settings.json` hook install and `~/.local/bin/guards/git` shim edit only | Door 1 | **unrecorded**; id added in PR-B; the installers check it |
| Lane owners merging `main` into live ez-gh-actions checkouts | W1 start rule | outside this repo's control; W1 starts at 48 h regardless and reports the gap |
| D1b unattended `cleanup_worktrees.sh --clean` | `routine`/`govern` worktree rows | **unrecorded** |
| D3 budgets | enforcement beyond `warn` | after pilot |
| D8 Colima self-heal | wedge recovery only | **unrecorded** |

PR-A (cut) needs no decision; W1 starts after the P0 PR is merged in ez-gh-actions and the live checkouts carry it. PR-B (doors) ships the code with the shim/hook/CI wiring as installable but not installed; the install steps run only after `external_edits` is recorded. PR-C (activate) is the recording of D2, D6 and D1b plus window W2; it contains no code.

## 11. Risks

- **Deleting a job that was the only thing reclaiming something.** Mitigation: PR-A's `install_launchd_sweepers.sh` prints the absorbed-by map; `check-launchd-fleet` fails if any deleted label is still loaded; window W1 runs with the cut alone and watches `daily_min_used` against the 30-day floor (`budget.json`) before any door changes cadence.
- **Attributing a pass or fail to the wrong change.** Mitigation: two windows (§8 Q12); W2 starts only after W1 is written up.
- **The git shim refusing a human's `git worktree add`.** Mitigation: rc 75 prints the zone, the class overage, and `DISK_MAGICIAN_WORKTREE_GUARD=off` for a one-off override; refusals are events, so a false refusal is visible the same day.
- **ezgha jobs queued at BLACK (76) stacking up.** Mitigation: the retry is once after `retry_after_s`; the runner's own job timeout bounds the wait; the RED alert names the pause command before BLACK is reached.
- **Table drift between report and routine.** Mitigation: one Python module; `tests/test_disk_report_html.sh` and a new `tests/test_reclaim_catalog.sh` both assert every `safe` row has an `actuator` that exists and every actuator is referenced by at least one row.

## 12. Deferred

- **PR-D, after the pilot:** the shared actuator argument parser (`actuator_args.sh`, §7.4) replacing the 25 private parsers.
- Per-agent scratch quotas inside `$TMPDIR` (`tmpdir_scratch` budget is measured and warned, not refused, until D3).
- Converting `pi`/`agy` long-running agents to call `diskm scratch-new` (C4 narrow producer conversion) — behind D6 and outside this repo.
- Reservation ledger (10-11 §12).
