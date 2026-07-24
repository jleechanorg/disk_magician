# Disk reclaim log — 2026-07-22 (lane2-reclaim, disk-cleanup-automation-20260722)

Mission bead: jleechan-4dtg. Swarm mission STATE:
`/tmp/disk_magician/sidekick/disk-cleanup-automation/STATE.md`.

## Baseline (12:44 local)

```
$ df -g /System/Volumes/Data
Filesystem   1G-blocks Used Available Capacity
/dev/disk3s5       926  857        12    99%

$ diskutil info /System/Volumes/Data | grep -i free
   Container Free Space:      13.2 GB
```

## Per-script dry-run vs actual

All deletions executed ONLY via this repo's own scripts, with their
documented flags. No hand-`rm` used anywhere in this run.

| Script | Dry-run finding | Action taken | Result |
|---|---|---|---|
| `scripts/cleanup_tmp.sh` (default dry-run) | 0 dirs / 0 files reclaimable | not re-run with `--clean` (nothing to gain; this is the one `pressure_sweep.sh` already runs unattended when free < 40G) | 0 freed |
| `scripts/cleanup_colima.sh` (default dry-run → `--clean`) | docker system df: Images 7.9-10.3GB "reclaimable" but 100% active (in use by running containers, not actually prunable) | ran `--clean`: builder/image/system prune all reclaimed 0B (images in active use); `colima ssh -- sudo fstrim -av` trimmed 367 MiB + 91 MiB + 87 MiB from the VM sparse disk | ~0.5 GB freed (fstrim only; prune was a no-op because the 2 images are actively referenced) |
| `scripts/symlink-shared-gemini.sh` (default dry-run → `--clean`) | 1078 per-session `.gemini` dirs replaceable with symlinks to canonical `~/.gemini`, 41 already symlinked | ran `--clean`: replaced all 1078 | ~0 MB freed today (each per-session `.gemini` copy was already near-empty/small) — real value is preventing future regrowth as new AO sessions spawn |
| `scripts/symlink-shared-playwright-cache.sh` (default dry-run) | **BUG FOUND**: dry-run targeted paths already ending in `.bak.<timestamp>` (e.g. `.../ms-playwright-go/1.57.0.bak.20260719-041505`) as if they were the live `$CANONICAL_VERSION` cache dir — looks like `CANONICAL_VERSION`/`ensure_canonical_cache()` is resolving to an already-backed-up dir name instead of the real live version. Running `--clean` on this would have renamed backup-of-backup dirs, not reclaimed real space. | **STOPPED — did not run `--clean`.** Flagging for lane1-rootcause / lane3-automation to fix the canonical-version resolution bug before this script is safe to run unattended. | 0 freed, bug flagged |
| `scripts/dedup_hermes_prompts.sh` (default dry-run → `--apply`) | 268 sessions >30d old with `system_prompt` set, ~17.9 MB reclaimable + VACUUM | ran `--apply` (first invocation ran in background and completed silently — output file was empty but a second confirmation run showed 0 sessions remaining, proving the first run had already NULLed them) | ~17.9 MB (system_prompt payload) reclaimed; state.db size unchanged in `ls -la` because SQLite doesn't shrink the file without a full VACUUM (see next row) |
| `scripts/vacuum_hermes_state.sh` (default dry-run → `--apply`) | would VACUUM 5644.6 MB state.db | ran `--apply` 4× (1 + 3 retries) — every attempt hit `Error: stepping, database is locked (5)` because the live Hermes daemon holds the db open with active writers | **Blocked — could not run.** Deferred to the scheduled Sunday 04:30 launchd window (`com.disk-magician.hermes-vacuum`) when daemon write contention is lower. Not a bug; matches the script's own documented behavior. |
| `scripts/cleanup_downloads_evidence.sh` (default dry-run → `--clean`) | 0 spools past the 72h retention window (2 kept as newest, 9 within retention) | ran `--clean` | 0 freed (nothing eligible yet — retention window is working as designed) |
| `scripts/cleanup_apfs_snapshots.sh` (default dry-run → `--clean`) | 2 snapshots queued for deletion: the `LIMITS_CONTAINER_SHRINK` anchor snapshot (39h old, pins the APFS container's minimum size — the regrowth-prevention README's "A1" failure mode) + a 39h-old `MSUPrepareUpdate` snapshot | **Attempted `--clean` — failed.** `diskutil apfs deleteSnapshot` returned an elevated-privilege error for both UUIDs. This is a documented, known limitation (see comment block in `launchd/com.disk-magician.apfs-snapshots.plist`): macOS 15.5 does not let a user-mode LaunchAgent delete `com.apple.os.update-*` snapshots without sudo, and no sudoers wiring exists for this. **The unattended launchd job has the exact same limitation** — it is not something lane2 broke. | 0 freed; **STOP item requiring a human to run manually with sudo** (see below) |
| `scripts/cleanup_worktree_venvs.sh` (default dry-run) | 15 venv dirs inspected, 0 old enough to strip (12 too young <14d, 3 not-worktree) | not run with `--clean` (would be a no-op; skipped touching `WORKTREE_APPROVED=1` for zero benefit) | 0 freed (nothing eligible) |
| `scripts/cleanup_llm_inspector.sh` (default dry-run) | 0 KB reclaimable, log rotation not yet needed | not run further | 0 freed |
| `scripts/cleanup_supervisor_logs.sh` (default dry-run) | 0 files reclaimable | not run further | 0 freed |
| `scripts/cleanup_code_sign_clones.sh` (default dry-run) | only 2 active app clones present (Aside, Chrome), 0 stale | not run further | 0 freed |

## STOP items — not executed, need explicit decision

1. **APFS snapshot deletion needs manual sudo.** Run interactively:
   ```
   sudo diskutil apfs deleteSnapshot disk3s1 -uuid 496C4D0C-6C17-48C9-836D-D8E391B74146   # LIMITS_CONTAINER_SHRINK anchor
   sudo diskutil apfs deleteSnapshot disk3s1 -uuid 37B9F447-36FE-4F98-97CF-069A42265683   # MSUPrepareUpdate, 39h old
   ```
   The first one is the higher-value target — it's the anchor pinning the
   container's minimum size per the regrowth-prevention README.

2. **`symlink-shared-playwright-cache.sh` canonical-version bug** — do not
   run `--clean` until fixed. Handed to lane1-rootcause/lane3-automation.

3. **Not executed (out of team-lead's named safe list, gated behind extra
   approval env vars in `disk_audit.sh`, so left for an explicit decision
   rather than self-approved):**
   - `scripts/cleanup_sessions.sh --clean` (gated `SESSIONS_APPROVED=1`) —
     dry-run shows **~2.2 GB reclaimable**: 1197 `~/.hermes/sessions/*.jsonl`
     files >30d old (~0.15 GB) + other stale `~/.ao-sessions/` and
     `~/.hermes/cron/output/` entries, 2091 entries total. Largest single
     lever left on the table.
   - `scripts/cleanup_agent_artifacts.sh --clean` (gated
     `AGENT_ARTIFACTS_APPROVED=1`) — dry-run shows **~1.26 GB reclaimable**:
     `~/Library/Caches/ms-playwright` (1.0G), `~/Library/Caches/pip` (197M),
     `~/.cursor/chats` (5.2M), `~/.claude/debug` (64K).

## Incident — dedup_hermes_prompts.sh backup spiked usage +5.5 GB, nearly wedged the disk

**Root cause, corrected from the initial "APFS purgeable noise" guess below,
per team-lead's diagnosis + this lane's own file evidence:**

`scripts/dedup_hermes_prompts.sh --apply` (run in this session at 12:53 to
NULL 268 stale `system_prompt` values) has a **mandatory pre-flight backup**
step (`scripts/dedup_hermes_prompts.sh:113-140`): before mutating, it `cp`'s
the entire live db to `~/.hermes/state.db.dedup-backup-<timestamp>` and
verifies the copy, gating on 2x db size free space to even attempt it. This
is by design (a safety net for an irreversible NULL+VACUUM) but the script
**never deletes the backup afterward** — there is no retention/cleanup
mechanism or `--delete-backups` flag for these files, unlike the analogous
`.bak.<timestamp>` handling in `symlink-shared-gemini.sh` /
`symlink-shared-playwright-cache.sh`.

Evidence: `ls -la ~/.hermes/state.db.dedup-backup-*` shows two such files
sitting on disk right now — `state.db.dedup-backup-20260720-210228`
(7258.3 MB, from an earlier run 2 days ago) and
`state.db.dedup-backup-20260722-125309` (5644.6 MB, created 12:53:09 by
this session's `--apply` run) — **12.9 GB combined dead weight**, neither
reclaimed by the `wal_checkpoint(TRUNCATE)` team-lead ran (that reclaimed
the separate `state.db-wal` file, not these `cp`-made full backups).

Note for the record: `scripts/vacuum_hermes_state.sh --apply`, which I also
ran (1 + 3 retries) during this session, **never succeeded** — every
invocation returned `Error: stepping, database is locked (5)` immediately
(the live Hermes daemon holds writers). So the actual WAL/space spike was
caused by `dedup_hermes_prompts.sh --apply`'s own internal VACUUM step
(documented in its own dry-run message: "would NULL system_prompt on 268
sessions and VACUUM"), not by `vacuum_hermes_state.sh`. Both scripts VACUUM
the same db and both are unsafe at low free space — team-lead's directive
to not re-run either one stands regardless of which one fired first.

**Not yet reclaimed — STOP item, no existing script deletes these:**
the two `~/.hermes/state.db.dedup-backup-*` files (12.9 GB). This is the
single largest lever found in this entire session, larger than every other
item combined. Not hand-`rm`'d per policy (no existing repo script covers
`.dedup-backup-*` cleanup) — flagging for team-lead decision: either a
manual `rm` of the two named files (both post-date successful, verified
mutations — the 07-20 one is 2 runs stale, the 07-22 one is from this
session's already-completed run) or a new retention step added to
`dedup_hermes_prompts.sh` (e.g. delete backups older than N days, mirroring
`symlink-shared-*`'s `--delete-backups` pattern) — handed to
lane3-automation.

**hermes-vacuum marked NOT-safe-at-low-free-space**, per team-lead
directive: do not re-run `vacuum_hermes_state.sh --apply` (needs ~2x db
size headroom to VACUUM safely) below ~15 GB free. Same caution now applies
to `dedup_hermes_prompts.sh --apply` for the same reason (its own gate
requires 2x db size free, but that gate checks space at the START, not
whether the WAL growth during VACUUM will itself consume the remaining
margin).

## Second anomaly — Colima `_lima` regrowth confirmed live, +5.1 GB in <4 min

While re-checking scripts after the incident above, free space swung again
independent of any lane2 action: 18 GB (post-team-lead-fix) → 10.5 GB in
the few minutes it took to run three more dry-run/no-op scripts. Checked
`du -sh ~/.colima/_lima` before/after: **12.9 GB (13:00:55) → 18 GB
(13:04:06+), +5.1 GB in under 4 minutes**, while lane2 ran nothing but
read-only dry-runs. This supersedes the initial "APFS purgeable noise"
theory below — the Colima sparse-disk regrowth mechanism (documented in
memory `project_2026-07-17_colima_regrowth_shlock_bug_and_dk2d_retention`)
is confirmed actively firing live during this session, most likely CI-runner
container churn. Handed to lane1-rootcause; `cleanup_colima.sh` prune found
0 reclaimable both times it ran here (the 2 images are 100% actively
referenced, not prunable garbage) so the existing sweeper cannot address
this — it needs a different mechanism (fstrim only recovers what's already
freed inside the VM, not active container growth).

### Original (superseded) anomaly note

Free space fluctuated sharply earlier in this run: 12 GB (baseline) → 6 GB
→ 5 GB (low point) → 7 GB → stabilized at 9-10 GB. At the time, `du -sh
~/.colima/_lima` read flat at ~13G across that dip, so this was attributed
to APFS purgeable-space/snapshot accounting noise. The dedup-backup finding
above is the confirmed root cause of that specific dip; the Colima regrowth
above is a second, independently confirmed mechanism seen later in the same
session.

## Final (13:04 local, after the incident + Colima regrowth)

```
$ df -g /System/Volumes/Data
Filesystem   1G-blocks Used Available Capacity
/dev/disk3s5       926  859         9    99%

$ diskutil info /System/Volumes/Data | grep -i free
   Container Free Space:      10.5 GB
```

## Summary

- Baseline: 12 GB free (df) / 13.2 GB (diskutil) at 12:44
- Mid-run low point: 5 GB free (13:00-ish), caused by
  `dedup_hermes_prompts.sh --apply`'s pre-flight full-db backup + internal
  VACUUM (see Incident above), not by `vacuum_hermes_state.sh` (which never
  succeeded — locked every attempt)
- Team-lead intervention: `PRAGMA wal_checkpoint(TRUNCATE)` on
  `~/.hermes/state.db` → free rose to 18 GB
- Final at end of this lane's work: 9 GB free (df) / 10.5 GB (diskutil) at
  13:04, driven back down by the independently-confirmed Colima `_lima`
  regrowth (+5.1 GB in <4 min, see above) — not by any lane2 action
- Net lane2 reclaim (script actions only, excluding the two anomalies):
  ~0.5 GB (colima fstrim) + ~17.9 MB (hermes prompt dedup) = **~0.52 GB**
- Uncollected levers identified, largest first:
  1. `~/.hermes/state.db.dedup-backup-*` — **12.9 GB**, STOP item, no
     covering script, needs a decision (see Incident above)
  2. 2 APFS snapshots incl. the `LIMITS_CONTAINER_SHRINK` anchor — size
     TBD but likely large (container min-size pin), blocked on sudo
  3. `cleanup_sessions.sh --clean` (gated `SESSIONS_APPROVED=1`) — ~2.2 GB
  4. `cleanup_agent_artifacts.sh --clean` (gated
     `AGENT_ARTIFACTS_APPROVED=1`) — ~1.26 GB
  5. Colima regrowth — ongoing, needs a different mechanism than
     `cleanup_colima.sh`'s prune (0 GB reclaimable there both runs)
