# Lane 5/6: mechanisms that write AI-conversation cloud backups (2026-10-03)

Read-only forensics. Evidence: launchd plists (`plutil -p`), `~/Library/Logs/user-scope-backup.launchd.log`, `~/Library/Logs/home-backup.latest.report.txt`, script reads, `rclone about dropbox:`.

## Bottom line

One job is the writer for nearly everything: `org.jleechan.user-scope-backup` runs `~/projects/user_scope/scripts/backup-home.sh` every 7200s (PID 75032 running at audit time; last exit 256). It has three legs per run:

| Leg | Source -> destination | Mechanism | Status |
|---|---|---|---|
| git | selected configs -> `~/projects/user_scope/backup/jeffreys-macbook-pro/` -> GitHub `jleechanorg/user_scope` | rsync + commit + push | Local copy is fine. Push fails: local is ahead 3, behind 58, so every non-fast-forward push is rejected. About 8 FAILED runs a day since ~09-10. |
| dropbox (CloudStorage) | transcripts (`~/.claude/projects`, `.codex/sessions*`, `.hermes/sessions`, ...) -> `~/Library/CloudStorage/Dropbox/conversation-backups/...` | `rsync -a` through the FileProvider mount | **Skipped** (`DISK_PRESSURE`) whenever Data volume free <=10%. Disk is 99% used (16 GiB free) now. |
| dropbox_rclone | same sources -> `dropbox:conversation-backups/...` over the Dropbox API | `rclone copyto --size-only --ignore-checksum`, no delete | Runs every tick. 67 OK, 10 FAILED, 2 SKIP in the latest report. Failures are `path/insufficient_space`. |

The Dropbox account is full: `rclone about dropbox:` shows Total 2.006 TiB, Used 2.006 TiB. New or grown files fail to upload (9 insufficient_space errors in the last report window, in the claude projects job and the Linux-delta job). Small files that fit still go through, which is why the report mixes OK and FAILED.

## Why the Dropbox writes stopped around 2026-09-02

- The CloudStorage rsync leg only runs when the disk is under 90% used. Daily results show `dropbox=DISK_PRESSURE` for most ticks from 08-01 on. It ran (`PARTIAL`) on 09-01, 09-03, 09-04, 09-06..08, 09-11..14, 09-16..19, 09-23/24 and 09-29, whenever a cleanup briefly freed space. Last run: 09-29 (one tick). Result is never `SUCCESS`, only PARTIAL or skipped.
- Folder mtimes match this: claude_conversations 09-02, codex/gemini 08-31, hermes 08-30, memory 08-29, shell 08-30, opencode 08-07, aside 08-25, config 08-07. `conversation-backups` newest child is 09-29 (rclone side). `claude_backup_jeffpc_linux` newest 10-02 (Linux delta stream).
- Directory-level writes after ~09-02 come only from the rclone leg, which is limited by the quota above.
- Not a stopped job: the launchd job is loaded and running. It is degraded by disk pressure plus a full Dropbox.

## Why the Google Drive "AI convos" copy stopped

- Writer: `~/projects/user_scope/scripts/sync-convos-to-gdrive.sh`. It does `rsync -a --ignore-existing` from `.codex/sessions`, `.claude/projects`, `.gemini/antigravity-cli`, `.cursor/chats`, `.hermes/sessions`, `.openclaw` into `~/Library/CloudStorage/GoogleDrive-jleechan@gmail.com/My Drive/AI convos`. Additive, no deletes.
- Nothing schedules it. No LaunchAgent, cron entry or hook references it (grepped `~/Library/LaunchAgents`). `backup-home.sh` line 1369 only says it is "handled by the standalone script already running on a schedule", which is stale. The script was last touched 2026-08-25.
- The Drive mount directory still exists but is a stale shell; `AI convos` child dirs have mtimes of 2026-08-01 (stat of top level only; I did not walk deeper, so the 08-27 last write is not contradicted). Drive for desktop is gone, so the script exits with "Google Drive mount not found" or writes into a dead mount.
- Conclusion: manual or ad-hoc invocation stopped around 08-27; no active scheduler exists.

## Other writers

| Label / script | Schedule | Destination | Notes |
|---|---|---|---|
| `ai.hermes.schedule.qdrant-backup` -> `~/.hermes/scripts/backup-qdrant-to-dropbox.sh` | daily 02:00 | `~/Dropbox/local/qdrant-backups/<date>/` (symlink to CloudStorage) | `rsync -a --delete` of `~/.hermes/qdrant_storage` (~73 MB) into a new dated dir each day: **full copy daily**. Last exit 32512 (127): `mapfile: command not found` under macOS bash 3.2, so the 7-day pruning never runs. Backups accumulate: 20 dated dirs now (09-13..10-03). Small, but a real bug. |
| `ai.hermes.schedule.cron-backup-sync` | Mon-Fri 08:25 | Hermes `docs/context/CRON_JOBS_BACKUP.*`, committed to git | Healthy (10-02 commit fcd017a). Not conversations. |
| `ai.hermes.claude-memory-sync` | every 900s | `~/.hermes/workspace/claude-memory-context.md` | Local only, healthy (191 files). No cloud. |
| `org.jleechan.backup-dropbox-orphan-cleanup` | weekly | deletes rsync temp orphans >7d under `Dropbox/conversation-backups` | Last run 09-13, deleted=0. Only delete at destination in this stack. |
| `ai.hermes.backup-leak-watchdog` | every 900s | monitor only | Ticking, 0 anomalies. Its err log shows `fork: retry: Resource temporarily unavailable` on 10-01. |
| `com.jleechan.conversation-backup` | 4h | n/a | **Disabled** (`.plist.disabled`, 2026-03-05); not loaded. |
| `hermes-backup` (`dropbox-hermes-backup.sh`, `backup-hermes-full.sh`) | none found | `Dropbox/hermes_backup/latest` with `rsync --delete` | No LaunchAgent loads them. Dormant. |
| Linux delta stream (inside backup-home.sh) | each tick | `dropbox:claude_backup_jeffpc_linux/conversation-backups/` | Pulls tarball deltas from the Linux box over ssh. Currently failing on insufficient_space. Delta tarballs accumulate; "archive cleanup failed" in logs. |
| crontab | n/a | n/a | No backup entries (moltbook-poster, mem-watchdog only). |
| `~/.claude/settings.json` hooks | n/a | n/a | No SessionEnd. Stop hook only runs `cross_cli_status.py`. No transcript copying. |

## Behavior summary

- Incremental or full: rsync legs use `--ignore-existing` (additive). That means files that grow after first copy (live `.jsonl` transcripts) are NOT refreshed at the destination. rclone leg is `copyto --size-only`, so it re-uploads grown files but skips same-size ones. Neither leg re-copies unchanged files, so there is no repeated duplication, except the qdrant job (full daily copy) and Linux delta tarballs (new file per run).
- Deletes at destination: none in backup-home.sh (no `--delete` in active code). Deleting paths: qdrant `rsync --delete` into its own dated dir, hermes_backup script (dormant), weekly orphan cleanup (temp files only).
- Git remotes: `~/projects/user_scope` -> `jleechanorg/user_scope` (stuck, ahead 3 / behind 58, `.git` ~6.6 GB). `~/.disk_magician_backup` -> `jleechanorg/disk_backup` (last commit 2026-10-03). `~/roadmap` -> `jleechanorg/roadmap` (last commit 09-25). `~/llm_wiki` -> `jleechanorg/llm-wiki` (10-03). None of these archive raw conversations except the user_scope config snapshots.
- Prior memory/beads: no earlier conclusion on conversation backups. `br search backup` returned only unrelated disk beads.

## Root causes, ranked

1. Dropbox account at quota (2.006 TiB of 2.006 TiB): rclone uploads of new data fail with `path/insufficient_space`.
2. Local disk 99% used: the FileProvider rsync leg self-skips (`DISK_PRESSURE`), so the only path to Dropbox is rclone, which hits cause 1.
3. user_scope git push rejected for 3+ weeks (divergent history); GitHub copy of configs is stale.
4. Google Drive: unscheduled script plus uninstalled Drive for desktop.
5. Qdrant pruning broken (`mapfile` on bash 3.2); daily dirs accumulate.

Coverage caveat: the per-folder newest mtimes above were read from direct children only (no deep walk), so a deeper file could be newer than reported.
