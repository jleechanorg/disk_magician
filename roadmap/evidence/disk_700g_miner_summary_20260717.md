### homedir-baseline
# Raw Output — `du -sk /Users/jleechan/* 2>/dev/null | sort -rn`

**Methodology note (read before trusting any single run of this command):** The literal command as given silently truncates in this environment. `du` takes >15s each on `~/Library` (88.6 GiB) and `~/projects` (119.8 GiB); when piped directly into `sort` and the outer process is interrupted/timed-out before `du` finishes walking the full argv list, `sort` still emits a clean, correctly-ordered-looking table — just an **incomplete** one (my first raw run returned only 41 lines, all alphabetically early — dropping every large directory including `~/projects` and `~/Library` entirely, with no error surfaced). I isolated this with a per-entry `timeout 15 du -sk "$d"` loop, found the two slow directories, measured them individually with `timeout 300`, and merged the results. Filed as bead `jleechan-ngj7` (fix: du sweeps over `$HOME/*` must loop per-entry with a timeout, not one piped invocation). Also found and filed `jleechan-7nc1`: a stray literal directory named `${MARKER_DIR}` in `$HOME` (leftover from some script that failed to expand a bash variable — harmless, near-zero size, not touched).

The table below is the **corrected, complete** raw output (329 entries, KB, descending) — reproducing exactly what the given command's output should be with `du -sk` on every non-hidden top-level entry of `/Users/jleechan`:

```
125577840	/Users/jleechan/projects
92905560	/Users/jleechan/Library
18381072	/Users/jleechan/projects_other
14528768	/Users/jleechan/Pictures
14076736	/Users/jleechan/project_worldaiclaw
11727844	/Users/jleechan/projects_reference
6629744	/Users/jleechan/repos
5125748	/Users/jleechan/agent-f
4280736	/Users/jleechan/evidence
4221520	/Users/jleechan/project_agento
3565484	/Users/jleechan/jleechanclaw
3429636	/Users/jleechan/project_ai_universe
2577484	/Users/jleechan/Downloads
2506140	/Users/jleechan/worldarchitect.ai
2197260	/Users/jleechan/cb-demo
1820352	/Users/jleechan/project_jleechanclaw
1759068	/Users/jleechan/worktrees
1755528	/Users/jleechan/worldarchitect-main-origin
1744296	/Users/jleechan/llm_wiki
1627232	/Users/jleechan/Apps
1559900	/Users/jleechan/conductor
1490448	/Users/jleechan/claude-codex-usage
1349576	/Users/jleechan/Documents
1308104	/Users/jleechan/thinclaw
1142220	/Users/jleechan/jleechanorg
990044	/Users/jleechan/cmux-backups
956808	/Users/jleechan/project_ai_universe_frontend
812632	/Users/jleechan/autoresearch-main-workspace
769784	/Users/jleechan/setup-pnpm
745072	/Users/jleechan/work
688836	/Users/jleechan/llm_wiki.worktrees
649136	/Users/jleechan/tmp
571564	/Users/jleechan/worldarchitect-ai-autor
541220	/Users/jleechan/worldarchitect.ai.worktrees
512896	/Users/jleechan/openclaw-repo
481608	/Users/jleechan/ez-gh-actions-workdir
461752	/Users/jleechan/node_modules
440376	/Users/jleechan/jleechan_bench_workspace
437032	/Users/jleechan/worldarchitect-ai-autor.git
424736	/Users/jleechan/llm-wiki-autor-phase3
394152	/Users/jleechan/mcp_mail
391624	/Users/jleechan/hermes-agent-fork-backup-2026-06-28
375236	/Users/jleechan/swebench_lite
364648	/Users/jleechan/worldarchitect.ai_rate_25
344776	/Users/jleechan/benchmark-runs
337344	/Users/jleechan/worldarchitect-prm6259
313580	/Users/jleechan/project_ai_universe_convo
312476	/Users/jleechan/claude-commands
305344	/Users/jleechan/pr-worktrees
294104	/Users/jleechan/django.git
279376	/Users/jleechan/wa_tos_training
274024	/Users/jleechan/wa-bq-openai-stream-response-text
273412	/Users/jleechan/mcp_mail_recovery
271580	/Users/jleechan/worldarchitect.ai-wa-pr-7638
271380	/Users/jleechan/wa-7493-prompt
271052	/Users/jleechan/wa-dev-min-instances
270736	/Users/jleechan/wa-pr-7558
270436	/Users/jleechan/worldarchitect.ai-wa-cost-report-fix
265508	/Users/jleechan/worldarchitect.ai-wt-pr5850-nlargs
264324	/Users/jleechan/clawd
255296	/Users/jleechan/ai_universe_living_blog
253340	/Users/jleechan/worldarchitect.ai-story-mode
249304	/Users/jleechan/django_temp
242624	/Users/jleechan/worldarchitect.ai-pairv3
239480	/Users/jleechan/minimax-coding-agent
217984	/Users/jleechan/workspaces
213396	/Users/jleechan/luma-scrape
208600	/Users/jleechan/project_openclaw
166248	/Users/jleechan/beads
148072	/Users/jleechan/bin
145496	/Users/jleechan/Desktop
145020	/Users/jleechan/worldarchitect-autoresearch
144500	/Users/jleechan/Models
144428	/Users/jleechan/fix
132160	/Users/jleechan/research-wiki
128588	/Users/jleechan/worldarchitect-public-wiki-tree-pr6252
127416	/Users/jleechan/evidence_backups
127340	/Users/jleechan/llm_wiki_wt
121920	/Users/jleechan/dk2d_comparison
118780	/Users/jleechan/ref3_u-rJwPPU3QA.mp4
95316	/Users/jleechan/roadmap
87312	/Users/jleechan/worldarchitect-bugcheck
86632	/Users/jleechan/go
83508	/Users/jleechan/dk2d_mission_backup
83464	/Users/jleechan/pr495-cr-fix
81884	/Users/jleechan/project_codex
63008	/Users/jleechan/pylint-dev
54580	/Users/jleechan/code
40404	/Users/jleechan/Music
30244	/Users/jleechan/ref2_phchDt63qAA.mp4
28320	/Users/jleechan/jclaw-fix-runner-token
27580	/Users/jleechan/project_jleechanorg
27424	/Users/jleechan/openclaw-thin-mcp
25404	/Users/jleechan/worldarchitect.ai-wt-prompt-rag
22896	/Users/jleechan/Movies
21808	/Users/jleechan/qdrant
20132	/Users/jleechan/br_migration_last15_20260309_011839
18888	/Users/jleechan/backups
18212	/Users/jleechan/merge_train
12960	/Users/jleechan/mcp_mail-pr221
10396	/Users/jleechan/jcc-19-fix
9800	/Users/jleechan/jcc-19-restore
9788	/Users/jleechan/project_smartclaw
6620	/Users/jleechan/autowiki
5408	/Users/jleechan/worldai_wiki
3992	/Users/jleechan/error.log
3940	/Users/jleechan/browserclaw
3304	/Users/jleechan/Applications
3096	/Users/jleechan/roadmap-hermes-phase8
2992	/Users/jleechan/logs
2812	/Users/jleechan/dk2d_evidence
2780	/Users/jleechan/aiewf-cache
2200	/Users/jleechan/issues_jsonl_original_backup_20260309_003340
1404	/Users/jleechan/rtk
1400	/Users/jleechan/llm-rpg
984	/Users/jleechan/ref2_phchDt63qAA.info.json
980	/Users/jleechan/ref1_hqHC6Z_lXyo.info.json
904	/Users/jleechan/ref3_u-rJwPPU3QA.info.json
716	/Users/jleechan/bp-telemetry-core-clone
684	/Users/jleechan/worldarchitect-public-wiki
636	/Users/jleechan/jleechan_fun
568	/Users/jleechan/comments.json
456	/Users/jleechan/memory
436	/Users/jleechan/voyage-campaign-summary.md
436	/Users/jleechan/voyage-campaign-gist.md
436	/Users/jleechan/bp-telemetry-core
356	/Users/jleechan/pr_status.json
356	/Users/jleechan/pr_feedback.json
332	/Users/jleechan/projects_fake_repo
[... remaining ~180 lines are single files/dirs under ~316 KB each, down to 0 — omitted here as immaterial to the top-25 GiB question; full 329-line list was captured in /tmp/home_du_final.txt during this session]
```

# Top 25 by size (GiB)

| Rank | GiB | Path | Risk flag |
|---|---|---|---|
| 1 | 119.76 | `~/projects` | **HIGH-RISK — active project tree, do not delete** |
| 2 | 88.60 | `~/Library` | system/app data (Messages, App Support) — do not delete |
| 3 | 17.53 | `~/projects_other` | **HIGH-RISK — active project tree (contains this repo)** |
| 4 | 13.86 | `~/Pictures` | **HIGH-RISK — user photos, never delete** |
| 5 | 13.42 | `~/project_worldaiclaw` | **HIGH-RISK — active project tree** |
| 6 | 11.18 | `~/projects_reference` | **HIGH-RISK — active project tree** |
| 7 | 6.32 | `~/repos` | active project data |
| 8 | 4.89 | `~/agent-f` | active project/workspace |
| 9 | 4.08 | `~/evidence` | working evidence artifacts |
| 10 | 4.03 | `~/project_agento` | active project tree |
| 11 | 3.40 | `~/jleechanclaw` | active project tree |
| 12 | 3.27 | `~/project_ai_universe` | active project tree |
| 13 | 2.46 | `~/Downloads` | user data |
| 14 | 2.39 | `~/worldarchitect.ai` | active project tree |
| 15 | 2.10 | `~/cb-demo` | active project tree |
| 16 | 1.74 | `~/project_jleechanclaw` | active project tree |
| 17 | 1.68 | `~/worktrees` | worktree state (not `~/.worktrees`) |
| 18 | 1.67 | `~/worldarchitect-main-origin` | active project tree |
| 19 | 1.66 | `~/llm_wiki` | active project/wiki |
| 20 | 1.55 | `~/Apps` | app data |
| 21 | 1.49 | `~/conductor` | active project tree |
| 22 | 1.42 | `~/claude-codex-usage` | usage-tracking data |
| 23 | 1.29 | `~/Documents` | user data |
| 24 | 1.25 | `~/thinclaw` | active project tree |
| 25 | 1.09 | `~/jleechanorg` | active project tree |

Note: `~/.codex`, `~/.claude/projects`, `~/.gemini`, `~/.hermes`, `~/.colima`, `~/.worktrees` are all **excluded from this table** because the literal glob `/Users/jleechan/*` does not match dotfiles (bash default, no `dotglob`). I measured them separately for the baseline comparison below — all are on the never-delete/HIGH-RISK list (Codex/Claude session state) and none were touched.

# Baseline comparison (one line each)

- **`~/projects` 119.76 GiB** — matches baseline (119.451 GiB), no significant change.
- **`~/Library` 88.60 GiB** — up ~3.05 GiB from baseline (85.547 GiB); consistent with ongoing Messages/App Support growth already flagged, not new.
- **`~/.colima` 44.69 GiB** (measured separately, hidden dir) — **above the known fluctuating ceiling of ~26–40 GiB**; consistent with the "Colima regrowth shlock bug" pattern from memory (CI-runner churn), worth a fresh trim-guard check.
- **`~/.codex` 28.99 GiB** — matches baseline (28.888 GiB), stable. **HIGH-RISK/never-delete (Codex session state).**
- **`~/.gemini` 23.18 GiB** — matches baseline (23.181 GiB) almost exactly, stable.
- **`~/dk2d_evidence` 2.68 MiB** — confirms baseline note (cleaned this session, was 19 GiB) — cleanup held.
- **`~/.worktrees` 17.10 GiB** — slightly below baseline (~17.8 GiB), consistent with the 13 SAFE worktrees already deleted this session; no regrowth.
- **`~/projects_other` 17.53 GiB** — up ~0.44 GiB from baseline (17.086 GiB), minor, this repo's own worktree churn. **HIGH-RISK — active project tree.**
- **`~/.hermes` 15.65 GiB** (measured separately) — up ~0.54 GiB from baseline (15.107 GiB), minor.
- **`~/Pictures` 13.86 GiB** — matches baseline (13.762 GiB), stable. **HIGH-RISK — user photos, never delete.**
- **`~/project_worldaiclaw` 13.42 GiB** — up ~0.48 GiB from baseline (12.942 GiB), minor. **HIGH-RISK — active project tree.**
- **`~/projects_reference` 11.18 GiB** — matches baseline (11.185 GiB) exactly, stable.

No files were deleted or modified; all commands run were read-only measurement (`du`, `ls`, `find`). Two beads filed for follow-up: `jleechan-7nc1` (stray `${MARKER_DIR}` artifact) and `jleechan-ngj7` (du-sweep truncation-without-error bug — should be fixed in any disk_magician sweeper script that pipes `du` over `$HOME/*` into `sort` without a per-entry timeout).

---

### worktree-needs-review
I now have complete data for all 106 entries. Let me produce the final report.

# NEEDS-REVIEW Worktree Sizing & Re-Classification (106 entries)

**Source:** `/Users/jleechan/projects_other/disk_magician/roadmap/evidence/worktree_classification_20260717.tsv`
**Method:** `du -sk` per path (real, not TSV-estimated) + fresh `git log --oneline -1 --format=%cr`/`--format=%ci` per path. All read-only — nothing deleted or modified.

## Totals

| metric | value |
|---|---:|
| Total NEEDS-REVIEW entries | 106 |
| **Total GiB across all 106** | **17.41 GiB** |
| STALE-LIKELY-SAFE entries | 10 |
| **STALE-LIKELY-SAFE GiB (subset)** | **0.27 GiB** |
| STILL-ACTIVE GiB | 17.14 GiB |
| UNKNOWN | 0 |

Key finding: this NEEDS-REVIEW population is **not** where the disk pressure lives — 106 worktrees sum to only 17.4 GiB total (they share `.git` object storage with their parent repos, so each leaf is mostly just working-tree files). The 1000+-commit-divergence flag only nets 0.27 GiB of reclaimable space. Any large-scale disk recovery must come from elsewhere (Colima sparse disk, AO scratch, etc. — see prior swarm findings), not this worktree set.

## Verdict rule applied
- `uncommitted_count > 0` (staged/unstaged/untracked changes present) → always **STILL-ACTIVE** (never marked safe, regardless of age or divergence — risk of losing real work).
- `uncommitted_count == 0` AND (`ahead ≥ 1000` OR last-commit age `> 30 days`) → **STALE-LIKELY-SAFE**.
- `uncommitted_count == 0` AND age ≤ 30 days AND ahead < 1000 → **STILL-ACTIVE**.
- 4 entries (branches with zero commits yet, `git log` errors "does not have any commits yet") have blank `last_commit_age` but nonzero uncommitted counts (74–1881 files) → correctly forced to STILL-ACTIVE by the uncommitted rule.

## STALE-LIKELY-SAFE (10 entries, 0.27 GiB total) — verified 0 uncommitted changes via direct `git status --porcelain` re-check

| path | size_gib | last_commit_age | uncommitted | ahead | verdict |
|---|---:|---|---:|---:|---|
| /Users/jleechan/.worktrees/jleechanclaw/hermes-deploy-skillify | 0.03 | 3 weeks ago | 0 | 1827 | STALE-LIKELY-SAFE |
| /Users/jleechan/.worktrees/jleechanclaw/hermes-deploy-soul-fastpath | 0.03 | 3 weeks ago | 0 | 1827 | STALE-LIKELY-SAFE |
| /Users/jleechan/.worktrees/jleechanclaw/soul-trim-48660 | 0.03 | 3 weeks ago | 0 | 1827 | STALE-LIKELY-SAFE |
| /Users/jleechan/.worktrees/jleechanclaw/agy-secondary | 0.03 | 3 weeks ago | 0 | 1788 | STALE-LIKELY-SAFE |
| /Users/jleechan/.worktrees/jleechanclaw/diag-parent-attribution | 0.03 | 4 weeks ago | 0 | 1749 | STALE-LIKELY-SAFE |
| /Users/jleechan/.worktrees/jleechanclaw/fix-watchdog-back-ass | 0.04 | 5 weeks ago | 0 | 2 | STALE-LIKELY-SAFE |
| /Users/jleechan/.worktrees/jleechanclaw/fix-pr-618 | 0.04 | 5 weeks ago | 0 | 2 | STALE-LIKELY-SAFE |
| /Users/jleechan/.worktrees/jleechanclaw/fix-pr-616 | 0.04 | 5 weeks ago | 0 | 2 | STALE-LIKELY-SAFE |
| /Users/jleechan/.worktrees/jleechanclaw/browserclaw | 0.01 | 3 months ago | 0 | 2 | STALE-LIKELY-SAFE |
| /Users/jleechan/.worktrees/jleechanclaw/jc-1795-pr537 | 0.01 | 3 months ago | 0 | 3 | STALE-LIKELY-SAFE |

The 5 entries with `ahead ≥ 1000` (1749–1827 commits) satisfy the "massively diverged" auto-flag per the task's rule (unconditional regardless of the 21-day-ish commit age, since they have 0 uncommitted changes). The remaining 5 are flagged purely on age (33–98 days since last commit, 0 uncommitted changes).

## Notable STILL-ACTIVE entries that superficially look stale (i.e., correctly NOT flagged)
- `homunculus-agy-driver` — ahead=9257 (massively diverged) but has 1 uncommitted file → STILL-ACTIVE (uncommitted work present, do not touch).
- `jc-549-fix`, `wa-daily-watcher-fix`, `runner-qdrant-keychain-durability` — all ahead 1400–1650, all have uncommitted changes (1, 8, 8 files respectively) → STILL-ACTIVE.
- `dark-factory/df-14-work` — 6 weeks old commit but only ahead=25 and 5 uncommitted files → STILL-ACTIVE (uncommitted rule wins).
- Several `fix/soul-*`, `fix/slack-*`, `jleechanclaw/*` entries at ahead=1641–1761 all carry 7–8 uncommitted files → STILL-ACTIVE despite huge divergence.
- `llm-wiki-auto-export-6` / `-1` — "uncommitted=63845" is real (untracked wiki-export file tree, not a parsing artifact) — confirmed against raw TSV.

## Full 106-row table (sorted by size_gib descending)
Written to `/tmp/final_markdown_table.md` (108 lines incl. header) — top 20 by size shown above are representative; the remaining 86 rows range from 0.29 GiB down to 0.00 GiB (`worldarchitect_ai/wa-*`, `dark-factory/audit-*`, `jleechanorg-fix/*` single-commit-ahead placeholder worktrees, etc.), all classified **STILL-ACTIVE** except the 10 listed above.

Full data files (read-only, for reference):
- Raw NEEDS-REVIEW TSV extract: `/tmp/needs_review.tsv`
- Per-path `du -sk` results: `/tmp/sizes.tsv`
- Per-path git commit-age results: `/tmp/commit_age.tsv`
- Combined structured JSON (all 106, all fields): `/tmp/final_entries.json`
- Rendered markdown table (all 106 rows): `/tmp/final_markdown_table.md`

No `git worktree remove` or `rm` was run — this is sizing/classification only, as instructed.

---

### cache-sweep
## READ-ONLY Disk Sweep Results — Regenerable Cache/Build Artifacts

Home directory: `/Users/jleechan` (excluded: `~/Library/CloudStorage/*`, `~/Pictures/*`). No files modified — sizing only.

| category | total_gib | count | regeneration_confidence |
|---|---|---|---|
| node_modules dirs | **41.31** | 882 | HIGH (`npm`/`pnpm install` rebuilds from `package.json`/lockfile) |
| Python venvs, unreferenced | **32.98** | 102 of 104 (2 excluded as active) | MEDIUM (needs `python -m venv` + `pip install -r requirements.txt` rebuild step) |
| ~/.npm | **3.5** | 1 | HIGH (npm registry cache) |
| ~/Library/Caches — other app caches | **~3.36** | 30+ subdirs | MEDIUM (mixed: HIGH for pkg-mgr caches, MEDIUM for app caches like Aside/CodexBar/lima that may need re-auth/re-index) |
| ~/.cache | **2.2** | 1 (multiple subdirs) | HIGH (codex-runtimes, uv, gh, fastembed, node caches all auto-redownload) |
| .pytest_cache dirs | **0.08** | 111 | HIGH (pytest recreates on next test run) |
| ~/.cargo/registry | **0.10** | 1 | HIGH (cargo redownloads crates) |
| ~/.gradle/caches | 0 | — | N/A (empty) |
| Xcode DerivedData | 0 | — | N/A (not present) |
| .tox dirs | 0 | — | N/A (none found) |
| ~/.docker build cache | ~0.001 | — | N/A (buildx cache is only 1.4M; nothing meaningful) |

**Sum of found regenerable space: ≈ 83.5 GiB**

### Notable exclusions (explicitly NOT counted above — not simple caches)
- `~/.colima` = **45 GiB** — this is the live Colima VM sparse disk (Docker daemon state/images), not a rebuildable cache. Per repo `CLAUDE.md`, this only shrinks via in-VM `fstrim`, never by deletion. Excluded from the sum.

### node_modules — top 20 by size (of 882 found)
```
5.2G  ~/.nvm/versions/node/v22.22.0/lib/node_modules   <- global npm CLI installs, not a project cache (MEDIUM: npm install -g per tool)
1.1G  ~/projects_reference/openclaw/node_modules
1.1G  ~/projects_reference/agent-orchestrator-mirror/node_modules
993M  ~/projects_other/vibe-kanban/node_modules
931M  ~/projects/openclaw-docs/node_modules
916M  ~/agent-f/agf-accounting/node_modules
850M  ~/project_ai_universe/ai_universe_frontend/node_modules
828M  ~/.npm/_npx/a4de8e9559618962/node_modules
775M  ~/projects_other/agent-orchestrator/node_modules
775M  ~/project_agento/agent-orchestrator-ts/node_modules
775M  ~/jleechanorg/agent-orchestrator/node_modules
775M  ~/.worktrees/agent-orchestrator-ts/repo-rename-refs/node_modules
775M  ~/.ao/data/worktrees/agent-orchestrator-ts-harness/worktree-bd-6hc9/node_modules
775M  ~/.ao/data/worktrees/agent-orchestrator-ts-harness/agent-orchestrator-ts-harness-1/node_modules
765M  ~/project_ai_universe_frontend/ai_universe_frontend/node_modules
752M  ~/setup-pnpm/node_modules
726M  ~/thinclaw/openclaw-src/node_modules
703M  ~/Apps/modly/node_modules
688M  ~/agent-f/factory/node_modules
658M  ~/projects_reference/openclaw-mission-control/frontend/node_modules
```
Note: 6 identical 775M `agent-orchestrator-ts` node_modules copies exist across worktrees/mirrors of the same repo — same regen story per copy (`npm install`), but a strong worktree-consolidation candidate.

### Python venvs — active/excluded (do NOT delete)
- `~/.local/orch-venv` (1.2G) — on `$PATH` in `~/.bashrc:1440`, backs `~/.local/bin/ai_orch` symlink
- `~/projects/worldarchitect.ai/venv` (857M) — `PROJECT_ROOT_PATH` in `~/.bashrc:750/757` (the `vpython` venv)

### Python venvs — top candidates (unreferenced, of 102)
```
1.0G  ~/projects_other/spicy_llm/heretic/.venv
788M  ~/project_agento/worktree_worldarchitect/venv
762M  ~/.local/whisper-venv                          <- not referenced by any symlink/launchd/bashrc
743M  ~/worldarchitect.ai/venv
743M  ~/.worktrees/worldarchitect/wa-3302-fix/venv
730M  ~/worldarchitect-main-origin/venv
729M  ~/worldarchitect-main-origin/venv312
723M  ~/repos/jleechanorg/worldarchitect.ai/venv
```
Plus ~15+ `venv.bak.20260703-*` / `venv.bak.20260712-*` dirs (723-724M each) under old `~/projects/worktree_pr*` and `~/projects/worldarchitect.ai/.claude/worktrees/*` — confirmed stale via mtime (5–14 days old, matching dead-worktree naming from disk_magician's own worktree-hygiene incidents). These are the single largest reclaim opportunity in this sweep.

### ~/Library/Caches — new items beyond prior pass (ms-playwright 1.03G / codexbar 0.60G / pnpm now 0B / Google 0.63G / colima 0.34G already known)
```
617M  Aside            (MEDIUM — browser profile/cache, re-login possible)
269M  pip              (HIGH  — macOS pip cache location)
255M  @granolaelectron-updater (MEDIUM)
242M  lima             (MEDIUM — VM image layer cache)
222M  SiriTTS          (MEDIUM — system TTS voice cache)
198M  CodexBar         (MEDIUM — distinct from com.steipete.codexbar 612M already known)
176M  superpowers      (MEDIUM)
144M  com.cmuxterm.app.debug.dev.fork (MEDIUM)
134M  com.apple.python (LOW/MEDIUM — system Python cache)
127M  us.zoom.xos      (MEDIUM — may need re-login)
126M  node-gyp         (HIGH)
122M  com.cmuxterm.app (MEDIUM)
109M  electron         (HIGH — electron-builder download cache)
 96M  com.mitchellh.ghostty (MEDIUM)
 90M  Homebrew         (HIGH — bottle/download cache)
 84M  io.tailscale.ipn.macsys (MEDIUM — may need re-auth)
 84M  cursor-compile-cache (HIGH)
 67M  snyk             (HIGH)
 43M  claude-cli-nodejs (HIGH)
 37M  GeoServices      (LOW)
 26M  virtualenv       (HIGH)
 26M  CloudKit         (LOW)
 17M  ms-playwright-mcp (HIGH)
  8.2M typescript      (HIGH — tsc incremental build cache)
  + ~15 tiny com.apple.* system caches (<10M each, LOW priority)
```

No .tox directories, no Xcode DerivedData, no meaningful Docker buildx cache were found. All figures above are sizing-only reads (`du -sh`); nothing was deleted or modified.

---

### large-files-sweep
## READ-ONLY Large-File Sweep — `/Users/jleechan` (>500MB, excluding Pictures/CloudStorage/Movies/.git/objects)

**Method:** `find /Users/jleechan -type f -size +500M 2>/dev/null | grep -v -E '(Pictures|CloudStorage|Movies|/\.git/)'` → 26 hits. For each: `ls -lh`/`du -h`, `lsof`, `ps aux`, and (for the colima/lima disks) `colima list` / `limactl list` to check active-mount status. No files were modified or deleted.

**Important caveat on sizes:** 5 of the hits are sparse virtual-disk images (colima/lima). Their `ls -lh` **apparent** size (what `find`/`ls` reports) wildly overstates real disk usage. The table below shows apparent size (matches the `ls -lh` you asked for) but I've also given the `du -h` **real/allocated** size for those 5, and the GiB sums at the bottom use the **real** size for sparse disks to avoid a misleading total (per the "verify disk accounting sums" project rule).

| # | Path | Size (ls -lh) | Real (du, if sparse) | Likely type | Confidence |
|---|------|---------------|----------------------|-------------|------------|
| 1 | `~/.codex/state_5.sqlite` | 2.5G | — | Codex CLI session-state SQLite DB | **DO-NOT-TOUCH** — active credential/session state |
| 2 | `~/.codex/logs_2.sqlite-wal` | 860M | — | Codex logs DB WAL journal | **DO-NOT-TOUCH** — active DB journal |
| 3 | `~/.codex/logs_2.sqlite` | 3.0G | — | Codex logs SQLite DB | **DO-NOT-TOUCH** — active DB |
| 4 | `~/.cmuxterm/workstream.jsonl` | 1.0G | — | cmux terminal-multiplexer session log, mtime = right now | **DO-NOT-TOUCH** — actively appended live session state (the tool running this task) |
| 5 | `~/.hermes/state.db` | 6.7G | — | Hermes gateway state SQLite DB | **DO-NOT-TOUCH** — active production DB |
| 6 | `~/Downloads/voyage_gameplay_stream/Devs Play Voyage： Larion (First Gameplay Stream).mp4` | 652M | — | Downloaded gameplay video | **SAFE** — ordinary Downloads media |
| 7 | `~/.lima/colima/basedisk` | 837M | — | Base VM image for a **stopped, orphaned raw lima instance** named "colima" (separate from the colima CLI's active profile — confirmed via `limactl list`: `Stopped`, dir `~/.lima/colima`) | **REVIEW** — no open fd, not the active colima VM; likely leftover from a pre-migration setup |
| 8 | `~/.lima/colima/diffdisk` | 100G (apparent) | **3.9G** | Overlay disk for the same stopped/orphaned lima instance | **REVIEW** — not open by any process (`lsof` empty); confirm unused, then `limactl delete colima` |
| 9 | `~/.dropbox/instance1/sync_fp/nucleus.sqlite3` | 1.0G | — | Dropbox sync-engine fingerprint DB, mtime = today 03:23, Dropbox.app confirmed running (PID 1172) | **DO-NOT-TOUCH** — active sync-engine DB |
| 10 | `~/.local/share/opencode/opencode.db` | 683M | — | opencode CLI local SQLite DB, mtime Jul 13 (4d old), no opencode process running now | **REVIEW** — app data, not currently open; safe to inspect/vacuum via the tool itself before deleting |
| 11 | `~/.colima/_lima/colima-ci/diffdisk` | 20G (apparent) | **1.0G** | Overlay disk for colima **"ci" profile** — confirmed `Stopped` via `colima list` | **REVIEW** — not open; recreatable via `colima start --profile ci` (used for CI-runner recovery per repo skills) |
| 12 | `~/.colima/_lima/colima/diffdisk` | 20G (apparent) | **1.5G** | Overlay disk for colima **"default" profile — ACTIVE** (confirmed open by `com.apple...Virtualization.VirtualMachine` PID 23732) | **DO-NOT-TOUCH** — in-use VM disk |
| 13 | `~/.config/mcp-daemon/logs/context7.log` | 899M (→943M live) | — | MCP daemon log for `context7-mcp`, actively growing right now | **REVIEW** (safe to truncate, not delete-while-tiny-benefit) — see process-storm note below |
| 14 | `~/.colima/_lima/_disks/colima-ci/datadisk` | 60G (apparent) | **2.1G** | Docker data-root disk for **stopped** "ci" profile | **REVIEW** |
| 15 | `~/.colima/_lima/_disks/colima/datadisk` | 60G (apparent) | **39G** | Docker data-root disk for **ACTIVE** "default" profile, mtime = right now, actively growing | **DO-NOT-TOUCH** — this is the disk behind the known "Colima regrowth" issue already tracked in project memory (`project_2026-07-17_colima_regrowth_shlock_bug_and_dk2d_retention.md`); not a new finding, just confirming it's currently 39G real and growing |
| 16 | `~/.codex/sessions/2026/03/17/rollout-...019cfba4....jsonl` | 611M | — | Codex conversation session transcript | **DO-NOT-TOUCH** — per standing rule "Leave Codex sessions alone" |
| 17 | `~/.codex/sessions/2026/03/17/rollout-...019cfc68....jsonl` | 1.2G | — | Codex conversation session transcript | **DO-NOT-TOUCH** — same rule |
| 18 | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | 3.2G | — | Cursor IDE workspace/chat-history SQLite DB, mtime Jul 11 (6d old), Cursor **not currently running**, no open fd | **REVIEW** — real app state (chat/workspace history); don't blind-delete, prune via Cursor's own storage-cleanup UI first |
| 19 | `~/Library/Application Support/Google/GoogleUpdater/crx_cache/618a6d0f...` | 704M | — | Chrome component-updater cache blob (content-hash filename) | **SAFE** — disposable, redownloadable cache |
| 20 | `~/Library/Application Support/FileProvider/C565AFA3.../database/db` | 1.8G | — | macOS FileProvider extension database, confirmed open by `fileproviderd` (PID 682, 3 open fds) | **DO-NOT-TOUCH** — active system/third-party sync-provider DB |
| 21 | `~/Library/Metadata/CoreSpotlight/.../index.spotlightV3/live.2.indexArrays` | 599M | — | macOS Spotlight search index shard | **DO-NOT-TOUCH** — system-managed index; use `mdutil`, never hand-delete |
| 22 | `~/.gemini/antigravity-cli/brain/eee85029.../tasks/task-224.log` | 946M | — | Google Antigravity IDE agent task log, mtime Jul 6 (11d old), no antigravity process running | **REVIEW** — stale, likely safe to archive/delete |
| 23 | `~/.gemini/antigravity-cli/brain/f1863a02.../tasks/task-618.log` | 1.4G | — | Same, mtime Jul 7 (10d old), no process running | **REVIEW** — stale, likely safe to archive/delete |
| 24 | `~/Library/Application Support/Google/Chrome/OptGuideOnDeviceModel/2025.8.8.1141/weights.bin` | 4.0G | — | Chrome on-device AI model weights (Gemini Nano / Optimization Guide) | **SAFE** — disposable Chrome-managed cache, redownloads on demand |
| 25 | `~/Library/Mobile Documents/57T9237FN3~net~whatsapp~WhatsApp/Accounts/.../backup/Media.tar` | 2.8G | — | WhatsApp media backup archive, synced via iCloud Drive (this path is `Mobile Documents`, distinct from `~/Library/CloudStorage` so it wasn't excluded) | **DO-NOT-TOUCH** — real personal backup data, high value, not disposable |
| 26 | `~/projects/user_scope/backup/jeffreys-macbook-pro/mcp-daemon/logs/context7.log` | 545M | — | Copy of the mcp-daemon context7 log inside the `user_scope` **git repo backup** dir; confirmed `git log` shows it was committed (`28093d0f9 chore: sync user scope backup`), even though `.gitignore` now excludes it going forward | **REVIEW** — needs `git rm --cached` + commit to actually shrink the repo; a plain `rm` would just show as an uncommitted deletion. Git-history bloat here is out of scope per your instructions (`.git/objects` excluded) but flagging since the live blob is still checked out |

### Sums by confidence tier (using **real/allocated** size for the 5 sparse colima/lima disks, apparent size for everything else)

| Tier | Count | ≈ GiB |
|---|---|---|
| **DO-NOT-TOUCH** | 13 files | **≈ 62.5 GiB** (items 1,2,3,4,5,9,12,15,16,17,20,21,25) |
| **REVIEW** | 10 files | **≈ 15.4 GiB** (items 7,8,10,11,13,14,18,22,23,26) |
| **SAFE** | 3 files | **≈ 5.3 GiB** (items 6,19,24) |
| **Total** | 26 files | **≈ 83.3 GiB** (real-size basis) |

Note: if you instead sum the **apparent** sizes of the 5 colima/lima sparse disks (100+20+20+60+60 = 260G) instead of their real allocation (3.9+1.0+1.5+2.1+39 = ~47.5G), the nominal total balloons to ~296 GiB — that's a `find`/`ls` artifact of sparse files, not real disk pressure. Use the real-size column for any capacity decisions.

### Explicit DO-NOT-TOUCH flags (active DB / in-use VM disk / session-credential state)
- `~/.codex/state_5.sqlite`, `~/.codex/logs_2.sqlite(-wal)` — active Codex session/log DBs
- `~/.hermes/state.db` — active Hermes gateway DB
- `~/.dropbox/.../nucleus.sqlite3` — active Dropbox sync DB (Dropbox.app confirmed running)
- `~/.colima/_lima/colima/diffdisk` and `~/.colima/_lima/_disks/colima/datadisk` — the **active** colima default-profile VM disk, confirmed open by a live Virtualization.framework process
- `~/.cmuxterm/workstream.jsonl` — actively-written session log for the tool running this very task
- `~/Library/Application Support/FileProvider/.../database/db` — open by live `fileproviderd`
- `~/Library/Metadata/CoreSpotlight/...` — macOS system search index
- `~/.codex/sessions/.../*.jsonl` — session transcripts (standing "never delete Codex sessions" rule)
- WhatsApp `Media.tar` — real personal backup data

### Side finding filed as a bead (not part of this read-only sweep's scope, but discovered while investigating item #13)
While checking why `context7.log` was growing in real time, `ps aux` showed **~97 concurrent `context7-mcp` supergateway node processes**, all spawned within the same minute (PIDs ~10846–11790, port 8001) — looks like a respawn/fork-loop in the mcp-daemon launcher rather than steady-state (1 process per session expected). Filed: **bead `jleechan-d7ow`** — "context7-mcp supergateway process explosion (100+ duplicate node processes)" with provenance (ps output, log path, timestamp). Not touched/killed — flagging only, per read-only scope of this task.

All 26 files remain untouched; this is a report only.

---

### colima-realistic-floor
## Colima disk floor investigation (read-only)

**Numbers gathered:**

| Metric | Value |
|---|---|
| `~/.colima/_lima/_disks/colima/datadisk` allocated (host, sparse) | 41,160,840 KB = **39.25 GiB** (max size 60 GiB) |
| `~/.colima/_lima/colima/diffdisk` allocated (host, sparse) | 1,603,180 KB = **1.53 GiB** (max size 20 GiB) — not the growth source, ignore |
| Guest-side actual usage, `/dev/vdb1` on `/mnt/lima-colima` (this IS the datadisk mounted in-VM) | **3.5 GiB used**, 53 GiB avail, 7% use — from `colima ssh -- df -h` |
| `docker ps -a` (colima context) | 7 containers total: 6× `ez-mac-runner-b-*` (**all currently `Up`**, none stopped/exited/dead), 1× `hermes-mem0-qdrant` (`Up 3 hours`) |
| `docker system df -v` | Images: 3.35GB `ezgha-runner` (in use by 6 containers) + 281MB qdrant (in use) + 11.9MB `alpine:3.19` (0 containers — dangling). Containers: each runner's writable layer is only ~61.4kB. Volumes: none. Build cache: 0B. |
| Host free space (`df -h /`) | 926Gi total, 56Gi avail — consistent with the guest's virtiofs-passthrough view (927G/871G/57G) seen on `/Users/.../worldarchitect-runners` etc. |

**Estimate — what a `docker system prune` + `fstrim` would reclaim right now:**

- **`docker system prune` alone: ~negligible (~12 MB).** There are zero stopped-but-not-removed containers (all 6 runner containers are actively `Up`), zero unused volumes, zero build cache. The only prunable image is the unused `alpine:3.19` (11.9 MB) — everything else is actively referenced by running containers.
- **`fstrim` is where the real reclaim is.** The datadisk sparse file is allocated at 39.25 GiB on the host, but the guest filesystem living on that disk (`/dev/vdb1`) reports only **3.5 GiB actually used**. That ~35.75 GiB gap is blocks that were written and then freed inside the guest ext4 (by the churn of ephemeral runner containers being created/destroyed repeatedly) but never punched back to the host because no trim has run recently.
- **Estimated reclaim from `fstrim` alone: ~35–36 GiB**, bringing the sparse file down from ~39.25 GiB toward something in the 4–6 GiB range (allowing for ext4 journal/metadata overhead and a small safety margin — filesystems rarely trim to the exact byte of "used").
- Net: this matches the confirmed root cause — it's runner-container churn inflating the sparse file, not genuinely retained disk content; the trim-guard's HOST-free-space-only trigger (<40 GiB free) is the known gap (bead jleechan-uio3) since it doesn't run proactively based on this allocated-vs-used gap.

**Bottom line:** almost all upside is in `fstrim`, not `docker prune`, because the runners are still running (nothing stopped to clean up) and the images/containers themselves are tiny — the growth is sparse-file bloat from container layer churn that a trim would reclaim (~35.75 GiB), not orphaned Docker objects.

No destructive commands were run — only `du`, `colima ssh -- df -h`, `docker ps -a`, `docker system df -v`, and a host `df -h` for context.

---

### duplicate-repos
## Duplicate Git Clone Investigation — READ-ONLY (no deletions performed)

**Scope scanned:** `/Users/jleechan/projects`, `projects_other`, `projects_reference`, `repos`, `.worktrees` (depth 1-2), 133 git dirs found, remote URLs normalized (stripped embedded credentials/`.git` suffix) to detect same-upstream dupes even when the raw URL text differed.

### CRITICAL side-finding (not part of the ask, but too severe to omit): plaintext GitHub PAT tokens in `.git/config`
Four clones have a **live-looking personal access token embedded directly in `remote.origin.url`** (visible via `git remote get-url origin`, i.e. it sits in plaintext in `.git/config`):
- `/Users/jleechan/projects/worldarchitect.ai` → `ghp_PU2m...REDACTED...a2DziPx (rotate immediately, see issue #27)`
- `/Users/jleechan/projects_reference/jleechanclaw` → `ghp_T9mz...REDACTED...c4ocDX03MDnq (rotate immediately, see issue #27)`
- `/Users/jleechan/repos/jleechanclaw` → a GitHub PAT (value redacted, rotate immediately — see issue #27)
- `/Users/jleechan/repos/wt-6969-tmp` → `ghp_@...` (looks empty/broken)

Recommend rotating/revoking these tokens and switching those remotes to `gh`-credential-helper or SSH. This is read-only discovery — no config was touched.

### CRITICAL side-finding #2: 41 GiB of stale worktrees inside one "duplicate" copy
`/Users/jleechan/projects/worldarchitect.ai` measures **44.85 GiB total**, but only ~3.8 GiB of that is real repo content (`.git`=2.0G, `venv`=857M, working tree ≈1G). The other **41 GiB is `.claude/worktrees/`** — 131 accumulated worktree checkouts (some 1+ GiB each, e.g. `wf_9efb8a9d-d60-3`, `agent-a13ba63a7fec96c8c`). This dwarfs every clone-duplication finding below combined and should be swept via `worktree_hygiene.sh` (this session's own tool), not by deleting the repo.

---

### Duplicate remote groups (high-confidence, safe to reclaim)

| Remote (normalized) | Copies (size) | Canonical (kept) | Redundant → reclaim | GiB |
|---|---|---|---|---|
| jleechanorg/agent-orchestrator | `projects/agent-orchestrator` 590M **[main, clean, 0/0, 2026-07-11]**; `agent-orchestrator-skeptic-wt` 231M (stale branch, 391 behind); `projects_reference/agent-orchestrator-mirror` 1.79G (dirty, diverged) | agent-orchestrator | skeptic-wt + mirror | **2.02** |
| jleechanorg/agent-orchestrator-ts | `projects_other/agent-orchestrator` 1.01G **[main, 0/0, 2026-07-06]**; `projects_reference/agent-orchestrator` 74M (stale, 2026-04-29) | projects_other copy | projects_reference copy | **0.07** |
| jleechanorg/ai_dev_recs | `projects_other` 400K **[main,0/0]**; `projects` 1.1M (10 behind, dirty) | projects_other | projects | 0.001 |
| jleechanorg/ai_universe | `projects_other` 1.13G **[main,0/0]**; `projects` 1.62G (18 behind, 9 dirty) | projects_other | projects | **1.62** |
| jleechanorg/ai_universe_frontend | `projects_other` 36M **[main,0/0]**; `projects` 52M (15 behind, weird `dev<ts>` branch, 12 dirty) | projects_other | projects | 0.05 |
| jleechanorg/autowiki | `projects` 7.1M **[main,0/0, full history]**; `projects_other` 128K (stub, only "Initial commit") | projects | projects_other | ~0 |
| jleechanorg/claude-code | `projects_other/claude-code-fresh` 40M (2026-04-02, newer); `projects_other/claude-code` 31M (2025-08-29, stale) | claude-code-fresh | claude-code | 0.03 |
| jleechanorg/git-hooks-security | `projects_other` 160K **[main,0/0]**; `projects` 516K (1 behind, dirty) | projects_other | projects | ~0 |
| jleechanorg/mcp_mail | `projects_other/mcp_mail` 319M **[0/0 vs main, detached HEAD]**; `projects/mcp_mail_repro_v2` 36M (diverged repro branch) | mcp_mail | mcp_mail_repro_v2 | 0.03 |
| NousResearch/hermes-agent | `projects/upstream-hermes-agent` 275M **[main,0/0]**; `projects_other/hermes-agent` 1.24G (25 ahead, active sync branch, freshest 2026-07-17 — keep, real WIP); `projects_reference/hermes-agent` 846M (**6346 commits behind**, 2026-03-29) | upstream + projects_other (both serve distinct purposes) | projects_reference (forgotten mirror) | **0.83** |
| openai/codex | `projects_other/codex` 92M (newer/more complete); `projects_other/openai_codex` 59M (older, shallower) | codex | openai_codex | 0.06 |
| openclaw/openclaw | `projects_reference/openclaw` 1.44G **[main,0/0]**; `projects/openclaw-docs` 1.24G (**4760 commits behind!**) | projects_reference | openclaw-docs | **1.24** |
| steveyegge/gastown | `projects_reference/gastown` 77M (main,0/0, more recent); `projects/gastown` 64M (main,0/0, older) | projects_reference | projects | 0.06 |
| myoung34/docker-github-actions-runner | `docker-github-actions-runner` 1.05M (main); `myoung34-docker-github-actions-runner` 376K (master, older clone) | docker-github-actions-runner | myoung34-... | ~0 |

**High-confidence reclaimable subtotal: ≈ 6.02 GiB**

### Ambiguous groups — needs manual check before removing anything

| Remote | Copies | Why ambiguous |
|---|---|---|
| jleechanorg/jleechanclaw (3×) | `projects/jleechanclaw-real` 1.14G (main, clean, 12 behind); `projects_reference/jleechanclaw` 1.84G (dirty, 35 behind, **has embedded PAT**); `repos/jleechanclaw` 1.64G (clean, most recent commit 2026-07-09, but on `session/jc-1990` branch, **has embedded PAT**) | None exactly matches origin/main; the two freshest are on non-main branches. `projects_reference` copy is the clear worst (stale+dirty+largest) — safe to reclaim ≈**1.84 GiB**; deciding between the other two needs a look at whether `session/jc-1990` has unmerged unique work. |
| jleechanorg/smartclaw (3×) | `smartclaw-fix-26` 28M (branch `pr-26`); `smartclaw` 109M (branch `fix/use-openclaw-dir`); `repos/smartclaw` 33M (branch `pr22-rebase`, 12 dirty) | All three sit on **different in-flight PR branches** — likely legitimate parallel worktree-style clones, not accidental dupes. Check PR status of pr-26 / pr22-rebase before touching; potential ≈0.17 GiB total if all are actually abandoned. |
| jleechanorg/worldai_claw (2×) | `worldai_claw` 1.06G (branch `add-skeptic-gate`, most recent, but **75 behind main**); `worldai_claw_agento` 91M (branch `feat/worldai-claw-agento`, stale, 5 dirty) | Neither matches origin main; can't tell which is "the" copy without checking PR history. Up to **1.06 GiB** if `worldai_claw` is confirmed abandoned. |
| jleechanorg/worldai_archive (2×) | `worldai_archive_round2` 233M (main, 0/0); `worldai_archive` 243M (branch `archive/worldarchitect-round4-low-risk-media`, 4 ahead) | Branch name suggests a **deliberate archival snapshot**, not accidental duplication — diff before removing. Up to 0.24 GiB if truly redundant. |
| jleechanorg/worldarchitect.ai (4×) | `repos/wt-6969-tmp` 401M (**main, clean, exactly 0 ahead/0 behind — the only copy that perfectly matches origin/main**); `projects_other/worldarchitect.ai` 1.26G (422 behind, dirty); `projects/wa-6884` 338M (no compare ref); `projects/worldarchitect.ai` 44.85 GiB (276 behind, 18 dirty, but is clearly the primary/active daily-driver clone with 345 registered worktrees — see 41 GiB worktree-bloat finding above) | By strict git-state, `wt-6969-tmp` is "most canonical," but practically `projects/worldarchitect.ai` is the real working repo. Reclaiming the other 3 (not touching the big one) = `410768+1293424+346100` KB ≈ **1.96 GiB**. The 41 GiB inside the big one is a separate worktree-hygiene issue, not dedup. |

### Grand summary
- **Safe/high-confidence reclaim by removing all-but-one copy:** ≈ **6.02 GiB**
- **Plus reasonably confident extras** (worst jleechanclaw copy + 3 non-primary worldarchitect.ai copies): **+1.84 + 1.96 ≈ 3.8 GiB** → combined ≈ **9.8 GiB**
- **Ambiguous/needs-PR-check groups** (smartclaw, worldai_claw, worldai_archive): up to another **≈1.5 GiB**, but do not act without checking branch/PR status first
- **Separate, much larger opportunity (not clone dedup):** **41 GiB** of stale worktrees under `/Users/jleechan/projects/worldarchitect.ai/.claude/worktrees/` (131 dirs) — route through `worktree_hygiene.sh`
- **Security action item (independent of disk space):** rotate the 3 live PAT tokens found embedded in `.git/config` remote URLs

All data files used for this analysis: `/tmp/dirs_list.txt`, `/tmp/dirs_remotes.tsv`, `/tmp/dup_dirs.txt`, `/tmp/dup_details.tsv` — left in place, nothing in any repo was modified or deleted.

---

### dirs-cleaner-recheck
## Findings — 2 new independent methods on `/private/var/dirs_cleaner`

### Method 1: man pages + periodic/daily maintenance config

- `man dirs_cleaner` — confirms it's a generic utility (`dirs_cleaner path ...`) that recursively deletes directory *contents* (not the dirs themselves); man page has no schedule info.
- `man periodic` — **no such man page exists** on this system. `/etc/periodic/`, `/usr/sbin/periodic`, and `/etc/defaults/periodic.conf` are all absent. Modern macOS 15.5 has removed the classic BSD periodic/cron daily-maintenance mechanism entirely — there is no "runs every N days via periodic" path for this.
- Grepped every readable `/System/Library/LaunchDaemons/*.plist` for `dirs_cleaner` — **zero matches**. The only related job is `com.apple.tmp_cleaner` (`/usr/libexec/tmp_cleaner`, a small shell script, `StartCalendarInterval Hour=0`, `daily_clean_tmps_days="3"`) which only cleans `/tmp` via `find -atime/-mtime +3`, and is a **separate mechanism** from `dirs_cleaner`. There is no persistent, visible, scheduled job that invokes `dirs_cleaner` — it appears to be invoked on-demand/via XPC by something not exposed in readable LaunchDaemons (e.g. storage-pressure handling), so no evidence of an automatic N-day decay.

**New concrete finding (unplanned but load-bearing):** `mdfind dirs_cleaner` turned up a real crash/diagnostic report:
`~/Library/Logs/DiagnosticReports/Retired/dirs_cleaner-2026-07-16-125636.ips` (yesterday, 12:56:33 PDT). It shows:
```
procPath: /usr/libexec/dirs_cleaner
parentPid: 35113, responsiblePid: 588, responsibleProc: "cmux DEV"
coalitionName: "com.cmuxterm.app.debug.dev.fork"
sip: "enabled"
exception: {"type":"EXC_CRASH","signal":"SIGKILL (Code Signature Invalid)"}
termination: {"namespace":"CODESIGNING","indicator":"Launch Constraint Violation"}
```
This independently confirms `dirs_cleaner` is protected by **macOS Launch Constraints** (a code-signing enforced restriction on which parent process may exec it) — a *distinct* protection layer from SIP file-ACLs. Someone (very likely an earlier probe in this same investigation, running under this `cmux DEV` session) tried to invoke `/usr/libexec/dirs_cleaner` directly and it was instant-SIGKILLed before it could even open the path, not merely permission-denied on read. This explains why direct-invocation attempts (even with sudo/FDA) can never work here — it's blocked at the exec layer, not just the filesystem-read layer.

### Method 2: system_profiler / diskutil apfs purgeable accounting

- `system_profiler SPStorageDataType`: Data volume shows Free 60.4 GB / Capacity 994.66 GB — a whole-volume aggregate only, no purgeable-space or path-specific line item.
- `diskutil apfs list`: Data volume "Capacity Consumed: 882.5 GB", container "Capacity Not Allocated: 60.2 GB" — again only container/volume-level aggregates. No "Purgeable" breakdown is exposed (APFS purgeable space here refers to snapshot-reclaimable space, a different concept from a SIP-protected directory's contents), and nothing attributes space specifically to `dirs_cleaner`.

### Bottom line

Neither new method independently confirms or refutes the ~165 GiB claim for `/private/var/dirs_cleaner` — it remains unmeasured by any read-only CLI tool available in this session. The new, verifiable fact is that `dirs_cleaner` is blocked by **Launch Constraints** (not just SIP file ACLs), evidenced by a real SIGKILL/"Launch Constraint Violation" crash report from yesterday (`~/Library/Logs/DiagnosticReports/Retired/dirs_cleaner-2026-07-16-125636.ips`), and that there is **no periodic/cron mechanism on this macOS version at all** (`man periodic` doesn't exist, `/etc/periodic` is gone) — so no automatic-decay schedule for this path could be found. The only remaining avenue would be Apple's own "Storage Management" system-settings pane (uses privileged StorageKit/OnDeviceStorage entitlements this shell doesn't have), which is outside read-only CLI capability.