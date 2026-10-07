# Disk growth analysis, 2026-10-03 (read-only)

Question: what grew? Data volume is 98-99% full. Live `df -g` at report time: 871 GiB used, 14 GiB free (snapshot `ad8baf6` at 15:17Z: 851 used, 44 free).

Method: CLAUDE.md "Investigation methodology". No `du`/`find`; snapshot history from `~/.disk_magician_backup` (git), frontier from `~/.disk_magician_state/frontier_last.json`, stat-only reads for named files. Extraction scripts: `/tmp/hx.py` (-> `/tmp/hist.json`, 1595 snapshot commits 2026-08-15..10-03, validated), `/tmp/series.py`, `/tmp/rl.py`. Sizes in GiB (snapshot `directories` values are KB).

## 0. Fleet check (step -1)

Not re-run here (no mutation allowed, and `check-launchd-fleet` is part of `audit`). Snapshots kept landing every ~35 min through 2026-10-03T18:21Z (git log of `snapshots/disk_snapshot.json`), so the snapshot collector is alive. Not verified: the other sweepers.

## 1. Floor and gap

Only snapshots with `snapshot_coverage_pct >= 70` used (233 of 1595; low-coverage runs are bimodal timeout artifacts, e.g. 2026-10-03T18:21Z = 21.4%, 877 used).

| Window | Floor (disk_used_gb) | Snapshot | Cov | Now (snapshot 15:17Z, 851) gap | Now (live df, 871) gap |
|---|---|---|---|---|---|
| Lowest of last ~14 days that have a >=70% snapshot (09-07..10-03) | **715 GiB, 2026-09-14T02:23Z** | `aee790f` (`complete`, 75/75 paths) | 71.3 | **+136** | **+156** |
| Strict last 14 calendar days (09-19..10-03) | 790 GiB, 2026-09-24T10:36Z | `af833a1` | 70.1 | +61 | +81 |
| Older, lowest since 08-15 | 725 (08-27 `93f4481`); 672.61 (2026-08-03, from memory file, not re-derived) | | | | |

Caveat: used swings 715-741 within 09-14 alone (Colima fstrim / reboot fd-release, see memory "Disk swing mechanisms"), so the 715 floor is the bottom of a ~25 GiB intraday swing; the 790 strict floor is the more conservative "sustained" number. Per-day min/max for the last 3 weeks is in `/tmp/hist.json` (e.g. 09-21 min 831, 09-22 min 831, 10-03 min 851 `5e80914`).

Accounting of the +136 (`aee790f` vs `ad8baf6`, `snapshot_metadata`): tracked_total_kb_deduped 534,732,036 -> 629,089,500 KB = 510.0 -> 600.0 GiB (**+90.0**); `residual_gb` 205.4 -> 251.2 (**+45.8**). Residual is the part not attributed to any snapshot key; it is inflated by keys that did not measure (see 2.3).

Ledger staleness: `ledger/topdown-5g.json` last commit `a8f629e` 2026-08-30 (capture 2026-08-31T06:53Z, 843.5 GiB used, complete). Used here only as the older-era comparison in section 3.2, not as the floor.

## 2. Per-path delta: floor `aee790f` (09-14T02:23Z) vs `ad8baf6` (10-03T15:17Z, 70.5%, 74/75 paths ok)

Source: `snapshots/disk_snapshot.json` `directories` in each commit. Nested keys are not additive (`dedup_excluded`: codex_sessions in codex_root, claude_projects in claude_root, hermes_prod alias of hermes, lc_* in library_containers).

### 2.1 Top growers

| Key | Floor 09-14 | Now 10-03 | Delta | Read |
|---|---|---|---|---|
| root_library | 3.33 | 33.65 | +30.32 | **Measurement artifact, not growth** (2.3) |
| projects | 207.69 | 233.80 | **+26.11** | Real: worktree sprawl |
| cache_dir (~/.cache) | 3.69 | 18.61 | **+14.93** | Real: wiki-publish, pr-ready |
| codex_root (~/.codex) | 69.98 | 83.45 | **+13.47** | Real (includes codex_sessions +10.25 to 61.12) |
| claude_root (~/.claude) | 17.92 | 31.16 | **+13.24** | Real: `state/` per-task clones |
| tmp_private | 0.78 | 4.32 | +3.54 | Real (scratch) |
| local_dir (~/.local) | 7.62 | 10.87 | +3.25 | Real |
| library_app_support | 12.74 | 15.68 | +2.94 | |
| library_developer | 0.03 | 2.19 | +2.16 | CoreSimulator |
| ollama | 0.26 | 1.77 | +1.52 | |
| projects_other | 13.70 | 14.57 | +0.87 | |
| gemini_root | 6.52 | 7.38 | +0.87 | |

Real growth excluding root_library and nested double counts: 26.11+14.93+13.47+13.24+3.54+3.25+2.94+2.16+1.52 = **81.2 GiB**.

### 2.2 Shrinkers (offsets)

hermes_prod -11.08 (alias, deduped, not real), library_caches -9.29 (**not measured now**, in `timeout_keys`), colima -9.68 (18.72 -> 9.04, volatile), worktrees_dot -3.96, rustup -2.51, projects_reference -1.51.

### 2.3 Why the table overstates / understates

- root_library is bimodal: 3.3-3.4 on every >=70% day 09-07..09-24, then 33.6 (09-27 `f6e5bac`, 10-03), 6.9 (10-02), or unmeasured. The frontier shows `Library/CloudStorage/GoogleDrive-jleechan@gmail.com` = 45.1 GiB (My Drive/AI convos: codex_conversations 32.0, claude_conversations 9.6, gemini_conversations 3.2). The 08-31 ledger already had Library at 115.2 GiB vs 103.8 now. So Google Drive was most likely always there; the File Provider walk only sometimes completes within the per-path budget.
- library_caches is None in the current snapshot (timeout), so its 9.3 GiB drops out while `residual_gb` rises. Part of the +45.8 residual is this.
- `ad8baf6` has no keys for `project_worldaiclaw` (60.4 GiB in frontier) or `.dark-factory` (14.9), so the largest unmapped growth is invisible to the snapshot table and appears only in section 3.

## 3. Frontier cross-check: `frontier_last.json` (gdu one-pass, captured 2026-10-03T10:50:19Z)

disk_used 851.13 GiB, measured 797.83, residual 53.31 (`residual_label`: protected_or_apfs_allocation_not_attributable). `granularity_buckets` sum 760.53 GiB, max bucket 4.98 GiB (<=5 GiB invariant holds); 5 oversize indivisible files = 39.1 GiB listed separately. `top_level_ledger`: 724.55 /Users, 25.55 /Applications, 21.84 /opt, 18.72 /private, 6.88 /Library (partial), 3 roots unfinished (.DocumentRevisions-V100, .Spotlight-V100, .fseventsd, permission denied; 209 `frontier_unfinished` total).

### 3.1 Largest roots, subdivided to <=5 GiB leaves (bucket sums from the file)

| Root | GiB | Children (bucket sums) |
|---|---|---|
| ~/projects | 228.0 | 571 child dirs; worktree_*/wt_*/pr* dirs sum **121.5**; worldarchitect.ai 22.4 (`.claude` 11.5, `.git` 6.1); user_scope 6.7 (`backup/jeffreys-macbook-pro` 4.83, leaf); dark-factory 3.9; ~25 worktrees at 1.6-2.7 each |
| ~/Library | 103.8 | GoogleDrive 45.1 (above), Dropbox 5.0, Metadata 3.9, Logs 3.9, App Support/Google 3.8, Mail 3.7, FileProvider 2.8, Aside 2.6, Containers 2.5, Caches/Google 2.3, Caches/com.openai.codex 2.2, Developer 2.2 |
| ~/.codex | 67.1 | sessions 61.1 (2026/08 20.75, 2026/09 17.18, 2026/07 6.34, 04 5.86, 06 3.80, 03 3.43, 05 2.57), sessions_archive 1.85, direct files 2.71; plus oversize files below |
| ~/project_worldaiclaw | 60.4 | many 1.8-3.1 worktrees (`worktree_ios_app` 3.09, `wt_sb_*`, `advice_src_*` 2.1-2.4), `worldai_claw/.git` 4.49, `docs` 3.26 |
| ~/.claude | 31.2 | `state` **21.78** (`pr-stack-fix-3gc6e52z` 5.15, `stack-gap-close-a9d_pntr` 4.22 leaf, rewards 1.76, stack-* 1.0-1.4), `projects` 6.67 |
| ~/.cache | 18.6 | wiki-publish 6.71, pr-ready 4.98 (leaf), codex-runtimes 2.31, worldai 1.25, uv 1.10 |
| ~/.dark-factory | 14.9 | runs 12.53, controller-snapshots 1.52 |
| ~/projects_other, Pictures, projects_reference, .local | 14.6, 14.4 (Photos library), 12.1, 10.9 | |
| /private/var/folders/...(T, X) | 8.4 | T 3.47, X 3.44 (browser code_sign_clone area), C/clang 0.63 |
| /opt/homebrew | 21.8 | Cellar 8.25, share 6.58 (android system-images 4.15), lib 6.08 |
| ~/.gemini 7.38, ~/.nvm 4.98, Xcode.app 4.94, ~/repos 4.39, ~/.Trash 2.98, ~/.colima 3.05 | | |

Oversize indivisible files (stat-verified live in section 4): `.codex/thread_history_1.sqlite` 11.11, `.hermes/state.db` 9.12, `.colima/_lima/_disks/colima/datadisk` 5.99, `user_scope/.git/objects/pack/pack-33ebee0d...pack` 5.78, `.codex/logs_2.sqlite` 5.29.

### 3.2 Older era: ledger `a8f629e` (2026-08-31, 843.5 used) vs frontier now (851.1), same grouping

| Path | 08-31 | 10-03 | Delta |
|---|---|---|---|
| ~/projects | 139.70 | 228.01 | **+88.31** |
| ~/project_worldaiclaw | 10.50 | 60.42 | **+49.92** |
| ~/.claude | 8.64 | 31.16 | +22.52 |
| ~/.cache | 1.20 | 18.61 | +17.41 |
| ~/.codex (buckets) | 51.18 | 67.05 | +15.87 |
| `.codex/thread_history_1.sqlite` | 5.33 | 11.11 | +5.79 |
| `.codex/logs_2.sqlite` (+wal) | 7.57 (wal) | 5.29 | rotated, not net growth |
| ~/.local | 6.33 | 10.87 | +4.53 |
| ~/.dark-factory | 10.62 | 14.90 | +4.29 |
| /private/tmp | 145.41 | 4.27 | -141.15 (reclaimed) |
| /private/var | 50.76 | 14.45 | -36.30 |
| ~/.openclaw | 17.35 | 0.00 | -17.35 |
| Spotlight Store-V2 | 14.81 | unfinished (permission denied) | n/a |
| ~/.gemini | 16.10 | 7.38 | -8.72 |

Net: used went 843.5 -> 851.1 only because ~230 GiB of /private/tmp, var, openclaw, spotlight, gemini were reclaimed while ~230 GiB of projects/worktrees, worldaiclaw, .claude, .cache, .codex grew. The "cache/tmp" reservoirs shrank; the worktree and agent-state reservoirs refilled.

### 3.3 Frontier-only buckets (not in the snapshot table)

project_worldaiclaw 60.4, .dark-factory 14.9, Library/CloudStorage/GoogleDrive 45.1 (intermittent in snapshot), Dropbox 5.0, .android 1.5, .Trash 2.98, project_agento 2.2, cb-demo 2.1, llm_wiki 2.1, Xcode.app 4.9 (applications key covers it). The 53.3 GiB frontier residual is unattributed; `purgeable_kb` 0, `local_snapshots_count` 0 (`tmutil listlocalsnapshots` live: none).

## 4. Named suspects (stat only, live 2026-10-03)

| File / dir | Apparent | Allocated | Note |
|---|---|---|---|
| ~/.codex/logs_2.sqlite | 5.10 | 5.10 | never-delete family (`~/.codex/log*`/state); report only |
| ~/.codex/logs_2.sqlite-wal | 0.62 | 0.63 | was 7.57 on 08-31 |
| ~/.codex/state_5.sqlite | 2.63 | 2.63 | `state*.sqlite` never-delete; report only |
| ~/.codex/thread_history_1.sqlite | 11.15 | 11.17 | largest single file; 5.33 on 08-31 (`a8f629e`) |
| ~/.cmuxterm/workstream.jsonl | 2.65 | 2.66 | ~/.cmuxterm dir 2.98 |
| ~/.hermes/state.db | 9.11 | 9.12 | 8.20 on 08-31 |
| ~/.colima/_lima/_disks/colima/datadisk | **100.00** | **17.40** | frontier at 10:50Z saw 5.99; +11.4 GiB allocated in hours; sparse |
| ~/.colima/_lima/colima/diffdisk | 20.00 | 2.66 | |
| /private/var/folders/...(T 3.47, X 3.44, C/clang 0.63) | | | 8.4 total; no `code_sign` bucket >=5 GiB in frontier (`code_sign_clone` buckets: 0) |
| ~/.gemini | | 7.38 | down from 16.10 on 08-31; `antigravity-cli/brain` leaf 4.28 |
| ~/.claude/state | 30 task dirs, newest mtime 2026-09-24/26 | 21.78 | all older than the 7-day floor |
| Worktrees | | ~121.5 (projects) + ~50 (worldaiclaw) | protected if touched in the last 7 days |

Live df rose 851 -> 871 between 15:17Z and report time (snapshots show 852 at 15:51Z, 877 at 18:21Z). The Colima datadisk allocation (17.4 vs 5.99 at 10:50Z) accounts for about 11 GiB of that; the rest was not attributed (no du allowed).

## 5. Growth mechanisms ranked

"Since floor" = snapshot delta 09-14 -> 10-03 unless stated; "always large" = present at the 08-31 ledger.

| # | Mechanism | GiB | Since floor or always large | Owner (6-tier stack) | Never-delete? |
|---|---|---|---|---|---|
| 1 | Git worktree sprawl: ~/projects (121.5 in worktree_/wt_/pr* dirs) + ~/project_worldaiclaw (60.4) | +26.1 (snapshot projects); +88.3 and +49.9 vs 08-31 | Grew (and 08-31 base ~150) | **Tier 6**: `cleanup_worktrees.sh`, `cleanup_worktree_venvs.sh`, `worktree_hygiene.sh`; needs `WORKTREE_APPROVED=1`, 7-day floor. Gap: ~/project_worldaiclaw and `.dark-factory` are not snapshot keys | No, but 7-day recency protection; young ones are untouchable |
| 2 | Agent state/scratch under ~/.claude/state (21.8) plus ~/.cache (wiki-publish 6.7, pr-ready 5.0) | +13.2 claude_root; +14.9 cache_dir | Grew | `.claude/state`: `cleanup_claude_state.sh` (db6fb14), tier-5-like agent state, not named in CLAUDE.md. `.cache/wiki-publish` and `.cache/pr-ready`: no script references them (grep of scripts/*.sh) -> **none** | `~/.claude/state` no; `~/.claude/projects` (6.67) yes |
| 3 | ~/.codex sessions and DBs: sessions 61.1 (+10.25), thread_history_1.sqlite 11.15 (+5.8 since 08-31), logs_2.sqlite 5.1, state_5.sqlite 2.6 | +13.5 codex_root | Grew (sessions Aug-Sep = 38 GiB) | `cleanup_sessions.sh` exists but sessions are protected; thread_history has no owner | **Yes**: sessions*, state*.sqlite, log. No deletion proposed |
| 4 | Colima VM sparse disk: allocated swings 6.0 -> 17.4 within a day (floor snapshot 18.7, now 9.0) | +/- 11 | Volatile, not net growth vs floor, but the likely source of the 15:51Z -> now rise | **Tier 3** `cleanup_colima.sh` (docker prune plus `fstrim`; guest wedges near 100% disk, recover with `colima stop/start`) | No |
| 5 | Google Drive local mirror of AI convos (~/Library/CloudStorage/GoogleDrive, 45.1; codex_conversations 32.0) | 0 vs floor (always), appears as +30 only through measurement | Always large | **None** (Drive File Provider, not covered by any tier; it mirrors the same codex/claude sessions as the never-delete stores). Needs a Drive-side offline/stream setting decision, not a script | Not on the list, but it is a copy of never-delete data: do not remove without a human call |

Others, smaller: dark-factory runs 12.5 (no tier; +4.3 vs 08-31), tmp_private +3.5 and `/private/var/folders` 8.4 (Tier 1 `cleanup_tmp.sh`, size-budget eviction PR #71, `cleanup_code_sign_clones.sh` PR #70), CoreSimulator 3.5 (Tier 2).

## 6. Conclusions

- The "gap to floor" is +136 GiB against 715 (or +61 against the sustained 790), and about 81 GiB of it is real growth: worktrees, agent state (.claude/state, .cache), and Codex sessions/DBs. About 30 GiB of the snapshot delta (root_library) is a measurement artifact and about 9-11 GiB each of library_caches/hermes_prod are dropout and aliasing.
- Since the 08-31 ledger the big reservoirs (/private/tmp -141, var -36, openclaw -17, spotlight -15, gemini -9) were reclaimed, and the worktree/agent-state families (+88, +50, +23, +17, +16) refilled them.
- Biggest gaps in cleaner coverage: nothing owns `~/.cache/{wiki-publish,pr-ready}`, `~/.dark-factory/runs`, `~/project_worldaiclaw`, or the Drive mirror; and `project_worldaiclaw`/`.dark-factory` are not snapshot keys, so `history_diff` cannot see them grow.
- The snapshot collector is bimodal at the top of the disk-fill window (coverage 13-43% on most runs after 09-24). 18 of 33 runs on 10-03 hit >=70%; the last 4 (16:26Z onward) were 15-37%. Frontier residual (53 GiB) is far smaller than snapshot residual (251 GiB), so prefer the frontier for accounting.
- Nothing was deleted or modified; the only write is this file.

## 60-day floor comparison (added 2026-10-03)

Floor: 714 GiB at 2026-08-11T01:07Z (`624c532`, cov 74.0%; coverage>=70 rule; a 62%-coverage run the same night read 687). Now: 851 GiB (`ad8baf6`, 2026-10-03T15:17Z, cov 70.5%). Gap +137 GiB. The floor is a post-reclaim trough (08-10 read 770).

| Path (GiB) | Floor -> now | Delta |
|---|---|---|
| projects | 151.5 -> 233.8 | +82.3 |
| codex_root (incl. codex_sessions 23.0 -> 61.1, +38.1) | 31.2 -> 83.5 | +52.3 |
| root_library (Google Drive mirror) | 6.8 -> 33.7 | +26.8 |
| claude_root | 10.2 -> 31.2 | +20.9 |
| cache_dir | 1.9 -> 18.6 | +16.8 |
| local_dir | 5.0 -> 10.9 | +5.8 |
| opt | 16.5 -> 21.8 | +5.3 |
| projects_reference | 6.9 -> 12.0 | +5.1 |
| tmp_private | 0.1 -> 4.3 | +4.2 |
| private_var | 11.0 -> 14.5 | +3.6 |
| colima | 40.4 -> 9.0 | -31.3 |
| library_developer | 15.9 -> 2.2 | -13.7 |
| ao_home | 13.5 -> 0.6 | -13.0 |
| worktrees_dot | 15.8 -> 3.6 | -12.2 |

Caveat: key set changed (54 -> 74). Floor-only counted keys total 85.5 GiB (project_siblings 74.4, removed by 436f3f3/PR #57 on 2026-09-01; library_caches 9.7); now-only counted keys 9.9 GiB. Counted common keys: +147.0 GiB vs df +137. Source: git show of snapshots/disk_snapshot.json in ~/.disk_magician_backup; units size_mb field is KiB-scaled (divide by 2^20 for GiB).
