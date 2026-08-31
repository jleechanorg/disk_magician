#!/usr/bin/env bash
# cleanup_pr_scratch.sh — Clean abandoned PR analyzer and scratch work directories in /private/tmp.
#
# Defaults to DRY-RUN; pass --clean or --apply to actually delete.
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_recency.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.json"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/config.json.template"

# Default configuration
DEFAULT_MIN_AGE_HOURS=48
DEFAULT_PATTERNS=("pr[0-9]*" "pr-*" "pr_*" "pr9*" "claude-*" "claude_*")
DEFAULT_PROTECTED_TMP_ROOTS=(worldarchitect.ai worldai_claw wa-missions)

MIN_AGE_HOURS="${DISK_MAGICIAN_PR_SCRATCH_MIN_AGE_HOURS:-}"
if [[ -z "$MIN_AGE_HOURS" && -f "$CONFIG_FILE" ]]; then
  MIN_AGE_HOURS="$(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || true
import json, sys
data = json.load(open(sys.argv[1]))
t = data.get("cleanup_thresholds", {})
print(t.get("pr_scratch_retention_hours", t.get("pr_scratch_hours", "")))
PY
)"
fi
MIN_AGE_HOURS="${MIN_AGE_HOURS:-$DEFAULT_MIN_AGE_HOURS}"

PROTECTED_TMP_ROOTS=()
if [[ -n "${DISK_MAGICIAN_PROTECTED_TMP_ROOTS:-}" ]]; then
  read -r -a PROTECTED_TMP_ROOTS <<<"$DISK_MAGICIAN_PROTECTED_TMP_ROOTS"
elif [[ -f "$CONFIG_FILE" ]]; then
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

PATTERNS=()
if [[ -n "${DISK_MAGICIAN_PR_SCRATCH_PATTERNS:-}" ]]; then
  read -r -a PATTERNS <<<"$DISK_MAGICIAN_PR_SCRATCH_PATTERNS"
elif [[ -f "$CONFIG_FILE" ]]; then
  while IFS= read -r pat; do
    [[ -n "$pat" ]] && PATTERNS+=("$pat")
  done < <(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
for p in data.get("pr_scratch_patterns") or []:
    print(p)
PY
)
fi
if [[ ${#PATTERNS[@]} -eq 0 ]]; then
  PATTERNS=("${DEFAULT_PATTERNS[@]}")
fi

DRY_RUN=true
CLI_TMP_DIRS=()
CLI_PATTERNS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean|--apply] [--dry-run] [--min-age-hours <N>] [--min-age-days <N>] [--tmp-dir <DIR>] [--pattern <PAT>] [-h|--help]

Clean up abandoned PR analyzer and scratch work directories in /private/tmp.

Options:
  --clean, --apply    Actually delete eligible entries (default: dry-run).
  --dry-run           Preview deletions without removing any files.
  --min-age-hours <N> Minimum age in hours before cleanup eligibility (default: 48).
  --min-age-days <N>  Minimum age in days (converted to hours).
  --tmp-dir <DIR>     Add or specify custom temporary directory to scan.
  --pattern <PAT>     Add custom glob pattern to match (e.g. "pr9*", "claude-*").
  -h, --help          Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean|--apply)
      DRY_RUN=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --min-age-hours)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --min-age-hours requires an integer argument" >&2
        exit 2
      fi
      MIN_AGE_HOURS="$2"
      shift 2
      ;;
    --min-age-hours=*)
      MIN_AGE_HOURS="${1#*=}"
      shift
      ;;
    --min-age-days)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --min-age-days requires an integer argument" >&2
        exit 2
      fi
      MIN_AGE_HOURS=$(( "$2" * 24 ))
      shift 2
      ;;
    --min-age-days=*)
      MIN_AGE_HOURS=$(( "${1#*=}" * 24 ))
      shift
      ;;
    --tmp-dir)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --tmp-dir requires a directory path" >&2
        exit 2
      fi
      CLI_TMP_DIRS+=("$2")
      shift 2
      ;;
    --tmp-dir=*)
      CLI_TMP_DIRS+=("${1#*=}")
      shift
      ;;
    --pattern)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --pattern requires a pattern string" >&2
        exit 2
      fi
      CLI_PATTERNS+=("$2")
      shift 2
      ;;
    --pattern=*)
      CLI_PATTERNS+=("${1#*=}")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! [[ "$MIN_AGE_HOURS" =~ ^[0-9]+$ ]] || (( MIN_AGE_HOURS < 0 )); then
  echo "Error: min-age-hours must be a non-negative integer, got '$MIN_AGE_HOURS'" >&2
  exit 2
fi

if [[ ${#CLI_PATTERNS[@]} -gt 0 ]]; then
  PATTERNS=("${CLI_PATTERNS[@]}")
fi

TMP_DIRS=()
if [[ ${#CLI_TMP_DIRS[@]} -gt 0 ]]; then
  TMP_DIRS=("${CLI_TMP_DIRS[@]}")
elif [[ -n "${DISK_MAGICIAN_PR_SCRATCH_ROOTS:-}" ]]; then
  read -r -a TMP_DIRS <<<"$DISK_MAGICIAN_PR_SCRATCH_ROOTS"
elif [[ -n "${DISK_MAGICIAN_TMP_DIR:-}" ]]; then
  TMP_DIRS=("$DISK_MAGICIAN_TMP_DIR")
else
  TMP_DIRS=("/private/tmp" "/tmp")
fi

# Normalize and deduplicate tmp directories
CANONICAL_TMP_DIRS=()
if [[ ${#TMP_DIRS[@]} -gt 0 ]]; then
  for tdir in "${TMP_DIRS[@]}"; do
    [[ -d "$tdir" ]] || continue
    canon="$(cd "$tdir" 2>/dev/null && pwd -P)" || canon="$tdir"
    already=false
    if [[ ${#CANONICAL_TMP_DIRS[@]} -gt 0 ]]; then
      for c in "${CANONICAL_TMP_DIRS[@]}"; do
        if [[ "$c" == "$canon" ]]; then
          already=true
          break
        fi
      done
    fi
    if [[ "$already" == false ]]; then
      CANONICAL_TMP_DIRS+=("$canon")
    fi
  done
fi

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2; }
dry_prefix() { [[ "$DRY_RUN" == true ]] && echo "DRY RUN: " || echo ""; }

find_cmd() {
  if [[ -n "${DISK_MAGICIAN_FIND_BIN:-}" ]]; then
    "$DISK_MAGICIAN_FIND_BIN" "$@"
  elif command -v find >/dev/null 2>&1; then
    find "$@"
  else
    /usr/bin/find "$@"
  fi
}

path_size_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1+0}' || echo 0
}

is_protected_root() {
  local base="$1" root
  if [[ ${#PROTECTED_TMP_ROOTS[@]} -gt 0 ]]; then
    for root in "${PROTECTED_TMP_ROOTS[@]}"; do
      [[ "$base" == "$root" ]] && return 0
    done
  fi
  return 1
}

is_protected_tmp_path() {
  local path="$1" root
  if [[ ${#PROTECTED_TMP_ROOTS[@]} -gt 0 ]]; then
    for root in "${PROTECTED_TMP_ROOTS[@]}"; do
      case "/$path/" in
        *"/$root/"*) return 0 ;;
      esac
    done
  fi
  return 1
}

matches_scratch_pattern() {
  local base="$1" pat
  if [[ ${#PATTERNS[@]} -gt 0 ]]; then
    for pat in "${PATTERNS[@]}"; do
      # shellcheck disable=SC2254
      case "$base" in
        $pat) return 0 ;;
      esac
    done
  fi
  return 1
}

has_recent_activity() {

  local target="$1" hours="$2" mins hit_file
  mins=$(( hours * 60 ))
  hit_file="$(mktemp -t disk-magician-activity.XXXXXX)"
  find_cmd "$target" -mmin "-${mins}" -print 2>/dev/null | head -n 1 >"$hit_file" || true
  if [[ -s "$hit_file" ]]; then
    rm -f "$hit_file"
    return 0
  fi
  rm -f "$hit_file"
  return 1
}

has_active_marker() {
  local target="$1" hit_file
  if [[ ! -d "$target" ]]; then
    return 1
  fi
  hit_file="$(mktemp -t disk-magician-marker.XXXXXX)"
  find_cmd "$target" \( -name .in-use -o -name .keep \) -print 2>/dev/null | head -n 1 >"$hit_file" || true
  if [[ -s "$hit_file" ]]; then
    rm -f "$hit_file"
    return 0
  fi
  rm -f "$hit_file"
  return 1
}


has_open_files() {
  local target="$1" lsof_bin out rc=0 timeout_cmd="" timeout_sec="${DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS:-5}"
  if [[ "${DISK_MAGICIAN_SKIP_LSOF_CHECK:-0}" == "1" ]]; then
    return 1
  fi
  if [[ -n "${DISK_MAGICIAN_LSOF_BIN:-}" ]]; then
    lsof_bin="$DISK_MAGICIAN_LSOF_BIN"
  elif [[ -x /usr/sbin/lsof ]]; then
    lsof_bin=/usr/sbin/lsof
  elif lsof_bin=$(command -v lsof 2>/dev/null); then
    :
  else
    log "Open-file check unavailable for $target — fail-closed, treating as active."
    return 0
  fi
  if [[ ! -x "$lsof_bin" ]]; then
    log "Open-file check unavailable for $target ($lsof_bin is not executable) — fail-closed, treating as active."
    return 0
  fi

  if [[ -n "${DISK_MAGICIAN_TIMEOUT_BIN:-}" ]]; then
    timeout_cmd="$DISK_MAGICIAN_TIMEOUT_BIN"
  elif command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout"
  fi

  local cmd=()
  if [[ -n "$timeout_cmd" ]]; then
    cmd=("$timeout_cmd" "$timeout_sec" "$lsof_bin")
  else
    cmd=("$lsof_bin")
  fi

  if [[ -d "$target" ]]; then
    out="$("${cmd[@]}" +w +D "$target" 2>/dev/null)" || rc=$?
  else
    out="$("${cmd[@]}" +w "$target" 2>/dev/null)" || rc=$?
  fi

  if [[ -n "$out" ]]; then
    return 0
  fi
  if (( rc != 1 && rc != 0 )); then
    log "Open-file check failed for $target (lsof rc=${rc}) — fail-closed, treating as active."
    return 0
  fi
  return 1
}



worktree_has_unsaved_work() {
  local wt="$1" git_bin upstream
  git_bin=$(command -v git 2>/dev/null) || {
    log "git unavailable — cannot prove worktree $wt is clean; treating as unsafe."
    return 0
  }
  # Not a git worktree at all -> no git work to lose here.
  "$git_bin" -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  # Uncommitted or untracked changes.
  if [[ -n "$("$git_bin" -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    return 0
  fi
  # Unpushed commits, or no upstream to compare against -> fail closed.
  upstream=$("$git_bin" -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || return 0
  [[ -z "$upstream" ]] && return 0
  if [[ -n "$("$git_bin" -C "$wt" rev-list "${upstream}..HEAD" 2>/dev/null)" ]]; then
    return 0
  fi
  return 1
}

log "$(dry_prefix)cleanup_pr_scratch.sh starting (roots: ${CANONICAL_TMP_DIRS[*]:-none}, patterns: ${PATTERNS[*]}, min-age: ${MIN_AGE_HOURS}h)"

DIRS_DELETED=0
FILES_DELETED=0
TOTAL_KB=0

if [[ ${#CANONICAL_TMP_DIRS[@]} -gt 0 ]]; then
  for tmp_dir in "${CANONICAL_TMP_DIRS[@]}"; do
    [[ -d "$tmp_dir" ]] || continue
    log "Scanning $tmp_dir for PR scratch & analyzer entries ..."

    while IFS= read -r -d '' item; do
      base="$(basename "$item")"
      [[ -n "$base" ]] || continue

      if ! matches_scratch_pattern "$base"; then
        continue
      fi

      if is_protected_root "$base" || is_protected_tmp_path "$item"; then
        log "Skipping protected root (in PROTECTED_TMP_ROOTS): $item"
        continue
      fi

      case "$base" in
        com.apple.*|system-*|PowerlogHelperd*|_disk_magician_archive) continue ;;
      esac

      if has_active_marker "$item"; then
        log "Skipping active-use marker (.in-use/.keep present): $item"
        continue
      fi

      if has_recent_activity "$item" "$MIN_AGE_HOURS"; then
        log "Skipping recently active path (mtime within ${MIN_AGE_HOURS}h): $item"
        continue
      fi

      if has_open_files "$item"; then
        log "Skipping in-use path (open files): $item"
        continue
      fi

      if [[ -d "$item/.git" || -f "$item/.git" ]]; then
        if worktree_has_unsaved_work "$item"; then
          log "Skipping scratch worktree with unsaved work (uncommitted/unpushed/no-upstream): $item"
          continue
        fi
      fi

      kb=$(path_size_kb "$item")
      if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN: would remove: $item  (${kb} KB)"
        if [[ -d "$item" ]]; then
          DIRS_DELETED=$(( DIRS_DELETED + 1 ))
        else
          FILES_DELETED=$(( FILES_DELETED + 1 ))
        fi
        TOTAL_KB=$(( TOTAL_KB + kb ))
      else
        if ! _safety_reason="$(safety_gate "$item" 2>/dev/null)"; then
          echo "SAFETY-SKIP $item ($_safety_reason)"
          continue
        fi
        log "Removing: $item  (${kb} KB)"
        if [[ -d "$item" ]]; then
          rm -rf "$item"
          DIRS_DELETED=$(( DIRS_DELETED + 1 ))
        else
          rm -f "$item"
          FILES_DELETED=$(( FILES_DELETED + 1 ))
        fi
        TOTAL_KB=$(( TOTAL_KB + kb ))
      fi
    done < <(find "$tmp_dir" -mindepth 1 -maxdepth 1 \( -type d -o -type f -o -type l \) -print0 2>/dev/null || true)
  done
fi

log "$(dry_prefix)Done. Dirs removed: ${DIRS_DELETED}  Files removed: ${FILES_DELETED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)"

