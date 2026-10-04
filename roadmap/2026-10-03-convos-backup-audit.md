# AI conversation backup audit — synthesis (2026-10-03)

Lane reports: roadmap/2026-10-03-convos-{1-originals,2-dropbox,3-drive-local,4-cloud-web,5-backup-jobs,6-duplicates}.md

## Headline
Cloud backup of new conversations is effectively stopped. Dropbox is full (rclone about: 2.006 TiB used of 2.006 TiB; verified live) so rclone uploads fail with path/insufficient_space, and the local rsync leg skips itself (dropbox=DISK_PRESSURE) while the Data volume is >90% full. The Drive 'AI convos' copy has no writer (sync-convos-to-gdrive.sh is unscheduled; Drive for desktop is not installed).

## Matrix
| Source | Local original | Dropbox | Drive cloud | Drive local copy |
|---|---|---|---|---|
| Codex | sessions 61.4 GiB (2026-02-27..now) + sessions_archive 1.85 (2025-08..2026-02) | standalone folder stale since 08-28..09-02; conversation-backups holds 35,161 of its 35,163 files | 2025 only, newest 2025-12-26 (under 'cli convos') | 37.8k files; sampled 40/40 byte-identical; 5,852 files (25 GiB, 2025-09) are cloud placeholders |
| Claude projects | 6.6 GiB, oldest mtime 2025-12-15 | claude_conversations 83k files, newest 09-02 | 50 project folders, Dec 26 2025 | 63.8k files; 30.7k not found locally (11.2k readable, 19.5k placeholders) |
| Gemini | antigravity-cli 6.9 GiB (2026-09 only); old antigravity symlinks dangle | gemini_conversations 3,019 files | none | 13.5k files, 3.2 GiB, readable, no local original, different set than Dropbox |
| Cursor | 2.4 GiB | 185 files | none | 49 files (0.2 GiB) not found elsewhere |
| Hermes | 9.5 GiB (state.db 9.1) | live (sessions.json 2026-10-03 00:49 via conversation-backups) | none | stale older snapshot |
| Aside/opencode/openclaw | small | aside 62 files; opencode 31k; openclaw 204k (conversation-backups) | none | openclaw empty |

## Duplication
- Local: transcripts are NOT duplicated across stores (0 same-name+size groups among codex/sessions, sessions_archive, claude/projects). 2.0 GiB of git-tracked jsonl dupes (not conversations).
- Dropbox: conversation-backups (148+ GiB apparent) is a growing superset of the standalone *_conversations folders; `local` 88 GiB apparent (qdrant dated copies, 20 so far, 7-day prune crashes on macOS bash 3.2 `mapfile`).
- Drive local copy: redundant for what has a local original or cloud copy; UNIQUE: ~4.7 GiB readable (gemini 3.18, ~11.2k claude files, cursor 0.2).
- Not observed: Dropbox web (Aside has no Dropbox session; login page offered Continue as Jeffrey, not clicked); claude.ai/ChatGPT/Gemini web histories.

## Writers
org.jleechan.user-scope-backup (every 2h) -> ~/projects/user_scope/scripts/backup-home.sh: git leg fails (local user_scope repo 3 ahead / 58 behind origin/main since ~09-10), rsync leg skips at disk pressure, rclone leg fails on Dropbox quota. com.jleechan.conversation-backup disabled since March.
