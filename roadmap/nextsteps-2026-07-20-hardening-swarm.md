# Nextsteps — disk_magician hardening + reclaim arc — 2026-07-20

## Table of contents

- [Executive summary](#executive-summary)
- [Context](#context)
- [Bead index](#bead-index)
- [Work queue](#work-queue)
- [PR / merge state](#pr--merge-state)
- [Learnings pointer](#learnings-pointer)
- [Roadmap pointer](#roadmap-pointer)

## Executive summary

- **Reclaimed ~108+ GiB in one arc**: free space went 11.3 GB → ~126 GiB. Sources: 8 DK2D evidence runs (~50 GiB), 6 older sidekick spools (41.3 GiB), 389 Antigravity brain dirs >7d (16.9 GiB), 47 clean/pushed worktrees, tmp scratch.
- **Root cause of the 2026-07-19 +92 GiB day**: DK2D evidence-gate harness (worldarchitect.ai) spooling 5–8 GiB/run into `~/Downloads` (a sweeper blind spot), plus /private/tmp churn and a staged macOS update. Fully attributed; not Colima.
- **Eight prevention layers now merged AND deployed (v0.2.41, smoke-verified)**: Downloads evidence retention (6h launchd), archive hard cap, Colima + /private/tmp proactive size ceilings, deploy guard + post-deploy smoke, disk_audit category-failure surfacing, worktree ahead-count sanity cap, Hermes prompt reclaimer.
- **Branch protection live**: `Test and lint` + `Evidence Gate` required on `main`; force-pushes/deletions blocked.
- **Blocked / human-decision items**: 9 real-work worktrees, PR #21 owner rebase, `jleechan-nwrk` (P0), optional ~1.9 GiB live Hermes reclaim.
- Key beads: [jleechan-fako](https://github.com/jleechanorg/disk_magician) (worktree keeps), jleechan-nwrk (launchd creds), jleechan-dqiz (AO tmp root fix), jleechan-rvqz (top-down default).

## Context

Session 742600d0 (2026-07-19 → 07-20, repo `disk_magician`, all work on `main` + short-lived PR branches). Arc: PR #28 review → deploy-chain verification → disk regrowth attribution → 108 GiB reclaim → prevention-gap mining swarm (workflow `wf_6ba0ec09-2ab`, 78 findings over 8 memory/history sources) → 5-teammate fix swarm (mission bead `jleechan-9gw7`) → serial integration with cross-model (gemini) adversarial review. Production tool now at **v0.2.41**, deployed via `tools/deploy_uv_tool.sh` (guard + smoke).

## Bead index

Open beads relevant to this arc (all `br show <id>` from repo root; no GitHub Issues sync on this repo):

| Bead | Pri | Title / state |
|------|-----|---------------|
| jleechan-fako | P2 | Triage remainder: **9 REAL-WORK-KEEP worktrees** (live modified/untracked files) — report at `/tmp/wt_triage_report.txt`; 23 deleted, 16 branches preserved this session |
| jleechan-nwrk | P0 (BLOCKED) | GitHub credential env vars leaking into user launchd domain — blocked upstream, not disk_magician-scoped |
| jleechan-dqiz | P1 | AO /private/tmp scratch root fix (register-on-start + dead-PID sweep) — belongs in Agent Orchestrator; disk_magician fallback ceiling shipped in #38 |
| jleechan-rvqz | P1 | Make full top-down disk accounting the default diagnostic |
| jleechan-wy3s | P0 | colima-trim-guard shlock stale-lock (ezgha tree, partially fixed per 07-17 memory — re-verify before work) |
| jleechan-zxhf | P1 | colima-trim-guard 75s outer timeout repeated fires (ezgha tree) |
| jleechan-k2qf | P1 | worktree_hygiene branch_for_worktree SIGPIPE — NOTE: may be already fixed by the #40-era refactor; verify against `88718b0` before implementing |
| jleechan-rx6v | P1 | host-disk-guardian log leaks plaintext PATs |
| jleechan-etjw | P1 | Colima inflation during ezgha churn — largely mitigated by #37/#38 ceilings; re-measure before further work |

Closed this session with evidence (for the record): jleechan-m4yc, uwtk, 7jq3, mtow, uio3, zx7g, rq9j, m8um, aoja, pqhb, dz94, bb3a, 70fi, 9gw7, 1es6, 17qi.

## Work queue

1. **Triage the 9 real-work worktrees** — tracks jleechan-fako. Read `/tmp/wt_triage_report.txt` REAL-WORK-KEEP rows (regenerate: `bash scripts/worktree_hygiene.sh --skip-push --skip-gh`); per worktree decide commit/PR/discard. Acceptance: each of the 9 dispositioned; bead closed. Needs human judgment on worldarchitect.ai + jleechanclaw dirty lanes.
2. **Optional live Hermes reclaim (~1.9 GiB)** — follow-on to closed jleechan-m8um. Run `bash scripts/dedup_hermes_prompts.sh ~/.hermes/state.db` (dry-run), review report, then `--apply` (auto-backs-up, refuses without 2× free space). Acceptance: state.db shrinks post-VACUUM; Hermes gateway still functions.
3. **PR #21 owner rebase** — 35-file safety-harness PR, CONFLICTING; triage note already on the PR (needs rebase over #28/#34/#35+, Evidence template fields, required checks). Acceptance: PR green or closed-superseded.
4. **Verify-then-fix the possibly-stale beads** — jleechan-k2qf (SIGPIPE) and jleechan-etjw (Colima inflation) may be overtaken by #37/#38/#40; re-verify against main `88718b0` and close-as-fixed or implement. Small.
5. **jleechan-rvqz top-down default** — larger design item; frontier scan machinery exists (`scripts/disk_frontier_scan.py`), needs wiring as default diagnostic per the bead.
6. **Watch the new guards' first live fires** — `~/Library/Logs/disk-magician-pressure-sweep.log` for `colima-only`/`tmp-only sweep triggered` lines and `disk-magician-downloads-evidence.log` for the first retention expiry (3 spools currently inside the 72h window will age out). No code work unless a guard misbehaves.

## PR / merge state

Verified via `gh` this run:

- https://github.com/jleechanorg/disk_magician/pull/21 — **OPEN** (conflicting, owner rebase required)
- PRs #28, #31, #34, #35, #36, #37, #38, #39, #40 — **MERGED** (main tip `88718b0`, v0.2.41 deployed, smoke=ok)
- PR #9 — **CLOSED** (superseded by #36); PR #1 — **CLOSED** (stale, unmerged)

## Learnings pointer

- `~/roadmap/learnings-2026-07.md` — section `2026-07-20 — Hardening arc: cross-model review catches what 26 same-model agents missed; tail -1 masks push rejections; Evidence Gate needs inline field values`.

## Roadmap pointer

- Appended `roadmap/activity/2026-07-20.md` (new date file) and prepended the date link to `roadmap/README.md` § Recent activity.
