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

# Concurrency guard for snapshot mode (bead jleechan-q9mu): mkdir-based lock,
# stale-lock TTL 90 min (dead pid + old enough -> steal), contention = log +
# exit 0 (skip this run, never queue).
SNAPSHOT_LOCK_DIR="${HOME}/.disk_magician_state/snapshot.lock"
SNAPSHOT_LOCK_TTL_SEC=5400

acquire_snapshot_lock() {
  mkdir -p "$(dirname "$SNAPSHOT_LOCK_DIR")"
  if mkdir "$SNAPSHOT_LOCK_DIR" 2>/dev/null; then
    echo $$ > "$SNAPSHOT_LOCK_DIR/pid"
    trap 'rm -rf "$SNAPSHOT_LOCK_DIR"' EXIT
    return 0
  fi
  local held_pid age
  held_pid=$(cat "$SNAPSHOT_LOCK_DIR/pid" 2>/dev/null || echo "")
  age=$(( $(date +%s) - $(stat -f%m "$SNAPSHOT_LOCK_DIR" 2>/dev/null || stat -c%Y "$SNAPSHOT_LOCK_DIR" 2>/dev/null || date +%s) ))
  if [[ "$age" -gt "$SNAPSHOT_LOCK_TTL_SEC" ]] && { [[ -z "$held_pid" ]] || ! kill -0 "$held_pid" 2>/dev/null; }; then
    rm -rf "$SNAPSHOT_LOCK_DIR"
    if mkdir "$SNAPSHOT_LOCK_DIR" 2>/dev/null; then
      echo $$ > "$SNAPSHOT_LOCK_DIR/pid"
      trap 'rm -rf "$SNAPSHOT_LOCK_DIR"' EXIT
      return 0
    fi
  fi
  echo "snapshot: lock held by pid ${held_pid:-?} (age ${age}s) — skipping this run"
  return 1
}

find_gitleaks() {
  local candidate
  if [[ -n "${DISK_MAGICIAN_GITLEAKS_BIN:-}" ]]; then
    if [[ -x "${DISK_MAGICIAN_GITLEAKS_BIN}" ]]; then
      printf '%s\n' "${DISK_MAGICIAN_GITLEAKS_BIN}"
      return 0
    fi
    return 1
  fi
  if command -v gitleaks >/dev/null 2>&1; then
    command -v gitleaks
    return 0
  fi
  for candidate in \
    "${HOMEBREW_PREFIX:+$HOMEBREW_PREFIX/bin/gitleaks}" \
    /opt/homebrew/bin/gitleaks \
    /usr/local/bin/gitleaks \
    "$HOME/.local/bin/gitleaks"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

remote_has_embedded_credentials() {
  local remote_url="$1"
  python3 -c '
import sys
from urllib.parse import urlsplit

url = urlsplit(sys.stdin.read().strip())
sys.exit(0 if url.scheme in {"http", "https"} and (url.username or url.password) else 1)
' <<<"$remote_url"
}

guard_snapshot_history_push() {
  local branch remote_url remote_exists=false remote_ref="" scan_range gitleaks_bin
  branch="$(git -C "$BACKUP_DIR" symbolic-ref --quiet --short HEAD)" || {
    echo "Snapshot history guard: detached HEAD is not safe to push." >&2
    return 1
  }
  remote_url="$(git -C "$BACKUP_DIR" remote get-url origin)" || {
    echo "Snapshot history guard: origin has no usable URL." >&2
    return 1
  }
  if remote_has_embedded_credentials "$remote_url"; then
    echo "Snapshot history guard: origin URL contains embedded credentials; refusing to push." >&2
    return 1
  fi

  if git -C "$BACKUP_DIR" ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
    remote_exists=true
  else
    local ls_remote_rc=$?
    if [[ "$ls_remote_rc" -ne 2 ]]; then
      echo "Snapshot history guard: could not verify origin/$branch." >&2
      return 1
    fi
  fi

  if [[ "$remote_exists" == true ]]; then
    remote_ref="refs/remotes/origin/$branch"
    git -C "$BACKUP_DIR" fetch --quiet origin \
      "refs/heads/$branch:$remote_ref" || {
      echo "Snapshot history guard: could not refresh origin/$branch." >&2
      return 1
    }
    if ! git -C "$BACKUP_DIR" merge-base --is-ancestor "$remote_ref" HEAD; then
      echo "Snapshot history guard: local $branch does not descend from origin/$branch; refusing history rewrite." >&2
      return 1
    fi
    scan_range="$remote_ref..HEAD"
  else
    scan_range="HEAD"
  fi

  if git -C "$BACKUP_DIR" show-ref --verify --quiet refs/heads/archive/pre-reset-20260711 && \
     ! git -C "$BACKUP_DIR" merge-base --is-ancestor refs/heads/archive/pre-reset-20260711 HEAD; then
    echo "Snapshot history guard: main no longer contains archive/pre-reset-20260711; refusing history loss." >&2
    return 1
  fi

  gitleaks_bin="$(find_gitleaks)" || {
    echo "Snapshot history guard: gitleaks is unavailable; refusing unscanned push." >&2
    return 1
  }
  if ! "$gitleaks_bin" git --no-banner --no-color --redact=100 \
      --log-opts="$scan_range" "$BACKUP_DIR" >/dev/null 2>&1; then
    echo "Snapshot history guard: secret scan rejected outgoing snapshot history." >&2
    return 1
  fi

  echo "Snapshot history guard passed for origin/$branch."
}

run_snapshot() {
  acquire_snapshot_lock || exit 0

  # Parse --output <path> from args; remaining args are ignored.
  local caller_output=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)
        caller_output="$2"
        shift 2
        ;;
      --output=*)
        caller_output="${1#--output=}"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  local host_name
  host_name="$(hostname -s 2>/dev/null || hostname)"

  if [[ -n "$caller_output" ]]; then
    # Caller-controlled output path: write there and skip auto git-commit/push.
    # DISK_MAGICIAN_CONFIG is inherited from the caller environment automatically.
    echo "Capturing disk snapshot -> $caller_output"
    "$SCRIPT_DIR/scripts/disk_snapshot.sh" --output "$caller_output"
    return
  fi

  # Default behavior: write to BACKUP_DIR and auto-commit/push.
  local snap_dest="$BACKUP_DIR/backup/$host_name/disk_snapshot.json"
  echo "Capturing disk snapshot -> $snap_dest"
  "$SCRIPT_DIR/scripts/disk_snapshot.sh" --output "$snap_dest"

  # Auto-commit and push if in git repo
  if [[ -d "$BACKUP_DIR/.git" ]]; then
    echo "Committing snapshot to git repository..."
    git -C "$BACKUP_DIR" add "backup/$host_name/disk_snapshot.json"
    if git -C "$BACKUP_DIR" diff --cached --quiet; then
      echo "No changes to commit."
    else
      git -C "$BACKUP_DIR" commit -m "chore: update disk snapshot for $host_name"
    fi

    # Push to origin if remote is configured
    if git -C "$BACKUP_DIR" remote | grep -q "origin"; then
      echo "Pushing snapshot to remote..."
      guard_snapshot_history_push
      git -C "$BACKUP_DIR" push origin "HEAD:refs/heads/$(git -C "$BACKUP_DIR" symbolic-ref --short HEAD)"
    fi
  fi
}

case "$CMD" in
  setup)
    run_setup "$@"
    ;;
  snapshot)
    run_snapshot "$@"
    ;;
  audit)
    # Default diagnosis: top-down accounting, snapshot deltas, and safe
    # quick-win analysis run concurrently and render as one ordered report.
    DISK_SNAPSHOT_JSON="$BACKUP_DIR/backup/$(hostname -s 2>/dev/null || hostname)/disk_snapshot.json"
    export DISK_SNAPSHOT_JSON
    "$SCRIPT_DIR/scripts/disk_diagnostic.sh" "$@"
    ;;
  clean)
    DISK_SNAPSHOT_JSON="$BACKUP_DIR/backup/$(hostname -s 2>/dev/null || hostname)/disk_snapshot.json"
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
    DISK_SNAPSHOT_JSON="$BACKUP_DIR/backup/$(hostname -s 2>/dev/null || hostname)/disk_snapshot.json"
    export DISK_SNAPSHOT_JSON
    "$SCRIPT_DIR/scripts/disk_audit.sh" --clean-all "$@"
    ;;
  history)
    DISK_SNAPSHOT_JSON="$BACKUP_DIR/backup/$(hostname -s 2>/dev/null || hostname)/disk_snapshot.json"
    export DISK_SNAPSHOT_JSON
    # Execute history from the BACKUP_DIR context so git history is tracked there
    DISK_SNAPSHOT_JSON="$BACKUP_DIR/backup/$(hostname -s 2>/dev/null || hostname)/disk_snapshot.json" python3 "$SCRIPT_DIR/scripts/disk_history.sh" "$@"
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
