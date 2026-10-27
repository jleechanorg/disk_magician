#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'create_mac_scratch: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail "run this entry point on the Mac"
[[ -t 0 && -t 1 ]] || fail "run from an interactive terminal for diskutil's direct passphrase prompt"

candidate="$HOME/.local/share/disk-magician/candidates/5793451d927a944ba2d013244aa7aa42db881dcd/venv/bin/diskm"
config="$HOME/.config/disk-magician/mac-scratch.json"
state="$HOME/.disk_magician_state"
[[ -x "$candidate" && ! -L "$candidate" ]] || fail "pinned diskm candidate is missing: $candidate"
shopt -s nullglob
volume_sources=("$HOME/.local/share/disk-magician/candidates/5793451d927a944ba2d013244aa7aa42db881dcd/venv"/lib/python*/site-packages/disk_magician/scripts/volume.py)
shopt -u nullglob
[[ "${#volume_sources[@]}" == 1 && -f "${volume_sources[0]}" && ! -L "${volume_sources[0]}" ]] || fail "pinned candidate volume source is missing or ambiguous"
volume_hash=$( shasum -a 256 "${volume_sources[0]}" | awk "{print \$1}") || fail "cannot verify candidate volume source"
[[ "$volume_hash" == "d250c500615313c1520601bdfd8cd7c18cffe89583d2059fadb6111100b7d699" ]] || fail "candidate volume source hash mismatch: $volume_hash"
[[ -f "$config" && ! -L "$config" ]] || fail "expected Mac scratch config is missing or unsafe: $config"
mode="$(stat -f '%Lp' "$config")" || fail "cannot verify config permissions"
[[ "$mode" == 600 ]] || fail "config permissions must be 600 (found $mode)"

run_diskm() {
  DISK_MAGICIAN_CONFIG="$config" DISK_MAGICIAN_STATE_DIR="$state" "$candidate" volume "$@"
}

set +e
status="$(run_diskm status --json)"
status_rc=$?
set -e
printf '%s\n' "$status"
[[ "$status_rc" == 0 || "$status_rc" == 1 ]] || fail "volume status failed (rc=$status_rc)"

# The public CLI proves an existing volume is active. Otherwise its own dry-run
# and guarded execution recheck fit, identity, free-space headroom, and recovery.
if run_diskm path scratch >/dev/null 2>&1; then
  printf '%s\n' "Scratch is already active and identity-verified; no create operation was needed."
else
  run_diskm create scratch
  run_diskm create scratch --execute
  run_diskm status --json
  run_diskm path scratch >/dev/null || fail "created volume did not pass the CLI's final identity check"
  printf '%s\n' "Encrypted Scratch is active. The passphrase was entered directly at diskutil's terminal prompt."
fi
