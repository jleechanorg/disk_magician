# Convos audit lane 6/6: local duplicates of AI-conversation data (2026-10-03)

Read-only. Method: bounded python `os.scandir`/`lstat` walks (120 s/tree cap, none hit it; `claude_state` took 90 s), no `du`/`find`. Dataless placeholders (st_blocks==0, st_size>0) were skipped, never opened. The index covers files >=64 KiB (plus a full-size pass over the four session stores). Sizes are allocated GiB. Host load was 56-99 during the run. Scratch index: `/tmp/lane6/*.json`.

## Headline

- Conversation transcripts are NOT duplicated locally. Across `~/.codex/sessions` (39,778 jsonl, 61.35 GiB), `sessions_archive` (2,190, 1.85 GiB), `archived_sessions` (11) and `~/.claude/projects` (6,941 jsonl, 5.79 GiB) there is no basename+size match between any two stores. Only two basenames repeat: `journal.jsonl` (87 workflow dirs, different contents) and one `agent-*.jsonl` (0.001 GiB). No Codex session uuid appears in more than one tree.
- Hash-confirmed duplicates are repo-file copies, not transcripts: 1.435 GiB (details below).
- Each store is the single local copy. Each lane that backs these up is protecting the only copy.
- `~/.gemini/antigravity/{brain,conversations}` are symlinks to `/var/folders/.../T/ao-wa-orchestrator/antigravity/...`. Both targets do not exist (dangling), so that path currently holds nothing. The real store is `~/.gemini/antigravity-cli` (6.72 GiB).

## Table

| Location | What it duplicates | GiB | Safe to remove? |
|---|---|---|---|
| `~/.codex/sessions` (39,776 files) | Nothing. Sole copy of Codex sessions. | 61.44 | never-delete: report only |
| `~/.codex/sessions_archive`, `archived_sessions` | Nothing. Disjoint from `sessions` (0 shared uuids/basenames). | 1.85 / ~0 | never-delete: report only (`sessions*`) |
| `~/.codex/state*.sqlite`, `~/.codex/log` | Not duplicated; not walked. | n/a | never-delete: report only |
| `~/.claude/projects` (1,806 project dirs) | Nothing. Sole copy of Claude transcripts. | 6.62 | never-delete: report only |
| `~/.claude/projects` stale-cwd dirs: 1,718 of 1,806 decode to a cwd that no longer exists | Not duplicates. Transcripts of deleted worktrees/tmp dirs, still the only copy. | 6.48 | never-delete: report only |
| Worktree-named subset (`worktree`/`-wt-`/`.worktrees`): 208 dirs, 162 with dead cwd | Not duplicates. | 4.80 dead of 4.84 | never-delete: report only |
| `~/.claude/projects--Users-jleechan-project_agento-...`, `projects-...cursor-worktrees...` | 4 files / 0 files; negligible. | ~0 | not on list, but trivial; not verified |
| `~/.gemini/antigravity-cli` (brain 3.94, conversations 2.69) | `conversations/*.pb` is canonical. `brain/*/.system_generated/worktrees` holds repo checkouts. | 6.72 | not verified; route via repo scripts + `scripts/safety_check.sh` |
| Hash-confirmed dup: `claude/state/*` clones vs `gemini/antigravity-cli/brain/*/.system_generated/worktrees/*` | Same git-tracked data files (`.beads/issues.jsonl`, `failure-census.jsonl`, `llm_request_responses*.jsonl`), 32 groups | 1.312 extra | Plausibly, but I did only head+tail 64 KiB hash, not full-file, and did not run `safety_check.sh`. Not a recommendation. |
| `~/.claude/scratch_pr9431` (`evidence_*` vs `stale_checkpoints_*`) | Same Gemini HTTP evidence jsonl copied between iteration dirs | 0.092 extra of 0.64 | Not verified for deletion |
| `~/.claude/state` per-task clones (480,331 files) | Not conversations. Repo clones for PR review. | 18.93 | Out of lane; sweeper exists (`cleanup_agent_artifacts.sh`) |
| `~/.gemini/antigravity-cli` internal dups (184 groups) | Repo files in subagent worktrees | 0.553 (hash-confirmed ~0.12 in sampled 200 groups) | Not verified |
| `~/.hermes_prod`, `~/.openclaw.bak` | Both are symlinks (23 B) to `/Users/jleechan/.hermes`. No second copy. | 0 | Symlinks only; leave |
| `~/.openclaw_bak`, `_prod`, `_prod_bak`, `-consensus`, `.openclaw.bak.2026-06-25`, `.hermes_prod.retired-20260628-023550` (real dirs) | Old OpenClaw/Hermes homes. Only 231 KB of hash-confirmed overlap (`hermes_oclbackups` vs `hermes_prod_retired`). Largest: `_prod_bak` 0.74, `_prod` 0.43, `_bak` 0.22, `-consensus` 0.19 (logs), `.0625` 0.10, retired 0.14. Agent session data under `agents/` (0.41+0.36) is unique to each. | ~1.8 total | Not verified; `.openclaw.bak.2026-06-25` contains 53 dataless placeholders (unread) |
| `~/.hermes/.hermes-backups`, `.openclaw-backups`, `checkpoints/store` | Backups/checkpoints | 0.01 / 0.03 / 0.44 | Not verified |
| `~/.claude/backups` | Skills/commands snapshots (14,337 files in one), not conversations | 0.68 | Not verified; out of lane |
| `~/.cursor/chats`, `~/.cursor/projects` | Cursor local chat/project data; unique | 0.17 / 0.16 | n/a |
| `~/.aside/u` | Aside local data (one hardlink pair found, the only `nlink>1` group in the index) | 0.66 | n/a |
| `~/llm_wiki` (git, `raw/` 0.83, `wiki/` 0.27) | Derived wiki; `raw/` has 0 jsonl. | git pack 244 MiB | n/a |

## Duplicate accounting for item (d)

- Candidates (same basename+size, different inode, `.jsonl`/`.pb`, >=64 KiB, all indexed stores): 245 groups, 2.003 GiB extra by name+size.
- Hashed first+last 64 KiB for the 200 largest groups: 1.435 GiB confirmed identical. Cluster breakdown: `claude/state` x `gemini brain` 1.312, `claude/scratch_pr9431` 0.092, `claude/state` internal 0.030, hermes backups x retired 0.0002. 45 smaller groups were not hashed (<=0.57 GiB residual). Head+tail match is strong evidence, not proof of full-file equality.
- Size breakdown: 100% of the duplicated bytes are `.jsonl` repo/evidence files, not session transcripts.

## Hardlink / symlink status (item e)

- All store roots (`.codex`, `.claude`, `.gemini`, `.hermes`, `.cursor`, `.aside`) are real dirs on dev 16777234 (same volume); none is a symlink into `~/Library/CloudStorage/{Dropbox,GoogleDrive-jleechan@gmail.com}`. No symlink target inside any walked tree contains Dropbox/CloudStorage/Google Drive.
- Hardlinks among indexed files: 1 inode group (`aside_u`). Nothing in codex/claude/gemini session stores is hardlinked, so there is no dedup-by-link already in place (and none to break).
- Symlinks inside walked trees are skill/venv/`latest` pointers; `.gemini/antigravity/{brain,conversations}` dangle into `$TMPDIR` (see headline).
- The `.codex` subdirs `.tmp` (0.139 GiB), `worktrees` (0.343 GiB, 33 jsonl) and `.hermes/sessions` (4 files) were sized only; not checked for duplicates of `sessions`.

## Git-based archives (item f)

| Repo | `count-objects -vH` | Remote / state |
|---|---|---|
| `~/llm_wiki` | loose 4,360 / 520 MiB; pack 244 MiB | origin `github.com/jleechanorg/llm-wiki`; `main`, behind 1, 0 unpushed |
| `~/roadmap` | loose 4,183 / 59 MiB; pack 200 MiB | origin `jleechanorg/roadmap`; main in sync |
| `~/projects/worldarchitect-memory-backups` | pack 828 KiB | origin `jleechanorg/worldarchitect-memory-backups`; on a `chore/br-smoke-...` branch, tracking upstream |
| `~/.disk_magician_backup` | pack 51 MiB | origin `jleechanorg/disk_backup` (snapshots, not conversations) |

No repo named conversation-backups, claude-code-history, or similar exists under `~`, `~/projects`, `~/projects_other`, or `~/roadmap` (name search of top-level dirs only). So there is no git-based archive of raw Codex/Claude transcripts, which fits the finding that the session stores are sole copies.

## Web / app histories (item g)

Local app caches that exist (file counts/size from bounded walks; contents not read): `~/Library/Application Support/Claude` (0.079 GiB, Claude desktop), `.../Google/Chrome/Default/IndexedDB` (0.275 GiB), `.../Aside` (3.198 GiB), `.../Cursor` (2.134 GiB), `.../Antigravity` (0.304 GiB), `.../Codex` (0.175 GiB), `~/.aside` (0.66 GiB), `~/.cursor/chats`.
Absent: ChatGPT desktop (`com.openai.chat`, `ChatGPT`), Perplexity, Gemini app dirs.
Cloud state of claude.ai, ChatGPT and Gemini web histories and of Aside conversations: NOT OBSERVED (not inventoriable from disk).

## Caveats

- Stale-cwd decoding of `~/.claude/projects` names is a greedy path heuristic (`-` is ambiguous with `/`, `.`, `_`); the 1,718 count is an estimate, though the sampled "dead" names matched deleted tmp/worktree paths.
- Age buckets of the 208 worktree-named dirs: <7 d 28 dirs 3.72 GiB; 7-30 d 71 dirs 1.12 GiB; 30-90 d 71 dirs ~0; >90 d 38 dirs ~0 (all counts; the dead subset is 27 / 53 / 44 / 38).
- Small files (<64 KiB) outside the four session stores were not in the dup index.
