# Convos audit 1/6: local originals of AI conversation history (2026-10-03)

Read-only metadata walk (os.scandir/lstat, 120 s budget per subtree, 6 threads). No file contents read. Raw data: `/tmp/convos/originals/inventory.json` (236 entries) and per-file manifests `codex.tsv` (42,379 rows), `claude.tsv` (33,907, projects only), `gemini.tsv` (188,390), `cursor.tsv` (3,853; relpaths prefixed `dotcursor/` or `appsupport/`), `hermes.tsv` (3,775; selected session/state/db subpaths of ~/.hermes).

## Store table (entries with >=0.01 GiB allocated or >=200 files)

| key | kind | files | apparent GiB | allocated GiB | oldest | newest | notes |
|---|---|---|---|---|---|---|---|
| codex:sessions | dir | 39776 | 61.334 | 61.437 | 2026-02-27 | 2026-10-03 |  |
| claude_other:state | dir | 471903 | 18.275 | 19.258 | 2026-09-06 | 2026-10-03 | PARTIAL (120 s budget hit); 2424 dataless |
| codex:thread_history_1.sqlite | sqlite | 1 | 11.207 | 11.215 | 2026-10-03 | 2026-10-03 |  |
| hermes:state.db | sqlite | 1 | 9.111 | 9.118 | 2026-10-03 | 2026-10-03 |  |
| claude_projects:projects | dir | 33903 | 6.539 | 6.615 | 2025-12-15 | 2026-10-03 |  |
| gemini:antigravity-cli/brain | dir | 138279 | 3.599 | 3.941 | 2025-09-08 | 2026-10-03 | 232 dataless |
| gemini:antigravity-cli/conversations | dir | 512 | 2.566 | 2.685 | 2026-09-14 | 2026-10-03 |  |
| cmuxterm:workstream.jsonl | jsonl | 1 | 2.657 | 2.662 | 2026-10-03 | 2026-10-03 |  |
| codex:state_5.sqlite | sqlite | 1 | 2.629 | 2.629 | 2026-10-03 | 2026-10-03 |  |
| codex:sessions_archive | dir | 2190 | 1.85 | 1.854 | 2025-08-28 | 2026-02-01 |  |
| cursor_app:User/globalStorage | dir | 2146 | 1.784 | 1.789 | 2026-08-11 | 2026-09-25 | 1 dataless |
| aside_app:Default | dir | 15801 | 1.671 | 1.71 | 2026-06-27 | 2026-10-03 |  |
| claude_other:supervisor | dir | 4 | 0.7 | 0.7 | 2026-07-26 | 2026-08-15 |  |
| aside_app:AsideDaemon | dir | 432 | 0.515 | 0.516 | 2026-10-02 | 2026-10-03 |  |
| aside_app:AsideUpdater | dir | 29 | 0.458 | 0.459 | 2026-09-13 | 2026-10-03 | 2 dataless |
| codex:logs_2.sqlite | sqlite | 1 | 0.442 | 0.455 | 2026-10-03 | 2026-10-03 |  |
| aside_dot:u | dir | 1151 | 0.656 | 0.407 | 2026-07-25 | 2026-10-03 | 340 dataless |
| hermes:logs | dir | 403 | 0.326 | 0.332 | 2026-07-11 | 2026-10-03 |  |
| gemini:history | dir | 48137 | 0.079 | 0.227 | 2026-01-09 | 2026-10-02 |  |
| cursor_app:CachedData | dir | 117 | 0.195 | 0.196 | 2026-08-20 | 2026-09-20 |  |
| cursor_dot:chats | dir | 272 | 0.151 | 0.166 | 2026-09-06 | 2026-09-30 |  |
| cursor_dot:projects | dir | 820 | 0.163 | 0.165 | 2026-08-21 | 2026-09-30 |  |
| aside_app:AsideAgentManager | dir | 3856 | 0.142 | 0.149 | 2026-10-02 | 2026-10-03 |  |
| aside_app:extensions_crx_cache | dir | 11 | 0.13 | 0.13 | 2026-09-10 | 2026-10-02 |  |
| cmuxterm:.dat.nosync16097.F0iN9t | file | 1 | 0.116 | 0.116 | 2026-09-13 | 2026-09-13 |  |
| cmuxterm:.dat.nosync3D84.gJe69B | file | 1 | 0.116 | 0.116 | 2026-09-13 | 2026-09-13 |  |
| claude_other:file-history | dir | 1777 | 0.092 | 0.096 | 2026-08-31 | 2026-10-03 |  |
| aside_app:aside_component_crx_cache | dir | 4 | 0.08 | 0.08 | 2026-10-03 | 2026-10-03 |  |
| cursor_dot:ai-tracking | dir | 1 | 0.061 | 0.062 | 2026-09-25 | 2026-09-25 |  |
| cursor_app:User/workspaceStorage | dir | 495 | 0.064 | 0.061 | 1979-12-31 | 2026-09-23 | 1 dataless |
| hermes:state | dir | 3220 | 0.046 | 0.053 | 2026-05-29 | 2026-10-03 |  |
| codex:history.jsonl | jsonl | 1 | 0.048 | 0.048 | 2026-10-03 | 2026-10-03 |  |
| cmuxterm:agent-turn-diff-baseline-snapshots | dir | 1407 | 0.042 | 0.045 | 2026-09-26 | 2026-10-03 |  |
| aside_app:component_crx_cache | dir | 10 | 0.034 | 0.034 | 2026-07-23 | 2026-10-02 |  |
| antigravity_app:User/globalStorage | dir | 132 | 0.03 | 0.03 | 2026-02-13 | 2026-05-20 |  |
| aside_sessions:.aside_sessions | dir | 51 | 0.028 | 0.028 | 2026-08-22 | 2026-09-16 |  |
| claude_other:history.jsonl | jsonl | 1 | 0.025 | 0.025 | 2026-10-03 | 2026-10-03 |  |
| aside_app:WasmTtsEngine | dir | 10 | 0.022 | 0.022 | 2026-10-01 | 2026-10-01 |  |
| aside_app:aside_sandbox | dir | 70 | 0.022 | 0.022 | 2026-08-19 | 2026-09-17 |  |
| aside_app:WidevineCdm | dir | 5 | 0.019 | 0.019 | 2026-06-27 | 2026-06-27 |  |
| claude_desktop:local-agent-mode-sessions | dir | 331 | 0.019 | 0.019 | 2026-04-07 | 2026-06-04 |  |
| cmuxterm:events.jsonl.1 | file | 1 | 0.016 | 0.016 | 2026-10-03 | 2026-10-03 |  |
| aside_app:AsidePasswordManager | dir | 144 | 0.015 | 0.015 | 2026-10-02 | 2026-10-03 |  |
| antigravity_app:User/workspaceStorage | dir | 361 | 0.015 | 0.015 | 2025-11-18 | 2026-05-20 |  |
| aside_app:aside_component_update.log | file | 1 | 0.014 | 0.014 | 2026-10-03 | 2026-10-03 |  |
| aside_app:GraphiteDawnCache | dir | 64 | 0.012 | 0.012 | 2026-09-11 | 2026-10-03 |  |
| cmuxterm:events.jsonl | jsonl | 1 | 0.011 | 0.012 | 2026-10-03 | 2026-10-03 |  |
| codex:sqlite | dir | 3 | 0.01 | 0.01 | 2026-10-02 | 2026-10-03 |  |
| codex:logs_2.sqlite-shm | sqlite | 1 | 0.009 | 0.01 | 2026-10-03 | 2026-10-03 |  |
| cmuxterm:agent-turn-diff-baseline-snapshots-staging | dir | 221 | 0.008 | 0.009 | 2026-09-13 | 2026-10-01 |  |
| claude_other:session-env | dir | 1849 | 0.001 | 0.007 | 2026-09-03 | 2026-10-03 |  |
| gemini:antigravity-cli/annotations | dir | 1450 | 0.0 | 0.006 | 2026-08-25 | 2026-10-03 |  |
| claude_other:teams | dir | 711 | 0.002 | 0.004 | 2026-02-21 | 2026-10-03 |  |
| codex:memories | dir | 369 | 0.002 | 0.003 | 2026-05-07 | 2026-10-03 |  |
| claude_other:tasks | dir | 374 | 0.0 | 0.002 | 2026-05-09 | 2026-09-14 |  |
| claude_other:paste-cache | dir | 258 | 0.001 | 0.001 | 2026-09-03 | 2026-10-03 |  |

Month histograms (file counts by mtime) are per entry in inventory.json; key ones:

- codex:sessions: 2026-02:54, 03:3857, 04:6440, 05:3555, 06:5557, 07:7161, 08:8060, 09:4712, 10:380
- claude_projects:projects: 2025-12:2, 2026-01:9, 02:19, 03:377, 04:590, 05:346, 06:840, 07:530, 08:708, 09:28746, 10:1736
- gemini brain: 2026-09:133059 of 138279 files

## Group totals (allocated GiB)

codex 77.7 (sessions 61.4, thread_history_1.sqlite 11.2, state_5.sqlite 2.6, sessions_archive 1.85); claude ~/.claude/projects 6.6; claude_other 20.1 (state 19.3, partial); gemini/antigravity-cli 6.9 (brain 3.9, conversations 2.7); hermes 9.5 (state.db 9.1); cmuxterm 3.0 (workstream.jsonl 2.66); cursor 2.4 (app globalStorage 1.8, ~/.cursor 0.4); aside app 3.2 + ~/.aside/u 0.4; openclaw, opencode, claude desktop, Codex app, shell history: negligible (<0.05).

## Findings

1. Codex is the dominant original: 39,776 session JSONLs (61.4 GiB, 2026-02-27 onward) plus sessions_archive (2,190 files, 1.85 GiB, 2025-08-28 to 2026-02-01) and 11 archived_sessions. Largest single rollout is 1.2 GiB (2026-03-17).
2. Huge single SQLite files: `~/.codex/thread_history_1.sqlite` 11.2 GiB, `~/.hermes/state.db` 9.1 GiB, `~/.codex/state_5.sqlite` 2.6 GiB, `~/.cmuxterm/workstream.jsonl` 2.66 GiB, `~/.codex/logs_2.sqlite` 0.44 GiB. All are live (mtime today, WAL files present), so a naive file copy is not a consistent backup and cloud sync of them will re-upload on every write.
3. ~/.codex/history.sqlite, history.db, state.sqlite are 0-byte stubs.
4. Symlink aliases: `~/.hermes_prod` and `~/.openclaw.bak` both -> `~/.hermes` (counted once, via ~/.hermes only). `~/.gemini/antigravity/brain` and `/conversations` are symlinks (since Jul 26) to `/var/folders/.../T/ao-wa-orchestrator/antigravity/{brain,conversations}`, which no longer exist (dangling); the real stores are `~/.gemini/antigravity-cli/{brain,conversations}`. A cloud sync that follows ~/.gemini/antigravity gets nothing.
5. `~/.claude/state` is the biggest non-obvious store: >=471,903 files / 18.3 GiB apparent (walk hit the 120 s budget, so true size is larger) with 2,424 dataless (st_blocks==0, size>0) files; mtimes only from 2026-09-06 (per-task clones, per this repo's notes). Not session JSONL, but it is a huge file count. The dataless files were not opened.
6. ~/.claude/projects (the true Claude transcripts) is only 33,903 files / 6.6 GiB with oldest mtime 2025-12-15 and 28,746 files dated 2026-09; transcript history before Dec 2025 is absent locally (cleanup or retention), so any cloud copy may now be the only holder of older sessions. Two sibling dirs (`projects--Users-jleechan-project_agento-agent-orchestrator`, `projects-Users-jleechan-.cursor-worktrees-worldarchitect.ai-9fd9`) hold 4 files and 0 files respectively and are included in claude.tsv.
7. Gemini brain: 138,279 files, 96% dated 2026-09 (likely a mass touch/restore or a burst of agent activity); conversations/*.db: 512 files, 2.7 GiB, only since 2026-09-14. gemini/history: 48,137 tiny files (0.08 GiB apparent, 0.23 allocated).
8. Hermes: the 9.1 GiB state.db dwarfs everything else; sessions/ itself is 4 files. hermes.tsv covers sessions, state, memory, memories, logs, ao-session-tracker and top-level *.db/*.sqlite/MEMORY.md/gateway_state.json only (the rest of ~/.hermes is a git checkout, not history).
9. Not present: ~/.agy, ~/.local/share/agy, ~/.antigravity_cli, ChatGPT desktop app dir. opencode (15 files), openclaw (36), Claude desktop local-agent-mode-sessions (331 files, 0.02 GiB, 2026-04..06), Codex app support (18 files) are tiny.
10. Aside: ~/Library/Application Support/Aside 3.2 GiB (Default 1.7, mostly browser profile), ~/.aside/u 1,151 files with 340 dataless files (not opened).

## Method caveats

- Allocated GiB uses st_blocks*512 with hardlinks counted once; apparent uses st_size.
- Mtime histograms reflect mtimes, not session creation; bulk touches (Sep 2026) skew them.
- claude_other:state is partial; all other entries completed within budget.
- cursor.tsv combines ~/.cursor and ~/Library/Application Support/Cursor; others are single-base. Manifests were written once at end from per-subtree parts, no store was modified.
