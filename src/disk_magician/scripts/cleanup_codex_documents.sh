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
#     with `wrh_remove_now --quarantine` before the rest is deleted, the latter
#     is kept. While the quarantine-capable WRH adapter is unavailable the task
#     is kept (fail closed, never the old unguarded `git worktree remove`).
# Non-git scratch is age-gated only. Empty date dirs are removed afterwards.
#
# C14 gate (spec §7.2): the task root is removed only through `quarantine_remove`,
# which owns the verified inventory and returns removed:<id>, quarantined:<id>,
# deferred:<step> or kept:<reason>. A provenance-less document is therefore kept
# even when it is old and idle. The pre-existing safety/age/live-cwd gates remain.
#
# Usage: cleanup_codex_documents.sh [--clean|--dry-run] [--deadline-at MONOTONIC] [--cursor FILE]
#   --clean        enable removal (default is DRY RUN)
#   --dry-run      explicit preview (same as the default); never activates cleanup
#   --deadline-at  cooperative soft deadline (monotonic seconds, from the shared
#                  actuator_deadline.sh helper). Before each unit the sweep asks
#                  act_unit_fits; when a unit would not finish in time it stops
#                  BEFORE that unit and records the index for the next run.
#   --cursor       resumable-enumeration checkpoint file (actuator_deadline.sh
#                  cursor format). The stored "source" binds the checkpoint to the
#                  normalized scope/order options (root, floor, kind, order); a
#                  stale or different-scope cursor fails closed and preserves
#                  content. The candidate list and next index are checkpointed
#                  after every completed unit. A completed C14 deferred:<step> is
#                  a completed visit: it is counted and the index advances (the
#                  scheduler enqueues the artifact for first review next pass). A
#                  unit that never started because the deadline expired is
#                  counted as interrupted and the index stays at it. Dry runs
#                  never advance the cursor and emit no receipt.
#
# Task 14 contract: on --clean the sweep emits one typed job receipt through the
# existing scripts/job_receipt.py schema (job cleanup_codex_documents) carrying
# candidates.removed_count / deferred_count / interrupted_count / retained_count
# and a signed postcondition.df_delta_bytes measured from df before and after the
# run. Only C14 removed:* is reclaimed bytes; quarantined:*,
# quarantine_conflict:* and kept:quarantine_partial_kept* are retained recovery
# state, reported as partial with a kept reason.
#   (default is DRY RUN)
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$SCRIPT_DIR/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$SCRIPT_DIR/lib/worktree_ignored.sh"
# shellcheck source=scripts/lib/actuator_deadline.sh
source "$SCRIPT_DIR/lib/actuator_deadline.sh"

# C14/quarantine removal gate (spec §7.2). The library is owned by the C14 /
# quarantine tasks; DISK_MAGICIAN_QUARANTINE_LIB is a test/override seam, the
# same pattern as DISK_MAGICIAN_LSOF_BIN. Sourcing is best-effort because the
# deletion site still fails closed when the functions are absent.
QUARANTINE_LIB_DEFAULT="$SCRIPT_DIR/lib/quarantine.sh"
QUARANTINE_LIB="${DISK_MAGICIAN_QUARANTINE_LIB:-$QUARANTINE_LIB_DEFAULT}"
if [[ -f "$QUARANTINE_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$QUARANTINE_LIB"
fi

# Deadline/cursor parsing is owned by the shared helper (no parallel parser).
# It fills ACT_DEADLINE_AT / ACT_CURSOR and leaves other flags in ACT_ARGS.
ACT_DEADLINE_AT=""
ACT_CURSOR=""
ACT_ARGS=()
act_parse_deadline_args "$@" || exit 2
DRY_RUN=true
for _arg in ${ACT_ARGS[@]+"${ACT_ARGS[@]}"}; do
  case "$_arg" in
    --clean) DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $_arg" >&2; exit 2 ;;
  esac
done
DEADLINE="${ACT_DEADLINE_AT:-}"
CURSOR="${ACT_CURSOR:-}"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }
dry_prefix() { if [[ "$DRY_RUN" == true ]]; then echo "DRY RUN: "; fi; }

# --- resumable enumeration + cooperative deadline (shared helper) ----------
# Candidate list and next index are checkpointed in the actuator_deadline.sh
# cursor ({"schema":1,"source":K,"items":[...],"next_index":N}); no second format.
UNIT_BUDGET="${DISK_MAGICIAN_CODEX_UNIT_BUDGET_SECONDS:-60}"
CURSOR_SOURCE=""
CANDIDATES=()
DATE_DIRS=()
NEXT_INDEX=0
DEFERRED=false

# cursor_source: normalized effective options that decide which tasks are in
# scope and their order. Any change makes an existing cursor stale (fail closed).
cursor_source() {
  printf 'cleanup_codex_documents.v1|root=%s|floor=%s|kind=%s|order=lexicographic' \
    "$ROOT" "$MIN_DAYS" "${QUARANTINE_KIND:-}"
}

enumerate_date_dirs() {
  DATE_DIRS=()
  local d
  while IFS= read -r -d '' d; do
    case "$(basename "$d")" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) DATE_DIRS+=("$d") ;;
    esac
  done < <(/usr/bin/find "$ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | LC_ALL=C sort -z)
}

enumerate_candidates() {
  CANDIDATES=()
  local dd t
  for dd in ${DATE_DIRS[@]+"${DATE_DIRS[@]}"}; do
    while IFS= read -r -d '' t; do
      CANDIDATES+=("$t")
    done < <(/usr/bin/find "$dd" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | LC_ALL=C sort -z)
  done
}

cursor_items_json() {
  python3 -c '
import json, sys
data = sys.stdin.buffer.read().split(b"\0")
items = [x.decode("utf-8") for x in data if x]
sys.stdout.write(json.dumps(items, separators=(",", ":")))
' < <(printf '%s\0' ${CANDIDATES[@]+"${CANDIDATES[@]}"})
}

# cursor_restore: 0 resumed, 1 no cursor file, 2 invalid/stale -> caller fails closed.
cursor_restore() {
  [[ -n "$CURSOR" ]] || return 1
  [[ -e "$CURSOR" ]] || return 1
  local loaded idx item c
  loaded="$(act_cursor_load "$CURSOR" "$CURSOR_SOURCE")" || return 2
  idx="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["next_index"])' "$loaded" 2>/dev/null)" || return 2
  [[ "$idx" =~ ^[0-9]+$ ]] || return 2
  CANDIDATES=()
  while IFS= read -r -d '' item; do
    CANDIDATES+=("$item")
  done < <(python3 -c 'import json,sys; sys.stdout.write("\0".join(json.loads(sys.argv[1])["items"]) + "\0")' "$loaded" 2>/dev/null)
  for c in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    case "$c" in
      "$ROOT"/*) ;;
      *) return 2 ;;   # stored candidate escaped the current scope
    esac
  done
  NEXT_INDEX="$idx"
  return 0
}

# cursor_checkpoint <next-index>: persist the frozen candidate list + index.
# Dry runs never advance a cursor (a preview must not consume real progress).
cursor_checkpoint() {
  [[ -n "$CURSOR" ]] || return 0
  [[ "$DRY_RUN" == false ]] || return 0
  local items_json
  items_json="$(cursor_items_json)" || { log "ERROR: cursor item serialization failed"; return 1; }
  act_cursor_save "$CURSOR" "$CURSOR_SOURCE" "$items_json" "$1" || { log "ERROR: cursor save failed"; return 1; }
  return 0
}

ROOT_LOGICAL="$HOME/Documents/Codex"
if [[ ! -d "$ROOT_LOGICAL" ]]; then
  log "No $ROOT_LOGICAL — nothing to do."
  exit 0
fi
ROOT="$(cd "$ROOT_LOGICAL" && pwd -P)"

MIN_DAYS="$(safety_min_stale_days)"
[[ "$MIN_DAYS" =~ ^[0-9]+$ ]] || MIN_DAYS=7
(( MIN_DAYS >= 7 )) || MIN_DAYS=7

# QUARANTINE_KIND is empty by default: codex task scratch must prove positive
# provenance. A caller that has declared its row (spec §7.2 E1-E7) may set it.
# It participates in the cursor source because it changes which removal path is
# eligible (scope), so a changed kind invalidates an existing cursor.
QUARANTINE_KIND="${DISK_MAGICIAN_CODEX_KIND:-}"

# Resolve the resumable candidate set before any deletion. A cursor whose source
# does not match the current normalized options is stale -> fail closed, content
# preserved, nothing silently advanced.
CURSOR_SOURCE="$(cursor_source)"
enumerate_date_dirs
if [[ -n "$CURSOR" ]]; then
  _crc=0; cursor_restore || _crc=$?
  case "$_crc" in
    0)
      if (( NEXT_INDEX >= ${#CANDIDATES[@]} )); then
        # A fully-consumed cursor must not starve later runs (new date dirs and
        # newly-aged tasks): re-enumerate and start a fresh pass.
        log "Cursor '$CURSOR' is complete (${NEXT_INDEX}/${#CANDIDATES[@]}); starting a fresh pass"
        enumerate_candidates
        NEXT_INDEX=0
        cursor_checkpoint 0 || exit 1
      else
        log "Resuming cursor '$CURSOR' at index ${NEXT_INDEX} of ${#CANDIDATES[@]} (source: $CURSOR_SOURCE)"
      fi
      ;;
    2)
      log "ERROR: cursor '$CURSOR' is corrupt or bound to different scope/options — failing closed, no deletions."
      exit 2
      ;;
    *)
      enumerate_candidates
      cursor_checkpoint 0 || exit 1
      log "Cursor '$CURSOR' initialized with ${#CANDIDATES[@]} candidate(s) (source: $CURSOR_SOURCE)"
      ;;
  esac
else
  enumerate_candidates
fi

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
  # Keep every absolute record. Filtering by only ROOT's physical spelling
  # drops macOS firmlink and logical-symlink aliases of the same open path.
  LIVE_PATHS="$(sed -n 's/^n\(\/.*\)$/\1/p' <<<"$out")"
  [[ -n "$LIVE_PATHS" ]] || LIVE_BLOCKED="lsof-failed"
}

path_aliases() {
  local p="$1"
  printf '%s\n' "$p"
  case "$p" in
    /System/Volumes/Data/*) printf '%s\n' "${p#/System/Volumes/Data}" ;;
    /*) printf '/System/Volumes/Data%s\n' "$p" ;;
  esac
}

path_is_live() {
  [[ -n "$LIVE_PATHS" ]] || return 1
  local task="$1" logical alias
  case "$task" in
    "$ROOT"|"$ROOT"/*) logical="$ROOT_LOGICAL${task#"$ROOT"}" ;;
    *) logical="$task" ;;
  esac
  while IFS= read -r alias; do
    if P="$alias" awk '$0 == ENVIRON["P"] || index($0, ENVIRON["P"] "/") == 1 {f=1; exit} END {exit !f}' <<<"$LIVE_PATHS"; then
      return 0
    fi
  done < <({ path_aliases "$task"; path_aliases "$logical"; } | awk '!seen[$0]++')
  return 1
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
      self="$(abs_dir "$repo")" || { REPO_REASON="worktree-path-unreadable:$repo"; return; }
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
N_DEFERRED=0
N_INTERRUPTED=0
N_RETAINED=0
keep() { log "KEEP [$1] $2"; N_KEPT=$(( N_KEPT + 1 )); }

# --- Task 14 typed actuator receipt ----------------------------------------
# Reuse the existing scripts/job_receipt.py schema; do not invent a second
# format. Counters are incremented in THIS shell (process_task is called
# directly), so removals/deferrals/interruptions are never lost to a
# command-substitution subshell. Emitted only for a real (--clean) run: a dry
# run must not consume receipt history.
RECEIPT_HELPER="${DISK_MAGICIAN_RECEIPT_HELPER:-$SCRIPT_DIR/job_receipt.py}"
RECEIPT_JOB="cleanup_codex_documents"
RECEIPT_RUN_ID=""
FREE_BEFORE=""
free_bytes() { df -kP "$ROOT" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%.0f\n", $4*1024}'; }
receipt_begin() {
  [[ "$DRY_RUN" == false ]] || return 0
  [[ -f "$RECEIPT_HELPER" ]] || { log "ERROR: receipt helper missing: $RECEIPT_HELPER"; return 1; }
  FREE_BEFORE="$(free_bytes)"
  RECEIPT_RUN_ID="$(python3 "$RECEIPT_HELPER" begin --job "$RECEIPT_JOB" --trigger clean)" || return 1
  return 0
}
# receipt_finish [forced-outcome] [forced-reason]
receipt_finish() {
  [[ -n "$RECEIPT_RUN_ID" ]] || return 0
  local forced_outcome="${1:-}" forced_reason="${2:-}" after outcome reason candidates post
  after="$(free_bytes)"
  if [[ -n "$forced_outcome" ]]; then
    outcome="$forced_outcome"
  elif (( N_INTERRUPTED > 0 )); then
    outcome=partial
    (( N_REMOVED > 0 || N_DEFERRED > 0 || N_RETAINED > 0 )) || outcome=timeout
  elif (( N_RETAINED > 0 )); then
    # A quarantined/conflicted tree is retained recovery state, not reclaimed;
    # the run must never terminate as a clean removal success.
    outcome=partial
  elif (( N_REMOVED > 0 )); then
    outcome=success
  elif (( N_DEFERRED > 0 )); then
    outcome=partial
  else
    outcome=success_noop
  fi
  reason="${forced_reason:-removed=$N_REMOVED deferred=$N_DEFERRED interrupted=$N_INTERRUPTED retained=$N_RETAINED kept=$N_KEPT}"
  candidates="$(python3 - "$N_REMOVED" "$N_DEFERRED" "$N_INTERRUPTED" "$N_RETAINED" "$N_KEPT" <<'PY'
import json, sys
removed, deferred, interrupted, retained, kept = map(int, sys.argv[1:])
print(json.dumps({"removed_count": removed, "deferred_count": deferred,
                  "interrupted_count": interrupted, "retained_count": retained,
                  "kept_count": kept}))
PY
)"
  post="$(python3 - "$FREE_BEFORE" "$after" <<'PY'
import json, sys
before, after = sys.argv[1:]
before = int(before) if before.isdigit() else None
after = int(after) if after.isdigit() else None
delta = (after - before) if (before is not None and after is not None) else None
print(json.dumps({"freed_bytes": max(0, delta) if delta is not None else None,
                  "df_delta_bytes": delta,
                  "free_bytes_before": before, "free_bytes_after": after}))
PY
)"
  if ! python3 "$RECEIPT_HELPER" finish --job "$RECEIPT_JOB" \
      --run-id "$RECEIPT_RUN_ID" --outcome "$outcome" --reason "$reason" \
      --candidates "$candidates" --postcondition "$post"; then
    log "ERROR: failed to record receipt finish"
    return 1
  fi
  RECEIPT_RUN_ID=""
  return 0
}

# quarantine_remove_available: the C14/quarantine gate is the only root-removal path.
quarantine_remove_available() { declare -F quarantine_remove >/dev/null 2>&1; }
# wrh_quarantine_available: the WRH adapter must advertise quarantine mode
# (`wrh_remove_now <real> <display> --quarantine`). Until the committed adapter
# lands, no wrh_remove_now accepts it, so linked worktrees fail closed instead of
# falling back to the old unguarded `git worktree remove`.
# TODO(final WRH, parent-owned): the adapter will expose a direct capability API;
# this transitional body probe must be replaced by that API, never treated as the
# final capability contract.
wrh_quarantine_available() {
  declare -F wrh_remove_now >/dev/null 2>&1 || return 1
  declare -f wrh_remove_now | grep -q -- '--quarantine'
}
# quarantine_gate <task>: route one artifact through C14/quarantine and print
# its verdict token. The caller interprets removed:/quarantined:/kept:/deferred:.
quarantine_gate() {
  local task="$1"
  local -a args=()
  [[ -n "$QUARANTINE_KIND" ]] && args+=(--kind "$QUARANTINE_KIND")
  [[ -n "$DEADLINE" ]] && args+=(--deadline-at "$DEADLINE")
  quarantine_remove "$task" ${args[@]+"${args[@]}"} 2>/dev/null || echo "kept:check-failed"
}
process_task() {
  local task="$1" rc reason kb main wt removed_worktrees=0 qout wrh_out wrh_rc
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
    rc=0; worktree_is_recently_active "$task" "$MIN_DAYS" || rc=$?
    if (( rc != 1 )); then keep "recent-recheck" "$task"; return; fi
    check_repos "$task"
    if [[ -n "$REPO_REASON" ]]; then keep "recheck:$REPO_REASON" "$task"; return; fi
    # Linked worktrees are removed by the WRH quarantine adapter before the
    # task root is quarantined; without that adapter the task stays (fail closed).
    if [[ -n "$WT_REMOVALS" ]]; then
      if ! wrh_quarantine_available; then
        keep "wrh-quarantine-unavailable" "$task"; return
      fi
      while IFS=$'\t' read -r main wt; do
        [[ -n "$main" ]] || continue
        # Current WRH contract: rc 0 only when the worktree was actually
        # removed; a quarantined-but-retained (or partial) worktree returns
        # non-zero. Capture stdout so a future contract that reports a
        # quarantined:<id>/quarantine_conflict:<id> verdict on success is never
        # counted as removed: only a real removal increments removed_worktrees.
        wrh_rc=0
        wrh_out="$(wrh_remove_now "$wt" "$wt" --quarantine 2>/dev/null)" || wrh_rc=$?
        if (( wrh_rc != 0 )); then
          if (( removed_worktrees > 0 )); then
            deletion_log cleanup_codex_documents.sh partial "$kb" "$task"
          fi
          keep "wrh-quarantine-failed:$wt" "$task"; return
        fi
        case "$wrh_out" in
          quarantined:*|quarantine_conflict:*|quarantine_partial_kept*)
            N_RETAINED=$(( N_RETAINED + 1 ))
            deletion_log cleanup_codex_documents.sh partial "$kb" "$task"
            keep "wrh-retained:${wrh_out%%:*}:$wt" "$task"; return
            ;;
        esac
        removed_worktrees=$(( removed_worktrees + 1 ))
      done <<<"$WT_REMOVALS"
    fi
    if ! quarantine_remove_available; then
      keep "quarantine-unavailable" "$task"; return
    fi
    log "Removing $task (${kb} KB) via C14/quarantine"
    qout="$(quarantine_gate "$task")"
    case "$qout" in
      removed:*)
        # Only a completed C14 removal is reclaimed bytes. Include this target
        # in REMOVED/TOTAL_KB/N_REMOVED below.
        deletion_log cleanup_codex_documents.sh removed "$kb" "$task"
        ;;
      quarantined:*)
        # Phase 1 moved the tree into quarantine but phase 2 did not delete it:
        # retained, recoverable recovery state, never counted as removed.
        N_RETAINED=$(( N_RETAINED + 1 ))
        deletion_log cleanup_codex_documents.sh partial "$kb" "$task"
        keep "quarantined:${qout#quarantined:}" "$task"; return
        ;;
      quarantine_conflict:*)
        # Original path recreated / exclusive rename unavailable: the tree is
        # retained (possibly in quarantine) and must not count as removed.
        N_RETAINED=$(( N_RETAINED + 1 ))
        deletion_log cleanup_codex_documents.sh partial "$kb" "$task"
        keep "quarantine-conflict:${qout#quarantine_conflict:}" "$task"; return
        ;;
      deferred:*)
        # C14 deferral is a COMPLETED visit (Task 14 contract): count it and let
        # the cursor advance. The scheduler enqueues the artifact for first
        # review next pass via govern_sched.json; it is not an interruption.
        DEFERRED=true
        N_DEFERRED=$(( N_DEFERRED + 1 ))
        deletion_log cleanup_codex_documents.sh partial "$kb" "$task"
        keep "deferred:${qout#deferred:}" "$task"; return
        ;;
      kept:quarantine_partial_kept*)
        # Real phase-2 partial: the tree was moved into quarantine but the
        # deletion walk did not complete (content changed under the walk, an
        # unlink failed, etc.). The bytes remain recoverable quarantine state,
        # so this is retained, never reclaimed, and the run must end `partial`
        # rather than falling through to the generic kept:*/success_noop path.
        # A deferred:* result is matched above and is never collapsed here.
        N_RETAINED=$(( N_RETAINED + 1 ))
        deletion_log cleanup_codex_documents.sh partial "$kb" "$task"
        keep "quarantine-partial-kept${qout#kept:quarantine_partial_kept}" "$task"; return
        ;;
      kept:*)
        keep "${qout#kept:}" "$task"; return
        ;;
      *)
        keep "quarantine-unexpected:$qout" "$task"; return
        ;;
    esac
  fi
  REMOVED="${REMOVED}${task}"$'\n'
  TOTAL_KB=$(( TOTAL_KB + kb ))
  N_REMOVED=$(( N_REMOVED + 1 ))
}

log "$(dry_prefix)cleanup_codex_documents.sh starting (root: $ROOT, floor: ${MIN_DAYS}d)"
snapshot_live_paths

if ! receipt_begin; then
  log "ERROR: failed to record receipt begin — failing closed"
  exit 1
fi

# Process the frozen candidate list from the resumed index. The unit budget is
# only an estimate of one unit; the deadline is cooperative, so a unit that has
# started may still overrun it — the next unit is what gets deferred.
_i="$NEXT_INDEX"
while (( _i < ${#CANDIDATES[@]} )); do
  task="${CANDIDATES[$_i]}"
  if [[ -n "$DEADLINE" ]]; then
    _frc=0; act_unit_fits "$UNIT_BUDGET" || _frc=$?
    if (( _frc == 1 )); then
      # Not started: not a completed visit, so keep the cursor at this unit.
      N_INTERRUPTED=$(( N_INTERRUPTED + 1 ))
      log "deadline reached before unit index ${_i}: $task — not started (interrupted)"
      break
    elif (( _frc != 0 )); then
      log "ERROR: invalid unit budget '$UNIT_BUDGET' — failing closed"
      receipt_finish error "invalid unit budget" || true
      exit 2
    fi
  fi
  DEFERRED=false
  process_task "$task"
  if [[ "$DEFERRED" == true ]]; then
    log "unit index ${_i} deferred — counted, advancing to the next unit"
  fi
  _i=$(( _i + 1 ))
  if ! cursor_checkpoint "$_i"; then
    log "cursor checkpoint failed — stopping before losing progress"
    break
  fi
done

# Date dirs left with nothing but already-removed tasks (and .DS_Store).
# The date dir is itself a removal target: route its teardown through the SAME
# C14/quarantine gate (same target variable). An unproven .DS_Store or other
# metadata keeps the dir; there is no direct rm/rmdir bypass.
for dd in ${DATE_DIRS[@]+"${DATE_DIRS[@]}"}; do
  left=0
  while IFS= read -r -d '' e; do
    [[ "$(basename "$e")" == .DS_Store ]] && continue
    grep -qxF "$e" <<<"$REMOVED" || left=1
  done < <(/usr/bin/find "$dd" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  if (( left == 0 )); then
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY RUN: would verify and remove emptied date dir $dd"
      continue
    fi
    if ! quarantine_remove_available; then
      log "kept:quarantine-unavailable $dd"
      continue
    fi
    dd_qout="$(quarantine_gate "$dd")"
    case "$dd_qout" in
      removed:*) log "Removed emptied date dir $dd" ;;
      *) log "date-dir retained ($dd_qout): $dd" ;;
    esac
  fi
done

receipt_finish || true
log "$(dry_prefix)Done. Task dirs removed: ${N_REMOVED}  kept: ${N_KEPT}  total: ${TOTAL_KB} KB (~$(( TOTAL_KB / 1024 )) MB)"
