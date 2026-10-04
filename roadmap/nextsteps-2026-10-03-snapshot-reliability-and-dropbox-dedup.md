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

This section owns the current reliability implementation handoff. The older
Dropbox, backup, and snapshot queue below is historical provenance and does
not authorize resuming unrelated operations. The implementation contract is
`docs/superpowers/plans/2026-10-03-disk-reliability-redesign.md`.

### Implemented scope and verification boundary

The packaged `diskm` entry point shares `disk_magician.cli:main` with
`disk-magician`; `AGENTS.md` remains a symlink to `CLAUDE.md`. This phase routes
the primary snapshot and six named scheduled jobs through the installed CLI.
Other fleet consumers remain visible in the actual installed-plist inventory;
they are not represented as migrated.

The accounting change publishes partial scans separately, protects the
canonical complete ledger, and refuses numeric growth for missing, carried,
stale, overlapping, or incomparable buckets. The current live frontier was
replayed into an isolated output directory: it remained partial and produced
no strict floor. The 30-day audit found 23/29 latest-per-day samples below 70%
coverage, 984 snapshot commits, and zero canonical-ledger updates. These are
dated audit results, not a claim that present coverage is healthy.

Typed job receipts distinguish active, skipped, blocked, failed, and completed
work. Status joins actual fleet routing, measurement, publication, outcomes,
safety, budgets, and deployed identity independently. A loaded plist, process
exit code, or touched log cannot substitute for verified postconditions.

Cleanup changes preserve unknown wiki-publish lifecycles, use the canonical
Dark Factory cleaner, protect TemporaryItems and every repository container
from generic scratch-budget deletion, and harden SQLite ownership, leases,
busy results, and inspection failures. The producer helper owns one private
scratch leaf and preserves the caller's signal/exit behavior. The residual-drilldown uncovered-root alert uses its existing checker and
reaches the scheduler through the same packaged dispatcher. The 15 GiB
scheduled scratch budget and bounded codesign stage require these guards.
No live destructive test or global agent hook is part of this implementation.

### Remaining execution and durable owners

This source handoff is written before final merge and deployment. The
canonical Beads and published final evidence are the authority for later
runtime completion; do not infer deployment from this document or a commit.

| Item | Owner and closing evidence |
|---|---|
| `disk_magician-disk-fill-prevention-scheduled-cleanup-q6l` | Root integrates and checks C1–C5; keep the broader epic open while existing children or observation windows remain |
| `disk_magician-zyn` | Partial publication: actual installed renderer/receipt and preserved complete ledger |
| `disk_magician-sweeper-health-ledger-warn-impl-s62` | Typed status and health warning: fixtures plus actual installed status readback |
| `disk_magician-7yv` | SQLite: real disposable busy reader/writer, guarded path tests, installed preview, and deployed bytes |
| `disk_magician-mda` | Wiki-publish: unknown lifecycle retention, fixtures, and deployed bytes |
| `disk_magician-cjc` | Historical uppercase `H` correction: retained provenance and real Git fixture |
| `disk_magician-6aa` | Canonical Dark Factory retention: deployed route and later scheduled outcome; fixture success alone does not close it |
| `disk_magician-asb` | Wheel includes the complete launchd catalog and sweeper registry; deployed manifest matches source |
| `disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.1` | Nested/recent/dirty repositories remain protected by generic scratch budget; independent fixture verification before activation |
| `disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.2` | Root owns the 24-hour and seven-day read-only observation windows; pending until real intervals elapse |
| `disk_magician-4y6` | Root attribution remains a separate privileged-runner follow-up; strict floor may correctly remain unavailable |

1. Freeze the combined source, complete independent semantic and executable
   verification, and publish the exact-head raw evidence.
2. Merge the authorized scoped change, then deploy only from a clean checkout
   equal to live `origin/main` using `tools/deploy_uv_tool.sh`.
3. Verify both installed CLI names, full deployed manifest, actual scheduled
   arguments, and a new scheduled snapshot receipt. Preserve known degraded
   or unknown status dimensions instead of manufacturing healthy results.
4. Record runtime proof in the existing Beads, home learnings, and the evidence
   record. Observe the 24-hour and seven-day windows in later sessions; these
   windows remain pending until real receipts exist.

### Review and evidence references

The canonical Codex and Opus plan review returned APPROVED. Its
[review receipt and synthesis](https://gist.github.com/jleechan2015/67557ce3d89624b3b9e0c0a20db90da1)
bind that verdict to the reviewed plan, not final code or deployment. The
optional browser transport timed out before submission, so no browser verdict
is claimed. The original standards audit is in
`docs/superpowers/reviews/2026-10-03-disk-reliability-audit.md`.

Raw implementation and independent checks are retained under
`/tmp/disk-reliability-20261003*`; the final published evidence record must
include the source pin, commands, results, deployed identity, and explicit
pending observations. Root is the single canonical Beads writer.

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
