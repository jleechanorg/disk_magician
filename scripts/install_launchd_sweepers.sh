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
LAUNCHD_SRC="${DISK_MAGICIAN_LAUNCHD_SRC:-$REPO_ROOT/launchd}"
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

# Concurrency lock (disk_magician-4mw): mkdir-based lock mirroring
# cleanup_worktree_venvs.sh's acquire_cleanup_venvs_lock (bead
# disk_magician-w7m). Contention = log one line and skip this run entirely
# (exit 0) -- never queue, never block. Added 2026-09-07 after the fleet was
# observed flapping with a SEPARATE agent session on this machine
# independently running this exact installer -- the leading hypothesis being
# two uncoordinated invocations interleaving install_plist()'s per-label
# `launchctl bootout` then `launchctl bootstrap` calls against each other.
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
LOCK_DIR="$STATE_DIR/install_launchd_sweepers.lock"
LOCK_TTL_SEC="${DISK_MAGICIAN_INSTALL_SWEEPERS_LOCK_TTL_SEC:-900}"

acquire_install_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
  fi
  local held_pid age
  held_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  age=$(( $(date +%s) - $(stat -f '%m' "$LOCK_DIR" 2>/dev/null || stat -c '%Y' "$LOCK_DIR" 2>/dev/null || date +%s) ))
  if [[ "$age" -gt "$LOCK_TTL_SEC" ]] && { [[ -z "$held_pid" ]] || ! kill -0 "$held_pid" 2>/dev/null; }; then
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ > "$LOCK_DIR/pid"
      trap 'rm -rf "$LOCK_DIR"' EXIT
      return 0
    fi
  fi
  echo "install_launchd_sweepers: already running (lock held by pid ${held_pid:-?}, age ${age}s) -- not queuing" >&2
  return 1
}

acquire_install_lock || exit 0

retired_labels=(
  com.disk-magician.gemini-dedup
  com.jleechan.disk-magician-gemini-dedup
)

# Whole-root AO session .gemini aliases violate AO's selective materialization
# ownership. Retire every historical label on all installer paths.
for label in "${retired_labels[@]}"; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  if [[ -f "$DEST/${label}.plist" ]]; then
    mkdir -p "$DEST/.retired"
    mv -f "$DEST/${label}.plist" "$DEST/.retired/${label}.plist"
  fi
  echo "retired $label"
done

legacy_labels=(
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
  # Preflight (disk_magician-zwb): plutil -lint alone does NOT catch a plist
  # truncated to a top-level <array> with no <dict> wrapper -- that's
  # syntactically legal plist XML and passes -lint clean (the actual
  # 2026-08-31 mass-corruption failure mode). Checking for a top-level Label
  # key is the cheapest reliable signal that the <dict> wrapper survived.
  # Never bootstrap a plist that fails either check.
  if ! plutil -lint "$dst" >/dev/null 2>&1; then
    echo "ABORT: $dst fails plutil -lint -- refusing to bootstrap a malformed plist for $label" >&2
    rm -f "$dst"
    return 1
  fi
  if ! plutil -extract Label raw -o - "$dst" >/dev/null 2>&1; then
    echo "ABORT: $dst has no top-level Label key (likely missing its <dict> wrapper) -- refusing to bootstrap $label" >&2
    rm -f "$dst"
    return 1
  fi
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

ERRORS=0

if [[ ${#SELECTED[@]} -gt 0 ]]; then
  for name in "${SELECTED[@]}"; do
    if [[ -f "$name" ]]; then
      src="$name"
    else
      src="$LAUNCHD_SRC/${name}"
      [[ -f "$src" ]] || src="$LAUNCHD_SRC/com.disk-magician.${name%.plist}.plist"
      [[ -f "$src" ]] || src="$LAUNCHD_SRC/com.disk-magician.${name%.plist}.plist.template"
      [[ -f "$src" ]] || src="$LAUNCHD_SRC/${name}.template"
      [[ -f "$src" ]] || src="$LAUNCHD_SRC/${name}.plist"
      [[ -f "$src" ]] || src="$LAUNCHD_SRC/${name}.plist.template"
    fi
    [[ -f "$src" ]] || { echo "not found: $name" >&2; exit 2; }
    if [[ "$name" == *apfs-snapshots* ]]; then
      install_launchdaemon "$src" || ERRORS=$(( ERRORS + 1 ))
    else
      install_plist "$src" || ERRORS=$(( ERRORS + 1 ))
    fi
  done
else
  shopt -s nullglob
  for src in "$LAUNCHD_SRC"/com.disk-magician.*.plist "$LAUNCHD_SRC"/com.disk-magician.*.plist.template; do
    if [[ "$(basename "$src")" == "com.disk-magician.apfs-snapshots.plist" ]]; then
      echo "Skipping com.disk-magician.apfs-snapshots.plist (requires root privileges; run: sudo ./scripts/install_launchd_sweepers.sh apfs-snapshots to install as a system LaunchDaemon)"
      continue
    fi
    install_plist "$src" || ERRORS=$(( ERRORS + 1 ))
  done
  # Control-loop jobs (distinct com.jleechanorg.disk-magician-* prefix, .plist.template
  # suffix). Same install_plist() path — label/dst are read from file content, not
  # filename. e.g. com.jleechanorg.disk-magician-drilldown.plist.template (4h residual
  # drilldown cadence, see roadmap/2026-07-11-total-coverage-snapshot-v2.md).
  for src in "$LAUNCHD_SRC"/com.jleechanorg.disk-magician-*.plist.template; do
    install_plist "$src" || ERRORS=$(( ERRORS + 1 ))
  done
fi

if [[ "$ERRORS" -gt 0 ]]; then
  echo "Encountered $ERRORS error(s) during sweeper installation." >&2
  exit 1
fi

echo "Done. Logs under /tmp/disk-magician-*.log"
