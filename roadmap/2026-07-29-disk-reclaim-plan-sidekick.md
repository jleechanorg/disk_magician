# Disk reclaim plan — 2026-07-29 sidekick pass

Mission: `disk_magician-xxv` ("sidekick: save-another-200g-systematic-fix").
State/log: `~/roadmap/disk_magician/sidekick/save-another-200g-systematic-fix/STATE.md`.
Companion doc: `roadmap/2026-07-29-systematic-fix-architecture-sidekick.md`.

Disk at spawn (2026-07-29 04:24 PDT): `/System/Volumes/Data` 825 GiB used /
47 GiB avail (95%). This pass builds directly on the same-day root-cause
report (`roadmap/2026-07-29-disk-regrowth-rootcause-sidekick.md`,
adversarially verified 2x) rather than re-measuring from scratch.

## Headline finding: 200 GiB of SAFE reclaim does not exist on this Mac right now

The mission target was ~200 GiB. After exhausting every repo-provided
cleanup script, a full-repo worktree hygiene census, and a fresh look at
the two largest known levers (APFS local snapshots, TCC-protected paths),
the honest number is:

- **~2.6 GiB actually executed this pass** (safe class, no operator
  approval needed — see table below).
- **~0.5 GiB more identified and ready**, blocked only on a deliberate
  human-approval env var (`WORKTREE_APPROVED=1`), not a technical blocker.
- **~10-15 GiB plausible but currently blocked** by a live infrastructure
  fault (Colima/Docker I/O wedge) that needs an operator-judgment recovery
  action, not a script.
- **The 200+ GiB-class levers are ALL genuinely operator-decision**: an
  unmeasured (possibly large, possibly small) amount behind APFS
  local-snapshot thinning, and a 291-406 GiB unattributed residual that is
  mostly OS-protected (TCC paths, an APFS snapshot pinning the container's
  minimum size) or legitimately in-flight work (42.2 GiB of <14-day-old
  agent worktrees).

This is not a failure to find reclaim — it is the correct output of a
system whose safety rails (never-delete list, 14-day worktree floor,
`WORKTREE_APPROVED` gate, free-space-gated VACUUM guards) are working as
designed. A prior investigator forcing "200 GiB found" out of this system
would have had to violate one of those rails. The companion systematic-fix
doc addresses why routine reclaim capacity is this thin in the first place.

## Table 1 — Executed this pass (safe class, no approval needed)

All measured before/after with the actual command output, not estimated.

| Item | Command | Freed | Verification |
|---|---|---:|---|
| `/private/tmp` + `/private/var/folders/.../T` stale scratch | `scripts/cleanup_tmp.sh --clean` | 42 MB | script's own before/after log |
| Ollama model cache (`llama3.2:3b`, `nomic-embed-text:latest` — re-downloadable) | `scripts/cleanup_ollama.sh --clean` | 2.1 GB | `du` before (2.1G) / after (0K) in script log |
| npm `_cacache` + `uv` cache | `scripts/cleanup_dev_caches.sh --clean` | 451 MB + 20 KB | script's own before/after log |
| Hermes SQLite session-prompt dedup (1066 sessions >30d old, `system_prompt` NULLed) | `scripts/dedup_hermes_prompts.sh --apply` (committed during this pass's first, interrupted attempt — confirmed via row-count recheck: 3675 → non-reclaimable-relevant count dropped from 1066 to 3 stale rows) | ~72 MB logical (not yet reflected in on-disk file size — see incident note below; VACUUM to actually shrink the file did not complete safely, see Table 3) | `SELECT COUNT(*) ... WHERE system_prompt IS NOT NULL` before/after |
| **Total executed, on-disk** | | **~2.6 GiB** | |

**Not counted as reclaim (self-created-then-cleaned, net zero):** a 6135 MB
`state.db.dedup-backup-*` file was created by this pass's own first
(interrupted) dedup attempt and then correctly deleted via
`--delete-backups` once superseded. Net disk effect relative to mission
start = 0. Listed here only for honesty/audit — do not double-count.

**Incident during this pass (resolved, no data loss):** a second attempt to
run the dedup script's `VACUUM` (to actually shrink `~/.hermes/state.db`
on disk, not just logically free rows) was wrapped in a `timeout 300` that
expired mid-VACUUM, exactly reproducing the WAL-ballooning pattern this
script's own header comment documents from a 2026-07-22 near-incident
(WAL grew to 5.95 GB). Recovered safely via
`sqlite3 ~/.hermes/state.db "PRAGMA wal_checkpoint(TRUNCATE);"` (600s
timeout, completed cleanly, `0|0|0`) followed by
`PRAGMA integrity_check;` → **`ok`**. No data was lost; the file simply
did not shrink (VACUUM's compaction was aborted, not corrupted). A
verified pre-VACUUM backup (`state.db.dedup-backup-20260729-044704`,
6433193984 bytes) still exists as an extra safety margin — recommend
deleting it only after confirming the Hermes gateway behaves normally on
its next run, not automatically by this pass. **Lesson, folded into the
systematic-fix doc:** never wrap a VACUUM/checkpoint call in a `timeout`
shorter than its own documented worst-case runtime.

## Table 2 — Ready to execute, blocked only on deliberate operator approval

| Item | Measured | Blocker | Exact command |
|---|---:|---|---|
| 6 SAFE (zero-ahead / merged-PR-clean) git worktrees, system-wide census across all repos (580 worktrees scanned: 6 SAFE, 52 NEEDS-REVIEW, 522 PRESERVE/young) | 493 MB (`hermes-agent-upstream` 138M, `worldarchitect-57` 301M, 4× AO proof/repo-rename/shell-reviewer/skeptic-adapter worktrees ~13-15M each) | `scripts/worktree_hygiene.sh --execute` requires `WORKTREE_APPROVED=1` in the environment — this repo's own CLAUDE.md treats that as a deliberate human-approval checkpoint, not a mission self-authorization, even though the SAFE classification itself is the pre-authorized safe class | `WORKTREE_APPROVED=1 bash scripts/worktree_hygiene.sh --execute` |

This is small in absolute terms but zero-risk (the script's own SAFE
classification means zero-ahead-of-origin or merged-and-clean) — worth
running on the next human touch of this repo.

## Table 3 — Real but currently blocked by infrastructure fault (operator decision)

| Item | Measured | Why blocked | Exact recovery path (risk-classed) |
|---|---:|---|---|
| Docker/Colima image+builder prune | `docker system df` shows 13.42 GB images (9.888 GB / 73% reclaimable), 0 GB reclaimable containers | `docker system df` **hung >15s with no response** when attempted live this pass — confirms this repo's documented gotcha ("Colima's sparse disk wedges with I/O errors when host disk hits ~100%") is currently active, not just theoretical | **Medium risk, disruptive:** `colima stop && colima start` then `colima ssh -- sudo fstrim -av`, THEN retry `docker image prune -af`. Disruptive because `colima stop` kills any in-flight containers (including active `ez-gh-actions` CI runners) — operator should confirm no in-progress CI runs before stopping. Not attempted this pass. |
| Hermes VACUUM full compaction of `state.db` (6.1 GB, ~72 MB+ of logically-freed-but-not-reclaimed space after the dedup above, plus normal fragmentation) | Unknown exact reclaim amount (script requires live free space ≥ 2× current DB size = 12.3 GB before attempting) | This pass's own attempt was interrupted by an overly-short `timeout` wrapper (see incident note above) — the script's *own* safety guard was never actually the blocker, my `timeout` was | **Low risk if done right:** `bash scripts/vacuum_hermes_state.sh --apply --full-vacuum` (no external `timeout` wrapper — let the script's own free-space guard decide) run when free space is comfortably above 15-20 GiB and Hermes gateway is not actively serving traffic. |

## Table 4 — Needs-operator-decision (large, unmeasured-with-precision, genuinely ambiguous — NEVER execute without explicit sign-off)

| Item | What's known | Risk | Exact command (propose only) |
|---|---|---|---|
| **APFS local-snapshot thinning** — the single largest *potential* lever this pass identified | `diskutil apfs listSnapshots /` shows 3 snapshots, all `com.apple.os.update-*` (OS-update-prep, not Time Machine), all report `Purgeable: No` (macOS itself will not auto-clear them). One is explicitly flagged by `diskutil`: "NOTE: This snapshot limits the minimum size of APFS Container disk3." `scripts/cleanup_apfs_snapshots.sh` (dry-run) already identifies exactly 2 candidates for deletion (the container-shrink-limiting anchor, 57h old, and a second stale `MSUPrepareUpdate` snapshot) past its 1-day retention threshold. **Exact GiB this would free is unknown without deleting it** — APFS doesn't expose per-snapshot size cheaply, and this pass did not execute the deletion to find out. | High — deleting an OS-update-prep snapshot could theoretically interfere with an in-progress update rollback path; nobody has verified against Apple's actual rollback contract whether "not purgeable" really means "still needed" vs. just "not yet been the OS's own turn to clean it up." (See the systematic-fix doc's APFS-accounting proposal and its adversarial critique for why this pass explicitly does NOT pre-approve a heuristic here.) | `bash scripts/cleanup_apfs_snapshots.sh --clean` (currently would delete the 2 identified snapshots) — **do not run without explicit operator sign-off** |
| **291-406 GiB unattributed residual** (two different measurement passes today: frontier-BFS scan captured 2026-07-28T11:23:50Z = 291.0 GiB; live `disk_snapshot.json` checked this pass = 406.5 GiB — presented as two distinct data points from two different tools/times, not reconciled, per the "never mix measurement passes" rule) | Mostly OS-protected TCC paths (`~/Library/{Mail,Messages,Containers,Group Containers}`, `~/Library/Application Support/MobileSync` iPhone backups, `.DocumentRevisions-V100`, `.Spotlight-V100`, most of `/private/var/{networkd,install,spool,...}`) unmeasurable without a Full Disk Access grant, plus the APFS snapshot above, plus normal container overhead/free-space slack | Granting Full Disk Access to any tool (even a read-only accounting one) is a standing filesystem-wide privilege grant on macOS — there is no metadata-only or traversal-only TCC scope, so this is a real security/privacy tradeoff, not just a measurement inconvenience | Operator must decide: (1) grant FDA to a dedicated read-only `du`-only binary (never the cleanup scripts) to quantify this bucket, or (2) accept it as permanently unmeasured. No command to propose until that decision is made. |
| 42.2 GiB of `.claude/worktrees/*` under `~/projects/worldarchitect.ai` (131 agent/workflow worktrees, sampled at exactly 2 days old — well inside the mandatory 14-day floor) | Confirmed correctly protected by the existing worktree-recency rule; re-verified this pass indirectly via the full `worktree_hygiene.sh` census, which classified all of them PRESERVE (young), none SAFE | None — this is working as designed, not a bug | No action. Re-check with `worktree_hygiene.sh` once these age past 14 days. |

## What this plan does NOT claim

- It does not claim the 42+ GiB runaway Cursor CLI agent log (bead
  `disk_magician-ax0`, PID 95634) as a win of this pass — that log was
  already found, killed, and truncated by a human/operator action at
  02:36 PDT, **before** this mission's 04:24 PDT spawn. Not double-counted.
- It does not force a number to hit "200 GiB." The systematic-fix
  companion doc addresses the actual question implied by that target —
  why does routine reclaim capacity stay this thin — rather than this doc
  manufacturing a total that the evidence doesn't support.

## Verification

- Every executed item above has a before/after measurement from the
  script's own log output, not an estimate.
- `df -g /System/Volumes/Data` before this pass's cleanup actions: 829
  GiB used / 43 GiB avail. After: 823 GiB used / 43-55 GiB avail
  (fluctuating — this box has multiple concurrent producers/consumers
  running independently of this mission, per the root-cause report's own
  finding that whole-disk usage swings by tens of GiB from unrelated
  activity; the ~2.6 GiB this pass executed is a small, real, but not
  independently isolable slice of that larger swing).
- `git log --oneline -1` at time of writing this doc:
  `144845a fix(residual_drilldown): gate on absolute residual_gb, not delta`
  (committed and pushed this pass — see companion systematic-fix doc for
  why this fix matters).
