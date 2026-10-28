#!/usr/bin/env bash
# Canonical single-source-of-truth resolver for agent scratch/temp directories.
# Resolves the provisioned diskm Scratch volume via `diskm volume path scratch`
# (or ~/.config/disk-magician/config.json), falling back to /tmp only when no
# Scratch volume is configured on the host.
#
# Usage:
#   diskm scratch-dir            # prints scratch root (e.g. /Volumes/diskm-scratch or /home/jleechan/Scratch or /tmp)
#   diskm scratch-dir <subpath>  # mkdir -p <scratch-root>/<subpath> and prints it

set -euo pipefail

if [ "$#" -gt 0 ]; then
  if [ -z "${1:-}" ]; then
    echo "scratch-dir: invalid subpath: (empty)" >&2
    exit 2
  fi
  SUBPATH="${1#/}"
  case "$SUBPATH" in
    ""|*..*)
      echo "scratch-dir: invalid subpath: $1" >&2
      exit 2
      ;;
  esac
fi

resolve_scratch_root() {
  local root=""
  local script_dir diskm_bin volume_rc=3
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  diskm_bin="${DISK_MAGICIAN_DISKM_BIN:-}"
  if [ -n "$diskm_bin" ]; then
    if [ ! -x "$diskm_bin" ]; then
      echo "scratch-dir: configured Disk Magician CLI is unavailable" >&2
      return 75
    fi
    if root="$("$diskm_bin" volume path scratch 2>/dev/null)"; then volume_rc=0; else volume_rc=$?; fi
  elif [ -x "$script_dir/../disk_magician.sh" ]; then
    if root="$("$script_dir/../disk_magician.sh" volume path scratch 2>/dev/null)"; then volume_rc=0; else volume_rc=$?; fi
  elif command -v diskm >/dev/null 2>&1; then
    if root="$(diskm volume path scratch 2>/dev/null)"; then volume_rc=0; else volume_rc=$?; fi
  elif command -v disk-magician >/dev/null 2>&1; then
    if root="$(disk-magician volume path scratch 2>/dev/null)"; then volume_rc=0; else volume_rc=$?; fi
  elif [ -x "${HOME}/.local/bin/diskm" ]; then
    if root="$("${HOME}/.local/bin/diskm" volume path scratch 2>/dev/null)"; then volume_rc=0; else volume_rc=$?; fi
  elif [ -x "${HOME}/.local/bin/disk-magician" ]; then
    if root="$("${HOME}/.local/bin/disk-magician" volume path scratch 2>/dev/null)"; then volume_rc=0; else volume_rc=$?; fi
  fi

  if [ "$volume_rc" -eq 0 ]; then
    [[ -n "$root" ]] || {
      echo "scratch-dir: active Scratch volume returned no path" >&2
      return 75
    }
    printf '%s\n' "$root"
    return 0
  fi
  if [ "$volume_rc" -eq 3 ]; then
    printf '/tmp\n'
    return 0
  fi

  echo "scratch-dir: Scratch volume lookup failed (rc=$volume_rc)" >&2
  return 75
}

SCRATCH_ROOT="$(resolve_scratch_root)"

if [ "$#" -gt 0 ]; then
  TARGET="${SCRATCH_ROOT%/}/${SUBPATH}"
  PHYSICAL_ROOT="$(cd -- "$SCRATCH_ROOT" 2>/dev/null && pwd -P)" || {
    echo "scratch-dir: Scratch root cannot be resolved" >&2
    exit 75
  }
  CURRENT="$PHYSICAL_ROOT"
  IFS=/ read -r -a COMPONENTS <<<"$SUBPATH"
  for COMPONENT in "${COMPONENTS[@]}"; do
    [ -n "$COMPONENT" ] || continue
    NEXT="$CURRENT/$COMPONENT"
    if [ -L "$NEXT" ]; then
      echo "scratch-dir: subpath contains a symlink: $COMPONENT" >&2
      exit 75
    fi
    if [ -e "$NEXT" ]; then
      CURRENT="$(cd -- "$NEXT" 2>/dev/null && pwd -P)" || {
        echo "scratch-dir: subpath component cannot be resolved: $COMPONENT" >&2
        exit 75
      }
      case "$CURRENT" in
        "$PHYSICAL_ROOT"|"$PHYSICAL_ROOT"/*) ;;
        *) echo "scratch-dir: subpath escapes Scratch root" >&2; exit 75 ;;
      esac
    else
      CURRENT="$NEXT"
    fi
  done
  mkdir -p "$TARGET"
  FINAL="$(cd -- "$TARGET" 2>/dev/null && pwd -P)" || {
    echo "scratch-dir: created subpath cannot be resolved" >&2
    exit 75
  }
  case "$FINAL" in
    "$PHYSICAL_ROOT"|"$PHYSICAL_ROOT"/*) ;;
    *) echo "scratch-dir: created subpath escapes Scratch root" >&2; exit 75 ;;
  esac
  printf '%s\n' "$TARGET"
else
  printf '%s\n' "$SCRATCH_ROOT"
fi
