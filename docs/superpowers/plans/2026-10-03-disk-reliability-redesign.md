# Disk reliability redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make disk reliability status truthful across measurement quality,
publication, scheduled-job outcomes, safety decisions, and deployed identity
while retaining the existing strict ledger and cleanup architecture.

**Architecture:** Extend the current snapshot/renderer provenance contract,
add a dedicated partial comparator, and add typed atomic receipts through a
small helper used by existing jobs. Join those artifacts with current fleet,
freshness, template, root-registry, safety, and deploy checks in a read-only
status command. The complete ledger remains the only strict floor; partial
comparisons remain explicitly partial.

**Tech Stack:** Bash, Python 3 standard library, macOS `launchd`/`launchctl`,
existing JSON state files, existing shell test harness, and the repository's
package mirror/deploy scripts. No dependency or new service.

---


## Authorized execution contract — October 3, 23:02 UTC

The user has now authorized implementation of this redesign and the audit's
safety fixes, parallel agents, `/nextsteps`, and merging the reviewed scoped
work into `origin/main`. This supersedes this document's earlier planning-only
boundary; it does not authorize unrelated cleanup, deletion of protected
state, force-push, or weakening existing safety gates. Root owns integration
and merge. Preserve `AGENTS.md` as the existing symlink to `CLAUDE.md`.

Implementation includes the SQLite checkpoint/concurrent-client fix, per-run
Dark Factory candidate checks, and wiki-publish lifecycle protection identified
in the audit. Reuse existing handlers and candidate guards; add no alternate
cleanup runner. Older relevant branches must be inspected for reusable
implementations, especially partial ledger publication, before new code.

### Five binary exit criteria

Each criterion requires an independent agent to re-execute the checks against
the final committed revision, record that revision and raw output, and compare
the installed/runtime state where applicable. A worker report alone is not
proof. Fixture results and live results remain distinct.

| Criterion | Executable checks | External anchor / independent verifier |
|---|---|---|
| C1: One CLI and one policy source | `test "$(readlink AGENTS.md)" = CLAUDE.md`; after installation `diskm --help` and `disk-magician --help`; compare both command outputs and run dispatch tests through the installed console entry point | Actual packaged executables and filesystem symlink; verifier other than CLI author |
| C2: Honest accounting and outcomes | `python3 -m unittest discover -s tests -p 'test_*.py' -v`; `bash tests/test_snapshot_commit.sh`; `bash tests/test_sweeper_health.sh`; installed `diskm status --json` and `diskm growth-top10 --json` checked against actual source artifacts, with missing/stale data explicitly unknown | State repo, published partial/complete artifacts and actual scheduled receipt; independent accounting verifier |
| C3: Cleanup guards and SQLite results are real | `bash tests/test_cleanup_codex_db.sh`; `bash tests/test_cleanup_dark_factory.sh`; `bash tests/test_cleanup_safety.sh`; reproduce a busy WAL reader using real disposable SQLite databases; invoke installed cleanup CLI only in preview against live state | Actual sqlite3 rows and retained fixture paths, plus installed CLI preview; independent safety verifier; no live destructive test |
| C4: Reviewed revision is merged and deployed | `git fetch origin main`; `git merge-base --is-ancestor HEAD origin/main`; `bash scripts/sync_package_tree.sh --check`; from a clean exact-main checkout `bash tools/deploy_uv_tool.sh --check`, guarded deploy, installed version/file hashes and a later scheduled outcome | GitHub merged state, origin/main, installed package bytes and scheduler process/artifact; root plus independent deployment verifier |
| C5: Follow-through is complete and evidence claims are bounded | `br --no-auto-flush show disk_magician-disk-fill-prevention-scheduled-cleanup-q6l --json`; read required nextsteps, home learnings and activity artifacts; compare final status with raw checks and current refs | Canonical tracker plus durable roadmap; independent final scope audit |

The existing test commands, CLI help, symlink and deployment preflight source
were inspected before this contract. New `diskm status`/`growth-top10` commands
are expected absent until implemented; their JSON flags and integration checks
are explicit implementation requirements, not claims about the current binary.
The complete-ledger floor may remain unavailable: success is truthful partial
publication and explicit degradation, never fabricating a floor. Twenty-four-hour
and seven-day recurrence observations are durable follow-up windows; the
implementation goal can close only with those limits reported and owned, never
with a claim that recurrence prevention was already demonstrated.

### Execution lanes and timeline

Estimated elapsed windows from 23:02:48Z: preparation and independent plan
review 0–20 minutes; parallel bounded implementation 20–80 minutes; integrated
independent verification 80–120 minutes; merge and guarded deployment 120–150
minutes, revised when evidence changes. Three worker slots plus root are the
runtime ceiling; initial available RAM was 9.17 GiB at pressure level 2.

- Lane A owns renderer/history partial publication and comparison internals.
- Lane B owns cleanup safety and SQLite checkpoint handling.
- Lane C owns receipt/status internals and later deployment identity.
- Root sequences shared CLI/package/template integration through a bounded
  delegated unit after interfaces stabilize; workers do not edit shared files.
- One independent verifier re-executes final checks after integration. Pair
  coding transports keep separate author and verifier contexts.

Use isolated source worktrees, explicit owned paths and explicit staging.
Commit every completed green unit within 30 minutes. Report milestones at
+20, +40 and +60 minutes (hourly rollup), then every 20 minutes. Start remains
2026-10-03T23:02:48Z; authorization expires 2026-10-04T07:02:48Z unless renewed
by a live human message. Independent `/advice` plan approval is required
before implementation; this is a workflow gate distinct from the user's
scoped implementation authorization.

## Preconditions and sequencing

1. Use the authorized clean isolated source state. Do not borrow old approvals,
   PR claims, or deployment status.
2. Reconcile Beads `q6l`, `i2o`, `d45`, `zyn`, `4y6`, `mfq`, `s62`, `371`, and
   `asb`; update existing items only when authorized. Do not create a duplicate
   epic.
3. Re-pin the source head, installed package, launchd templates, and current
   state paths with `git rev-parse HEAD` and `git status --short`. Use
   `/tmp/disk-redesign-20261003-baseline.json` and
   `/tmp/disk-redesign-20261003-daily-coverage.json`. The earlier 88b6bff
   review is historical context; the integration head must be measured again
   before each verification round. Preserve unrelated staged and untracked files.
4. Perform bounded fixture and read-only checks; do not run an unbounded live
   scan. Live cleanup activation remains behind the safety task and C4.
5. Resolve `diskm` as a packaged additional name for the same
   `disk_magician.cli:main` implementation. Current runtime remains
   `disk-magician` until the packaged name is installed; do not create a shell
   alias or second dispatcher.

## Task 1: Freeze the structural contract with adversarial fixtures

**Files:**

- Modify: `scripts/history_diff.py` only where shared validation contracts are
  needed.
- Modify: `scripts/render_topdown_ledger.py` to publish the separate partial
  artifact while preserving the complete-ledger gate.
- Test: `tests/test_history_diff.py`
- Test: `tests/test_render_topdown_ledger.py`
- Test: `tests/test_snapshot_carry_forward.py`
- Test: `tests/test_snapshot_coverage_fields.sh`

**Step 1: Add RED fixtures.** Add fixtures for a complete ledger, partial
envelope, mismatched scope, stale current/floor, missing, carried, unmeasured,
parent/children partition, and overlap. Assert partial data cannot publish the
canonical ledger.

**Step 2: Run the focused RED checks.**

Run: `python3 -m pytest -q tests/test_history_diff.py tests/test_render_topdown_ledger.py tests/test_snapshot_carry_forward.py`

Expected: new partial/publication cases fail while complete and carry-forward
behavior retains its baseline.

**Step 3: Implement the minimum contract.** Extend
`scripts/render_topdown_ledger.py` to atomically write
`ledger/topdown-5g.partial.json` with run/time, scope, coverage, measured
buckets, unfinished frontier, residual, and non-canonical status; preserve the
complete-only gate for `ledger/topdown-5g.json`. Keep strict validation and
sidecar behavior; do not change `compute_deltas` for partial inputs.

**Step 4: Run the focused GREEN checks.**

Run: `python3 -m pytest -q tests/test_history_diff.py tests/test_render_topdown_ledger.py tests/test_snapshot_carry_forward.py`

Expected: PASS for complete/carry-forward and partial publication contracts.

## Task 2: Implement the explicit partial comparator

**Files:**

- Create: `scripts/partial_history_diff.py`
- Create: `tests/test_partial_history_diff.py`
- Create: `scripts/growth_top10.py` and `tests/test_growth_top10.py` as the
  thin partial-current reader over existing floor/history logic.
- Modify: `scripts/sync_package_tree.sh` only if its existing `scripts/*.py`
  glob requires a documented package mirror adjustment.
- Mirror: `src/disk_magician/scripts/partial_history_diff.py` through the
  existing sync mechanism, never by hand.

**Step 1: Write RED tests.** Cover exact-path numeric deltas, unknown-not-zero,
same-scope requirements, stale-current and stale-floor reasons,
parent-to-children reconciliation, child-to-parent reconciliation, overlap
rejection, carried/unmeasured provenance, unknown interval/non-numeric output,
and the rule that no partial result writes `ledger/topdown-5g.json`.

**Step 2: Run RED.**

Run: `python3 -m pytest -q tests/test_partial_history_diff.py tests/test_growth_top10.py`

Expected: FAIL because the module and comparator contract are absent.

**Step 3: Implement the minimum comparator.** Canonicalize paths, compare
scope and quality envelopes, match exact paths, reconcile proven partitions,
and return explicit unknown records for anything unmatched or overlapping.
Return a typed result with `comparison_kind`, `reason`, `deltas`, `unknown`,
and both coverage envelopes. Add `growth_top10.py` as a thin reader that
reports the actual measured interval and refuses a missing/stale strict floor.
Carried values are provenance, not new current deltas; unknown interval or
freshness remains non-numeric. Do not call `history_diff.compute_deltas` for
partial data.

**Step 4: Run GREEN and mirror checks.**

Run: `python3 -m pytest -q tests/test_partial_history_diff.py tests/test_growth_top10.py`

Run: `bash scripts/sync_package_tree.sh`

Run: `bash scripts/sync_package_tree.sh --check`

Expected: both pass after the source file is mirrored. If `--check` reports
pre-existing unrelated drift, record it and stop before altering those files.

## Task 3: Add atomic typed job receipts

**Files:**

- Create: `scripts/job_receipt.py`
- Create: `tests/test_job_receipt.py`
- Modify first: `scripts/snapshot_commit.sh`, `scripts/pressure_sweep.sh`, and
  `scripts/tmp_scratch_sweep.sh`; expand only after their fixtures pass.
- Mirror: `src/disk_magician/scripts/job_receipt.py` through
  `scripts/sync_package_tree.sh`.

**Step 1: Write RED tests.** Test started-without-terminal remains unknown;
all seven terminal outcomes; skipped lock; skipped threshold/no-op; blocked
safety; timeout/error; atomic writer crash; bounded retention; independent
lock/current-writer fields; and no false zero freed when terminal evidence is
missing.

**Step 2: Run RED.**

Run: `python3 -m pytest -q tests/test_job_receipt.py`

Expected: FAIL because the helper and receipt schema are absent.

**Step 3: Implement the narrow helper.** Use only Python standard library
JSON, temporary-file, flush/fsync, and atomic rename operations. Validate the
fixed outcome enum and required timestamps. Store state under the existing
`DISK_MAGICIAN_STATE_DIR` convention, with a test override. Retain at most 64
completed summaries and two active/started records per job; keep started,
success, and skipped records independently addressable so a contender's skip
cannot overwrite an active or successful receipt. Do not add a cleanup script.

**Step 4: Run GREEN.**

Run: `python3 -m pytest -q tests/test_job_receipt.py`

Expected: all schema, crash, and unknown-not-zero cases pass.

**Step 5: Wire the three named jobs.** Begin before work, publish terminal
receipt after postcondition, and preserve safety gates. Add lock skip,
threshold skip, safe no-op, and success cases. Expand only after these fixture
contracts are green.

**Step 6: Run job regressions.**

Run: `bash tests/test_snapshot_commit.sh`

Run: `bash tests/test_pressure_sweep.sh`

Run: `bash tests/test_tmp_scratch_sweep.sh`

Run: `bash tests/test_sweeper_health.sh`

Expected: existing behavior remains intact and each exercised path emits a
typed receipt in the fixture state directory.

## Task 3b: Close cleanup safety defects before activation

**Files:** `scripts/cleanup_codex_db.sh`, `tests/test_cleanup_codex_db.sh`,
`scripts/cleanup_agent_artifacts.sh`, `scripts/cleanup_dark_factory.sh`,
`tests/test_cleanup_dark_factory.sh`, `scripts/cleanup_dev_caches.sh`, and a
`tests/test_cleanup_wiki_publish.sh`.

**Step 1: Write RED disposable concurrency fixtures.** Test that every SQLite
operation applies `busy_timeout`, each database has a single-maintainer lease,
active open clients are handled conservatively, and every `wal_checkpoint`
result row is parsed, including an exit-0 `busy` row. Verify poststate and
classify busy or incomplete work as non-success. Use real concurrent reader and
writer processes against disposable temporary databases; never delete a
database.

**Step 2: Run the focused safety tests.** Run
`bash tests/test_cleanup_codex_db.sh` and the existing cleanup safety tests;
the new concurrency cases must be RED before their implementation.

**Step 3: Implement the smallest safe fixes.** Keep the database path
non-destructive; delegate Dark Factory handling to
`cleanup_dark_factory.sh`, remove the duplicate `~/.dark-factory/runs` target,
and prove the canonical guard and per-candidate safety logging. Remove
automatic wiki-publish deletion until lifecycle provenance is known; retain
unknown, active, recent, and protected entries without inventing producer
markers. Do not add an ad-hoc cleaner.

**Step 4: Run GREEN.** Run `bash tests/test_cleanup_codex_db.sh`,
`bash tests/test_cleanup_dark_factory.sh`, `bash tests/test_cleanup_safety.sh`,
and `bash tests/test_unify_routine_cleanups.sh`. Fixture output must show no
database deletion and no unguarded candidate deletion.

**Step 5: Hold activation.** Do not enable scheduled `--clean` execution
until these tests pass and the independent verifier records their output.

## Task 4: Derive inventory from existing templates and registries

**Files:**

- Modify: `scripts/check_launchd_fleet.sh` only to consume or cross-check the
  template-derived labels without changing its read-only exit contract.
- Modify: `scripts/install_launchd_sweepers.sh` only if a shared parser can be
  reused without changing install behavior.
- Modify: `config/sweeper_roots.txt` and `scripts/lib/scratch_roots.sh` only
  for the existing root-owner and coverage entries.
- Modify: `pyproject.toml` to include `config/*.txt` as package data, so the
  installed fleet inventory and sweeper roots are present.
- Create: `tests/test_job_inventory.sh`
- Test: `tests/test_check_launchd_fleet.sh`
- Test: `tests/test_install_launchd_sweepers_preflight.sh`
- Test: `tests/test_package_sync.sh` and `tests/test_deploy_uv_tool.sh`

**Step 1: Write RED drift tests.** Assert every installed job template has a
label, entrypoint, execution kind, receipt owner, and coverage owner; assert
the compatibility list has no missing or extra labels; assert scratch and
sweeper roots expose an owner and safety policy. Use fixture templates, never
live deletion.

**Step 2: Run RED.**

Run: `bash tests/test_job_inventory.sh`

Expected: FAIL until the inventory join is implemented.

**Step 3: Implement the smallest parser/join.** Reuse current extraction for
Apple templates because `plistlib` may reject comments that `plutil -lint`
accepts; test native and non-macOS fixtures. Do not add a JSON registry.
Preserve specialized worktree, never-delete, scratch, and safety behavior.

**Step 4: Run GREEN.**

Run: `bash tests/test_job_inventory.sh`

Run: `bash tests/test_check_launchd_fleet.sh`

Run: `bash tests/test_install_launchd_sweepers_preflight.sh`

Run: `bash tests/test_package_sync.sh`

Run: `bash tests/test_deploy_uv_tool.sh`

Expected: all pass, including malformed plist and missing-label protections.

## Task 5: Add the read-only status command

**Files:**

- Modify: `disk_magician.sh` to dispatch `status` without cleanup or repair.
- Create: Python 3 standard-library `scripts/disk_status.py`.
- Create: `tests/test_cli_reliability.py`
- Create: `tests/test_disk_status.py`

**Step 1: Write RED fixtures.** Provide fixture outputs for healthy, stale
ledger, partial coverage, missing receipt, interrupted started receipt,
wrong-package identity, malformed plist, safety-blocked action, and non-macOS
launchd-unavailable cases.

**Step 2: Run RED.**

Run: `python3 -m unittest discover -s tests -p 'test_disk_status.py' -v`

Expected: FAIL because `status` is not yet a dispatch command and dimensions
are not joined.

**Step 3: Implement the read-only join.** Print each dimension independently,
its source timestamp/path, typed state, and owner. Exit 0 only when required
dimensions are healthy; exit 1 for degraded/unknown; exit 2 for unreadable or
invalid status inputs. Do not call install, cleanup, repair, deploy, or
publication commands.

**Step 4: Run GREEN.**

Run: `python3 -m unittest discover -s tests -p 'test_disk_status.py' -v`

Run: `python3 -m pytest -q tests/test_disk_status.py`

Expected: healthy fixtures exit 0 and every degraded/unknown fixture exits
nonzero with the correct dimension, without a mutation.

**Step 5: Wire through the canonical packaged entry point and scoped
scheduler templates.** Add the packaged `diskm` name in `pyproject.toml`
pointing to the same `disk_magician.cli:main`, then add installed dispatch and
`--help` tests for `status`, `growth-top10`, and receipt/status paths. Route
the existing pressure-sweep, tmp-scratch-sweep, cleanup-claude-state, and
codex-vacuum helpers through that dispatch. Add a `frontier-nightly` dispatch
that executes the existing `disk_frontier_scan.sh` wrapper (the existing
`frontier` direct-Python command is not equivalent). Update these exact templates to
use stable `@HOME@/.local/bin/diskm` with identical arguments and environment:

- `launchd/com.jleechanorg.disk-magician-frontier-nightly.plist.template`
  (nightly frontier wrapper consumer)
- `launchd/com.jleechanorg.disk-magician-pressure-sweep.plist.template`
- `launchd/com.jleechanorg.disk-magician-tmp-scratch.plist.template`
- `launchd/com.disk-magician.claude-state.plist.template`
- `launchd/com.disk-magician.codex-vacuum.plist.template`
- `launchd/com.jleechanorg.disk-magician-drilldown.plist.template`
  (Task 7 uncovered-root alert owner; route through `diskm residual-drilldown`
  so the deployed helper actually reaches its scheduled caller)

Update the snapshot plist writer in `disk_magician.sh`
`run_setup()` (the measured interval is 1,800 seconds) to use the same stable installed `diskm snapshot` entry
point, preserving its schedule and environment. Include both installer paths
in the dispatch fixture tests.

Keep `disk_status.py`, `growth_top10.py`, and receipt helpers private behind
the CLI. Use the existing `disk-magician` command until the packaged `diskm`
installation check proves the additional name is registered; do not create a
shell alias, second dispatcher, or independent runner. Other root consumers
remain inventory findings until a later dispatch migration is explicitly
scoped; this task does not claim all jobs are migrated. Validate with
`bash tests/test_install_launchd_sweepers_preflight.sh`,
`bash tests/test_package_sync.sh`, and `bash tests/test_deploy_uv_tool.sh`.

## Task 6: Reuse the existing deployment guard and package mirror

**Files:**

- Modify: `tools/deploy_uv_tool.sh` only for the verified deployed receipt
  fields and atomic record behavior.
- Modify: `pyproject.toml` for the monotonic version bump.
- Test: `tests/test_deploy_uv_tool.sh`
- Test: `tests/test_package_sync.sh`
- Modify: `CLAUDE.md` only if its deployment paragraph still names a bare
  `uv tool install`; route it through the existing guard.

**Step 1: Add RED tests.** Cover wrong source SHA, wrong installed package,
missing package file, installed timestamp without receipt, atomic deployed
record replacement, and source-revert/version-bump rollback evidence. Keep
branch override behavior unchanged and explicit.

**Step 2: Run RED.**

Run: `bash tests/test_deploy_uv_tool.sh`

Expected: new receipt assertions fail while existing dirty-tree and package
diff protections remain covered.

**Step 3: Bump the monotonic version and implement the new post-verification record**
`~/.disk_magician_state/deployed.json` only after all existing checks pass. A
prior receipt is evidence, not proof rollback succeeded. Do not deploy or
grant a branch override during this task.

**Step 4: Run GREEN and mirror checks.**

Run: `bash tests/test_deploy_uv_tool.sh`

Run: `bash tests/test_package_sync.sh`

Run: `scripts/sync_package_tree.sh`

Run: `bash scripts/sync_package_tree.sh --check`

Expected: the monotonic package version is bumped, root/package copies are
synced, `--check` reports zero drift, and source/package identities are tested.

## Task 7: Complete scoped enablement and scheduled postconditions

**Files:**

- Modify only the files named by the reconciled existing Beads for enablement,
  producer migration, codesign scheduling, and safety preflight.
- Test: the owning existing tests, plus receipt/status fixtures from Tasks 3
  and 5.

**Step 1: Recheck ownership and safety.** Confirm the live owner and exact
   target for each Bead. Run the repository safety preflight and use temporary
   fixture trees for destructive-path tests.

**Step 2: Add RED enablement assertions.** Assert the scheduled invocation,
   deployed revision, postcondition receipt, and coverage publication are
   joined. Do not count a plist load or touched log as invocation proof.

**Step 3: Implement only authorized enablement.** Route scheduled jobs through
   the existing templates and deploy guard. Preserve clean-main, worktree
   seven-day, never-delete, and safety rules.

**Step 4: Run focused GREEN checks.**

Run: `bash tests/test_pressure_sweep.sh`

Run: `bash tests/test_install_launchd_sweepers_preflight.sh`

Run: `bash tests/test_deploy_uv_tool.sh`

Expected: focused checks pass and a fixture scheduled invocation has a typed
postcondition receipt.

## Task 8: Observational acceptance, last and once

**Files:**

- Create: an ignored evidence directory under `/tmp`, with raw status,
  receipt, coverage, publication, and deployed identity captures.
- Do not add production fixtures or cleanup scripts.

**Step 1: Run the fixture suite as the final code check.**

Run: `python3 -m pytest -q tests/test_history_diff.py tests/test_render_topdown_ledger.py tests/test_snapshot_carry_forward.py tests/test_partial_history_diff.py tests/test_growth_top10.py tests/test_job_receipt.py tests/test_disk_status.py`

Run: `python3 -m unittest discover -s tests -p 'test_disk_status.py' -v`; then `bash tests/test_deploy_uv_tool.sh` and `bash tests/test_package_sync.sh`.

Expected: all focused checks pass before any costly observation.

**Step 2: Observe passive existing scheduled telemetry.** Across restart and
sleep where feasible, capture raw receipts and status. Each active execution
obeys the eight-hour authorization window; later sessions may collect
accumulated 24-hour/seven-day receipts. Record pending windows as pending;
never fabricate a run from a launchd interval or log mtime.

**Step 3: Run the initial 24-hour watch.** Report counts of healthy,
degraded, and unknown dimensions plus exact artifact paths. A 24-hour watch
is initial evidence only.

**Step 4: Complete the seven-day recurrence observation.** Report whether the
recurrence contract held, with producer growth, coverage, action outcomes, and
deployed identity. Until this window exists, status remains pending/partial.

## Rollback

Disable new status/reporting consumers while preserving existing cleanup and
snapshot behavior. Roll back source through a normal revert in an isolated
checkout, bumping the monotonic version and using the existing clean-main
release/deploy path. A prior deployed receipt is evidence only; never claim
rollback by restoring its JSON alone.

## Supersession map

| Existing artifact | Relationship |
|---|---|
| `docs/superpowers/specs/2026-09-11-ledger-fresh-and-queryable-design.md` and plan | Retain strict freshness and complete-only publication; add the separate partial comparator and status join. |
| `docs/superpowers/specs/2026-09-11-fleet-is-real-again-design.md` and plan | Retain fleet liveness and read-only semantics; status adds independent measurement/publication/receipt/deploy dimensions. |
| `docs/superpowers/specs/2026-09-11-deploy-guard-design.md` and plan | Reuse `tools/deploy_uv_tool.sh`; add durable verified receipt fields, never a second deploy path. |
| `docs/superpowers/specs/2026-09-23-disk-fill-prevention-and-scheduled-cleanup-design.md` and plan | Reconcile the open producer/enablement/registry Beads; do not duplicate the epic or claim historical PRs are live. |
| `docs/superpowers/specs/2026-10-03-snapshot-timeout-reliability-design.md` and plan | Reuse fresh/carried/unmeasured fields and frontier provenance; do not reinterpret them as complete history. |

## Anti-gaming acceptance checks

- A touched log with no terminal receipt is unknown.
- A loaded plist with stale publication or deployed identity is degraded.
- A pending launchd interval is not a run.
- A partial result cannot overwrite the complete ledger or establish a floor.
- Missing paths and expired carry-forward are unknown, never zero.
- Parent/child partition and overlap cases cannot create artificial deltas.
- A writer crash leaves the previous valid artifact and an observable unknown
  started receipt.
- A wrong package or mixed root/uv revision fails status.
- Safety refusal, unmeasurable recency, and protected paths produce no delete.
- Fixture success, 24-hour observation, and seven-day recurrence remain
  separately labeled.

## Review record

The first canonical `/advice` round returned CHANGES REQUESTED. The revised
plan was independently approved by Codex and Opus on October 3 at
23:22 UTC. The [round-two review record](https://gist.github.com/jleechan2015/67557ce3d89624b3b9e0c0a20db90da1)
contains the exact source pin, coverage statement, reviewer outputs, and
runner receipt. This approval covers the implementation plan, not the final
code or deployed behavior. The optional browser review could not attach to
the existing browser because the browser transport timed out; no external
submission or browser verdict is claimed.

Execution corrections from inspected code: the snapshot writer is
`run_setup()` with a 1,800-second interval. Status behavior is covered by
`tests/test_disk_status.py`; shell/installed dispatch is covered by
`tests/test_cli_reliability.py`, without a duplicate status shell harness.

## Final self-review checklist

- [x] Every architectural component has exact source/test paths.
- [x] Every task has RED, GREEN, and command-level exit evidence.
- [x] The plan does not require a new dependency, daemon, database, or scanner.
- [x] Package mirror and two deployment consumers are explicit.
- [x] Existing safety and seven-day rules remain in force.
- [x] Live observation is last, bounded, and cannot be faked by timestamps.
- [x] Implementation is authorized within the named tasks; deployment, cleanup
  activation, merge, and push remain behind their explicit safety and C4 gates.
- [x] All design decisions and evidence limitations are explicit.
