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

DRY_RUN=true
MIN_KB="${CODE_SIGN_CLONE_MIN_KB:-102400}"
# A code_sign_clone is extracted at app launch and briefly has no open
# handles before the app opens files inside it. Per-launch children are now
# judged individually (no longer shielded by a mapped sibling under the same
# parent), so require a minimum age before a candidate is even eligible —
# guards against deleting a clone mid-extraction/mid-launch.
MIN_AGE_SEC="${CODE_SIGN_CLONE_MIN_AGE_SEC:-600}"

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

path_size_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1+0}' || echo 0
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

lsof_state() {
  local candidate="$1" output diagnostics rc=0 pid command err_file
  # Keep stdout (structured lsof records) separate from stderr diagnostics.
  # rc=1 with empty stdout is the normal no-match result only when stderr is
  # also empty; a diagnostic means inspection was incomplete and must fail
  # closed. A bounded caller still owns the lsof invocation timeout.
  if ps -Ao comm= 2>/dev/null | grep -qF "${candidate}/"; then
    LSOF_DETAIL="running executable inside clone"
    return 0
  fi
  err_file=$(mktemp "${TMPDIR:-/tmp}/disk-magician-lsof.XXXXXX" 2>/dev/null) || {
    LSOF_DETAIL="unable to capture lsof diagnostics"
    return 2
  }
  output=$(lsof -Fpcn +D "$candidate" 2>"$err_file") || rc=$?
  diagnostics=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  diagnostics="${diagnostics//$'\n'/; }"
  # macOS lsof may return 1 even when +D emitted valid matches. Structured
  # process + file records are authoritative; rc=1 means inactive only when
  # the record stream and diagnostics are empty.
  if grep -q '^p' <<<"$output" && grep -q '^n' <<<"$output"; then
    # Clones hardlink some files (the main executable is shared by every
    # clone and the app in /Applications), and macOS lsof +D matches by inode,
    # so a process holding a shared file is reported under every clone; lsof's
    # path for such a vnode is whichever link name is cached, so it cannot say
    # which clone was used. A shared inode survives unlinking one path, so it
    # does not pin this clone. A single-link (or unstattable) open file does,
    # as does a running process whose executable lives inside the clone.
    local line rec_pid="" rec_cmd="" path links
    while IFS= read -r line; do
      case "$line" in
        p*) rec_pid="${line#p}" ;;
        c*) rec_cmd="${line#c}" ;;
        n*)
          path="${line#n}"
          links=$(stat -f %l "$path" 2>/dev/null || echo 1)
          if [[ ! -f "$path" || "$links" -le 1 ]]; then
            LSOF_DETAIL="pid=${rec_pid:-unknown} command=${rec_cmd:-unknown}"
            return 0
          fi
          ;;
      esac
    done <<<"$output"
    LSOF_DETAIL="only hardlink-shared open files"
    [[ -z "$diagnostics" ]] && return 1
    LSOF_DETAIL+=" diagnostics=${diagnostics}"
    return 2
  fi
  [[ "$rc" -eq 1 && -z "$output" && -z "$diagnostics" ]] && return 1
  LSOF_DETAIL="rc=$rc"
  [[ -n "$diagnostics" ]] && LSOF_DETAIL+=" diagnostics=${diagnostics}"
  return 2
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

if ! command -v lsof >/dev/null 2>&1; then
  log "lsof unavailable — preserving all candidates; open handles cannot be proven absent."
  exit 0
fi

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

DIRS_REMOVED=0
TOTAL_KB=0

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

  LSOF_DETAIL=""
  if lsof_state "$d"; then
    log "ACTIVE — preserving: $d  (${kb} KB, mtime=$(path_mtime "$d"), $LSOF_DETAIL)"
    continue
  else
    lsof_rc=$?
  fi
  if [[ "$lsof_rc" -ne 1 ]]; then
    log "Skipping code_sign_clones: lsof failed for $d  (${LSOF_DETAIL:-unknown})"
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: INACTIVE candidate: $d  (${kb} KB, mtime=$(path_mtime "$d"))"
  else
    # Recheck handles immediately before removal, then verify that neither the
    # candidate nor its trusted parent changed while lsof was running.
    LSOF_DETAIL=""
    if lsof_state "$d"; then
      log "ACTIVE on final recheck — preserving: $d  (${kb} KB, $LSOF_DETAIL)"
      continue
    else
      lsof_rc=$?
    fi
    if [[ "$lsof_rc" -ne 1 ]]; then
      log "Skipping code_sign_clones: final lsof failed for $d  (${LSOF_DETAIL:-unknown})"
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
    rm -rf "$d"
  fi
  TOTAL_KB=$(( TOTAL_KB + kb ))
  DIRS_REMOVED=$(( DIRS_REMOVED + 1 ))
done

log "$(dry_prefix)Done. Dirs removed: ${DIRS_REMOVED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)"
