#!/usr/bin/env bash
# cleanup_codex_documents.sh — safety-gated cleanup of Codex-app task scratch
# under ~/Documents/Codex/<YYYY-MM-DD>/<task-dir> (bead disk_magician-nlq5;
# 8.7 GiB of nested clones, worktrees, advice results and repro bundles).
#
# A task dir is removed only when ALL hold; every unknown keeps it (fail closed):
#   - not a symlink, and not matched by safety.local.json (safety_gate)
#   - newest content older than the 7-day floor (worktree_is_recently_active)
#   - no live process cwd/open file inside (machine-wide lsof snapshot)
#   - every nested git repo/worktree is clean, has no ignored secrets or
#     non-rebuildable ignored data, and has no commit missing from a
#     remote-tracking ref (standalone repos: also no local-only branch/stash)
#   - a linked worktree whose main repo lives outside the task, or any repo
#     with worktrees outside the task, is handled safely: the former is removed
#     with `git worktree remove` before the rest is deleted, the latter is kept.
# Non-git scratch is age-gated only. Empty date dirs are removed afterwards.
#
# Usage: cleanup_codex_documents.sh [--clean]   (default is DRY RUN)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$SCRIPT_DIR/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$SCRIPT_DIR/lib/worktree_ignored.sh"

DRY_RUN=true
for arg in "$@"; do
  case "$arg" in
    --clean) DRY_RUN=false ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
dry_prefix() { if [[ "$DRY_RUN" == true ]]; then echo "DRY RUN: "; fi; }

ROOT="$HOME/Documents/Codex"
if [[ ! -d "$ROOT" ]]; then
  log "No $ROOT — nothing to do."
  exit 0
fi
ROOT="$(cd "$ROOT" && pwd -P)"

MIN_DAYS="$(safety_min_stale_days)"
[[ "$MIN_DAYS" =~ ^[0-9]+$ ]] || MIN_DAYS=7
(( MIN_DAYS >= 7 )) || MIN_DAYS=7

if [[ "$DRY_RUN" == false ]]; then
  sandbox_guard_roots "$ROOT"
fi

# Machine-wide open-path snapshot (cwd + open files). Unknown => block all.
LIVE_PATHS=""
LIVE_BLOCKED=""
snapshot_live_paths() {
  local lsof_bin out rc=0 t=""
  if [[ -n "${DISK_MAGICIAN_LSOF_BIN:-}" ]]; then lsof_bin="$DISK_MAGICIAN_LSOF_BIN"
  elif [[ -x /usr/sbin/lsof ]]; then lsof_bin=/usr/sbin/lsof
  else lsof_bin="$(command -v lsof 2>/dev/null || true)"; fi
  if [[ -z "$lsof_bin" || ! -x "$lsof_bin" ]]; then LIVE_BLOCKED="lsof-unavailable"; return; fi
  command -v timeout >/dev/null 2>&1 && t="timeout 180s"
  # shellcheck disable=SC2086
  out="$($t "$lsof_bin" -n -P -Fn 2>/dev/null)" || rc=$?
  # rc 1 with output is lsof's normal "some items unreadable"; anything else is unknown.
  if (( rc > 1 )) || [[ -z "$out" ]]; then LIVE_BLOCKED="lsof-failed"; return; fi
  LIVE_PATHS="$(sed -n 's/^n\(\/.*\)$/\1/p' <<<"$out" | R="$ROOT" awk 'index($0, ENVIRON["R"] "/") == 1')"
}

path_is_live() {
  [[ -n "$LIVE_PATHS" ]] || return 1
  P="$1" awk '$0 == ENVIRON["P"] || index($0, ENVIRON["P"] "/") == 1 {f=1; exit} END {exit !f}' <<<"$LIVE_PATHS"
}

abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
# git_dir_of <repo> <rev-parse flag>: physical path of a repo's (common) git dir.
git_dir_of() { (cd "$1" 2>/dev/null && cd "$(git rev-parse "$2" 2>/dev/null)" 2>/dev/null && pwd -P); }

# eligible_remote_args <repo> <task>: prints one `--remotes=<name>` per remote
# whose URL does not resolve to a local path under $ROOT. A remote living inside
# the Codex scratch tree dies with it, so pushes to it are not backups. A local
# path that cannot be resolved is ineligible (fail closed).
eligible_remote_args() {
  local repo="$1" name url p
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
      p="$(cd "$repo" 2>/dev/null && cd "$p" 2>/dev/null && pwd -P)" || { ok=false; break; }
      case "$p" in "$ROOT"|"$ROOT"/*) ok=false; break ;; esac
    done < <(git -C "$repo" remote get-url --all "$name" 2>/dev/null || echo "?unreadable")
    if [[ "$ok" == true ]]; then echo "--remotes=$name"; fi
  done < <(git -C "$repo" remote 2>/dev/null)
}

# find_bare_repo <task>: prints the first bare/separate git dir (HEAD + refs/ +
# objects/ outside any .git) so the task is kept; rc 1 when none.
find_bare_repo() {
  local task_for_bare="$1" o p
  while IFS= read -r -d '' o; do
    p="$(dirname "$o")"
    case "$p/" in */.git/*) continue ;; esac
    if [[ -f "$p/HEAD" && -d "$p/refs" ]]; then echo "$p"; return 0; fi
  done < <(/usr/bin/find "$task_for_bare" -type d -name objects -print0 2>/dev/null)
  return 1
}

# check_repos <task>: sets REPO_REASON (empty = all nested repos safe) and
# WT_REMOVALS ("main<TAB>worktree" lines to `git worktree remove` first).
REPO_REASON=""
WT_REMOVALS=""
check_repos() {
  local task="$1" g repo gd common wts self blk line gl
  REPO_REASON=""; WT_REMOVALS=""
  local bare
  if bare="$(find_bare_repo "$task")"; then REPO_REASON="bare-repo:$bare"; return; fi
  local gits=() gl
  gl="$(mktemp -t dm-codexdocs.XXXXXX)" || { REPO_REASON="mktemp-failed"; return; }
  /usr/bin/find "$task" -name .git -prune -print0 >"$gl" 2>/dev/null || { rm -f "$gl"; REPO_REASON="find-failed"; return; }
  while IFS= read -r -d '' g; do gits+=("$g"); done <"$gl"
  rm -f "$gl"
  for g in ${gits[@]+"${gits[@]}"}; do
    repo="$(dirname "$g")"
    git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { REPO_REASON="git-unreadable:$repo"; return; }
    local st
    st="$(git -C "$repo" status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)" \
      || { REPO_REASON="git-status-failed:$repo"; return; }
    [[ -z "$st" ]] || { REPO_REASON="dirty:$repo"; return; }
    if has_hidden_state "$repo"; then REPO_REASON="hidden-state:$repo"; return; fi
    if has_ignored_user_data "$repo"; then REPO_REASON="ignored-user-data:$repo"; return; fi
    local unpushed rargs=()
    while IFS= read -r line; do rargs+=("$line"); done < <(eligible_remote_args "$repo")
    unpushed="$(git -C "$repo" rev-list -n1 HEAD --not ${rargs[@]+"${rargs[@]}"} 2>/dev/null)" \
      || { REPO_REASON="head-unreadable:$repo"; return; }
    [[ -z "$unpushed" ]] || { REPO_REASON="unpushed-head:$repo"; return; }
    gd="$(git_dir_of "$repo" --git-dir)" || { REPO_REASON="git-dir-unreadable:$repo"; return; }
    common="$(git_dir_of "$repo" --git-common-dir)" || { REPO_REASON="git-dir-unreadable:$repo"; return; }
    if [[ "$gd" != "$common" ]]; then
      # Linked worktree. Main repo inside the task dies with it; outside, unregister it.
      case "$common" in
        "$task"/*) continue ;;
      esac
      wts="$(git --git-dir="$common" worktree list --porcelain 2>/dev/null)" || { REPO_REASON="worktree-list-failed:$repo"; return; }
      self="$(abs_dir "$repo")"
      blk="$(awk -v p="$self" 'BEGIN{RS="";FS="\n"} {for(i=1;i<=NF;i++) if($i=="worktree " p){print; exit}}' <<<"$wts")"
      [[ -n "$blk" ]] || { REPO_REASON="worktree-unregistered:$repo"; return; }
      if grep -q '^locked' <<<"$blk"; then REPO_REASON="worktree-locked:$repo"; return; fi
      [[ -w "$common/worktrees" ]] || { REPO_REASON="worktree-admin-unwritable:$repo"; return; }
      WT_REMOVALS="${WT_REMOVALS}${common}"$'\t'"$self"$'\n'
    else
      # Standalone repo (deleted whole): no local-only branch, stash, or outside worktree.
      local lb ext
      lb="$(git -C "$repo" rev-list -n1 --all --not ${rargs[@]+"${rargs[@]}"} 2>/dev/null)" \
        || { REPO_REASON="refs-unreadable:$repo"; return; }
      [[ -z "$lb" ]] || { REPO_REASON="unpushed-refs:$repo"; return; }
      if [[ -d "$g" ]]; then
        wts="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || { REPO_REASON="worktree-list-failed:$repo"; return; }
        ext="$(sed -n 's/^worktree //p' <<<"$wts" | tail -n +2 | R="$task" awk 'index($0, ENVIRON["R"] "/") != 1')"
        [[ -z "$ext" ]] || { REPO_REASON="has-external-worktrees:$repo"; return; }
      fi
    fi
  done
}

REMOVED=""
TOTAL_KB=0
N_REMOVED=0
N_KEPT=0
keep() { log "KEEP [$1] $2"; N_KEPT=$(( N_KEPT + 1 )); }

process_task() {
  local task="$1" rc reason kb row main wt
  if [[ -L "$task" ]]; then keep symlink "$task"; return; fi
  reason="$(safety_gate "$task")" && rc=0 || rc=$?
  if (( rc != 0 )); then keep "safety: $reason" "$task"; return; fi
  rc=0; worktree_is_recently_active "$task" "$MIN_DAYS" || rc=$?
  if (( rc != 1 )); then keep "recent-or-unmeasurable(<${MIN_DAYS}d)" "$task"; return; fi
  if [[ -n "$LIVE_BLOCKED" ]]; then keep "$LIVE_BLOCKED" "$task"; return; fi
  if path_is_live "$task"; then keep live-process "$task"; return; fi
  check_repos "$task"
  if [[ -n "$REPO_REASON" ]]; then keep "$REPO_REASON" "$task"; return; fi
  kb="$(du -sk "$task" 2>/dev/null | cut -f1)" || kb=0
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would remove $task (${kb} KB, age $(worktree_age_days "$task")d)"
  else
    snapshot_live_paths
    if [[ -n "$LIVE_BLOCKED" ]]; then keep "$LIVE_BLOCKED" "$task"; return; fi
    if path_is_live "$task"; then keep live-process-recheck "$task"; return; fi
    while IFS=$'\t' read -r main wt; do
      [[ -n "$main" ]] || continue
      if ! git --git-dir="$main" worktree remove --force "$wt" 2>/dev/null; then
        keep "worktree-remove-failed:$wt" "$task"; return
      fi
    done <<<"$WT_REMOVALS"
    log "Removing $task (${kb} KB)"
    rm -rf "$task"
    if [[ -e "$task" ]]; then keep "rm-incomplete" "$task"; return; fi
    deletion_log cleanup_codex_documents.sh removed "$kb" "$task"
  fi
  REMOVED="${REMOVED}${task}"$'\n'
  TOTAL_KB=$(( TOTAL_KB + kb ))
  N_REMOVED=$(( N_REMOVED + 1 ))
}

log "$(dry_prefix)cleanup_codex_documents.sh starting (root: $ROOT, floor: ${MIN_DAYS}d)"
snapshot_live_paths

DATE_DIRS=()
while IFS= read -r -d '' d; do
  case "$(basename "$d")" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) DATE_DIRS+=("$d") ;;
  esac
done < <(/usr/bin/find "$ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null) \
  || { log "Listing $ROOT failed — fail-closed, aborting without deletions."; exit 1; }

for dd in ${DATE_DIRS[@]+"${DATE_DIRS[@]}"}; do
  while IFS= read -r -d '' task; do
    process_task "$task"
  done < <(/usr/bin/find "$dd" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
done

# Date dirs left with nothing but already-removed tasks (and .DS_Store).
for dd in ${DATE_DIRS[@]+"${DATE_DIRS[@]}"}; do
  left=0
  while IFS= read -r -d '' e; do
    [[ "$(basename "$e")" == .DS_Store ]] && continue
    grep -qxF "$e" <<<"$REMOVED" || left=1
  done < <(/usr/bin/find "$dd" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  if (( left == 0 )); then
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY RUN: would remove emptied date dir $dd"
    else
      rm -f "$dd/.DS_Store"
      rmdir "$dd" 2>/dev/null && log "Removed emptied date dir $dd"
    fi
  fi
done

log "$(dry_prefix)Done. Task dirs removed: ${N_REMOVED}  kept: ${N_KEPT}  total: ${TOTAL_KB} KB (~$(( TOTAL_KB / 1024 )) MB)"
