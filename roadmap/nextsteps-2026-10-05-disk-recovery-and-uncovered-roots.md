# Nextsteps — disk_magician — 2026-10-05

## Table of contents

- [Executive summary](#executive-summary)
- [Context](#context)
- [Bead index](#bead-index)
- [Work queue](#work-queue)
- [Timeline and parallel lanes](#timeline-and-parallel-lanes)
- [PR / merge state](#pr--merge-state)
- [Learnings pointer](#learnings-pointer)
- [Roadmap pointer](#roadmap-pointer)

## Executive summary

- **Disk Recovery & Floor Grounding:** Workstation Data volume recovered from a peak pressure of 876 GiB used (7–10 GiB available, 97% capacity) down to 844 GiB used and 33 GiB available (+23 to +26 GiB net free space). Grounded against the 3-day snapshot floor of 843–849 GiB (2026-10-04 23:34Z snapshot `116dbd0` measured 843 GiB used, 38 GiB free; 2026-10-05 00:58Z snapshot `150880e` measured 847 GiB). Live used of 844 GiB sits within 1 GiB of the 3-day floor.
- **Routine Maintenance Execution:** Safe multi-tier cleanup reclaimed ~56.5 GiB across six vectors: ~19 GiB dormant worktrees older than 7d recency floor, ~17.8 GiB Claude state task scratches, 4.9 GiB /private/tmp test clones, 12.9 GiB Colima container prune & in-VM fstrim, 1.2 GiB dev caches, and 762 MB Trash venv.
- **Automation Fleet Status:** Evaluated launchd fleet via ./disk_magician.sh check-launchd-fleet: 18/18 jobs loaded and valid. 24-hour observation milestone recorded on bead disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.2 verifying stable operation of deployed v0.2.128.
- **Identified Gap & Bead Created:** Discovered that Google Chrome helper and update relaunches generate 4–6 code_sign_clones per day (~2.2 GiB each, accumulating 25–30 GiB). While reactive cleanup is wired into pressure_sweep.sh step 3 (PR #84 open), no proactive periodic sweeper exists to prevent accumulation before the 40 GiB pressure gate triggers. Filed new bead disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.3 to provision a dedicated periodic launchd job.
- **Uncovered Roots Monitoring:** PR #103 and PR #102 merged to main; feature branch feat/monitor-uncovered-roots-20261004 added commit 9b157c8 (config registration for agent roots) and commit ccb0124 (wiring cleanup-code-sign-clones dispatch in diskm CLI).

## Context

During intense overnight multi-agent testing across worldarchitect.ai and related repositories, workstation disk consumption surged to 876 GiB on /System/Volumes/Data, leaving 7–10 GiB free and triggering system pressure. A multi-tier safe cleanup was executed adhering strictly to all repo safety invariants (including the mandatory 7-day recency floor for git worktrees, in-VM Colima fstrim, and lossless compaction).

The primary operational entry point is diskm (/Users/jleechan/projects_other/disk_magician/disk_magician.sh). Recent PRs #101, #102, and #103 established compiled FDA root launching, state-dir candidate persistence, and monitoring of uncovered agent workspaces. This sync performs the situational assessment, 24-hour reliability review, bead and roadmap synchronization, and plans the remaining code-sign-clone automation and open PR rebases.

## Bead index

| Bead | Title | Priority | Status | Link |
|---|---|---|---|---|
| disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.3 | Provision periodic launchd sweeper for Chrome/Aside code-sign-clone cleanup | P2 | OPEN | [disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.3](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.2 | Observe 24-hour and seven-day disk reliability outcomes after verified deployment | P1 | OPEN | [disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.2](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-disk-fill-prevention-scheduled-cleanup-q6l | EPIC: Disk-fill prevention and automatic periodic cleanup via launchd | P1 | IN_PROGRESS | [disk_magician-disk-fill-prevention-scheduled-cleanup-q6l](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-pressure-sweep-codesign-impl-371 | IMPL: pressure_sweep.sh step 3 code-sign-clone reclaim | P2 | OPEN | [disk_magician-pressure-sweep-codesign-impl-371](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-pressure-sweep-codesign-test-w5e | TEST: pressure_sweep.sh code-sign-clone step assertions | P2 | OPEN | [disk_magician-pressure-sweep-codesign-test-w5e](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-i56 | IMPL: snapshot timeout reliability (parallel measure, honest timeouts, carry-forward) | P1 | OPEN | [disk_magician-i56](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-4y6 | Provision root-owned full-attribution snapshot runner with Full Disk Access | P1 | OPEN | [disk_magician-4y6](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-dbp | rebase + version-bump open PRs after #90 | P1 | OPEN | [disk_magician-dbp](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-xqm | dropbox dedup: finish hash-verified deletions | P1 | OPEN | [disk_magician-xqm](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-e50 | backups: Dropbox full (2.006/2.006 TiB) | P1 | IN_PROGRESS | [disk_magician-e50](https://github.com/jleechanorg/disk_magician/issues) |
| disk_magician-d45 | $TMPDIR (/var/folders/.../T) agent scratch leaks | P1 | OPEN | [disk_magician-d45](https://github.com/jleechanorg/disk_magician/issues) |

## Work queue

1. **Deploy Periodic Launchd Sweeper for Code-Sign-Clones**
   - **Goal:** Automate regular periodic cleanup of unmapped Chrome and Aside code_sign_clones so they do not accumulate to 25–30 GiB between browser restarts.
   - **Tracks:** [disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.3](https://github.com/jleechanorg/disk_magician/issues)
   - **Files:**
     /Users/jleechan/projects_other/disk_magician/launchd/com.disk-magician.code-sign-clones.plist.template
     /Users/jleechan/projects_other/disk_magician/scripts/install_launchd_sweepers.sh
     /Users/jleechan/projects_other/disk_magician/scripts/cleanup_code_sign_clones.sh
   - **Acceptance criteria:**
     - Add launchd template invoking `diskm cleanup-code-sign-clones` with `CODE_SIGN_CLONES_APPROVED=1`.
     - Register the job in `scripts/install_launchd_sweepers.sh` with a 12-hour or daily interval.
     - Verify job installation and validate fleet check reports 19/19 loaded and healthy.
   - **Dependencies:** Branch `feat/monitor-uncovered-roots-20261004` (commit ccb0124) landed diskm CLI dispatch.

2. **Rebase & Land Open PR Fleet (PR #84, #86, #85, #81, #80, #77)**
   - **Goal:** Unblock and land open feature PRs that were held behind snapshot reliability PR #90 and version-monotonic check.
   - **Tracks:** [disk_magician-dbp](https://github.com/jleechanorg/disk_magician/issues), [disk_magician-pressure-sweep-codesign-impl-371](https://github.com/jleechanorg/disk_magician/issues)
   - **Files:**
     /Users/jleechan/projects_other/disk_magician/pyproject.toml
     /Users/jleechan/projects_other/disk_magician/scripts/pressure_sweep.sh
     /Users/jleechan/projects_other/disk_magician/scripts/sweeper_health_check.sh
     /Users/jleechan/projects_other/disk_magician/scripts/residual_drilldown.sh
   - **Acceptance criteria:**
     - Rebase branches on origin/main (currently at v0.2.132 post PR #103).
     - Ensure pyproject.toml version strictly increments monotonically.
     - Land PR #84 (pressure-sweep step 3 code-sign-clone reclaim).
   - **Dependencies:** PR #103 merged on main.

3. **Complete 20-Run Acceptance for Snapshot Measurement (Bead i56)**
   - **Goal:** Conclude formal acceptance for bounded parallel snapshot measurement under sustained machine load.
   - **Tracks:** [disk_magician-i56](https://github.com/jleechanorg/disk_magician/issues)
   - **Files:**
     /Users/jleechan/projects_other/disk_magician/src/disk_magician/snapshots.py
     /Users/jleechan/projects_other/disk_magician/scripts/disk_snapshot.sh
   - **Acceptance criteria:**
     - Record 20 consecutive scheduled runs of diskm snapshot under live load.
     - Zero unhandled timeout exceptions or zombie measurement workers.
     - Close bead disk_magician-i56 upon verified proof.

4. **Observe 7-Day Recurrence Window (Bead q6l.2)**
   - **Goal:** Track workstation disk growth rate, fleet health, and recurrence over the 7-day window.
   - **Tracks:** [disk_magician-disk-fill-prevention-scheduled-cleanup-q6l.2](https://github.com/jleechanorg/disk_magician/issues)
   - **Review milestones:** 24h milestone completed 2026-10-05T01:26:27Z; 7d review due 2026-10-11T01:26:27Z.
   - **Acceptance criteria:**
     - Maintain launchd fleet 100% loaded and valid without silent unloading or plist corruption.
     - Document physical disk delta vs 844 GiB baseline.

## Timeline and parallel lanes

| Elapsed estimate | Lane / owner | Scope / dependencies | Deliverable / proof |
|---|---|---|---|
| 0–30m | Lane A (Code-Sign Sweeper) | launchd template + installer registration | com.disk-magician.code-sign-clones.plist.template + fleet 19/19 test |
| 30–60m | Lane B (PR Rebases) | Rebase PR #84, #86, #85 on main v0.2.132 | Green CI and monotonic version bumps on open PRs |
| Day 1–7 | Lane C (Recurrence Watch) | Periodic diskm status & df tracking | 7-day observation report on 2026-10-11 for bead q6l.2 |

- **Critical path:** Lane A (code-sign-clone accumulation prevention) is the highest-yield preventative automation gap.
- **Concurrency ceiling:** Local workstation load is moderate (~20–30 loadavg). Edits to launchd and scripts are lightweight.
- **Milestones:** Review every 20 minutes; hourly rollup while active.

## PR / merge state

- https://github.com/jleechanorg/disk_magician/pull/103 — MERGED (feat: monitor uncovered agent-workspace roots; scope fsevents ownership)
- https://github.com/jleechanorg/disk_magician/pull/102 — MERGED (fix: write drilldown candidates to state dir, not package tree)
- https://github.com/jleechanorg/disk_magician/pull/101 — MERGED (feat: run root frontier daemon via compiled diskm FDA launcher)
- https://github.com/jleechanorg/disk_magician/pull/100 — MERGED (docs: record scheduled root daemon TCC denial evidence)
- https://github.com/jleechanorg/disk_magician/pull/99 — MERGED (docs: limit finding to directly evidenced root preflight outcomes)
- https://github.com/jleechanorg/disk_magician/pull/90 — MERGED (feat: bounded parallel snapshot measurement, carry-forward and honest coverage)
- https://github.com/jleechanorg/disk_magician/pull/84 — OPEN (feat: pressure_sweep.sh step 3 code-sign-clone reclaim)
- https://github.com/jleechanorg/disk_magician/pull/86 — OPEN (feat: residual_drilldown.sh uncovered-roots alert)
- https://github.com/jleechanorg/disk_magician/pull/85 — OPEN (feat: sweeper_health_check.sh ledger-freshness WARN)
- https://github.com/jleechanorg/disk_magician/pull/81 — OPEN (fix: scratch_budget.sh excludes TemporaryItems from eviction)
- https://github.com/jleechanorg/disk_magician/pull/80 — OPEN (feat: additive non-file signals in 35-min snapshot + swing correlator)
- https://github.com/jleechanorg/disk_magician/pull/77 — OPEN (feat: publish partial ledger + extend freshness gate for stale canonical)
- https://github.com/jleechanorg/disk_magician/pull/87 — OPEN (ci: migrate macOS 14 runner to macOS 15)

## Learnings pointer

- /Users/jleechan/roadmap/learnings-2026-10.md — section "2026-10-05 — Workstation disk recovery, 24h fleet observation, and code-sign-clone periodic automation gap"

## Roadmap pointer

- /Users/jleechan/projects_other/disk_magician/roadmap/activity/2026-10-05.md appended with session details.
- /Users/jleechan/projects_other/disk_magician/roadmap/README.md prepended with 2026-10-05 date link in Recent activity (by day).

---

# Session block 2 — 2026-10-05 (retention-gate audit + worktree discovery blind spot)

## Table of contents

- [Block 2 executive summary](#block-2-executive-summary)
- [Block 2 context](#block-2-context)
- [Block 2 bead index](#block-2-bead-index)
- [Block 2 work queue](#block-2-work-queue)
- [Block 2 timeline and parallel lanes](#block-2-timeline-and-parallel-lanes)
- [Block 2 PR / merge state](#block-2-pr--merge-state)
- [Block 2 learnings pointer](#block-2-learnings-pointer)
- [Block 2 roadmap pointer](#block-2-roadmap-pointer)

## Block 2 executive summary

- **Full safe-clean sweep reclaimed ~0 GiB, by design.** Ran worktrees, Claude state, tmp, PR scratch, dev caches, codex DB vacuum, hermes WAL, aside, brain, dark-factory, code-sign-clones, APFS snapshots. Every candidate was inside its retention window or blocked by a safety gate. The gates are working; there is no junk left to sweep.
- **Root cause of regrowth: retention gates protect active work, but nothing caps active work.** The 7d worktree floor plus the clean+merged bar means a worktree holding any untracked content is *immortal* — it fails the gate forever. Confirms and extends `disk_magician-ueh` (2026-10-03: 136 worktrees / 47 GiB, 0 eligible).
- **NEW finding — worktree discovery blind spot.** `cleanup_worktrees.sh` scanned only `~/projects`, `~/.ao/data/worktrees`, `~/.gemini/antigravity/worktrees`, and the nested `worldai_claw`. It never scanned `~/wc-wt` (24 GiB) or `~/project_worldaiclaw` (42 GiB) — **66 GiB never reached triage**. Fixed with a 2-line discovery registration; verified those worktrees now appear in triage output. Filed `disk_magician-663`.
- **Pressure sweep is a no-op under pressure.** All three steps fail: `cleanup_tmp.sh` rc=124 (timeout), `cleanup_colima.sh` rc=1 (Docker daemon unreachable), only code-sign-clones runs. Tracked by `disk_magician-3ma` and `disk_magician-i56`.
- **Colima is wedged.** 20.0 GiB `_lima`, `docker system df` times out at 5s, daemon unreachable, recovery gated behind `VACATE_CI_RUNNERS_APPROVED=1` (unset, operator decision). The VM burns ~166% CPU serving a dead daemon, which is *why* `cleanup_tmp` times out and pressure-sweep fails — the wedge and the sweep failure share one cause.
- **Out of scope but adjacent:** `worldarchitect.ai` agent-instruction consolidation (AGENTS.md canonical, GEMINI.md reduced 26→13 lines, `.gemini/tmp/` routed to `/tmp/worldarchitect.ai/...`). Committed and pushed there by a Gemini session as branch `docs/consolidate-agent-md-tmp`; no PR yet. Per that repo's `AGENTS.md:85` it is **not** exempt from independent review.

## Block 2 context

A second cleanup pass on the same workstation after the first block's ~56.5 GiB reclaim. Goal was "cleanup some safe disk." The measurable outcome is negative and that is the finding: the safe surface is exhausted. Fleet check passed (19/19 loaded), so this is not a dead-collector incident. Disk oscillated 1.9 ↔ 33 GiB free during the session against a 926 GiB volume at 97–100% capacity, with load average peaking at 200 on 14 cores. Free-space swings are *not* reclaim and must not be reported as such — an intermediate reading of 33 GiB after a dry-run was initially misread as a win and corrected.

Last *complete* ledger coverage scan was 2026-08-31 (35 days); every scan since is partial (11/17 roots), so current coverage 36.5% is below the hard 70% floor and cannot serve as a measurement floor.

## Block 2 bead index

| Bead | Title | Priority | Status | Link |
|---|---|---|---|---|
| disk_magician-663 | cleanup_worktrees.sh: discovery blind spot — `~/wc-wt` + `~/project_worldaiclaw` never scanned (66 GiB untriaged) | P1 | OPEN | `br show disk_magician-663` |
| disk_magician-ueh | classify squash-merged PR worktrees as eligible instead of `ahead-of-main` PRESERVE | P2 | OPEN | `br show disk_magician-ueh` |
| disk_magician-3ma | Bound Docker health probes so routine cleanup cannot stall | P2 | IN_PROGRESS | `br show disk_magician-3ma` |
| disk_magician-i56 | IMPL: snapshot timeout reliability (parallel measure, honest timeouts, carry-forward) | P1 | OPEN | `br show disk_magician-i56` |
| disk_magician-rpv | Attribute bidirectional df swings via APFS purgeable, snapshots, swap/VM volume, Colima diffdisk | P2 | OPEN | `br show disk_magician-rpv` |
| disk_magician-0si | harness: coverage_streak resets on any good run; playbook never checks coverage mode | P2 | OPEN | `br show disk_magician-0si` |

## Block 2 work queue

1. **Land the worktree discovery fix** — tracks [disk_magician-663](br)
   - **Goal:** make `~/wc-wt` and `~/project_worldaiclaw` visible to worktree triage.
   - **State:** 2-line change already applied to `scripts/cleanup_worktrees.sh` (adds two `find_repos_from_worktrees` calls). `bash -n` clean. Verified those worktrees now appear in triage output.
   - **Acceptance:** repo test suite passes; the 66 GiB roots appear in `cleanup-worktrees` triage; no new `Repo missing or not a git checkout` noise (an earlier revision registered both dirs as repo roots, which was a no-op because neither is itself a git checkout, and was removed).
   - **Note:** registration alone does not reclaim — all newly-visible worktrees are `untracked`/`ahead-of-main` PRESERVE. This fix restores *visibility*; reclamation depends on item 2.

2. **Resolve the immortal-dirty-worktree class** — tracks [disk_magician-ueh](br)
   - **Goal:** stop worktrees with untracked/ahead content from being permanently unprunable.
   - **Evidence:** 6 newly-visible `project_worldaiclaw` worktrees, 18–22d old, ~6 GiB, all PRESERVE on `untracked`/`ahead-of-main`. Earlier measurement (ueh): 136 worktrees / 47 GiB / 0 eligible.
   - **Acceptance:** gh-verified merged-same-head rule in `classify_candidate`, keeping the 7d floor and all dirty/stash/cwd checks, failing closed on `gh` errors, with an unmeasurable-`gh` test case.

3. **Un-wedge Colima (operator decision — needs `VACATE_CI_RUNNERS_APPROVED=1`)** — related [disk_magician-3ma](br)
   - **Goal:** restore the Docker daemon so pressure-sweep step 2 can reclaim.
   - **Acceptance:** `docker system df` returns without a 5s timeout; `colima _lima` drops below 20 GiB after prune + in-VM `fstrim -av`; `cleanup-colima --clean` exits 0.
   - **Blocked on:** operator approval. Not agent-actionable unattended.

4. **Restore complete ledger coverage** — tracks [disk_magician-i56](br), [disk_magician-0si](br)
   - **Goal:** a complete (17/17 roots) snapshot so floor accounting and trend alerting are trustworthy again.
   - **Acceptance:** one `topdown-5g.json` commit with `mode: complete` and `coverage_envelope.complete: true`; `diskm history diff --days N` usable without the 70% floor caveat.

## Block 2 timeline and parallel lanes

| Elapsed estimate | Lane / owner | Scope / dependencies | Deliverable / proof |
|---|---|---|---|
| ~5m | root session | fleet check, ledger floor, snapshot coverage gate | `check-launchd-fleet` 19/19; floor 843.55 GiB @ 2026-08-31 |
| ~20m | root session (parallel) | 12 safe cleanup vectors | all exit 0, ~0 GiB reclaimed |
| ~10m | root session | sweeper-health + pressure-sweep log triage | 7 WARN sweepers; rc=124 / rc=1 |
| ~15m | root session | discovery gap + 2-line fix + verify | triage output shows new roots |

- **Critical path and concurrency ceiling:** item 3 (Colima) unblocks the most reclaim, but needs operator approval. Items 1 and 2 are agent-actionable and independent.
- **Measured resource bound:** load average 200 on 14 cores (~14×) at peak; CPU-bound, not memory-bound. Per the CPU tier, `/dot` delegation and local test suites were correctly skipped in favour of local minimal-cost work; `/dot` itself failed twice (`chrome_rc=124`) because Chrome could not load a page under that load.
- **Milestones:** +20m, +40m, +60m (hourly rollup), then repeat while active.
- **Execution start:** pending authorized resumption; this handoff does not start it.

## Block 2 PR / merge state

- https://github.com/jleechanorg/disk_magician/pull/104 — MERGED (`86047a3`, code-sign-clones launchd sweeper)
- https://github.com/jleechanorg/disk_magician/pull/105 — MERGED (`6b0eddb`, query-only dry-run vacuum + lsof tag)
- https://github.com/jleechanorg/disk_magician/pull/107 — MERGED (`f672bbd`, standard worktree root and evidence location; carries discovery fix for ~/wc-wt and ~/project_worldaiclaw)
- Deployed: `disk-magician 0.2.133` via `tools/deploy_uv_tool.sh` (`~/.disk_magician_state/deployed.json`).
- Lane B completed: PreToolUse hooks registered in `~/.claude/settings.json` and `~/.codex/hooks.json`; `path-deletion-guard.py` verified; `~/.codex/AGENTS.md` spec D7 policy added; bead `disk_magician-codex-agents-md-scratch-policy-2gp` closed; skills updated.

## Block 2 learnings pointer

- `~/roadmap/learnings-2026-10.md` — section `2026-10-05 — Retention gates are not a regrowth fix`.

## Block 2 roadmap pointer

- Appended `roadmap/activity/2026-10-05.md` (date file already existed; README not touched).
