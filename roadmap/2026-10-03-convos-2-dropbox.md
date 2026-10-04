# Convos lane 2: ~/Library/CloudStorage/Dropbox inventory (2026-10-03, read-only)

Data: /tmp/convos/dropbox/inventory.json, per-folder TSVs in the same dir. Metadata only (scandir/lstat); no file contents read.

## Sync state
- Personal Dropbox Pro (info.json: is_team=false), root = ~/Library/CloudStorage/Dropbox (File Provider mode).
- Files carry com.dropbox.attrs / com.dropbox.internal xattrs. Placeholders = st_blocks==0 and size>0.
- Dropbox, Dropbox Helper, DropboxFileProv, DropboxActivity processes are running.
- Essentially everything is dataless: only ~0.54 GiB is hydrated locally, all in `local/qdrant-backups/2026-10-03/collections` (about 549 MiB, 197 files), plus a handful of files elsewhere.
  Local-disk cost of the whole Dropbox is therefore about 0.5 GiB.

## Per-folder (apparent GiB / allocated / files / dataless / newest mtime)
| folder | files | apparent | alloc | dataless | oldest | newest |
|---|---|---|---|---|---|---|
| claude_conversations | 83407 | 13.2 | 0 | 83375 | 2025-09-05 | 2026-09-02 |
| codex_conversations | 35163 | 41.8 | 0 | 35157 | 2025-11-03 | 2026-08-31 |
| opencode_conversations | 31324 | 0.61 | 0 | 31321 | 2026-04-02 | 2026-08-30 |
| gemini_conversations | 3019 | ~0 | 0 | 3018 | 2026-07-23 | 2026-08-31 |
| cursor_conversations | 185 | ~0 | 0 | 185 | 2026-04-18 | 2026-08-31 |
| hermes_conversations | 9 | 0.02 | 0 | 9 | 2026-07-31 | 2026-08-31 |
| aside_conversations | 62 | ~0 | 0 | 62 | 2026-07-25 | 2026-08-28 |
| memory | 110 | ~0 | 0 | 110 | 2026-02-14 | 2026-08-29 |
| config | 4 | ~0 | 0 | 4 | 2026-06-18 | 2026-08-06 |
| shell | 1 | ~0 | 0 | 1 | 2026-08-30 | 2026-08-30 |
| conversation-backups (PARTIAL, 180 s cap) | 471373+ | 147.8+ | 0 | 468558 | 2025-08-19 | 2026-10-03 00:49 |
| claude_backup_jeffpc_linux | 2426 | 11.25 | 0 | 2424 | 2025-07-26 | 2026-10-02 22:29 |
| local | 40679 | 87.9 | 0.54 | 40482 | 2026-07-02 | 2026-10-03 13:11 |
| WorldAIClaw | 1 (.ipa) | 0.009 | 0 | 1 | 2026-08-12 | 2026-08-12 |
| Wedding / Jeffrey + Cindil - Indigo West | 2 / 964 (jpg) | 0.85 / 6.2 | 0 | all | 2025-10 | 2025-12 |
| top-level personal files | 30 | 0.019 | 0 | 29 | | |

Year-month histograms, layouts, top-6 extensions, top-30 hydrated lists are in inventory.json.
Newest-file paths (patterns only):
- claude_conversations: claude.json, history.jsonl (2026-09-02); sessions/ jsonl bulk is 2026-07..08 (28.9k/38.2k files).
- codex_conversations: skills/.system/... (2026-08-31); sessions jsonl 2026-06..08. Includes state_5.sqlite (2.8 GB apparent).
- opencode: opencode/opencode.db-shm (2026-08-30); gemini/cursor/hermes/aside/memory/shell/config: late Aug 2026.

## Questions
1. Is the Dropbox backup still being written? Mixed.
   - The standalone `*_conversations`, memory, config, shell folders stopped at 2026-08-28..09-02 (about 31 days stale). They are the old backup path, no longer updated.
   - `conversation-backups/` is live: newest 2026-10-03 00:49 (`hermes_conversations/{hermes,hermes_prod}/sessions/sessions.json`); 2026-08..10 histogram is still growing. This is the current writer.
   - `claude_backup_jeffpc_linux/conversation-backups/linux-conversation-delta-<ts>-<id>.tar.gz` last written 2026-10-02 22:29, so the Linux box (jeff-ubuntu) is still pushing deltas.
   - `local/qdrant-backups/<date>/` is written daily (2026-10-03).
2. Is conversation-backups a second copy of the `*_conversations` folders? Yes, a superset successor. Its top level holds same-named subfolders plus extras (openclaw_conversations 204k files, coding_memory, agent_orchestrator, antigravity, ccproxy, git, hermes, supervisors, wrappers, mcp-daemon_conversations, local, _stray_quarantine_2026-09-01).
   Path overlap with the standalone TSV (scan partial, so counts are lower bounds): codex 35161/35163, gemini 3019/3019, aside 62/62, hermes 9/9, cursor 116/185, opencode 6044/31324. Its copies of hermes/opencode/codex/cursor are larger (127k/78k/56k/968 files), i.e. it keeps growing past what the standalone folders hold. claude_conversations did not get scanned inside the 180 s cap (dir exists with the same contents, e.g. claude_mem, agent_orchestrator, claude_agent_f); overlap is unmeasured. Standalone folders are therefore redundant duplicates once conversation-backups is verified.
3. Is claude_backup_jeffpc_linux a stale one-off? No. Its first files are from 2025-07-26, but it received a tar.gz delta on 2026-10-02 (histogram 2026-08: 88, 09: 41, 10: 11 files). It is the Linux machine's ongoing delta stream (about 11.3 GiB apparent), not a one-off. Only the 2 newest files are hydrated.

## Caveats
- conversation-backups scan hit the 180 s budget (471k files seen, truncated); totals are lower bounds and its TSV lacks claude_conversations/ and later subtrees.
- Do not hydrate anything: reading these files would pull ~300 GiB onto a near-full disk.
- Conflicted copies exist (e.g. `... (Jeff LC's conflicted copy 2026-09-06).json`, `home_backup_metadata (... conflicted copy 2026-05-24).txt`), showing two hosts writing the same paths.
