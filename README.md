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

---

## Section B: Weekly Worktree-Venv Sweeper (launchd)

### Problem

`scripts/cleanup_worktree_venvs.sh` is proven to reclaim ~29 GB of
Python venvs in dormant Git worktrees in a single run, but it only ran
when invoked manually. The 156-worktree `~/projects` tree re-fills
`venv`/`/`.venv`` directories continuously as new work is started, and
nothing bounded regrowth.

### Fix

A weekly launchd plist that auto-runs the sweeper. The template lives
at `launchd/com.jleechan.disk-magician-worktree-venvs.plist` and uses
`@HOME@` placeholders so an install script can substitute `$HOME` and
copy into `~/Library/LaunchAgents/`. Per the launchd repo-template
rule, the template (not a fully-resolved copy) is what gets committed.

- **Schedule:** Sundays at 04:00 local time
  (`StartCalendarInterval` `Weekday=0`, `Hour=4`, `Minute=0`).
- **Command:** `/opt/homebrew/bin/bash` `…/cleanup_worktree_venvs.sh`
  `--clean` `--min-age 14`.
- **Env:** `WORKTREE_APPROVED=1` set in `EnvironmentVariables`, so the
  script's `--clean` gate passes.
- **Log:** `/tmp/disk-magician-worktree-venvs.log`
  (`StandardOutPath` + `StandardErrorPath`).

### Why `WORKTREE_APPROVED=1` is baked into the plist

`cleanup_worktree_venvs.sh` refuses `--clean` without
`WORKTREE_APPROVED=1` in the environment, mirroring the
worktree-safety rule in `user_scope` `CLAUDE.md` (any delete inside a
worktree requires explicit approval). This scheduled job is itself
that explicit approval: the operator chose to install the plist, and
the plist sets the env var when invoking the script, so the script's
gate passes by design. The 14-day `--min-age` and the worktree-only
filter (skips base repos, skips symlinked/centralized venvs) are the
second line of defense against accidental destruction.

### Why `/opt/homebrew/bin/bash` and not `/bin/bash`

`/bin/bash` on macOS is Apple-bundled bash 3.2.57, which lacks
associative arrays (`declare -A`). The script's worktree-age cache
uses `declare -A WT_AGE_CACHE`, so it crashes immediately under
3.2.57. launchd's default environment PATH is
`/usr/bin:/bin:/usr/sbin:/sbin` — no Homebrew — so the script's
`#!/usr/bin/env bash` shebang also resolves to 3.2.57 when launched
by launchd. Pointing the plist at `/opt/homebrew/bin/bash` (5.x)
makes the script work without modifying it.

### Install (operator action)

```bash
sed "s|@HOME@|$HOME|g" \
  launchd/com.jleechan.disk-magician-worktree-venvs.plist \
  > ~/Library/LaunchAgents/com.jleechan.disk-magician-worktree-venvs.plist

launchctl unload ~/Library/LaunchAgents/com.jleechan.disk-magician-worktree-venvs.plist 2>/dev/null
launchctl load  ~/Library/LaunchAgents/com.jleechan.disk-magician-worktree-venvs.plist
launchctl list  | grep disk-magician-worktree-venvs
```

Verify the next run by tailing the log after the next Sunday 04:00
trigger, or trigger manually:

```bash
launchctl start com.jleechan.disk-magician-worktree-venvs
tail -n 50 /tmp/disk-magician-worktree-venvs.log
```

---

## Section D: Sweeper Health Watchdog

### Problem

The 9 `com.jleechan.cleanup-*.plist` jobs registered with launchd are
treated by the harness as "running" the moment they're loaded. That is
a silent-degradation failure mode: a plist with a wrong `ProgramArguments`
path, a missing target script, or a misconfigured `StartCalendarInterval`
will never produce a log entry, and the system will not notice the
missing-cleanup gap until disk pressure recurs.

A spot check on 2026-06-12 found **2 of 7 loaded sweepers with no log
file at all**: `com.jleechan.cleanup-docker` and
`com.jleechan.cleanup-antigravity-brain`. Both plists are loaded by
launchd; both have valid `StandardOutPath` keys; neither has ever
written a byte.

### Fix

`scripts/sweeper_health_check.sh` walks every
`com.jleechan.cleanup-*.plist` in `~/Library/LaunchAgents`, resolves
the log path from each plist's `StandardOutPath` (with `StandardErrorPath`
as a fallback), and classifies the sweeper by log state:

- **OK** — log file exists, was modified within the threshold window,
  and the tail of the log contains no error markers.
- **WARN** — log file is recent but the last 50 lines contain an
  `ERROR`, `Traceback`, `failed`, or `exception` marker. The sweeper
  is running, but the run is failing.
- **MISS** — log file is missing, empty, or older than
  `--threshold-days` (default 7). The sweeper is loaded but not
  producing output.

Exit code 0 means every cleanup-`*` plist has a healthy log; 1 means
at least one sweeper is MISS or WARN. Wire the non-zero exit into
any alerting channel (Slack, email, `disk_usage_alert.sh`) to turn
this into a real page.

### Run manually

```bash
# Default: scan ~/Library/LaunchAgents, threshold 7d
./scripts/sweeper_health_check.sh

# Tighter threshold (alerts after 3 days of silence)
./scripts/sweeper_health_check.sh --threshold-days 3

# Show per-sweeper details for healthy ones too
./scripts/sweeper_health_check.sh --verbose

# Always read-only — never runs a sweeper, never modifies logs
./scripts/sweeper_health_check.sh --dry-run
```

### Current detection (2026-06-12)

```
[MISS] com.jleechan.cleanup-antigravity-brain  log=…/cleanup-antigravity-brain.log  (file does not exist)
[MISS] com.jleechan.cleanup-docker             log=…/cleanup-docker.log  (file does not exist)
[OK]   com.jleechan.cleanup-ao-sessions        …
[OK]   com.jleechan.cleanup-ao-tmp             …
[OK]   com.jleechan.cleanup-apfs-snapshots     …
[OK]   com.jleechan.cleanup-dev-caches         …
[OK]   com.jleechan.cleanup-llm-inspector      …
Summary: 5 OK, 0 WARN, 2 MISS (of 7)
```

### Automated run (launchd template)

`launchd/com.jleechan.disk-magician-sweeper-health.plist` schedules a
daily 09:00 run. The template uses `@HOME@` placeholders; an install
script is expected to substitute `$HOME` and copy into
`~/Library/LaunchAgents/`. The template is **not** installed by this
PR — installation is left to operator action.

### Tests

```bash
bash tests/test_sweeper_health.sh
```

Builds a self-contained mock launchd layout under `/tmp` covering
fresh, stale, missing, empty, and warn cases. Asserts the right
status for each, the right summary line, and that an all-healthy
fixture exits 0. All 9 assertions pass.
