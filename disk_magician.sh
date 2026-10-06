#!/usr/bin/env bash
# disk_magician.sh — Main orchestrator CLI for Disk Magician.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Disk Magician 🪄 — Portable Disk Diagnostics, Snapshot Backups, & Cleanup

Usage: $(basename "$0") <command> [options]

Commands:
  setup         Configure local backup repository, create GitHub remote, and schedule jobs.
  snapshot      Perform disk usage breakdown and write to backup JSON.
  status        Report fleet, accounting, job outcomes, and deployed identity (--json).
  growth-top10  Report attributable growth with explicit partial/unknown values (--json).
  audit         Analyze current snapshot, show regressions, and recommend cleanups.
  frontier      Run the full-disk frontier scanner and optionally persist its state.
  frontier-nightly Run the existing scheduled frontier wrapper.
  residual-drilldown Run the scheduled residual and uncovered-root checks.
  pressure-sweep Run the existing free-space-gated maintenance job.
  tmp-scratch-sweep Run the existing scheduled scratch maintenance wrapper.
  clean         Clean safe targets across 6-tier routine stack (caches, temp, Docker, Xcode, worktrees).
  routine       Alias for clean --routine (runs unified 6-tier routine stack).
  clean-all     Clean all targets interactively (Docker VMs, old sessions).
  history       Show historical growth trends from git snapshots.
  history diff [ref]  Diff two committed ledger/topdown-5g.json snapshots.
  history diff --days N  Attribute growth from the lowest-used ledger in N days.
  discover      Scan for untracked directories > 5 GB.
  alert         Check if free disk space is below alert threshold.
  state         Manage the per-machine state repo (init|status|remote|push).
  check-system-residual Diagnose system residual space (/private/var/dirs_cleaner, deleted_helper logs).
  check-launchd-fleet    Verify all disk-magician launchd jobs are loaded and valid (run this FIRST when investigating disk fill).
  sweeper-health        Check scheduled cleanup and ledger health.
  cleanup-dirs-cleaner   Safely clean /private/var/dirs_cleaner accumulation.
  cleanup-pr-scratch     Safely clean abandoned PR analyzer and scratch work in /private/tmp.
  prune-aside-sessions   Prune stale Aside browser sessions and deduplicate static assets.
  cleanup-colima         Prune Docker images and in-VM fstrim sparse datadisk.
  cleanup-worktrees      Safely prune stale linked worktrees >=7d (alias: prune-worktrees).
  cleanup-worktree-venvs Strip Python venvs from dormant worktrees >=7d.
  worktree-hygiene       Audit and triage worktrees across multi-repo workspaces.
  cleanup-dev-caches     Clean compiler, npm, cargo, and test caches.
  cleanup-tmp            Clean ephemeral /private/tmp directories older than retention.
  cleanup-apfs-snapshots Clean stale APFS OS update snapshots older than retention.
  cleanup-antigravity-brain Clean stale conversation task logs and media artifacts.
  cleanup-claude-state   Run the guarded Claude state maintenance helper.
  cleanup-codex-db       Maintain Codex SQLite databases (aliases: vacuum-codex-db, codex-vacuum).
  cleanup-uv-cache       Prune disk-magician's own orphaned uv-cache build artifacts.
  cleanup-dark-factory   Prune stale dark-factory releases, runs, and df-* AO session homes.
  cleanup-code-sign-clones Clean stale macOS app code_sign_clone bundles.
  vacuum-hermes-state    Vacuum SQLite state and truncate WAL in ~/.hermes.
  worktree-new           Create new worktree under ~/.worktrees/<repo>/<name>.
  guard-worktree-add     PreToolUse hook guarding worktree placement under ~/.worktrees/.
  worktree-create-hook   Claude WorktreeCreate hook creating under ~/.worktrees/.
  layout-check           Audit worktree and evidence placement against standard layout.
  evidence-push          Sync local evidence dir to remote storage.

Options:
  --routine     Run unified 6-tier routine cleanup stack across all verified safe targets.
  --dry-run     Run clean/clean-all/setup in dry-run/preview mode.
  -h, --help    Show this help menu.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

CMD="$1"
shift

# Paths
CONFIG_FILE="$SCRIPT_DIR/config.json"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="$SCRIPT_DIR/config.json.template"

# Get backup directory from config or fallback
BACKUP_DIR="${HOME}/.disk_magician_backup"
if [[ -f "$CONFIG_FILE" ]]; then
  BACKUP_DIR=$(python3 - "$CONFIG_FILE" "${HOME}" <<'PY' 2>/dev/null || echo "${HOME}/.disk_magician_backup"
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("backup_dir", "~/.disk_magician_backup").replace("~", sys.argv[2]))
PY
)
fi

# Resolve the snapshot JSON to read from: prefer the new-layout state repo
# (scripts/resolve_state_repo_path.py — the same resolver snapshot_commit.sh
# uses to write), falling back to the legacy backup/<host>/ path so a repo
# that hasn't taken a new-layout snapshot yet still reads its last one.
resolve_dispatch_snapshot_json() {
  # shellcheck source=scripts/lib/resolve_snapshot_json.sh
  source "$SCRIPT_DIR/scripts/lib/resolve_snapshot_json.sh"
  resolve_snapshot_json
}

run_setup() {
  local dry_run=false
  for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && dry_run=true
  done

  echo "=== Setting up Disk Magician ==="
  echo "Local Backup Directory: $BACKUP_DIR"
  
  if [[ "$dry_run" == true ]]; then
    echo "[dry-run] Would create directory $BACKUP_DIR"
    echo "[dry-run] Would run: git init in $BACKUP_DIR"
    echo "[dry-run] Would create remote GitHub repository under jleechanorg"
    return 0
  fi

  local installed_cli="${HOME}/.local/bin/diskm"
  if [[ ! -x "$installed_cli" ]]; then
    echo "Install the packaged diskm command before scheduling snapshot jobs: $installed_cli" >&2
    return 1
  fi

  # 1. Create local backup directory
  mkdir -p "$BACKUP_DIR/backup/$(hostname -s 2>/dev/null || hostname)"
  if [[ ! -d "$BACKUP_DIR/.git" ]]; then
    echo "Initializing local Git repository for snapshots..."
    git -C "$BACKUP_DIR" init
  fi

  # 2. Check and configure git remote via gh
  if command -v gh &>/dev/null; then
    if gh auth status &>/dev/null; then
      # Ask to setup remote repository
      echo "GitHub CLI detected. Do you want to create a remote repository 'jleechanorg/disk_backup' (or similar) on GitHub? [y/N] "
      # Set non-interactive fallback for automation
      local answer="n"
      if [[ -t 0 ]]; then
        read -r answer
      fi
      if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        echo "Creating GitHub repository..."
        gh repo create jleechanorg/disk_backup --public --source="$BACKUP_DIR" --remote=origin --push || \
        gh repo create disk_backup --public --source="$BACKUP_DIR" --remote=origin --push || true
      fi
    fi
  fi

  # 3. Schedule Recurring Job
  echo "Setting up recurring snapshot jobs (every 30 minutes)..."
  if [[ "$OSTYPE" == "darwin"* ]]; then
    local plist_path="${HOME}/Library/LaunchAgents/com.jleechanorg.disk-magician.plist"
    echo "Creating launchd agent at $plist_path ..."
    mkdir -p "$(dirname "$plist_path")"
    cat <<XML > "$plist_path"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jleechanorg.disk-magician</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HOME}/.local/bin/diskm</string>
        <string>snapshot</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/disk-magician.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/disk-magician.log</string>
</dict>
</plist>
XML
    launchctl unload "$plist_path" 2>/dev/null || true
    launchctl load "$plist_path"
    echo "launchd agent successfully loaded."
  else
    # Linux cron fallback
    local cron_job="*/30 * * * * \"$installed_cli\" snapshot >> /tmp/disk-magician.log 2>&1"
    local prior_cron
    prior_cron="$(crontab -l 2>/dev/null || true)"
    {
      printf '%s\n' "$prior_cron" | grep -Fv -e "disk_magician.sh snapshot" -e "$installed_cli" || true
      printf '%s\n' "$cron_job"
    } | crontab -
    echo "Cron job added to crontab."
  fi

  echo "Setup complete! Run 'diskm snapshot' to capture your first snapshot."
}

# NOTE: the legacy inline snapshot lock, gitleaks secret-scan guard,
# credential-URL guard, and auto-commit/push logic that used to live here
# have moved to scripts/state_repo.sh (guard_state_repo_push) and
# scripts/snapshot_commit.sh (acquire_snapshot_lock) — design bright line:
# the state repo owns everything about its own writes and pushes, so both
# this dispatcher and the launchd job funnel through the one orchestrator
# instead of each call site re-implementing commit/push/guard. See
# roadmap/2026-07-21-generic-split-state-repo-design.md §Snapshot/commit flow.

case "$CMD" in
  setup)
    run_setup "$@"
    ;;
  snapshot)
    exec bash "$SCRIPT_DIR/scripts/snapshot_commit.sh"
    ;;
  status)
    exec python3 "$SCRIPT_DIR/scripts/disk_status.py" "$@"
    ;;
  growth-top10)
    exec python3 "$SCRIPT_DIR/scripts/growth_top10.py" "$@"
    ;;
  audit)
    for audit_arg in "$@"; do
      if [[ "$audit_arg" == "-h" || "$audit_arg" == "--help" ]]; then
        usage
        exit 0
      fi
    done
    # Default diagnosis: top-down accounting, snapshot deltas, and safe
    # quick-win analysis run concurrently and render as one ordered report.
    DISK_SNAPSHOT_JSON="$(resolve_dispatch_snapshot_json)"
    export DISK_SNAPSHOT_JSON
    "$SCRIPT_DIR/scripts/disk_diagnostic.sh" "$@"
    ;;
  frontier)
    exec python3 "$SCRIPT_DIR/scripts/disk_frontier_scan.py" "$@"
    ;;
  frontier-nightly)
    exec bash "$SCRIPT_DIR/scripts/disk_frontier_scan.sh" "$@"
    ;;
  residual-drilldown)
    exec bash "$SCRIPT_DIR/scripts/residual_drilldown.sh" "$@"
    ;;
  pressure-sweep)
    exec bash "$SCRIPT_DIR/scripts/pressure_sweep.sh" "$@"
    ;;
  tmp-scratch-sweep)
    exec bash "$SCRIPT_DIR/scripts/tmp_scratch_sweep.sh" "$@"
    ;;
  clean|routine)
    DISK_SNAPSHOT_JSON="$(resolve_dispatch_snapshot_json)"
    export DISK_SNAPSHOT_JSON
    
    AUTO_CLEAN="${DISK_MAGICIAN_AUTO_CLEAN:-${DISK_MAGICIAN_SAFE_AUTO:-0}}"
    DRY_RUN_ARG=false
    for arg in "$@"; do
      [[ "$arg" == "--dry-run" ]] && DRY_RUN_ARG=true
    done
    
    if [[ "$AUTO_CLEAN" != "1" && "$DRY_RUN_ARG" == false ]]; then
      echo "DISK_MAGICIAN_AUTO_CLEAN is not set. Proceed with safe cleanups? [y/N] "
      answer="n"
      if [[ -t 0 ]]; then
        read -r answer < /dev/tty
      fi
      if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "Defaulting to dry-run/preview mode."
        set -- "$@" "--dry-run"
      fi
    fi
    
    "$SCRIPT_DIR/scripts/disk_audit.sh" --clean "$@"
    ;;
  clean-all)
    DISK_SNAPSHOT_JSON="$(resolve_dispatch_snapshot_json)"
    export DISK_SNAPSHOT_JSON
    "$SCRIPT_DIR/scripts/disk_audit.sh" --clean-all "$@"
    ;;
  history)
    if [[ "${1:-}" == "diff" ]]; then
      shift
      python3 "$SCRIPT_DIR/scripts/history_diff.py" "$@"
      exit $?
    fi
    DISK_SNAPSHOT_JSON="$(resolve_dispatch_snapshot_json)"
    export DISK_SNAPSHOT_JSON
    # Execute history from the BACKUP_DIR context so git history is tracked there
    DISK_SNAPSHOT_JSON="$(resolve_dispatch_snapshot_json)" python3 "$SCRIPT_DIR/scripts/disk_history.sh" "$@"
    ;;
  discover)
    "$SCRIPT_DIR/scripts/disk_snapshot.sh" --discover
    ;;
  alert)
    "$SCRIPT_DIR/scripts/disk_usage_alert.sh" "$@"
    ;;
  state)
    "$SCRIPT_DIR/scripts/state_repo.sh" "$@"
    ;;
  check_system_residual|check-system-residual)
    "$SCRIPT_DIR/scripts/check_system_residual.sh" "$@"
    ;;
  check_launchd_fleet|check-launchd-fleet)
    "$SCRIPT_DIR/scripts/check_launchd_fleet.sh" "$@"
    ;;
  sweeper_health|sweeper-health)
    "$SCRIPT_DIR/scripts/sweeper_health_check.sh" "$@"
    ;;
  cleanup_dirs_cleaner|cleanup-dirs-cleaner)
    "$SCRIPT_DIR/scripts/cleanup_dirs_cleaner.sh" "$@"
    ;;
  cleanup_pr_scratch|cleanup-pr-scratch)
    "$SCRIPT_DIR/scripts/cleanup_pr_scratch.sh" "$@"
    ;;
  prune_aside_sessions|prune-aside-sessions)
    "$SCRIPT_DIR/scripts/prune_aside_sessions.sh" "$@"
    ;;
  cleanup_colima|cleanup-colima)
    "$SCRIPT_DIR/scripts/cleanup_colima.sh" "$@"
    ;;
  cleanup_worktrees|cleanup-worktrees|prune_worktrees|prune-worktrees)
    "$SCRIPT_DIR/scripts/cleanup_worktrees.sh" "$@"
    ;;
  cleanup_worktree_venvs|cleanup-worktree-venvs)
    "$SCRIPT_DIR/scripts/cleanup_worktree_venvs.sh" "$@"
    ;;
  worktree_hygiene|worktree-hygiene)
    "$SCRIPT_DIR/scripts/worktree_hygiene.sh" "$@"
    ;;
  cleanup_dev_caches|cleanup-dev-caches)
    "$SCRIPT_DIR/scripts/cleanup_dev_caches.sh" "$@"
    ;;
  cleanup_tmp|cleanup-tmp)
    "$SCRIPT_DIR/scripts/cleanup_tmp.sh" "$@"
    ;;
  cleanup_apfs_snapshots|cleanup-apfs-snapshots)
    "$SCRIPT_DIR/scripts/cleanup_apfs_snapshots.sh" "$@"
    ;;
  cleanup_antigravity_brain|cleanup-antigravity-brain)
    "$SCRIPT_DIR/scripts/cleanup_antigravity_brain.sh" "$@"
    ;;
  cleanup-claude-state)
    exec bash "$SCRIPT_DIR/scripts/cleanup_claude_state.sh" "$@"
    ;;
  cleanup_codex_db|cleanup-codex-db|vacuum_codex_db|vacuum-codex-db|codex-vacuum)
    "$SCRIPT_DIR/scripts/cleanup_codex_db.sh" "$@"
    ;;
  cleanup_uv_cache|cleanup-uv-cache)
    "$SCRIPT_DIR/scripts/cleanup_uv_cache.sh" "$@"
    ;;
  cleanup_dark_factory|cleanup-dark-factory)
    "$SCRIPT_DIR/scripts/cleanup_dark_factory.sh" "$@"
    ;;
  cleanup_code_sign_clones|cleanup-code-sign-clones)
    "$SCRIPT_DIR/scripts/cleanup_code_sign_clones.sh" "$@"
    ;;
  vacuum_hermes_state|vacuum-hermes-state)
    "$SCRIPT_DIR/scripts/vacuum_hermes_state.sh" "$@"
    ;;
  worktree_new|worktree-new)
    "$SCRIPT_DIR/scripts/worktree_new.sh" "$@"
    ;;
  guard_worktree_add|guard-worktree-add)
    python3 "$SCRIPT_DIR/scripts/worktree_guard.py" "$@"
    ;;
  worktree_create_hook|worktree-create-hook)
    "$SCRIPT_DIR/scripts/worktree_create_hook.sh" "$@"
    ;;
  layout_check|layout-check)
    python3 "$SCRIPT_DIR/scripts/layout_check.py" "$@"
    ;;
  evidence_push|evidence-push)
    "$SCRIPT_DIR/scripts/evidence_push.sh" "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac
