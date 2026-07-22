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

## Anomaly observed mid-run (flagged separately to team-lead)

Free space fluctuated sharply during this run, independent of the
reclaim actions above: 12 GB (baseline) → 6 GB → **5 GB (low point)** → 7 GB
→ stabilized at 9-10 GB. `ps aux` during the dip showed no single runaway
writer; `du -sh ~/.colima/_lima` was flat at ~13G across the dip. Most
likely explanation is APFS purgeable-space/snapshot accounting noise
(consistent with local snapshots still present per the apfs-snapshots
dry-run above) rather than a genuine leak, but flagged to lane1-rootcause
for confirmation since it happened live during this session.

## Final (13:03 local)

```
$ df -g /System/Volumes/Data
Filesystem   1G-blocks Used Available Capacity
/dev/disk3s5       926  858         9    99%

$ diskutil info /System/Volumes/Data | grep -i free
   Container Free Space:      10.0 GB
```

## Summary

- Baseline: 12 GB free (df) / 13.2 GB (diskutil)
- Final: 9 GB free (df) / 10.0 GB (diskutil)
- Net change: **-3 GB** despite ~0.5 GB + ~18 MB reclaimed by lane2's
  actions — the mid-run anomaly (or concurrent activity from other
  swarm lanes / the live system) outpaced this lane's reclaim by a wide
  margin. Real, larger reclaim levers exist but are blocked on:
  (a) a human running the 2 sudo APFS snapshot deletions, and
  (b) an explicit go/no-go decision on the 2 approval-gated scripts
  above (~3.5 GB combined).
