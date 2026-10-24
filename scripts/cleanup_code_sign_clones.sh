#!/usr/bin/env bash
# cleanup_code_sign_clones.sh — Remove stale macOS app code_sign_clone caches.
#
# Apps (Aside, Chrome, Codex, etc.) extract signed bundles into
# $DARWIN_USER_TEMP_DIR/../X/*.code_sign_clone during launch. Safe to
# delete when the app is quit; they rebuild on next launch.
#
# Defaults to DRY-RUN; pass --clean to delete (requires CODE_SIGN_CLONES_APPROVED=1).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"
# shellcheck source=scripts/lib/quarantine.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/quarantine.sh"

DRY_RUN=true
MIN_KB="${CODE_SIGN_CLONE_MIN_KB:-102400}"
# A code_sign_clone is extracted at app launch and briefly has no open
# handles before the app opens files inside it. Per-launch children are now
# judged individually (no longer shielded by a mapped sibling under the same
# parent), so require a minimum age before a candidate is even eligible —
# guards against deleting a clone mid-extraction/mid-launch.
MIN_AGE_SEC="${CODE_SIGN_CLONE_MIN_AGE_SEC:-600}"
# One bounded liveness pass replaces one `lsof +D` per candidate. Per-dir
# probes cost seconds each and, on real trees, exceeded any sane per-dir
# budget — every timeout fail-closed to ACTIVE and preserved reclaimable
# clones. This budget bounds the single enumeration instead.
LSOF_TIMEOUT_SEC="${CODE_SIGN_CLONE_LSOF_TIMEOUT_SEC:-30}"
# A --clean removal needs a fresher liveness answer than a long dry-run scan.
# The index is rebuilt at most once per window, so the lsof cost stays
# independent of the candidate count.
LIVENESS_MAX_AGE_SEC="${CODE_SIGN_CLONE_LIVENESS_MAX_AGE_SEC:-60}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [-h|--help]

Delete stale *.code_sign_clone directories under the user's var/folders X cache.

Options:
  --clean      Actually delete (requires CODE_SIGN_CLONES_APPROVED=1)
  --dry-run    Preview only (default)
  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$DRY_RUN" != true && "${CODE_SIGN_CLONES_APPROVED:-0}" != "1" ]]; then
  echo "Refusing code_sign_clone deletion: set CODE_SIGN_CLONES_APPROVED=1 after reviewing dry-run output." >&2
  exit 0
fi

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2; }
dry_prefix() { [[ "$DRY_RUN" == true ]] && echo "DRY RUN: " || echo ""; }

# c14_remove <path> [quarantine_remove args...] — the only removal route.
# rc 0 only when quarantine_remove reports removed:*; a kept verdict prints
# the reason and returns 1 so the caller does not count freed bytes.
path_size_kb() {
  { du -sk "$1" 2>/dev/null || true; } | awk '$1 ~ /^[0-9]+$/ {f=$1} END{print f+0}'
}

path_identity() {
  stat -f '%d:%i:%u' "$1" 2>/dev/null || stat -c '%d:%i:%u' "$1" 2>/dev/null
}

path_mtime() {
  stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$1" 2>/dev/null \
    || stat -c '%y' "$1" 2>/dev/null \
    || echo unknown
}

path_mtime_epoch() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

# pid_alive <pid>: rc 0 when the process still exists. `ps -p` sees other
# users' processes, so a permission-restricted `kill -0` cannot misreport a
# live process as gone.
pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  ps -p "$pid" >/dev/null 2>&1 || kill -0 "$pid" 2>/dev/null
}

# run_bounded <secs> <stdout-file> <stderr-file> <cmd...>: portable bounded
# runner (stock macOS bash 3.2 ships no GNU `timeout`). A watchdog fires the
# kill and leaves a marker, so "we timed out" (rc 124) is never confused with
# the command's own exit status, and partial output is never mistaken for a
# complete scan.
run_bounded() {
  local secs="$1" out="$2" err="$3" marker="$2.timeout" pid watchdog rc=0
  shift 3
  rm -f "$marker"
  "$@" >"$out" 2>"$err" &
  pid=$!
  (
    sleep "$secs"
    : >"$marker"
    kill -TERM "$pid" 2>/dev/null || exit 0
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" || rc=$?
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  if [[ -f "$marker" ]]; then
    rm -f "$marker"
    return 124
  fi
  return "$rc"
}

# _liveness_enumerate <raw-out>: ONE bounded lsof enumeration of every open
# file, filtered to the X scan root afterwards, instead of `lsof +D` per
# candidate. rc 0 when the pass is authoritative (a clean record stream with
# no diagnostics); rc 2 when it is not. Bounded fallback: a single
# `lsof +D <X root>` pass, same budget — still one lsof run, never one per
# clone. Both pass a `-w -n -P -F pcn` record stream, so the parse is shared.
_liveness_enumerate() {
  local raw="$1" err="$RAW_ERR" rc=0 diagnostics
  LIVENESS_REASON=""
  if ! command -v lsof >/dev/null 2>&1; then
    LIVENESS_REASON="kept:unverified:lsof-unavailable"
    return 2
  fi
  : >"$raw"
  rc=0
  run_bounded "$LSOF_TIMEOUT_SEC" "$raw" "$err" lsof -w -n -P -F pcn || rc=$?
  diagnostics=$(tr '\n' ';' <"$err" 2>/dev/null || true)
  if [[ "$rc" -eq 124 ]]; then
    LIVENESS_REASON="kept:unverified:all-open-files-timeout=${LSOF_TIMEOUT_SEC}s"
  elif [[ "$rc" -ne 0 && "$rc" -ne 1 ]] || [[ -n "$diagnostics" ]]; then
    LIVENESS_REASON="kept:unverified:rc=$rc"
    [[ -n "$diagnostics" ]] && LIVENESS_REASON+=" diagnostics=$diagnostics"
  else
    return 0
  fi
  # Bounded fallback: narrow the same single-pass probe to the scan root.
  : >"$raw"
  rc=0
  run_bounded "$LSOF_TIMEOUT_SEC" "$raw" "$err" lsof -w -n -P -F pcn +D "$X_DIR" || rc=$?
  diagnostics=$(tr '\n' ';' <"$err" 2>/dev/null || true)
  if [[ "$rc" -eq 124 ]]; then
    LIVENESS_REASON+=" fallback=timeout"
    : >"$raw"
    return 2
  fi
  if [[ "$rc" -ne 0 && "$rc" -ne 1 ]] || [[ -n "$diagnostics" ]]; then
    LIVENESS_REASON+=" fallback=rc=$rc"
    [[ -n "$diagnostics" ]] && LIVENESS_REASON+=" fallback-diagnostics=$diagnostics"
    : >"$raw"
    return 2
  fi
  log "liveness: all-open-files pass incomplete (${LIVENESS_REASON}); answered by the bounded +D scan of the X root."
  return 0
}

# build_liveness_index <index-out>: authoritative live-FD index, one line per
# clone dir that has an open fd: "<dir>\t<pid>\t<command>". Sets
# LIVENESS_STATE=ok|unverified and LIVENESS_REASON. Records whose pid is gone
# are dropped: a stale pid is not evidence of a live handle, so a dead holder
# can no longer mask a reclaimable clone.
build_liveness_index() {
  local index="$1" raw="$RAW_OUT" dirs_raw="$RAW_DIRS" pids="$RAW_PIDS" alive="$RAW_ALIVE"
  local pid stale_pids
  LIVENESS_STATE="unverified"
  : >"$index"
  if ! _liveness_enumerate "$raw"; then
    LIVENESS_REASON="${LIVENESS_REASON:-kept:unverified}"
    return 2
  fi
  : >"$dirs_raw"
  # Attribute every open fd to the clone dir that contains it: the top-level
  # '<name>.code_sign_clone' and, one level down, 'code_sign_clone.<id>'.
  # Those two shapes are exactly the candidate set, so a dir with no record
  # has no live fd under it.
  awk -v r1="$X_DIR" -v r2="$X_DIR_REAL" '
    /^p/ { pid = substr($0, 2); next }
    /^c/ { cmd = substr($0, 2); next }
    /^n/ {
      p = substr($0, 2)
      for (i = 1; i <= 2; i++) {
        root = (i == 1) ? r1 : r2
        if (root == "" || p == root) continue
        if (index(p, root "/") != 1) continue
        rest = substr(p, length(root) + 2)
        depth = split(rest, part, "/")
        if (depth < 1 || part[1] == "") continue
        top = root "/" part[1]
        # Candidate shapes only: the <name>.code_sign_clone parent and its
        # code_sign_clone.<id> children. A deeper fd belongs to one of them.
        if (part[1] ~ /\.code_sign_clone$/) print top "\t" pid "\t" cmd
        if (depth >= 2 && part[2] ~ /^code_sign_clone\./) print top "/" part[2] "\t" pid "\t" cmd
      }
    }
  ' "$raw" >"$dirs_raw"
  cut -f2 "$dirs_raw" | sort -u >"$pids"
  : >"$alive"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if pid_alive "$pid"; then printf '%s\n' "$pid" >>"$alive"; fi
  done <"$pids"
  awk -F'\t' 'FILENAME == ARGV[1] { live[$1] = 1; next } live[$2]' "$alive" "$dirs_raw" \
    | awk -F'\t' '!seen[$1]++' >"$index"
  # Stale holders are recorded, not silently ignored: the difference between
  # "no fd exists" and "the fd's pid is gone" is the whole diagnosis here.
  stale_pids=$(awk -F'\t' 'FILENAME == ARGV[1] { live[$1] = 1; next } !($2 in live) { print $2 }' "$alive" "$dirs_raw" | sort -u | tr '\n' ' ')
  LIVENESS_STALE_PIDS="${stale_pids% }"
  [[ -n "$LIVENESS_STALE_PIDS" ]] && log "ignoring stale holders (pid gone): ${LIVENESS_STALE_PIDS}"
  LIVENESS_STATE="ok"
  LIVENESS_INDEX_EPOCH=$(date +%s)
  return 0
}

# refresh_liveness_index_if_stale: rebuild the index when the last pass is
# older than LIVENESS_MAX_AGE_SEC. A 0 window forces a pass per removal (tests
# use it to exercise the final-recheck path); the default keeps the cost flat.
liveness_refresh_if_stale() {
  local now
  now=$(date +%s)
  if [[ "$LIVENESS_STATE" == "ok" ]] \
     && [[ $(( now - LIVENESS_INDEX_EPOCH )) -lt "$LIVENESS_MAX_AGE_SEC" ]]; then
    return 0
  fi
  build_liveness_index "$LIVE_INDEX" || return 2
  return 0
}

# live_fd_detail <dir>: print "pid=<pid> command=<command>" and rc 0 when the
# index shows an open fd under <dir>; rc 1 when it does not.
live_fd_detail() {
  local out
  out=$(awk -F'\t' -v d="$1" '$1 == d { printf "pid=%s command=%s", $2, $3; found = 1; exit } END { if (!found) exit 1 }' "$LIVE_INDEX")
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

resolve_x_dir() {
  if [[ -n "${DISK_MAGICIAN_CODE_SIGN_X_DIR:-}" ]]; then
    if [[ -d "${DISK_MAGICIAN_CODE_SIGN_X_DIR}" ]]; then
      printf '%s\n' "${DISK_MAGICIAN_CODE_SIGN_X_DIR}"
      return 0
    fi
    echo "ERROR: DISK_MAGICIAN_CODE_SIGN_X_DIR is not a directory: ${DISK_MAGICIAN_CODE_SIGN_X_DIR}" >&2
    return 1
  fi
  local user_tmp
  user_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "")
  [[ -n "$user_tmp" ]] || return 1
  user_tmp=$(cd "$user_tmp" && pwd -P 2>/dev/null) || return 1
  local x_dir
  x_dir="$(dirname "$user_tmp")/X"
  [[ -d "$x_dir" ]] || return 1
  printf '%s\n' "$x_dir"
}

X_DIR=""
X_DIR=$(resolve_x_dir) || {
  log "code_sign_clone: DARWIN_USER_TEMP_DIR X parent not found — nothing to do."
  exit 0
}

log "$(dry_prefix)code_sign_clone cleanup starting (scan: $X_DIR)"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/disk-magician-code-sign.XXXXXX" 2>/dev/null) || {
  log "Cannot create a work directory — preserving all candidates."
  exit 0
}
RAW_OUT="$WORK_DIR/lsof.raw"
RAW_ERR="$WORK_DIR/lsof.err"
RAW_DIRS="$WORK_DIR/fd-dirs.tsv"
RAW_PIDS="$WORK_DIR/fd-pids.txt"
RAW_ALIVE="$WORK_DIR/alive-pids.txt"
LIVE_INDEX="$WORK_DIR/live-index.tsv"
trap 'rm -rf "$WORK_DIR"' EXIT

CURRENT_UID=$(id -u)
X_IDENTITY=$(path_identity "$X_DIR") || {
  log "Unsafe scan root identity — preserving all candidates: $X_DIR"
  exit 0
}
if [[ "${X_IDENTITY##*:}" != "$CURRENT_UID" ]]; then
  log "Unsafe scan root owner uid=${X_IDENTITY##*:}, expected uid=$CURRENT_UID — preserving all candidates: $X_DIR"
  exit 0
fi

# Freeze the candidate paths, their filesystem identities, and their
# immediate parent's identity before any lsof checks. Revalidation below
# prevents a replaced path — or a replaced *.code_sign_clone parent one
# level up, for nested per-launch children — from being removed.
CANDIDATES=()
CANDIDATE_IDENTITIES=()
CANDIDATE_PARENT_IDENTITIES=()
while IFS= read -r -d '' candidate; do
  candidate_identity=$(path_identity "$candidate") || continue
  parent_identity=$(path_identity "$(dirname "$candidate")") || continue
  CANDIDATES[${#CANDIDATES[@]}]="$candidate"
  CANDIDATE_IDENTITIES[${#CANDIDATE_IDENTITIES[@]}]="$candidate_identity"
  CANDIDATE_PARENT_IDENTITIES[${#CANDIDATE_PARENT_IDENTITIES[@]}]="$parent_identity"
done < <(
  # A long-running app (e.g. Chrome) accumulates one code_sign_clone.XXXX per
  # relaunch under its *.code_sign_clone parent while keeping only one mapped;
  # judge each child separately so unmapped siblings are reclaimable.
  find -P "$X_DIR" -mindepth 1 -maxdepth 1 -type d -name '*code_sign_clone' -print0 2>/dev/null |
    while IFS= read -r -d '' parent; do
      if find -P "$parent" -mindepth 1 -maxdepth 1 -type d -name 'code_sign_clone.*' -print -quit 2>/dev/null | grep -q .; then
        find -P "$parent" -mindepth 1 -maxdepth 1 -type d -name 'code_sign_clone.*' -print0 2>/dev/null
      else
        printf '%s\0' "$parent"
      fi
    done || true
)

# Single bounded liveness pass for the whole scan (O(1) lsof runs, not one
# per clone). X_DIR_REAL covers lsof's resolved-path form of the scan root.
X_DIR_REAL=$(cd "$X_DIR" && pwd -P 2>/dev/null) || X_DIR_REAL="$X_DIR"
LIVENESS_STATE=""
LIVENESS_REASON=""
LIVENESS_STALE_PIDS=""
LIVENESS_INDEX_EPOCH=0
if ! build_liveness_index "$LIVE_INDEX"; then
  if [[ "$LIVENESS_REASON" == *lsof-unavailable* ]]; then
    log "lsof unavailable — preserving all candidates as unverified (kept:unverified); open handles cannot be proven absent."
  else
    log "code_sign_clone liveness pass incomplete — preserving all candidates as unverified (${LIVENESS_REASON})."
  fi
fi
if [[ "$LIVENESS_STATE" == "ok" ]]; then
  log "liveness index: $(wc -l <"$LIVE_INDEX" | tr -d ' ') clone dirs with a live fd (one bounded lsof pass, budget ${LSOF_TIMEOUT_SEC}s)"
fi

DIRS_REMOVED=0
TOTAL_KB=0
ACTIVE_COUNT=0
UNVERIFIED_COUNT=0

for i in "${!CANDIDATES[@]}"; do
  d="${CANDIDATES[$i]}"
  frozen_identity="${CANDIDATE_IDENTITIES[$i]}"
  frozen_parent_identity="${CANDIDATE_PARENT_IDENTITIES[$i]}"
  kb=$(path_size_kb "$d")
  if [[ "$kb" -lt "$MIN_KB" ]]; then
    continue
  fi

  current_identity=$(path_identity "$d" 2>/dev/null || true)
  current_parent_identity=$(path_identity "$(dirname "$d")" 2>/dev/null || true)
  if [[ -z "$current_identity" || "$current_identity" != "$frozen_identity" \
        || "${current_identity##*:}" != "$CURRENT_UID" \
        || -z "$current_parent_identity" || "$current_parent_identity" != "$frozen_parent_identity" \
        || -L "$d" || -L "$(dirname "$d")" \
        || ( "$(dirname "$d")" != "$X_DIR" && "$(dirname "$(dirname "$d")")" != "$X_DIR" ) ]]; then
    log "Unsafe candidate ownership or identity changed — preserving: $d"
    continue
  fi

  mtime_epoch=$(path_mtime_epoch "$d" 2>/dev/null || true)
  if [[ ! "$mtime_epoch" =~ ^[0-9]+$ ]]; then
    log "Cannot read mtime — preserving: $d"
    continue
  fi
  age_sec=$(( $(date +%s) - mtime_epoch ))
  if [[ "$age_sec" -lt "$MIN_AGE_SEC" ]]; then
    log "Too young (${age_sec}s < ${MIN_AGE_SEC}s) — preserving: $d"
    continue
  fi

  # An unverifiable probe stays fail-closed but is reported as
  # kept:unverified, never as ACTIVE — a live holder is provable, a broken
  # probe is not.
  if [[ "$LIVENESS_STATE" != "ok" ]]; then
    log "UNVERIFIED — preserving: $d  (${kb} KB, kept:unverified, ${LIVENESS_REASON})"
    UNVERIFIED_COUNT=$(( UNVERIFIED_COUNT + 1 ))
    continue
  fi
  if live_detail=$(live_fd_detail "$d"); then
    log "ACTIVE — preserving: $d  (${kb} KB, mtime=$(path_mtime "$d"), $live_detail)"
    ACTIVE_COUNT=$(( ACTIVE_COUNT + 1 ))
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: INACTIVE candidate: $d  (${kb} KB, mtime=$(path_mtime "$d"))"
    TOTAL_KB=$(( TOTAL_KB + kb ))
    DIRS_REMOVED=$(( DIRS_REMOVED + 1 ))
  else
    # Recheck handles immediately before removal with a freshly-refreshed
    # index (still one bounded pass, at most one per LIVENESS_MAX_AGE_SEC),
    # then verify that neither the candidate nor its trusted parent changed
    # while lsof was running.
    if ! liveness_refresh_if_stale; then
      log "UNVERIFIED on final recheck — preserving: $d  (${kb} KB, kept:unverified, ${LIVENESS_REASON})"
      UNVERIFIED_COUNT=$(( UNVERIFIED_COUNT + 1 ))
      continue
    fi
    if live_detail=$(live_fd_detail "$d"); then
      log "ACTIVE on final recheck — preserving: $d  (${kb} KB, $live_detail)"
      ACTIVE_COUNT=$(( ACTIVE_COUNT + 1 ))
      continue
    fi
    final_identity=$(path_identity "$d" 2>/dev/null || true)
    final_x_identity=$(path_identity "$X_DIR" 2>/dev/null || true)
    final_parent_identity=$(path_identity "$(dirname "$d")" 2>/dev/null || true)
    if [[ "$final_identity" != "$frozen_identity" || "$final_x_identity" != "$X_IDENTITY" \
          || "$final_parent_identity" != "$frozen_parent_identity" || -L "$(dirname "$d")" ]]; then
      log "Candidate changed after lsof recheck — preserving: $d"
      continue
    fi
    log "Removing: $d  (${kb} KB)"
    if ! _safety_reason="$(safety_gate "$d" 2>/dev/null)"; then
      echo "SAFETY-SKIP "$d" ($_safety_reason)"
      continue
    fi
    # safety_gate spawns a subprocess and takes measurable time; revalidate
    # identity one more time immediately before the actual deletion so that
    # window cannot be used for a same-uid path swap either.
    presubmit_identity=$(path_identity "$d" 2>/dev/null || true)
    presubmit_parent_identity=$(path_identity "$(dirname "$d")" 2>/dev/null || true)
    if [[ "$presubmit_identity" != "$frozen_identity" \
          || "$presubmit_parent_identity" != "$frozen_parent_identity" \
          || -L "$(dirname "$d")" ]]; then
      log "Candidate changed after safety_gate — preserving: $d"
      continue
    fi
    if c14_remove "$d" --kind os_clone \
        --frozen-identity "$frozen_identity" \
        --frozen-parent-identity "$frozen_parent_identity" \
        --frozen-root-identity "$X_IDENTITY"; then
      log "Removed (quarantined): $d  (${kb} KB)"
      TOTAL_KB=$(( TOTAL_KB + kb ))
      DIRS_REMOVED=$(( DIRS_REMOVED + 1 ))
    else
      log "Preserving (C14 kept): $d  (${kb} KB)"
    fi
  fi
done

log "$(dry_prefix)Done. Dirs removed: ${DIRS_REMOVED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)  active: ${ACTIVE_COUNT}  unverified: ${UNVERIFIED_COUNT}"
