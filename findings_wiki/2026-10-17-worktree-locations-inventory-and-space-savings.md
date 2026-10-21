---
title: Out-of-bounds worktree and clone inventory (1,396 checkouts) and ranked 185+ GiB space reclaim roadmap
hostname: jeffreys-macbook-pro.local
date: 2026-10-17
status: active
paths:
  - ~/.worktrees
  - ~/wf_*
  - ~/wf*_dd
  - ~/wc-wt
  - ~/project_*
  - ~/projects_other
  - ~/Documents/Codex
  - ~/.dark-factory
  - ~/.openclaw_prod_bak
  - /private/tmp/worldai_claw
  - /private/tmp/worldarchitect.ai
  - /private/tmp/_disk_magician_archive
safety_rule: none — central registry and hard 2-root enforcement tracked under beads disk_magician-master-space-saving-roadmap-bv8p and disk_magician-worktree-clone-registry-enforcement-rfng
---

## What

A comprehensive workstation-wide audit identified 1,396 git checkouts (475 linked worktrees and 921 standalone clones) residing across 9 disparate out-of-bounds bucket locations outside the standard `/tmp` and `~/projects` hierarchies. Standalone repositories (`git clone`) created by automated agents and ad-hoc workflows bypass `git worktree list` from primary repos, leaving ~185+ GiB of stranded disk usage unmanaged by standard cleanup scripts.

### Complete Inventory: 9 Out-of-Bounds Buckets (1,396 Checkouts)

Outside `/tmp` and `/Users/jleechan/projects`, checkouts are fragmented across:

1. **Bucket 1: `~/.worktrees` (206 items)**:
   - 206 linked worktrees for `worldarchitect.ai`.
   - Size: ~65–78.6 GiB. Many contain stale merged branches or unpushed WIP commits.

2. **Bucket 2: `~/wf_*` (32 checkouts) and `~/wf*_dd` (3 DerivedData dirs)**:
   - 11 standalone clones (`git clone`) + 21 linked worktrees for workflow sprints (28.6 GiB).
   - 3 custom DerivedData directories (`wf_dd`, `wf_ipad_dd`, `wf_cache_dd` totaling 14.25 GiB).
   - Total bucket footprint: 42.85 GiB.

3. **Bucket 3: `~/wc-wt` (7 items)**:
   - 7 standalone clones used for code-review and advice tasks (7.0 GiB).

4. **Bucket 4: `~/project_*` (35 items across 11 directories)**:
   - 35 checkouts across directories such as `project_a`, `project_b`, etc. (~25 GiB).

5. **Bucket 5: `~/projects_other` (86 items)**:
   - 86 checkouts including `disk_magician` worktrees and standalone tooling repositories (>30 GiB).

6. **Bucket 6: `~/Documents/Codex` (27 items)**:
   - 27 standalone task clones containing heavy `node_modules` across dated execution subdirectories (`2026-10-03`, `2026-10-08`, `2026-10-12`, `2026-10-15`) totaling 14.2 GiB.

7. **Bucket 7: Agent-Internal & Automation Checkouts (804 checkouts)**:
   - `~/.dark-factory`: 482 automated task checkouts.
   - `~/.openclaw_prod_bak`: 306 unmanaged workspace backups.
   - `~/.local/state/ezgha-operations`: 6 runner checkouts.
   - `~/.ao`: 2 worktrees.
   - `~/.claude/worktrees`: 1 worktree.
   - `~/.hermes`: 7 checkouts.

8. **Bucket 8: Secondary `*.worktrees` Directories (22 checkouts)**:
   - `~/worktrees`: 8 checkouts.
   - `~/worldarchitect.ai.worktrees`: 5 checkouts.
   - `~/.worktrees-mctrl`: 3 checkouts.
   - `~/.worktrees-mirror`: 3 checkouts.
   - `~/roadmap.worktrees`: 2 checkouts.
   - `~/llm_wiki.worktrees`: 1 checkout.
   - Total size: ~4.1 GiB.

9. **Bucket 9: `$HOME` Root Scatter (166 checkouts)**:
   - `~/repos`: 7 checkouts.
   - Direct `$HOME/*` linked worktrees: 37 checkouts.
   - Direct `$HOME/*` standalone clones: 122 checkouts (e.g., `cb-wa-*`, advice review checkouts).
   - Total footprint: ~25 GiB.

**Total Count**: 475 linked worktrees + 921 standalone clones = 1,396 checkouts.

---

## Why it matters

Disk usage on the workstation currently sits at ~857 GiB, approximately 76 GiB above the 7-day floor (780.87 GiB) and ~184 GiB above the all-time floor (672.61 GiB). The fragmentation into 9 separate buckets creates two primary systemic risks:

### 1. The Standalone Clone Blind Spot
When an agent or script executes `git clone <url> <path>` instead of `git worktree add`:
- The clone receives a self-contained `.git/` directory and object store rather than a `.git` pointer file (`gitdir: /path/to/main/.git/worktrees/...`).
- Standard repository sweepers (`cleanup_worktrees.sh`, `worktree_reap.sh`, `worktree_hygiene.sh`) inspect worktrees by invoking `git worktree list --porcelain` from primary repositories (e.g. `~/projects/worldarchitect.ai`).
- Because standalone clones have no entry in `git worktree list`, they are 100% invisible to worktree lease tracking, recency auditing, and automated reaping.
- They silently retain duplicate git objects, full dependency trees (`node_modules`, `target`, `venv`), and compiler caches across `~/wf_*`, `~/Documents/Codex`, `~/cb-wa-*`, `~/wc-wt/advice-*`, `/private/tmp/worldai_claw`, `/private/tmp/worldarchitect.ai`, `~/.openclaw_prod_bak`, and `~/.dark-factory`.

### 2. Ranked Reclaim Catalog (~185+ GiB Total Actionable Opportunities)

The following opportunities have been cataloged and ranked by yield and safety:

- **1. `/Users/jleechan/.worktrees` (~65–78.6 GiB across 206 linked worktrees)**
  - Action: Enable and approve `diskm worktree-reap --mode remove` (or `cleanup_worktrees.sh`). For stale unpushed branches, push commits to `refs/wip/*` remote backup refs to satisfy the safety gate without losing work.
  - Reclaim yield: ~30–45 GiB.
  - Tracking bead: `disk_magician-master-space-saving-roadmap-bv8p`

- **2. `/private/tmp` Ephemeral Checkouts and Archives (51 GiB)**
  - Footprint: `/private/tmp/worldai_claw` (21 GiB standalone clones), `/private/tmp/worldarchitect.ai` (16 GiB standalone clones), `/private/tmp/_disk_magician_archive` (14 GiB tarballs).
  - Action: Fix `cleanup_tmp.sh` line 531 `lsof` `f*000` regex bug where open descriptors hold inactive trees; lower protected-root child age and enforce an archive cap (retain max 5 GiB).
  - Reclaim yield: ~30–40 GiB.
  - Tracking bead: `disk_magician-master-space-saving-roadmap-bv8p`

- **3. `~/wf_*` Clones and Custom DerivedData (42.85 GiB)**
  - Footprint: `~/wf_*` (28.6 GiB across 11 standalone clones + 21 worktrees), `~/wf*_dd` (14.25 GiB across `wf_dd`, `wf_ipad_dd`, `wf_cache_dd`).
  - Action: Immediately remove dormant custom DerivedData directories `wf_dd`, `wf_ipad_dd`, `wf_cache_dd` (14.25 GiB immediate). After workflow sprint completion, consolidate and prune the 11 standalone clones.
  - Reclaim yield: ~25–35 GiB.
  - Tracking bead: `disk_magician-master-space-saving-roadmap-bv8p`

- **4. Scattered Project Checkouts & Standalone Duplicates (87+ GiB)**
  - Footprint: `/Users/jleechan/wc-wt` (7.0 GiB), `/Users/jleechan/project_*` (~25 GiB across 11 dirs), `/Users/jleechan/projects_other` (>30 GiB across 86 checkouts), direct `$HOME` checkouts (~25 GiB across 37 worktrees and 122 clones).
  - Action: Consolidate active repos into canonical `~/projects`, prune duplicate standalone advice and code-review clones, run `cleanup_worktree_deps.sh` to strip stale `node_modules` and target directories.
  - Reclaim yield: ~30–40 GiB.
  - Tracking bead: `disk_magician-master-space-saving-roadmap-bv8p`

- **5. `~/Documents/Codex` Task Checkouts (14.2 GiB)**
  - Footprint: 27 task clone folders containing deep `node_modules` from automated agent runs.
  - Action: Strip aged (>7d) task clones and `node_modules` in dated directories `2026-10-03`, `2026-10-08`, `2026-10-12`, and `2026-10-15`.
  - Reclaim yield: ~12 GiB.
  - Tracking bead: `disk_magician-master-space-saving-roadmap-bv8p`

- **6. CoreSimulator, OpenClaw Backups, and Secondary Worktrees (12.3+ GiB)**
  - Footprint: `/Users/jleechan/Library/Developer/CoreSimulator/Devices` (8.2 GiB), `/Users/jleechan/.openclaw_prod_bak` (306 unmanaged workspaces), secondary worktree directories `~/worktrees`, `~/.worktrees-mctrl`, `~/.worktrees-mirror`, `~/roadmap.worktrees` (4.1 GiB).
  - Action: Run `xcrun simctl erase all` / CoreSimulator cache cleanup, sweep stale unmanaged `.openclaw_prod_bak` directories, prune dormant secondary worktrees.
  - Reclaim yield: ~8–12 GiB.
  - Tracking bead: `disk_magician-master-space-saving-roadmap-bv8p`

**Total Actionable Opportunity**: ~185+ GiB.

---

## Guards / governance

Two authoritative tracking beads have been created to govern space reclamation and root sprawl:

1. **Bead `disk_magician-master-space-saving-roadmap-bv8p`**:
   - Master Space-Saving Roadmap & Ranked Reclaim Targets (~185+ GiB).
   - Coordinates the 6 ranked reclaim targets above to return workstation disk usage from ~857 GiB to the 780.87 GiB 7-day floor and toward the 672.61 GiB all-time floor.

2. **Bead `disk_magician-worktree-clone-registry-enforcement-rfng`**:
   - Single Authoritative Worktree & Clone Registry + Hard 2-Root Enforcement.
   - Establishes a canonical repository registry (`config/worktree_roots.json` or `scripts/lib/layout_standard.sh`) and unified scanner in `disk_magician` to record and sweep all legacy checkout locations.
   - Enforces a workstation-wide hard 2-root convention: all NEW checkouts (whether `git worktree add` or `git clone`) must reside strictly within:
     - `/tmp/*` (or `/private/tmp/*`) for ephemeral lanes, scratch checkouts, and automated verifications.
     - `~/projects/*` for durable multi-day worktrees and primary repositories.
   - Enforces guardrails across all coding agent harnesses (Claude, Codex, Pi, Hermes, ChatGPT Desktop) prohibiting ad-hoc directory creation in `$HOME`, `~/Documents`, or custom prefixes.

---

## History

- 2026-10-17 — Discovered 1,396 checkouts (475 linked worktrees, 921 standalone clones) scattered across 9 out-of-bounds buckets. Identified standalone clone bypass mechanism.
- 2026-10-17 — Cataloged ranked ~185+ GiB reclaim opportunities across `.worktrees`, `/private/tmp`, `~/wf_*`, `~/Documents/Codex`, and `$HOME` sprawl.
- 2026-10-17 — Created master roadmap bead `disk_magician-master-space-saving-roadmap-bv8p` and registry enforcement bead `disk_magician-worktree-clone-registry-enforcement-rfng`.
