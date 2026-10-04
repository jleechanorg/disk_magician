# Disk reliability redesign

Date: 2026-10-03  
Status: Implementation authorized by the user on October 3 at 23:02 UTC; see the execution contract in the implementation plan. Earlier planning-only statements describe the original /sq invocation. Safety and destructive-action gates remain in force.

## Goal and current boundary

The disk fills again because operational signals say that scheduled jobs ran
while useful measurement, cleanup outcomes, and deployed identity remain
uncertain. This design makes those dimensions observable and fail closed while
preserving the existing scanner, snapshot, ledger, launchd, safety, and deploy
paths. It is an evolutionary consolidation, not a scanner replacement, new
daemon, database, rewrite, or LLM classifier.

The supplied 30-day audit (2026-09-03 through 2026-10-03) contains 23 daily
observations across 29 days below 70% coverage, 984 commits, and zero canonical
ledger updates. Therefore there is no valid strict 14-day floor. Evidence is
recorded in `/tmp/disk-redesign-20261003-baseline.json` and
`/tmp/disk-redesign-20261003-daily-coverage.json`. The supplied deployment
evidence says snapshot scripts match version 0.2.124, but the installed copy
was recorded at 22:37Z and the latest low-coverage snapshot at 22:19Z
predates it; this evidence does not assign failure to the new snapshot fix.
The initial baseline HEAD is
[5e75836d3380979fa0cb1e3fc650f20ea64925bd](https://github.com/jleechanorg/disk_magician/commit/5e75836d3380979fa0cb1e3fc650f20ea64925bd)
(prod +1375/-155 including package mirrors; non-prod +1144/-6). Verification
then advanced to the historical review context `88b6bffb3da191834f68979abd932e936d29d2b6`
at 22:46Z with reviewed file hashes unchanged. Before implementation or each
verification round, re-pin the actual source with `git rev-parse HEAD` and
`git status --short`; do not treat that historical SHA as the current head.
At the original review snapshot, the pre-existing production work was
committed and these planning documents were untracked. The documents are now
tracked and implementation is authorized. Production activation, heavy scans,
and multi-hour validation remain governed by the safety tasks and five exit
criteria.

## Failure contract

Every report must keep these dimensions independent:

| Dimension | Healthy evidence | Degraded or unknown evidence |
|---|---|---|
| Fleet | all expected plists lint, expose `Label`, and are loaded | missing, malformed, or unloaded job |
| Measurement | fresh values and explicit run/provenance fields | carried, unmeasured, timed out, stale, or partial |
| Publication | a current artifact was atomically published | only a sidecar/status artifact changed, or publication is stale |
| Action outcome | typed terminal receipt with postcondition | started without terminal receipt, skipped, blocked, timeout, or error |
| Deployed identity | source revision, package revision, and deployed receipt agree | log changed or installed timestamp changed without identity proof |
| Safety | existing safety gates prove candidate eligibility | a path is unmeasurable, protected, young, in use, or rules unreadable |

The status command reports each dimension separately and returns nonzero when
any required dimension is degraded or unknown. A green log timestamp, loaded
plist, or already-installed package is never sufficient by itself.

## Invariants

The complete fresh full-attribution ledger alone supplies strict floors and
canonical bucket deltas. Partial comparisons require matching scope, quality,
and accounting; missing/expired values are unknown, never zero, and changing
parent/child partitions or overlaps cannot create deltas. Started jobs without
terminal receipts remain unknown, including after crash or sleep; lock skips
are typed independently. Receipts are atomic and bounded. Existing safety
modules, the seven-day worktree floor, never-delete list, and package sync
remain authoritative and are not weakened.

## Chosen architecture

### 1. Structural contract and partial comparison

Extend the existing renderer and history validation around the current
`fresh`, `carried`, `unmeasured`, coverage, run-id, frontier, and accounting
fields. Keep the complete publication gate in `scripts/render_topdown_ledger.py`
and the strict validation in `scripts/history_diff.py`.

Add `scripts/partial_history_diff.py` rather than calling the existing
`compute_deltas` (`scripts/history_diff.py:447-463`), whose missing-path
default is zero. Require matching scope, canonical paths, schema/accounting
version, and quality; match exact paths, then only proven disjoint
parent/children partitions. Stale current/floor artifacts, overlaps, and
unmatched values remain explicit unknown/indeterminate records. Preserve fresh,
carried, effective coverage and unmeasured paths; emit partial kind/reason;
never write `ledger/topdown-5g.json` or call partial data a floor. A carried
value is provenance, not a new current delta; unknown interval or freshness
remains non-numeric and reports the measured interval.

Extend `scripts/render_topdown_ledger.py` to atomically publish
`ledger/topdown-5g.partial.json` for a fresh partial frontier while preserving
the complete-only gate for `ledger/topdown-5g.json`. It contains run/time,
scope, coverage, measured buckets, unfinished frontier, residual, and
non-canonical status. Add a thin `growth-top10` reader over existing history;
it may show current partial deltas with provenance and must refuse a bogus
floor.

The current snapshot path continues to own timeout and carry-forward behavior
(`scripts/disk_snapshot.sh` and `scripts/snapshot_carry.py`). The comparator
consumes their fields; it does not invent a second carry cache.

### 2. Typed terminal receipts

Add `scripts/job_receipt.py` with fields for schema/id/job/run/times, installed
revision, trigger, outcome, lock, safety, candidates, precondition,
postcondition, and publication. Outcomes are exactly `skipped_lock`,
`skipped_threshold`, `blocked_safety`, `error`, `timeout`, `success_noop`, and
`success`. Write started before work and terminal only after postcondition;
temp-file flush/fsync/rename preserves the previous valid artifact. Interrupted
started remains unknown, never success or zero freed. Retain at most the last
64 completed summaries per job and two active/started writer records per job
under the producer-owned state directory; skipped attempts cannot overwrite an
active or successful receipt. No event framework or cleanup script.

The first rollout is limited to `scripts/snapshot_commit.sh`,
`scripts/pressure_sweep.sh`, and `scripts/tmp_scratch_sweep.sh`; expand only
after their receipt and status fixtures pass.

### 3. Read-only status command

Add read-only `status` to `disk_magician.sh`, backed by Python 3 standard-library
`scripts/disk_status.py`. Join fleet, ledger/renderer sidecar,
snapshot coverage, receipts, and deployed identity; print each typed dimension,
source/time, and owner. No repair, cleanup, reload, deploy, or publication.
Exit 0 healthy, 1 degraded/unknown, 2 unreadable/invalid; preserve the
existing non-macOS fleet behavior.

### 3a. Canonical `diskm` dispatch contract

All operational capabilities in this redesign must be reached through the
canonical `diskm` binary and its CLI dispatch. New status and `growth-top10`
commands are CLI subcommands with focused dispatch tests; they are not
independently operated runner scripts. Small Python or shell helpers remain
private implementation modules behind that dispatch, and scheduled jobs
converge on the same command path. When a capability is missing, extend the
CLI once and test it rather than adding another ad hoc entry point.

At this planning snapshot, `pyproject.toml` declares the console entry point
`disk-magician = disk_magician.cli:main`; `diskm` is not claimed as an
installed noninteractive PATH binary. The implementation phase must resolve
the actual wrapper and add or update the canonical alias before claiming CLI
availability. This is a required contract, not a claim that migration or
installation is complete.

### 4. Existing sources as the catalog

Do not add a generic registry. Parse `launchd/*.plist.template` for label,
entrypoint, interval, and package-vs-root execution; cross-check the existing
fleet list. Extend `config/sweeper_roots.txt` and
`scripts/lib/scratch_roots.sh` through their owners with coverage/safety
fields. If config changes, deliberately extend package sync and test root and
`src/disk_magician/` parity. Existing Apple templates contain comments that
can make `plistlib` reject files that `plutil -lint` accepts; reuse current
extraction behavior and test native and non-macOS fixtures.

### 5. Deployment identity and rollback

Reuse `tools/deploy_uv_tool.sh` and have that existing tool emit a new
verified atomic `~/.disk_magician_state/deployed.json` post-verification record
with source SHA, installed version, package hashes, override state, and UTC
time; this record does not exist yet. Write it only after existing clean-source,
revision, package-diff, and smoke checks; do not grant a branch override. A
prior receipt is evidence, not proof rollback succeeded. Status reports uv
snapshot and repo-root frontier/drilldown/pressure/cleanup consumers separately.

### 6. Close existing enablement only under scoped authorization

The open Sep. 23 enablement, producer migration, codesign scheduling, safety,
and deployment Beads remain the work queue. Existing IDs to reconcile are
`q6l`, `i2o`, `d45`, `zyn`, `4y6`, `mfq`, `s62`, `371`, and `asb`; do not
create a duplicate epic. Completion requires a fresh safety preflight, a
deployed scheduled invocation, and a postcondition receipt. No design text
claims those items are enabled or live today.

## Alternatives considered

| Option | Decision | Rationale |
|---|---|---|
| Add more sweepers and raise thresholds | Reject as the whole solution | Can reduce pressure but cannot distinguish green logs from useful output or repair stale attribution. Existing safety gates and thresholds should be tuned only after evidence. |
| Replace scanner/ledger with a new daemon, database, or rewrite | Reject | High risk, duplicates working provenance and carry-forward work, and expands the production surface before the existing contract is complete. |
| Reuse and consolidate current paths | Choose | Smallest coherent change; preserves strict history, partial snapshot fields, launchd, safety, package verification, and existing Bead ownership. |

## Assumptions and recommended defaults

| Question | Recommended default | Rationale |
|---|---|---|
| Can a partial artifact become a strict floor? | No | The current audit has no valid strict 14-day floor; partial evidence must remain visibly partial. |
| How should missing paths affect a partial delta? | Unknown | Treating missing as zero is the known defect in `compute_deltas`. |
| What qualifies two partial snapshots for comparison? | Same scope, canonical paths, accounting version, and measurement quality | Prevents false deltas after coverage or partition changes. |
| What does an interrupted job mean? | Unknown until a later bounded reconciliation | A log or process exit cannot prove cleanup or postcondition. |
| Should lock skips count as failures? | Typed terminal `skipped_lock`, degraded only if policy says it blocks freshness | Operators can distinguish contention from errors without false success. |
| Where is inventory authority? | Existing plist templates plus existing root registries | Avoids another catalog that can drift. |
| Where is deployed identity authority? | The new `~/.disk_magician_state/deployed.json` post-verification record emitted by `tools/deploy_uv_tool.sh` | Keeps identity proof in the existing deploy owner; the record must not be treated as present before the tool writes it. |
| When is prevention proven? | Fixture contracts, then observed scheduled cycles across restart/sleep, then 24-hour watch and seven-day recurrence evidence | A pending window is not a run; one green cycle is not recurrence prevention. |

## Execution boundaries

Implementation is authorized by the current execution contract in the plan.
Re-pin the source, package, templates, and state before each verification;
preserve unrelated work and existing seven-day, never-delete, partial-ledger,
clean-main, and safety gates. Use temporary fixture trees for destructive-path
tests and never delete live data during fixture validation. The scope includes
the audited SQLite, Dark Factory, wiki-publish, CLI, scheduler, and package
data fixes; unrelated cleanup or a new scanner, daemon, database, or classifier
remains out of scope.

### 7. Safety fixes before activation

The following safety work is a blocking implementation task before any
scheduled `--clean` activation:

- `scripts/cleanup_codex_db.sh` and `tests/test_cleanup_codex_db.sh`: apply
  `busy_timeout` to every SQLite operation; acquire a per-database
  single-maintainer lease; use a conservative active-open-client policy;
  parse every `wal_checkpoint` result row, including exit-0 `busy` results;
  verify post-operation state and classify busy/incomplete outcomes as
  non-success. Add disposable concurrent SQLite reader/writer tests using real
  temporary databases. This task never deletes databases.
- `scripts/cleanup_agent_artifacts.sh`, `scripts/cleanup_dark_factory.sh`,
  `tests/test_cleanup_dark_factory.sh`, and routine-clean regression tests:
  remove the duplicate `~/.dark-factory/runs` target and delegate to the
  existing canonical cleanup handler. Prove that the canonical guard and
  per-candidate safety logging are used.
- `scripts/cleanup_dev_caches.sh` and a focused wiki-publish fixture test:
  remove automatic wiki-publish deletion until lifecycle provenance is known.
  Unknown, active, recent, and protected entries remain; tests must prove
  retention without inventing producer markers.

No ad-hoc cleaner or alternate deletion runner is introduced.

### 8. One CLI and scoped scheduler convergence

Package `diskm` as an additional console name pointing to the existing
`disk_magician.cli:main`; keep `disk-magician` as the same implementation until
the new name is installed. Add dispatch/help tests and installed-wheel tests
for `diskm status`, `diskm growth-top10`, and receipt/status paths. Helpers are
private modules, not user interfaces.

The first scheduler migration is limited to these existing templates and
installer paths: `launchd/com.jleechanorg.disk-magician-frontier-nightly.plist.template`
(snapshot/frontier consumer),
`launchd/com.jleechanorg.disk-magician-pressure-sweep.plist.template`,
`launchd/com.jleechanorg.disk-magician-tmp-scratch.plist.template`,
`launchd/com.disk-magician.claude-state.plist.template`, and
`launchd/com.disk-magician.codex-vacuum.plist.template`. Their operational
pressure-sweep, tmp-scratch-sweep, cleanup-claude-state, and codex-vacuum
subcommands route the existing helpers through the same CLI. Installed
templates use stable `@HOME@/.local/bin/diskm` with identical arguments and
environment. Other root consumers remain inventory findings until a later
dispatch migration is explicitly scoped; this design does not claim all jobs
are migrated. Validate installer behavior with
`tests/test_install_launchd_sweepers_preflight.sh` and package/deploy parity
with `tests/test_package_sync.sh` and `tests/test_deploy_uv_tool.sh`.

Add `config/*.txt` to `pyproject.toml` package-data to close the existing
`disk_magician-asb` gap, and prove it through the installed-wheel test. Do not
create a new registry.

## Acceptance contract

Acceptance is staged and evidence-bearing:

1. Fixture contracts pass for stale/partial inputs, same-scope partial
   comparison, parent/child repartition, overlap, unknown-not-zero, carried
   and unmeasured values, log-touched-without-receipt, skipped lock/no-op,
   writer crash/atomic replacement, wrong package identity, and safety no-op.
2. Existing scheduled cycles are observed across restart and sleep where
   feasible, with raw receipts, coverage, publication, and deployed identity.
3. An initial 24-hour watch reports observed windows and unresolved unknowns;
   it does not fabricate a run from a pending schedule.
4. A seven-day recurrence observation establishes whether the producer growth
   and prevention contract held. Until then, the result is pending/partial.
5. The final report distinguishes fixture GREEN, observed behavior, and
   recurrence evidence. It never upgrades a green test or a touched log into
   production reliability.

## Self-review checklist

- [x] Complete-only floor and partial comparison are separate.
- [x] Missing paths, changing partitions, overlap, stale inputs, and unknown
  outcomes have explicit behavior.
- [x] Receipt, status, catalog, and deployment work reuse existing owners.
- [x] Existing package mirror and two-consumer deployment paths are named.
- [x] Open Beads are reconciled without duplicating the Sep. 23 epic.
- [x] Safety fixes and scoped activation gates are explicit.
- [x] Acceptance requires observed windows and seven-day recurrence evidence.
- [x] All design decisions and evidence limitations are explicit.

## Review record

Canonical `/advice` returned CHANGES REQUESTED on the frozen review clone. The
targeted safety and scheduler corrections are incorporated above; no approval
is claimed until the required independent rerun. `/web-advice` is SKIPPED
because no external browser recipient was authorized. Reviewer D (Web advice)
is unavailable (disabled by parent authorization boundary). The
[audit](../reviews/2026-10-03-disk-reliability-audit.md) records the earlier
runner output and exact skill requirements.
