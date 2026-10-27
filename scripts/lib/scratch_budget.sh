# shellcheck shell=bash
# scratch_budget.sh — size-budget eviction engine for agent/PR scratch roots.
#
# Bead disk_magician-d45 (age-only sweepers never touch 0-24h scratch, which
# is where ~15 GiB/day of growth lives) + dcz (reviewed lsof-recheck
# requirement). When a scratch root's matched candidates exceed a size
# budget, evict the oldest ones (by real content mtime, never a directory-
# mtime proxy — see scripts/lib/worktree_recency.sh's header for why that
# proxy is banned in this repo) until back under budget.
#
# Public entry point:
#   scratch_budget_evict_root <root> <budget_kb> <floor_minutes>
#
# NEVER evicts:
#   - anything with content mtime newer than <floor_minutes> (hard floor;
#     clamped to a 60-minute minimum below regardless of caller input)
#   - anything with an open file handle: has_open_files() is rechecked
#     immediately before every single deletion (bead dcz), independent of
#     the upfront lsof snapshot used only to speed up enumeration
#   - anything is_protected_root() / is_protected_tmp_path() reports true for
#   - a repository/worktree, including one nested inside a scratch container
#   - anything safety_gate() (safety_lib.sh: never_delete /
#     protected_live_paths / needs_decision, or an unreadable safety file)
#     refuses, checked immediately before every deletion
#
# CALLER CONTRACT (duck-typed — cleanup_tmp.sh and cleanup_pr_scratch.sh
# both already define these with matching semantics, so no adapter shim is
# needed to source this file from either):
#   log <msg>                     caller-provided logger
#   path_size_kb <path>           caller-provided `du -sk` wrapper
#   is_protected_root <basename>  rc0 = top-level basename is protected
#   is_protected_tmp_path <path>  rc0 = path form is protected
#   has_open_files <path>         rc0 = has an open handle (fails closed)
#   DRY_RUN                       "true" or "false"
# Sourced directly (not duck-typed): safety_gate (safety_lib.sh).
# Repository containers are preserved for the canonical worktree cleanup.
# Actual artifact removal is delegated to C14 quarantine; callers may set
# ACT_DEADLINE_AT after parsing the shared actuator deadline flags.
_SCRATCH_BUDGET_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SCRATCH_BUDGET_LIB/quarantine.sh"
# Cursor discipline (Cursor review 5/6): this is the ONE place a cleanup
# candidate advances the shared resume cursor. The cursor is validated with the
# shared act_cursor_load/act_cursor_save helpers (never a private JSON
# reader/writer) and follows the same ordered-list contract as
# cleanup_worktrees.sh's act_candidate_begin/act_candidate_done:
#   - the caller resets a fully-consumed cursor ONCE per invocation
#     (act_cursor_reset_once), never per artifact;
#   - a candidate already behind the resume point is skipped as
#     complete:cursor-complete; a candidate ahead of it advances the point
#     past the units in between, so an interrupted unit never stalls the rest;
#   - every FINISHED visit (removed, any kept verdict, and a completed C14
#     deferral) advances the cursor;
#   - an interruption (deadline-before-unit) never advances, so the next
#     invocation retries the same unit;
#   - an invalid/stale scope fails closed (no candidate is processed).
scratch_budget_quarantine_remove() {
  local cursor_step="" cursor_index=0 cursor_item_index=0 cursor_items="[]" cursor_visit_complete=false result
  if [[ -n "${ACT_CURSOR:-}" && -n "${ACT_CURSOR_SOURCE:-}" ]]; then
    local _cursor_state _cursor_plan _cursor_rest
    _cursor_state="$(act_cursor_load "$ACT_CURSOR" "$ACT_CURSOR_SOURCE")" || { echo 'kept:cursor-invalid'; return 0; }
    _cursor_plan="$(printf '%s' "$_cursor_state" | python3 -c '
import json, os, sys
state, item = json.load(sys.stdin), sys.argv[1]
items = list(state["items"])
i = state["next_index"]
# Skip candidates that vanished since the cursor was written.
while i < len(items) and not os.path.lexists(items[i]):
    i += 1
try:
    idx = items.index(item)
except ValueError:
    items.append(item)
    idx = len(items) - 1
# Behind the resume point: already visited in this pass.
if idx < i:
    print("complete"); raise SystemExit
# At or ahead of the resume point. Emit the unit own index separately and
# leave next_index where it is: the resume point moves only when the visit
# FINISHES, so an interrupted unit (idx > i) keeps the cursor on the earlier
# unfinished unit instead of being stepped over.
print("ready\t" + str(i) + "\t" + str(idx) + "\t" + json.dumps(items, separators=(",", ":")))
' "$1")" || { echo 'kept:cursor-invalid'; return 0; }
    case "$_cursor_plan" in
      complete) echo 'kept:cursor-complete'; return 0 ;;
      invalid) echo 'kept:cursor-invalid'; return 0 ;;
      ready$'\t'*)
        _cursor_rest="${_cursor_plan#*$'\t'}"
        cursor_index="${_cursor_rest%%$'\t'*}"
        _cursor_rest="${_cursor_rest#*$'\t'}"
        cursor_item_index="${_cursor_rest%%$'\t'*}"
        cursor_items="${_cursor_rest#*$'\t'}"
        cursor_step="ready" ;;
      *) echo 'kept:cursor-invalid'; return 0 ;;
    esac
    # Persist the appended candidate BEFORE any destructive work, so a kill
    # mid-unit resumes the same unit next run. next_index stays at the
    # resume point (not the candidate's own index).
    act_cursor_save "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" "$cursor_items" "$cursor_index" || { echo 'kept:cursor-save-failed'; return 0; }
  fi
  if [[ -n "${ACT_DEADLINE_AT:-}" ]]; then
    local fit_rc=0 unit_budget=20
    if [[ -d "$1/.git" || -f "$1/.git" ]]; then unit_budget=60; fi
    act_unit_fits "$unit_budget" || fit_rc=$?
    case "$fit_rc" in
      1) [[ "${CANDIDATE_INTERRUPTED_COUNT+x}" == x ]] && CANDIDATE_INTERRUPTED_COUNT=$((CANDIDATE_INTERRUPTED_COUNT + 1)); echo 'deferred:deadline-before-unit'; return 0 ;;
      2) [[ "${CANDIDATE_INTERRUPTED_COUNT+x}" == x ]] && CANDIDATE_INTERRUPTED_COUNT=$((CANDIDATE_INTERRUPTED_COUNT + 1)); echo 'kept:invalid-deadline'; return 0 ;;
    esac
  fi
  local args=(--kind ephemeral)
  [[ -n "${ACT_DEADLINE_AT:-}" ]] && args+=(--deadline-at "$ACT_DEADLINE_AT")
  result="$(quarantine_remove "$1" "${args[@]}")" || result=kept:check-failed
  if [[ "${CANDIDATE_REMOVED_COUNT+x}" == x ]]; then
    case "$result" in
      removed:*) CANDIDATE_REMOVED_COUNT=$((CANDIDATE_REMOVED_COUNT + 1)) ;;
      deferred:deadline-before-unit) CANDIDATE_INTERRUPTED_COUNT=$((CANDIDATE_INTERRUPTED_COUNT + 1)) ;;
      deferred:*) CANDIDATE_DEFERRED_COUNT=$((CANDIDATE_DEFERRED_COUNT + 1)) ;;
    esac
  fi
  # A finished visit advances; only an interruption (or a preflight config
  # failure) leaves the cursor on the unit so the next invocation retries it.
  if [[ "$result" == kept:intent-write-failed && -n "${DISK_MAGICIAN_C14_DIAGNOSTIC_OUT:-}" ]] && \
    python3 - "${DISK_MAGICIAN_C14_DIAGNOSTIC_OUT}" <<'PYDIAG' >/dev/null 2>&1
import json,sys
try:
    with open(sys.argv[1], encoding="utf-8") as f: value=json.load(f)
except (OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if value == {"operation":"intent_write","errno":28,"errno_name":"ENOSPC"} else 1)
PYDIAG
  then
    # volume_reclaim may perform one typed ENOSPC ballast-release retry for
    # this exact item. Keep the cursor on it until that retry's final result.
    cursor_visit_complete=false
  else
    case "$result" in
      deferred:deadline-before-unit|kept:invalid-deadline|kept:cursor-*)
        cursor_visit_complete=false ;;
      *) cursor_visit_complete=true ;;
    esac
  fi
  if [[ -n "${ACT_CURSOR:-}" && "$cursor_step" == ready && "$cursor_visit_complete" == true ]]; then
    act_cursor_save "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" "$cursor_items" "$((cursor_item_index + 1))" || { echo 'kept:cursor-save-failed'; return 0; }
  fi
  echo "$result"
  return 0
}
#
# Caller must declare (and reset per invocation) these globals; this file
# accumulates into them rather than returning a value, matching the
# TOTAL_KB/DIRS_DELETED/FILES_DELETED convention already used by both
# sweepers:
#   BUDGET_DIRS_DELETED / BUDGET_FILES_DELETED / BUDGET_KB_FREED

# PERFORMANCE (bead dcz): calling has_open_files() — a full `lsof +D <dir>`
# subprocess — once per enumerated candidate is what made a dry-run over the
# real TMPDIR take ~8 minutes. A single `lsof -n -P -F n` snapshot of the
# whole open-file table (~2.8s measured) is taken once up front and used ONLY
# to skip obviously-open candidates cheaply during enumeration/scoring. It is
# NEVER the basis for an actual deletion: every deletion re-runs the real
# has_open_files() immediately beforehand (below), so a file opened in the
# seconds between snapshot and eviction is still protected, and a snapshot
# that fails to build degrades to "no prefilter" rather than to "assume
# nothing is open".
_scratch_budget_lsof_snapshot() {
  local lsof_bin
  if [[ -n "${DISK_MAGICIAN_LSOF_BIN:-}" ]]; then
    lsof_bin="$DISK_MAGICIAN_LSOF_BIN"
  elif [[ -x /usr/sbin/lsof ]]; then
    lsof_bin=/usr/sbin/lsof
  elif lsof_bin=$(command -v lsof 2>/dev/null); then
    :
  else
    return 1
  fi
  local tbin=""
  declare -F resolve_timeout_bin >/dev/null && tbin="$(resolve_timeout_bin "${DISK_MAGICIAN_PROBE_TIMEOUT_BIN:-}")"
  if [[ -n "$tbin" ]]; then
    # Bounded: a timeout is a failed snapshot -> caller proceeds without prefilter.
    { "$tbin" --kill-after=2s "${PROBE_TIMEOUT_SEC:-30}s" "$lsof_bin" -n -P -F n 2>/dev/null || return 1; } | sed -n 's/^n//p'
    return "${PIPESTATUS[0]}"
  fi
  "$lsof_bin" -n -P -F n 2>/dev/null | sed -n 's/^n//p'
}

# _scratch_budget_snapshot_has_prefix <snapshot_file> <path> — enumeration-
# time-only prefilter; see the performance note above for why this is never
# authoritative on its own.
_scratch_budget_snapshot_has_prefix() {
  local snapshot_file="$1" path="$2"
  [[ -s "$snapshot_file" ]] || return 1
  grep -Fq "$path" "$snapshot_file" 2>/dev/null
}

# scratch_budget_content_mtime <path> — newest content mtime under <path> in
# epoch seconds, or EMPTY STRING if it cannot be determined (stat/find
# failure, unreadable subtree). Uses the same batched `find -exec stat +`
# approach as worktree_last_activity_epoch: one process fan-out, not one
# `stat` per file.
#
# CONTRACT (bead disk_magician-lsl follow-up / PR #71 /advice request-changes,
# Opus): this used to fall back to the string "0" (epoch 1970) on failure,
# which sorts FIRST for oldest-first eviction -- the opposite of this repo's
# "cannot measure -> preserve" rule (worktree_recency.sh, safety_gate). "0" is
# also ambiguous with a legitimate epoch-0 file. Callers MUST treat a
# non-numeric return as "exclude from eviction", never coerce it to 0.
scratch_budget_content_mtime() {
  local path="$1" epoch strict="${2:-}" links stat_format
  if [[ "$strict" == --strict ]]; then
    [[ -d "$path" && ! -L "$path" ]] || return 1
    links="$(find "$path" -type l -print -quit 2>/dev/null)" || return 1
    [[ -z "$links" ]] || return 1
    local files item stamp newest=0
    files="$(find "$path" -type f -print 2>/dev/null)" || return 1
    [[ -n "$files" ]] || return 1
    if [[ "$(uname -s)" == Darwin ]]; then stat_format='%m'; else stat_format='%Y'; fi
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      if [[ "$(uname -s)" == Darwin ]]; then
        stamp="$(stat -f "$stat_format" "$item" 2>/dev/null)" || return 1
      else
        stamp="$(stat -c "$stat_format" "$item" 2>/dev/null)" || return 1
      fi
      [[ "$stamp" =~ ^[0-9]+$ ]] || return 1
      (( stamp > newest )) && newest="$stamp"
    done <<<"$files"
    (( newest > 0 )) || return 1
    echo "$newest"
    return 0
  fi
  if [[ "$(uname -s)" == Darwin ]]; then stat_format="%m"; else stat_format="%Y"; fi
  # PR #71 /advice follow-up (Opus, PR #78): every `stat`/`find` call below is
  # neutralized with `|| true` so a failure (e.g. the path vanishing between
  # the caller's enumeration and this call -- the same TOCTOU class as bead
  # disk_magician-lsl) can never abort the caller under `set -euo pipefail`.
  # A bare failing command here previously aborted the ENTIRE cleanup script
  # instead of yielding "unmeasurable, preserve".
  if [[ -f "$path" && ! -d "$path" ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then stat -f "$stat_format" "$path" 2>/dev/null || true; else stat -c "$stat_format" "$path" 2>/dev/null || true; fi
    return
  fi
  if [[ "$(uname -s)" == Darwin ]]; then
    epoch="$(find "$path" -type f -exec stat -f "$stat_format" {} + 2>/dev/null \
        | awk '$1+0>m{m=$1+0} END{if (m>0) print m}' || true)"
  else
    epoch="$(find "$path" -type f -exec stat -c "$stat_format" {} + 2>/dev/null \
        | awk '$1+0>m{m=$1+0} END{if (m>0) print m}' || true)"
  fi
  if [[ -z "$epoch" ]]; then
    if [[ "$(uname -s)" == Darwin ]]; then epoch="$(stat -f "$stat_format" "$path" 2>/dev/null || true)"; else epoch="$(stat -c "$stat_format" "$path" 2>/dev/null || true)"; fi
  fi
  echo "$epoch"
}

# Repository removal belongs to the canonical worktree cleanup, which also
# checks unpushed work. A failed traversal cannot prove this is disposable.
_scratch_budget_contains_git() {
  local found
  if ! found="$(find "$1" -name .git -prune -print -quit 2>/dev/null)"; then
    return 0
  fi
  [[ -n "$found" ]]
}

# scratch_budget_evict_root <root> <budget_kb> <floor_minutes>
scratch_budget_evict_root() {
  local root="$1" budget_kb="$2" floor_minutes="$3"
  [[ -d "$root" ]] || return 0

  # Hard production guard (bead disk_magician-ka4): abort before any
  # deletion if DISK_MAGICIAN_TEST_SANDBOX is set and this root falls
  # outside it. No-op in production (env unset).
  sandbox_guard_roots "$root"

  if ! [[ "$budget_kb" =~ ^[0-9]+$ ]] || (( budget_kb <= 0 )); then
    return 0
  fi
  if ! [[ "$floor_minutes" =~ ^[0-9]+$ ]]; then
    floor_minutes=120
  fi
  # Hard floor (bead disk_magician-d45 spec): 2h default, 1h minimum,
  # never lower — mirrors the WORKTREE_MIN_AGE_DAYS clamp-up pattern in
  # cleanup_tmp.sh (may only be raised by config, never lowered below the
  # safety floor).
  (( floor_minutes < 60 )) && floor_minutes=60

  local snapshot_file candidates_file
  snapshot_file="$(mktemp -t disk-magician-scratch-budget-lsof.XXXXXX)"
  if ! _scratch_budget_lsof_snapshot >"$snapshot_file"; then
    log "scratch_budget: lsof snapshot unavailable for $root enumeration — proceeding without prefilter (per-candidate lsof still gates every deletion)."
    : >"$snapshot_file"
  fi
  candidates_file="$(mktemp -t disk-magician-scratch-budget-candidates.XXXXXX)"

  local item base kb mtime total_kb=0
  while IFS= read -r -d '' item; do
    base="$(basename "$item")"
    [[ -n "$base" ]] || continue
    case "$base" in
      com.apple.*|system-*|PowerlogHelperd*|TemporaryItems|_disk_magician_archive*) continue ;;
    esac
    if is_protected_root "$base" || is_protected_tmp_path "$item"; then
      log "scratch_budget: skipping protected root: $item"
      continue
    fi
    if [[ -d "$item" && ! -L "$item" ]] && _scratch_budget_contains_git "$item"; then
      log "scratch_budget: preserving repository container or uninspectable path: $item"
      continue
    fi
    mtime="$(scratch_budget_content_mtime "$item")"
    kb="$( { path_size_kb "$item" || true; } | awk '$1 ~ /^-?[0-9]+$/ {f=$1} END{print f+0}' )"
    if (( kb < 0 )); then
      log "scratch_budget: size unknown for $item — preserving (excluded from eviction and total)."
      continue
    fi
    total_kb=$(( total_kb + kb ))
    # "cannot measure -> preserve" (bead disk_magician-lsl follow-up): a
    # non-numeric mtime (stat/find failure, unreadable subtree) is excluded
    # from the eviction candidate list entirely -- never written to
    # candidates_file, so it can never sort first and never gets evicted.
    # kb still counts toward total_kb above since the space is real; only
    # eviction ELIGIBILITY is affected. Filtering here (rather than writing
    # an empty first field) also keeps every candidates_file row a
    # well-formed 3-field TSV line for the `IFS=$'\t' read` below.
    if ! [[ "$mtime" =~ ^[0-9]+$ ]]; then
      log "scratch_budget: cannot measure content mtime for $item — preserving (excluded from eviction)."
      continue
    fi
    printf '%s\t%s\t%s\n' "$mtime" "$kb" "$item" >>"$candidates_file"
  done < <(find "$root" -mindepth 1 -maxdepth 1 \( -type d -o -type f -o -type l \) -print0 2>/dev/null || true)

  if (( total_kb <= budget_kb )); then
    log "scratch_budget: $root total ${total_kb} KB <= budget ${budget_kb} KB — nothing to evict."
    rm -f "$snapshot_file" "$candidates_file"
    return 0
  fi

  local over_kb=$(( total_kb - budget_kb ))
  log "scratch_budget: $root total ${total_kb} KB exceeds budget ${budget_kb} KB by ${over_kb} KB — evicting oldest-first (floor ${floor_minutes}m)."

    local now floor_epoch freed_kb=0
  now="$(date +%s)"
  floor_epoch=$(( now - floor_minutes * 60 ))

    local mtime_i kb_i item_i was_dir result
  while IFS=$'\t' read -r mtime_i kb_i item_i; do
    (( freed_kb >= over_kb )) && break
    [[ -e "$item_i" ]] || continue  # already gone (e.g. removed by an earlier pass)

    if (( mtime_i > floor_epoch )); then
      continue  # too young — hard floor, never evict
    fi
    if _scratch_budget_snapshot_has_prefix "$snapshot_file" "$item_i"; then
      log "scratch_budget: skipping (open per lsof snapshot): $item_i"
      continue
    fi
    # Per-candidate recheck immediately before deletion (bead dcz): the
    # upfront snapshot above is enumeration-speed-only, never authoritative.
    if has_open_files "$item_i"; then
      log "scratch_budget: skipping (open files, rechecked): $item_i"
      continue
    fi
    if ! _scratch_budget_reason="$(safety_gate "$item_i" 2>/dev/null)"; then
      log "scratch_budget: SAFETY-SKIP $item_i (${_scratch_budget_reason:-unknown})"
      continue
    fi

    was_dir=false
    [[ -d "$item_i" && ! -L "$item_i" ]] && was_dir=true

    if [[ "$DRY_RUN" == true ]]; then
      log "DRY RUN: would evict (budget): $item_i  (${kb_i} KB)"
    else
      log "Requesting C14 eviction: $item_i  (${kb_i} KB)"
      result="$(DM_DELETION_LOGGED=1 scratch_budget_quarantine_remove "$item_i")"
      if [[ "${CANDIDATE_REMOVED_COUNT+x}" == x ]]; then
        case "$result" in
          removed:*) CANDIDATE_REMOVED_COUNT=$((CANDIDATE_REMOVED_COUNT + 1)) ;;
          deferred:deadline-before-unit) CANDIDATE_INTERRUPTED_COUNT=$((CANDIDATE_INTERRUPTED_COUNT + 1)) ;;
          deferred:*) CANDIDATE_DEFERRED_COUNT=$((CANDIDATE_DEFERRED_COUNT + 1)) ;;
        esac
      fi
      # No unit after an interruption can fit the (strictly shrinking) deadline
      # budget, so stop this pass. The cursor stays on the interrupted unit for
      # the next invocation to retry (Cursor review 5/6).
      case "$result" in
        deferred:deadline-before-unit|kept:invalid-deadline)
          log "scratch_budget: stopping pass ($result): $item_i"
          break ;;
      esac
      if [[ "$result" != removed:* ]]; then
        log "scratch_budget: preserved by C14 ($result): $item_i"
        continue
      fi
      deletion_log "$(basename "${0:-scratch_budget}")" "evict_budget" "$kb_i" "$item_i"
    fi

    freed_kb=$(( freed_kb + kb_i ))
    if [[ "$was_dir" == true ]]; then
      BUDGET_DIRS_DELETED=$(( BUDGET_DIRS_DELETED + 1 ))
    else
      BUDGET_FILES_DELETED=$(( BUDGET_FILES_DELETED + 1 ))
    fi
    BUDGET_KB_FREED=$(( BUDGET_KB_FREED + kb_i ))
  done < <(sort -t $'\t' -k1,1n "$candidates_file")

  rm -f "$snapshot_file" "$candidates_file"
}
