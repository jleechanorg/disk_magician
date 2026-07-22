# Disk regrowth root cause — 2026-07-22

Mission: `jleechan-4dtg` (swarm `disk-cleanup-automation-20260722`), lane1-rootcause.
Read-only analysis. Data volume (`/dev/disk3s5`, mounted `/System/Volumes/Data`)
at 852 GiB used / 17 GiB free / 99% full at time of writing (`df -h
/System/Volumes/Data`, 2026-07-22T19:50Z). Free space has been oscillating
13-44 GiB over the last 24h — the pressure-sweep threshold (40 GiB) keeps
firing but not recovering headroom (see §3).

## 1. Top-down breakdown (≥5 GiB granularity, explicit residual)

Sources: `du -d1 -g` direct measurement (this session, 2026-07-22 ~19:40-19:50Z)
cross-checked against `~/.disk_magician_backup/snapshots/disk_snapshot.json`
(35-min sweeper, commit `b95fee5`, captured `2026-07-22T19:16:59Z`) and
`~/.disk_magician_state/frontier_last.json` (frontier scan, captured
`2026-07-22T11:26:33Z`, 45-min bounded run, `mode: partial`).

| Bucket | Size (GiB) | Evidence |
|---|---:|---|
| `/Users/jleechan/projects` | 124 | `du -d1 -g` this session; `worldarchitect.ai` main clone = 59 GiB, remaining ~65 GiB spread across ~290 `wt-*`/`worktree_*` AO scratch dirs |
| `/private/tmp` | 43 | `du -d1 -g`; see §2 breakdown |
| `/Library` | 36 | `du -d1 -g`; `/Library/Developer/CoreSimulator` = 31 GiB (Xcode simulator runtimes/caches) |
| `~/.worktrees` | 26 | `du -d1 -g`; ~70 subdirs, largest `worldarchitect` = 6 GiB |
| `~/.codex` (sessions + sqlite) | ~29 | `disk_snapshot.json` `codex_root` |
| `~/.hermes` (+ `.hermes_prod` symlink alias, deduped) | 22.4 | `disk_snapshot.json` `hermes` |
| `~/.colima` | 16.8 | `du -d2 -g`; `_lima/_disks` = 10 GiB (VM disk backend — **not** the same as the "1.7 GiB diffdisk" cited in the mission brief, which undercounts the full `_lima` tree) |
| `~/.claude` (root + `.claude/projects` nested) | ~9.6 | `disk_snapshot.json` `claude_root`/`claude_projects` |
| Sum of measured buckets above | **~306.8** | matches `frontier_last.json` `measured_kb` (306 GiB) and `disk_snapshot.json` `tracked_total_kb_deduped` (305 GiB) — internally consistent |
| **Unattributed residual** | **~545** | `852 (df used) − 306.8 (measured)`; matches `frontier_last.json` `accounting_equation.residual_kb` = 536-548 GiB, labeled `protected_or_apfs_allocation_not_attributable_by_this_session` (APFS purgeable pool, TCC/SIP-protected paths, Photos/Mail/Messages libraries, MobileSync — none of which any sweeper in this repo currently measures or cleans) |

Local APFS snapshots checked and ruled out as a residual contributor: only 3
exist (`tmutil listlocalsnapshots /`), all tiny `com.apple.os.update-*`
OS-update prep snapshots, and `diskutil apfs listSnapshots
/System/Volumes/Data` reports none on the data volume itself.

## 2. #1 growth source: `/private/tmp` AO scratch, structurally un-sweepable

`/private/tmp` grew **18.1 GiB → 43 GiB (+25 GiB) in ~30 hours**
(`disk_snapshot.json` `tmp_private` key, first commit `b46e6f2`
2026-07-21T13:57:31Z vs last commit `b95fee5` 2026-07-22T19:16:59Z).
`/Users/jleechan/projects` grew a further **114.8 GiB → 124 GiB (+9 GiB)** in
the same window (same source, `projects` key — confirmed via direct
re-measurement since the sweeper itself lost visibility on this key, see §4).

Breakdown of the 43 GiB in `/private/tmp` today:
- `worldarchitect.ai/` — 17 GiB
- `wa-missions/` — 7 GiB
- `_disk_magician_archive/` — 4.3 GiB (**this repo's own cleanup archive
  output** — see §3.4)
- ~290 remaining `wa-fix-*`, `wc-*`, `test-send-*`, `worktree_*`,
  `pr*-verify*` dirs — mostly 1-2 GiB each, all AO/mission scratch

`find /private/tmp -maxdepth 1 -type d -newermt '2026-07-21'` returns **250**
dirs (vs **0** older than 2026-07-15) — this is fresh, ongoing churn, not
stale accumulation the sweeper simply hasn't reached yet.

## 3. Why the existing 13 sweepers didn't catch it

`launchctl list | grep -i disk-magician` confirms all sweepers are loaded
and firing on schedule (`com.jleechanorg.disk-magician-pressure-sweep`,
`com.jleechan.cleanup-ao-tmp`, etc. all present, exit status 0). The gap is
not "sweeper broken/not scheduled" — it's that the sweep logic's own safety
gates neuter it against exactly the directories that dominate the growth.

### 3.1 Hardcoded permanent protected-root allowlist (structural, not age-based)

`scripts/cleanup_tmp.sh:50`:
```
DEFAULT_PROTECTED_TMP_ROOTS=(worldarchitect.ai worldai_claw wa-missions)
```
`worldarchitect.ai` (17 GiB) and `wa-missions` (7 GiB) — 24 GiB, 56% of
`/private/tmp` — are excluded from every cleanup pass **by basename, forever,
regardless of size or age** (`cleanup_tmp.sh:362,394,415`, log lines confirm
`"Skipping protected root (in PROTECTED_TMP_ROOTS): ..."` firing repeatedly
in `~/Library/Logs/disk-magician-pressure-sweep.log`). Their mtimes were
`2026-07-22 12:15` and `2026-07-22 12:43` at scan time — actively written,
so even an age-based override wouldn't help without also being pressure-aware.

### 3.2 `TMP_WORKTREES_APPROVED` gate is never granted by any automated path

`scripts/cleanup_tmp.sh:544-545`:
```
log "Skipping temp worktree dir (requires TMP_WORKTREES_APPROVED=1): $d"
[[ "${TMP_WORKTREES_APPROVED:-0}" == "1" ]] || continue
```
`pressure_sweep.sh` (the only sweeper that runs `cleanup_tmp.sh --large` on a
pressure trigger) exports `LARGE_TMP_APPROVED=1` for its own invocation
(comment at `pressure_sweep.sh:15`, confirmed in source at the `tmp_step=(env
LARGE_TMP_APPROVED=1 ...)` line) but **never** sets `TMP_WORKTREES_APPROVED`.
The launchd plist's `EnvironmentVariables` block (`plutil -p
com.jleechanorg.disk-magician-pressure-sweep.plist`) sets only `HOME`. Result:
every `worktree_*`-prefixed dir under `/private/tmp` (and structurally,
anything matching the same pattern) is permanently skipped by the automated
path — confirmed in the log: `"Skipping temp worktree dir (requires
TMP_WORKTREES_APPROVED=1): /private/tmp/worktree_bugz"`.

### 3.3 24h mtime grace window means near-zero yield even when triggered correctly

`pressure_sweep.sh` DID fire correctly twice in the last few hours when free
space crossed its 40 GiB threshold:
```
[2026-07-22T16:10:19Z] pressure_sweep: step 1/2 cleanup_tmp.sh done — free after: 42 GB
[2026-07-22T18:10:20Z] pressure_sweep: free 30 GB < threshold 40 GB — sweep triggered (dry_run=false).
```
But the actual yield was negligible — `"Done. Dirs removed: 1  Files removed:
0  Total freed: 324 KB (~0 MB)"` — because the remaining non-protected,
non-worktree scratch dirs are shielded by a 24h "recently active" mtime
window (`LARGE_TMP_ACTIVE_HOURS` default 24, `cleanup_tmp.sh` log:
`"Skipping recently active dir (mtime within 24h): /private/tmp/wa-fix-c739i
(317772 KB)"`). Active AO missions touch their scratch dirs continuously
while running, so they never age out of this window before the mission ends
and gets cleaned up manually (or not).

### 3.4 The sweeper's own "safe" fallback adds its own footprint back to the same full volume

When `cleanup_tmp.sh --large` can't safely delete an oversized dir, it
archives it to `/private/tmp/_disk_magician_archive/<timestamp>/` instead of
deleting. That archive is itself **4.3 GiB today**, with 6+ new
timestamped subdirs created just in the last 12 hours
(`20260722T080156Z`...`20260722T120826Z`). Retention constants exist
(`LARGE_TMP_ARCHIVE_RETENTION_HOURS=24`, `LARGE_TMP_ARCHIVE_MAX_HOURS=168`,
seen in `cleanup_tmp.sh`) but nothing in `pressure_sweep.sh`'s 2-hour trigger
path calls a prune step for this archive directory — it only grows.

### 3.5 The one sweeper that names `worldarchitect.ai` directly runs once a day

`com.jleechan.cleanup-ao-tmp` (`~/Library/LaunchAgents/com.jleechan.cleanup-ao-tmp.plist`)
runs `cleanup-ao-tmp.sh` via `StartCalendarInterval { Hour: 4, Minute: 5 }` —
once daily. Its own log shows repeated `"Scanning
/private/tmp/worldarchitect.ai/ ... Done. Dirs removed: 0  Files removed: 0
Total freed: 0 KB"` — i.e. it also finds nothing to remove there, most likely
for the same active-mtime reason as §3.3, at 1/12th the frequency of the
2-hour pressure sweep.

### 3.6 Secondary: the 35-min snapshot sweeper loses visibility on the 5 biggest trees

`disk_snapshot.json.snapshot_metadata.measurement_path_max_seconds = 20`.
The 5 largest tracked paths (`projects`, `root_library`, `worktrees_dot`,
`tmp_private`, `library_containers`) now routinely exceed 20s to `du` under
disk pressure and get recorded as **literal `0`** rather than "stale/last
known good" — this is exactly `disk_snapshot.json.timeout_keys` in the latest
snapshot. Naive diffing against the prior snapshot then shows these trees
"shrinking to zero" (e.g. `projects: 114.8 → 0.0`) instead of the real +9-25
GiB growth, even though the topline `disk_used_gb` correctly climbed 780 →
854 GiB over the same 24h. This is why lane1 had to re-measure directly with
bounded `du -d1 -g` rather than trust the tracked-directory diff. Not a
deletion-prevention bug, but it hides exactly the trees that most need
attention from anyone watching the dashboard.

## 4. Prioritized SAFE-to-automate list

1. **HIGH** — Close the `TMP_WORKTREES_APPROVED` gap in the pressure-triggered
   path. `pressure_sweep.sh` already grants `LARGE_TMP_APPROVED=1`
   specifically for the pressure path with existing lsof-in-use safety
   checks in `cleanup_tmp.sh`; mirror that same pattern for
   `TMP_WORKTREES_APPROVED=1` (pressure-only, not the default daily/manual
   invocation) so `worktree_*` dirs under `/private/tmp` are eligible when
   free space is critically low. Unlocks a meaningful slice of the ~290
   scratch dirs.
2. **HIGH** — Add archive retention enforcement as an explicit step in
   `pressure_sweep.sh` (prune `/private/tmp/_disk_magician_archive/*`
   older than `LARGE_TMP_ARCHIVE_MAX_HOURS`) so the sweeper's own safety
   fallback stops growing unbounded on the same full volume it's relieving.
3. **MEDIUM** — Raise `cleanup-ao-tmp.sh` cadence from once-daily (04:05) to
   match or complement the 2h pressure-sweep cadence, since it's the only
   job that specifically targets `worldarchitect.ai`/`wa-missions` by name.
4. **MEDIUM (observability, not cleanup)** — On a per-path `du` timeout in
   the 35-min snapshot sweeper, retain the last successfully-measured value
   (flagged stale) instead of writing `0`, so `directories` diffs stay
   truthful for the 5 largest trees during exactly the periods they matter
   most (high disk pressure → slower `du` → more timeouts → less visibility).
5. **LOW / needs human judgment, not blanket-safe** — `~/projects/worldarchitect.ai`
   worktrees (~290 `wt-*`/`worktree_*` dirs, ~65 GiB) and `~/.worktrees`
   (26 GiB): candidates for a `git worktree list` + prune pass per repo for
   genuinely merged/abandoned branches. Not blanket-automatable — some are
   live in-progress work.
6. **LOW, outside disk_magician's charter** — `/Library/Developer/CoreSimulator`
   (31 GiB): `xcrun simctl delete unavailable` is Apple's own low-risk
   cleanup for orphaned simulator runtimes; worth a one-off manual run but
   not something this repo should own automating.

## 5. Explicitly not the culprit this cycle

- Colima primary diffdisk: confirmed small per mission brief; however the
  full `~/.colima/_lima` tree (VM disk backend, `_disks/` = 10 GiB) is
  larger than the diffdisk alone and contributed +7 GiB in the last 30h —
  worth noting for future triage so "diffdisk is small" isn't read as
  "colima isn't growing."
- APFS local snapshots: only 3 exist, all tiny OS-update prep snapshots: not
  a residual contributor.
