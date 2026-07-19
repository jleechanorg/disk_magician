#!/usr/bin/env bash
# cleanup_tmp.sh — Delete stale git clones and temp logs from system temp directories.
#
# Defaults to DRY-RUN; pass --clean to actually delete. Callers that must
# delete (disk_audit.sh safe-clean path, pressure sweeps) pass --clean.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.json"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/config.json.template"

# Default thresholds (minutes unless noted)
GIT_CLONE_MIN=240
AGENT_PROMPT_MIN=240
CLI_VALIDATION_MIN=60
WORKTREE_POINTER_MIN=30
WORKTREE_POINTER_MIN_KB=51200
# --large branch safety (hours): a top-level /private/tmp dir with any file
# mtime within this window is considered "active use" and is skipped
# regardless of size or protected-root status.
LARGE_TMP_ACTIVE_HOURS="${LARGE_TMP_ACTIVE_HOURS:-24}"
# --large branch: how long an archived dir sits under
# /private/tmp/_disk_magician_archive/<ts>/ before a later --large run may
# permanently rm -rf it and actually reclaim the space.
LARGE_TMP_ARCHIVE_RETENTION_HOURS="${LARGE_TMP_ARCHIVE_RETENTION_HOURS:-24}"

if [[ -f "$CONFIG_FILE" ]]; then
  read -r GIT_CLONE_MIN AGENT_PROMPT_MIN CLI_VALIDATION_MIN WORKTREE_POINTER_MIN WORKTREE_POINTER_MIN_KB LARGE_TMP_ACTIVE_HOURS LARGE_TMP_ARCHIVE_RETENTION_HOURS <<<"$(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || echo "240 240 60 30 51200 24 24"
import json, os, sys
data = json.load(open(sys.argv[1]))
t = data.get("cleanup_thresholds", {})
print(f"{t.get('git_clone_minutes', 240)} {t.get('agent_prompt_minutes', 240)} {t.get('cli_validation_minutes', 60)} {t.get('worktree_pointer_minutes', 30)} {t.get('worktree_pointer_min_kb', 51200)} {os.environ.get('LARGE_TMP_ACTIVE_HOURS', t.get('large_tmp_active_hours', 24))} {os.environ.get('LARGE_TMP_ARCHIVE_RETENTION_HOURS', t.get('large_tmp_archive_retention_hours', 24))}")
PY
)"
fi

# --large branch: top-level /private/tmp basenames that are NEVER deleted or
# archived, regardless of mtime/size — a documented canonical evidence/repo
# root landing directly in /private/tmp (e.g. worldarchitect.ai's evidence
# path) must never be treated as scratch. Override via
# DISK_MAGICIAN_PROTECTED_TMP_ROOTS (space-separated) or config.json's
# top-level "protected_tmp_roots" array; env wins over config.
DEFAULT_PROTECTED_TMP_ROOTS=(worldarchitect.ai worldai_claw wa-missions)
PROTECTED_TMP_ROOTS=()
if [[ -n "${DISK_MAGICIAN_PROTECTED_TMP_ROOTS:-}" ]]; then
  read -r -a PROTECTED_TMP_ROOTS <<<"$DISK_MAGICIAN_PROTECTED_TMP_ROOTS"
elif [[ -f "$CONFIG_FILE" ]]; then
  # Portable read loop (not `mapfile`/`readarray`) — macOS ships /bin/bash
  # 3.2 by default and launchd jobs without an interactive PATH fall back to
  # it even though the shebang is `env bash`.
  while IFS= read -r root; do
    [[ -n "$root" ]] && PROTECTED_TMP_ROOTS+=("$root")
  done < <(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
for r in data.get("protected_tmp_roots") or []:
    print(r)
PY
)
fi
if [[ ${#PROTECTED_TMP_ROOTS[@]} -eq 0 ]]; then
  PROTECTED_TMP_ROOTS=("${DEFAULT_PROTECTED_TMP_ROOTS[@]}")
fi

DRY_RUN=true
INCLUDE_LARGE=false
INCLUDE_OPENCODE_DYLIBS=false
LARGE_TMP_MIN_KB="${LARGE_TMP_MIN_KB:-102400}"
usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--large] [--opencode-dylibs] [--help]

Delete stale agent git clones and temp files from system temp paths.

Options:
  --clean      Actually perform the cleanup (default: dry-run)
  --dry-run    Run in dry-run/preview mode
  --large      Include top-level /private/tmp dirs larger than LARGE_TMP_MIN_KB
  --opencode-dylibs
               Include closed OpenCode libopentui dylibs in DARWIN_USER_TEMP_DIR
  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --large)   INCLUDE_LARGE=true ;;
    --opencode-dylibs) INCLUDE_OPENCODE_DYLIBS=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$INCLUDE_LARGE" == true && "$DRY_RUN" != true && "${LARGE_TMP_APPROVED:-0}" != "1" ]]; then
  echo "Refusing large /private/tmp deletion: set LARGE_TMP_APPROVED=1 after reviewing dry-run output." >&2
  exit 0
fi

if [[ "$INCLUDE_OPENCODE_DYLIBS" == true && "$DRY_RUN" != true && "${OPENCODE_DYLIBS_APPROVED:-0}" != "1" ]]; then
  echo "Refusing OpenCode dylib cleanup: set OPENCODE_DYLIBS_APPROVED=1 after reviewing dry-run output." >&2
  exit 0
fi

TMP_DIRS=("/private/tmp" "/tmp")
# Add macOS user-specific temp dir if available
USER_TMP=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "")
if [[ -n "$USER_TMP" && -d "$USER_TMP" ]]; then
  USER_TMP=$(cd "$USER_TMP" && pwd -P)
  TMP_DIRS+=("$USER_TMP")
fi

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2; }
dry_prefix() { [[ "$DRY_RUN" == true ]] && echo "DRY RUN: " || echo ""; }

path_size_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1+0}' || echo 0
}

remove_path() {
  local path="$1"
  local kb
  kb=$(path_size_kb "$path")

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would remove: $path  (${kb} KB)"
  else
    log "Removing: $path  (${kb} KB)"
    rm -rf "$path"
  fi
  echo "$kb"
}

# is_protected_root <basename> — true if the top-level /private/tmp dir
# basename is on the never-touch list (see PROTECTED_TMP_ROOTS above).
is_protected_root() {
  local base="$1" root
  for root in "${PROTECTED_TMP_ROOTS[@]}"; do
    [[ "$base" == "$root" ]] && return 0
  done
  return 1
}

# has_recent_activity <dir> <hours> — true if any file/dir under <dir> has an
# mtime within the last <hours>. Fails CLOSED: any error reading the tree
# (permission denied, vanished path, etc.) is treated as "active" so the
# caller skips deletion rather than risking a false-negative on a directory
# it can't actually inspect. Uses /usr/bin/find explicitly — some shells in
# this fleet alias `find` to an incompatible wrapper that rejects -mmin.
has_recent_activity() {
  local dir="$1" hours="$2" mins hit_file rc=0
  mins=$(( hours * 60 ))
  hit_file="$(mktemp -t disk-magician-activity.XXXXXX)"
  /usr/bin/find "$dir" -mmin "-${mins}" -print -quit >"$hit_file" 2>/dev/null || rc=$?
  if (( rc != 0 )); then
    rm -f "$hit_file"
    log "Active-use check failed for $dir (find rc=${rc}) — fail-closed, treating as active."
    return 0
  fi
  if [[ -s "$hit_file" ]]; then
    rm -f "$hit_file"
    return 0
  fi
  rm -f "$hit_file"
  return 1
}

# archive_path <dir> <size_kb> — move (not delete) a large top-level /private/tmp dir
# into a dated quarantine root instead of an instant rm -rf. Same-filesystem
# mv is a rename (near-zero cost, frees no space immediately) so a later
# --large run can still purge_aged_archives() once the retention window
# passes, giving a real recovery window before space is reclaimed.
archive_path() {
  local path="$1" kb="$2" ts dest
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$ARCHIVE_ROOT/$ts"

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would archive: $path -> $dest/  (${kb} KB)"
  else
    mkdir -p "$dest"
    log "Archiving: $path -> $dest/  (${kb} KB)"
    mv "$path" "$dest/"
  fi
  echo "$kb"
}

# purge_aged_archives — permanently rm -rf archive entries older than
# LARGE_TMP_ARCHIVE_RETENTION_HOURS. This is the "later sweep ages it out"
# step that actually reclaims disk space for content nobody rescued.
purge_aged_archives() {
  [[ -d "$ARCHIVE_ROOT" ]] || return 0
  local mins=$(( LARGE_TMP_ARCHIVE_RETENTION_HOURS * 60 ))
  local d kb
  while IFS= read -r -d '' d; do
    kb=$(path_size_kb "$d")
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY RUN: would purge aged archive (>${LARGE_TMP_ARCHIVE_RETENTION_HOURS}h): $d  (${kb} KB)"
    else
      log "Purging aged archive (>${LARGE_TMP_ARCHIVE_RETENTION_HOURS}h): $d  (${kb} KB)"
      rm -rf "$d"
    fi
    TOTAL_KB=$(( TOTAL_KB + kb ))
    DIRS_DELETED=$(( DIRS_DELETED + 1 ))
  done < <(/usr/bin/find "$ARCHIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -mmin "+${mins}" -print0 2>/dev/null || true)
}

log "$(dry_prefix)cleanup_tmp.sh starting"

DIRS_DELETED=0
FILES_DELETED=0
TOTAL_KB=0
DIRS_ARCHIVED=0
ARCHIVED_KB=0

# Scan all temp directories for git clones & validation scratch dirs
for tmp_dir in "${TMP_DIRS[@]}"; do
  [[ -d "$tmp_dir" ]] || continue
  log "Scanning $tmp_dir ..."

  # 1. Any directory containing a .git folder and older than GIT_CLONE_MIN
  while IFS= read -r -d '' subdir; do
    [[ -d "$subdir/.git" ]] || continue
    # Skip essential system or user active directories
    case "$(basename "$subdir")" in
      claude-*|system-*|com.apple.*|PowerlogHelperd*) continue ;;
    esac

    kb=$(remove_path "$subdir")
    TOTAL_KB=$(( TOTAL_KB + kb ))
    DIRS_DELETED=$(( DIRS_DELETED + 1 ))
  done < <(find "$tmp_dir" -mindepth 1 -maxdepth 2 -type d \
              -mmin "+${GIT_CLONE_MIN}" -print0 2>/dev/null || true)

  # 2. agent_prompt_*.txt files older than AGENT_PROMPT_MIN
  while IFS= read -r -d '' f; do
    local_kb=$(path_size_kb "$f")
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY RUN: would remove: $f  (${local_kb} KB)"
    else
      log "Removing: $f  (${local_kb} KB)"
      rm -f "$f"
    fi
    TOTAL_KB=$(( TOTAL_KB + local_kb ))
    FILES_DELETED=$(( FILES_DELETED + 1 ))
  done < <(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type f \
              -name "agent_prompt_*.txt" \
              -mmin "+${AGENT_PROMPT_MIN}" -print0 2>/dev/null || true)

  # 3. cli_validation_gemini_* dirs older than CLI_VALIDATION_MIN
  while IFS= read -r -d '' d; do
    kb=$(remove_path "$d")
    TOTAL_KB=$(( TOTAL_KB + kb ))
    DIRS_DELETED=$(( DIRS_DELETED + 1 ))
  done < <(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d \
              -name "cli_validation_gemini_*" \
              -mmin "+${CLI_VALIDATION_MIN}" -print0 2>/dev/null || true)

  # 4. Worktree-linked dirs: .git is a file (worktree pointer) pointing at
  #    <parent_repo>/.git/worktrees/<name>/. Safety:
  #      - parse the "gitdir:" line
  #      - confirm the resolved gitdir exists
  #      - confirm it lives under a parent repo's .git/worktrees/
  #      - confirm the parent repo is NOT currently checked out to this worktree
  #      - honor the worktree-pointer mtime + min-size filters
  while IFS= read -r -d '' subdir; do
    # .git must be a regular file (worktree pointer), not a directory
    [[ -f "$subdir/.git" ]] || continue
    # Skip essential system or user active directories
    case "$(basename "$subdir")" in
      claude-*|system-*|com.apple.*|PowerlogHelperd*) continue ;;
    esac

    # Parse the gitdir: line from the pointer file
    gitdir_line=$(head -n 1 "$subdir/.git" 2>/dev/null || true)
    [[ "$gitdir_line" == gitdir:* ]] || continue
    gitdir_path="${gitdir_line#gitdir: }"
    # Resolve relative paths against the worktree dir
    if [[ "$gitdir_path" != /* ]]; then
      gitdir_path="$subdir/$gitdir_path"
    fi
    # Normalize via cd + pwd
    gitdir_path=$(cd "$subdir" && cd "$gitdir_path" 2>/dev/null && pwd) || continue
    [[ -d "$gitdir_path" ]] || continue

    # Confirm the gitdir lives under some <repo>/.git/worktrees/<name>
    case "$gitdir_path" in
      */.git/worktrees/*) : ;;
      *) continue ;;
    esac

    # Derive the parent repo's .git path
    parent_git_dir=$(echo "$gitdir_path" | sed -E 's#/\.git/worktrees/[^/]+/?\$##')
    [[ -d "$parent_git_dir" ]] || continue

    # Derive the parent repo's work-tree (working dir)
    parent_work_tree=$(git -C "$parent_git_dir" rev-parse --show-toplevel 2>/dev/null || true)
    [[ -n "$parent_work_tree" && -d "$parent_work_tree" ]] || continue

    # Safety: the worktree must NOT be the currently checked-out branch of the parent repo
    current_link=$(readlink "$parent_git_dir" 2>/dev/null || true)
    if [[ -n "$current_link" ]]; then
      # If HEAD points into the same worktrees/<name>/ we're considering, skip
      case "$current_link" in
        *"/worktrees/$(basename "$subdir")"|*"/worktrees/$(basename "$subdir")/") continue ;;
      esac
    fi
    # Also skip if the worktree dir IS the parent repo's toplevel
    if [[ "$(cd "$subdir" && pwd)" == "$(cd "$parent_work_tree" && pwd)" ]]; then
      continue
    fi

    # Size filter
    kb=$(path_size_kb "$subdir")
    if [[ "$kb" -lt "$WORKTREE_POINTER_MIN_KB" ]]; then
      log "Skipping (under min size ${WORKTREE_POINTER_MIN_KB} KB): $subdir  (${kb} KB)"
      continue
    fi

    kb=$(remove_path "$subdir")
    TOTAL_KB=$(( TOTAL_KB + kb ))
    DIRS_DELETED=$(( DIRS_DELETED + 1 ))
  done < <(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d \
              -mmin "+${WORKTREE_POINTER_MIN}" -print0 2>/dev/null || true)
done

if [[ "$INCLUDE_OPENCODE_DYLIBS" == true ]]; then
  log "Scanning DARWIN_USER_TEMP_DIR for OpenCode libopentui dylibs ..."
  if [[ -z "$USER_TMP" || ! -d "$USER_TMP" ]]; then
    log "Skipping OpenCode dylibs: DARWIN_USER_TEMP_DIR is unavailable"
  elif ! command -v otool >/dev/null 2>&1; then
    log "Skipping OpenCode dylibs: otool is unavailable"
  elif [[ "$DRY_RUN" != true ]] && ! command -v lsof >/dev/null 2>&1; then
    log "Skipping OpenCode dylibs: lsof is unavailable, cannot prove files are closed"
  else
    dylib_candidate_file=$(mktemp -t disk-magician-opencode-dylibs.XXXXXX)
    trap 'rm -f "${dylib_candidate_file:-}"' EXIT
    find "$USER_TMP" -mindepth 1 -maxdepth 1 -type f \
      -name '.*.dylib' -print0 2>/dev/null > "$dylib_candidate_file" || true

    open_dylibs=""
    lsof_rc=0
    if command -v lsof >/dev/null 2>&1; then
      set +e
      lsof_output=$(lsof +D "$USER_TMP" -Fn 2>/dev/null)
      lsof_rc=$?
      set -e
      open_dylibs=$(sed -n 's/^n//p' <<<"$lsof_output")
    fi
    if [[ "$DRY_RUN" != true && "$lsof_rc" -gt 1 ]]; then
      log "Skipping OpenCode dylibs: lsof failed (rc=${lsof_rc}), cannot prove files are closed"
    else
      dylib_candidates=0
      dylib_deleted=0
      while IFS= read -r -d '' f; do
        [[ -f "$f" ]] || continue
        otool_output=$(otool -D "$f" 2>/dev/null || true)
        grep -Fxq '@rpath/libopentui.dylib' <<<"$otool_output" || continue
        dylib_candidates=$(( dylib_candidates + 1 ))
        if grep -Fxq "$f" <<<"$open_dylibs"; then
          log "Skipping in-use OpenCode dylib: $f"
          continue
        fi
        if [[ "$DRY_RUN" == true ]]; then
          log "DRY RUN: would remove closed OpenCode dylib: $f"
        else
          rm -f "$f"
          dylib_deleted=$(( dylib_deleted + 1 ))
        fi
      done < "$dylib_candidate_file"
      log "$(dry_prefix)OpenCode dylibs: candidates ${dylib_candidates}, deleted ${dylib_deleted}"
      FILES_DELETED=$(( FILES_DELETED + dylib_deleted ))
    fi
    rm -f "$dylib_candidate_file"
    dylib_candidate_file=""
  fi
fi

if [[ "$INCLUDE_LARGE" == true ]]; then
  # Overridable so sandboxed tests can point archiving at a fixture tree
  # instead of the real /private/tmp; production always uses the default.
  ARCHIVE_ROOT="${DISK_MAGICIAN_ARCHIVE_ROOT:-/private/tmp/_disk_magician_archive}"
  log "Scanning /private/tmp for large top-level dirs >= ${LARGE_TMP_MIN_KB} KB (active-use window: ${LARGE_TMP_ACTIVE_HOURS}h, protected roots: ${PROTECTED_TMP_ROOTS[*]}) ..."
  while IFS= read -r -d '' d; do
    base="$(basename "$d")"

    case "$base" in
      com.apple.*|system-*|PowerlogHelperd*) continue ;;
      # Our own quarantine root — never re-archive/delete it here;
      # purge_aged_archives() below is the only thing that touches it.
      _disk_magician_archive) continue ;;
    esac
    case "$base" in
      wt_*|worktree_*)
        log "Skipping temp worktree dir (requires TMP_WORKTREES_APPROVED=1): $d"
        [[ "${TMP_WORKTREES_APPROVED:-0}" == "1" ]] || continue
        ;;
    esac

    if is_protected_root "$base"; then
      log "Skipping protected root (in PROTECTED_TMP_ROOTS): $d"
      continue
    fi

    kb=$(path_size_kb "$d")
    if [[ "$kb" -lt "$LARGE_TMP_MIN_KB" ]]; then
      continue
    fi

    if [[ "$DRY_RUN" != true ]] && command -v lsof >/dev/null 2>&1 && lsof +D "$d" >/dev/null 2>&1; then
      log "Skipping in-use large tmp dir: $d  (${kb} KB)"
      continue
    fi

    if [[ -e "$d/.in-use" ]]; then
      log "Skipping active-use marker (.in-use present): $d  (${kb} KB)"
      continue
    fi

    if has_recent_activity "$d" "$LARGE_TMP_ACTIVE_HOURS"; then
      log "Skipping recently active dir (mtime within ${LARGE_TMP_ACTIVE_HOURS}h): $d  (${kb} KB)"
      continue
    fi

    archive_path "$d" "$kb" >/dev/null
    ARCHIVED_KB=$(( ARCHIVED_KB + kb ))
    DIRS_ARCHIVED=$(( DIRS_ARCHIVED + 1 ))
  done < <(find /private/tmp -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)

  purge_aged_archives
fi

log "$(dry_prefix)Done. Dirs removed: ${DIRS_DELETED}  Files removed: ${FILES_DELETED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)  Dirs archived: ${DIRS_ARCHIVED}  Total archived: ${ARCHIVED_KB} KB"
