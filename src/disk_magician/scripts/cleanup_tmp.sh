#!/usr/bin/env bash
# cleanup_tmp.sh — Delete stale git clones and temp logs from system temp directories.
#
# Defaults to actually deleting (use --dry-run to preview).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.json"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/config.json.template"

# Default thresholds (minutes)
GIT_CLONE_MIN=240
AGENT_PROMPT_MIN=240
CLI_VALIDATION_MIN=60
WORKTREE_POINTER_MIN=30
WORKTREE_POINTER_MIN_KB=51200

if [[ -f "$CONFIG_FILE" ]]; then
  read -r GIT_CLONE_MIN AGENT_PROMPT_MIN CLI_VALIDATION_MIN WORKTREE_POINTER_MIN WORKTREE_POINTER_MIN_KB <<<$(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || echo "240 240 60 30 51200"
import json, sys
data = json.load(open(sys.argv[1]))
t = data.get("cleanup_thresholds", {})
print(f"{t.get('git_clone_minutes', 240)} {t.get('agent_prompt_minutes', 240)} {t.get('cli_validation_minutes', 60)} {t.get('worktree_pointer_minutes', 30)} {t.get('worktree_pointer_min_kb', 51200)}")
PY
)
fi

DRY_RUN=true
INCLUDE_LARGE=false
LARGE_TMP_MIN_KB="${LARGE_TMP_MIN_KB:-102400}"
usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--large] [--help]

Delete stale agent git clones and temp files from system temp paths.

Options:
  --clean      Actually perform the cleanup (default: dry-run)
  --dry-run    Run in dry-run/preview mode
  --large      Include top-level /private/tmp dirs larger than LARGE_TMP_MIN_KB
  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --large)   INCLUDE_LARGE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$INCLUDE_LARGE" == true && "$DRY_RUN" != true && "${LARGE_TMP_APPROVED:-0}" != "1" ]]; then
  echo "Refusing large /private/tmp deletion: set LARGE_TMP_APPROVED=1 after reviewing dry-run output." >&2
  exit 0
fi

TMP_DIRS=("/private/tmp" "/tmp")
# Add macOS user-specific temp dir if available
USER_TMP=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "")
if [[ -n "$USER_TMP" && -d "$USER_TMP" ]]; then
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

log "$(dry_prefix)cleanup_tmp.sh starting"

DIRS_DELETED=0
FILES_DELETED=0
TOTAL_KB=0

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

if [[ "$INCLUDE_LARGE" == true ]]; then
  log "Scanning /private/tmp for large top-level dirs >= ${LARGE_TMP_MIN_KB} KB ..."
  while IFS= read -r -d '' d; do
    case "$(basename "$d")" in
      com.apple.*|system-*|PowerlogHelperd*) continue ;;
    esac
    case "$(basename "$d")" in
      wt_*|worktree_*)
        log "Skipping temp worktree dir (requires TMP_WORKTREES_APPROVED=1): $d"
        [[ "${TMP_WORKTREES_APPROVED:-0}" == "1" ]] || continue
        ;;
    esac

    kb=$(path_size_kb "$d")
    if [[ "$kb" -lt "$LARGE_TMP_MIN_KB" ]]; then
      continue
    fi

    if [[ "$DRY_RUN" != true ]] && command -v lsof >/dev/null 2>&1 && lsof +D "$d" >/dev/null 2>&1; then
      log "Skipping in-use large tmp dir: $d  (${kb} KB)"
      continue
    fi

    kb=$(remove_path "$d")
    TOTAL_KB=$(( TOTAL_KB + kb ))
    DIRS_DELETED=$(( DIRS_DELETED + 1 ))
  done < <(find /private/tmp -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
fi

log "$(dry_prefix)Done. Dirs removed: ${DIRS_DELETED}  Files removed: ${FILES_DELETED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)"
