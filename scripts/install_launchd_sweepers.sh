#!/usr/bin/env bash
# install_launchd_sweepers.sh — Install disk_magician weekly/daily launchd sweepers.
#
# Templates: launchd/com.disk-magician.*.plist (@REPO_ROOT@, @HOME@, @BASH@)
# Usage: ./scripts/install_launchd_sweepers.sh [--unload-legacy] [plist-name ...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHD_SRC="$REPO_ROOT/launchd"
DEST="${DISK_MAGICIAN_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
UNLOAD_LEGACY=false
SELECTED=()

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --unload-legacy) UNLOAD_LEGACY=true; shift ;;
    -h|--help) sed -n '1,12p' "$0"; exit 0 ;;
    *) SELECTED+=("$1"); shift ;;
  esac
done

resolve_bash() {
  if [[ -n "${DISK_MAGICIAN_BASH:-}" && -x "${DISK_MAGICIAN_BASH}" ]]; then
    echo "${DISK_MAGICIAN_BASH}"; return
  fi
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash; do
    [[ -x "$candidate" ]] && echo "$candidate" && return
  done
  echo "/bin/bash"
}

BASH_BIN="$(resolve_bash)"
mkdir -p "$DEST"

legacy_labels=(
  com.jleechan.disk-magician-gemini-dedup
  com.jleechan.disk-magician-playwright-dedup
  com.jleechan.disk-magician-colima-prune
  com.jleechan.disk-magician-hermes-vacuum
  com.jleechan.disk-magician-apfs-snapshots
  com.jleechan.disk-magician-worktree-venvs
  com.jleechan.disk-magician-sweeper-health
)

if [[ "$UNLOAD_LEGACY" == true ]]; then
  for label in "${legacy_labels[@]}"; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$DEST/${label}.plist"
    echo "unloaded legacy $label"
  done
fi

install_plist() {
  local src="$1" label dst
  label="$(grep -A1 '<key>Label</key>' "$src" | tail -1 | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p')"
  [[ -n "$label" ]] || { echo "skip (no label): $src" >&2; return 1; }
  dst="$DEST/${label}.plist"
  sed -e "s|@REPO_ROOT@|$REPO_ROOT|g" \
      -e "s|@HOME@|$HOME|g" \
      -e "s|@BASH@|$BASH_BIN|g" \
      "$src" > "$dst"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$dst"
  echo "installed $label -> $dst"
}

if [[ ${#SELECTED[@]} -gt 0 ]]; then
  for name in "${SELECTED[@]}"; do
    src="$LAUNCHD_SRC/${name}"
    [[ -f "$src" ]] || src="$LAUNCHD_SRC/com.disk-magician.${name%.plist}.plist"
    [[ -f "$src" ]] || { echo "not found: $name" >&2; exit 2; }
    install_plist "$src"
  done
else
  shopt -s nullglob
  for src in "$LAUNCHD_SRC"/com.disk-magician.*.plist; do
    install_plist "$src"
  done
fi

echo "Done. Logs under /tmp/disk-magician-*.log"
