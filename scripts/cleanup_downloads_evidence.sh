#!/usr/bin/env bash
# cleanup_downloads_evidence.sh — validate-then-expire retention for agent
# evidence spool directories under ~/Downloads (bead jleechan-uwtk).
#
# Provenance: 2026-07-19 incident — a DK2D evidence pipeline produced 9 runs
# in one day (5.3–7.7 GiB each, 55.9 GiB total) into ~/Downloads, where no
# sweeper operates, dropping container free space from 81.7 GiB to 11.3 GB
# (bead jleechan-m4yc). An older sidekick generation added another ~41 GiB.
# Downloads is TCC-protected, so this script is expected to run either
# interactively or from the launchd context that already measures Downloads
# for the frontier supplement.
#
# Policy (all knobs env-first, then config.json, then defaults):
#   - Only TOP-LEVEL directories of EVIDENCE_ROOT whose basename matches one
#     of EVIDENCE_PATTERNS are ever considered. Everything else in Downloads
#     is invisible to this script.
#   - The KEEP_COUNT newest matching dirs (by mtime) are always kept.
#   - Older matching dirs are removed only when their mtime is older than
#     RETENTION_HOURS.
#   - A `.keep` or `.in-use` marker file at the dir root exempts it.
#   - Open files (lsof) exempt it; lsof unavailable/failing is treated as
#     in-use (fail closed).
#   - DRY-RUN by default; pass --clean to actually delete.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/config.json"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/config.json.template"

# Env-first defaults (env wins over config; config wins over these literals).
EVIDENCE_ROOT="${DISK_MAGICIAN_EVIDENCE_ROOT:-$HOME/Downloads}"
RETENTION_HOURS="${DISK_MAGICIAN_EVIDENCE_RETENTION_HOURS:-}"
KEEP_COUNT="${DISK_MAGICIAN_EVIDENCE_KEEP_COUNT:-}"
PATTERNS_RAW="${DISK_MAGICIAN_EVIDENCE_PATTERNS:-}"

CONFIG_RETENTION_HOURS=""
CONFIG_KEEP_COUNT=""
CONFIG_PATTERNS=""
if [[ -f "$CONFIG_FILE" ]]; then
  # Single python read; newline-separated: hours, keep, then patterns.
  CONFIG_BLOB="$(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import json, sys
data = json.load(open(sys.argv[1]))
t = data.get("cleanup_thresholds", {})
print(t.get("downloads_evidence_retention_hours", 72))
print(t.get("downloads_evidence_keep_count", 2))
print(" ".join(data.get("downloads_evidence_patterns") or []))
PY
)"
  CONFIG_RETENTION_HOURS="$(printf '%s\n' "$CONFIG_BLOB" | sed -n 1p)"
  CONFIG_KEEP_COUNT="$(printf '%s\n' "$CONFIG_BLOB" | sed -n 2p)"
  CONFIG_PATTERNS="$(printf '%s\n' "$CONFIG_BLOB" | sed -n 3p)"
fi
RETENTION_HOURS="${RETENTION_HOURS:-${CONFIG_RETENTION_HOURS:-72}}"
KEEP_COUNT="${KEEP_COUNT:-${CONFIG_KEEP_COUNT:-2}}"
PATTERNS_RAW="${PATTERNS_RAW:-${CONFIG_PATTERNS:-}}"
# Broadened 2026-07-21 (pattern drift: the generator began emitting
# DK2D-RUN9-captioned-burned/, dk2d_style_round*/ etc. that escaped the
# original DK2D-EVIDENCE-*/dk2d_evidence_* patterns — 20 escapee dirs found).
# keep-newest + 72h retention + markers still protect anything active.
[[ -n "$PATTERNS_RAW" ]] || PATTERNS_RAW="DK2D-* dk2d_*"

# Portable split (no mapfile — macOS /bin/bash 3.2).
PATTERNS=()
read -r -a PATTERNS <<<"$PATTERNS_RAW"

DRY_RUN=true
for arg in "$@"; do
  case "$arg" in
    --clean) DRY_RUN=false ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
dry_prefix() { [[ "$DRY_RUN" == true ]] && echo "DRY RUN: " || echo ""; }

matches_pattern() {
  local base="$1" pat
  for pat in "${PATTERNS[@]}"; do
    # shellcheck disable=SC2254  # intentional glob match against pattern list
    case "$base" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# has_open_files <dir> — fail closed: lsof unavailable or erroring with
# diagnostics counts as in-use. Mirrors scripts/cleanup_tmp.sh semantics.
has_open_files() {
  local dir="$1" lsof_bin rc=0 out
  if [[ -n "${DISK_MAGICIAN_LSOF_BIN:-}" ]]; then
    lsof_bin="$DISK_MAGICIAN_LSOF_BIN"
  elif [[ -x /usr/sbin/lsof ]]; then
    lsof_bin=/usr/sbin/lsof
  elif ! lsof_bin=$(command -v lsof 2>/dev/null); then
    log "Open-file check unavailable for $dir — fail-closed, treating as in-use."
    return 0
  fi
  out="$("$lsof_bin" +w +D "$dir" 2>/dev/null)" || rc=$?
  if [[ -n "$out" ]]; then
    return 0
  fi
  # rc=1 with no output is lsof's ordinary "no matches" result.
  if (( rc != 0 && rc != 1 )); then
    log "Open-file check failed for $dir (lsof rc=${rc}) — fail-closed, treating as in-use."
    return 0
  fi
  return 1
}

path_size_kb() { du -sk "$1" 2>/dev/null | cut -f1; }

log "$(dry_prefix)cleanup_downloads_evidence.sh starting (root: $EVIDENCE_ROOT, patterns: ${PATTERNS[*]}, keep: $KEEP_COUNT, retention: ${RETENTION_HOURS}h)"

if [[ ! -d "$EVIDENCE_ROOT" ]]; then
  log "Evidence root does not exist: $EVIDENCE_ROOT — nothing to do."
  exit 0
fi

# Collect matching top-level dirs as "mtime<TAB>path" lines, newest first.
# find errors fail closed: a listing failure aborts the run without deleting.
CANDIDATE_FILE="$(mktemp -t disk-magician-evidence.XXXXXX)"
trap 'rm -f "$CANDIDATE_FILE"' EXIT
rc=0
while IFS= read -r -d '' d; do
  base="$(basename "$d")"
  matches_pattern "$base" || continue
  mtime="$(stat -f %m "$d" 2>/dev/null)" || { rc=1; break; }
  printf '%s\t%s\n' "$mtime" "$d" >> "$CANDIDATE_FILE"
done < <(/usr/bin/find "$EVIDENCE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
if (( rc != 0 )); then
  log "Failed to stat a candidate — fail-closed, aborting without deletions."
  exit 1
fi

TOTAL_KB=0
DIRS_DELETED=0
NOW_EPOCH="$(date +%s)"
CUTOFF=$(( NOW_EPOCH - RETENTION_HOURS * 3600 ))
rank=0
while IFS=$'\t' read -r mtime d; do
  rank=$(( rank + 1 ))
  base="$(basename "$d")"
  if (( rank <= KEEP_COUNT )); then
    log "Keeping (newest #${rank}): $d"
    continue
  fi
  if [[ -e "$d/.keep" || -e "$d/.in-use" ]]; then
    log "Skipping marked dir (.keep/.in-use): $d"
    continue
  fi
  if (( mtime > CUTOFF )); then
    log "Skipping within retention (${RETENTION_HOURS}h): $d"
    continue
  fi
  if has_open_files "$d"; then
    log "Skipping in-use dir (open files): $d"
    continue
  fi
  kb=$(path_size_kb "$d")
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would remove expired evidence spool: $d  (${kb} KB)"
  else
    log "Removing expired evidence spool: $d  (${kb} KB)"
    rm -rf "$d"
  fi
  TOTAL_KB=$(( TOTAL_KB + kb ))
  DIRS_DELETED=$(( DIRS_DELETED + 1 ))
done < <(sort -rn "$CANDIDATE_FILE")

log "$(dry_prefix)Done. Spools removed: ${DIRS_DELETED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)"
