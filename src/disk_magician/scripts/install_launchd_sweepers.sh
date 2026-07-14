#!/usr/bin/env bash
# install_launchd_sweepers.sh — Install disk_magician weekly/daily launchd sweepers.
#
# Templates: launchd/com.disk-magician.*.plist (@REPO_ROOT@, @HOME@, @BASH@)
#            launchd/com.jleechanorg.disk-magician-*.plist.template (same placeholders;
#            distinct prefix for control-loop jobs, e.g. residual-drilldown, that are
#            not part of the weekly/daily sweeper family)
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

install_launchdaemon() {
  local src="$1" label dst
  label="$(grep -A1 '<key>Label</key>' "$src" | tail -1 | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p')"
  [[ -n "$label" ]] || { echo "skip (no label): $src" >&2; return 1; }
  
  # Clean up legacy user-mode LaunchAgent if present
  local user_dst="$DEST/${label}.plist"
  if [[ -f "$user_dst" ]]; then
    echo "Removing legacy user LaunchAgent: $user_dst"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$user_dst"
  fi

  dst="/Library/LaunchDaemons/${label}.plist"
  echo "Installing root LaunchDaemon: $label -> $dst (requires sudo)"
  sed -e "s|@REPO_ROOT@|$REPO_ROOT|g" \
      -e "s|@HOME@|$HOME|g" \
      -e "s|@BASH@|$BASH_BIN|g" \
      "$src" | sudo tee "$dst" >/dev/null
  sudo chown root:wheel "$dst"
  sudo launchctl bootout system "$dst" 2>/dev/null || true
  sudo launchctl bootstrap system "$dst"

  # Automatically configure passwordless sudoers rule for diskutil apfs deleteSnapshot
  local sudoers_file="/etc/sudoers.d/disk_magician"
  if [[ ! -f "$sudoers_file" ]]; then
    local target_user="${SUDO_USER:-$(id -un)}"
    echo "Creating passwordless sudoers entry for $target_user: $sudoers_file"
    echo "${target_user} ALL=(ALL) NOPASSWD: /usr/sbin/diskutil apfs deleteSnapshot *" | sudo tee "$sudoers_file" >/dev/null
    sudo chmod 440 "$sudoers_file"
  fi
  echo "Successfully installed and bootstrapped root LaunchDaemon $label"
}

if [[ ${#SELECTED[@]} -gt 0 ]]; then
  for name in "${SELECTED[@]}"; do
    src="$LAUNCHD_SRC/${name}"
    [[ -f "$src" ]] || src="$LAUNCHD_SRC/com.disk-magician.${name%.plist}.plist"
    [[ -f "$src" ]] || { echo "not found: $name" >&2; exit 2; }
    if [[ "$name" == *apfs-snapshots* ]]; then
      install_launchdaemon "$src"
    else
      install_plist "$src"
    fi
  done
else
  shopt -s nullglob
  for src in "$LAUNCHD_SRC"/com.disk-magician.*.plist; do
    if [[ "$(basename "$src")" == "com.disk-magician.apfs-snapshots.plist" ]]; then
      echo "Skipping com.disk-magician.apfs-snapshots.plist (requires root privileges; run: sudo ./scripts/install_launchd_sweepers.sh apfs-snapshots to install as a system LaunchDaemon)"
      continue
    fi
    install_plist "$src"
  done
  # Control-loop jobs (distinct com.jleechanorg.disk-magician-* prefix, .plist.template
  # suffix). Same install_plist() path — label/dst are read from file content, not
  # filename. e.g. com.jleechanorg.disk-magician-drilldown.plist.template (4h residual
  # drilldown cadence, see roadmap/2026-07-11-total-coverage-snapshot-v2.md).
  for src in "$LAUNCHD_SRC"/com.jleechanorg.disk-magician-*.plist.template; do
    install_plist "$src"
  done
fi

echo "Done. Logs under /tmp/disk-magician-*.log"
