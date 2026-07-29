# Disk regrowth root-cause report — 2026-07-29 sidekick pass

Mission: `disk_magician-7io` ("sidekick: root-cause-disk-keeps-filling").
State/log: `~/roadmap/disk_magician/sidekick/root-cause-disk-keeps-filling/STATE.md`.
Disk at spawn: `/System/Volumes/Data` 833 GiB used / 29 GiB avail (97%
capacity). This report follows the mandatory three-lane structure: (1)
top-down reconciliation with explicit unattributed residual, (2)
coverage-validated growth-rate deltas, (3) safety-gated quick wins listed
separately from the explanation.

## Executive summary

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

Separately, a **currently-active, unfixed** producer was identified and
quantified: the `ez-mac-runner` self-hosted CI containers (image
`ezgha-runner:latest`) are OOM-killed and relaunched roughly every 30–40
minutes each, generating on the order of one full container lifecycle per
minute across the fleet — a churn rate no periodic sweeper can keep pace
with. This is reported as a root cause and a quick-win recommendation, not
fixed in this pass (it's an `ez-gh-actions` workload-config issue, outside
`disk_magician`'s scope).

The system was also observed under extreme, unrelated CPU load during this
session (load average swinging 33–959) severe enough that trivial shell
commands took >60s to return — noted as a contributing/related
observation, not independently root-caused.

**Read the Addendum before treating this report as complete.** A parallel
`/history` + `/ms` sweep surfaced two previously-diagnosed producers
(~97 GiB/day AO `/tmp` scratch churn, ~40 GiB/day `backup-home.sh`
duplicate writes) that, if still active, would dwarf everything in this
session's own measurements — their cited bead IDs could not be
re-confirmed open in this pass, so their current status needs a fresh
check, not an assumption either way.

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

`~/projects/worldarchitect.ai` at 50.88 GiB is the single largest
attributed item and is flagged as a quick-win candidate for a follow-up
`du`/worktree-hygiene pass (likely nested worktrees + git pack objects +
node_modules; not broken down further in this pass — time-boxed out, see
Lane 3).

## Lane 2 — Coverage-validated growth-rate deltas

Source: `~/.disk_magician_state/disk_observer.jsonl` (2,631 records,
sampled every few minutes, span 2026-07-27 05:24 → 2026-07-29 01:15, 1.83
days).

- Net change over the full span: 837.1 → 832.8 GiB used (**-4.3 GiB**,
  ≈ **-2.35 GiB/day** net) — but net is a misleading headline here.
- Actual behavior is **highly volatile, not monotonic**: used space swung
  from a min of 802.6 GiB (2026-07-27 14:17) to a max of 864.5 GiB
  (2026-07-28 23:16) — a **62 GiB peak-to-trough swing inside under 2
  days**.
- Steepest single-hour rise measured: **+26.9 GiB in one hour**
  (2026-07-27 14:32 → 15:32).
- Colima's sparse-disk allocation (`root_allocated_kb`) swung between 2.7
  GiB and 41.6 GiB over the same window, consistent with the documented
  sparse-disk-grows-under-churn / shrinks-only-via-in-VM-fstrim behavior,
  but colima alone does not explain the sustained +34 GiB climb from
  2026-07-28 02:24 (825.3 GiB used) to 23:24 (859.3 GiB used) — colima
  stayed flat/low (5.6–11 GiB) for most of that climb.
- Docker event counts in that same 21-hour climb window: **919 `create`,
  903 `die`, 925 `destroy`, 897 `start`, 361 `oom`** — see Executive
  Summary and `findings_wiki/extreme-cpu-load-and-ezgha-runner-oom-churn.md`.
  All 551 OOM events across the full observer history are on
  `ezgha-runner:latest` across 6 named containers, each OOM'd 68–97 times
  in under 2 days.
- **Direct before/after proof of the RunAtLoad fix (Lane-1-adjacent, not a
  quick win — this is the structural fix landing):** the observer's very
  last sample before this report shows used space dropping from the
  859.3 GiB peak to 832.6 GiB (**-26.7 GiB**) in the window immediately
  following the `RunAtLoad` fix landing and all 4 sweepers firing for the
  first time ever (colima `docker prune`, hermes-vacuum WAL checkpoint,
  playwright-dedup, worktree-venvs). `df` immediately after this session's
  work confirms 833 GiB used / 29 GiB avail (97%) — back near the spawn
  baseline despite the intervening 859 GiB peak.

Coverage caveat: the daily growth-tracking snapshot
(`~/projects/user_scope/backup/Mac/disk_snapshot.json`) was stale
2026-07-25 → 2026-07-29 due to the `EX_CONFIG` bug (Lane fix #2 above), so
this report leans on `disk_observer.jsonl` (fine-grained, unaffected) for
the delta lane rather than the daily snapshot series, which only regained
validity mid-session.

## Lane 3 — Safety-gated quick wins (reported separately — NOT the root-cause explanation)

These are recommendations, not actions taken in this pass, and require
`scripts/safety_check.sh` + the worktree 14-day rule before any deletion:

1. **`ez-gh-actions` runner memory limit.** Raise the per-container memory
   limit (or reduce concurrent runner count) for `ezgha-runner:latest` to
   stop the ~30–40-minute OOM-cycle per runner. This is the single highest
   -leverage fix available — it addresses the producer, not the sweeper.
   Out of `disk_magician`'s scope to change directly; file/track in
   `ez-gh-actions`.
2. **`~/projects/worldarchitect.ai` (50.88 GiB).** Largest single
   attributed item; not broken down in this pass. Follow-up: run the
   existing worktree-hygiene / dedup tooling against it specifically,
   respecting the 14-day worktree-recency rule.
3. **`colima-prune` I/O error.** The first-ever `colima-prune` run hit
   `input/output error` on one containerd blob during `docker image prune
   -af`. Possibly the known "Colima sparse disk wedges under host disk
   pressure" gotcha (host was at 97%+ at the time) — not confirmed root
   cause, worth a recheck once host free space is more comfortable.
4. **`disk_magician-w7m`** (new bead, P2): confirm or refute the
   overlapping `cleanup_worktree_venvs.sh` PIDs observed right after the
   `RunAtLoad` fix; add a flock-style lock if it reproduces under normal
   (non-extreme-load) conditions.

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

- **Known larger, still-unresolved producers exist and predate this
  session's findings.** Per `2026-07-22-disk-regrowth-rootcause.md` §2-3
  and `nextsteps-2026-07-12-disk-magician-root-cause.md`: (a) AO `/tmp`
  scratch-worktree churn measured up to **~97 GiB/day**, root-caused to
  `scripts/cleanup_tmp.sh:50`'s permanent protected-root allowlist
  (`worldarchitect.ai worldai_claw wa-missions` — 24 GiB / 56% of
  `/private/tmp` excluded by basename forever) plus a `TMP_WORKTREES_APPROVED`
  gate that no automated path ever sets; (b) `backup-home.sh` (user_scope
  repo) writing duplicate rsync output to `/tmp` at an estimated
  **~40 GiB/day**. The recall cited these as open beads `jleechan-dqiz` and
  `bd-m8w`, but **this session could not re-locate either ID** as open (or
  at all) in the `worldarchitect.ai` or `user_scope` beads databases
  checked — either resolved-and-pruned, or a repo/scope mismatch worth
  reconciling before assuming either is still live. The underlying roadmap
  citations are durable regardless of bead-ID status and are worth a fresh
  measurement pass, since ~97 + ~40 GiB/day would dwarf everything found in
  this session if still active today.
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
