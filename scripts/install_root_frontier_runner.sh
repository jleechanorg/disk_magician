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

LIBEXEC_DIR="/usr/local/libexec/disk-magician"
STATE_DIR="/var/db/disk-magician"
# Overridable only for the non-root test harness (tests/test_install_root_frontier_runner.sh).
# Gated on non-root so these can never redirect a real root install (e.g.
# via `sudo -E` or a root cron inheriting the caller's environment).
if [[ "$(id -u)" -ne 0 ]]; then
  LIBEXEC_DIR="${DISK_MAGICIAN_LIBEXEC_DIR:-$LIBEXEC_DIR}"
  STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$STATE_DIR}"
fi
PLIST_DST="/Library/LaunchDaemons/com.jleechanorg.disk-magician-frontier-root.plist"
PLIST_TEMPLATE="$REPO_ROOT/launchd/com.jleechanorg.disk-magician-frontier-root.plist.template"

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
  echo "Error: plist template $PLIST_TEMPLATE missing" >&2
  exit 1
fi

# assert_safe_install_target — refuse to install through a symlink at the
# target itself, or through a non-root-owned/symlinked ancestor directory.
# mkdir -p + chown of only the leaf directory is not enough: on a
# Homebrew-managed Intel Mac, /usr/local is owned by the admin user, not
# root, so a local non-root user with that pre-existing write access could
# plant a symlink or writable directory under it that this script would
# then chown/populate as root — a nightly root-code-execution foothold
# (found in /advice review of disk_magician-4y6). Checking only the
# immediate parent is not enough either: Homebrew never creates
# /usr/local/libexec, so on the exact machine class this guards against,
# the immediate parent does not exist at check time and a naive
# `-e "$parent"` guard silently no-ops. Walk up to the nearest EXISTING
# ancestor instead — that is the directory mkdir -p will actually descend
# from, so it is the one that must be verified root-owned and non-symlink.
# Stops at the target's own great-great-grandparent (bounded, not a full
# walk to /) so this never misfires on macOS's own /var and /tmp symlinks
# (-> /private/var, /private/tmp) further up the tree.
# Ownership is only enforced when running as root (EUID 0): the non-root
# test harness exercises the symlink check alone.
assert_safe_install_target() {
  local target="$1"
  if [[ -L "$target" ]]; then
    echo "Error: refusing to install through symlink: $target" >&2
    exit 1
  fi
  [[ "$(id -u)" -eq 0 ]] || return 0

  local path="$target" depth=0 max_depth=4
  while [[ $depth -lt $max_depth ]]; do
    path="$(dirname "$path")"
    depth=$((depth + 1))
    [[ "$path" == "/" ]] && break
    if [[ -e "$path" ]]; then
      if [[ -L "$path" ]]; then
        echo "Error: refusing to install under symlinked ancestor: $path" >&2
        exit 1
      fi
      local owner_uid
      owner_uid="$(stat -f '%u' "$path" 2>/dev/null || stat -c '%u' "$path")"
      if [[ "$owner_uid" != "0" ]]; then
        echo "Error: refusing to install into $target — nearest existing ancestor $path is not root-owned (uid=$owner_uid)" >&2
        exit 1
      fi
      break
    fi
  done
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
# Re-check immediately after creation and BEFORE chown/chmod: the ancestor
# check above and this mkdir are not atomic, so a TOCTOU window exists if
# an ancestor directory remained writable by a non-root user between the
# two. chown/chmod on a symlink follow it — running them before this check
# would turn the guard into an arbitrary-path chown-to-root primitive
# instead of a defense against one.
if [[ -L "$LIBEXEC_DIR" ]]; then
  echo "Error: $LIBEXEC_DIR became a symlink after creation — aborting" >&2
  exit 1
fi
chown root:wheel "$LIBEXEC_DIR"
chmod 755 "$LIBEXEC_DIR"

cp "$REPO_ROOT/scripts/disk_frontier_scan.py" "$LIBEXEC_DIR/disk_frontier_scan.py"
chown root:wheel "$LIBEXEC_DIR/disk_frontier_scan.py"
chmod 755 "$LIBEXEC_DIR/disk_frontier_scan.py"

mkdir -p "$STATE_DIR"
if [[ -L "$STATE_DIR" ]]; then
  echo "Error: $STATE_DIR became a symlink after creation — aborting" >&2
  exit 1
fi
chown root:wheel "$STATE_DIR"
chmod 755 "$STATE_DIR"

sed -e "s|@USER_HOME@|$USER_HOME|g" "$PLIST_TEMPLATE" > "$PLIST_DST"
chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"

launchctl bootout system "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST"

echo "Installed and bootstrapped com.jleechanorg.disk-magician-frontier-root."
launchctl print system/com.jleechanorg.disk-magician-frontier-root | head -n 15 || true
