# Disk Magician 🪄

`disk_magician` is a generalized, zero-dependency utility to analyze local disk usage, validate snapshots, identify bloat (orphaned worktrees, caches, stale temp files), and run automated backup/history tracking using a serverless Git repository.

Designed to work across macOS and Linux, it can be exposed as a skill/plugin for various agent environments (Claude, Codex, Hermes, Openclaw).


## Portable configuration

`config.json.template` is the starting point for every install. Copy it to
`config.json` and edit `monitored_dirs`, optional `gc_worktree_repos`, and
thresholds for **your** machine — nothing in the repo assumes a particular
username or checkout path.

**Weekly sweepers (macOS launchd):** templates live under `launchd/com.disk-magician.*.plist`
with `@REPO_ROOT@`, `@HOME@`, and `@BASH@` placeholders. Install from anywhere:

```bash
./scripts/install_launchd_sweepers.sh --unload-legacy
```

**Find dormant large dirs** (excluding conversations/sessions):
```bash
./scripts/find_stale_large_dirs.sh --days 14 --min-mb 500
```

Override bash for scripts that need 4+ features:

```bash
DISK_MAGICIAN_BASH=/opt/homebrew/bin/bash ./scripts/install_launchd_sweepers.sh
```

Optional environment hooks:

| Variable | Purpose |
|----------|---------|
| `DISK_MAGICIAN_GC_REPOS` | Colon-separated git repo paths for `set_gc_worktree_prune.sh` |
| `DISK_MAGICIAN_EXTRA_ARTIFACT_DIRS` | Extra cleanup targets for `cleanup_agent_artifacts.sh` |
| `DISK_MAGICIAN_CONFIG` | Path to your `config.json` |
| `DISK_MAGICIAN_GITLEAKS_BIN` | Explicit path to `gitleaks` for the snapshot pre-push secret scan |

Automated snapshot pushes require [`gitleaks`](https://github.com/gitleaks/gitleaks).
The resolver honors `DISK_MAGICIAN_GITLEAKS_BIN`, the current `PATH`,
`$HOMEBREW_PREFIX/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, and finally
`~/.local/bin`, so the launchd environment can find standard Homebrew installs.
An explicit `DISK_MAGICIAN_GITLEAKS_BIN` that is not executable fails closed.
Before pushing, Disk Magician refreshes the matching remote branch, requires a
fast-forward history (and preserves `archive/pre-reset-20260711` when present),
rejects HTTP(S) remotes with embedded credentials, and scans every outgoing
commit with fully redacted output. A missing scanner or failed guard stops the
push with a non-zero exit; the local snapshot commit remains available for
inspection and recovery.

---

## Features

- 🔍 **Diagnostics & Audit**: Quick summary of APFS/Ext4 volumes, top directories, and actionable cleanup recommendations.
- 🕒 **Historical Trends**: Reads git history of your snapshots to show growth patterns and regressions over time.
- 🧹 **Guarded Worktree Cleanup**: Dynamically discovers orphaned Git worktrees without deleting them unless `WORKTREE_APPROVED=1` is set.
- 🗑️ **Temporary & Cache Purge**: Safely removes stale git clones, debug logs, and build/package manager caches older than a configurable threshold.
- 🧰 **Large Cleanup Sweep**: `clean-all` can preview or apply large tmp, Docker, Ollama, and Xcode cleanup with explicit gates for destructive paths.
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

# Preview safe targets to be cleaned; worktrees are skipped unless approved
./disk_magician.sh clean --dry-run

# Execute cleanup of safe targets (temp files, cache)
./disk_magician.sh clean

# Preview larger/destructive targets (large tmp, Docker, Ollama, Xcode)
./disk_magician.sh clean-all --dry-run

# Apply larger/destructive cleanup after reviewing the dry-run
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

## Cleanup Guardrails

- `clean` runs safe cache/temp/log cleanup, but skips worktree deletion unless `WORKTREE_APPROVED=1` is set.
- `clean-all` supports both `--dry-run` and apply mode for stale sessions, large tmp directories, worktrees, APFS snapshots, Docker, Ollama, and Xcode cleanup.
- Large tmp apply mode requires `LARGE_TMP_APPROVED=1`; temp directories named `wt_*` or `worktree_*` are skipped unless `TMP_WORKTREES_APPROVED=1` is also set.
- Docker cleanup runs `docker system prune -a -f` and preserves Docker volumes.
- Ollama cleanup deletes the local model store (`~/.ollama/models` by default, or `OLLAMA_MODELS_DIR`).
- Xcode cleanup clears DerivedData, CoreSimulator temp/cache directories, and unavailable simulators.

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
ln -sf "$(git rev-parse --show-toplevel 2>/dev/null || pwd)/scripts/post_job_docker_prune.sh" \
       "$RUNNER_ROOT/hooks/post-job.sh"
```

**Expected savings:** 5–15 GB/day of regrowth prevented per machine
(10 active runners: up to 30 GB/day).

### Section B — Weekly Worktree-Venv Sweeper (launchd plist)

**Problem.** `scripts/cleanup_worktree_venvs.sh` is proven (reclaimed
29.2 GB in one dry-run pass) but requires manual invocation. Dormant
worktree venvs regrow because new worktrees are created with fresh
venvs.

**Fix.** `launchd/com.disk-magician.worktree-venvs.plist`
runs every **Sunday at 04:00** with `WORKTREE_APPROVED=1` baked in:

```bash
./scripts/install_launchd_sweepers.sh com.disk-magician.worktree-venvs.plist
launchctl start com.disk-magician.worktree-venvs   # one-shot seed
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
./scripts/install_launchd_sweepers.sh com.disk-magician.sweeper-health.plist
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

### Section F — node_modules / venv Duplication Across Worktrees (Documentation Only)

**Problem.** Agent Orchestrator (AO) spawns each worker in its own
git worktree. Every Node.js worktree resolves its own
`node_modules/` (typically **~775 MB** per worktree for the
worldarchitect.ai + hermes-agent Node deps), and every Python
worktree builds its own `.venv/` (typically **~800 MB** per
worktree). With **6 active AO Node worktrees**, that is
**6 × 775 MB = ~4.6 GB of duplicate Node deps**; with **5
worldarchitect Python worktrees**, that is
**5 × 800 MB = ~3.7 GB of duplicate venvs**. Combined floor:
**~8.3 GB** consumed by copies of essentially-identical
dependency graphs.

**Why it regrows.** `npm install` and `python -m venv` both
materialize the full dependency set into the worktree because
the worktree is a fully independent working copy from the file-
system's perspective. There is no built-in mechanism for
`node_modules/` or `.venv/` to be shared across worktrees, and
`package.json` / `requirements.txt` rarely change between
adjacent worktrees on the same repo, so the install output is
near-identical.

**Recommended fix (NOT implemented in disk_magician — requires a
code change in agent-orchestrator).** Two viable shapes, in
preference order:

1. **pnpm content-addressable store** for Node projects
   (preferred). pnpm stores every package version once in
   `~/.local/share/pnpm/store/` and symlinks `node_modules/`
   entries into that store. Across N worktrees, the store stays
   at **~775 MB total** (one copy) instead of N × 775 MB. Per-
   worktree symlink overhead is < 10 MB. Migration: convert
   `npm install` to `pnpm install` in the worker bootstrap and
   pre-warm the pnpm store in the org-runner image so worktrees
   resolve from cache on first use.
2. **Symlink sharing** for both `node_modules/` and `.venv/`
   (simpler but fragile). Have the AO bootstrap detect when a
   sibling worktree on the same repo already has a populated
   `node_modules/` (matching `package-lock.json` hash) and
   symlink instead of reinstalling. For `.venv/`, use
   `python -m venv --symlinks` (3.10+) or symlink
   `lib/pythonX.Y/site-packages` from a parent store.

**Why disk_magician does NOT implement this.** The fix lives in
agent-orchestrator's worker bootstrap and in the
`myoung34/github-runner` image build, not on the disk
monitoring / cleanup axis. This section exists to make the
duplication pattern visible to anyone reading the regrowth-
prevention series and to document the recommended remediation
path so the next pass at the org-runner image has a target.

**Measured exposure (snapshot 2026-06-13).** Floor cost of the
AO + worldarchitect worktree set with current duplication:
**~8.3 GB**. After pnpm + symlinked-venv fix: **~1.6 GB**
(pnpm store + one venv per Python branch). **Potential
savings: ~6.7 GB sustained**, with the regrowth floor dropping
in proportion to active worktree count.

### Section G — APFS Snapshot Deletion Sudo Blocker (launchd plist)

**Problem.** macOS requires root privileges to delete local APFS snapshots (errors with exit code 1 or permissions failure like -69863). The user-mode `LaunchAgents` plist runs as the installing user and fails to delete snapshots when scheduled.

**Fix.** Install the snapshot cleanup scheduler as a system-wide `LaunchDaemon` under `/Library/LaunchDaemons` instead of a user-mode `LaunchAgent`. Since LaunchDaemons run as `root` by default, the script has the required permissions to execute `diskutil apfs deleteSnapshot` and `tmutil deletelocalsnapshots` without password prompts or sudoers modifications.

**Install:**
```bash
# APFS cleanup needs root — install LaunchDaemon manually from template:
REPO="$(cd "$(dirname "$0")" && pwd)"  # or your clone path
sed -e "s|@REPO_ROOT@|$REPO|g" -e "s|@HOME@|$HOME|g" -e "s|@BASH@|$(command -v bash)|g" \
  launchd/com.disk-magician.apfs-snapshots.plist | sudo tee /Library/LaunchDaemons/com.disk-magician.apfs-snapshots.plist
sudo chown root:wheel /Library/LaunchDaemons/com.disk-magician.apfs-snapshots.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.disk-magician.apfs-snapshots.plist
```
