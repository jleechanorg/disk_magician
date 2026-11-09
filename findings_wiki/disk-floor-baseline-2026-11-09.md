---
title: Historical disk baseline and ledger paths; October 20 is outside the November 9 14-day window
hostname: jeffreys-macbook-pro
date: 2026-11-09
status: active
paths:
  - ~/.disk_magician_backup/ledger/topdown-5g.json
  - ~/.disk_magician_backup/ledger/topdown-5g.partial.json
  - ~/.disk_magician_backup/ledger/topdown-5g.status.json
  - ~/.disk_magician_backup/snapshots/disk_snapshot.json
  - /var/db/disk-magician/frontier_last.json
  - ~/.disk_magician_state/frontier_last.json
  - /Volumes/diskm-scratch
  - ~/.worktrees
  - ~/.codex/sessions
  - ~/.claude/projects
safety_rule: none
---

## What

The last published complete ledger records **789.1 GiB used on October 20**. This is a historical
observation. On November 9, a 14-day window starts October 26, so that sample cannot establish the
14-day floor. The host's ledger history has no eligible capture in that window.

| quantity | value | source |
|---|---|---|
| Historical used space (`df`, filesystem aggregate) | **789.1 GiB used** | `~/.disk_magician_backup/ledger/topdown-5g.json` @ commit `b4ff54a0e5f213a81ded326eaf158883cf8f9ca5`, captured **2026-10-20T14:04:01Z**; `disk_used_kb=827387344` |
| 14-day ledger floor at 2026-11-09 | **Unavailable** | No eligible captures since October 26 |
| Gap to a 14-day floor | **Unavailable** | Requires an eligible floor and a current observation of the same filesystem |

The historical value is a filesystem aggregate, with no file-itemization threshold. It establishes
used space at that capture, not the age or reclaimability of any directory. Selecting the newest
commit does not select a minimum. A new observation below 789.1 GiB also does not prove the host is
below its rolling floor.

## Where the measurements live

These are the files to read. **Do not run a fresh whole-disk `du`** to answer "what is the floor";
read the ledger (repo `CLAUDE.md` mandates this and warns `du` stalls >60 s on this box).

```
~/.disk_magician_backup/ledger/topdown-5g.json          ← last published complete ledger
~/.disk_magician_backup/ledger/topdown-5g.md            ← human-readable render of the same
~/.disk_magician_backup/ledger/topdown-5g.partial.json  ← partial-scan observations
~/.disk_magician_backup/ledger/topdown-5g.status.json   ← current publication/coverage status
~/.disk_magician_backup/snapshots/disk_snapshot.json    ← live snapshot (needs coverage >= 70%)
/var/db/disk-magician/frontier_last.json                ← root-owned frontier scan
~/.disk_magician_state/frontier_last.json               ← user-owned frontier mirror
```

Retrieve the historical sample with:

```bash
# Recent publication history; newest does not mean lowest.
git -C ~/.disk_magician_backup log --oneline -3 -- ledger/topdown-5g.json
git -C ~/.disk_magician_backup show b4ff54a0e5f213a81ded326eaf158883cf8f9ca5:ledger/topdown-5g.json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["captured_at"], d["disk_used_kb"], round(d["disk_used_kb"]/1048576, 1), d["mode"])'
```

The sample prints `2026-10-20T14:04:01Z 827387344 789.1 complete`. For a rolling comparison:

```bash
diskm history diff --days 14
```

On the reviewed host this reports `no valid ledger snapshots in the last 14 days`. Use the fallback
below. Also check the command's selected reference: when the selected floor is HEAD, the current
implementation substitutes `HEAD~1` to show movement (`scripts/history_diff.py`, `main`). That
comparison must not be reported as the window minimum without checking the capture selection.

**Coverage gate (hard):** never treat `snapshots/disk_snapshot.json`'s `disk_used_gb` as a floor when
`snapshot_coverage_pct` < 70 %. A low-coverage minimum is bogus.

## Historical ledger observations

These October captures all precede the 14-day window ending November 9:

| date | used GiB | commit |
|---|---|---|
| 2026-10-20 | **789.1** | `b4ff54a0` |
| 2026-10-19 | 830.6 | `83c31699` |
| 2026-10-18 | 867.7 | `9ef7ac82` |
| 2026-10-17 | 836.2 | `480db551` |
| 2026-10-15 | 861.2 | `e1fd0a56` |
| 2026-10-14 | 780.9 | `e7bd2559` |

October 14's 780.9 GiB is lower than October 20's value. Both are already outside the window;
neither establishes a November 9 14-day floor.

## Cleanup safety

`~/.codex/sessions*` and `~/.claude/projects` are on the repository's hard never-delete list.
They are protected regardless of age. This finding grants no cleanup exception. Use the canonical
`diskm` cleaners and their live safety checks for eligible data; preserve their recency and lease
gates. A directory total cannot prove that its contents are stale or reclaimable. Itemize files and
child directories to the repository's 100 MiB stop threshold before making those claims.

## Why this finding exists

The last complete ledger capture was over 19 days old on November 9. The status envelope describes
the newer partial scan: the inspected `topdown-5g.status.json` records `captured_at=2026-11-08T23:43:48Z`,
`reason=coverage_incomplete`, and `age_hours=9.222`. Its age is separate from the complete ledger's age.
Read both capture timestamps before using history.

### Partial frontier coverage and Full Disk Access

The partial scan captured **2026-11-08T23:43:48Z**, inspected November 9, reports:

```
fda_preflight_status: partial
fda_user_preflight_status: granted
fda_hint: grant_full_disk_access_to_the_snapshot_frontier_executable
measured_top_level_roots: 0 / 20
unfinished_top_level_roots: 18
frontier_unfinished entries: 195,031
```

Zero of twenty top-level roots completed measurement. The executable's Full Disk Access preflight
needs investigation even though the user preflight is granted. Those fields establish incomplete
coverage; they do not establish that permission was revoked or that no child paths were enumerated.

The earlier attribution to missing `EDEADLK`/`SF_DATALESS` handling requires an error receipt linked
to the failed scan. Absence of a handler alone does not prove the cause. Restore and verify complete
coverage before publishing a new complete ledger; retain partial observations separately.

### Freshness reporting is misleading

On November 9, `diskm ledger-freshness` returned **`OK`** for partial freshness while also reporting
a stale complete publication. Selected fields from that receipt:

```
OK  published_age_hours=475  status=partial  partial_age_hours=9
label=PARTIAL  canonical_publication=stale
scan_measured_roots=0  scan_reachable_roots=20
```

The leading token alone cannot establish a fresh complete ledger. Inspect `canonical_publication`
and both root-count fields; the fleet and disk-alert callers already check the stale-publication
field. A partial-freshness result does not make incomplete observations eligible for floor math.

## How to apply

1. Follow the repository's fleet check and existing reclaim-ledger sequence before a live disk
   investigation. Compute the requested 7-day and 30-day minima from eligible captures; report each
   capture window, coverage, typical daily minimum, and current-minus-floor for the same filesystem.
2. If the complete ledger is older than 48 hours, state the gap. If no eligible ledger exists,
   fall back to daily minima of `host_disk.used_kb` in
   `~/.disk_magician_state/disk_observer.jsonl{,.1,.2}`. State the earliest available date and the
   median daily minimum alongside the minimum; report missing observations explicitly. Use committed
   `snapshots/disk_snapshot.json` captures with coverage at least 70% for bucket comparisons. Never
   manufacture a bucket delta from stale or partial measurements.
3. On macOS, verify that Scratch and Data share an APFS container before attributing changes in
   available space. On Linux, deleting inside a loop image can leave allocated host blocks until
   discard/trim. `diskm volume trim-auto scratch --clean` supports native Scratch with a pinned local
   admin image and rootful Docker transport; its helper uses container root and `CAP_SYS_ADMIN`.
   It skips non-native Scratch and image gaps below 4 GiB. Read the trim receipt and measure host
   free space before claiming reclamation.
