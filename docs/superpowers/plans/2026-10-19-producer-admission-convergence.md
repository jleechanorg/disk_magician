# Producer-Admission Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:executing-plans` (or `~/.claude/skills/superpowers-execute-plan`) to implement this plan task-by-task. Planning-only invocation: nothing below has been started.

**Goal:** Make disk_magician's existing admission controls act (every governed birth passes `diskm admit`; refusals possible once decisions are recorded) and shrink the reclaim side to one table, one probe, one argument contract, and six launchd jobs with no cadence regression.

**Architecture:** One prerequisite PR plus three coarse PRs, two pilot windows. **PR-0** (no new code): open and merge the PR for `feat/worktree-lease-reap-rebased` (9 commits ahead of `origin/main`, v0.2.243–0.2.245, already deployed on both machines, carries `scripts/disk_report_html.py` and `CATALOG_RULES`); PR-A is based on it. PR-A *cut* (table-driven routine, generic prune actuator for five path-plus-age scripts, single live-file probe, six jobs at today's cadences, `tmp` tier gap fix, `every_min` on the existing C10 trigger table) plus **P0**, a separate PR in `ez-gh-actions` fixing the `TempDir` leak (cross-repo authority, no decision) → deploy → live checkouts carry P0 → **window W1** (7 days, cadence metrics in `df` Available). PR-B *doors* (Claude hook installer and git shim patch gated on the C11 decision `external_edits`, ezgha job-started PR, CI class fix, diagnosis of the existing Colima overage row; installable, not installed). PR-C *activate* (user records D2/D6/D1b, doors installed, **window W2**, 7 days, door and backstop metrics; no code). Zones are free-space based, so refusals in W2 occur only at BLACK/FLOOR; swing/peak improvements are owned by cadence, not admission (spec §7.5a). Spec: `docs/superpowers/specs/2026-10-19-producer-admission-convergence-design.md`.

**Tech Stack:** bash (actuators, `disk_magician.sh` dispatch), Python 3.13 (`reclaim_catalog.py`, `disk_report_html.py`, `disk_budget.py`), launchd/systemd templates, bats-style `tests/test_*.sh` and `pytest` under `tests/`, uv-tool deploy via `tools/deploy_uv_tool.sh`.

**Branch/worktree:** one worktree per PR via `diskm worktree-new <repo> <branch>` under `~/.worktrees/disk_magician/`. Never edit the primary checkout. Commit messages end with `[claude-code][claude-fable-5-1]`; PR titles end with `[claude-code][claude-fable-5-1]`.

**Shared gates per PR:** `bash disk_magician.sh sync-package-tree --check`, `bash disk_magician.sh check-version`, `shellcheck -S error scripts/*.sh scripts/lib/*.sh hooks/*.sh`, `python3 -m pytest tests -q`, `REMOVAL_SITES_AUDIT=1 bash tests/test_removal_sites.sh`, `/cs` (prod delta > 150 lines, required), `/advice` at the final head, then `/green`.

---

## PR-0 — merge the deployed branch (no new code)

Base: `origin/main` `bc35f2d`. Head: `feat/worktree-lease-reap-rebased` `5289a8e` (remote: `origin/feat/unified-mac-linux-0.2.240`). Steps: `git merge-tree` cleanliness vs `origin/main`; run the shared gates on the head; `/cs` (its prod delta exceeds 150 lines); `/advice`; open the PR with the standard body (line-delta opener, evidence that 0.2.245 is what both hosts run per `deployed.json`); wait for `MERGE APPROVED`. Until it merges, reviewers of PR-A must be pointed at this branch, not `origin/main`.

## PR-A — cut (prod delta estimate: −2,500 / +600)

### Task A1: `reclaim_catalog.py` becomes the single target table

**Files:**
- Create: `scripts/lib/reclaim_catalog.py`
- Modify: `scripts/disk_report_html.py` (import, delete inline `CATALOG_RULES`)
- Create: `tests/test_reclaim_catalog.sh`
- Modify: `tests/test_disk_report_html.sh` (import path only)

**Step 1: Write the failing test**

`tests/test_reclaim_catalog.sh` asserts: (a) `python3 scripts/lib/reclaim_catalog.py --json` prints a JSON array; (b) every row with `bucket == "safe"` has `actuator` in the allowed set and `age_days >= 0`; (c) every `actuator` value names an existing `scripts/<actuator>` script per the map `{dev_caches: cleanup_dev_caches.sh, tmp: cleanup_tmp.sh, worktrees: cleanup_worktrees.sh, worktree_deps: cleanup_worktree_deps.sh, colima: cleanup_colima.sh, xcode: cleanup_xcode.sh, codex_db: cleanup_codex_db.sh, claude_state: cleanup_claude_state.sh, task_scratch: cleanup_task_scratch.sh, pr_scratch: cleanup_pr_scratch.sh, antigravity_brain: cleanup_antigravity_brain.sh, codex_documents: cleanup_codex_documents.sh, apfs_snapshots: cleanup_apfs_snapshots.sh, uv_cache: cleanup_uv_cache.sh, dark_factory: cleanup_dark_factory.sh, sessions: cleanup_sessions.sh, dir_prune: reclaim_dir_prune.sh}`; because A2 creates `reclaim_dir_prune.sh`, assertion (c) is marked expected-fail until A2 and the test file is committed with A1 anyway; (d) `disk_report_html.py` renders the same 40 keys as before (`CATALOG_RULES` count snapshot).

**Step 2: Run to verify it fails** — `bash tests/test_reclaim_catalog.sh` → fails: module missing.

**Step 3: Implement** — move the dict verbatim into `reclaim_catalog.py` as `CATALOG_RULES`; add `actuator`, `age_days`, `class` to each `safe`/`gated` row (values from the current script defaults: tmp 1, worktree_deps 3, worktrees 3, xcode 7, colima 0, codex_db 0, claude_state 7, task_scratch 1, pr_scratch 1, dir_prune rows per §7.2 of the spec); add `main()` with `--json`. `disk_report_html.py`: `from reclaim_catalog import CATALOG_RULES` with the `scripts/lib` path insert the other scripts already use.

**Step 4: Run** — `bash tests/test_reclaim_catalog.sh && bash tests/test_disk_report_html.sh` → both pass.

**Step 5: Commit** — `feat(catalog): single reclaim table shared by report and routine`.

### Task A2: `reclaim_dir_prune.sh` generic actuator

**Files:**
- Create: `scripts/reclaim_dir_prune.sh` (parses its own four flags inline: `--clean | --dry-run (default) | --min-age N | --max-items N`; the shared parser is PR-D)
- Create: `tests/test_reclaim_dir_prune.sh`

**Step 1: Failing tests** — `test_reclaim_dir_prune.sh` (fixture dirs under `mktemp -d`, `HOME` overridden, `DISK_MAGICIAN_ADMIT_BIN` stub): dry-run lists but keeps; `--clean --min-age 7` removes an 8-day entry, keeps a 1-day entry, keeps an entry with an open file (use `sleep` holding a fd), keeps a path matched by a `never_delete` glob in a fixture `safety.local.json`, writes one receipt line via `actuator_receipt.sh`, and refuses to run when `artifact_removal_verdict --self-test` fails (stub it to fail).

**Step 2: Run** — both fail: files missing.

**Step 3: Implement** — `reclaim_dir_prune.sh --path P --min-age N [--dedup]`: sources `safety_lib.sh`, `artifact_verdict.sh`, `actuator_receipt.sh`; candidates = depth-1 entries of P older than N days by `worktree_last_activity_epoch`-style newest-mtime (reuse `_av_newest_mtime`); per candidate `safety_gate` then `artifact_removal_verdict` then `quarantine_remove` (existing `scripts/lib/quarantine.sh`); `--dedup` runs the hardlink pass copied from `prune_aside_sessions.sh`.

**Step 4: Run** — pass.

**Step 5: Commit** — `feat(reclaim): generic dir_prune actuator`.

### Task A3: Fold five scripts into table rows; delete four; keep three bespoke

**Files:**
- Delete: `scripts/cleanup_llm_inspector.sh`, `cleanup_downloads_evidence.sh`, `cleanup_supervisor_logs.sh`, `prune_aside_sessions.sh`, `cleanup_agent_artifacts.sh` (the five path-plus-age scripts), `cleanup_code_sign_clones.sh`, `cleanup_ollama.sh`, `cleanup_docker.sh`, `cleanup_dirs_cleaner.sh`
- Keep bespoke (rows with their own actuator): `cleanup_uv_cache.sh` (`uv cache prune --force`, reachability-based), `cleanup_dark_factory.sh` (systemd/`bin/`/`/proc/*/fd` reference scan), `cleanup_sessions.sh` (per-root Hermes rules). Before deleting `cleanup_docker.sh`, diff it against `cleanup_colima.sh` and record in the PR body which commands it ran that colima does not; if any, move them into the colima actuator first.
- Modify: `scripts/lib/reclaim_catalog.py` (rows for the five with `actuator: dir_prune`, their current path and age), `disk_magician.sh` (delete the nine subcommands; `cleanup-dirs-cleaner --clean` → `check-system-residual --clean`), `scripts/check_system_residual.sh` (absorb the `find -delete` path from `cleanup_dirs_cleaner.sh`)
- Delete tests that only exercised deleted scripts; move their assertions that still apply into `tests/test_reclaim_dir_prune.sh` fixtures (one fixture per former script).

**Step 1: Failing test** — extend `tests/test_reclaim_catalog.sh`: the five names appear as `dir_prune` rows with the exact paths from the deleted scripts; `uv_cache`, `dark_factory`, `sessions` rows point at their bespoke scripts; `grep -c 'cleanup_code_sign_clones\|cleanup_ollama\|cleanup_docker\.sh\|cleanup_dirs_cleaner' disk_magician.sh scripts/*.sh` is 0.

**Step 2: Run** — fails.

**Step 3: Implement** — as listed. For each deleted script, record `path`, `min-age`, and any exclusion glob in the row before deleting the file (read the script first; do not infer).

**Step 4: Run** — `bash tests/test_reclaim_catalog.sh`, `python3 -m pytest tests -q`, `REMOVAL_SITES_AUDIT=1 bash tests/test_removal_sites.sh` → pass with the shorter site list.

**Step 5: Commit** — `refactor(reclaim): fold 5 prune scripts into dir_prune rows; delete 4 phantom/duplicate actuators`.

### Task A4: Table-driven routine in `disk_audit.sh`

**Files:**
- Modify: `scripts/disk_audit.sh` (lines 533–607: replace the `if [[ -f cleanup_*.sh ]]` ladder with a loop over `reclaim_catalog.py --json`), `scripts/main_sweeper.sh` (Phase 3 pressure list reads `bucket==safe && class!=null` rows instead of its hard-coded three)
- Modify: `tests/test_disk_audit_routine.sh` (create if absent)

**Step 1: Failing test** — with `DISK_MAGICIAN_ACTUATOR_STUB=1` (each actuator replaced by a stub that echoes its argv), `disk_audit.sh --routine --dry-run` invokes exactly the `safe` rows in table order with `--min-age <row.age_days>`; a `gated` worktree row runs only when `WORKTREE_APPROVED=1`; `protected` rows never appear. In `tests/test_govern_scheduler.py`, against the **existing** `eligible_actuators()`: a class with `trigger: always, every_min: 60` is eligible when its last receipt is older than 60 min and not eligible when younger; a class with `trigger: always` and no `every_min` behaves as today (every tick); `zone` and `overage` rows are unchanged.

**Step 2: Run** — fails (ladder order, no `--min-age`).

**Step 3: Implement** — loop in `disk_audit.sh`; in `eligible_actuators()` (`disk_budget.py:231–262`) add the single `every_min` check for `trigger == "always"` using the last receipt age (`actuator_receipt.sh` already writes it); add `every_min` to `config.json.template` for `tmp_containers` (60) and `worktrees` (30) and set their `trigger` to `always`. No new table, no new dispatcher. Keep `run_category` and its timeout/receipt behavior unchanged. This is what lets Task A6 delete the `tmp-scratch` and `worktree-reap` plists without lowering their frequency; `worktree-hygiene` moves to `routine`.

**Step 4: Run** — pass; also `bash disk_magician.sh clean --routine --dry-run` on the dev host prints the same categories as before plus the folded rows.

**Step 5: Commit** — `refactor(routine): drive diskm clean from the reclaim table`.

### Task A5: One live-file probe (bead `disk_magician-ulr0`)

**Files:**
- Step 0 (read-only): `grep -l lsof scripts/*.sh scripts/lib/*.sh` on the PR-A base and paste the list (22 files on rev 8's base) into the PR body; subtract the files A3/A8 delete or fold; every remaining file is in scope.
- Modify: `scripts/lib/artifact_verdict.sh` (public `artifact_open_files`, `artifact_live_cwd`; absorb `scripts/lib/lsof_linux.sh`) and **every** remaining file from Step 0, including `scripts/cleanup_worktrees.sh`, `scripts/worktree_hygiene.sh`, `scripts/worktree_reap.sh`, `scripts/cleanup_tmp.sh`, `scripts/cleanup_xcode.sh`, `scripts/cleanup_colima.sh`, `scripts/pressure_sweep.sh`, `scripts/worktree_remove_hook.sh`, `scripts/lib/worktree_safety.sh`, `scripts/lib/scratch_budget.sh`
- Delete: `scripts/lib/lsof_linux.sh`
- Modify: `tests/test_cleanup_tmp_open_files.sh` (unchanged assertions, new function names), create `tests/test_artifact_live_probe.sh`

**Step 1: Failing test** — `test_artifact_live_probe.sh`: `artifact_live_cwd <dir>` returns the PID of a `sleep` whose cwd is the dir, empty otherwise, rc 0 either way; rc 3 and `probe_failed` on stderr when `lsof` is absent from `PATH` (fail closed); `grep -l lsof scripts/*.sh scripts/lib/*.sh` → `scripts/lib/artifact_verdict.sh` only.

**Step 2: Run** — fails (the Step 0 list minus `artifact_verdict.sh` still matches).

**Step 3: Implement** — move the parser; each consumer replaces its private block with the two calls and keeps its "unknown → protected" branch.

**Step 4: Run** — `test_artifact_live_probe.sh`, `test_cleanup_tmp_open_files.sh` (85/85), `test_worktree_recency.sh`, `test_cleanup_worktrees*.sh` → pass. Close bead `disk_magician-ulr0` in the PR body.

**Step 5: Commit** — `refactor(probe): one live-file/live-cwd probe in artifact_verdict.sh`.

### Task A6: Six launchd jobs, six systemd units, no cadence regression

**Files:**
- Delete: 18 templates under `launchd/` (all except observer, fsevents-projects, snapshot, govern, main-sweeper → renamed `routine` with `StartInterval` 1800, frontier-root)
- Modify: `scripts/disk_observer.py` (the liveness check from `sweeper_health_check.sh` runs inside the observer loop every 30 min and pushes the existing C12 alert; `tests/test_disk_observer_liveness.py` asserts an unloaded label in a fixture `launchctl list` produces one alert), `scripts/disk_snapshot.sh` (checks the observer's last record age; > 5 min → the same C12 alert; test in `tests/test_snapshot_observer_watch.sh`), `scripts/main_sweeper.sh` (after the snapshot phase, iterate `class == null` catalog rows and run each whose last receipt is older than its `every_min`; receipts via `actuator_receipt.sh`), `scripts/lib/reclaim_catalog.py` (`every_min` on every non-class row, values from the §7.5 table; `apfs_snapshots` 360), `scripts/install_launchd_sweepers.sh` (`ABSORBED_LABELS=(…)` listing exactly the 18 labels; bootout only those; print the absorbed-by map with `old_interval → every_min`; **refuse** if any `old_interval < every_min`; `--restore-absorbed` re-installs the 18 templates from the previous package tree and is the W1 rollback), `scripts/check_launchd_fleet.sh` (expects exactly six labels), `systemd/` (same six), `CLAUDE.md` § "6-tier routine cleanup stack" (now "one table"), `README.md` job list
- Modify: `tests/test_install_launchd_sweepers.sh`, `tests/test_check_launchd_fleet.sh`, `tests/test_main_sweeper.sh` (create if absent)

**Step 1: Failing test** — (a) fleet check with a fixture `launchctl list` output containing a stale `com.disk-magician.colima-prune` → reports `stale_label`, rc 1; (b) installer dry-run prints `absorbed: downloads-evidence (21600s) -> routine every_min=360` for each deleted template and exits 1 if a fixture row sets `every_min: 1440` for a job whose template interval was 21600; (c) `main_sweeper.sh` with stub actuators runs a row whose receipt is 400 min old and `every_min` 360, skips one whose receipt is 100 min old, and runs no class rows (those belong to govern); (d) `--restore-absorbed` against a fixture previous package tree re-creates all 18 plists and loads them; (e) a label not in `ABSORBED_LABELS` is never booted out even if it carries the repo prefix.

**Step 2: Run** — fails.

**Step 3: Implement** — delete templates; installer `bootout` loop and interval assertion; main_sweeper row loop; fleet expectation list.

**Step 4: Run** — tests pass; on the dev host `bash scripts/install_launchd_sweepers.sh --dry-run` lists 18 bootouts, 6 loads, and no interval violation. Do **not** install from the worktree (deploy is Task A10).

**Step 5: Commit** — `refactor(launchd): six jobs; routine every 30 min; installer asserts no cadence regression`.

### Task A0 (P0): fix the `TempDir` leak in ez-gh-actions — a PR in that repo, first

**Repo:** `~/projects_other/ez-gh-actions`, worktree via `diskm worktree-new ~/projects_other/ez-gh-actions fix/test-tempdir-leak` under `~/.worktrees/ez-gh-actions/`. Authority: this repo's `CLAUDE.md` "Cross-repo authority" (disk-maintenance work in other repos needs no `APPROVE DIR SWITCH`). That repo's own merge gate applies.

**Files:** `src/lima_convergence.rs` `mod tests` (`short_tmp_root()`, `fake_home()`), plus its test module.

**Step 1: Failing test** — a Rust test that spawns a **child process** (the test binary with a filter for a helper test that calls `fake_home()` and sleeps), kills it with `SIGKILL` (dropping a thread's `JoinHandle` detaches, it does not abort — ChatGPT review), then asserts that `reap_orphans()` removes the leftover `ezgha-lima-*` dir; a second test keeps a child process alive with cwd inside its `fake_home()` and asserts `reap_orphans()` leaves that dir alone even when it is older than 1 h (mtime set back); plus a test that `fake_home()`'s root is `short_tmp_root()/ezgha-tests/`.

**Step 2: Run** — `cargo test -p ez-gh-actions lima_convergence::tests` fails (no `reap_orphans`, wrong root).

**Step 3: Implement** — `fake_home()` creates under `short_tmp_root().join("ezgha-tests")`, returns the `TempDir` guard (callers hold it for the test scope); `reap_orphans()` removes `ezgha-lima-*` siblings older than 1 h **that have no live owner** (no process with cwd or open file inside, checked right before removal) and is called at the top of each test in the module.

**Step 4: Run** — passes; then a manual proof recorded in the PR body: start `cargo test` for the module, `kill -9` it mid-run, run it again, `ls /private/tmp/ezgha-tests/` shows no leftover older than the run.

**Step 5: Commit, push, open the PR** in `ez-gh-actions` with the proof; link it from PR-A's body. After merge, the W1 propagation step (below) applies.

### Task A7: `tmp` tier reclaims orphaned `ezgha-lima-*` test tempdirs

**Files:**
- Modify: `scripts/cleanup_tmp.sh` (only the cause found in Step 0), `tests/test_cleanup_tmp_open_files.sh` or new `tests/test_cleanup_tmp_orphan_tempdirs.sh`

**Step 0: Measure the cause (read-only, on the dev host).** For five of the 57 `ezgha-lima-*` dirs aged 1–3 days: run `artifact_removal_verdict <dir>` and `artifact_live_cwd <dir>` from the worktree, and read the last `tmp` actuator receipt for that path. Record which of {`kept:lease`, `kept:open_file`, `kept:live_cwd`, `probe_failed`, never a candidate (depth/pattern filter), timeout before reaching it} applies. Write the result into the PR body. Do not guess.

**Step 1: Failing test** — fixture `/private/tmp`-shaped root under `mktemp -d` with an `ezgha-lima-1-2-abcdef` dir whose newest file is 26 h old, no open files, no live cwd, no lease: `cleanup_tmp.sh --clean` removes it and writes a receipt; the same dir 2 h old is kept; the same dir with a `sleep` cwd inside is kept with `kept:live_cwd`.

**Step 2: Run** — fails in the way Step 0 measured (or passes, in which case Step 0 found a scheduling cause: the tier never reached the dir within `STEP_TIMEOUT`; then the fix is ordering candidates by size descending in the tier, with the test asserting order).

**Step 3: Implement** the one cause. **Step 4: Run** — pass. **Step 5: Commit** — `fix(tmp): reclaim orphaned test tempdirs past the 24h tier (cause: <measured>)`.

### Task A8: Merge the three venv/dependency actuators into `worktree_deps` with per-class floors

**Files:**
- Modify: `scripts/cleanup_worktree_deps.sh` (adds `.venv`/`venv` as a dependency class with its own floor), `scripts/lib/reclaim_catalog.py` (`worktree_deps` row carries `age_days: {venv: 7, node_modules: 3, target: 3, .mypy_cache: 3}`; `cleanup_worktree_deps.sh` accepts `--min-age-class venv=7`), `scripts/disk_audit.sh` (drop the direct `reclaim_worktree_venvs.sh` call; the row covers it), `launchd/` (the `worktree-venvs` template is absorbed in A6)
- Delete: `scripts/cleanup_worktree_venvs.sh` and `scripts/reclaim_worktree_venvs.sh` (read both first; any behavior not in `cleanup_worktree_deps.sh`, such as a manifest proof or rebuildable check, is carried over before deletion and named in the commit); move their assertions into `tests/test_cleanup_worktree_deps.sh`

**Step 1: Failing test** — fixture worktrees under `mktemp -d`: a 5-day-dormant worktree's `.venv` is **kept**, an 8-day one's `.venv` is removed, a 4-day one's `node_modules` is removed, a 2-day one's `node_modules` is kept; `safety_worktree_floor_days` and `worktree_is_recently_active` are the only recency sources (grep asserts no `stat`/`find -mtime` proxy); a worktree with a live cwd is kept at any age.

**Step 2–5:** run (fails: no venv class, single floor), implement, run, commit `refactor(worktree-deps): absorb venv strip with a 7-day venv floor and 3-day dependency floor`.

### Task A9: Xcode DerivedData floor 7 → 2 days and per-producer reclaim reporting

**Files:** `scripts/lib/reclaim_catalog.py` (`xcode` row `age_days: 2` for DerivedData only; simulator caches unchanged), `scripts/lib/actuator_receipt.sh` (receipt already carries `bytes_reclaimed`; add `producer` = catalog key), `scripts/budget_status.py` (`diskm budget status --producers` prints per-producer bytes reclaimed for the last 24 h from receipts), `tests/test_budget_status.py`, `tests/test_cleanup_xcode.sh`.

**Step 1: Failing test** — a 3-day-old DerivedData project dir is removed and a 1-day one kept; `diskm budget status --producers` on a fixture receipts dir prints one line per catalog key with the summed bytes.

**Step 2–5:** run, implement, run, commit `feat(status): per-producer reclaim report; DerivedData floor 2 days`.

### PR-A close-out

Bump `pyproject.toml` (patch), `scripts/sync_package_tree.sh`, run the shared gates, `/cs`, `/advice`, open draft PR titled `refactor: table-driven reclaim, one probe, six launchd jobs, per-producer reclaim report [claude-code][claude-fable-5-1]` with the spec and the ez-gh-actions P0 PR linked and the line-delta opener. Merge needs `MERGE APPROVED` (prod delta > 150).

### Task A10: Deploy PR-A (after merge)

`git checkout origin/main` in a clean worktree, `tools/deploy_uv_tool.sh`, verify `~/.disk_magician_state/deployed.json` `version` matches `pyproject.toml`, `diskm check-launchd-fleet` → 6/6 (this runs `install_launchd_sweepers.sh`, which boots out the 18 absorbed labels and asserts no cadence regression). On `jeff-ubuntu`: `uv tool install --force --reinstall`, `systemctl --user daemon-reload`, six timers/services active. This is the deploy W1 needs; PR-C's Task C1 only re-deploys after PR-B.

### Window W1 (after PR-A merge and deploy, and the P0 PR merged in ez-gh-actions)

Deploy per Task A10. With the Task A0 PR merged in `ez-gh-actions`, propagate: list the **live** ez-gh-actions checkouts only (those with a running `cargo test` or `pi` process whose cwd is inside them: `artifact_live_cwd <checkout>` over `git -C ~/projects_other/ez-gh-actions worktree list` and `~/.worktrees/ez-gh-actions/*`), and for each one still lacking `reap_orphans` ask its lane owner (the `pi` agent on that branch, via the branch-ownership rule) to merge `main`. W1 starts when `grep -L reap_orphans <live>/src/lima_convergence.rs` prints nothing over that live set; dormant worktrees are not in the gate. W1 starts when the live set carries `reap_orphans`, or 48 h after the P0 merge, whichever comes first (a lane that has not merged by then is named in the report and its `ezgha-lima-*` bytes are counted separately). **Stop rule:** on any day whose minimum `df` Available is below 60 GiB, or when `daily_min_used` rises two days running, run `install_launchd_sweepers.sh --restore-absorbed` that day, halt W1, and write the report naming the producer from `diskm budget status --producers`. Then 7 days of daily evidence, all in `df` Available: min Available per day, max intraday Available swing, `ezgha-lima-*` count and max age, `diskm budget status --producers` (bytes reclaimed per producer), 30-day floor, `diskm check-launchd-fleet` 6/6. Write `roadmap/pilot-W1-2026-<mm-dd>-cut.md` with the spec §9 W1 table filled in. PR-B may be developed in parallel but is **not deployed** until this file exists.

---

## PR-B — doors (prod delta estimate: +180 / −20; installs nothing)

### Task B0: C11 decision id `external_edits` (D6, two user-owned files)

**Files:** `scripts/policy_provenance.py` (`IDS` gains `external_edits`), `tests/test_policy.sh`.
**Step 1: Failing test** — `diskm policy list` includes `external_edits`; `diskm policy approved external_edits` → rc 1 unrecorded. **Step 2–5:** run, add the id, run, commit `feat(policy): external_edits standing decision (git shim + settings.json)`.

### Task B1: `diskm setup --hooks` installs the C6 hook idempotently

**Files:**
- Modify: `disk_magician.sh` (`setup --hooks [--settings <path>]`), create `scripts/install_claude_hooks.py`
- Modify: `tests/test_disk_admission_hook.sh` (add installer cases)

**Step 1: Failing test** — against a fixture `settings.json` with the existing three disk hooks: after `setup --hooks --settings fixture`, the `PreToolUse` Bash array contains exactly one `hooks/disk-admission.sh` entry (installed `diskm` path), and running it twice leaves the file byte-identical; a fixture with `"hooks": {}` gets the array created; malformed JSON → rc 2, file untouched.

**Step 2–5:** implement (JSON load/dump, stable key order), run, commit `feat(setup): idempotent C6 hook installer`.

### Task B2: git shim admission call (ships as a patch file, applied only after D6)

**Files:**
- Create: `tools/guards/git.patch` (unified diff against the current `~/.local/bin/guards/git`, with the source file's SHA256 recorded in a header comment), `tools/guards/apply_git_admit.sh` (applies the patch only when `diskm policy approved external_edits` returns 0 **and** the live shim's SHA256 equals the recorded hash; otherwise prints the diff and the reason and exits 75; there is no flag that bypasses either check)
- Create: `tests/test_git_shim_admit.sh`

**Step 1: Failing test** — copy the shim to a temp dir, apply the patch, run `git worktree add ~/.worktrees/x/y` with a `DISK_MAGICIAN_ADMIT_BIN` stub for each rc: 0 → worktree created; 10 → warning line on stderr and worktree created; 75 → rc 75, `disk-admission: refused class=worktrees` on stderr, no worktree; 76 then 0 (stub returns 76 once, then 0; `DISK_MAGICIAN_ADMIT_RETRY_S=1`) → worktree created after one wait; 76 then 76 → rc 75, no worktree; stub missing → worktree created and an `admission_degraded:caller` line; `DISK_MAGICIAN_WORKTREE_GUARD=off` bypasses all.

**Step 2–5:** write the patch (call `admit_gate worktrees - git-shim "$dest" shim` after the placement check, sourcing `admit_caller.sh` from the installed package root, and branch on its rc per the matrix above, never a bare `|| exit 75`), run, commit `feat(doors): git shim admission patch (apply after D6)`.

### Task B3: ezgha job-started wiring and CI class fix

**Files:**
- In `ez-gh-actions` (separate PR, same cross-repo authority as Task A0): add `diskm ci-admit` to the runner's job-started hook; link the PR from PR-B.
- Modify: `scripts/ci_admit.sh` (`--class tmp_containers` for the workspace birth; `--class colima` only for the image-pull estimate; on rc 76 the hook itself sleeps `retry_after_s` once and re-admits, because a non-zero hook exit fails the job in the runner, so a job is delayed, never failed, by a 76; rc 75 exits 75 and the job fails with the refusal line as its first stderr line), `tests/test_ci_admit.sh` (cases: `GITHUB_WORKSPACE` under `/private/tmp/...` classifies as `tmp_containers`; est from the calibrated producer estimate when `CI_ADMIT_EST_GB` is empty; stub 76-then-0 → rc 0 after one wait; stub 76-then-76 → rc 75).

**Step 1–5:** failing cases, run, implement, run, commit `feat(doors): ezgha job-started admission patch; ci_admit charges tmp_containers`.

### Task B4: Why the existing Colima overage row is not firing (diagnosis first)

**Step 0: Measure (read-only).** From `~/.disk_magician_state/budget.json` (`classes.colima.used_gb`, `measured_at`) and the govern receipts for the last 7 days, tabulate per tick: zone, colima `used_gb`, budget (30), `fresh`, and whether `eligible_actuators` listed `colima` (`class_stale:colima` reason or not). State the cause in one line: threshold (used_gb ≤ 30 while the datadisk swings 10–42 GiB), staleness, or an activation block. Put the table in the PR body.

**Step 1: Failing test** — the test that encodes the measured cause: for threshold, `tests/test_budget_controls.py` asserts the shipped `config.json.template` colima budget makes a 25 GiB measurement eligible; for staleness, `tests/test_govern_reconcile_measure.py` asserts the colima measure runs at least every 2 h.

**Step 2–5:** run, change the one thing (budget value or measure cadence; no new trigger code), run, commit `fix(govern): Colima overage row fires (cause: <measured>)`.

### Task B5: RED alert names the pause command (extends C12, no new event)

**Files:**
- Modify: the existing C12 RED alert text in `scripts/budget_status.py` / `scripts/sweeper_health_check.sh` (one added line: top class by overage and its pause command), `tests/test_budget_alerts_extra.py`

**Step 1–5:** failing test (RED alert text contains `pause: <cmd>` for the top-overage class; no new event type appears in `events.jsonl`), implement, run, commit `feat(alerts): RED alert names the producer pause command`.

### PR-B close-out

Version bump, sync, gates, `/cs`, `/advice`, draft PR `feat: admission doors — hook installer, git shim patch, CI class fix, Colima overage diagnosis [claude-code][claude-fable-5-1]`. Body states that nothing is installed, lists the `external_edits`-gated install commands, and links the ez-gh-actions job-started PR.

---

## PR-C — activate and window W2 (no code; evidence PR)

Preconditions: PR-A merged and deployed, the P0 PR merged in ez-gh-actions, **W1 written up**; PR-B merged; user has said the literal phrases for **D2** (`admission_enforcement`) and **D6** (`external_edits`, git shim + settings.json), optionally **D1b** (`worktree_cleanup`). Each step below that needs a decision is marked and must not run without it.

### Task C1: Deploy PR-B
Same procedure as Task A10 for the PR-B head; fleet stays 6/6.

### Task C2: Record decisions (user-only)
`diskm policy approve admission_enforcement --phrase '<user text>' --from-transcript <session.jsonl>`; same for D6 and, if given, D1b. `diskm policy list` shows them with `approved_at`.

### Task C3: Install doors (needs `external_edits` recorded)
`diskm setup --hooks`; `tools/guards/apply_git_admit.sh` (refuses unless `diskm policy approved external_edits` and the shim hash matches); the job-started PR in `ez-gh-actions` (Task B3) merged and the runner supervisor restarted. Verify: one `git worktree add` from a plain shell produces an `admit` event with `source=shim`; one Claude Bash `git clone` produces `source=hook`; the next CI job produces `source=ci` with `class=tmp_containers`.

### Task C4: Window W2 evidence (7 days)
Daily, in `df` Available: min per day, max intraday swing; plus `admission/events.jsonl` counts by source and decision, `floor_breach` count, Colima datadisk swing, `diskm budget status --producers`, fleet check 6/6. Write `roadmap/pilot-W2-2026-<mm-dd>-doors.md` with the spec §9 W2 table filled in from measurements and the W1 numbers alongside. If Available drops below the W2 target on any day, attribute it from the ledger and the per-producer reclaim report before changing any threshold; do not loosen floors.

### Task C5: Budgets (needs D3, after the pilot)
Record `budgets`; flip non-emergency rows from `warn` to `refuse_red`. Close beads `disk_magician-master-space-saving-roadmap-bv8p` items that the pilot resolved; open one bead per unresolved producer.

---

## TDD plan step check (self-review)

- Every code task starts with a failing test that names its file and its assertion, runs it, implements, reruns.
- No task writes application-side heuristics; classification stays in the table and in C14 (deterministic safety invariants).
- No task edits `~/.local/bin/guards/git` or `~/.claude/settings.json` until Task C3, gated on the recorded C11 decision `external_edits`, which the installers check themselves with no bypass flag. `ez-gh-actions` changes are ordinary PRs in that repo under this repo's cross-repo authority.
- No task adds a trigger table or dispatcher beside `eligible_actuators()`; Task A4 adds one key to the existing class config.
- No task collapses the admit exit codes to `|| exit 75`; every call site branches on 0/10/75/76/other.
- The shared argument parser is not in PR-A (PR-D, after the pilot).
- Task A7 Step 0 measures before fixing; the commit message names the measured cause.
- No task changes an observe default to refuse; Task C2 is the only activation and is user-performed.
- PR count: 3 (`pr-quantity-control` ≤ 3 per scope). No stacked chain.
