---
title: `_disk_magician_archive` is a same-volume reservoir — bound it by size, not just age
hostname: jeffreys-macbook-pro.local
date: 2026-10-16
status: mitigated
paths:
  - /private/tmp/_disk_magician_archive
safety_rule: none (retention reservoir; bounded, not never-delete)
---

## What

`cleanup_tmp.sh --large` does NOT `rm -rf` large `/private/tmp` candidates
outright — it **moves** them into
`/private/tmp/_disk_magician_archive/<ts>/` so a later pass can purge them
after a recovery window. Because the archive lives on the **same APFS volume**
as `/private/tmp`, that `mv` is a near-zero-cost rename and frees **no space**
until the retention purge actually runs.

The archive only purged entries once they were older than
`large_tmp_archive_retention_hours` (default 24h). While the inflow of
newly-archived directories outpaces the >24h purge, the archive **only grows**
and the sweep's headline "freed" number (from `du` of the moved dir) is real
per-directory but yields **zero acute free-space relief** at the volume level.

## Evidence (2026-10-16)

- Archive grew **20.3 → 23.4 GiB** in a single session while `cleanup_tmp
  --large` reported freeing 2.2 GiB (all of it a same-volume move).
- In the same session the archive only shrank **30G → 10G** when an aged
  (>24h) purge finally ran.
- Kept-candidate classes that can sit for the full recovery window: unpushed
  commits, no recorded baseline, uncommitted changes, secret-like files,
  check-failed, archive identity mismatch.

## Why it matters

A same-volume archive turns "cleanup" into "accounting": the disk can stay at
99% while the tool reports gigabytes freed. Without a size bound the reservoir
is only bounded by the 168h hard cap (`large_tmp_archive_max_hours`), so a
burst of large archives can hold tens of GiB for up to a week.

## Guards / governance

1. **Age purge** (pre-existing): entries older than
   `large_tmp_archive_retention_hours` (24h) are purged when inactive;
   entries older than `large_tmp_archive_max_hours` (168h) are purged
   unconditionally (activity guards bypassed).
2. **Size cap** (this fix, bead `disk_magician-archive-same-volume-regrowth-03bn`):
   `large_tmp_archive_max_mb` (default 20480 = 20 GiB). Once the archive
   exceeds the cap, the oldest-mtime entries are evicted (`rm -rf`, activity
   guards bypassed — same documented policy as the hours hard cap) until the
   archive is back under the cap. Enforced by `enforce_archive_size_cap()`,
   called from `purge_aged_archives()` so every cleanup pass (large or not)
   re-bounds it.
3. **Regression test:** `tests/test_cleanup_tmp_archive_purge.sh` Test 6 —
   under a raised age cap, an over-size archive still evicts its oldest entry
   and keeps the newer one.

## History

- 2026-10-16 — size cap added after a session where the archive grew while the
  sweep reported frees; see bead `disk_magician-archive-same-volume-regrowth-03bn`.
