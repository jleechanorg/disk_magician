# 296 GiB residual — UPDATE 1 (2026-07-30 23:35)

`/research` original subagent landed with substantial live-measurement
findings that **invert part of the three-lane synthesis** above. Canonical
summary:

## What changes

| Topic | Three-lane verdict | `/research` re-verdict | Reason |
|---|---|---|---|
| Frontier scanner cause | unknown / mitigated by FDA grant | **EINTR retry bug in the scanner, not TCC** | Live `os.listdir(Mail)` returns `errno=4 (EINTR)`, NOT EACCES; frontier's `limits.permission_denied_or_tcc: []`. 430 of the 627 unfinished paths are EINTR. |
| MobileSync / Photos library measurement unlock | FDA grant → measurement | FDA grant gives **no** incremental unlock for these; scanner must retry EINTR | TCC only blocks app-level XPC (Mail.app, etc.), not shell-side `os.listdir`. |
| APFS container residual | hidden floor + snapshots | **Container reconciles within 4.4 GiB** of df Used when volumes are summed correctly (System 18.4 + Preboot 15.2 + Recovery 2.4 + Data 891.0 + VM 25.8 = 952.8 GiB vs container in-use 949.2) — no hidden floor | The 3 OS-update snapshots are on `disk3s1` (System, sealed), not `disk3s5` (Data); they don't add to Data volume accounting. |
| Snapshot deletion lever | explore in Recovery Mode | **Don't bother**. Snaps are on System, contribution <1 GiB | Verified live; nothing to reclaim from snapshots here. |
| Permanent floor | unknown | **Documented permanent floor on this Mac ≈ 27.6–47.6 GiB**, with **+18.4 GiB temporary** during the in-flight MSUPrepareUpdate (resolves on Restart or auto-rollback) | SSV 18.4 + Preboot 15.2 + Recovery 2.4 + APFS metadata 10–30 GiB. |

## Operational unlock (single most actionable)

**Fix the EINTR retry in `disk_frontier_scan` — does NOT need FDA.**

Expected residual drop after the fix: **30–60 GiB** (the 430 unfinished paths
that touch Mail/Messages/MobileSync/Backup/Music/Pictures/Desktop at typical
per-user sizes). Residual will likely drop from 284.5 GiB to ~225 GiB on
the first re-scan after the fix lands.

**FDA grant is still useful**, but for *different* measurements than
previously thought: Mail Index access, Messages `chat.db`, Safari history,
Time Machine toggles — none of which are in the EINTR-pending frontier set.

## Commands to execute now (read-only — measure, don't fix)

```bash
# 1. Confirm EINTR, not TCC (3 lines):
python3 -c "
import os, errno
for p in ['~/Library/Mail','~/Library/Messages','~/Library/Application Support/MobileSync/Backup']:
    try: os.listdir(os.path.expanduser(p))
    except OSError as e: print(p, 'errno=', e.errno, errno.errorcode.get(e.errno,'?'))
"

# 2. Run an EINTR-retried scan over the 430 paths the frontier gave up on:
python3 -c "
import json, os, errno, time
with open('$HOME/.disk_magician_state/frontier_last.json') as f:
    d = json.load(f)
targets = [u['path'] for u in d['frontier_unfinished']
           if u.get('reason')=='inventory_interrupted_system_call']
print(f'{len(targets)} EINTR paths')
total = 0
for p in targets:
    for _ in range(5):
        try:
            for r,_,fs in os.walk(p):
                for f in fs: total += os.lstat(os.path.join(r,f)).st_size
            break
        except OSError as e:
            if e.errno == errno.EINTR: time.sleep(0.5); continue
            print(p, e); break
print(f'EINTR-path total (apparent): {total/1024**3:.2f} GiB')
"

# 3. APFS volume arithmetic (verifies the 4.4 GiB reconciliation):
diskutil apfs list -plist /System/Volumes/Data | grep -E 'container_capacity_kb|container_free_kb'
diskutil info /System/Volumes/Data | awk '/Container Free/ {print}'
df -k /System/Volumes/Data | tail -1
```

## Action beading

Open a new bead: `disk_magician-XXX` (next P2 after 5yh/rvf/w7m/etc.) for
"frontier scanner EINTR retry fix" — cite this Markdown + the original
research_residual_296gib synthesis. Accept criteria: inventory
unfinished paths drop by ≥70% on next snapshot run; residual_kb in ledger
drops by ≥30 GiB.

## Files

- Original (3-lane): `roadmap/research-residual-296gib-20260730.md` — KEEP, retrofit a "superseded by update-1" banner pointing here.
- This update: `roadmap/research-residual-296gib-20260730-update1.md`
- Original /research output: `/tmp/research_residual_296.md`
