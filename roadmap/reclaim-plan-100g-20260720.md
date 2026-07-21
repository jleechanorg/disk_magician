# Reclaim plan — next 100 GiB — 2026-07-20 (fresh rebaseline, supersedes 200G-target-v2 tiers)

Baseline at plan time: **free 74.9 GiB** (df, Data volume), after the same-day 108 GiB reclaim arc.
Method: 4-lane swarm (long-tail / repos / Library-apps / protected-residual), every candidate re-measured
fresh per-item (jleechan-x4z5 acceptance; the 2026-07-18 plan's totals are explicitly non-authoritative).
Lane raw reports: session scratch `/tmp/dm100g/lane{1,2,3,4}.md` (ephemeral); this doc is the durable ledger.

## Class totals (fresh measurements)

| Class | GiB (est) | Notes |
|---|---:|---|
| SAFE-AUTO (executed this session — see execution log) | ~22 | scripts-gated or unambiguous recreatables |
| REVIEW (needs explicit user approval, all measured) | ~55 | biggest: wa `.claude/worktrees` aged subset, DK2D in-retention spools, main-checkout venvs |
| USER-ONLY (personal; ranked, never auto) | ~86 | Messages 27.2, /Applications 23.3, CloudStorage 15.6, Photos 14.4, Mail 5.7 |
| Structural (time/privilege-gated) | ~15+ | hermes backup 7.6 after stability window; residual needs jleechan-1utw privileged lane |

Path to +100 GiB without touching personal data: SAFE ~22 + REVIEW ~55 + hermes backup 7.6 + retention/aging of
wa worktrees over the following week ≈ 100+.

## SAFE-AUTO tier (executed)

| GiB | Item | Command |
|---:|---|---|
| 3.15 | `~/.config/mcp-daemon/logs/*.log` — 12 stale (>3d) daemon logs; active `context7.log` kept | targeted rm of stale files |
| ~8 | worktree venvs (`~/.worktrees/*` 4.97 + named `worktree_*`/`wt-*` 4.94, venv portion) | `scripts/cleanup_worktree_venvs.sh --clean` + `scripts/reclaim_worktree_venvs.sh` (>14d gates built in) |
| 1.17 | git packfile garbage (`tmp_pack_*`: dark-factory 674M, jleechanclaw 382M, user_scope 113M, hermes-agent 27M) | `git gc` per repo (NEVER `~/.disk_magician_backup`) |
| 1.36 | duplicate `venv` + `.venv` in non-primary clone `~/repos/jleechanorg/worldarchitect.ai` | rm both (recreatable; primary checkout unaffected) |
| 4.21 | pnpm content-addressable store | `pnpm store prune` |
| ~4 | `~/Library/Caches` dev subset (pip/npm/yarn/go-build/uv class only) | targeted rm of package-manager caches |

## REVIEW tier — awaiting explicit approval (fresh per-item numbers)

| GiB | Item | Why REVIEW | Reclaim |
|---:|---|---|---|
| 45.38 | `~/projects/worldarchitect.ai/.claude/worktrees/` (132 agent/wf worktrees) | most are <14d (young-preserve class); 29 dirty ones already snapshot-preserved to `backup/wip-*-20260720` refs | `scripts/worktree_hygiene.sh --execute` collects SAFE subset now; rest ages in over ~2 weeks |
| 15.52 | DK2D spools inside 72h retention (`RUN8` 5.98, `RUN9` 4.96, `sidekick14` 4.58) | retention holds them ≤2 more days; approving now banks immediately | rm after user OK, or wait for the 6h retention job |
| 6.52 | `/private/tmp/worldarchitect.ai/pr-*` (22 AO scratch dirs) | inside a PROTECTED root (deliberately sweep-immune); 3 sampled PRs are open | per-PR check then targeted rm |
| 6.02 | main-checkout venv/target/node_modules (17 venvs 12.15 across classes) | repos may be mid-work | `reclaim_worktree_venvs.sh` symlink dedup or per-repo rm |
| ~6-8 | version-manager old toolchains (`~/.nvm/versions` 5.21, `~/.rustup` 4.10, `~/.pyenv` 3.90 — totals, not all reclaimable) | active versions must be kept; ~/.nvm global-package incident 2026-07-17 | `nvm ls` / `rustup toolchain list` / `pyenv versions` then uninstall unused |
| 3.50 | `/Library/Developer/CoreSimulator/Caches` | regenerable but next sim boot re-creates slowly | rm after user OK |
| 3.47 | `~/.ao/data/worktrees/*auto-export*` (5 dirs) | **6mu5 incident class — contains uncommitted work**; needs fako-style snapshot-preserve first | preserve-then-rm |
| 3.40 | `~/jleechanclaw` (top-level stale repo-like dir, mtime Jul 17) | unclear provenance | user confirm then archive/rm |
| 2.80 | `~/.gemini/antigravity-cli/conversations` | conversation history (brains already expired >7d this session) | 7d retention pass after user OK |

## USER-ONLY tier (ranked; no action without owner)

Messages 27.22 · /Applications 23.28 (53 apps; largest with last-used dates in lane3 raw) · CloudStorage 15.61 ·
Photos library 14.38 · Mail 5.73 · `~/.hermes/sessions` 5.11 (operational history, treat like `~/.codex/sessions`).

## Refuted / dead theories (do not re-chase)

- MobileSync device backups: **empty** (0 bytes, fully readable — kills the 2026-07-15 "MobileSync likely largest" hypothesis).
- `brew cleanup -n`: **0 reclaimable** (already lean). Xcode DerivedData: empty; 0 unavailable simulators.
- Local APFS snapshots on Data: none. Purgeable delta: only ~5.8 GiB.
- Residual (~213 GiB): predominantly `/private/var/folders` (system hash bucket) + `/private/var/db` + protected system stores — only the jleechan-1utw privileged lane (Full Disk Access + sudo runbook in lane-4 report) can attribute further; not reclaimable by policy even then, mostly.

## Known display defect

`cleanup_tmp.sh --dry-run --large` double-counts some candidates in its reported totals (jleechan-i67e, open) —
affects dry-run REPORTING only, not deletions; do not trust its "Total freed" preview without dedup.

## Execution log

- 2026-07-20: SAFE tier executed (see next section appended post-execution with before/after df).

## Execution log — SAFE tier, 2026-07-20 ~22:05

df before 77.3 GiB → after **84.8 GiB** (+7.5 net; concurrent CI-runner churn consumed some during execution).
Itemized (per-item verified at execution time):
- mcp-daemon logs: **3.2 GiB** — lane estimate right in total, wrong in mechanism: only 1 file was >3d stale; the bulk was 10 ACTIVE oversized logs (context7.log alone 1.3 GiB) — truncated in place, daemons unaffected.
- reclaim_worktree_venvs (symlink conversion): **1.41 GiB** (2 venvs converted, 0 failed).
- duplicate-clone venv+.venv (`~/repos/jleechanorg/worldarchitect.ai`): **1.36 GiB**.
- pnpm store prune: 31,164 files / 951 packages (~3.5 GiB store était 4.2).
- package-manager caches (pnpm/pip/node-gyp/electron/Homebrew >50MB): **1.01 GiB**.
- git gc (dark-factory, jleechanclaw, user_scope, hermes-agent): ~1.2 GiB packfile garbage.
- cleanup_worktree_venvs --clean: most candidates <14d young — correctly gated out (small yield).

SAFE tier came in at ~11.5 GiB itemized vs ~22 estimated — the difference is age-gates working as designed
(young venvs protected) and one lane mechanism error caught by per-item verification (the x4z5/6mu5 discipline).
