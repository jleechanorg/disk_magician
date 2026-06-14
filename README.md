# Disk Magician 🪄

`disk_magician` is a generalized, zero-dependency utility to analyze local disk usage, validate snapshots, identify bloat (orphaned worktrees, caches, stale temp files), and run automated backup/history tracking using a serverless Git repository.

Designed to work across macOS and Linux, it can be exposed as a skill/plugin for various agent environments (Claude, Codex, Hermes, Openclaw).

---

## Features

- 🔍 **Diagnostics & Audit**: Quick summary of APFS/Ext4 volumes, top directories, and actionable cleanup recommendations.
- 🕒 **Historical Trends**: Reads git history of your snapshots to show growth patterns and regressions over time.
- 🧹 **Orphaned Worktree Cleanup**: Dynamically discovers and deletes orphaned Git worktrees (saving gigabytes of dead venvs/node_modules) without hardcoding repository paths.
- 🗑️ **Temporary & Cache Purge**: Safely removes stale git clones, debug logs, and build/package manager caches older than a configurable threshold.
- 📦 **Automated Snapshot Backups**: Self-configures a local and remote backup repository (`disk_backup`) and registers launchd/cron schedules to push snapshot JSON updates every 30 minutes.

---

## Installation & Setup

To get started, clone the repository and run:

```bash
./disk_magician.sh setup
```

This command will:
1. Initialize/configure your local backup directory (default: `~/.disk_magician_backup`).
2. Offer to automatically create a corresponding `disk_backup` remote repository on GitHub using `gh`.
3. Register a recurring scheduler (a macOS launchd daemon or a Linux cron job) to capture snapshots every 30 minutes and push them.

---

## Usage CLI

```bash
# Audits current disk usage and recommends cleanups
./disk_magician.sh audit

# Preview safe targets to be cleaned
./disk_magician.sh clean --dry-run

# Execute cleanup of safe targets (temp files, cache)
./disk_magician.sh clean

# Interactively clean larger/destructive targets (Docker VMs, old sessions)
./disk_magician.sh clean-all

# Shows historical growth trends from the git log of your snapshots
./disk_magician.sh history

# Scan home folder for directories > 5 GB not currently monitored
./disk_magician.sh discover
```

---

## Agent Integrations

Detailed skills/plugin specifications are available under `skills/`:
* `skills/claude/SKILL.md` (for Claude Code)
* `skills/codex/SKILL.md` (for Codex)
* `skills/hermes/SKILL.md` (for Hermes)
* `skills/openclaw/SKILL.md` (for Openclaw)

---

## Regrowth Prevention Series (PRs 1–4)

Four PRs land together to prevent the disk-fill recurrence pattern that
caused this series to be written (95% → 91% used, 47 GiB → 89 GiB free
in one session, but the regrowth was unbounded without these guards).

### Section A — CI Runner Post-Job Docker Prune

**Problem.** Self-hosted GitHub Actions runners regrow their Docker
builder cache unbounded across CI jobs. `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`
hit 103 GB because every `docker build` leaves ~1 GB of intermediate
layer artifacts in the builder cache and nothing reclaims it. TRIM is
run weekly, but TRIM only reclaims the host `.raw` — it does not
delete the underlying Docker objects, so the next build re-fills the
cache.

**Fix.** `scripts/post_job_docker_prune.sh` runs after every CI job
on each runner:

1. `docker system prune -f` — always runs; removes dangling images,
   containers, networks. Safe; this is the build's own intermediate
   artifacts.
2. `docker builder prune -f --filter "until=24h"` — runs only when
   the builder cache exceeds the configured threshold (default
   **2048 MB**). The 24h filter preserves the most recent warm window.

**Install on a self-hosted Actions runner:**
```bash
RUNNER_ROOT="$HOME/actions-runner"   # or any of the other runner roots
ln -sf "$HOME/projects_other/disk_magician/scripts/post_job_docker_prune.sh" \
       "$RUNNER_ROOT/hooks/post-job.sh"
```

**Expected savings:** 5–15 GB/day of regrowth prevented per machine
(10 active runners: up to 30 GB/day).

### Section B — Weekly Worktree-Venv Sweeper (launchd plist)

**Problem.** `scripts/cleanup_worktree_venvs.sh` is proven (reclaimed
29.2 GB in one dry-run pass) but requires manual invocation. Dormant
worktree venvs regrow because new worktrees are created with fresh
venvs.

**Fix.** `launchd/com.jleechan.disk-magician-worktree-venvs.plist`
runs every **Sunday at 04:00** with `WORKTREE_APPROVED=1` baked in:

```bash
sed "s|@HOME@|$HOME|g" \
  launchd/com.jleechan.disk-magician-worktree-venvs.plist \
  > ~/Library/LaunchAgents/com.jleechan.disk-magician-worktree-venvs.plist

launchctl unload ~/Library/LaunchAgents/com.jleechan.disk-magician-worktree-venvs.plist 2>/dev/null
launchctl load  ~/Library/LaunchAgents/com.jleechan.disk-magician-worktree-venvs.plist
launchctl start com.jleechan.disk-magician-worktree-venvs   # one-shot seed
```

Note: the plist pins `/opt/homebrew/bin/bash` (5.x) explicitly. The
script's `WT_AGE_CACHE` associative array requires bash 4+; the
default macOS `/bin/bash` is 3.2.57 and crashes on `declare -A`.

### Section C — Snapshot Freshness + Growth-Rate Detection

**Problem.** `disk_snapshot.sh` runs every 30 min via launchd, but a
3-day-stale snapshot missed a +49 GB `Library/Containers` growth. The
disk_audit had no staleness signal and no growth-rate field, so
regressions only surfaced as disk-full emergencies.

**Fix.** Three additive JSON fields plus a regression detector:

- **`snapshot_metadata.captured_at`** — ISO 8601 timestamp on every
  snapshot
- **`snapshot_metadata.age_seconds`** — for staleness checks
- **`snapshot_metadata.coverage_pct`** + **`measurement_status`**
  (`complete` / `partial` / `timeout`) — sentinel handling per
  `feedback_silent_zero_anti_pattern`
- **`disk_history.sh --growth-rate`** — linear regression of KB/day
  per top-level dir over the last 7 days
- **`disk_audit.sh`** — emits `STALE SNAPSHOT WARNING` when
  `age_seconds > 14400` (4h) and refuses snapshots with
  `measurement_status=timeout`
- **`lc_<safe_name>` keys** — top-20 subdirs of `~/Library/Containers`
  captured per snapshot for sub-container regression detection

All changes are additive — no existing JSON consumer breaks.

### Section D — Sweeper Health Watchdog

**Problem.** 9 `com.jleechan.cleanup-*` launchd sweepers are
installed at `~/Library/LaunchAgents/`, but 2 of them (cleanup-docker,
cleanup-antigravity-brain) are MISS — installed but never logging.
This is silent degradation: the user discovers it when disk fills up
again.

**Fix.** `scripts/sweeper_health_check.sh` walks the LaunchAgents
directory, resolves each plist's log path, and classifies by log
state:

- **OK** — log modified within `--threshold-days` (default 7)
- **WARN** — log fresh but tail contains error markers
- **MISS** — log absent or older than threshold

Exit code 0 if all healthy, 1 if any unhealthy. Currently detects the
2 known MISS sweepers on this host.

**Install:**
```bash
sed "s|@HOME@|$HOME|g" \
  launchd/com.jleechan.disk-magician-sweeper-health.plist \
  > ~/Library/LaunchAgents/com.jleechan.disk-magician-sweeper-health.plist

launchctl unload ~/Library/LaunchAgents/com.jleechan.disk-magician-sweeper-health.plist 2>/dev/null
launchctl load  ~/Library/LaunchAgents/com.jleechan.disk-magician-sweeper-health.plist
```

**Recommended rollout order:**
1. **D first** — land the watchdog so you can observe whether the
   other 3 are firing
2. **A** — Docker post-job prune (highest impact, 5–30 GB/day)
3. **B** — worktree-venvs weekly sweeper (prevents venv regrowth)
4. **C** — snapshot freshness (gives the watchdog + a/b something
   meaningful to alert on)

### Section E — Supervisor Launchd-Log Rotator

**Problem.** The `cmux-codex-launchd` plist rotates its stdout log
to `cmux-codex-launchd.YYYYMMDDTHHMMSS.log` at 50 MB; without
intervention those rotated files accumulate forever. We measured
**91 × 50 MB = 4.55 GB** across 19 days on 2026-06-13. The
auto-cleanup paths (cleanup_llm_inspector, cleanup_agent_artifacts,
cleanup_dev_caches) did not touch `~/.claude/supervisor/`.

**Fix.** `scripts/cleanup_supervisor_logs.sh` deletes rotated logs
older than **7 days** and explicitly preserves the active log
(`cmux-codex-launchd.log`), the active stderr, and the
`cmux-codex-launchd-state.json` state file. Wired into
`disk_audit.sh` so `./disk_magician.sh clean` runs it on every pass.

**Expected savings:** ~1.95 GB per machine (39 × 50 MB) on a host
that has been running 19+ days without this script. New regrowth
blocked: the 7-day window keeps total log floor to ~7 × 50 MB =
350 MB indefinitely.
