#!/usr/bin/env bash
# install_cwd_scanner.sh — one-time root install of the passwordless cwd scanner
# (bead disk_magician-kub3 option a). Linux only.
#
# Installs /usr/local/sbin/diskm-cwd-scan (root:root 0755, read-only /proc cwd
# walker) and /etc/sudoers.d/diskm-cwd-scan (NOPASSWD, no arguments), validates
# the sudoers file with visudo, then proves `sudo -n` works as the target user.
#
# Usage: sudo bash scripts/install_cwd_scanner.sh [--user <username>] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/diskm_cwd_scan.py"
BIN=/usr/local/sbin/diskm-cwd-scan
SUDOERS=/etc/sudoers.d/diskm-cwd-scan
TARGET_USER="${SUDO_USER:-$(id -un)}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) TARGET_USER="${2:?--user needs a name}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) echo "Usage: sudo bash $0 [--user <username>] [--dry-run]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ "$(uname -s)" == Linux ]] || { echo "Error: Linux only" >&2; exit 1; }
[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Error: unsafe user name '$TARGET_USER'" >&2; exit 1; }
[[ "$TARGET_USER" != root ]] || { echo "Error: run via sudo from the target user, or pass --user" >&2; exit 1; }
id "$TARGET_USER" >/dev/null 2>&1 || { echo "Error: no such user '$TARGET_USER'" >&2; exit 1; }
[[ -f "$SRC" ]] || { echo "Error: missing $SRC" >&2; exit 1; }

# `""` forbids any argument, so the rule can only ever run the bare helper.
RULE="$TARGET_USER ALL=(root) NOPASSWD: $BIN \"\""

if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] install $SRC -> $BIN (root:root 0755)"
  echo "[dry-run] write $SUDOERS (root:root 0440): $RULE"
  echo "[dry-run] visudo -cf, then sudo -n -u $TARGET_USER $BIN"
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || { echo "Error: run as root (sudo bash $0)" >&2; exit 1; }
command -v visudo >/dev/null || { echo "Error: visudo not found" >&2; exit 1; }

tmp_bin="$(mktemp /usr/local/sbin/.diskm-cwd-scan.XXXXXX)"
tmp_rule="$(mktemp /etc/sudoers.d/.diskm-cwd-scan.XXXXXX)"
trap 'rm -f "$tmp_bin" "$tmp_rule"' EXIT

install -m 0755 -o root -g root "$SRC" "$tmp_bin"
printf '%s\n' "$RULE" >"$tmp_rule"
chown root:root "$tmp_rule"
chmod 0440 "$tmp_rule"
visudo -cf "$tmp_rule" >/dev/null || { echo "Error: sudoers rule failed visudo" >&2; exit 1; }

# Helper first: the rule never exists without its target. Both renames are atomic.
mv -f "$tmp_bin" "$BIN"
mv -f "$tmp_rule" "$SUDOERS"
visudo -c >/dev/null || { rm -f "$SUDOERS"; echo "Error: sudoers failed global visudo -c; rule removed" >&2; exit 1; }

count="$(sudo -n -u "$TARGET_USER" sudo -n "$BIN" | tr -cd '\0' | wc -c)"
[[ "$count" -gt 0 ]] || { echo "Error: verification as $TARGET_USER returned no records" >&2; exit 1; }
echo "Installed $BIN and $SUDOERS; verified passwordless scan as $TARGET_USER ($count processes)."
