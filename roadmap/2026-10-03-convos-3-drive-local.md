# Convos audit lane 3: Google Drive "My Drive" mirror (2026-10-03)

Read-only, metadata-only walk plus sha256 on small samples. Data: `/tmp/convos/drive/` (`inventory.json`, per-folder manifests `<folder>.tsv`, `cmp3.json`, `dataless.json`, `*_drive_only.json`).

## Verdict

The Drive copy is NOT a pure redundant duplicate. Where a local original exists the content is byte-identical (sampled), but Drive holds a large set of conversation files that exist nowhere else locally or in Dropbox. The "fully hydrated, 50 GiB" premise is also wrong: only AI convos is resident, and part of it is cloud-only.

## Whole mirror

- 1,428 top-level entries, 190,349 files, 632.6 GiB apparent, 45.06 GiB allocated.
- AI convos = 45.06 GiB of the 45.06 GiB allocated (99.9998%). Every other folder is dataless (st_blocks = 0, `SF_DATALESS` flag): about 557 GiB apparent of placeholders that cannot be read with Drive for desktop absent. Largest: cindil portfolio 486 GiB (64k files), macbook backup 13.3, mac upgrade backup 9.2, wedding day videos 8.1, wedding photos 6.2, field 6.1, text messages 4.8. Personal docs/photos were counted only.
- Top 20 files by allocated size are all AI convos (largest: a 1.2 GiB codex rollout, 611 MiB codex, 550 MiB gemini task log, 229 MiB gemini .db). By directory: codex sessions 32.0 GiB, claude projects 9.6, gemini conversations 2.0, gemini brain 1.25, cursor chats 0.2.
- Mtime range for AI convos: 2025-08-17 to 2026-08-27.

## AI convos folders

| folder | files | apparent GiB | allocated GiB | mtime range | dataless (cloud-only) files |
|---|---|---|---|---|---|
| claude_conversations | 63,834 | 13.96 | 9.59 | 2025-08-17..2026-08-27 | 19,583 (4.47 GiB) |
| codex_conversations | 37,844 | 58.08 | 32.05 | 2025-08-28..2026-08-27 | 7,020 (26.1 GiB) |
| cursor_conversations | 77 | 0.20 | 0.20 | 2026-06-23..2026-08-01 | 0 |
| gemini_conversations | 13,523 | 3.18 | 3.21 | 2026-07-26..2026-08-25 | 0 |
| hermes_conversations | 1 | 0.005 | 0.005 | 2026-08-01 | 0 |
| openclaw_conversations | 0 (empty) | 0 | 0 | n/a | n/a |

Layout and extensions (full year-month histograms are in `inventory.json`):
- claude: `projects/<encoded-cwd>/<session-uuid>.jsonl` plus `subagents/`, 47.7k files, and a second legacy layer of 362 top-level `-Users-...` project dirs (16.1k files, 2025 layout). Also `history.jsonl`, `settings.json`. Extensions: .jsonl 32.2k, .txt 20.1k (tool-results), .json 8.4k, .md 2.7k. Peak months 2025-09 (7.3k), 2025-11 (7.8k), 2026-07 (39.4k).
- codex: `sessions/2026/MM/DD/rollout-*.jsonl` (30.8k) plus `2025/MM/DD/` (7.0k, Aug-Dec 2025), `history.jsonl`. All .jsonl.
- cursor: `chats/<workspace-hash>/<session-uuid>/{store.db,-wal,-shm,meta.json}`, `prompt_history.json`, `mcp.json`.
- gemini: `brain/<uuid>/...` (526 sessions, 12.2k files, one with 7.5k) and `conversations/<uuid>.db` (528 db plus wal/shm). Extensions .md, .json, .py, .log, .jsonl, .db.
- hermes: only `sessions/sessions.json` (5.4 MB).

## Comparison against local originals (and Dropbox)

All files matched by path (codex also via sessions_archive/archived_sessions; claude/codex also via uuid-jsonl basename; cursor via uuid dir). "Drive-only" = no local original and not in Dropbox (path or uuid-name).

| folder | resident, original exists | dataless, original exists | has no local original | of which Drive-only |
|---|---|---|---|---|
| claude | 2,769 | 40 | 61,025 | 30,741 files (6.2 GiB): 11,201 resident (1.29 GiB), 19,538 dataless (4.47 GiB); ~30.3k of the rest are in Dropbox |
| codex | 30,824 | 1,168 | 5,852 | 5,852 (25.3 GiB), ALL dataless, all 2025-09 sessions |
| gemini | 0 | 0 | 13,523 | 13,523 (3.18 GiB), all resident |
| cursor | 2 | 0 | 75 | 49 (0.20 GiB, resident); 26 in Dropbox |
| hermes | 1 | 0 | 0 | 0 (but see below) |

Hash samples (40 resident files under 20 MiB, spread across months; Drive vs local original):
- codex: 40/40 identical. claude: 39 identical, 1 different (`memory/MEMORY.md`, local copy is newer). cursor: 2/2 identical (only 2 had a matching original). gemini: 0 sampleable, no local original for any file. hermes: Drive `sessions.json` is 5.4 MB vs local 359 KB (different; Drive is an older, larger snapshot).
- Original-missing counts in the sample: claude/gemini/cursor mostly missing locally, consistent with the table above.

Why originals are gone locally: Claude local retention is about 1.8k project dirs (many old worktree sessions pruned); Gemini Antigravity `~/.gemini/antigravity/{brain,conversations}` are symlinks into a vanished `/var/folders/.../ao-wa-orchestrator/` tmp dir, and the 526 Drive brain UUIDs have zero overlap with the 501 local `antigravity-cli/brain` UUIDs; codex 2025-09 sessions are absent from `~/.codex/sessions_archive`.

## What this means

1. Unique and readable on Drive today: gemini (3.18 GiB, 13.5k files), claude 11.2k files (1.29 GiB), cursor 49 files (0.20 GiB). About 4.7 GiB. Do not remove the Drive folder before copying these out.
2. Unique but unreadable offline: codex 2025-09 (5,849 jsonl, 25.3 GiB) and 19.5k claude files (4.5 GiB) are dataless placeholders. Reads hang with ETIMEDOUT (errno 60; 15/40 in an earlier unfiltered codex sample). The content exists only in Google's cloud, if at all. Drive for desktop (or the Drive web download) would be needed to recover them; I did not use the Drive MCP.
3. Everything else on Drive (about 38 GiB resident) is byte-identical redundant with local `~/.codex/sessions`, `~/.claude/projects`, or Dropbox, per samples (not a full-hash proof).
4. Caveat: Dropbox presence was checked by path and uuid-name only, not hashed, and Dropbox files may themselves be online-only.
