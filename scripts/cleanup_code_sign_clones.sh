#!/usr/bin/env bash
# cleanup_code_sign_clones.sh — Remove stale macOS app code_sign_clone caches.
#
# Apps (Aside, Chrome, Codex, etc.) extract signed bundles into
# $DARWIN_USER_TEMP_DIR/../X/*.code_sign_clone during launch. Safe to
# delete when the app is quit; they rebuild on next launch.
#
# These directories are APFS copy-on-write clonefiles of an installed bundle:
# their contents share extents with /Applications, so `du` counts the same
# blocks once per clone and their reported size is NOT reclaimable space. A
# documented controlled test on 2026-10-06 removed 73 clones whose du total was
# 104.1 GiB and moved `df` by 0.3 GiB (8.2 -> 8.5 GiB free). Treat a removal as
# hygiene, never as a reclaim step; only the `df` delta measures reclaim. See
# findings_wiki/2026-10-17-codesign-clone-du-is-phantom-when-versions-match.md.
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

usage() {
  local prog="${0##*/}"
  printf 'Usage: %s [--clean] [--dry-run] [-h|--help]\n\n' "$prog"
  # Quoted delimiter, deliberately: an unquoted heredoc expands this body, so
  # the backticked `du` and `df` below were executed by `--help` itself (they
  # walked the whole disk and spliced their tables into the help text).
  cat <<'EOF'
Delete stale *.code_sign_clone directories under the user's var/folders X cache.

Reported sizes are `du` walks of APFS copy-on-write clones and are NOT
reclaimable: they count blocks shared with /Applications once per clone.
Measure reclaim with `df` before/after, never with this script's byte total.

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

# BSD and GNU stat disagree on how to read a hard-link count, and the wrong
# form fails silently rather than loudly: on GNU, `-f %l` is a filesystem
# format where %l means max-name-length (255), which would read as "shared"
# for an exclusive file. Pick one form up front instead of trying both.
if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
  STAT_LINKS_ARGS=(-f '%l')
else
  STAT_LINKS_ARGS=(-c '%h')
fi

# link_count <path> — hard links to <path>, or 1 when the count cannot be
# proven (already unlinked but still open, unreadable, not a regular file).
# 1 means "exclusive to this clone" and therefore pins it.
link_count() {
  local path="$1" out=""
  out=$(stat "${STAT_LINKS_ARGS[@]}" "$path" 2>/dev/null || true)
  [[ "$out" =~ ^[0-9]+$ ]] || out=1
  printf '%s\n' "$out"
}

# exec_path_of <pid> — the path a process was launched from, /private-normalized,
# or empty when it cannot be read. Deliberately per-pid: `ps -p <pid> -o comm=`
# costs ~11ms, while a global `ps -Ao comm=` costs 2m15s with 2071 processes on
# this host (measured 2026-10-24), which no per-candidate gate can afford.
exec_path_of() {
  local pid="$1" out=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  out=$(ps -p "$pid" -o comm= 2>/dev/null || true)
  printf '%s\n' "${out#/private}"
}

# holder_start_epoch <pid> — process start time as an epoch second, or empty.
# The launch-time rule below needs it: a clone created at or after the oldest
# live shared-handle holder started can still be that holder's clone.
holder_start_epoch() {
  local pid="$1" stamp=""
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  stamp=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null || true)
  while [[ "$stamp" == *" " ]]; do stamp="${stamp% }"; done
  [[ -n "$stamp" ]] || return 0
  LC_ALL=C date -j -f '%a %b %d %T %Y' "$stamp" +%s 2>/dev/null \
    || LC_ALL=C date -d "$stamp" +%s 2>/dev/null \
    || true
}

lsof_state() {
  local candidate="$1" output diagnostics rc=0 err_file
  # Set to 1 on the one path where lsof's evidence is a hardlink-shared inode
  # only: not a per-clone handle, so not "ACTIVE", but also not proof that the
  # clone is idle. Callers report that state separately instead of counting it
  # as reclaimable.
  LSOF_SHARED_ONLY=0
  # Keep stdout (structured lsof records) separate from stderr diagnostics.
  # rc=1 with empty stdout is the normal no-match result only when stderr is
  # also empty; a diagnostic means inspection was incomplete and must fail
  # closed. A bounded caller still owns the lsof invocation timeout.
  err_file=$(mktemp "${TMPDIR:-/tmp}/disk-magician-lsof.XXXXXX" 2>/dev/null) || {
    LSOF_DETAIL="unable to capture lsof diagnostics"
    return 2
  }
  output=$(lsof -Fpcn +D "$candidate" 2>"$err_file") || rc=$?
  # A diagnostics capture that cannot be read is an INCOMPLETE inspection, not
  # proof that nothing holds this clone. Swallowing the failure (the old
  # `|| true`) left diagnostics empty, so the rc=1/empty-output/empty-stderr
  # branch below classified a clone as INACTIVE — deletable — whenever the read
  # itself failed. Fail closed instead and preserve the candidate.
  if ! diagnostics=$(cat "$err_file" 2>/dev/null); then
    rm -f "$err_file"
    LSOF_DETAIL="unable to read captured lsof diagnostics"
    return 2
  fi
  rm -f "$err_file"
  diagnostics="${diagnostics//$'\n'/; }"
  # macOS lsof may return 1 even when +D emitted valid matches. Structured
  # process + file records are authoritative; rc=1 means inactive only when
  # the record stream and diagnostics are empty.
  if grep -q '^p' <<<"$output" && grep -q '^n' <<<"$output"; then
    # lsof +D matches by inode, not by path, and every clone hard-links the
    # app's main executable, so the link count tracks the clone count (measured
    # on this host: nlink=348 with 347 clones, and 433 with 432 clones an hour
    # later). A process holding that single inode is therefore reported
    # under every clone and reads as "this clone is in use" — 4 live pids once
    # pinned 344 clone bundles whose only match was one shared path. That is an
    # artifact: an inode with other links survives unlinking this clone's copy.
    # Only an exclusive link (nlink 1), a non-regular file, or an open-but-
    # unlinked file proves use of *this* clone.
    local line rec_pid="" rec_cmd="" path links exec_path
    local holder_pids=""
    while IFS= read -r line; do
      case "$line" in
        p*) rec_pid="${line#p}" ;;
        c*) rec_cmd="${line#c}" ;;
        n*)
          path="${line#n}"
          case " $holder_pids " in
            *" ${rec_pid:-unknown} "*) ;;
            *) holder_pids+=" ${rec_pid:-unknown}" ;;
          esac
          links=$(link_count "$path")
          if [[ ! -f "$path" || "$links" -le 1 ]]; then
            LSOF_DETAIL="pid=${rec_pid:-unknown} command=${rec_cmd:-unknown} path=${path}"
            return 0
          fi
          # A hardlinked inode is reported for every sibling clone, so the
          # process's own launch path is what decides whether it runs out of
          # *this* clone. Compare without the /private prefix: ps may report
          # /var/folders/... for a path spelled /private/var/folders/... .
          exec_path=$(exec_path_of "$rec_pid")
          case "$exec_path" in
            "${candidate#/private}/"*)
              LSOF_DETAIL="running executable inside clone pid=${rec_pid:-unknown} command=${rec_cmd:-unknown}"
              return 0
              ;;
          esac
          ;;
      esac
    done <<<"$output"
    # Only hardlink-shared inodes are open, so nothing attributes them to this
    # clone. Chromium creates a clone per launch and keeps it for signature
    # validity across a staged update, so any clone created at or after the
    # OLDEST live shared-handle holder started can still be that holder's clone
    # — preserve those. A clone that predates every live holder cannot belong to
    # any of them (the exec-path check above already covers a process actually
    # launched out of a clone). Unreadable start times or mtimes fail closed.
    # Keeping "only the newest" was rejected twice in review (bead
    # disk_magician-bd6): it leaves a still-live holder's clone unpinned.
    LSOF_SHARED_ONLY=1
    local pid start earliest="" candidate_mtime
    if [[ "$HAVE_PS" != 1 ]]; then
      LSOF_DETAIL="only hardlink-shared inodes open; ps unavailable"
      return 0
    fi
    candidate_mtime=$(path_mtime_epoch "$candidate" 2>/dev/null || true)
    for pid in $holder_pids; do
      start=$(holder_start_epoch "$pid")
      if [[ ! "$start" =~ ^[0-9]+$ ]]; then
        LSOF_DETAIL="only hardlink-shared inodes open; holder start time unavailable for pid=${pid}"
        return 0
      fi
      if [[ -z "$earliest" || "$start" -lt "$earliest" ]]; then
        earliest="$start"
      fi
    done
    if [[ -z "$earliest" || ! "$candidate_mtime" =~ ^[0-9]+$ ]]; then
      LSOF_DETAIL="only hardlink-shared inodes open; start or mtime unavailable"
      return 0
    fi
    if [[ "$candidate_mtime" -ge "$earliest" ]]; then
      LSOF_DETAIL="only hardlink-shared inodes open; clone is newer than the oldest live holder"
      return 0
    fi
    LSOF_DETAIL="only hardlink-shared inodes open; clone predates every live holder"
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
HAVE_PS=0
if command -v ps >/dev/null 2>&1; then
  HAVE_PS=1
else
  log "ps unavailable — candidates with only hardlink-shared handles will be preserved."
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
SHARED_ONLY_COUNT=0

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
    if [[ "$LSOF_SHARED_ONLY" == 1 ]]; then
      log "SHARED-INODE — preserving: $d  (${kb} KB, mtime=$(path_mtime "$d"), $LSOF_DETAIL)"
    else
      log "ACTIVE — preserving: $d  (${kb} KB, mtime=$(path_mtime "$d"), $LSOF_DETAIL)"
    fi
    continue
  else
    lsof_rc=$?
  fi
  if [[ "$lsof_rc" -ne 1 ]]; then
    log "Skipping code_sign_clones: lsof failed for $d  (${LSOF_DETAIL:-unknown})"
    continue
  fi
  if [[ "$LSOF_SHARED_ONLY" == 1 ]]; then
    # No per-clone evidence, only a hardlink-shared inode that another path
    # keeps alive. This is NOT reclaimable work: the bytes are APFS CoW blocks
    # shared with /Applications, and C14's generic in-quarantine open-handle
    # recheck is inode-based too, so it keeps every such candidate anyway
    # (measured: 73 clones, 104.1 GiB of du, 0.3 GiB of df on 2026-10-06).
    # Report the classification and stop there; relaxing that generic gate is
    # tracked separately rather than by weakening it here.
    log "SHARED-INODE — not a per-clone handle, not reclaimable: $d  (${kb} KB, $LSOF_DETAIL)"
    SHARED_ONLY_COUNT=$(( SHARED_ONLY_COUNT + 1 ))
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: INACTIVE candidate: $d  (${kb} KB, mtime=$(path_mtime "$d"))"
    TOTAL_KB=$(( TOTAL_KB + kb ))
    DIRS_REMOVED=$(( DIRS_REMOVED + 1 ))
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
    if [[ "$LSOF_SHARED_ONLY" == 1 ]]; then
      log "SHARED-INODE on final recheck — not reclaimable, preserving: $d  (${kb} KB, $LSOF_DETAIL)"
      SHARED_ONLY_COUNT=$(( SHARED_ONLY_COUNT + 1 ))
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

# Never report this byte total as freed space. The clones are APFS copy-on-write
# clonefiles of an installed bundle, so a du walk counts the same shared blocks
# once per clone: 73 clones measuring 104.1 GiB freed 0.3 GiB of df on 2026-10-06.
log "$(dry_prefix)Done. Dirs removed: ${DIRS_REMOVED}  du-walked clone bytes: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB) — APFS CoW shared blocks, NOT freed space; only the df delta is reclaim. See findings_wiki/2026-10-17-codesign-clone-du-is-phantom-when-versions-match.md"
if [[ "$SHARED_ONLY_COUNT" -gt 0 ]]; then
  log "$(dry_prefix)Shared-inode-only candidates: ${SHARED_ONLY_COUNT} — their only open handle is a hardlink-shared inode, so no per-clone evidence exists and their du bytes are APFS CoW blocks shared with /Applications (non-reclaimable)."
fi
