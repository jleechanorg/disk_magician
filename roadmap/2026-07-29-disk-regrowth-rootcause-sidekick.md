# Disk regrowth root-cause report — 2026-07-29 sidekick pass

Mission: `disk_magician-7io` ("sidekick: root-cause-disk-keeps-filling").
State/log: `~/roadmap/disk_magician/sidekick/root-cause-disk-keeps-filling/STATE.md`.
Disk at spawn: `/System/Volumes/Data` 833 GiB used / 29 GiB avail (97%
capacity). This report follows the mandatory three-lane structure: (1)
top-down reconciliation with explicit unattributed residual, (2)
coverage-validated growth-rate deltas, (3) safety-gated quick wins listed
separately from the explanation.

## Executive summary

**Trustworthy headline number:** whole-disk usage grew **+7.0 GiB/day net**
over the last 7.86 days (778 → 833 GiB used, from `df`-derived values in
`~/.disk_magician_backup` snapshot history — see Lane 2). This net figure
hides large sawtooth swings (reclaim events of -85, -28, and -27 GiB) on
top of a steadier upward creep, and a path-level ledger whose measurement
coverage has degraded in lockstep with disk pressure (down to 1.0%
coverage — 18 of 58 tracked paths — in the most recent snapshot). Do not
trust a single recent snapshot for "what's using disk right now"; this
report uses the 8-day union of snapshots plus independent live sampling
instead.

**The dominant currently-active producer, confirmed by two independent
measurement passes, is AO/CI `/private/tmp` scratch-worktree churn** —
not the launchd bugs below, though those compound the problem. Gross
production is ~23–25 GiB/day when unswept; the most recent unswept climb
was **+25.2 GiB/day sustained for 1.76 days** before the tracking key
itself timed out under load (true current size likely 65–75+ GiB,
unmeasured). Critically, `host-disk-guardian.log` shows its CRITICAL-tier
auto-clean firing 3 times in 2 minutes at 2–6 GiB free and processing
**zero** evidence bundles, scratchpads, or merged-PR worktrees each time —
every `/private/tmp/wa-pr-*` candidate is skipped for "no merged PR found"
or "uncommitted changes present". **The safety net is alive but
structurally cannot reclaim this path's current occupants** — this is the
answer to "why don't sweepers keep up," more directly than any of the
launchd-scheduling bugs below. See Lane 2.

Two structural launchd bugs were found and **fixed** in this pass, both of
which had silently zeroed out disk-reclaim automation for days:

1. Four weekly reclaim sweepers (colima-prune, hermes-vacuum,
   playwright-dedup, worktree-venvs) had **never fired once** since
   install (2026-07-23) — not a symptom of running-late, a structural
   starvation: `StartInterval=604800` (7 days) resets on every per-user
   launchd reload, and this Mac only reboots every ~2 days, so the
   interval can never accumulate. Fixed with `RunAtLoad=true`; verified
   all 4 fired for the first time immediately after the fix.
2. The daily growth-tracking snapshot job had been failing
   `EX_CONFIG` (exit 78) every day since 2026-07-25 because its
   `ProgramArguments` hardcoded a `python3.13` site-packages path that
   stopped existing after a `uv tool install --reinstall` bumped the
   interpreter to python3.14. Fixed by pointing at the stable uv-tool
   entrypoint instead of a version-pinned internal path.

A **third bug in the same "sweeper structurally cannot fire" class** was
found by measurement but not fixed: the residual-drilldown sweeper gates
on `residual_delta_gb` (snapshot-to-snapshot delta, ~0.4 GiB) instead of
the absolute `residual_gb` (400–824 GiB across this window), so it logs
"no-op" every ~40 minutes regardless of how catastrophic the absolute
unmeasured residual gets. Filed as bead `disk_magician-nea` (P1), not
fixed in this pass — see Lane 2.

Separately, two **currently-active, unfixed** producers were identified
and quantified:

- The `ez-mac-runner` self-hosted CI containers (image
  `ezgha-runner:latest`) are OOM-killed and relaunched roughly every
  30–40 minutes each — a churn rate no periodic sweeper can keep pace
  with. Out of `disk_magician`'s scope (an `ez-gh-actions` workload-config
  issue).
- Colima's sparse-disk trim/prune path is **currently broken**: the
  2026-07-29 `colima-prune` run hit an `input/output error` on a
  containerd blob during `docker image prune`, and the subsequent
  `fstrim -av` reclaimed **0 bytes** on the main volumes — independently
  corroborated by two separate measurement passes in this session (72.8
  GiB/day gross-up vs. 578.6 GiB gross-down churn over the 8-day window,
  net only -0.90 GiB/day because the trim isn't landing).

The system was also observed under extreme, unrelated CPU load during this
session (load average swinging 33–959) severe enough that trivial shell
commands took >60s to return — noted as a contributing/related
observation, not independently root-caused.

## Lane 1 — Top-down reconciliation (≥5 GiB granularity, explicit residual)

Source: `~/.disk_magician_state/frontier_last.json` (schema v2 frontier
BFS scan, captured 2026-07-28T11:23:50Z, 42.7 min wall-clock, 5,897
buckets capped at ≤5 GiB granularity each).

| Metric | Value |
|---|---|
| Disk total | 926.5 GiB |
| Disk used (at capture) | 823.7 GiB |
| Disk free (at capture) | 56.2 GiB |
| Measured (attributed) | 532.8 GiB (64.7% of used) |
| **Unattributed residual** | **291.0 GiB (35.3% of used)** |

For context: the 2026-07-22 root-cause pass measured 306.8 GiB attributed
of 852 GiB used (36% coverage, 545 GiB residual) and explicitly concluded
further residual-chasing was not productive with available introspection
(OS-protected/TCC/SIP paths, APFS purgeable/snapshot space). The residual
has shrunk from 545 → 291 GiB since then, but **mostly because the v2
frontier scan's measurement coverage improved (36% → 64.7%)**, not because
actual disk usage dropped much (852 → 823.7 GiB, a modest ~28 GiB
decrease). This report does not re-litigate that residual composition;
see `roadmap/2026-07-22-disk-regrowth-rootcause.md` §"Reclaimable residual"
for what was already ruled out.

Top attributed producers, aggregated to ~4 path levels under
`/System/Volumes/Data` (top 15 of 40+ collected, full list in mission
STATE.md):

| GiB | Path |
|---:|---|
| 50.88 | `~/projects/worldarchitect.ai` |
| 21.32 | `~/.codex/sessions` |
| 17.33 | `/private/var/folders/j0` |
| 16.46 | `~/Library/Application Support` |
| 12.93 | `~/.gemini/antigravity-cli` |
| 12.70 | `~/project_worldaiclaw/worldai_claw` |
| 11.27 | `~/Library/Developer` |
| 9.62 | `~/Library/Caches` |
| 9.27 | `~/.worktrees/worldarchitect` |
| 9.16 | `~/projects/user_scope` |
| 7.85 | `~/.claude/projects` |
| 5.75 | `~/.ao/data` |
| 5.64 | `~/.codex` (direct, excl. sessions) |
| 5.57 | `~/.colima/_lima` |
| 5.22 | `~/.nvm/versions` |

`~/projects/worldarchitect.ai` at 50.88 GiB (54.32 GiB by a second,
slightly different pass over the same frontier buckets — within the
scanner's own known accounting slack, see Addendum) is the single largest
attributed item. Broken down from the frontier scan's own sub-buckets:

- **42.20 GiB (78%) in `.claude/worktrees/*`** — 131 distinct
  agent/workflow worktrees (`agent-<hash>`, `wf_<id>`). Sampled 8 of 131 at
  random with the canonical `worktree_age_days` helper
  (`scripts/lib/worktree_recency.sh`, real content-mtime measurement, not
  a proxy): **all 8 measured exactly 2 days old** — well inside the
  mandatory 14-day protected window, and consistent (not a fail-closed
  default, which reads differently). **For cleanup purposes this is
  correctly protected — not a safe reclaim target.** But for root-cause
  purposes, standing stock ÷ observed age is itself a rate finding: 42.2
  GiB accumulated in ~2 days is **on the order of ~20 GiB/day of
  in-repo agent-worktree production** (a rough derivation from
  stock/age, not a direct measured delta — treat as an estimate). This
  independently corroborates the historical "AO worktree churn" producer
  class from the recall sweep, this time landing inside a project
  checkout (`~/projects/worldarchitect.ai/.claude/worktrees/`) rather than
  `/private/tmp`, and reads as part of the same underlying burst of
  concurrent agent activity responsible for the extreme CPU load and
  container churn documented in the Executive Summary. Re-sample in a
  future pass once agent activity on this repo quiets down; if a
  meaningful fraction age past 14 days, the existing worktree-hygiene
  tooling can reclaim it then.
- 5.94 GiB in `.git/` (mostly the 4.70 GiB pack file — normal git
  history, not a leak).
- 3.27 GiB across other worktree-adjacent dirs (`worldarchitect.ai.worktrees`,
  `.worktrees`, `.git/worktrees`) — same 14-day protection applies, not
  independently sampled this pass.
- Remainder (~2-3 GiB) not broken down further — `venv/`, `.beads/`, and
  smaller items below the ≥5-item cutoff used here.

## Lane 2 — Coverage-validated growth-rate deltas

### Primary source (authoritative, 7.86-day window): `measure-deltas.md`

A parallel measurement teammate mined `~/.disk_magician_backup` git history
(266 parsed `disk_snapshot.json` blobs across 273 commits, 2026-07-21 04:52
→ 2026-07-29 01:23, READ-ONLY, no commits/gc/prune performed) — see
`~/roadmap/disk_magician/sidekick/root-cause-disk-keeps-filling/measure-deltas.md`
for full methodology and raw artifact paths.

**Whole-disk `df` trend (the only fully-trustworthy number in this
report):** 778 → 833 GiB used over 7.855 days = **+7.0 GiB/day net**, free
107 → 29 GiB, capacity 84% → 89% (peaked 93% mid-window). Not monotonic —
large sawtooth reclaim events are superimposed on the upward trend: -85
GiB in 78 minutes (2026-07-23), -28 GiB (2026-07-25→26), -21 GiB
(2026-07-24), -18 GiB (2026-07-26), -27 GiB (2026-07-28→29, immediately
preceding a coverage collapse).

**Coverage caveat — do not trust the most recent snapshot alone:**
`snapshot_coverage_pct` degrades in lockstep with disk pressure, exactly
as a prior finding predicted. It fell from 62.0% (77/77 paths, window
start, healthy) to **1.0% (18/58 paths) at window end** — the snapshot
that matters most for "what's using disk right now" has essentially
collapsed (`tmp_private`, `colima`, `codex_root`, `claude_root`, `hermes`,
`ao_sessions`, `worktrees_dot`, and 30+ others read `null`/timed out). The
824.5 GiB `residual_gb` in that final snapshot is not newly-discovered
dark matter — it's mostly the same paths that measured fine an hour
earlier, now timing out under load. The nightly frontier-BFS top-down scan
is worse still: it returned `measured_total_kb: 0` (0% coverage) for
**three consecutive nights** (2026-07-25, 26, 27) before one partial
success on 2026-07-28 (532.8 GiB measured, 290.9 GiB residual — the
figures used in Lane 1 above), which is now >21 hours stale with no
refresh since.

**Top identified producers, ranked by gross production (the real
root-cause ranking — net alone hides active-but-swept churn):**

| Producer | Net GiB/day | Gross-up GiB/day | Status |
|---|---:|---:|---|
| `tmp_private` (`/private/tmp`, AO/CI scratch worktrees) | +4.97 (8-day avg) | ~23–25 (most recent unswept climb: **+25.2 sustained 1.76 days**) | **ACTIVE, currently invisible to tracker (timed out last 4 snapshots)** |
| `colima` (sparse VM disk) | -0.90 | 72.76 (578.6 GiB gross-down over window) | Trim/prune **currently broken** (I/O error, 0 bytes trimmed) |
| `worktrees_dot` (`~/.worktrees`) | +1.47 | 2.94 | Steady grower, **not swept at all currently** |
| `gemini_root` (`~/.gemini`) | +1.30 | 1.47 | Growing, **no sweeper** |
| `library_developer` (Xcode/DerivedData-class) | +1.03 | 2.17 | Partial sweeps, net still climbing |
| `projects` (whole `~/projects`) | +0.50 | 7.21 (52.3 GiB gross-down) | Git checkout/rebase churn, mostly self-correcting via 14-day sweeper |
| `ao_home` | +0.88 | 1.25 | Monotonic, **zero observed reclaim** over the window |
| `ao_sessions` | +0.71 | 0.71 | Monotonic, **zero reclaim**, same AO family as above |

`library_messages` (27.25→0.45 GiB, one real step-change, likely a
one-time Messages-cache clear of uncertain provenance) and `pictures`
(13.7→0.0 GiB) are excluded from the table above: `pictures` is confirmed
**measurement noise**, not a real trend — it flaps repeatedly between
exactly 13.7 and 0.0 GiB with no intermediate values, a `du`/timeout
artifact under load. `hermes`/`hermes_prod` are the same physical
directory (symlink alias) — net -0.79 GiB/day, driven by the
`hermes-vacuum` fix's WAL checkpoint (which flushes the WAL but does not
shrink the 6,130.9 MB main `state.db` — a full guarded `VACUUM` has not
run, by design).

**Why the sweepers can't keep up with the #1 producer:**
`host-disk-guardian.log` (2026-07-29 00:46–00:48 local) shows the
CRITICAL-tier auto-clean firing 3 times in 2 minutes at 2/3/6 GiB free,
processing **0 evidence bundles, 0 scratchpads, 0 merged-PR worktrees**
every single time — every `/private/tmp/wa-pr-*` candidate is skipped
because it has "no merged PR found for this branch" or "uncommitted
changes present." The safety net is running, on schedule, and structurally
cannot touch the thing that's filling the disk. This is a materially
different (and more currently-relevant) answer than the launchd-scheduling
bugs fixed elsewhere in this report — those bugs meant sweepers didn't
*run*; this one means a sweeper runs perfectly and still can't reclaim
anything, because its own safety gate (no merged PR / no uncommitted
changes) is being tripped by every candidate.

**New prevention-gap bug found, not yet fixed:** `/tmp/disk-magician-drilldown.log`
shows the residual-drilldown sweeper firing every ~40 minutes and logging
"residual 0.4 GB < threshold 10 GB — no-op," even while `residual_gb` in
the *same* snapshots is 400–824 GiB. The gate checks `residual_delta_gb`
(snapshot-to-snapshot delta, ~0.4 GiB) instead of the absolute
`residual_gb` — so it can never fire regardless of how catastrophic the
absolute unmeasured residual gets. Filed as bead `disk_magician-nea` (P1).

### Secondary source (shorter window, independent data): `disk_observer.jsonl`

This session's own earlier pass over `~/.disk_magician_state/disk_observer.jsonl`
(2,631 records, 2026-07-27 05:24 → 2026-07-29 01:15, 1.83 days) is a
narrower window but an independent data source, and its findings are
consistent with the above: net -2.35 GiB/day but a **62 GiB peak-to-trough
swing in under 2 days** (802.6 → 864.5 GiB), steepest single-hour rise
+26.9 GiB. Docker event counts in one 21-hour climb window: **919
`create`, 903 `die`, 925 `destroy`, 897 `start`, 361 `oom`** — all 551 OOM
events across the full observer history are on `ezgha-runner:latest`
across 6 named containers, each OOM'd 68–97 times in under 2 days (see
`findings_wiki/extreme-cpu-load-and-ezgha-runner-oom-churn.md`). This
data source also captured **direct before/after proof of the RunAtLoad
fix**: used space dropped from an 859.3 GiB peak to 832.6 GiB (-26.7 GiB)
in the window immediately following all 4 sweepers firing for the first
time ever.

Coverage caveat: the daily growth-tracking snapshot
(`~/projects/user_scope/backup/Mac/disk_snapshot.json`) was stale
2026-07-25 → 2026-07-29 due to the `EX_CONFIG` bug (Lane fix #2 above), so
this secondary source leans on `disk_observer.jsonl` (fine-grained,
unaffected by that specific bug) rather than the daily snapshot series.

## Lane 3 — Safety-gated quick wins (reported separately — NOT the root-cause explanation)

These are recommendations, not actions taken in this pass, and require
`scripts/safety_check.sh` + the worktree 14-day rule before any deletion:

1. **`ez-gh-actions` runner memory limit.** Raise the per-container memory
   limit (or reduce concurrent runner count) for `ezgha-runner:latest` to
   stop the ~30–40-minute OOM-cycle per runner. This is the single highest
   -leverage fix available — it addresses the producer, not the sweeper.
   Out of `disk_magician`'s scope to change directly; file/track in
   `ez-gh-actions`.
2. **`~/projects/worldarchitect.ai` (50.88 GiB) — mostly NOT currently
   reclaimable.** Broken down in Lane 1 above: 42.20 GiB is 131 active
   `.claude/worktrees/*` agent worktrees, sampled and measured at 2 days
   old (well inside the 14-day floor) — this is in-flight work, not a
   quick win today. Re-run the sample (or a full census) with
   `scripts/lib/worktree_recency.sh` in a future pass once agent activity
   on this repo quiets down; anything that ages past 14 days becomes a
   real reclaim target for the existing worktree-hygiene tooling.
3. **`colima-prune` I/O error — now corroborated, still not root-caused.**
   Two independent measurement passes this session confirm `docker image
   prune -af` is currently failing with an `input/output error` on the
   containerd blob store, and `fstrim -av` is reclaiming 0 bytes on the
   main volumes — this is very likely the documented "Colima sparse disk
   wedges under host disk pressure" gotcha (host has been at 93-97%+
   throughout this session), but a definitive root-cause confirmation
   (e.g. via `colima ssh -- dmesg` or an explicit stop/start/fstrim cycle)
   was not performed this pass — worth doing once host free space is more
   comfortable, since attempting the guest-VM restart cycle while the
   host itself is critically low on space carries its own risk.
4. **`disk_magician-w7m`** (new bead, P2): confirm or refute the
   overlapping `cleanup_worktree_venvs.sh` PIDs observed right after the
   `RunAtLoad` fix; add a flock-style lock if it reproduces under normal
   (non-extreme-load) conditions.
5. **`disk_magician-nea`** (new bead, P1): fix the residual-drilldown
   sweeper's gate to check absolute `residual_gb` instead of
   `residual_delta_gb` — see Lane 2. Low-risk, mechanical fix (change a
   threshold comparison), but out of this pass's time budget to implement
   and verify safely.
6. **`host-disk-guardian`'s emergency-tier candidate filter is too
   strict for a real emergency.** At 2-6 GiB free, the guardian correctly
   refuses to touch `/private/tmp/wa-pr-*` worktrees with uncommitted
   changes or no merged PR — appropriate caution under normal pressure,
   but it means the CRITICAL tier has no actual fallback when literally
   every candidate fails that check (observed live: 3 consecutive
   CRITICAL-tier runs, 0 reclaims each). Recommend a genuinely
   last-resort tier (e.g. archive-not-delete uncommitted scratch worktrees
   to a separate volume/quota once free space crosses a harder floor like
   1-2 GiB) rather than silently no-op'ing at the point of actual
   emergency. Design change, not a quick win — flagging for a dedicated
   follow-up, not implemented this pass.

## Fixes landed this session (durable, committed)

- `disk_magician` repo: `launchd/com.disk-magician.{colima-prune,
  hermes-vacuum,playwright-dedup,worktree-venvs}.plist` +
  `src/disk_magician/launchd/` packaged copies — added `RunAtLoad=true`.
  Installed live via `scripts/install_launchd_sweepers.sh`.
- `user_scope` repo: `dotfiles/launchd/com.jleechan.user-scope-disk-snapshot.plist`
  — `ProgramArguments` now uses the stable `~/.local/bin/disk-magician`
  entrypoint instead of a `python3.13`-pinned internal path; also fixed a
  latent `projects_other` → `projects` path-drift bug in the same
  template. Live plist updated and reloaded to match.
- `findings_wiki/`: 3 new docs — see file list below.
- Bead `disk_magician-w7m` opened for the unconfirmed overlapping-sweeper
  follow-up.

## Addendum — cross-referenced with /history + /ms recall (integrated post-write)

The main session ran parallel `/history` and `/ms` sweeps
(`recall-history.md`, `recall-ms.md`, same STATE.md directory) and forwarded
them. Key items that change or extend the picture above:

- **UPDATE (superseded by direct measurement, see Lane 2): AO `/tmp`
  scratch-worktree churn is CONFIRMED still live today.** The recall
  originally cited historical rates up to ~97 GiB/day for this producer
  (root-caused to `scripts/cleanup_tmp.sh:50`'s permanent protected-root
  allowlist plus a `TMP_WORKTREES_APPROVED` gate no automated path ever
  sets — `2026-07-22-disk-regrowth-rootcause.md` §2-3). Rather than rely
  on that historical figure or the bead IDs below, this session's Lane 2
  measurement directly confirms the mechanism is still active *right now*:
  `tmp_private` shows a +25.2 GiB/day sustained unswept climb as of
  2026-07-28, and `host-disk-guardian.log` shows its CRITICAL-tier cleaner
  firing 3x with 0 reclaims each time because every candidate fails the
  "no merged PR" / "no uncommitted changes" safety check. This is now the
  Executive Summary's headline finding, not an open question.
- **`backup-home.sh` duplicate `/tmp` writes — checked live, appears
  ALREADY FIXED in the current script, contrary to the recall's citation
  of an open ~40 GiB/day bug.** Read `~/projects/user_scope/scripts/backup-home.sh`
  directly: it uses `SECURE_TEMP="$(mktemp -d)"` with `trap cleanup EXIT`
  (`cleanup() { rm -rf "$SECURE_TEMP"; }`) and a second nested trap for its
  per-target snapshot temp dir — no unbounded `/tmp` accumulation pattern
  found. `launchctl print gui/<uid>/org.jleechan.user-scope-backup` shows
  it ran most recently at 2026-07-29 01:05 (in progress at time of check);
  its log shows normal git-commit/push cycles to `user_scope`, not runaway
  `/tmp` growth. One live anomaly noted but not chased further: `launchctl
  list` shows this job's last exit code as `-9` (SIGKILL) from a prior run
  — worth a follow-up if it recurs, but does not on its own indicate the
  historical duplicate-writes bug is still present.
- **Both `jleechan-dqiz` and `bd-m8w` remain unlocatable** as open (or at
  all) across `disk_magician`, `worldarchitect.ai`, and `user_scope` beads
  databases checked (100+ `.beads/` directories exist across
  `~/projects/*` worktrees; not exhaustively searched). Given the live
  reproduction above supersedes the need for the bead-ID reconciliation
  for root-cause purposes, this is noted but not pursued further this
  pass.
- **`disk_magician-1f9` (P0, open):** whole-root AO `.gemini` symlink
  corruption (an unattended alias script materialized onto a real AO PR).
  Code fix already implemented (branch `fix/agy-dedup-alias-contract`,
  disk_magician PR #49) — open only pending merge + existing-alias
  migration/rollback verification, not a fresh finding for this report.
- **Frontier-scanner accounting caveat applies to this report's own Lane 1
  numbers.** Beads `jleechan-df3k`/`jleechan-rvqz` (open) track a known
  defect where the scanner's displayed ≥5 GiB buckets and its
  `measured_total_kb` are computed from different bases and don't always
  reconcile. Checked against this session's own `frontier_last.json`:
  `granularity_bucket_total_kb` (525.6 GiB) undershoots `measured_total_kb`
  (532.8 GiB, the figure used above) by **~7.2 GiB** — the same defect
  class, smaller magnitude than the 55.7 GiB overage that reopened `rvqz`,
  but present. Treat the 291.0 GiB residual figure as accurate to within
  roughly this margin, not as a fully closed accounting equation.
- **Growth-rate telemetry gap worth verifying:** the regrowth-prevention
  series' "part C" (linear regression of KB/day per top-level dir) was
  described as shipped 2026-07-06, but the recall found no roadmap doc
  confirming a currently-running dashboard/output path for it. This
  session's Lane 2 numbers came from ad hoc analysis of
  `disk_observer.jsonl`, not from that telemetry — if part C is actually
  live somewhere, it should be the canonical source going forward instead
  of one-off analysis.
- **35-min snapshot's own blind spot on its largest trees:** per
  `2026-07-22-disk-regrowth-rootcause.md` §3.6/§4.4 (not independently
  re-verified this session), `du` timeouts on the 5 largest monitored
  trees (`projects`, `root_library`, `worktrees_dot`, `tmp_private`,
  `library_containers`) get recorded as literal `0` rather than "stale,"
  which would make those trees appear to shrink to zero in naive
  day-over-day diffs while `disk_used_gb` keeps climbing. Not confirmed
  fixed; worth checking before trusting the 35-min snapshot series for
  delta attribution on exactly the trees that matter most.

## Durable artifacts

- This report: `roadmap/2026-07-29-disk-regrowth-rootcause-sidekick.md`
- `findings_wiki/weekly-sweepers-never-fired-startinterval-reboot-starvation.md`
- `findings_wiki/daily-snapshot-python-version-path-drift.md`
- `findings_wiki/extreme-cpu-load-and-ezgha-runner-oom-churn.md`
- Mission state: `~/roadmap/disk_magician/sidekick/root-cause-disk-keeps-filling/STATE.md`
- Bead: `disk_magician-7io` (mission), `disk_magician-w7m` (follow-up)
