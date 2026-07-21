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
  audit         Analyze current snapshot, show regressions, and recommend cleanups.
  clean         Clean safe targets (caches, temp files, orphaned worktrees).
  clean-all     Clean all targets interactively (Docker VMs, old sessions).
  history       Show historical growth trends from git snapshots.
  discover      Scan for untracked directories > 5 GB.
  alert         Check if free disk space is below alert threshold.
  state         Manage the per-machine state repo (init|status|remote|push).

Options:
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
  local state_dir new_layout legacy
  state_dir="$(python3 "$SCRIPT_DIR/scripts/resolve_state_repo_path.py" 2>/dev/null)"
  new_layout="$state_dir/snapshots/disk_snapshot.json"
  legacy="$BACKUP_DIR/backup/$(hostname -s 2>/dev/null || hostname)/disk_snapshot.json"
  if [[ -n "$state_dir" && -f "$new_layout" ]]; then
    printf '%s\n' "$new_layout"
  else
    printf '%s\n' "$legacy"
  fi
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
        <string>${SCRIPT_DIR}/disk_magician.sh</string>
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
    local cron_job="*/30 * * * * ${SCRIPT_DIR}/disk_magician.sh snapshot >> /tmp/disk-magician.log 2>&1"
    (crontab -l 2>/dev/null | grep -Fv "disk_magician.sh"; echo "$cron_job") | crontab -
    echo "Cron job added to crontab."
  fi

  echo "Setup complete! Run './disk_magician.sh snapshot' to capture your first snapshot."
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
  audit)
    # Default diagnosis: top-down accounting, snapshot deltas, and safe
    # quick-win analysis run concurrently and render as one ordered report.
    DISK_SNAPSHOT_JSON="$(resolve_dispatch_snapshot_json)"
    export DISK_SNAPSHOT_JSON
    "$SCRIPT_DIR/scripts/disk_diagnostic.sh" "$@"
    ;;
  clean)
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
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac
