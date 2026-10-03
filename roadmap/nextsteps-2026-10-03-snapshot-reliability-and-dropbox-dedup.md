# Nextsteps — disk_magician — 2026-10-03

## Table of contents

- [Executive summary](#executive-summary)
- [2026-10-03 reliability integration refresh](#2026-10-03-reliability-integration-refresh)
- [Context](#context)
- [Bead index](#bead-index)
- [Work queue](#work-queue)
- [Timeline and parallel lanes](#timeline-and-parallel-lanes)
- [PR / merge state](#pr--merge-state)
- [Learnings pointer](#learnings-pointer)
- [Roadmap pointer](#roadmap-pointer)

## Executive summary

- **Snapshot coverage swings (15-40% vs ~70%) were a timeout artifact**, not missing data: 20 s per-path `du` cap + null counted as zero + host loadavg 50-140 (Colima VM ~4.5 cores). Fixed in [PR #90](https://github.com/jleechanorg/disk_magician/pull/90) (MERGED by jleechan2015 22:32Z; main = 0.2.124): parallel measure, honest timeouts, 72 h carry-forward, fresh/carried/effective coverage. Not deployed; plan Task 0 (benchmark) and Task 7 (20-run acceptance) not done.
- **Dropbox was full (2.006/2.006 TiB) so cloud backups of AI conversations had silently stopped.** User approved API deletion of hash-verified duplicates in the stale standalone folders; ~25.1k files / ~27.8 GiB deleted so far, quota now 1.975 TiB used (31.7 GiB free). A background job is still deleting (see Work queue 1).
- **Merge fallout:** six open PRs (#77 #80 #81 #84 #85 #86) are now behind main (0.2.124) and will fail the version-monotonic check; #80 likely conflicts with #90 in `disk_snapshot.sh`.
- Local disk free jumped to ~111 GiB at the end of this block (was 13-30 GiB); cause not identified (another actor is also cleaning/deleting — ~3.7k duplicate Dropbox files vanished before we deleted them).
- Beads: [disk_magician-xqm](#bead-index) (Dropbox dedup), [disk_magician-dbp](#bead-index) (rebase PRs), [disk_magician-hwa](#bead-index) (snapshot follow-ups), [disk_magician-i56](#bead-index), [disk_magician-e50](#bead-index).

## 2026-10-03 reliability integration refresh

This refresh is the current `/nextsteps` handoff for the active native disk
reliability goal. It supersedes the older queue below for implementation order;
the historical Dropbox and snapshot notes remain provenance. The active
execution contract is
`docs/superpowers/plans/2026-10-03-disk-reliability-redesign.md` § Authorized
execution contract. The scoped implementation/merge work is authorized; this
refresh made no Bead or GitHub Issue mutation.

### Current state and tracker index

The parent lane's 2026-10-03 audit found 23 of 29 latest-per-day samples below
70% coverage, 984 snapshot commits, and zero canonical-ledger updates in the
30-day interval. There is no valid strict 14-day floor. The current isolated
integration head is [commit 0bbc2ce10e255a739abe5c6ea6525db82894430f](https://github.com/jleechanorg/disk_magician/commit/0bbc2ce10e255a739abe5c6ea6525db82894430f),
based on `d44704343a7a12e8652c2112138f9a4cd4200b55`; it contains docs only
(prod +0/-0, non-prod +890/-0). The earlier 88b6bff… pin belongs to historical
review context and is not current integration state.

| Item | Refreshed state | Owner / next action |
|---|---|---|
| Epic | `disk_magician-disk-fill-prevention-scheduled-cleanup-q6l` OPEN, P1; rollup 3 closed / 23 open | Root: reconcile existing children; do not create a replacement epic |
| Partial-ledger task | `disk_magician-zyn` OPEN; existing PR #77 remains an implementation candidate pending current-head review | Root/scout: inspect and reconcile before reuse |
| Root attribution | `disk_magician-4y6` OPEN | Root: preserve root-runner and fresh-attribution gate |
| Health warning | `disk_magician-sweeper-health-ledger-warn-impl-s62` OPEN | Root: extend current health path with typed publication/receipt state |
| SQLite safety | `disk_magician-7yv` OPEN | Root: reproduce checkpoint-busy result and add guarded proof before activation |
| Wiki-publish safety | `disk_magician-mda` OPEN | Root: require measured lifecycle, active-consumer, and per-entry safety proof |
| Source-quality correction | `disk_magician-cjc` OPEN | Root: correct uppercase `H` interpretation without rewriting history |
| Retention | `disk_magician-6aa` OPEN | Root: independently reproduce and close only with deployed scheduled proof |

### Exact PR state

- [PR #91](https://github.com/jleechanorg/disk_magician/pull/91) is OPEN and
  draft at head `d44704343a7a12e8652c2112138f9a4cd4200b55`, base `main`,
  `BLOCKED`. Test and lint is in progress; Evidence Gate and CodeRabbit are
  successful. No merge authorization is implied.
- [PR #77](https://github.com/jleechanorg/disk_magician/pull/77) is OPEN,
  non-draft, `DIRTY`, at head `cea7b8127764bb253e175b037a4152a167aa76ce`.
  Its historical checks are mixed and stale for current integration; do not
  infer that it is merge-ready or that it covers all redesign scope.

### Work queue and five exit criteria

1. Resolve the packaged `diskm` name as an additional entry point to the same
   CLI implementation, preserve `disk-magician` until installed, and test
   dispatch/help plus the symlink/entry-point contract.
2. Implement partial accounting as a separately named artifact, with
   same-scope/quality gates, unknown-not-zero, parent/child handling, and
   typed receipts/status. Keep the complete canonical ledger as the strict
   floor source.
3. Independently reproduce and fix the safety defects tracked by `7yv`, `mda`,
   and `cjc`, plus the `6aa` retention path, without broadening cleanup scope.
4. Integrate on exact current `main`, run the package sync/version guard, and
   use the guarded deploy path. A prior receipt or green check is evidence,
   not merge or deployment authorization.
5. Update the tracker and collect real scheduled evidence. Label pending,
   24-hour, and seven-day observations separately; never fabricate a seven-day
   run from a schedule, log timestamp, or partial artifact.

### Timeline and parallel lanes

These are estimates from the parent handoff, not observed completion. The
supplied admission was 9.17 GiB available at pressure level 2 with three worker
slots; perform a fresh admission check before launching workers. `/advice` is
currently RUNNING from the frozen clean independent clone; its verdict is not
yet available.

| Window from flow start | Lane / owner | Scope and dependency | Completion evidence |
|---|---|---|---|
| 0–20 min | Root: preparation and plan review | Re-pin current head, reconcile q6l children, confirm CLI/deploy/safety ownership | exact state table and frozen plan |
| 20–80 min | Parallel implementation lanes | CLI/entry-point, partial accounting/receipts/status, safety reproductions; disjoint files/worktrees | focused RED/GREEN results per lane |
| 80–120 min | Root: integration and independent verification | exact-main integration, package mirror, focused/full checks, receipt/status join | verified integrated SHA and evidence bundle |
| 120–150 min | Root: merge/deploy gate | only after results and explicit merge/deploy authority | current-head checks, guarded deploy receipt, no invented recurrence claim |

Critical path: partial artifact and typed receipt contracts → independent safety
verification → exact-main integration → guarded deploy. Shared source files,
GitHub merge authority, and deploy identity are serialization boundaries.

### Required Beads instructions for the root writer

No Beads mutation was made here. The root writer should use
`br --no-auto-flush` against `/Users/jleechan/projects_other/disk_magician/.beads`
and update existing records only after current-head verification:

- q6l: append the native CLI/partial-accounting/receipt/status scope and keep
  its existing children; do not duplicate the epic.
- zyn: record whether existing PR #77 can be reused after exact-main review;
  preserve its partial publication and structural-validation findings.
- 4y6: keep root-runner/FDA attribution as an independent gate.
- disk_magician-sweeper-health-ledger-warn-impl-s62: require typed
  receipt/publication evidence rather than log prose.
- 7yv: attach the checkpoint-busy reproduction and require concurrent-client
  safety before scheduled activation.
- mda: require measured lifecycle, active-consumer, and per-entry safety tests.
- cjc: preserve the Git documentation correction with historical provenance.
- 6aa: require deployed scheduled retention proof and safety review.

### Review and evidence references

The design and plan are the two
`docs/superpowers/{specs,plans}/2026-10-03-disk-reliability-redesign*`
artifacts in the integration worktree. The earlier dirty-checkout `/advice`
failure and `/sq` constraint are historical; current `/advice` is RUNNING
from the frozen clean independent clone. This `/nextsteps` update does not
claim a verdict. The code-standards audit is recorded at
`docs/superpowers/reviews/2026-10-03-disk-reliability-audit.md`.

## Context

Session started from a "disk is full again" request on a 98-99% full Data volume. Fleet check was healthy (16/16 jobs). Routine cleanup freed ~3 GB; worktrees (136, 47 GiB) and `~/.claude/state` (21.8 GiB) were all preserved by their own safety gates. Investigation showed the snapshot's low coverage was timeouts; growth vs the 60-day floor (714 GiB on 2026-08-11 -> 851 GiB, +137) is mostly projects/worktrees (+82), `~/.codex` (+52), `~/.claude` (+21), Drive mirror (+27), `~/.cache` (+17). A multi-lane audit of AI-conversation backups (local originals, Dropbox, Google Drive local copy, cloud web, backup jobs, duplicates) led to the Dropbox dedup. Repo: `/Users/jleechan/projects_other/disk_magician`, branch main. Reports: `roadmap/2026-10-03-*.md`.

## Bead index

| Bead | Title | Link |
|---|---|---|
| disk_magician-xqm | Dropbox dedup: finish hash-verified deletion; decide claude/opencode | `br show disk_magician-xqm` |
| disk_magician-dbp | Rebase + version-bump open PRs after #90 | `br show disk_magician-dbp` |
| disk_magician-hwa | Snapshot reliability follow-ups after #90 (Task 0, Task 7, deploy, evidence) | `br show disk_magician-hwa` |
| disk_magician-i56 | IMPL snapshot timeout reliability (PR #90 merged; tasks 0/7 open) | `br show disk_magician-i56` |
| disk_magician-e50 | Backups: Dropbox full + DISK_PRESSURE skip + unscheduled Drive writer | `br show disk_magician-e50` |
| disk_magician-0si | Harness: coverage_streak resets on good runs; low_coverage noise | `br show disk_magician-0si` |
| disk_magician-6aa | `~/.dark-factory/runs` retention (likely covered by merged #89) | `br show disk_magician-6aa` |
| disk_magician-ueh | cleanup_worktrees: squash-merged PR worktrees (14 / 5.1 GiB) wrongly PRESERVE | `br show disk_magician-ueh` |
| disk_magician-mq9 | disk_audit: show carried keys + fresh vs effective coverage | `br show disk_magician-mq9` |
| disk_magician-asb | `config/sweeper_roots.txt` missing from wheel package-data | `br show disk_magician-asb` |
| disk_magician-4y6 | Root-privileged frontier job never installed (needs sudo) | `br show disk_magician-4y6` |
| [disk_magician-disk-fill-prevention-scheduled-cleanup-q6l](#bead-index) | Native reliability epic; keep existing child DAG and current execution contract | `br show disk_magician-disk-fill-prevention-scheduled-cleanup-q6l` |
| [disk_magician-zyn](#bead-index) | Partial-ledger publication task; inspect existing implementation before reuse | `br show disk_magician-zyn` |
| [disk_magician-sweeper-health-ledger-warn-impl-s62](#bead-index) | Typed publication/receipt health warning | `br show disk_magician-sweeper-health-ledger-warn-impl-s62` |
| [disk_magician-7yv](#bead-index) | SQLite checkpoint-busy and concurrent-client safety | `br show disk_magician-7yv` |
| [disk_magician-mda](#bead-index) | Wiki-publish lifecycle and active-consumer safety | `br show disk_magician-mda` |
| [disk_magician-cjc](#bead-index) | Correct uppercase `git ls-files -v` interpretation | `br show disk_magician-cjc` |
| [disk_magician-6aa](#bead-index) | Dark Factory retention safety and deployed proof | `br show disk_magician-6aa` |

## Work queue

1. **Monitor/finish the Dropbox deletion job** — [disk_magician-xqm](#bead-index).
   - Running: `python3 /tmp/convos/dup/fresh/run_delete.py` (idempotent; re-lists live and verifies hashes per directory before each purge; skips mismatches). Log `/tmp/convos/dup/fresh/run.log`, done flag `/tmp/convos/dup/fresh/run.done`, deleted manifest `~/.disk_magician_state/dropbox_dedup_deleted-2026-10-03.tsv`. Progress at handoff: 209 dirs purged, 1000 of 4,603 loose codex files done (~25 min per 1000 under Dropbox write limits); then gemini (2 dirs, 4 files), aside (27 dirs), cursor (39 dirs, 11 files). If the process died, re-run it (state is live, safe).
   - Acceptance: every path in the run's manifest is absent from `dropbox:<folder>` and present with identical hash in `dropbox:conversation-backups/<folder>`; `rclone about dropbox:` shows the freed space. Never run more than one `rclone lsjson` listing at a time (rate limits). Constraint from the user: previously "no API needed for checks"; deletion was explicitly authorized via API.
2. **Decide claude_conversations (13.1 GiB, 82,982 size-equal files) and opencode_conversations (0.6 GiB)** — not hash-verified. Fetch hashes (`rclone lsjson -R --files-only --hash --fast-list --tpslimit 6`, timeout >= 6000 s, one at a time; the 900 s timeouts truncated earlier attempts), then reuse `run_delete.py` logic. Keep the 588+ files with no identical counterpart.
3. **Rebase and version-bump the six open PRs** — [disk_magician-dbp](#bead-index). Order by merge intent; each needs version > 0.2.124, `scripts/sync_package_tree.sh`, tests, refreshed Evidence SHA/gist, `/er` at the new head. #80 vs #90 conflict in `disk_snapshot.sh`.
4. **Snapshot follow-ups** — [disk_magician-hwa](#bead-index): benchmark (Task 0), 20-run acceptance (Task 7), real evidence bundle, deploy (`uv tool install --force --reinstall`, verify deployed tree), review the dedup-trie behavior change.
5. **Dark-factory runs retention** — [disk_magician-6aa](#bead-index): confirm `cleanup_dark_factory.sh` (PR #89) is in the deployed copy, run `./disk_magician.sh cleanup-dark-factory` dry-run, review, then `--clean`.
6. **Fix the backup writer** — [disk_magician-e50](#bead-index): DISK_PRESSURE skip in `~/projects/user_scope/scripts/backup-home.sh`, `user_scope` repo 58 behind origin/main, qdrant 7-day prune crash (`mapfile` on bash 3.2), unscheduled `sync-convos-to-gdrive.sh`, no alert when no backup leg succeeds in 24 h.
7. **Decisions needing the user:** (a) Google Drive local copy (45 GiB allocated, orphaned, Drive app not installed) holds ~4.7 GiB of conversations found nowhere else in the cloud (gemini 3.18 GiB, ~11.2k claude files, cursor 0.2) — do not delete before preserving; options: archive externally / reinstall Drive and upload / delete. (b) Dropbox web is not signed in inside Aside (login page offered "Continue as Jeffrey"; not clicked). (c) Root frontier install needs the user's sudo: `sudo ./scripts/install_root_frontier_runner.sh --user jleechan` plus a `DISK_MAGICIAN_GDU_CMD` setting in the plist ([disk_magician-4y6](#bead-index)).
8. **Smaller items:** [disk_magician-ueh](#bead-index), [disk_magician-asb](#bead-index), [disk_magician-0si](#bead-index), [disk_magician-mq9](#bead-index).

## Timeline and parallel lanes

| Elapsed estimate | Lane / owner | Scope / dependencies | Deliverable / proof |
|---|---|---|---|
| now .. +3 h | Lane A: Dropbox deletion job (background, single rclone writer) | exclusive: `dropbox:` standalone folders; one listing at a time | `run.done` + manifest + `rclone about` |
| +0 .. +40 min | Lane B: claude/opencode hash listing (after Lane A, or serialized in the same job; Dropbox rate limit) | depends on Lane A finishing its writes | hash JSONs in `/tmp/convos/dup/` |
| +0 .. +2 h | Lane C: rebase/bump six PRs (disjoint worktrees per PR) | merge order decision by user; #80 first (conflict) | green CI + Evidence SHA per PR |
| +0 .. +1 h | Lane D: dark-factory dry-run and deploy check | read-only first | dry-run output reviewed |
| +1 .. +3 h | Lane E: snapshot Task 0 / Task 7 / deploy | after Lane C lands #80 or in a scratch state dir | benchmark + 20-run results |

- Critical path: Lane A (Dropbox write rate limits), then Lane B. Concurrency ceiling: bounded by Dropbox API limits (one writer, one listing) and host load (loadavg 50-140 at times, 16 GB RAM available at start); lanes C-E are independent and CPU-bound.
- Milestones: +20 m, +40 m, +60 m (hourly rollup), then repeat while active. Execution start: pending the next agent's takeover; this handoff does not start it.

## PR / merge state

Resolved via the GitHub REST API in this run:

- https://github.com/jleechanorg/disk_magician/pull/90 — MERGED (jleechan2015, 2026-10-03T22:32Z)
- https://github.com/jleechanorg/disk_magician/pull/89 — MERGED (on main; dark-factory retention)
- https://github.com/jleechanorg/disk_magician/pull/77 — OPEN (head cea7b81, 0.2.120)
- https://github.com/jleechanorg/disk_magician/pull/80 — OPEN (head f475980, 0.2.121)
- https://github.com/jleechanorg/disk_magician/pull/81 — OPEN (head c88f5a9, 0.2.120)
- https://github.com/jleechanorg/disk_magician/pull/84 — OPEN (head e540852, 0.2.120)
- https://github.com/jleechanorg/disk_magician/pull/85 — OPEN (head e22359b, 0.2.120)
- https://github.com/jleechanorg/disk_magician/pull/86 — OPEN (head 66d87d4, 0.2.122)

Merge-order: #90 is MERGED, so do not "land #90"; rebase the OPEN PRs on main. Open PRs are ready-for-review with CI green and `/er` PASS at their heads (before the rebase); Codex CLI was broken on this host (401) so agy substituted for Codex in `/advice`.

## Learnings pointer

- `~/roadmap/learnings-2026-10.md` — section `2026-10-03 — snapshot timeouts, Dropbox full, backup audit`.

## Roadmap pointer

- Appended `roadmap/activity/2026-10-03.md` (date file already existed; README untouched).
- Evidence/reports from this block: `roadmap/2026-10-03-{growth-analysis,blind-spot-analysis,convos-backup-audit,dropbox-duplicate-deletion-plan}.md` and `roadmap/2026-10-03-convos-{1..6}-*.md`.
