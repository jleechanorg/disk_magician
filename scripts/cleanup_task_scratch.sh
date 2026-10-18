#!/usr/bin/env bash
# cleanup_task_scratch.sh — Safely clean aged task-scratch containers under ~/projects and ~/projects_other (bead disk_magician-jj2).
#
# Defaults to DRY-RUN (--dry-run); pass --clean (or --apply) to execute removals.
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure lsof is reachable on macOS where /usr/sbin may not be in non-login PATH.
if ! command -v lsof >/dev/null 2>&1 && [[ -x /usr/sbin/lsof ]]; then
  export PATH="$PATH:/usr/sbin"
fi
if [[ -z "${DISK_MAGICIAN_LSOF_BIN:-}" ]]; then
  if command -v lsof >/dev/null 2>&1; then
    DISK_MAGICIAN_LSOF_BIN="$(command -v lsof)"
    export DISK_MAGICIAN_LSOF_BIN
  fi
fi

# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$SCRIPT_DIR/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$SCRIPT_DIR/lib/worktree_ignored.sh"
# shellcheck source=scripts/lib/quarantine.sh
source "$SCRIPT_DIR/lib/quarantine.sh"

DRY_RUN=true
TASK_SCRATCH_MIN_AGE_HOURS="${DISK_MAGICIAN_TASK_SCRATCH_MIN_AGE_HOURS:-12}"
TASK_SCRATCH_ROOTS_RAW="${DISK_MAGICIAN_TASK_SCRATCH_ROOTS:-$HOME/projects:$HOME/projects_other}"
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
MANIFEST_FILE="$STATE_DIR/task_scratch_cleanup_manifest.txt"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean|--apply] [--dry-run] [--min-age-hours <N>] [--roots <DIR[:DIR...]>] [-h|--help]

Safely clean aged task-scratch container directories under ~/projects and ~/projects_other.

Candidates:
  Top-level directories under each configured root that are NOT themselves git
  repositories or linked worktrees (no .git entry) and match task-scratch
  container patterns: *-???????? (8-char lowercase hex/alnum suffix),
  pr[0-9]*-*, pr-[0-9]*-*, advice*, ready-*.

Safety Gates (fail-closed):
  - Skips paths protected by safety_gate (safety.local.json).
  - Skips containers with any entry modified within --min-age-hours (default: 12h).
  - Skips containers with open file handles (_av_open_file / lsof +D) or live cwd.
  - Skips containers containing secret-like files (_av_secret_like).
  - Inspects nested git worktrees and clones: preserves the container if any
    child repo/worktree is dirty or has commits not reachable from refs/remotes/*.
  - Removes clean, pushed linked worktrees via 'git worktree remove' (no --force),
    removes C14-verified ephemeral scratch entries, and appends manifest lines to:
    \${DISK_MAGICIAN_STATE_DIR:-\$HOME/.disk_magician_state}/task_scratch_cleanup_manifest.txt

Options:
  --clean, --apply       Execute removals (default: dry-run preview).
  --dry-run              Preview candidates without modifying disk or manifest.
  --min-age-hours <N>    Minimum container quiet age in hours (default: 12;
                         env DISK_MAGICIAN_TASK_SCRATCH_MIN_AGE_HOURS).
  --roots <DIR[:DIR...]> Colon-separated scan roots (default:
                         \$HOME/projects:\$HOME/projects_other;
                         env DISK_MAGICIAN_TASK_SCRATCH_ROOTS).
  -h, --help             Show this help message.
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
      TASK_SCRATCH_MIN_AGE_HOURS="$2"
      shift 2
      ;;
    --min-age-hours=*)
      TASK_SCRATCH_MIN_AGE_HOURS="${1#*=}"
      shift
      ;;
    --roots)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --roots requires a path list argument" >&2
        exit 2
      fi
      TASK_SCRATCH_ROOTS_RAW="$2"
      shift 2
      ;;
    --roots=*)
      TASK_SCRATCH_ROOTS_RAW="${1#*=}"
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

if ! [[ "$TASK_SCRATCH_MIN_AGE_HOURS" =~ ^[0-9]+$ ]]; then
  echo "Error: min-age-hours must be a non-negative integer, got '$TASK_SCRATCH_MIN_AGE_HOURS'" >&2
  exit 2
fi
TASK_SCRATCH_MIN_AGE_HOURS=$((10#$TASK_SCRATCH_MIN_AGE_HOURS))

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
dry_prefix() { [[ "$DRY_RUN" == true ]] && echo "DRY RUN: " || echo ""; }

path_size_kb() {
  { du -sk "$1" 2>/dev/null || true; } | awk '{f=$1} END{print f+0}'
}

append_manifest() {
  local action="$1" target="$2"
  mkdir -p "$(dirname "$MANIFEST_FILE")"
  printf '%s %s\n' "$action" "$target" >>"$MANIFEST_FILE"
}

matches_task_scratch_pattern() {
  local base="$1"
  case "$base" in
    pr[0-9]*-*|pr-[0-9]*-*|advice*|ready-*)
      return 0
      ;;
  esac
  if [[ "$base" =~ ^.+-[a-z0-9_]{8}$ ]]; then
    return 0
  fi
  return 1
}

# dir_newest_mtime_epoch <dir>: walks <dir> without following symlinks and
# prints the maximum integer mtime across <dir> and all descendants.
# Fails closed (returns 1) on any unreadable directory or stat failure.
dir_newest_mtime_epoch() {
  local target="$1"
  python3 - "$target" <<'PY'
import os, sys
root = sys.argv[1]
try:
    m = int(os.lstat(root).st_mtime)
    def on_err(err):
        raise err
    for dp, dns, fns in os.walk(root, topdown=True, onerror=on_err, followlinks=False):
        for name in dns + fns:
            p = os.path.join(dp, name)
            st = os.lstat(p)
            mt = int(st.st_mtime)
            if mt > m:
                m = mt
    print(m)
except Exception:
    sys.exit(1)
PY
}

set_dir_mtime_epoch() {
  local target="$1" epoch="$2"
  python3 - "$target" "$epoch" <<'PY' 2>/dev/null || true
import os, sys
p, t = sys.argv[1], int(sys.argv[2])
os.utime(p, (t, t), follow_symlinks=False)
PY
}

git_dir_of() {
  (cd "$1" 2>/dev/null && cd "$(git rev-parse "$2" 2>/dev/null)" 2>/dev/null && pwd -P)
}

# eligible_remote_args <repo> <container>: prints `--remotes=<name>` for every
# remote whose URL does not resolve inside <container>. Local remotes inside the
# scratch container would be deleted with it, so they do not count as pushed.
eligible_remote_args() {
  local repo="$1" container="$2" name url p
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    local ok=true
    while IFS= read -r url; do
      case "$url" in
        file://*) p="${url#file://}" ;;
        /*|./*|../*|~*) p="$url" ;;
        *://*|*@*:*) continue ;;
        *:*) continue ;;
        *) p="$url" ;;
      esac
      p="${p/#\~/$HOME}"
      p="$(cd "$repo" 2>/dev/null && cd "$p" 2>/dev/null && pwd -P)" || { ok=false; break; }
      case "$p" in
        "$container"|"$container"/*) ok=false; break ;;
      esac
    done < <(git -C "$repo" remote get-url --all "$name" 2>/dev/null || echo "?unreadable")
    if [[ "$ok" == true ]]; then
      echo "--remotes=$name"
    fi
  done < <(git -C "$repo" remote 2>/dev/null)
}

find_bare_repo_in() {
  local search_root="$1" o p
  while IFS= read -r -d '' o; do
    p="$(dirname "$o")"
    case "$p/" in */.git/*) continue ;; esac
    if [[ -f "$p/HEAD" && -d "$p/refs" ]]; then
      echo "$p"
      return 0
    fi
  done < <(/usr/bin/find "$search_root" -type d -name objects -print0 2>/dev/null)
  return 1
}

# inspect_container_repos <container>:
# Sets CONTAINER_REPO_REASON (empty when all nested repos/worktrees are safe to
# clean) and CONTAINER_WT_REMOVALS (lines of "common_dir<TAB>worktree_path",
# ordered deepest-first).
CONTAINER_REPO_REASON=""
CONTAINER_WT_REMOVALS=""
inspect_container_repos() {
  local container="$1" bare g repo st line gd common wts self blk unpushed lb ext
  CONTAINER_REPO_REASON=""
  CONTAINER_WT_REMOVALS=""

  if bare="$(find_bare_repo_in "$container")"; then
    CONTAINER_REPO_REASON="bare-repo:$bare"
    return 0
  fi

  local gits_tmp
  gits_tmp="$(mktemp "${TMPDIR:-/tmp}/dm-task-scratch-gits.XXXXXX")" || {
    CONTAINER_REPO_REASON="mktemp-failed"
    return 0
  }
  if ! /usr/bin/find "$container" -mindepth 2 -name .git -prune -print0 >"$gits_tmp" 2>/dev/null; then
    rm -f "$gits_tmp"
    CONTAINER_REPO_REASON="find-failed"
    return 0
  fi

  local gits=()
  while IFS= read -r -d '' g; do
    gits+=("$g")
  done < <(python3 - "$gits_tmp" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read().split(b"\0")
items = [x for x in raw if x]
items.sort(key=lambda p: (-p.count(b"/"), p))
for x in items:
    sys.stdout.buffer.write(x + b"\0")
PY
)
  rm -f "$gits_tmp"

  for g in ${gits[@]+"${gits[@]}"}; do
    repo="$(dirname "$g")"
    if [[ -L "$g" ]]; then
      CONTAINER_REPO_REASON="symlink-git:$repo"
      return 0
    fi
    if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      CONTAINER_REPO_REASON="git-unreadable:$repo"
      return 0
    fi
    st="$(git -C "$repo" status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)" || {
      CONTAINER_REPO_REASON="git-status-failed:$repo"
      return 0
    }
    if [[ -n "$st" ]]; then
      CONTAINER_REPO_REASON="dirty:$repo"
      return 0
    fi
    if has_hidden_state "$repo"; then
      CONTAINER_REPO_REASON="hidden-state:$repo"
      return 0
    fi
    if has_ignored_user_data "$repo"; then
      CONTAINER_REPO_REASON="ignored-user-data:$repo"
      return 0
    fi

    local rargs=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && rargs+=("$line")
    done < <(eligible_remote_args "$repo" "$container")
    if [[ ${#rargs[@]} -eq 0 ]]; then
      CONTAINER_REPO_REASON="no-remote:$repo"
      return 0
    fi
    if [[ -z "$(git -C "$repo" for-each-ref --count=1 --format='%(refname)' refs/remotes 2>/dev/null)" ]]; then
      CONTAINER_REPO_REASON="no-remote-refs:$repo"
      return 0
    fi
    unpushed="$(git -C "$repo" rev-list -n 1 HEAD --not "${rargs[@]}" 2>/dev/null)" || {
      CONTAINER_REPO_REASON="rev-list-failed:$repo"
      return 0
    }
    if [[ -n "$unpushed" ]]; then
      CONTAINER_REPO_REASON="unpushed-head:$repo"
      return 0
    fi

    gd="$(git_dir_of "$repo" --git-dir)" || {
      CONTAINER_REPO_REASON="git-dir-unreadable:$repo"
      return 0
    }
    common="$(git_dir_of "$repo" --git-common-dir)" || {
      CONTAINER_REPO_REASON="git-common-dir-unreadable:$repo"
      return 0
    }

    if [[ "$gd" != "$common" ]]; then
      # Linked worktree
      case "$common" in
        "$container"|"$container"/*)
          continue
          ;;
      esac
      wts="$(git --git-dir="$common" worktree list --porcelain 2>/dev/null)" || {
        CONTAINER_REPO_REASON="worktree-list-failed:$repo"
        return 0
      }
      self="$(cd "$repo" 2>/dev/null && pwd -P)" || {
        CONTAINER_REPO_REASON="worktree-path-unreadable:$repo"
        return 0
      }
      blk="$(awk -v p="$self" 'BEGIN{RS="";FS="\n"} {for(i=1;i<=NF;i++) if($i=="worktree " p){print; exit}}' <<<"$wts")"
      if [[ -z "$blk" ]]; then
        CONTAINER_REPO_REASON="worktree-unregistered:$repo"
        return 0
      fi
      if grep -q '^locked' <<<"$blk"; then
        CONTAINER_REPO_REASON="worktree-locked:$repo"
        return 0
      fi
      CONTAINER_WT_REMOVALS="${CONTAINER_WT_REMOVALS}${common}"$'\t'"${self}"$'\n'
    else
      # Standalone git clone inside container
      lb="$(git -C "$repo" rev-list -n 1 --branches --not "${rargs[@]}" 2>/dev/null)" || {
        CONTAINER_REPO_REASON="branch-rev-list-failed:$repo"
        return 0
      }
      if [[ -n "$lb" ]]; then
        CONTAINER_REPO_REASON="unpushed-branches:$repo"
        return 0
      fi
      if [[ -n "$(git -C "$repo" stash list 2>/dev/null || echo "?stash-err")" ]]; then
        CONTAINER_REPO_REASON="stash-present:$repo"
        return 0
      fi
      wts="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || {
        CONTAINER_REPO_REASON="worktree-list-failed:$repo"
        return 0
      }
      ext="$(sed -n 's/^worktree //p' <<<"$wts" | tail -n +2 | R="$container" awk 'index($0, ENVIRON["R"] "/") != 1')"
      if [[ -n "$ext" ]]; then
        CONTAINER_REPO_REASON="has-external-worktrees:$repo"
        return 0
      fi
    fi
  done
}

# Extend C14 ephemeral retention and repo verification in this process for
# paths inside the currently verified task-scratch container so
# `artifact_removal_verdict <entry> --kind ephemeral` runs all C14 checks
# (safety_check, fd inventory, leases, live-cwd, open-file, newest-mtime,
# secrets, and retention).
CURRENT_APPROVED_SCRATCH_DIR=""
if declare -F c14_ephemeral_retention >/dev/null 2>&1; then
  eval "_orig_$(declare -f c14_ephemeral_retention)"
  c14_ephemeral_retention() {
    if _orig_c14_ephemeral_retention "$@"; then
      return 0
    fi
    local p="${1:-}" archive_origin="${3:-}"
    [[ "$archive_origin" != "--archive-origin" ]] || return 1
    if [[ -n "$CURRENT_APPROVED_SCRATCH_DIR" ]] && { [[ "$p" == "$CURRENT_APPROVED_SCRATCH_DIR" ]] || [[ "$p" == "$CURRENT_APPROVED_SCRATCH_DIR"/* ]]; }; then
      local ret_min=$(( TASK_SCRATCH_MIN_AGE_HOURS * 60 ))
      (( ret_min > 0 )) && ret_min=$(( ret_min - 1 ))
      echo "$ret_min"
      return 0
    fi
    return 1
  }
fi

if declare -F c14_repos_ok >/dev/null 2>&1; then
  eval "_orig_$(declare -f c14_repos_ok)"
  c14_repos_ok() {
    local root="${1:-}"
    if [[ -n "$CURRENT_APPROVED_SCRATCH_DIR" ]] && { [[ "$root" == "$CURRENT_APPROVED_SCRATCH_DIR" ]] || [[ "$root" == "$CURRENT_APPROVED_SCRATCH_DIR"/* ]]; }; then
      local saved_reason="$CONTAINER_REPO_REASON" saved_wts="$CONTAINER_WT_REMOVALS" res=0
      inspect_container_repos "$root"
      if [[ -n "$CONTAINER_REPO_REASON" ]]; then
        echo "kept:$CONTAINER_REPO_REASON"
        res=1
      else
        echo "ok"
        res=0
      fi
      CONTAINER_REPO_REASON="$saved_reason"
      CONTAINER_WT_REMOVALS="$saved_wts"
      return "$res"
    fi
    _orig_c14_repos_ok "$@"
  }
fi

# Resolve and deduplicate roots
IFS=':' read -r -a RAW_ROOTS <<<"$TASK_SCRATCH_ROOTS_RAW"
CANONICAL_ROOTS=()
for r in ${RAW_ROOTS[@]+"${RAW_ROOTS[@]}"}; do
  [[ -n "$r" ]] || continue
  r="${r/#\~/$HOME}"
  [[ -d "$r" && ! -L "$r" ]] || continue
  canon="$(cd "$r" 2>/dev/null && pwd -P)" || continue
  already=false
  for existing in ${CANONICAL_ROOTS[@]+"${CANONICAL_ROOTS[@]}"}; do
    if [[ "$existing" == "$canon" ]]; then
      already=true
      break
    fi
  done
  if [[ "$already" == false ]]; then
    CANONICAL_ROOTS+=("$canon")
  fi
done

if [[ "$DRY_RUN" == false && ${#CANONICAL_ROOTS[@]} -gt 0 ]]; then
  sandbox_guard_roots "${CANONICAL_ROOTS[@]}"
fi

log "$(dry_prefix)cleanup_task_scratch.sh starting (roots: ${CANONICAL_ROOTS[*]:-none}, min-age: ${TASK_SCRATCH_MIN_AGE_HOURS}h)"

CONTAINERS_REMOVED=0
CONTAINERS_KEPT=0
WORKTREES_REMOVED=0
ENTRIES_REMOVED=0
TOTAL_KB=0

for root in ${CANONICAL_ROOTS[@]+"${CANONICAL_ROOTS[@]}"}; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' dir; do
    base="$(basename "$dir")"
    [[ -n "$base" ]] || continue

    # Skip symlinks or non-directories
    if [[ -L "$dir" || ! -d "$dir" ]]; then
      continue
    fi

    # Candidate must NOT itself be a git repo or linked worktree
    if [[ -e "$dir/.git" || -L "$dir/.git" ]]; then
      continue
    fi
    if [[ -f "$dir/HEAD" && -d "$dir/objects" && -d "$dir/refs" ]]; then
      continue
    fi

    # Candidate basename must match task-scratch container patterns
    if ! matches_task_scratch_pattern "$base"; then
      continue
    fi

    # Safety Gate 1: safety_gate
    if ! safety_reason="$(safety_gate "$dir" 2>/dev/null)"; then
      log "KEEP [safety: $safety_reason] $dir"
      CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
      continue
    fi

    # Safety Gate 2: newest mtime inside $dir >= TASK_SCRATCH_MIN_AGE_HOURS
    now_epoch="$(date +%s)"
    if ! newest_epoch="$(dir_newest_mtime_epoch "$dir")" || [[ ! "$newest_epoch" =~ ^[0-9]+$ ]]; then
      log "KEEP [mtime-unmeasurable] $dir"
      CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
      continue
    fi
    if (( now_epoch - newest_epoch < TASK_SCRATCH_MIN_AGE_HOURS * 3600 )); then
      log "KEEP [recent <${TASK_SCRATCH_MIN_AGE_HOURS}h] $dir"
      CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
      continue
    fi

    # Safety Gate 3: open files (_av_open_file) and live cwd
    open_st="$(_av_open_file "$dir" 2>/dev/null || echo "kept:check-failed")"
    if [[ "$open_st" != "no" ]]; then
      log "KEEP [open-file: $open_st] $dir"
      CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
      continue
    fi
    live_cwd_st="$( (wrh_live_cwd_reason "$dir"; printf '%s' "${WRH_LIVE_CWD_REASON:-}") )"
    if [[ -n "$live_cwd_st" ]]; then
      log "KEEP [live-cwd: $live_cwd_st] $dir"
      CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
      continue
    fi

    # Safety Gate 4: secret-like files (_av_secret_like)
    if _av_secret_like "$dir"; then
      log "KEEP [secret-like] $dir"
      CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
      continue
    fi

    # Safety Gate 5: inspect child git worktrees and git clones
    inspect_container_repos "$dir"
    if [[ -n "$CONTAINER_REPO_REASON" ]]; then
      log "KEEP [$CONTAINER_REPO_REASON] $dir"
      CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
      continue
    fi

    dir_kb="$(path_size_kb "$dir")"

    if [[ "$DRY_RUN" == true ]]; then
      if [[ -n "$CONTAINER_WT_REMOVALS" ]]; then
        while IFS=$'\t' read -r _common wt; do
          [[ -n "$wt" ]] || continue
          log "DRY RUN: would remove-worktree $wt"
          WORKTREES_REMOVED=$(( WORKTREES_REMOVED + 1 ))
        done <<<"$CONTAINER_WT_REMOVALS"
      fi
      while IFS= read -r -d '' entry; do
        log "DRY RUN: would rm $entry"
        ENTRIES_REMOVED=$(( ENTRIES_REMOVED + 1 ))
      done < <(/usr/bin/find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | LC_ALL=C sort -z)
      log "DRY RUN: would rmdir $dir (${dir_kb} KB)"
      CONTAINERS_REMOVED=$(( CONTAINERS_REMOVED + 1 ))
      TOTAL_KB=$(( TOTAL_KB + dir_kb ))
      continue
    fi

    # Execute removals (--clean)
    CURRENT_APPROVED_SCRATCH_DIR="$dir"
    container_abort=false

    # 1. Remove clean, pushed linked worktrees via 'git worktree remove' (without --force)
    if [[ -n "$CONTAINER_WT_REMOVALS" ]]; then
      while IFS=$'\t' read -r common wt; do
        [[ -n "$wt" ]] || continue
        wt_kb="$(path_size_kb "$wt")"
        wt_parent="$(dirname "$wt")"
        if git --git-dir="$common" worktree remove "$wt" 2>/dev/null; then
          # Restore parent mtime so C14 age check on remaining siblings/container sees original mtime
          set_dir_mtime_epoch "$wt_parent" "$newest_epoch"
          set_dir_mtime_epoch "$dir" "$newest_epoch"
          append_manifest "removed-worktree" "$wt"
          deletion_log "cleanup_task_scratch.sh" "removed-worktree" "$wt_kb" "$wt"
          log "removed-worktree $wt (${wt_kb} KB)"
          WORKTREES_REMOVED=$(( WORKTREES_REMOVED + 1 ))
          TOTAL_KB=$(( TOTAL_KB + wt_kb ))
        else
          log "KEEP [git-worktree-remove-failed: $wt] $dir"
          container_abort=true
          break
        fi
      done <<<"$CONTAINER_WT_REMOVALS"
    fi

    if [[ "$container_abort" == true ]]; then
      CURRENT_APPROVED_SCRATCH_DIR=""
      CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
      continue
    fi

    # 2. Remove remaining scratch files/dirs inside $dir that pass artifact_removal_verdict --kind ephemeral
    while IFS= read -r -d '' entry; do
      verdict="$(artifact_removal_verdict "$entry" --kind ephemeral 2>/dev/null || echo "kept:check-failed")"
      if [[ "$verdict" != "remove" ]]; then
        log "KEEP [c14: $verdict] $entry"
        container_abort=true
        continue
      fi
      entry_kb="$(path_size_kb "$entry")"
      if [[ ! -L "$entry" && -d "$entry" ]]; then
        chmod -R u+w "$entry" 2>/dev/null || true
      elif [[ ! -L "$entry" ]]; then
        chmod u+w "$entry" 2>/dev/null || true
      fi
      if rm -rf -- "$entry" 2>/dev/null && [[ ! -e "$entry" && ! -L "$entry" ]]; then
        set_dir_mtime_epoch "$dir" "$newest_epoch"
        append_manifest "rm" "$entry"
        deletion_log "cleanup_task_scratch.sh" "rm" "$entry_kb" "$entry"
        log "rm $entry (${entry_kb} KB)"
        ENTRIES_REMOVED=$(( ENTRIES_REMOVED + 1 ))
        TOTAL_KB=$(( TOTAL_KB + entry_kb ))
      else
        log "KEEP [rm-failed: $entry] $dir"
        container_abort=true
      fi
    done < <(/usr/bin/find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | LC_ALL=C sort -z)

    # 3. Remove the emptied container directory itself
    if [[ "$container_abort" == false ]]; then
      set_dir_mtime_epoch "$dir" "$newest_epoch"
      dir_verdict="$(artifact_removal_verdict "$dir" --kind ephemeral 2>/dev/null || echo "kept:check-failed")"
      if [[ "$dir_verdict" == "remove" ]] && rmdir "$dir" 2>/dev/null; then
        append_manifest "rmdir" "$dir"
        deletion_log "cleanup_task_scratch.sh" "rmdir" "0" "$dir"
        log "rmdir $dir"
        CONTAINERS_REMOVED=$(( CONTAINERS_REMOVED + 1 ))
      else
        log "KEEP [rmdir-or-c14-kept: $dir_verdict] $dir"
        CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
      fi
    else
      CONTAINERS_KEPT=$(( CONTAINERS_KEPT + 1 ))
    fi

    CURRENT_APPROVED_SCRATCH_DIR=""
  done < <(/usr/bin/find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | LC_ALL=C sort -z)
done

log "$(dry_prefix)Done. Containers removed: ${CONTAINERS_REMOVED}  Containers kept: ${CONTAINERS_KEPT}  Worktrees removed: ${WORKTREES_REMOVED}  Entries removed: ${ENTRIES_REMOVED}  Total freed: ${TOTAL_KB} KB (~$(( TOTAL_KB / 1024 )) MB)"
