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

### 3.4 The sweeper's own "safe" fallback adds its own footprint back to the same full volume (correction below)

When `cleanup_tmp.sh --large` can't safely delete an oversized dir, it
archives it to `/private/tmp/_disk_magician_archive/<timestamp>/` instead of
deleting. That archive was **4.3 GiB** at scan time, with 6+ new
timestamped subdirs created just in the preceding 12 hours
(`20260722T080156Z`...`20260722T120826Z`).

**Correction (2026-07-22, follow-up pass):** `purge_aged_archives()`
(`cleanup_tmp.sh:292-343`) IS called unconditionally at the bottom of the
script (`cleanup_tmp.sh:579`, not gated behind `--large`), and does exactly
what the retention constants promise: `find "$ARCHIVE_ROOT" -mmin
+$((LARGE_TMP_ARCHIVE_RETENTION_HOURS*60))` soft-purges entries past 24h
(subject to active-marker/recent-activity/open-file guards, same as live
`/private/tmp` dirs), and unconditionally force-purges anything past the
168h `LARGE_TMP_ARCHIVE_MAX_HOURS` hard cap regardless of guards. All
observed archive entries were <5h old at scan time — well inside the
retention window — so the 4.3 GiB figure reflects normal steady-state
turnover, not an unbounded leak. Original claim ("nothing calls a prune
step") was wrong; retracted. Not a cleanup target — no action needed here.

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
2. ~~HIGH — Add archive retention enforcement...~~ **RETRACTED** — see §3.4
   correction: `purge_aged_archives()` already runs unconditionally on every
   `cleanup_tmp.sh` invocation and enforces the 24h/168h retention/hard-cap
   window. No action needed.
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

## Reclaimable residual (follow-up pass, 2026-07-22, still read-only)

Team-lead asked lane1 to attribute the safely-reclaimable slice of the
~545 GiB residual from §1 so lane2/lane3 can act. Result: **none of the
four requested candidate buckets are meaningful reclaim targets on this
machine right now** — each was checked directly and is either empty, small,
or not safely touchable by automation. The residual itself remains
predominantly the APFS-protected/purgeable pool described in §1 (`purgeable_kb:
0` in `frontier_last.json` — nothing is even sitting in the purgeable
category to reclaim via `tmutil` or Space Nudge). The real reclaimable
opportunity continues to be the worktree/scratch buckets already identified
in §2-§4 above (~134 GiB across `/private/tmp` protected roots + `~/.worktrees`
+ `~/projects/worldarchitect.ai` worktrees), not new residual.

| Bucket | GiB | Reclaim method | Safety note | Repo script covers it? |
|---|---:|---|---|---|
| `~/Library/Developer/Xcode/DerivedData` | 2.3 | `rm -rf` contents (Xcode regenerates on next build) | Safe, standard Xcode cache | No — not in this repo's scope |
| `/Library/Developer/CoreSimulator` | 31 (see breakdown) | `xcrun simctl delete unavailable` | **0 GiB actually reclaimable** — see below | No, and shouldn't be |
| `~/Library/Application Support/MobileSync/Backup` | 0 | N/A | Directory exists but is **empty** — no iOS device backups on this machine | N/A |
| `~/Library/Caches` (user, subdirs ≥2 GiB) | 6 total / 2 in `ms-playwright` | manual clear | Small; not a meaningful residual source | No |
| `~/Library/Containers` (user, subdirs ≥2 GiB) | 2 total, no single subdir ≥2 GiB | N/A | Below the requested threshold | No |
| `~/Library/Developer/Xcode/Archives`, `iOS DeviceSupport` | 0 | N/A | Neither directory exists on this machine | N/A |
| `/private/tmp/_disk_magician_archive` | 4.3 | already self-pruning | See §3.4 correction — retention/hard-cap already enforced by `cleanup_tmp.sh:579` | **Yes**, no fix needed |

### CoreSimulator detail (why 31 GiB ≠ 31 GiB reclaimable)

`/Library/Developer/CoreSimulator` (root-owned, `stat -f %Su` = `root`) breaks
down as: `Volumes/` 19 GiB, `Cryptex/` 9 GiB, `Caches/` 4 GiB, `Profiles/` +
`Images/` 2 GiB. `xcrun simctl list devices | grep -i unavailable` returned
**zero** unavailable devices, and `xcrun simctl runtime list` shows exactly
**one** installed runtime (iOS 18.6, 8.2 GiB disk image, status `Ready`) which
is the one actively backing the user's simulator devices
(`~/Library/Developer/CoreSimulator/Devices`, separately only 4 GiB, 10
devices, all pointing at the same runtime). `simctl delete unavailable`
would free **0 GiB** — there is nothing unavailable to delete. The
`Volumes`/`Cryptex` weight is the live, in-use runtime infrastructure itself;
deleting it means deleting the only installed iOS runtime and breaking
simulator functionality until Xcode re-downloads ~8+ GiB. This bucket is
**not a safe automation target** and is root-owned, outside this repo's
user-scope charter regardless.

### Other large tracked (not residual) libraries checked for completeness

While chasing the residual, also measured three big non-growing, already-tracked
libraries the earlier top-down pass hadn't called out by name: `~/Pictures/Photos
Library.photoslibrary` (14 GiB), `~/Library/Messages` (27 GiB, this is the
`library_messages` key from §1's tracked-bucket table, confirmed stable at
+0.018 GiB growth over 24h — not a grower), `~/Library/Mail` (5.7 GiB). These
are already inside the ~307 GiB "measured" total from §1, not part of the
545 GiB unattributed residual, and are personal-data libraries — not
candidates for automated cleanup regardless.

### Bottom line for lane2/lane3

The only genuine, immediately-actionable reclaim from this pass is
**DerivedData (2.3 GiB)** — small, and arguably not worth a dedicated
sweeper given the effort/reward ratio versus the ~134 GiB already sitting in
the worktree/scratch buckets from the main report. Recommend lane2/lane3
prioritize the §4 fixes (worktree-approval gap, worktree prune pass) over
chasing this residual further; the residual bucket itself does not currently
contain a hidden multi-GB "quick win."

## 5. Explicitly not the culprit this cycle

- Colima primary diffdisk: confirmed small per mission brief; however the
  full `~/.colima/_lima` tree (VM disk backend, `_disks/` = 10 GiB) is
  larger than the diffdisk alone and contributed +7 GiB in the last 30h —
  worth noting for future triage so "diffdisk is small" isn't read as
  "colima isn't growing."
- APFS local snapshots: only 3 exist, all tiny OS-update prep snapshots: not
  a residual contributor.
