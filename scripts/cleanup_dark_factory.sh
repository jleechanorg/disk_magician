#!/usr/bin/env bash
# cleanup_dark_factory.sh — Retention for dark-factory artifacts, which have
# no upstream pruning: installed releases, per-run dirs, and df-* AO session
# homes. Defaults to dry-run; pass --clean to delete.
#
# Never deleted: releases referenced by ~/.local/bin symlinks, systemd user
# units/drop-ins, or a live process; the newest --keep-releases releases;
# anything with a file modified inside --days (floor: safety_min_stale_days).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

DRY_RUN=true
DAYS=30
KEEP_RELEASES=3
RELEASES_DIR="${HOME}/.local/share/dark-factory/releases"
RUNS_DIR="${HOME}/.dark-factory/runs"
SESSIONS_DIR="${HOME}/.ao-sessions"
BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${HOME}/.config/systemd/user"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--days N] [--keep-releases N] [-h|--help]

  --clean            Actually delete (default: dry-run preview)
  --days N           Staleness threshold for runs/sessions/releases (default: 30, min 7)
  --keep-releases N  Always keep the N newest releases (default: 3)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --days)    shift; DAYS="${1:?--days requires a number}" ;;
    --keep-releases) shift; KEEP_RELEASES="${1:?--keep-releases requires a number}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

floor="$(safety_min_stale_days)"
(( DAYS < floor )) && DAYS="$floor"
sandbox_guard_roots "$RELEASES_DIR" "$RUNS_DIR" "$SESSIONS_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Every path a live process is using (exe, cwd, argv). Fail closed for --clean
# when processes cannot be inspected.
LIVE_REFS="$(mktemp)"
trap 'rm -f "$LIVE_REFS"' EXIT
if [[ -d /proc/self ]]; then
  for p in /proc/[0-9]*; do
    { readlink "$p/exe"; readlink "$p/cwd"; tr '\0' '\n' <"$p/cmdline"; } 2>/dev/null || true
  done >"$LIVE_REFS"
else
  # macOS: argv from ps, cwd/exe from lsof.
  ps -axww -o command= >"$LIVE_REFS" 2>/dev/null || true
  lsof_out="$(lsof -nP -d cwd,txt -Fn 2>/dev/null | sed -n 's/^n//p' || true)"
  if [[ -z "$lsof_out" && "$DRY_RUN" == false ]]; then
    echo "Cannot inspect live processes (no /proc, lsof empty) — refusing --clean." >&2
    exit 1
  fi
  printf '%s\n' "$lsof_out" >>"$LIVE_REFS"
fi
# Our own argv must be visible, or the scan is not seeing processes at all.
if [[ "$DRY_RUN" == false ]] && ! grep -qF "cleanup_dark_factory" "$LIVE_REFS"; then
  echo "Live-process scan did not see this process — refusing --clean." >&2
  exit 1
fi

is_live() { grep -qF "$1" "$LIVE_REFS"; }

# Resolve each stdin path through every symlink (relative or chained).
realpaths() { python3 -c 'import os,sys
for l in sys.stdin:
    l = l.rstrip("\n")
    if l: print(os.path.realpath(l))'; }

# A symlinked root would let rm act on its target outside the gated path.
root_ok() {
  if [[ -L "$1" ]]; then log "SKIP root (symlink): $1"; return 1; fi
  [[ -d "$1" ]]
}

# rc 0 when no file under $1 was modified within $DAYS days. Fails closed: if
# find cannot read part of the tree, recency is unknown and the path is kept.
is_stale() {
  local hit
  hit="$(find "$1" -newermt "-${DAYS} days" -print -quit 2>/dev/null)" || return 1
  [[ -z "$hit" ]]
}

total_kb=0
count=0
remove() {
  local path="$1" kind="$2" reason kb
  if ! reason="$(safety_gate "$path")"; then
    log "PROTECTED ($reason): $path"
    return 0
  fi
  kb="$(du -sk "$path" 2>/dev/null | awk '{print $1}')"
  kb="${kb:-0}"
  total_kb=$(( total_kb + kb ))
  count=$(( count + 1 ))
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would remove $kind: $path (${kb} KB)"
    return 0
  fi
  chmod -R u+w "$path" 2>/dev/null || true
  if rm -rf "$path"; then
    deletion_log "cleanup_dark_factory" "remove_$kind" "$kb" "$path"
  else
    log "WARN: failed to remove $path"
  fi
}

# --- releases ---
if root_ok "$RELEASES_DIR"; then
  keep="$(mktemp)"
  {
    find "$BIN_DIR" -maxdepth 1 -type l 2>/dev/null | realpaths || true
    find "$UNIT_DIR" -type f 2>/dev/null -exec cat {} + 2>/dev/null | sed "s#%h#$HOME#g" \
      | { grep -oE "$RELEASES_DIR/[^/\"' ]+" || true; } || true
    grep -oE "$RELEASES_DIR/[^/\"' ]+" "$LIVE_REFS" || true
  } | { grep -oE "$RELEASES_DIR/[^/]+" || true; } | sort -u >"$keep"
  newest=0
  while IFS= read -r rel; do
    rel="${rel%/}"
    [[ -L "$rel" ]] && continue
    echo "$rel" >>"$keep"
    newest=$(( newest + 1 ))
    (( newest >= KEEP_RELEASES )) && break
  done < <(ls -1td "$RELEASES_DIR"/*/ 2>/dev/null || true)
  log "Releases kept (referenced or newest $KEEP_RELEASES): $(sort -u "$keep" | sed 's#.*/##' | cut -c1-7 | tr '\n' ' ')"
  for rel in "$RELEASES_DIR"/*/; do
    rel="${rel%/}"
    [[ -d "$rel" && ! -L "$rel" ]] || continue
    grep -qxF "$rel" "$keep" && continue
    is_stale "$rel" || { log "SKIP release (recent): $rel"; continue; }
    remove "$rel" release
  done
  rm -f "$keep"
fi

# --- runs ---
if root_ok "$RUNS_DIR"; then
  while IFS= read -r -d '' run; do
    [[ -L "$run" ]] && continue
    is_live "$run" && continue
    is_stale "$run" || continue
    remove "$run" run
  done < <(find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -mtime +"$DAYS" -print0)
fi

# --- df-* AO session homes ---
if root_ok "$SESSIONS_DIR"; then
  for sess in "$SESSIONS_DIR"/df-*/; do
    sess="${sess%/}"
    [[ -d "$sess" && ! -L "$sess" ]] || continue
    is_live "$sess" && { log "SKIP session (live process): $sess"; continue; }
    is_stale "$sess" || continue
    remove "$sess" session
  done
fi

mode="Would reclaim"
[[ "$DRY_RUN" == false ]] && mode="Reclaimed"
log "$mode: ${count} item(s), $(( total_kb / 1024 / 1024 )) GiB (${total_kb} KB), threshold ${DAYS}d"
