# Disk reclaim plan — 2026-07-29 sidekick pass

Mission: `disk_magician-xxv` ("sidekick: save-another-200g-systematic-fix").
State/log: `~/roadmap/disk_magician/sidekick/save-another-200g-systematic-fix/STATE.md`.
Companion doc: `roadmap/2026-07-29-systematic-fix-architecture-sidekick.md`.

**READ-ONLY MODE IN EFFECT (operator directive, 2026-07-29 ~04:33 PDT,
verbatim: "lets scope out what can change readonly and dont delete anything
yet").** Every "executed" item in Table 1 below happened BEFORE this
directive reached this session (message delivery lagged ~25 min behind
execution — full accounting in STATE.md, disclosed in full to the
team-lead). **From the moment this notice was added onward, this document
is proposal-only.** Nothing further will be executed, deleted, truncated,
or pruned without an explicit operator instruction, including items
previously identified as "safe class." Revised 2026-07-29 ~05:05 PDT with
corrections from independent `/ms` and `/history` recall passes — see the
"Corrections from /ms and /history recall" section before trusting any
number below in isolation.

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

## Table 3b — Large REVIEW-tier backlog, reconciled across four prior passes (proposal only, read-only)

**This is the highest-leverage bucket in the whole plan and was missing from
the original version of this doc.** Independent bead `disk_magician-7v3`
(re-triaged 2026-07-29 03:09 PDT, ~1h before this mission spawned) found
~76 GiB reclaimable with a concrete, code-level root cause for the largest
item. Critically, **four separate passes since 2026-07-17 have all
independently flagged the same underlying gap** — this is not a new
finding, it's the fourth confirmation of a known, never-closed item:

| Item | Measured (source) | Root cause | Exact command (propose only — READ-ONLY MODE, do not run) |
|---|---:|---|---|
| `.claude/worktrees/*/venv` + `venv.bak.<timestamp>` dirs across agent/workflow worktrees, some 26+ days old | ~25 GiB (`disk_magician-7v3`, 2026-07-29); as `.claude/worktrees` sweep this reconciles with 41 GiB (2026-07-17 plan) and 45.38 GiB (2026-07-20 plan, "most <14d and therefore protected") | **Gating gap, not a safety-floor issue:** `cleanup_worktree_venvs.sh` only walks `~/projects/worktree_*` and `~/worktrees_*` — it never walks into `<repo>/.claude/worktrees/*`, so the `.bak.<timestamp>` backups it correctly creates (as its own safety net) are never subsequently purged by anything, regardless of age. This is a code fix (extend the glob + add an age gate on `.bak.*` dirs specifically, which are pure backups with no live-worktree-protection concern once past a retention window), not a data-deletion decision — appropriate to actually build, once out of read-only mode. | No safe delete command exists yet — the fix is extending `cleanup_worktree_venvs.sh`'s scan glob, then running it in dry-run first. Do not hand-delete `.bak.*` dirs individually; that reproduces exactly the "grouped-row size misestimate" trap from `feedback_2026-07-18_verify_swarm_report_sizes_per_item_before_delete`. |
| 102 unreferenced Python venvs elsewhere | 32.98 GiB (2026-07-17 plan REVIEW tier) — status since unconfirmed, needs re-measurement, not re-assumed stale | Never executed from the original 700G plan; superseded plans (07-18, 07-20) each re-baselined without re-confirming this specific item was resolved | Re-measure via a scoped `find`+`du` pass before assuming this number still holds; do not delete from a 12-day-old measurement. |
| Duplicate-repo extras with embedded PATs, orphaned lima instance, ambiguous duplicate-repo groups, Antigravity/opencode logs | ~1.84 + 4.72 + 1.5 + 4.8 ≈ 12.9 GiB combined (2026-07-17 plan REVIEW tier, never executed) | Explicitly listed as "needs explicit user approval" in the original plan; no execution log entry found in any later doc | Re-measure each item individually before any action — same per-item-verification rule as above. |

**Security note, resolved this pass:** the 2026-07-17 plan flagged 3
live-looking GitHub PATs embedded in plaintext `.git/config` remote URLs
(worldarchitect.ai + jleechanclaw clones, filed as issues #25/#27).
Re-verified read-only this pass (2026-07-29 ~05:05 PDT): scanned 10
`.git/config` files across every worldarchitect.ai (2) and jleechanclaw (6
with a config; 4 candidate dirs had no direct `.git/config`, likely
worktrees) clone found on this machine for the `https://<user>:ghp_...@`
PAT pattern — **zero matches**, consistent with the original finding having
been remediated via the filed issues, or the specific flagged clones no
longer present at these paths. Not exhaustive across all ~580 worktrees on
the machine; no token values were printed at any point, only match/no-match
booleans. **Recommend operator spot-check a broader sweep if time allows,
but no active leak found in the targeted repos.**

## Table 4 — Needs-operator-decision (large, unmeasured-with-precision, genuinely ambiguous — NEVER execute without explicit sign-off)

Ranked by risk/effort, cheapest-and-safest first (revised this pass — FDA
now ranks above snapshot deletion, reversing the original draft's order,
per canonical memory `project_2026-07-15_disk_swing_mechanisms_confirmed`
and the 2026-07-22 sudo-failure precedent below):

| Item | What's known | Risk | Exact command (propose only) |
|---|---|---|---|
| **Grant Full Disk Access to cmux (the terminal host)** — ranks first: pure measurement unlock, zero deletion risk | Canonical finding (`project_2026-07-15_disk_swing_mechanisms_confirmed`, bead `jleechan-w5is`): the 213.9-406 GiB accounting gap (this pass measured up to 406.5 GiB, consistent with further growth since 07-15) is fully named as TCC/SIP-protected paths — `~/.Trash`, ~20 `~/Library` subtrees, 4 SIP dot-dirs — "not a hidden consumer; a permission wall." **MobileSync (iPhone/iPad backups) is called out as likely the single largest piece**, alongside Mail and Messages. As of that memory's writing, FDA had never been granted to cmux; **current status unknown to this pass** — a System Settings > Privacy & Security > Full Disk Access UI check, not verifiable from a shell probe. | Granting FDA to any tool is a standing filesystem-wide privilege grant on macOS — no metadata-only or traversal-only TCC scope exists — a real security/privacy tradeoff, but this option only enables *measurement*, never deletion, so its downside ceiling is lower than the snapshot-deletion option below. | Operator action in System Settings (not a shell command); once granted, re-run the frontier scan / `du` against the TCC paths to quantify, still without deleting anything. |
| **APFS local-snapshot thinning — has ALREADY failed once, needs interactive sudo, can never be a launchd/agent action** | `diskutil apfs listSnapshots /` shows 3 snapshots, all `com.apple.os.update-*` (OS-update-prep, not Time Machine), all report `Purgeable: No`. One is explicitly flagged: "NOTE: This snapshot limits the minimum size of APFS Container disk3." **This deletion was already attempted once, 2026-07-22, and failed**: `diskutil apfs deleteSnapshot` requires sudo that an unattended LaunchAgent does not have — "a documented, known limitation... macOS 15.5 does not let a user-mode LaunchAgent delete `com.apple.os.update-*` snapshots without sudo, and no sudoers wiring exists for this." Exact commands logged from that attempt: `sudo diskutil apfs deleteSnapshot disk3s1 -uuid 496C4D0C-6C17-48C9-836D-D8E391B74146` (the shrink-limiting anchor) plus the equivalent for the `MSUPrepareUpdate` snapshot. No evidence found this session that a human has run these since. **Note on snapshot state itself:** the 2026-07-20 100G pass found ZERO local snapshots present ("Purgeable delta: only ~5.8 GiB"); this pass's two live checks (04:26 and 05:00 PDT today) both found 3 present — most likely a macOS update ran between 07-20 and 07-29 and created these prep snapshots (consistent with their naming), not a measurement discrepancy between the two passes. **Exact GiB this would free is still unknown without deleting it.** | High: requires interactive `sudo` (an operator must type a password at a terminal — this can never be automated by a launchd job or an unattended agent, which is itself a durable structural reason this stays manual forever, not just "for now"), plus the unresolved rollback-safety question from the systematic-fix doc's APFS proposal critique. | `sudo bash scripts/cleanup_apfs_snapshots.sh --clean` (currently would attempt the 2 identified snapshots; will still need the operator to supply sudo credentials interactively) — **do not run without explicit operator sign-off, and note it cannot run inside this or any other unattended session regardless of approval.** |
| **291-406 GiB unattributed residual, restated** (two measurement passes today: frontier-BFS scan captured 2026-07-28T11:23:50Z = 291.0 GiB; live `disk_snapshot.json` checked this pass = 406.5 GiB — two distinct data points, not reconciled, per the "never mix measurement passes" rule) | See the FDA row above — this is the same bucket, restated for completeness since it's the number most often cited as "the 200 GiB target." | Same as FDA row. | No separate command; resolved by the FDA decision above, not independently actionable. |
| 42.2 GiB of `.claude/worktrees/*` under `~/projects/worldarchitect.ai` (131 agent/workflow worktrees, sampled at exactly 2 days old — well inside the mandatory 14-day floor) | Confirmed correctly protected by the existing worktree-recency rule; re-verified this pass indirectly via the full `worktree_hygiene.sh` census, which classified all of them PRESERVE (young), none SAFE | None — this is working as designed, not a bug | No action. Re-check with `worktree_hygiene.sh` once these age past 14 days. |

**FDA status correction (2026-08-27):** The current interactive shell can read
`~/Library/Application Support/MobileSync`, `~/Library/Mail`, and
`~/Library/Messages`. The FDA row above records the historical status of this
2026-07-29 pass; it is no longer accurate to describe those paths as unreadable
because cmux lacks Full Disk Access. Before relying on fresh attribution, the
scanner must run an access preflight in its own process and record any remaining
denials; an FDA grant alone does not prove complete coverage.

## Corrections from /ms and /history recall (added post-scope-change, 2026-07-29 ~05:05 PDT)

- **Two prior bugs this plan's earlier draft would have re-diagnosed from
  scratch are already fixed** (confirmed via direct, read-only code
  inspection, not re-assumed from a stale digest): `dedup_hermes_prompts.sh`
  now has a working `--delete-backups` flag (closes the 2026-07-22 12.9 GiB
  backup-leak incident class — this pass used it successfully before
  READ-ONLY MODE took effect); `symlink-shared-playwright-cache.sh` now has
  an `is_canonical_version_name()` guard that explicitly rejects its own
  `.bak.<timestamp>` naming (closes the 2026-07-22 canonical-resolution
  bug). Do not re-file beads for either.
- **`TMP_WORKTREES_APPROVED` is now wired**: `pressure_sweep.sh` line 213
  sets it alongside `LARGE_TMP_APPROVED=1` for its pressure-only call to
  `cleanup_tmp.sh` — the "no automated caller ever sets it" gap from
  2026-07-22 is closed. This does not fully explain away the dominant
  `/private/tmp` producer finding from the root-cause doc, since that
  producer's under-reclaim is a *guardian eligibility* problem (uncommitted/
  no-merged-PR), a different mechanism than this gate — both are real,
  addressing one doesn't close the other.
- **`host-disk-guardian`'s last-resort archive-to-quota tier is confirmed
  still NOT implemented** (grep of the live script found nothing matching)
  — this is exactly the systematic-fix doc's Layer 2 recommendation; no
  duplicate work needed, just execute that design once out of read-only
  mode and with operator sign-off.

## What this plan does NOT claim

- It does not claim the 42+ GiB runaway Cursor CLI agent log (bead
  `disk_magician-ax0`, PID 95634) as a win of this pass — that log was
  already found, killed, and truncated by a human/operator action at
  02:36 PDT, **before** this mission's 04:24 PDT spawn. Not double-counted.
- It does not force a number to hit "200 GiB." The systematic-fix
  companion doc addresses the actual question implied by that target —
  why does routine reclaim capacity stay this thin — rather than this doc
  manufacturing a total that the evidence doesn't support.

### Tier-math calibration against prior plans (added post-scope-change)

This pass's ~2.6 GiB immediately-safe, no-approval-needed number looks
small in isolation; calibrated against prior plans on this same machine,
it is exactly what's expected once the easy tier has already been mined
repeatedly:
- 2026-07-17 700G plan: 94.56 GiB SAFE tier + 98.04 GiB REVIEW tier (never
  fully executed).
- 2026-07-20 100G plan: ~22 GiB SAFE-AUTO executed / ~55 GiB REVIEW /
  ~86 GiB USER-ONLY (Messages, Photos, Mail, /Applications — never
  auto-touched, by design).
- **This pass, 2026-07-29: ~2.6 GiB immediately-safe.** Consistent with
  "the SAFE tier was already largely consumed by the three prior runs" —
  not a sign this pass under-delivered, but confirmation that repeated
  mining of the same machine converges toward the REVIEW and
  operator-decision tiers (Table 3b and Table 4 above) rather than new
  SAFE-tier discoveries. Future passes should expect the same pattern and
  budget accordingly, rather than re-running the same SAFE-tier sweeps
  expecting a similar yield.

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
