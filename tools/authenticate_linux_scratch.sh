#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'authenticate_linux_scratch: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Linux ]] || fail "run this entry point on jeff-ubuntu (Linux)"
[[ -t 0 && -t 1 ]] || fail "run from an interactive terminal so sudo can authenticate directly"

candidate="$HOME/.local/share/disk-magician/candidates/5793451d927a944ba2d013244aa7aa42db881dcd/venv/bin/diskm"
config="$HOME/.config/disk-magician/linux-scratch.json"
state="$HOME/.disk_magician_state"
[[ -x "$candidate" && ! -L "$candidate" ]] || fail "pinned diskm candidate is missing: $candidate"
shopt -s nullglob
volume_sources=("$HOME/.local/share/disk-magician/candidates/5793451d927a944ba2d013244aa7aa42db881dcd/venv"/lib/python*/site-packages/disk_magician/scripts/volume.py)
shopt -u nullglob
[[ "${#volume_sources[@]}" == 1 && -f "${volume_sources[0]}" && ! -L "${volume_sources[0]}" ]] || fail "pinned candidate volume source is missing or ambiguous"
volume_hash=$( sha256sum "${volume_sources[0]}" | awk "{print \$1}") || fail "cannot verify candidate volume source"
[[ "$volume_hash" == "d250c500615313c1520601bdfd8cd7c18cffe89583d2059fadb6111100b7d699" ]] || fail "candidate volume source hash mismatch: $volume_hash"
[[ -f "$config" && ! -L "$config" ]] || fail "expected Linux scratch config is missing or unsafe: $config"
mode="$(stat -c '%a' -- "$config")" || fail "cannot verify config permissions"
[[ "$mode" == 600 ]] || fail "config permissions must be 600 (found $mode)"

# sudo reads its password from this terminal; the script never captures it.
sudo -v || fail "sudo authentication failed"

set +e
status="$(DISK_MAGICIAN_CONFIG="$config" DISK_MAGICIAN_STATE_DIR="$state" "$candidate" volume status --json)"
status_rc=$?
set -e
printf '%s\n' "$status"
[[ "$status_rc" == 0 || "$status_rc" == 1 ]] || fail "pinned volume status failed (rc=$status_rc)"

# Require the CLI's exact active-volume identity check before handing back control.
DISK_MAGICIAN_CONFIG="$config" DISK_MAGICIAN_STATE_DIR="$state" "$candidate" volume path scratch >/dev/null \
  || fail "Scratch is not an active, identity-verified mount; no migration was attempted"

printf '%s\n' "Authentication ready. Continue with the independent I2 gate, then the assistant will perform the native migration and timer proof."
