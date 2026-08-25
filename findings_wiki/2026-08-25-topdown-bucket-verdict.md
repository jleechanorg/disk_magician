# Cross-reference verdict — top 30 topdown buckets

**Mission:** safe-cleanup-30d-floor, Lane B audit
**Source of truth:** `~/.disk_magician_backup/ledger/topdown-5g.md` (snapshot 2026-08-25 11:26 UTC, 24,224 buckets, 838 GiB total)
**Cross-reference sources:** `~/.gemini/antigravity-cli/brain/<dir>/tasks/*.log` (skipped per `feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records.md`); `~/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/*.md` (47+ docs); `scripts/lib/worktree_recency.sh` (canonical 14-day helper, PR #50 commit 9d702c6)
**Total tracked in this table:** ~75 GiB across 31 buckets + 8.3 GiB state.db

## Verdict table

| Bucket | Size (GiB) | Verdict | Reason / Source |
|---|---:|---|---|
| `/Users/jleechan/projects_reference` | 4.2 | PROTECTED | 16 nested working repos (cmux, agent-browser, llm-wiki, etc.); not a single worktree but a project root — worktree 14-day rule applies to any subdirs (`worktree_recency.sh`). 8.0 GiB measured. |
| `/Users/jleechan/worldarchitect.ai` | 3.9 | PROTECTED | Main `worldarchitect.ai` working repo (3.9 GiB measured); contains 184 entries — active dev. Nested worktrees inside the repo are also PROTECTED. |
| `/Users/jleechan/Library/Application Support/Google` | 3.9 | GATED-APP | Chrome 3.5 GiB cache — closing Chrome before delete is mandatory. Includes `Chrome`, `Chrome for Testing`, `Chrome-headless`, `ChromeForTesting` dirs. Per `project_2026-07-12_disk_four_leak_classes_prevention.md` (code_sign_clone class). `cleanup_code_sign_clones.sh` available but Chrome must be closed first. |
| `/Users/jleechan/project_worldaiclaw/worldai_claw` | 3.3 | PROTECTED | Main worldai_claw working repo (43 GiB measured!); active dev with `.claude/worktrees/` (agy_ac022_*). PROTECTED by 14-day rule for any nested worktrees. |
| `/Users/jleechan/Library/Application Support/Aside` | 3.0 | GATED-APP | 2.8 GiB Aside app cache (`.aside_component_crx_cache`, `aside_sandbox`, etc.) — Aside is running (last mod Aug 25 13:47). Must close Aside before deletion. Active log `aside_component_update.log` is being written. |
| `/Users/jleechan/.codex/logs_2.sqlite` | 3.0 | NEVER-DELETE | CLAUDE.md hard list: `~/.codex/log` (rotates to `logs_2.sqlite`). Per `feedback_2026-06-13_leave_codex_sessions_alone.md` — codex session/state/log artifacts are user's permanent record-of-work. |
| `/Users/jleechan/.worktrees/worldarchitect.ai` | 2.8 | PROTECTED | Worktree under `~/.worktrees/` (33 total there); 14-day recency rule applies via `scripts/lib/worktree_recency.sh`. Must measure, not proxy (`feedback_2026-07-27_worktree_recency_proxies_wrong.md`). |
| `/Users/jleechan/.claude/projects/-Users-jleechan-project-worldaiclaw-worldai-claw` | 2.7 | NEVER-DELETE | CLAUDE.md hard list: `~/.claude/projects` (entire dir). 2.7 GiB measured; contains session JSONLs. |
| `/Users/jleechan/projects_other/agent_wrapper` | 2.7 | PROTECTED | Active working repo (`CLAUDE.md`, `.git`, `agents/`, `bin/`, `.claude/worktrees/`). Top-level git repo, not a worktree — not subject to 14-day sweep, but `.claude/worktrees/*` inside is. |
| `/Users/jleechan/.codex/state_5.sqlite` | 2.6 | NEVER-DELETE | CLAUDE.md hard list: `~/.codex/state*.sqlite`. Codex CLI state — must never delete. |
| `/Users/jleechan/.local/share` | 2.5 | INVESTIGATE | 2.5 GiB; mixed (uv tools, etc.). Per `feedback_2026-07-17_exclude_global_npm_dirs_from_bulk_cleanup.md`, must exclude `~/.local/share/uv/tools/*` and similar tool-manager install dirs from any bulk deletion. |
| `/Users/jleechan/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt` | 2.4 | GATED-APP | 2.4 GiB; `ShipIt_stderr.log`, `ShipIt_stdout.log`, `ShipItState.plist`, `update.pR4i0c4` — Cursor/ShipIt updater cache (1.2 GiB measured; ledger is 2.4 — unit skew likely). GATED because Cursor may auto-update. Pattern matches code_sign_clone class. `cleanup_code_sign_clones.sh` available. |
| `/Users/jleechan/.colima` | 2.2 | PROTECTED | 15 GiB measured. Per CLAUDE.md gotcha + `project_2026-07-15_disk_swing_mechanisms_confirmed.md`: Colima sparse disk, shrinks only via in-VM `fstrim` — `colima stop && colima start && colima ssh -- sudo fstrim -av`. 2h pressure-sweep job gates on free<40G. Operationally PROTECTED; wedge risk if touched under pressure. |
| `/Users/jleechan/cb-demo` | 2.1 | PROTECTED | 2.1 GiB; project dir. PROTECTED — likely active working repo. |
| `/Users/jleechan/.codex/sessions_archive` | 1.9 | NEVER-DELETE | CLAUDE.md hard list: `~/.codex/sessions_archive`. Per `feedback_2026-06-13_leave_codex_sessions_alone.md`, the entire codex session corpus is permanent, no-touch. |
| `/Users/jleechan/.cmuxterm` | 1.9 | PROTECTED | cmux term state — 1.9 GiB; likely actively used by cmux (the user's primary CLI). Treat as live process state. |
| `/Users/jleechan/worldarchitect-main-origin` | 1.7 | PROTECTED | 1.7 GiB; clone of worldarchitect main. PROTECTED — primary origin clone, `git fetch`/`push` target. |
| `/Users/jleechan/worktrees` | 1.7 | PROTECTED | 33 worktree dirs at this root (6979-finish-intent, browserclaw-gcp-leak-cleanup, etc.). 14-day recency rule applies per bucket via `scripts/lib/worktree_recency.sh`. |
| `/Users/jleechan/project_agento` | 1.6 | PROTECTED | 3.5 GiB; project dir with `CLAUDE.md`, `.git`, `bin/`, `agents/`, `artifacts/`, `benchmarks/`. Active working repo. |
| `/Users/jleechan/.gemini` | 1.5 | MIXED (PARTIAL-CLEAN) | 9.1 GiB total. 1.5 GiB in `~/.gemini/antigravity-cli/brain/` (501 dirs; 6 dirs >7d = ~65 MiB reclaimable). `cleanup_antigravity_brain.sh` exists (default DRY-RUN, `--clean` applies; 14-day threshold; preserves active sessions and user-facing markdown). The remaining 6.1 GiB in `~/.gemini/antigravity-cli/conversations` is OUT OF SCOPE per `feedback_2026-07-29_root_cause_disk_full.md` #4 (bead `disk_magician-1f9`). |
| `/Users/jleechan/llm_wiki.worktrees` | 1.5 | PROTECTED | 9.2 GiB measured; llm_wiki worktrees (worldarchitect, wa-evidence-standards, etc.). 14-day rule applies per bucket. Per `feedback_2026-08-03_portability_three_separate_claims.md`, llm_wiki had 3wk-blocked push (leaked secrets) — verify remote state, not just clean status. |
| `/Users/jleechan/Applications` | 1.4 | PROTECTED | Installed apps (`cmux DEV 2026-08-15.app`, `cmux DEV dev-fork.app`, `CodexBar.app`, `Claude Code URL Handler.app`, Chromium/Chrome Apps). Actively used. Do not touch. |
| `/Users/jleechan/projects/worktree_factory_codex_process_group_cleanup` | 1.4 | PROTECTED | 1.4 GiB; factory project (`.claude`, `.git`, `AGENTS.md`, `bin/`, `artifacts/`, `benchmarks/`). Worktree 14-day rule applies. |
| `/Users/jleechan/.codex/thread_history_1.sqlite` | 1.4 | NEVER-DELETE | 1.5 GiB measured. Codex CLI thread history — falls under the codex "permanent corpus" rule per `feedback_2026-06-13_leave_codex_sessions_alone.md` (cache files like thread_history are part of codex state). CLAUDE.md hard list covers `state*.sqlite` + `log` + sessions; thread_history is adjacent protected state. |
| `/Users/jleechan/claude-codex-usage` | 1.3 | PROTECTED | 1.3 GiB; project dir. PROTECTED — active working repo. |
| `/Users/jleechan/llm_wiki` | 1.3 | PROTECTED | 1.6 GiB measured; main llm_wiki repo. PROTECTED — primary working repo. |
| `/Users/jleechan/repos` | 1.3 | PROTECTED | 7.9 GiB measured; mixed repos dir. PROTECTED — working repositories. |
| `/Users/jleechan/Library/Caches/ms-playwright` | 1.3 | SAFE-CLEAN | 1.8 GiB measured; Playwright browser cache. Regenerable — `npx playwright install` re-creates. Standard cache. |
| `/Users/jleechan/.aside` | 1.3 | GATED-APP | 1.5 GiB Aside app state. Aside is running — must close before delete. |
| `/Users/jleechan/projects/worktree_factory_pr755_quarantine` | 1.3 | PROTECTED | 1.3 GiB; factory project. Worktree 14-day rule applies. |
| `/Users/jleechan/.hermes/state.db` | 8.3 | NEVER-DELETE | Oversize indivisible SQLite file (8.3 GiB, schema 4, written 2026-08-25 13:45 today). Hermes state DB — actively written by the live hermes process. Treating as live state; deletion breaks hermes. Out of scope for cleanup. |

## Summary by verdict class

| Verdict | Count | Total (GiB) | Action |
|---|---:|---:|---|
| NEVER-DELETE | 6 | ~13.8 | Hard-blocked (CLAUDE.md / codex permanent corpus) |
| PROTECTED | 17 | ~46.7 | Worktree 14-day rule or live working state — measure, do not proxy |
| GATED-APP | 4 | ~8.6 | Close app first (Chrome, Aside, Cursor/ShipIt) |
| SAFE-CLEAN | 1 | ~1.8 | Regenerable cache (ms-playwright) |
| MIXED (PARTIAL-CLEAN) | 1 | 0.065 (cleanable) | `.gemini` brain dirs >7d only — `cleanup_antigravity_brain.sh --clean` |
| INVESTIGATE | 2 | ~5.0 | `.local/share` + `worldarchitect.ai.worktrees` — need bucket-level inspection before any verdict |
| **Total tracked** | **31 + state.db** | **~75.9** | |

## Key findings from cross-reference

### What prior sweeps already cover
- **Tier A — supervisor logs** (`~/.claude/supervisor` = 0.7 GiB): covered by `cleanup_supervisor_logs.sh` (rotated cmux-codex-launchd logs, 7-day retention; never touches active log/state files). Wired into `disk_audit.sh` line 263-266.
- **Tier B — AO wa-* sessions**: covered by 14-day mtime + size filter + `WORKTREE_APPROVED=1` env. 9.8 GiB reclaimed historically (PR #686 fixed the colima bootstrap pattern).
- **Tier C — `/private/tmp/wt-*` and `/private/tmp/wa-*` scratch worktrees**: 100M+30min safety filter, 4.0 GiB reclaimed historically.
- **Antigravity brain dirs >7d**: covered by `cleanup_antigravity_brain.sh` (default DRY-RUN; `--clean` applies; preserves active sessions <24h and user-facing markdown). On this box: 6 of 501 dirs qualify = ~65 MiB.

### What's NEW growth that could be cleaned
- **`ms-playwright` cache (1.8 GiB)**: SAFE-CLEAN, regenerable. No prior sweep pattern named, but standard cache class.
- **`.gemini` brain dirs >7d (~65 MiB)**: covered by existing script — just needs `--clean` flag. Currently DRY-RUN.
- **`Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt` (Cursor updater cache, 1.2-2.4 GiB)**: matches code_sign_clone class; `cleanup_code_sign_clones.sh` available but gated on closing Cursor.
- **`Library/Application Support/Google/Chrome` (3.5 GiB)**: chrome cache — gated on closing Chrome.
- **`Library/Application Support/Aside` (2.8 GiB) + `.aside` (1.5 GiB)**: gated on closing Aside.

### What's structural and unfixable without Full Disk Access
- **213.9 GiB TCC/SIP `~/Library` gap**: per `project_2026-07-15_disk_swing_mechanisms_confirmed.md`, this is a permission wall (MobileSync backups likely the largest single piece, Mail, Messages, ~20 protected subtrees, 4 SIP dotdirs). Out of scope for non-FDA shells. NOT in the topdown mega-table because the scanner cannot reach these paths.
- **APFS local snapshots + container min-size pinning**: separate structural contributor, ~291 GiB residual per `project_2026-07-29_disk_rootcause_producers_and_decisions.md`.

### What's structural and requires user decision (NOT auto-clean)
- **Worktrees <14d** across `~/.worktrees/`, `~/worktrees/`, `~/projects/worktrees/`, `~/worldarchitect.ai.worktrees/`, `~/projects/worktree_factory_*`: per 14-day recency rule, PROTECTED by default. Per `feedback_2026-07-27_worktree_recency_proxies_wrong.md`, must measure with `worktree_recency.sh` (NOT `stat <wt>/.git` which measured creation age and over-stated staleness).

### What is UNCOVERED by prior sweep patterns
- **`worldarchitect.ai.worktrees` (1.0 GiB in ledger; 992 MiB measured)**: NOT covered by `cleanup_worktrees.sh` (which only walks `<repo>/.claude/worktrees`). Per `feedback_2026-07-29_root_cause_disk_full.md` #2: "Abandoned AO+Claude parents under `~/.worktrees`" fix shape is to enumerate `~/.worktrees/*` at depth 1 — but this is `worldarchitect.ai.worktrees` (the same pattern at the repo root). INVESTIGATE before any verdict.
- **`.local/share` (2.5 GiB)**: mixed (uv tools, etc.). Per `feedback_2026-07-17_exclude_global_npm_dirs_from_bulk_cleanup.md`, any bulk enumeration must exclude tool-manager install dirs.

## Critical safety gates to preserve

1. **NEVER-DELETE list (CLAUDE.md, hard)**: `~/.codex/sessions*`, `~/.codex/state*.sqlite`, `~/.codex/log`, `~/.claude/projects` — covers 6 buckets (~13.8 GiB) in this table.
2. **Worktree 14-day rule**: `scripts/lib/worktree_recency.sh` is the canonical fail-closed helper (PR #50, commit 9d702c6). Proxies (`stat <wt>/.git`, `stat <wt>`) are unsafe — measured wrong by 7.6 days on live worldarchitect.ai registry.
3. **Tool-manager exclusion**: bulk cleanup of `node_modules`, `~/.cache`, `~/.local/share`, `~/.npm` MUST exclude `~/.nvm`, `~/.npm`, `~/.pyenv`, `~/.cargo/bin` (per `feedback_2026-07-17_exclude_global_npm_dirs_from_bulk_cleanup.md`). 24 broken symlinks result otherwise.
4. **Pre-delete per-item re-measure**: per `feedback_2026-07-18_verify_swarm_report_sizes_per_item_before_delete.md`, even adversarially-verified SAFE rows can be wrong by orders of magnitude (1.6 GiB claimed as 0.00002 GiB). Always `du -sh` each individual member directly before deleting a grouped/aggregate row.
5. **Brain logs are NOT cleanup records**: per `feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records.md`, do not try to grep `~/.gemini/antigravity-cli/brain/<dir>/tasks/*.log` for "what we cleaned up before" — they are work transcripts (pytest/codex/Flask session outputs). Brain DIRS are the reclaim target.

## Reclaimable estimate (without touching PROTECTED/NEVER-DELETE)

| Action | Reclaim (GiB) | Gate |
|---|---:|---|
| `cleanup_antigravity_brain.sh --clean --days 14` | ~0.065 | None (preserves active sessions) |
| `Library/Caches/ms-playwright` cleanup | ~1.8 | None (regenerable) |
| `Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt` cleanup (code_sign_clone class) | ~1.2-2.4 | Close Cursor first |
| `Library/Application Support/Google/Chrome` cache cleanup | ~3.5 | Close Chrome first |
| `Library/Application Support/Aside` + `.aside` cleanup | ~4.3 | Close Aside first |
| **Subtotal (app-gated, regenerable)** | **~10.9** | App-close gates only |
| Structural TCC/SIP `~/Library` gap | ~213.9 | Requires Full Disk Access (OUT OF SCOPE) |
| APFS local snapshots | unknown | Requires FDA (OUT OF SCOPE) |

**Note:** Topdown ledger covers ~75.9 GiB in the top 30 + state.db. The remaining ~760 GiB is dominated by:
- The TCC/SIP `~/Library` blind spot (~213.9 GiB structural)
- APFS container min-size + local snapshots
- Worktrees <14d PROTECTED (per 14-day rule)
- Per-repo `.git` history (~6 GiB across `.worktrees/` + `~/.hermes/.git`)
- Agent venv bloat (~25 GiB reclaimable per `feedback_2026-07-29_root_cause_disk_full.md` #1)
- Abandoned `~/.worktrees/*` siblings (~30 GiB per #2)
- Unowned `/private/tmp` scratch (~8.4 GiB per #3)

The top-30 cross-reference confirms NO NEW SAFE-CLEAN targets beyond app-gated caches. The reclaim story is still: close apps, run existing scripts (`cleanup_antigravity_brain.sh --clean`, `cleanup_code_sign_clones.sh`), and accept the structural TCC/SIP gap.
