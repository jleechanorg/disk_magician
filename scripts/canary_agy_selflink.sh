#!/usr/bin/env bash
# canary_agy_selflink.sh — Cross-repo AGY self-link and mutable state-root corruption canary.
#
# Enforces the hard mutable state-root symlink rule:
# 1. Host .gemini must be a real directory, not a symlink.
# 2. No entry within .gemini may be a self-link or recursive cyclic link.
# 3. Session .gemini directories must not be root aliases to the host .gemini.
# 4. Detaches dangerous root aliases before any materialization writes can occur.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERBOSE=false
DETACH=false
TARGET_HOST_GEMINI="${DISK_MAGICIAN_HOST_GEMINI:-$HOME/.gemini}"
TARGET_SESSIONS_ROOT="${DISK_MAGICIAN_AO_SESSIONS:-$HOME/.ao-sessions}"

usage() {
  cat <<HELP
Usage: $(basename "$0") [--verbose] [--detach] [--host-dir <dir>] [--sessions-dir <dir>] [-h|--help]

Options:
  --verbose          Enable verbose logging.
  --detach           Safely detach / remove dangerous root aliases found in sessions.
  --host-dir <dir>   Path to host .gemini root (default: \$HOME/.gemini).
  --sessions-dir <dir> Path to sessions root (default: \$HOME/.ao-sessions).
  -h, --help         Show this help.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=true; shift ;;
    --detach) DETACH=true; shift ;;
    --host-dir) TARGET_HOST_GEMINI="$2"; shift 2 ;;
    --sessions-dir) TARGET_SESSIONS_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() {
  if [[ "$VERBOSE" == true ]]; then
    echo "[canary_agy_selflink] $*"
  fi
}

error() {
  echo "[canary_agy_selflink:ERROR] $*" >&2
}

ERRORS=0

# Check 1: Host .gemini existence and type
if [[ -e "$TARGET_HOST_GEMINI" ]]; then
  if [[ -L "$TARGET_HOST_GEMINI" ]]; then
    error "Host state root $TARGET_HOST_GEMINI is a symlink (violates mutable state-root invariant)."
    ERRORS=$((ERRORS + 1))
  elif [[ ! -d "$TARGET_HOST_GEMINI" ]]; then
    error "Host state root $TARGET_HOST_GEMINI is not a directory."
    ERRORS=$((ERRORS + 1))
  else
    log "Host state root $TARGET_HOST_GEMINI is a regular directory (PASS)."
  fi
fi

# Check 2: Scan for internal self-links / circular symlinks inside host .gemini
if [[ -d "$TARGET_HOST_GEMINI" && ! -L "$TARGET_HOST_GEMINI" ]]; then
  HOST_REAL="$(cd "$TARGET_HOST_GEMINI" 2>/dev/null && pwd -P || echo "")"
  while IFS= read -r link_entry; do
    [[ -n "$link_entry" ]] || continue
    # Resolve target
    target="$(readlink "$link_entry" 2>/dev/null || echo "")"
    if [[ -z "$target" ]]; then
      continue
    fi

    # Check if target equals link path (direct self-link)
    if [[ "$target" == "$link_entry" ]]; then
      error "Direct self-link detected at $link_entry -> $target"
      ERRORS=$((ERRORS + 1))
      continue
    fi

    # Check if target resolves to the link itself or canonical parent
    resolved_target="$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$link_entry" 2>/dev/null || echo "")"
    if [[ "$resolved_target" == "$link_entry" ]]; then
      error "Circular self-link detected at $link_entry (resolves to itself)"
      ERRORS=$((ERRORS + 1))
    fi
  done < <(find "$TARGET_HOST_GEMINI" -type l 2>/dev/null || true)
fi

# Check 3: Check session .gemini directories
if [[ -d "$TARGET_SESSIONS_ROOT" && -d "$TARGET_HOST_GEMINI" ]]; then
  HOST_REAL="$(cd "$TARGET_HOST_GEMINI" 2>/dev/null && pwd -P || echo "")"

  while IFS= read -r session_gemini; do
    [[ -n "$session_gemini" ]] || continue
    if [[ -L "$session_gemini" ]]; then
      session_real="$(cd "$session_gemini" 2>/dev/null && pwd -P || echo "")"
      if [[ -n "$HOST_REAL" && "$session_real" == "$HOST_REAL" ]]; then
        error "Session state root $session_gemini is a whole-directory symlink to host root $TARGET_HOST_GEMINI!"
        ERRORS=$((ERRORS + 1))
        if [[ "$DETACH" == true ]]; then
          echo "[canary_agy_selflink] Detaching dangerous root symlink: $session_gemini"
          rm -f "$session_gemini"
          mkdir -p "$session_gemini"
          echo "detached $(date -u +%Y%m%dT%H%M%SZ)" > "$session_gemini/.detached_by_canary"
        fi
      fi
    fi
  done < <(find "$TARGET_SESSIONS_ROOT" -maxdepth 3 -type l -name ".gemini" 2>/dev/null || true)
fi

if [[ "$ERRORS" -gt 0 ]]; then
  error "Canary check failed with $ERRORS error(s)."
  exit 1
fi

log "All AGY state-root and self-link canary checks passed."
exit 0
