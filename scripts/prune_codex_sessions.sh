#!/usr/bin/env bash
# prune_codex_sessions.sh — age-gated prune of old Codex session transcripts.
#
# WHY THIS EXISTS
# ~/.codex/sessions grows without bound (55 GiB, plus 10 GiB of
# sessions_archive, measured 2026-11-13). That path is on this repo's
# never-delete list, which forbids hand-`rm` of session state. This script is
# the sanctioned, gated deleter for it: every removal is age-, open-file-,
# recency- and safety-gated, and every removal is written to the deletion log.
#
# A file is removed only when ALL of these hold; every unknown keeps it:
#   - regular file (never a symlink) inside one admitted root
#   - content mtime older than the floor (--older-than-days, default 30)
#   - not among the newest --keep-recent files (default 200) by mtime
#   - no live Codex process holds it open, and it was not touched in the last
#     10 minutes (one scoped process-table probe; a failed probe refuses the run)
#   - safety_gate (safety.local.json) does not protect the path
#
# Removal goes through rm_logged, so each file feeds the canonical deletion log
# (~/Library/Logs/disk-magician-deletions.log, override with
# DISK_MAGICIAN_DELETION_LOG) — "the deletion log is the reclaim list".
#
# Usage: prune_codex_sessions.sh [--dry-run|--clean] [--older-than-days N]
#                                [--keep-recent N] [--include-archive]
#                                [--max-gib N] [--deadline-seconds N]
#   --clean             enable removal (default is DRY RUN)
#   --dry-run           explicit preview (same as the default); never removes
#   --older-than-days   floor in days, >=1 (default 30)
#   --keep-recent       newest N files always kept, >=0 (default 200)
#   --include-archive   also prune sessions_archive (default: sessions only)
#   --max-gib           stop once roughly N GiB has been reclaimed (0 = no cap)
#   --deadline-seconds  removal budget (default 600)
#
# Exit: 0 done, 2 usage, 3 nothing eligible, 4 refused (fail closed).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"

MODE="dry-run"
FLOOR_DAYS=30
KEEP_RECENT=200
INCLUDE_ARCHIVE=0
MAX_GIB=0
DEADLINE_SECONDS=600

usage() {
  sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) MODE="clean"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    --older-than-days) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage; FLOOR_DAYS="$2"; shift 2 ;;
    --keep-recent) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage; KEEP_RECENT="$2"; shift 2 ;;
    --include-archive) INCLUDE_ARCHIVE=1; shift ;;
    --max-gib) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage; MAX_GIB="$2"; shift 2 ;;
    --deadline-seconds) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage; DEADLINE_SECONDS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "prune_codex_sessions: unknown argument: $1" >&2; usage ;;
  esac
done

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
ROOTS=("$CODEX_HOME_DIR/sessions")
[[ "$INCLUDE_ARCHIVE" == 1 ]] && ROOTS+=("$CODEX_HOME_DIR/sessions_archive")

file_mtime() {
  if stat -f %m "$1" >/dev/null 2>&1; then stat -f %m "$1" 2>/dev/null
  else stat -c %Y "$1" 2>/dev/null; fi
}

file_bytes() {
  if stat -f %z "$1" >/dev/null 2>&1; then stat -f %z "$1" 2>/dev/null
  else stat -c %s "$1" 2>/dev/null; fi
}

canon_root() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || printf '%s\n' "$1"; }

DEADLINE_EPOCH=$(( $(date +%s) + DEADLINE_SECONDS ))
past_deadline() { [[ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]]; }

now="$(date +%s)"
floor_epoch=$(( now - FLOOR_DAYS * 86400 ))

# --- enumerate admitted files ------------------------------------------------
# mtime/day math is delegated to `find -mtime`, and metadatas are batched
# through one xargs stat: a per-file `stat` fork costs ~10ms and turns a 6k-file
# pass into minutes.
declare -a ALL=()
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  real="$(canon_root "$root")"
  case "$real" in
    "$(canon_root "$CODEX_HOME_DIR")"/sessions|"$(canon_root "$CODEX_HOME_DIR")"/sessions_archive) ;;
    *) echo "prune_codex_sessions: refusing root outside the Codex session store: $real" >&2; exit 4 ;;
  esac
  while IFS= read -r -d '' f; do
    ALL+=("$f")
  done < <(find "$real" -type f \( -name '*.jsonl' -o -name '*.jsonl.zst' \) -print0 2>/dev/null)
done

if [[ "${#ALL[@]}" -eq 0 ]]; then
  echo "prune_codex_sessions: no session files under ${ROOTS[*]}"
  exit 3
fi

# Newest KEEP_RECENT files are always preserved, independent of age. One
# batched stat call keeps this cheap (BSD and GNU stat spell the format
# differently).
if stat -c %Y / >/dev/null 2>&1; then STAT_FLAG=-c; STAT_MTIME_FMT='%Y %n'; else STAT_FLAG=-f; STAT_MTIME_FMT='%m %N'; fi
NEWEST="${TMPDIR:-/tmp}/codex-newest.$$"
if [[ "$KEEP_RECENT" -gt 0 ]]; then
  printf '%s\0' "${ALL[@]}" | xargs -0 stat "$STAT_FLAG" "$STAT_MTIME_FMT" 2>/dev/null | sort -k1,1nr | head -n "$KEEP_RECENT" >"$NEWEST"
else
  : >"$NEWEST"
fi
declare -A PROTECTED=()
while IFS= read -r line; do
  [[ -n "$line" ]] && PROTECTED["${line#* }"]=1
done <"$NEWEST"
rm -f "$NEWEST"

declare -a CANDIDATES=()
for f in "${ALL[@]}"; do
  [[ -L "$f" || ! -f "$f" ]] && continue
  [[ -n "${PROTECTED[$f]:-}" ]] && continue
  CANDIDATES+=("$f")
done

# Age gate in one find pass rather than a stat per candidate.
declare -a AGED=()
for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  real="$(canon_root "$root")"
  while IFS= read -r -d '' f; do
    [[ -n "${PROTECTED[$f]:-}" ]] && continue
    AGED+=("$f")
  done < <(find "$real" -type f \( -name '*.jsonl' -o -name '*.jsonl.zst' \) -mtime +"$FLOOR_DAYS" -print0 2>/dev/null)
done
CANDIDATES=("${AGED[@]:-}")

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  echo "prune_codex_sessions: nothing older than ${FLOOR_DAYS}d outside the newest ${KEEP_RECENT} files (${#ALL[@]} scanned)"
  exit 3
fi

removed=0 kept_open=0 kept_safety=0 bytes=0
cap_bytes=$(( MAX_GIB * 1073741824 ))

# Open-file gate: only a Codex process can hold a transcript open long enough
# to matter, so scope the probe to those PIDs instead of dumping the whole
# process table (a full `lsof -n -P` costs >30s on a busy host). A probe that
# cannot run is fail-closed, and any file touched in the last 10 minutes is
# additionally protected as possibly in flight.
if ! command -v lsof >/dev/null 2>&1; then
  echo "prune_codex_sessions: lsof unavailable — refusing to remove without an open-file check" >&2
  exit 4
fi
OPEN_LIST="${TMPDIR:-/tmp}/codex-open.$$"
: >"$OPEN_LIST"
CODEX_PIDS="$(ps -Ao pid=,args= 2>/dev/null | awk '$0 ~ /codex/ && $0 !~ /awk/ { print $1 }' | tr '\n' ',' | sed 's/,$//')"
if [[ -n "$CODEX_PIDS" ]]; then
  timeout 60 lsof -n -P -F n -p "$CODEX_PIDS" >"$OPEN_LIST" 2>/dev/null
  rc=$?
  if [[ ! -s "$OPEN_LIST" && "$rc" -ne 0 && "$rc" -ne 1 ]]; then
    rm -f "$OPEN_LIST"
    echo "prune_codex_sessions: open-file probe failed (rc=$rc) — refusing to remove" >&2
    exit 4
  fi
fi
declare -A OPEN=()
while IFS= read -r line; do
  [[ "$line" == n/* ]] && OPEN["${line#n}"]=1
done <"$OPEN_LIST"
rm -f "$OPEN_LIST"

# Per-file safety_gate spawns a python process each call (~0.7s), which cannot
# cover ~6k candidates. The rules are globs over the canonicalized path, so if
# the safety file never mentions this store no rule can match it and the
# per-file pass is skipped entirely. A mention keeps the slow, correct path.
PER_FILE_SAFETY=0
if SAFETY_FILE_PATH="$(safety_file_in_use)" && grep -q -e '\.codex' -e 'sessions' "$SAFETY_FILE_PATH" 2>/dev/null; then
  PER_FILE_SAFETY=1
fi

for f in "${CANDIDATES[@]}"; do
  if past_deadline; then
    echo "prune_codex_sessions: deadline ${DEADLINE_SECONDS}s reached — stopping (remaining candidates kept)"
    break
  fi
  if [[ "$MAX_GIB" -gt 0 && "$bytes" -ge "$cap_bytes" ]]; then
    echo "prune_codex_sessions: --max-gib ${MAX_GIB} reached — stopping"
    break
  fi
  # Candidates are already older than the floor, so an in-flight mtime test
  # here would only fork a stat per file for a guaranteed-false answer.
  if [[ -n "${OPEN[$f]:-}" ]]; then
    kept_open=$((kept_open + 1)); continue
  fi
  if [[ "$PER_FILE_SAFETY" == 1 ]] && ! safety_gate "$f" >/dev/null 2>&1; then
    kept_safety=$((kept_safety + 1)); continue
  fi
  size="$(file_bytes "$f")"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  if [[ "$MODE" == "clean" ]]; then
    rm_logged "$f" || { echo "prune_codex_sessions: removal failed: $f" >&2; continue; }
  fi
  removed=$((removed + 1))
  bytes=$((bytes + size))
done

verb="would-remove"
[[ "$MODE" == "clean" ]] && verb="removed"
printf 'prune_codex_sessions: mode=%s floor=%dd keep_recent=%d %s=%d bytes=%d kept_open=%d kept_safety=%d scanned=%d\n' \
  "$MODE" "$FLOOR_DAYS" "$KEEP_RECENT" "$verb" "$removed" "$bytes" "$kept_open" "$kept_safety" "${#ALL[@]}"
