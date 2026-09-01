#!/usr/bin/env bash
# install_root_frontier_runner.sh — Install immutable root-owned frontier runner
#
# Copies scanner code to /usr/local/libexec/disk-magician and installs
# /Library/LaunchDaemons/com.jleechanorg.disk-magician-frontier-root.plist
# (Bead disk_magician-4y6).
#
# Usage: sudo ./scripts/install_root_frontier_runner.sh [--user <username>] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET_USER="${SUDO_USER:-$(id -un)}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --user) TARGET_USER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: sudo $0 [--user <username>] [--dry-run]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

USER_HOME="/Users/$TARGET_USER"
if [[ ! -d "$USER_HOME" ]]; then
  echo "Error: target user home $USER_HOME does not exist" >&2
  exit 1
fi

LIBEXEC_DIR="/usr/local/libexec/disk-magician"
STATE_DIR="/var/db/disk-magician"
PLIST_DST="/Library/LaunchDaemons/com.jleechanorg.disk-magician-frontier-root.plist"
PLIST_TEMPLATE="$REPO_ROOT/launchd/com.jleechanorg.disk-magician-frontier-root.plist.template"

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
  echo "Error: plist template $PLIST_TEMPLATE missing" >&2
  exit 1
fi

echo "Installing root frontier runner for user $TARGET_USER (home: $USER_HOME)..."

if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] Would create directory: $LIBEXEC_DIR (owner: root:wheel, mode: 0755)"
  echo "[dry-run] Would copy $REPO_ROOT/scripts/disk_frontier_scan.py -> $LIBEXEC_DIR/disk_frontier_scan.py (mode: 0755)"
  echo "[dry-run] Would create directory: $STATE_DIR (owner: root:wheel, mode: 0755)"
  echo "[dry-run] Would install LaunchDaemon: $PLIST_DST"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: installer must be run as root (e.g. sudo $0)" >&2
  exit 1
fi

mkdir -p "$LIBEXEC_DIR"
chown root:wheel "$LIBEXEC_DIR"
chmod 755 "$LIBEXEC_DIR"

cp "$REPO_ROOT/scripts/disk_frontier_scan.py" "$LIBEXEC_DIR/disk_frontier_scan.py"
chown root:wheel "$LIBEXEC_DIR/disk_frontier_scan.py"
chmod 755 "$LIBEXEC_DIR/disk_frontier_scan.py"

mkdir -p "$STATE_DIR"
chown root:wheel "$STATE_DIR"
chmod 755 "$STATE_DIR"

sed -e "s|@USER_HOME@|$USER_HOME|g" "$PLIST_TEMPLATE" > "$PLIST_DST"
chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"

launchctl bootout system "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST"

echo "Installed and bootstrapped com.jleechanorg.disk-magician-frontier-root."
launchctl print system/com.jleechanorg.disk-magician-frontier-root | head -n 15 || true
