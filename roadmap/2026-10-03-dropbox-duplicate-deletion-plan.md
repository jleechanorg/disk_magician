# Dropbox duplicate deletion plan (for review — nothing deleted yet)

Date: 2026-10-03. Owner: jleechan (personal Dropbox, File Provider / Stream mode on a Mac).

## Problem
The Dropbox account is full (2.006 / 2.006 TiB). The backup job's uploads fail with `path/insufficient_space`, so new AI-conversation backups are not reaching the cloud. We want ~55 GiB of headroom by removing files that exist twice in the same account.

## What is duplicated
Two trees in the same Dropbox account hold the same conversation backups:

- Standalone folders at the Dropbox root: `codex_conversations`, `claude_conversations`, `gemini_conversations`, `aside_conversations`, `cursor_conversations`, `hermes_conversations`, `opencode_conversations`, `memory`, `config`, `shell` (stale: last written 2026-08-28 .. 2026-09-02, old writer).
- `conversation-backups/<same folder name>/...` — the current writer's tree, a growing superset (newest writes 2026-10-03).

Method (local CLI only, no Dropbox API): for every file in a standalone folder, `lstat` the counterpart at `conversation-backups/<folder>/<same relative path>` (metadata only; the files are online-only placeholders and are never opened or downloaded). Counterpart exists and size is identical => duplicate.

| Folder | Files | Duplicate (same path+size) | GiB | Kept (no identical counterpart) |
|---|---|---|---|---|
| codex_conversations | 35,163 | 35,091 | 41.17 | 72 (0.61 GiB: 70 files where the conversation-backups copy is larger/newer, 2 tiny `.git` objects with no counterpart) |
| claude_conversations | 83,407 | 82,982 | 13.13 | 425 (0.09 GiB, counterpart differs; newer in conversation-backups) |
| opencode_conversations | 31,324 | 31,324 | 0.61 | 0 |
| gemini / aside / cursor / hermes / memory / config / shell | 3,390 | 3,299 | ~0.01 | 91 (cursor: 69 chat files missing from conversation-backups; hermes: two ~4 MB `sessions.json` that are larger than the counterpart; rest differ) |
| **Total** | **153,284** | **152,696** | **54.92** | **588 (0.71 GiB)** |

Caveats on the evidence:
- Size equality is not a content hash. An earlier Dropbox-API content-hash listing (already collected, not repeated) for codex_conversations showed 35,087 hash-identical of the 35,091 size-equal files: 4 size-equal files differed. Expect a similar ~0.01% rate elsewhere. Session files are append-only JSONL, so equal size normally means equal content, but this is an inference, not proof, for claude/opencode/others.
- Only about half of the size-equal pairs also have equal mtimes (the two tree writers set mtimes differently).
- Dropbox web does not show content hashes; there is no CLI-only way to hash online-only files without downloading them (which would fill the local disk).

## Proposed deletion
Delete only the 152,696 duplicate files in the standalone folders (path list in `/tmp/convos/dup/<folder>.delete.json`). Keep the 588 files that have no identical counterpart. Never touch `conversation-backups`, `local`, `claude_backup_jeffpc_linux`, personal files, or anything else.

Mechanism (local CLI): a script that reads the delete lists, and for each path re-checks immediately before deleting that (a) the standalone file still has the recorded size, (b) the `conversation-backups` counterpart still exists with the same size, then `rm`s the standalone file through the File Provider path (the delete propagates to the cloud). Dry-run first (prints counts and a sample, deletes nothing); real run in batches of 5,000 with a stop on any error and a log of every removed path; empty standalone directories removed afterwards. Run only after explicit user approval of this plan and approval from /advice and /wa.

Expected effect: ~55 GiB less in Dropbox. Deleted files do not count toward quota; Dropbox keeps deleted files recoverable for a limited retention period (plan-dependent, 30 days on most plans; to be checked) from the web "Deleted files" view or by restoring from the log.

## Risks and rollback
- After deletion each file exists once in Dropbox (in `conversation-backups`) instead of twice. The account is the only cloud copy for claude sessions older than 2025-12-15 (the local `~/.claude/projects` starts 2025-12-15); Google Drive holds a Dec-2025 snapshot of ~50 Claude project folders and 2025 Codex sessions.
- The backup writer is currently failing (quota full, disk-pressure skip). If it fails further the cloud will not have newer data, but nothing already in `conversation-backups` is removed.
- Mistaken deletion: restore from Dropbox "Deleted files" within the retention window using the removed-path log.
- The 4-in-35k size-equal-but-different rate means a handful of older snapshot versions could be removed whose content differed from the surviving copy (surviving copy is the newer/current one).

## Out of scope / follow-ups
Freeing quota does not fix the writer: bead `disk_magician-e50` tracks the DISK_PRESSURE skip, the quota alert, the stale `user_scope` repo, and the unscheduled Drive writer.

## Questions for reviewers
1. Is "same path + same size under conversation-backups" sufficient evidence to delete the standalone copy, or should deletion be limited to files whose mtimes also match (~50%)?
2. Is anything in this plan unsafe or missing (ordering, per-file re-check, rollback, retention, single-copy risk)?
3. Verdict: APPROVE / APPROVE WITH CHANGES (list them) / HOLD.

## Review outcome (2026-10-03) — NOT APPROVED, nothing deleted
- /advice: Opus APPROVE WITH CHANGES (high confidence; sampled 200 entries, all passed; no live job reads or writes the standalone folders: backup-home.sh writes only to conversation-backups). Blocking: gate on content hashes not size (7 size-equal pairs already known to differ, all currently in the delete lists: codex memories/.git/refs/heads/main, memories/.git/logs/{refs/heads/main,HEAD}, skills/.system/.codex-system-skills.marker; aside skills/.bootstrap-manifest.json; 2 cursor meta.json); do not use the mtime-equal rule (loses ~half the space); rollback via web view is unrealistic at 152k files (log path+size+hash, canary a restore, confirm the retention period); ~380 kept files are larger/unique in the standalone copy (copy them or leave them). agy returned no usable verdict (output was an unrelated file list).
- /wa: ChatGPT HOLD (size+path is not identity), Perplexity HOLD (about 17 wrong deletions expected at the codex rate; surviving copy would be the only cloud copy while the writer is failing), Gemini APPROVE WITH CHANGES (batch small, watch fileproviderd, confirm lstat/rm do not hydrate files). Shared asks: canary + restore test, confirm retention, content-hash proof, smaller batches, durable manifest of survivors, fix the writer first. Note: the /wa lane ran its headless-Chrome fallback with a patched temp copy of the driver that skips the attachment upload.
- Proposed v2 scope: delete only hash-verified duplicates. Hashes already collected exist for codex (35,087 hash-identical files, 41.17 GiB), gemini, aside, cursor; none for claude or opencode (13.7 GiB), which wait for hashes. Remove the 7 known-different pairs from the list. Canary of ~50 files first, batches of 500-1000, retention period confirmed first.
