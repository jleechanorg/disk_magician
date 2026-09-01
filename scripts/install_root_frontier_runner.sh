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

if [[ "$DRY_RUN" != true && "$(id -u)" -ne 0 ]]; then
  echo "Error: installer must be run as root (e.g. sudo $0)" >&2
  exit 1
fi

USER_HOME="${DISK_MAGICIAN_SCAN_USER_HOME:-/Users/$TARGET_USER}"
if [[ "$DRY_RUN" != true && ! -d "$USER_HOME" ]]; then
  echo "Error: target user home $USER_HOME does not exist" >&2
  exit 1
fi

# Overridable only for the non-root test harness (tests/test_install_root_frontier_runner.sh);
# production installs always target the real system paths below.
LIBEXEC_DIR="${DISK_MAGICIAN_LIBEXEC_DIR:-/usr/local/libexec/disk-magician}"
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-/var/db/disk-magician}"
PLIST_DST="/Library/LaunchDaemons/com.jleechanorg.disk-magician-frontier-root.plist"
PLIST_TEMPLATE="$REPO_ROOT/launchd/com.jleechanorg.disk-magician-frontier-root.plist.template"

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
  echo "Error: plist template $PLIST_TEMPLATE missing" >&2
  exit 1
fi

# assert_safe_install_target — refuse to install through a symlink at the
# target itself, or through a pre-existing non-root-owned parent directory.
# mkdir -p + chown of only the leaf directory is not enough: on a
# Homebrew-managed Intel Mac, /usr/local (and sometimes /usr/local/libexec)
# is owned by the admin user, not root, so a local non-root user with that
# pre-existing write access could plant a symlink or writable directory at
# $LIBEXEC_DIR that this script would then chown/populate as root — a
# nightly root-code-execution foothold (found in /advice review of
# disk_magician-4y6). Scoped to target + immediate parent only — walking the
# full ancestor chain up to / would misfire on macOS's own /var and /tmp
# symlinks (-> /private/var, /private/tmp), which are not attacker-plantable.
# Ownership is only enforced when running as root (EUID 0): the non-root
# test harness exercises the symlink check alone.
assert_safe_install_target() {
  local target="$1" parent
  parent="$(dirname "$target")"
  if [[ -L "$parent" ]]; then
    echo "Error: refusing to install under symlinked parent: $parent" >&2
    exit 1
  fi
  if [[ "$(id -u)" -eq 0 && -e "$parent" ]]; then
    local owner_uid
    owner_uid="$(stat -f '%u' "$parent" 2>/dev/null || stat -c '%u' "$parent")"
    if [[ "$owner_uid" != "0" ]]; then
      echo "Error: refusing to install into $target — parent $parent is not root-owned (uid=$owner_uid)" >&2
      exit 1
    fi
  fi
  if [[ -L "$target" ]]; then
    echo "Error: refusing to install through symlink: $target" >&2
    exit 1
  fi
}

echo "Installing root frontier runner for user $TARGET_USER (home: $USER_HOME)..."

assert_safe_install_target "$LIBEXEC_DIR"
assert_safe_install_target "$STATE_DIR"

if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] Would create directory: $LIBEXEC_DIR (owner: root:wheel, mode: 0755)"
  echo "[dry-run] Would copy $REPO_ROOT/scripts/disk_frontier_scan.py -> $LIBEXEC_DIR/disk_frontier_scan.py (mode: 0755)"
  echo "[dry-run] Would create directory: $STATE_DIR (owner: root:wheel, mode: 0755)"
  echo "[dry-run] Would install LaunchDaemon: $PLIST_DST"
  exit 0
fi

mkdir -p "$LIBEXEC_DIR"
chown root:wheel "$LIBEXEC_DIR"
chmod 755 "$LIBEXEC_DIR"

# Re-check immediately before writing through it: the ancestor check above
# and this cp are not atomic, so a TOCTOU window exists if any ancestor
# directory remains writable by a non-root user between the two.
if [[ -L "$LIBEXEC_DIR" ]]; then
  echo "Error: $LIBEXEC_DIR became a symlink after creation — aborting" >&2
  exit 1
fi

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
