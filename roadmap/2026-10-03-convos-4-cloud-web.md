# Convos audit lane 4: cloud web verification (2026-10-03)

Method: Aside MCP REPL, signed-in browser, read-only (navigation/search only). All tabs opened were closed.

## Task A: Dropbox web - NOT OBSERVED

`https://www.dropbox.com/home` redirected to `https://www.dropbox.com/login?cont=%2Fhome`
("Please sign in or register to access this page."). The Aside browser has no signed-in Dropbox session
(the page offered "Continue as Jeffrey jleechan@gmail.com" via Google sign-in). Signing in is outside the
read-only navigation/search/open scope of this lane, so I did not click it.

NOT OBSERVED for Dropbox: existence/counts/modified/sizes of aside_conversations, claude_conversations,
codex_conversations (incl. sessions/2026 months), conversation-backups, cursor_conversations,
gemini_conversations, hermes_conversations, opencode_conversations, memory, config, shell,
claude_backup_jeffpc_linux; account storage/plan/quota; sync-error banner.
To finish: user signs in to Dropbox in Aside (or authorizes the Google "Continue as" click), then rerun.

## Task B: Google Drive web (signed in as jleechan@gmail.com)

Storage (sidebar link text): "Storage Summary: 882.93 GB of 30.05 TB used".

### 'AI convos'
No folder named 'AI convos' found. Search "cli convos" finds folder `cli convos` (Dec 26, 2025, owner me, My Drive).
Related but different: folders "AI discussions", "AI coding" (Oct 1), "backup-test-dryrun" (Aug 1) exist in My Drive root.

### 'cli convos' children (folder id 1MUTwr5K...)
Exactly two children, both owner me, modified Dec 26, 2025:
- `codex_conversations`
- `claude_conversations`

### codex_conversations
Children: `2025/` and `.DS_Store`. No `sessions/` level and no `2026` folder.
`2025/` contains month folders `08, 09, 10, 11, 12` (+ .DS_Store). `2025/12` contains 18 day folders:
01, 02, 04, 06, 07, 10, 11, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 26.
Newest in Drive: 2025-12-26 (matches folder modified date). Nothing from 2026.

### claude_conversations
50 child folders named like `-Users-jleechan-projects-...`, `-private-tmp-...`, `-Users-jleechan-tmp-pr-automation-...`
(Claude project-directory layout, no year/month split). Every folder's Date-modified reads Dec 26, 2025.
Contents of the individual project folders were not opened, so the newest file inside is NOT OBSERVED;
the list-level evidence puts the newest at Dec 26, 2025. The list is virtualized, so 50 is what was rendered (may be a lower bound).

### rollout-2026-*
Search "rollout-2026" returned 8 results, none named rollout-2026-*.jsonl (unrelated docs: deck.pdf, Sparkle, etc., fuzzy content matches).
Earlier Dec-2025 rollout-2025-* files confirmed to exist (search "cli convos" listed rollout-2025-10-06, 11-10, 11-11, 11-20, 11-28 x2 jsonl).
Confirms: no 2026 codex rollouts in Drive.

### Other sources by name search (My Drive + shared)
- cursor_conversations: 0 results
- gemini_conversations: 0 results
- hermes_conversations: 0 results
- opencode_conversations: 0 results
- aside_conversations: 0 results
- claude_backup_jeffpc_linux: 0 results
- conversation-backups: 20 results but all fuzzy matches on doc content (AI coding, Openclaw workshop notes, whatsapp_chat, ...), no folder with that name seen
- openclaw: 40 results, all meeting-notes/workshop docs (e.g. "Openclaw workshop March 29th notes"), not conversation backups

### Computers / Shared / Trash
- Computers: "My Computer" (child: test), "My MacBook Pro" (Documents, Pictures), "My MacBook Pro - M4" (Messages), "USB and External Devices" (iPhone). No conversation backups.
- Shared with me: only meeting docs/slides etc.; no conversation-backup folders in first ~25 rows seen.
- Trash: one item, Gemini_Lifetime_Transaction_History_2026-10-03.xlsx.

## Gaps
- Dropbox entirely unverified (login wall).
- Drive holds convos only through 2025-12-26 for codex and claude; zero cursor/gemini/hermes/opencode/aside/openclaw conversation folders.
