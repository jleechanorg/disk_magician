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

## Section A: CI Runner Post-Job Docker Prune

### Problem

Self-hosted GitHub Actions runners regrow their Docker builder cache
unbounded across CI jobs. On the `worldarchitect.ai` runners, the host
`~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw`
sparse image reached **103 GB** in days because every `docker build`
leaves ~1 GB of intermediate layer artifacts in the builder cache and
nothing on the runner ever reclaims it. TRIM is run weekly by
`cleanup-docker.plist`, but TRIM only reclaims the host `.raw` — it
does not delete the underlying Docker objects, so the next build
instantly re-fills the cache.

### Fix

`scripts/post_job_docker_prune.sh` runs after every CI job on each
runner and keeps the cache bounded:

1. `docker system prune -f` — always runs; removes dangling images,
   containers, networks. Cheap and safe; this is the build's own
   intermediate artifacts.
2. `docker builder prune -f --filter "until=24h"` — runs only when the
   builder cache exceeds the configured threshold (default **2048 MB**).
   The 24h filter preserves the most recent warm window so consecutive
   jobs on the same runner do not cold-start layer pulls.

The script is fail-soft: if `docker` is missing or the daemon is
unreachable, the hook exits 0 with a log line so the CI job result is
never affected. (Prune runs *after* the job has already completed.)

### Install on a self-hosted Actions runner

```bash
# One-time per runner root (assumes the script is already on disk):
RUNNER_ROOT="$HOME/actions-runner"   # or ~/actions-runner-2, ~/actions-runner-aub, etc.
ln -sf "$HOME/projects_other/disk_magician/scripts/post_job_docker_prune.sh" \
       "$RUNNER_ROOT/hooks/post-job.sh"
```

GitHub Actions runner invokes `$RUNNER_ROOT/hooks/post-job.sh` after
every job. The symlink keeps the script version-controlled in this repo
so updates propagate with a single `git pull` + reload.

If your runner version predates 2.300, the hook path may differ — older
runners used `post-job.py` instead of `post-job.sh`. Verify with
`ls $RUNNER_ROOT/hooks/`.

### Expected savings

| Metric                              | Before         | After        |
|-------------------------------------|----------------|--------------|
| Builder cache ceiling per runner    | unbounded      | ~2 GB        |
| 10 runners × 5 builds/day × ~1 GB  | **+50 GB/day** | +0 GB/day    |
| `Docker.raw` host size              | regrowing      | flat after weekly TRIM |

Net steady-state impact: **5–15 GB/day** of regrowth prevented per
machine, scaling linearly with build volume. Worst case (10 active
runners, no cap): up to 30 GB/day.

### Verify the hook is firing

```bash
# Watch the log while a CI build runs:
tail -f ~/.disk_magician_backup/post-job.log
# After a build, the most recent entry should report the builder cache
# size in MB and whether the builder prune fired.
```

If no entries appear within 24 hours, the symlink is wrong or the
runner version does not support `post-job.sh`. Check the runner's
`_diag/` worker log for `post-job.sh` mention.

### CLI

```bash
# Preview what would run (no docker calls):
bash scripts/post_job_docker_prune.sh --dry-run

# Run live (safe — only removes dangling + old builder layers):
bash scripts/post_job_docker_prune.sh

# Custom threshold and log location:
bash scripts/post_job_docker_prune.sh \
  --max-cache-mb 4096 \
  --log /var/log/disk-magician/post-job.log
```

### Tests

```bash
bash tests/test_post_job_docker_prune.sh
```

Mocks the `docker` binary via PATH override and verifies that the
right commands run under the right conditions (above threshold, below
threshold, docker missing, dry-run mode).
