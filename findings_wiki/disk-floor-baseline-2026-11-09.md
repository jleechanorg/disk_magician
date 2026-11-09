---
title: Disk-space floor is 789.1 GiB (2026-10-20 ledger); record it here so it is not re-derived
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

The 14-day rolling **floor** for this host, and the exact files that hold it. Written down so a
future session can recall the baseline in one read instead of re-deriving it — this session burned
hours re-measuring because the floor was not recorded anywhere findable.

| quantity | value | source |
|---|---|---|
| **Floor (lowest `df used` in the window)** | **789.1 GiB used** | `~/.disk_magician_backup/ledger/topdown-5g.json` @ commit `b4ff54a0`, captured **2026-10-20T14:04:01Z** |
| Used at 2026-11-09 | **710.6 GiB** | live `df -m /System/Volumes/Data` |
| **Gap to floor** | **−78.5 GiB (below floor)** | derived |
| Free at 2026-11-09 (post-reclaim) | **122.9 GiB (85%)** | live `df` |

## Where the floor lives — the authoritative paths

These are the files to read. **Do not run a fresh whole-disk `du`** to answer "what is the floor";
read the ledger (repo `CLAUDE.md` mandates this and warns `du` stalls >60 s on this box).

```
~/.disk_magician_backup/ledger/topdown-5g.json          ← THE floor ledger (authoritative)
~/.disk_magician_backup/ledger/topdown-5g.md            ← human-readable render of the same
~/.disk_magician_backup/ledger/topdown-5g.partial.json  ← partial-scan ledger (coverage-gated)
~/.disk_magician_backup/ledger/topdown-5g.status.json   ← status/coverage envelope + age_hours
~/.disk_magician_backup/snapshots/disk_snapshot.json    ← live snapshot (needs coverage >= 70%)
/var/db/disk-magician/frontier_last.json                ← root-owned frontier scan (30 MB)
~/.disk_magician_state/frontier_last.json               ← user-owned frontier mirror
```

Retrieve the floor and any historical floor with:

```bash
# newest floor commit + its value
git -C ~/.disk_magician_backup log --oneline -3 -- ledger/topdown-5g.json
git -C ~/.disk_magician_backup show -s --format=%ci <sha>
python3 -c "import json,subprocess;d=json.loads(subprocess.run(['git','-C','$HOME/.disk_magician_backup','show','<sha>:ledger/topdown-5g.json'],capture_output=True,text=True).stdout);print(round(d['disk_used_kb']/1048576,1))"

# or, one command:
diskm history diff --days 14
```

**Coverage gate (hard):** never treat `snapshots/disk_snapshot.json`'s `disk_used_gb` as a floor when
`snapshot_coverage_pct` < 70 %. A low-coverage minimum is bogus.

## The measured floor curve at 2026-11-09

Recent ledger commits, used-GiB, for the 14-day window:

| date | used GiB | commit |
|---|---|---|
| 2026-10-20 | **789.1** ← floor | `b4ff54a0` |
| 2026-10-19 | 830.6 | `83c31699` |
| 2026-10-18 | 867.7 | `9ef7ac82` |
| 2026-10-17 | 836.2 | `480db551` |
| 2026-10-15 | 861.2 | `e1fd0a56` |
| 2026-10-14 | 780.9 | `e7bd2559` |

Note 2026-10-14 (780.9) is *lower* than 10-20 but falls outside the 14-day window as of 2026-11-09;
recompute the window rather than reusing 789.1 blindly once 10-20 ages out.

## The reclaimable buckets, with paths

Per this repo's "per-file, never per-directory aggregate" rule (100 MiB stop floor), the buckets that
were actually reclaimed 2026-11-08/09:

| bucket | path | GiB before | notes |
|---|---|---|---|
| Scratch top-level | `/Volumes/diskm-scratch/<name>` | 102.4 used | shared APFS container `disk3` with `Data` — freeing here raises `Data` free immediately on macOS |
| Worktrees | `~/.worktrees/<repo>/<name>` | 121–160 | floor is env-var driven, 3-day hard minimum |
| Codex sessions | `~/.codex/sessions` | 53.3 | never-delete list; >14 d was 6.6 GiB |
| Claude projects | `~/.claude/projects` | 22.1 | never-delete list; >14 d was 9.5 GiB |
| Codex archive | `~/.codex/sessions_archive` | 10.6 | never-delete list |
| Simulators | `~/Library/Developer/CoreSimulator/Devices` | 66 → 4.6 | erase shutdown devices only; keep booted |
| Caches | `~/Library/Caches` | 17.1 | canonical sweeper frees ~0; live app cache |
| Linux scratch image | `~/.local/share/disk-magician/volumes/scratch.ext4` | 176 → 104 | **loop-mounted ext4**: freeing inside returns NOTHING to the host until FITRIM |

## Result achieved 2026-11-09

| host | before | after |
|---|---|---|
| Mac `Data` free | 12.8 GiB (99%) | **122.9 GiB (85%)** |
| Mac scratch free | 2.1 GiB (99%) | 107 GiB (29%) |
| Linux `/` free | 9.1 GiB (95%) | 67.8 GiB (92%) |

Methods: manual 6 h-floor sweep of scratch (1,139 dirs / 62.1 GiB, 0 failures), 26 shutdown simulators
deleted, >14 d session pruning (16.1 GiB Mac + 17.9 GiB Linux), and rootless FITRIM on Linux via
`diskm volume trim-auto scratch --clean` (25.6 GB, no sudo).

## Why this finding exists

The floor **was not discoverable** in one place. The ledger was 19 days stale
(`topdown-5g.status.json` → `reason=coverage_incomplete`, `age_hours=339`) and the frontier scan was
`mode=partial`, so the authoritative number had to be reconstructed from git history. This doc records
both the number and the retrieval commands so the next session starts from 789.1 GiB rather than from a
fresh `du` sweep that stalls.

### Why the frontier scan is partial — two different causes, in order

**Current cause (2026-11-09 evening): Full Disk Access was revoked.**

```
fda_preflight_status: partial          ← was "granted" earlier the same day
fda_hint: grant_full_disk_access_to_the_snapshot_frontier_executable
measured_top_level_roots: 0 / 20
unfinished_top_level_roots: 18
frontier_unfinished entries: 195,031
```

Zero of twenty roots measured. `partial` here does **not** mean "nearly complete with a tail of gaps" —
it means *nothing was enumerated*. Without TCC Full Disk Access the scanner cannot read the system
paths, so every root lands in `unfinished`. This is a GUI action (System Settings → Privacy & Security
→ Full Disk Access) with no CLI grant path; `install-root-frontier-runner.sh` also needs `sudo`.

**Earlier cause (superseded): missing errno handling.** `disk_frontier_scan.py` had no
`EDEADLK`/`SF_DATALESS` handling for iCloud placeholder files. That was a real defect and blocked
completion on its own, but **fixing it will not help while FDA is revoked** — a scanner that cannot read
the disk cannot enumerate it regardless of errno handling. Fix FDA first, then re-check whether the
errno path still blocks.

### Freshness reporting is misleading

`diskm ledger-freshness` returns **`OK`** while the same output line carries
`published_age_hours=474` and `canonical_publication=stale`, because it accepts a fresh *partial* as
sufficient:

```
OK  published_age_hours=474  status=partial  partial_age_hours=9  \
    label=PARTIAL  canonical_publication=stale  scan_measured_roots=0/20
```

A freshness check that reports OK against a 19.8-day-old published ledger will keep hiding this. Treat
`canonical_publication=stale` and `scan_measured_roots=0/*` as failures regardless of the leading token.

## How to apply

1. **Before any disk proposal**, read the floor from `ledger/topdown-5g.json` and state the gap.
   Do not propose cleanup without the gap.
2. **If the ledger is older than 48 h**, say so and use `diskm history diff --days N`; do not invent
   bucket deltas from a stale HEAD.
3. **On macOS**, prefer reclaiming inside `/Volumes/diskm-scratch` — it is the same APFS container as
   `Data`, so freed blocks help the main volume with no trim step.
4. **On Linux**, deleting inside Scratch returns nothing until FITRIM; use the rootless
   `diskm volume trim-auto scratch --clean`, never `sudo fstrim` by hand.
