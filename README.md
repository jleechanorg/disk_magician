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
