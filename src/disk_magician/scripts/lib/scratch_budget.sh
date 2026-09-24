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
#   - a git worktree younger than the 7-day floor (worktree_recency.sh)
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
# Sourced directly (not duck-typed): safety_gate (safety_lib.sh),
# worktree_is_recently_active (scripts/lib/worktree_recency.sh) — both
# scripts already source these ahead of this file.
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
  local path="$1" epoch
  if [[ -f "$path" && ! -d "$path" ]]; then
    stat -f '%m' "$path" 2>/dev/null
    return
  fi
  epoch="$(find "$path" -type f -exec stat -f '%m' {} + 2>/dev/null \
      | awk '$1+0>m{m=$1+0} END{if (m>0) print m}')"
  if [[ -z "$epoch" ]]; then
    epoch="$(stat -f '%m' "$path" 2>/dev/null)"
  fi
  echo "$epoch"
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
      com.apple.*|system-*|PowerlogHelperd*|_disk_magician_archive*) continue ;;
    esac
    if is_protected_root "$base" || is_protected_tmp_path "$item"; then
      log "scratch_budget: skipping protected root: $item"
      continue
    fi
    if [[ -d "$item/.git" || -f "$item/.git" ]] && worktree_is_recently_active "$item" 7; then
      log "scratch_budget: skipping worktree younger than 7d floor: $item"
      continue
    fi
    mtime="$(scratch_budget_content_mtime "$item")"
    kb=$(path_size_kb "$item")
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

  local mtime_i kb_i item_i was_dir
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
      log "Evicting (budget): $item_i  (${kb_i} KB)"
      if [[ "$was_dir" == true ]]; then
        chmod -R u+w "$item_i" 2>/dev/null || true
        if ! rm -rf "$item_i" 2>/dev/null; then
          log "scratch_budget: rm failed for $item_i"
          continue
        fi
      else
        chmod u+w "$item_i" 2>/dev/null || true
        if ! rm -f "$item_i" 2>/dev/null; then
          log "scratch_budget: rm failed for $item_i"
          continue
        fi
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
