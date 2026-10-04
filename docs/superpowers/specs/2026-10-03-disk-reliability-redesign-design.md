# Disk reliability redesign

Date: 2026-10-03  
Status: Design only; implementation is separately authorized work.

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
then advanced to current HEAD `88b6bffb3da191834f68979abd932e936d29d2b6` at
22:46Z with reviewed file hashes unchanged. The pre-existing production work
is now committed; these planning documents remain untracked. No production activation,
heavy scan, or multi-hour validation is authorized by this design.
Current-head reference:
[88b6bffb3da191834f68979abd932e936d29d2b6](https://github.com/jleechanorg/disk_magician/commit/88b6bffb3da191834f68979abd932e936d29d2b6)
(prod +1427/-25 including mirrors; non-prod +1245/-27).

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

Reuse `tools/deploy_uv_tool.sh` and add a new verified atomic
`~/.disk_magician_state/deployed.json` post-verification record with source
SHA, installed version, package hashes, override state, and UTC time. Write it
only after existing clean-source, revision, package-diff, and smoke checks; do
not grant a branch override. A prior receipt is evidence, not proof rollback
succeeded. Status reports uv snapshot and repo-root frontier/drilldown/
pressure/cleanup consumers separately.

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
| Where is deployed identity authority? | `~/.disk_magician_state/deployed.json` written by `tools/deploy_uv_tool.sh` | Matches existing state and verified deploy ownership. |
| When is prevention proven? | Fixture contracts, then observed scheduled cycles across restart/sleep, then 24-hour watch and seven-day recurrence evidence | A pending window is not a run; one green cycle is not recurrence prevention. |

## Implementation preconditions

- User explicitly authorizes implementation in a clean isolated source state;
  this document grants no production activation.
- Reconcile the listed Beads and current owner status; do not rely on old PR
  or commit prose as live state.
- Re-pin deployed package, launchd templates, and repository head before each
  verification round. Preserve unrelated dirty changes and isolate source
  edits.
- Resolve the authoritative current snapshot and ledger paths; do not invent
  absent baseline artifacts or run an unbounded `du` sweep.
- Confirm package mirror rules if adding `scripts/*.py`, config, or template
  files; bump the monotonic package version, run
  `scripts/sync_package_tree.sh`, then `scripts/sync_package_tree.sh --check`
  before a guarded deploy.
- Obtain a fresh safety preflight before any future live cleanup test. Fixtures
  must use temporary trees and must not delete live data.

## Explicit exclusions

This design does not authorize code implementation, deployment, launchd repair,
cleanup, deletion, force-push, merge, credential work, a new scanner or daemon,
database storage, LLM classification, broad policy edits, or live multi-hour
validation. It does not weaken the seven-day worktree rule, never-delete list,
partial publication gate, or clean-main deployment guard.

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
- [x] No live activation or destructive test is implied.
- [x] Acceptance requires observed windows and seven-day recurrence evidence.
- [x] All design decisions and evidence limitations are explicit.

## Review record

`/advice` FAILED before reviewer input because the dirty checkout lacked an
exact-SHA representation; no retry was made. `/web-advice` is SKIPPED because
no external browser recipient was authorized. Reviewer D (Web advice) is
unavailable (disabled by parent authorization boundary). The
[audit](../reviews/2026-10-03-disk-reliability-audit.md) records the runner
output and exact skill requirements. This `diskm` refinement is local review
only; no review was rerun and no independent approval is claimed.
