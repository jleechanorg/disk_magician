# Nextsteps — disk_magician 30d disk-recurrence root cause — 2026-09-11

## Table of contents

- [Executive summary](#executive-summary)
- [Context](#context)
- [Bead index](#bead-index)
- [Work queue](#work-queue)
- [PR / merge state](#pr--merge-state)
- [Learnings pointer](#learnings-pointer)
- [Roadmap pointer](#roadmap-pointer)

## Executive summary

- **Why the disk fills every 3–6 days (+60–100 GiB, 30d sawtooth 726→853 GiB used):** growth is produced by 0–2-day-old agent scratch (`$TMPDIR/T` 63 GiB, `/private/tmp` ~30 GiB, AO/pair worktrees) and one-off evidence dumps (`~/roadmap/.../gemini-memory` 161.5 GiB written in one day by an Opus study run) — all below every reclaim age gate (24h/4h/7d) and outside every ledger key / hot-dir list. Every reset in 30 days was an operator session (~400 GiB); automation reclaimed ~0 per cycle.
- **Why automation never caught it:** snapshot coverage 19.6% (20s per-path cap times out 14 roots incl. `~/projects` 199 GiB and `~/roadmap` 166 GiB); `pressure_sweep`'s `cleanup_tmp.sh` times out on a per-candidate system-wide `lsof +D`; sweeper-health's alert path is `cmux` (absent from launchd PATH); weekly sweeper logs live in `/tmp` and get purged → daily false MISS/reinstall.
- **Pinned + reproduced:** the launchd "mass corruption / flapping" (08-31, 09-06, 09-11) is `plutil -extract <key> <fmt> <plist>` run **without `-o -`**, which overwrites the plist in place. Fixed in PR #69 (fleet check names it; CLAUDE.md rule; findings_wiki; `cleanup_apfs_snapshots.sh` `-o -`; fleet repaired 16/16; 0.2.99 deployed).
- **Top priorities, in order:** (1) merge PR #69; (2) [disk_magician-hyr](https://github.com/jleechanorg/disk_magician/issues?q=disk_magician-hyr) fleet-is-real-again (hash manifest, logs off `/tmp`, wire the existing Slack/SMTP alert); (3) [disk_magician-zyn](https://github.com/jleechanorg/disk_magician/issues?q=disk_magician-zyn) ledger visibility (`~/roadmap` + `~/projects`, partial ledger, `growth-top10`); (4) [disk_magician-dcz](https://github.com/jleechanorg/disk_magician/issues?q=disk_magician-dcz) `lsof` fix + producer fix in worldarchitect.ai; (5) [disk_magician-6wd](https://github.com/jleechanorg/disk_magician/issues?q=disk_magician-6wd) /innov birth-cohort attribution, falsify-first.
- **Risks:** PR #68's unmerged branch had been deployed to production via `uv` as 0.2.98 (now replaced by main+#69 at 0.2.99) — [disk_magician-tli](https://github.com/jleechanorg/disk_magician/issues?q=disk_magician-tli); `frontier-root` still broken pending one `sudo` run ([disk_magician-4y6](https://github.com/jleechanorg/disk_magician/issues?q=disk_magician-4y6)); 2 orphaned MCP servers (8104/8108) still running ([disk_magician-swb](https://github.com/jleechanorg/disk_magician/issues?q=disk_magician-swb)).

## Context

Session 2026-09-11 in `~/projects_other/disk_magician` (branch `fix/plutil-extract-plist-corruption-and-disk-recurrence-report`, PR #69). Followed CLAUDE.md order: fleet check → `/history` + `/ms` (30d) → ledger floor (749 GiB on 09-06, gap +74) → bounded live buckets → 54-agent ultracode swarm (5 miners → 10 claims × 3 refuters → 3 designs → 2 judges → synthesis → 3 innovations × 2 challengers → critic → report). Post-swarm live verification overturned one swarm claim (the 4 corrupt plists were this session's own doing) and pinned the mechanism. Scope: diagnosis, reliability fixes, plan + beads. No deletions; never-delete list and 7-day worktree floor untouched. Full report: `roadmap/2026-09-11-disk-recurrence-rootcause-and-automation.md`; evidence: `roadmap/2026-09-11-disk-recurrence-evidence.md`.

## Bead index

| Bead | Title | Priority / status | Link |
|------|-------|-------------------|------|
| disk_magician-hyr | PR1 fleet-is-real-again: sha256 manifest + registered-AND-valid, redundant fleet check, logs off /tmp, wire alert egress | P2 open | `br show disk_magician-hyr` |
| disk_magician-zyn | PR2 ledger-fresh-and-queryable: partial ledger artifact, `growth-top10`, `~/roadmap`+`~/projects` visibility | P2 open | `br show disk_magician-zyn` |
| disk_magician-dcz | PR3 reclaim-reliability: single `lsof` scan in cleanup_tmp.sh; worldarchitect.ai producer fix (J) | P2 open | `br show disk_magician-dcz` |
| disk_magician-6wd | /innov birth-cohort attribution (`find -newerBt`), falsify-first | P2 open | `br show disk_magician-6wd` |
| disk_magician-tli | Guard: uv tool install only from origin/main HEAD | P2 open | `br show disk_magician-tli` |
| disk_magician-swb | Decision: kill 2 orphaned worldarchitect.ai MCP servers (8104/8108) | P3 open | `br show disk_magician-swb` |
| disk_magician-4y6 | Provision root-owned full-attribution snapshot runner (frontier-root path drift; needs `sudo`) | P1 open (pre-existing) | `br show disk_magician-4y6` |
| disk_magician-lmr | swarm mission bead | closed | `br show disk_magician-lmr` |

(GitHub Issues are not created in default mode; `br show` is the source of truth.)

## Work queue

1. **Merge PR #69** (draft → ready): fleet-corruption fix + report. Acceptance: CI green, `tests/test_check_launchd_fleet.sh` passes, `scripts/sync_package_tree.sh --check` = 0 drift. Overlaps PR #68 on `CLAUDE.md` and `scripts/check_launchd_fleet.sh` (different hunks — #68 adds a ledger-freshness block; #69 adds the `[`/`{` hint). Whichever lands second rebases; version must end > 0.2.99.
2. **[disk_magician-hyr](#bead-index) — make the fleet real again (~11h).** `install_launchd_sweepers.sh` writes a sha256 manifest; `check_launchd_fleet.sh` reports HASH-DRIFT; drilldown job also runs the fleet check; move the 5 weekly-job `StandardOutPath`s from `/tmp/disk-magician-*.log` to `~/Library/Logs/`; replace `command -v cmux` in `sweeper_health_check.sh:239-244` with the already-deployed Slack/SMTP `disk_usage_alert.sh` (reconcile `~/Library/Application Support/user-scope/bin/disk_usage_alert.sh` into the repo, add its LaunchAgent). Acceptance in bead. Depends on: PR #69 merged.
3. **[disk_magician-zyn](#bead-index) — ledger fresh and queryable (~9h).** `ledger/topdown-5g.partial.json` when coverage incomplete (canonical file untouched); `disk_magician.sh growth-top10` (history_diff.py over the 14-day floor, no `du`); add `~/roadmap` and `~/projects` to `config.json.template` monitored_dirs and `disk_observer.py:41-54` DEFAULT_HOT_DIRS with per-key `du` timeout. Acceptance in bead. Independent of #2.
4. **[disk_magician-dcz](#bead-index) — reclaim reliability (~5h + cross-repo).** One upfront `lsof +D /private/tmp` in `cleanup_tmp.sh:243-281`, collapse `TMP_DIRS` to one path, fail closed on lsof failure; file the worldarchitect.ai bead for `run_local_server.sh`/`mcp_dual_background.sh` trap-kill + study output to `$TMPDIR`. Acceptance: 3 consecutive pressure-sweep runs without `rc=124`. Land after #2 so the fleet can prove it.
5. **[disk_magician-6wd](#bead-index) — /innov birth-cohort attribution.** ≤1h falsification probe against the 18.0 GiB anonymous step event at 2026-09-12T00:07:40Z before any build; kill if newborn bytes don't explain a material fraction. Independent.
6. **[disk_magician-tli](#bead-index) — deploy guard.** Refuse `uv tool install` from a non-main / non-origin-HEAD checkout unless explicitly approved; record deployed SHA. Small; can ride with #2.
7. **Operator-only:** `sudo` once for [disk_magician-4y6](#bead-index) (`install_root_frontier_runner.sh`), and decide [disk_magician-swb](#bead-index) (kill PIDs 3842/47420 + parents 2761/45483).

## PR / merge state

- https://github.com/jleechanorg/disk_magician/pull/69 — **PR #69: OPEN** (draft, mergeable, head `d03b385` + this commit)
- https://github.com/jleechanorg/disk_magician/pull/68 — **PR #68: OPEN** (branch `fix/harness-snapshot-floor-gate`, 0.2.98; was deployed unmerged via uv at 13:06)

## Learnings pointer

- `~/roadmap/learnings-2026-09.md` — section `2026-09-11 — Disk recurrence: plutil -extract without -o corrupts live plists; growth lives below every age gate` (🚨 feedback).

## Roadmap pointer

- Appended `roadmap/activity/2026-09-11.md` (new date → link prepended to `roadmap/README.md` § Recent activity).

---

# Nextsteps — design → review → (failed) implementation round — 2026-09-13

## Table of contents (round 2)

- [Executive summary (round 2)](#executive-summary-round-2)
- [Context (round 2)](#context-round-2)
- [Bead index (round 2)](#bead-index-round-2)
- [Work queue (round 2)](#work-queue-round-2)
- [PR / merge state (round 2)](#pr--merge-state-round-2)
- [Learnings pointer (round 2)](#learnings-pointer-round-2)
- [Roadmap pointer (round 2)](#roadmap-pointer-round-2)

## Executive summary (round 2)

- **Done:** 5 parallel /sq design lanes produced specs + executor-grade plans (`docs/superpowers/{specs,plans}/2026-09-11-*`, commit `b5bd0fa`). One combined `/advice` run (Codex + Opus, ref `b5bd0fa`): Codex **REJECTED**, Opus **APPROVED-WITH-CHANGES**; verdict files archived at `docs/superpowers/reviews/2026-09-12-advice-{codex,opus}-designs-b5bd0fa.txt`. Every blocking finding is now in the owning bead.
- **Not done:** implementation. All 4 coder lanes (`agy-pair-coder`) died at spawn on the Fable usage limit; lane worktrees `/tmp/dm-lane-{hyr-fleet,zyn-ledger,dcz-lsof,tli-deploy}` are clean at integration base `4df6cc7` (PR #69 + PR #68). Bead `disk_magician-v4a` routes the next attempt to sonnet/codexs coders.
- **Design corrections that change the plan:** (1) `disk_magician-6wd` is *not* refuted — the lane's probe used UTC strings with BSD `find -newerBt` (local-time parser); Opus's corrected rerun found 3.74 GiB newborn under `/private/tmp` (21% of the 18 GiB event, in a null-`hot_dirs_kb` root). (2) The lsof-snapshot design fails open on non-canonical paths (`/var/folders` vs `/private/var/folders`) and reuses a stale snapshot for destructive decisions. (3) Fleet manifest misses the primary job (created by `disk_magician.sh:130-161`), one planned test can't pass as written, the plan itself invokes bare `uv tool install`, and component E would drop merged #68 code. (4) Deploy-guard override must reject detached HEAD. (5) `check_ledger_freshness.sh` already exists (PR #68 merged) — extend, never recreate; validate schema, not just timestamp.
- **Priority order:** merge PR #69 (now conflict-free at 0.2.101) → fix designs per beads → re-spawn coders on sonnet → hyr → zyn → dcz → tli → 6wd re-probe.

## Context (round 2)

2026-09-12 22:40 → 2026-09-13 10:20 PDT, repo `disk_magician`, branch `fix/plutil-extract-plist-corruption-and-disk-recurrence-report` (PR #69). PR #68 merged mid-session (`be4da3f`, 0.2.100); PR #69 merged `origin/main` back in (version resolved to 0.2.101). Scope: design + review only; no production code changed this round. A sibling session owns the primary checkout; all work went through scratch worktrees.

## Bead index (round 2)

| Bead | Title | Status | Link |
|------|-------|--------|------|
| disk_magician-hyr | PR1 fleet-is-real-again — design reviewed, 6 blocking fixes recorded | open P2 | `br show disk_magician-hyr` |
| disk_magician-zyn | PR2 ledger-fresh-and-queryable — extend #68's freshness checker; schema validation | open P2 | `br show disk_magician-zyn` |
| disk_magician-dcz | PR3 single-lsof — re-snapshot before destructive step; canonicalize paths | open P2 | `br show disk_magician-dcz` |
| disk_magician-tli | deploy guard — reuse `tools/deploy_uv_tool.sh`; reject detached HEAD | open P2 | `br show disk_magician-tli` |
| disk_magician-6wd | birth-cohort attribution — REOPENED, partially validated (3.74 GiB) | open P2 | `br show disk_magician-6wd` |
| disk_magician-v4a | coder lanes died on Fable limit → route to sonnet/codexs | open P2 | `br show disk_magician-v4a` |
| disk_magician-bjk | attribute the 18 GiB anonymous step event (mtime + other roots) | open P2 | `br show disk_magician-bjk` |
| disk_magician-j1c | cleanup_tmp.sh:534 non-additive EXIT trap | open P3 | `br show disk_magician-j1c` |
| disk_magician-swb | orphaned MCP servers 8104/8108 decision | open P3 | `br show disk_magician-swb` |
| disk_magician-4y6 | root frontier runner (needs `sudo`) | open P1 | `br show disk_magician-4y6` |

## Work queue (round 2)

1. **Merge PR #69** — https://github.com/jleechanorg/disk_magician/pull/69 (post-merge at 0.2.101; CI must be green; contains the plutil fix, report, designs, reviews).
2. **Fix each design per its bead's BLOCKING list, then re-review only the changed docs** (`/advice` with the new ref; Codex must move off REJECTED). Owners: hyr, zyn, dcz, tli, 6wd. Acceptance: every BLOCKING item in `docs/superpowers/reviews/2026-09-12-advice-*.txt` has a matching doc change or a written rebuttal.
3. **Re-spawn implementation** ([disk_magician-v4a](#bead-index-round-2)): `general-purpose` subagents, `model: sonnet`, coder + independent verifier per lane, worktrees `/tmp/dm-lane-*` (recreate from `origin/main` after #69 merges). Lane order if serial capacity only: hyr → zyn → dcz → tli.
4. **6wd re-probe** ([disk_magician-6wd](#bead-index-round-2)): local-time `find -newerBt`, fresh step event, 6 bounded roots; decide build/kill in ≤1h.
5. **Operator-only:** `sudo` for [disk_magician-4y6](#bead-index-round-2); decide [disk_magician-swb](#bead-index-round-2).

## PR / merge state (round 2)

- https://github.com/jleechanorg/disk_magician/pull/69 — **PR #69: OPEN** (draft; main merged in, 0.2.101)
- https://github.com/jleechanorg/disk_magician/pull/68 — **PR #68: MERGED** (`be4da3f`)

## Learnings pointer (round 2)

- `~/roadmap/learnings-2026-09.md` — section `2026-09-13 — BSD find -newerBt is local-time; agy-pair-* agent types are Fable-bound`.

## Roadmap pointer (round 2)

- Appended `roadmap/activity/2026-09-13.md` (new date → README link).
