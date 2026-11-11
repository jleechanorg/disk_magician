#!/usr/bin/env bash
# cleanup_scratch_top_level.sh — reclaim top-level artifacts on the Scratch volume.
#
# Why this exists (disk_magician-46z7 / -mxhz follow-up): the 2026-10-28
# /tmp -> Scratch relocation moved agent scratch out of every canonical cleaner's
# ownership. cleanup_tmp.sh, cleanup_pr_scratch.sh and cleanup_xcode.sh all scope
# /private/tmp, and `volume reclaim` matches only <repo>/{evidence,build}/<name>.
# Top-level entries under the Scratch root (/Volumes/diskm-scratch/<name>) are
# therefore unowned: nothing but `rm` could take them, which the worktree/rm
# guards correctly refuse. Measured 2026-10-30: 65.8 GiB sat in that dead zone.
#
# Gates, all fail-closed, in this order:
#   1. the root must be the registered Scratch mount (verify-mount) and a real
#      directory; a test root requires the explicit test sandbox;
#   2. registered Scratch candidates include generic nested directory units:
#      never the root, symlinks, hidden components or repository internals;
#   3. newest content mtime must be at least SCRATCH_PRUNE_MIN_HOURS old
#      (24 h floor; a larger value is honoured, a smaller one is clamped up);
#   4. safety_gate (never_delete / protected_live_paths / needs_decision);
#   5. webhook-free C14 verdict under the shared lease-registry lock. C14 proves
#      no live owner lease, no live cwd, no open file and no recent activity
#      BEFORE it reaches its content checks, so a content keep has already
#      cleared all four;
#   6. the content verdicts kept:secret-like and kept:unproven-content are
#      overridden ONLY with SCRATCH_TOP_LEVEL_APPROVED=1, and the override is
#      recorded in the deletion log. Every other keep blocks (live-owner,
#      open-file, live-cwd, dirty, recent-activity, check-failed, ...).
#
# Deleting is delegated to the canonical C14 two-phase quarantine primitives
# (bind -> candidate -> verdict+inventory -> remove) and logged through
# deletion_log_removal, so a keep is always the default.
#
# LRU budget mode (bead disk_magician-walx, --budget-pct N): Scratch is
# disposable by contract, so when the volume is above N% used, top-level entries
# (plus <repo>/{build,evidence}/<name> units) are evicted least-recently-used
# first by canonical content mtime, re-measuring usage before each removal, until
# usage is at or below N%. Only live use keeps: C14 lease/live-cwd/open-file/
# 60-minute activity, the --budget-floor-minutes floor (default 120, minimum 60),
# safety_gate, and unmeasurable recency or usage. Content and repository
# provenance keeps (dirty, not-pushed, secret-like, ...) are overridden, and each
# eviction logs its prior C14 verdict so unpushed losses stay auditable.
#
# Usage: cleanup_scratch_top_level.sh [--dry-run|--clean] [--min-hours N] [--max-gib N]
#        [--budget-pct N [--budget-floor-minutes N]]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=scripts/lib/quarantine.sh
source "$SCRIPT_DIR/lib/quarantine.sh"
# shellcheck source=scripts/lib/scratch_lock.sh
source "$SCRIPT_DIR/lib/scratch_lock.sh"
# shellcheck source=scripts/lib/scratch_budget.sh
source "$SCRIPT_DIR/lib/scratch_budget.sh"
# shellcheck source=scripts/lib/actuator_deadline.sh
source "$SCRIPT_DIR/lib/actuator_deadline.sh"

artifact_batch_output_file=""
scratch_lock_set_traps

ORIG_ARGS=("$@")
act_parse_deadline_args "$@" || exit 2
if ((${#ACT_ARGS[@]})); then set -- "${ACT_ARGS[@]}"; else set --; fi

MIN_HOURS_FLOOR=24
SCRATCH_AUTOMATIC="${DISK_MAGICIAN_SCRATCH_AUTOMATIC:-0}"
AVAILABLE_FLOOR=false
RECENCY_SPEC=""
# Idle-floor override (operator decision 2026-10-31): DISK_MAGICIAN_SCRATCH_FLOOR_HOURS=N
# (N>=12) lowers the manual operator floor. Automatic mode always uses at least 24h
# and does not activate the content/repository override tied to this floor.
if [[ "$SCRATCH_AUTOMATIC" != 1 && "${DISK_MAGICIAN_SCRATCH_FLOOR_HOURS:-}" =~ ^[1-9][0-9]{1,3}$ && "$DISK_MAGICIAN_SCRATCH_FLOOR_HOURS" -ge 12 && "$DISK_MAGICIAN_SCRATCH_FLOOR_HOURS" -lt "$MIN_HOURS_FLOOR" ]]; then
  _guard_state_dir="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
  if { mkdir -p "$_guard_state_dir" && printf '%s scratch-prune: recency override active: hours:%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DISK_MAGICIAN_SCRATCH_FLOOR_HOURS" >>"$_guard_state_dir/worktree_guard.log"; } 2>/dev/null; then
    MIN_HOURS_FLOOR="$DISK_MAGICIAN_SCRATCH_FLOOR_HOURS"
    RECENCY_SPEC="hours:$MIN_HOURS_FLOOR"
  else
      echo "scratch-prune: cannot record recency override hours:$DISK_MAGICIAN_SCRATCH_FLOOR_HOURS; using 24h floor" >&2
  fi
fi
MIN_HOURS="${SCRATCH_PRUNE_MIN_HOURS:-$MIN_HOURS_FLOOR}"
MAX_GIB="${SCRATCH_PRUNE_MAX_GIB:-25}"
MAX_GIB_SET=false
[[ -n "${SCRATCH_PRUNE_MAX_GIB:-}" ]] && MAX_GIB_SET=true
BUDGET_PCT=""
BUDGET_PRESERVE_CONTENT_KEEPS=false
BUDGET_FLOOR_MINUTES=120
# Known content/provenance keeps budget mode may override; anything else keeps,
# including remote-unverified (a failed ls-remote is an unknown, not a keep).
BUDGET_OVERRIDABLE='kept:secret-like|kept:unproven-content|kept:not-pushed|kept:dirty|kept:git-unbaselined|kept:git-metadata|kept:unreachable-object|kept:ignored-data'
DRY_RUN=true

usage() {
  cat <<'USAGE'
Usage: cleanup_scratch_top_level.sh [--dry-run|--clean] [--available-floor] [--deadline-at T] [--cursor PATH] [--min-hours N] [--max-gib N]
       cleanup_scratch_top_level.sh [--dry-run|--clean] --budget-pct N [--budget-floor-minutes N] [--budget-preserve-content-keeps] [--max-gib N] [--deadline-at T]

  --dry-run       Preview candidates and their C14 verdicts (default).
  --clean         Actually remove eligible candidates. Requires
                  SCRATCH_TOP_LEVEL_APPROVED=1, or the C14-only
                  DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 mode on the registered volume.
  --available-floor  Stop at 50 GiB available and recheck before each removal.
  --min-hours N   Recency floor in hours (default 24; values below 24 are
                  clamped up to 24).
  --max-gib N     Per-run removal cap in GiB (default 25; 0 means no cap;
                  budget mode defaults to no cap).
  --budget-pct N  LRU budget mode: while Scratch is above N% used (1-99),
                  evict least-recently-used entries until at or below N%.
                  Overrides content/provenance keeps (dirty, not-pushed,
                  secret-like, ...) only when every repository in the entry
                  returns such a known keep; never lease, live-cwd, open-file,
                  floor, unknown or failed checks, and never an entry holding
                  a linked worktree.
                  --clean needs SCRATCH_TOP_LEVEL_APPROVED=1.
  --budget-floor-minutes N  Budget-mode recency floor (default 120, min 60).
  --budget-preserve-content-keeps  Keep every C14 content/provenance verdict; only final `remove` verdicts may be budget-evicted.

Automatic mode removes only C14-recognized ephemeral Scratch artifacts. It never
overrides C14 secret, unknown-content, lease, live-cwd, open-file, dirty, or
unpushed keeps.
USAGE
}

# The lock supervisor re-executes this script, so it must receive the caller's
# original argv: the parse loop below consumes the flags.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --available-floor) AVAILABLE_FLOOR=true; shift ;;
    --min-hours) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; MIN_HOURS="$2"; shift 2 ;;
    --max-gib) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; MAX_GIB="$2"; MAX_GIB_SET=true; shift 2 ;;
    --budget-pct) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]?$ ]] || { usage >&2; exit 2; }; BUDGET_PCT="$2"; shift 2 ;;
    --budget-floor-minutes) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; BUDGET_FLOOR_MINUTES="$2"; shift 2 ;;
    --budget-preserve-content-keeps) BUDGET_PRESERVE_CONTENT_KEEPS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# The recency floor may rise but never fall below the 24 h default: a caller
# cannot make this cleaner more aggressive than its documented contract.
[[ "$MIN_HOURS" =~ ^[0-9]+$ ]] || MIN_HOURS="$MIN_HOURS_FLOOR"
MIN_HOURS=$((10#$MIN_HOURS))
(( MIN_HOURS < MIN_HOURS_FLOOR )) && MIN_HOURS="$MIN_HOURS_FLOOR"
[[ "$MAX_GIB" =~ ^[0-9]+$ ]] || MAX_GIB=25
MAX_GIB=$((10#$MAX_GIB))
if [[ "$BUDGET_PRESERVE_CONTENT_KEEPS" == true && -z "$BUDGET_PCT" ]]; then
  echo "--budget-preserve-content-keeps requires --budget-pct." >&2
  exit 2
fi
if [[ -n "$BUDGET_PCT" ]]; then
  # Budget mode never runs inside the C14-only automatic mode, and the budget
  # target (not the 50 GiB available floor) is its stop condition.
  if [[ "$SCRATCH_AUTOMATIC" == 1 || "$AVAILABLE_FLOOR" == true ]]; then
    echo "Refusing --budget-pct with automatic mode or --available-floor." >&2
    exit 2
  fi
  BUDGET_FLOOR_MINUTES=$((10#$BUDGET_FLOOR_MINUTES))
  (( BUDGET_FLOOR_MINUTES < 60 )) && BUDGET_FLOOR_MINUTES=60
  [[ "$MAX_GIB_SET" == true ]] || MAX_GIB=0
fi
MAX_KB=$(( MAX_GIB * 1024 * 1024 ))

if [[ "$DRY_RUN" != true && "$SCRATCH_AUTOMATIC" == 1 && "${SCRATCH_TOP_LEVEL_APPROVED:-0}" == 1 ]]; then
  echo "Refusing automatic mode with SCRATCH_TOP_LEVEL_APPROVED=1; automatic mode never overrides C14 keeps." >&2
  exit 2
fi
if [[ "$DRY_RUN" != true && "${SCRATCH_TOP_LEVEL_APPROVED:-0}" != "1" && "$SCRATCH_AUTOMATIC" != 1 ]]; then
  echo "Refusing to delete: set SCRATCH_TOP_LEVEL_APPROVED=1 after reviewing the dry-run output." >&2
  exit 2
fi

diskm="${DISK_MAGICIAN_DISKM_BIN:-$SCRIPT_DIR/../disk_magician.sh}"
if [[ -n "${DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE:-}" ]]; then
  # A synthetic root is only admissible inside the explicit test sandbox, so a
  # test or a stray env var can never point this cleaner at real data.
  if [[ "${DISK_MAGICIAN_TEST_CONTEXT:-}" != "1" || -z "${DISK_MAGICIAN_TEST_SANDBOX:-}" ]]; then
    echo "Refusing root override outside the test sandbox." >&2
    exit 2
  fi
  root="$DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE"
  root_registered=false
  if [[ -z "$root" || "$root" == "/" || ! -d "$root" || -L "$root" ]]; then
    echo "Refusing unsafe scratch root: '${root}'" >&2
    exit 2
  fi
  sandbox_guard_roots "$root"
else
  root="$("$diskm" volume path scratch --for-reclaim 2>/dev/null)" || { echo skipped:unavailable; exit 0; }
  [[ -n "$root" ]] || { echo skipped:unavailable; exit 0; }
  "$diskm" volume verify-mount "$root" >/dev/null 2>&1 || { echo skipped:unavailable; exit 0; }
  root_registered=true
fi
if [[ -z "$root" || "$root" == "/" || ! -d "$root" || -L "$root" ]]; then
  echo "Refusing unsafe scratch root: '${root}'" >&2
  exit 2
fi
root="$(cd "$root" 2>/dev/null && pwd -P)" || { echo "Refusing unresolvable scratch root." >&2; exit 2; }
[[ -n "$root" && "$root" != "/" ]] || { echo "Refusing unsafe scratch root: '${root}'" >&2; exit 2; }
if [[ "$SCRATCH_AUTOMATIC" == 1 && "$root_registered" != true ]]; then
  echo "Refusing automatic cleanup outside the verified registered Scratch mount." >&2
  exit 2
fi
if [[ "$AVAILABLE_FLOOR" == true && "$root_registered" != true ]]; then
  echo "Refusing --available-floor without a verified registered Scratch mount." >&2
  exit 2
fi

if [[ "$DRY_RUN" != true ]]; then
  # Serialize with volume reclaim and the tmp sweeps; the supervisor execs this
  # script again, so pass the original argv (never the consumed one).
  if (( ${#ORIG_ARGS[@]} )); then
    scratch_lock_acquire scratch_prune "${ORIG_ARGS[@]}" || exit $?
  else
    scratch_lock_acquire scratch_prune || exit $?
  fi
fi

ACT_CURSOR_SOURCE="scratch_prune:v1:$root"
CURSOR_ERROR=0
CURSOR_RESUME_TARGET=""
if [[ "$SCRATCH_AUTOMATIC" == 1 && "$DRY_RUN" != true && -n "$ACT_CURSOR" ]]; then
  _cursor_state="$(act_cursor_load "$ACT_CURSOR" "$ACT_CURSOR_SOURCE")" || { CURSOR_ERROR=1; echo kept:cursor-invalid; }
  if (( ! CURSOR_ERROR )); then
    act_cursor_reset_once "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" || { CURSOR_ERROR=1; echo kept:cursor-reset-failed; }
    if (( ! CURSOR_ERROR )); then
      _cursor_state="$(act_cursor_load "$ACT_CURSOR" "$ACT_CURSOR_SOURCE")" || { CURSOR_ERROR=1; echo kept:cursor-invalid; }
    fi
    if (( ! CURSOR_ERROR )); then
      while IFS= read -r -d '' _cursor_pending; do CURSOR_RESUME_TARGET="$_cursor_pending"; break; done < <(
        printf '%s' "$_cursor_state" | python3 -c 'import json,os,sys
state=json.load(sys.stdin)
for path in state["items"][state["next_index"]:]:
    if os.path.lexists(path):
        sys.stdout.buffer.write(path.encode()+bytes([0]))
        break'
      )
      if [[ -z "$CURSOR_RESUME_TARGET" ]]; then
        # All unfinished cursor entries disappeared since the previous pass.
        # Treat that queue as complete and start a fresh pass in the same scope.
        act_cursor_save "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" "[]" 0 || { CURSOR_ERROR=1; echo kept:cursor-reset-failed; }
      fi
    fi
  fi
fi

# scratch_usage_pair — "<allocated_bytes> <quota_bytes>" from the canonical volume
# status (the metric volume reclaim's trigger/target uses); rc 75 if unmeasurable.
scratch_usage_pair() {
  local status rc pair
  if [[ "$root_registered" == true ]]; then
    "$diskm" volume verify-mount "$root" >/dev/null 2>&1 || return 75
  fi
  status="$("$diskm" volume status --json --snapshot 2>/dev/null)"; rc=$?
  (( rc == 0 || rc == 1 )) || return 75
  pair="$(python3 -c 'import json,sys; d=json.load(sys.stdin); r=next(x for x in d["volumes"] if x.get("class")=="scratch"); u=r.get("allocated_bytes"); q=r.get("quota_bytes"); assert type(u) is int and type(q) is int and q>0; print(u,q)' <<<"$status" 2>/dev/null)" || return 75
  [[ "$pair" =~ ^[0-9]+\ [0-9]+$ ]] || return 75
  printf '%s\n' "$pair"
}

scratch_available_bytes() {
  local pair used quota quota_free fs_free
  pair="$(scratch_usage_pair)" || return 75
  read -r used quota <<<"$pair"
  fs_free="$(python3 "$SCRIPT_DIR/scratch_pressure.py" "$root" 2>/dev/null)" || return 75
  [[ "$fs_free" =~ ^[0-9]+$ ]] || return 75
  quota_free=$(( quota - used )); (( quota_free < 0 )) && quota_free=0
  (( fs_free < quota_free )) && printf '%s\n' "$fs_free" || printf '%s\n' "$quota_free"
}

data_volume_free_bytes() {
  local mount=/ line
  [[ -d /System/Volumes/Data ]] && mount=/System/Volumes/Data
  line="$(df -Pk "$mount" 2>/dev/null | awk 'NR==2 {print $4; exit}')" || return 1
  [[ "$line" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$(( line * 1024 ))"
}

# Detail floor for candidate reporting. A candidate at or above it is reported
# file-by-file instead of as ONE `du` total, so the operator sees which child
# holds the bytes: measured 2026-11-03, a 35 GiB build root reported as a single
# line while 23.7 GiB of its children were 39-41 h old. Reporting only -- the
# C14 verdict, the recency floor, the cursor and the LRU order are untouched.
DETAIL_MIB=100
report_candidate_detail() {
  local entry="$1" rows bytes files newest flag path apparent_bytes metadata rc=0
  # The caller supplies allocated du KiB; only the measurement can decide
  # the apparent-size threshold (sparse files may have almost no allocation).
  rows="$(scratch_budget_measure_files "$entry" "$DETAIL_MIB" 2>/dev/null)" || rc=$?
  while IFS=$'\t' read -r bytes files newest flag path apparent_bytes; do
    [[ -n "${flag:-}" ]] || continue
    [[ "$flag" == A && "$path" == "$entry" ]] && continue
    metadata="size_method=inode-deduplicated-file-summed-apparent threshold_mib=$DETAIL_MIB apparent_bytes=$apparent_bytes unique_bytes=$bytes"
    if [[ "$flag" == G || "$flag" == E ]]; then
      metadata="size_method=unmeasured size_known=false age_known=false threshold_mib=$DETAIL_MIB"
    fi
    printf 'detail:%s bytes=%s files=%s newest=%s %s %s\n' "$flag" "$bytes" "$files" "$newest" "$metadata" "$path"
  done <<<"$rows"
  if (( rc != 0 )); then
    printf 'detail:unfinished rc=%s path=%s\n' "$rc" "$entry"
  fi
  return "$rc"
}

if [[ "$AVAILABLE_FLOOR" == true ]]; then
  scratch_available="$(scratch_available_bytes)" || { echo skipped:measurement-unavailable; exit 75; }
  if (( scratch_available >= 50 * 1024 * 1024 * 1024 )); then
    echo "skipped:available-floor:$scratch_available"
    exit 0
  fi
fi

now="$(date +%s)"
floor_epoch=$(( now - MIN_HOURS * 3600 ))
scanned=0 kept=0 removable=0 removed=0 planned_kb=0 removed_kb=0 capped=0 busy_streak=0
DEFERRED_CANDIDATES=0
MEASUREMENT_INCOMPLETE=0
data_free_before_bytes="$(data_volume_free_bytes 2>/dev/null || echo unknown)"
budget_target_bytes=0 budget_gap_before_bytes=unknown

emit_discovery_deferred_summary() {
  local reason="$1" after delta
  DEFERRED_CANDIDATES=$(( DEFERRED_CANDIDATES + 1 ))
  after="$(data_volume_free_bytes 2>/dev/null || echo unknown)"
  if [[ "$data_free_before_bytes" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]]; then delta=$(( after - data_free_before_bytes )); else delta=unknown; fi
  printf 'scanned=%s kept=%s removable=%s removed=%s eligible_estimate=%s candidate_size_estimate_kb=0 deletion_size_estimate_kb=0 deferred_candidates=%s data_free_before_bytes=%s data_free_after_bytes=%s data_free_interval_delta_bytes=%s\n' \
    "$scanned" "$kept" "$removable" "$removed" "$removable" "$DEFERRED_CANDIDATES" "$data_free_before_bytes" "$after" "$delta"
  echo "deferred:artifact-discovery-${reason}"
  if [[ -n "$BUDGET_PCT" && "$DRY_RUN" != true ]]; then
    echo "budget_unmet=unknown projected_budget_unmet=unknown reason=artifact-discovery-${reason}"
  elif [[ -n "$BUDGET_PCT" ]]; then
    echo "budget_unmet=not-run projected_budget_unmet=unknown projected_gap_bytes=unknown"
  fi
}

# verdict_and_maybe_remove <entry> — C14 gate plus the operator-approved content
# override. The caller captures this function's output, so its lease scope must
# live in that command-substitution shell across verdict and quarantine rename.
verdict_and_maybe_remove() { _lease_lock_scope release _verdict_and_maybe_remove "$@"; }
_verdict_and_maybe_remove() {
  local entry="$1" inv binding verdict_path verdict override="" out
  inv="$(mktemp "${TMPDIR:-/tmp}/dm-sp-inv.XXXXXX")" || { echo kept:check-failed; return 0; }
  binding="$(mktemp "${TMPDIR:-/tmp}/dm-sp-parent.XXXXXX")" || { rm -f "$inv"; echo kept:check-failed; return 0; }
  if ! python3 "$SCRIPT_DIR/quarantine_rename.py" bind "$entry" "$binding" >/dev/null 2>&1; then
    rm -f "$inv" "$binding"; echo kept:parent-identity-missing; return 0
  fi
  verdict_path="$(python3 "$SCRIPT_DIR/quarantine_rename.py" candidate "$binding" 2>/dev/null)" || verdict_path=""
  if [[ -z "$verdict_path" ]]; then rm -f "$inv" "$binding"; echo kept:parent-identity-missing; return 0; fi
  # A preview mutates nothing, so it does not need the registry lock; --clean
  # takes it per candidate so a producer cannot register a lease between the
  # verdict and the rename. The retry budget is short because a busy registry
  # blocks EVERY candidate: the caller aborts the pass on repeated contention
  # instead of paying this wait once per entry.
  local tries=600
  if [[ "$DRY_RUN" != true ]]; then
    while (( tries-- > 0 )); do
      if lease_registry_mutation_lock_enter; then break; fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    if (( tries < 0 )); then rm -f "$inv" "$binding"; echo kept:lease-busy; return 0; fi
  fi
  if [[ "$BUDGET_PRESERVE_CONTENT_KEEPS" == true ]]; then
    # Only C14-recognized ephemeral artifacts get the age-based remove verdict;
    # unknown and repository content keeps remain final keeps in this mode.
    verdict="$(artifact_removal_verdict "$verdict_path" --kind ephemeral --inventory-out "$inv" 2>/dev/null)" || verdict=kept:check-failed
  else
    verdict="$(artifact_removal_verdict "$verdict_path" --inventory-out "$inv" 2>/dev/null)" || verdict=kept:check-failed
  fi
  case "$verdict" in
    remove) ;;
    kept:secret-like|kept:unproven-content)
      # Ordered-gate guarantee: C14 evaluates owner lease, live cwd, open files
      # and recent activity BEFORE these content checks, so both are already
      # proven for this candidate when this branch runs.
      if [[ "${SCRATCH_TOP_LEVEL_APPROVED:-0}" == "1" && "$BUDGET_PRESERVE_CONTENT_KEEPS" != true ]]; then
        override="$verdict"
        verdict=remove
      fi ;;
  esac
  # LRU budget mode (walx): Scratch is disposable, so known content and provenance
  # keeps may be overridden. C14 stops at the first failing check, so this is only
  # a candidate override: the whole-entry repository check below decides it.
  if [[ "$verdict" != remove && -n "$BUDGET_PCT" && "$BUDGET_PRESERVE_CONTENT_KEEPS" != true && "|$BUDGET_OVERRIDABLE|" == *"|$verdict|"* ]]; then
    override="$verdict"
    verdict=remove
  fi
  if [[ "$verdict" != remove ]]; then
    [[ "$DRY_RUN" == true ]] || lease_registry_mutation_lock_exit || true
    rm -f "$inv" "$binding"
    echo "$verdict"
    return 0
  fi
  if [[ -n "$override" ]]; then
    # C14 writes --inventory-out only after it approves, so an overridden content
    # keep has no inventory yet. Build it with the same canonical builder the
    # verdict uses. c14_probe.py inventory reports success on stdout ("ok"), not
    # through its exit status, so the output is what is checked.
    if [[ "$(python3 "$SCRIPT_DIR/c14_probe.py" inventory "$entry" "$inv" 2>/dev/null)" != ok ]]; then
      [[ "$DRY_RUN" == true ]] || lease_registry_mutation_lock_exit || true
      rm -f "$inv" "$binding"
      echo kept:check-failed
      return 0
    fi
  fi
  # Budget policy protects linked worktrees even when ordinary C14 already
  # approved a clean, pushed entry without requiring a content override.
  if [[ -n "$override" || -n "$BUDGET_PCT" ]]; then
    # A content override never grants repository-discard authority. The secrets
    # probe can short-circuit before provenance, so validate every override with
    # the shared repository gate regardless of the chosen recency floor.
    local repo_reason repo_rc=0
    # Budget mode decides over the WHOLE entry: every repository the inventory
    # holds is checked (rc 2 = every keep was a known overridable one); a linked
    # worktree or submodule anywhere inside, or any failed, deferred or unknown
    # check, keeps the entry whatever order repositories are discovered in. Other
    # modes pass an empty C14_OVERRIDABLE, so rc 2 cannot occur and every keep holds.
    # Keep Git status from refreshing the index after the immutable inventory.
    repo_overridable="${BUDGET_PCT:+$BUDGET_OVERRIDABLE}"
    [[ "$BUDGET_PRESERVE_CONTENT_KEEPS" == true ]] && repo_overridable=""
    repo_reason="$(GIT_OPTIONAL_LOCKS=0 C14_OVERRIDABLE="$repo_overridable" c14_repos_ok "$entry" "$inv" "${ACT_DEADLINE_AT:-}")" || repo_rc=$?
    (( repo_rc == 2 )) && { [[ "$repo_reason" == "$override" ]] || override+="+${repo_reason}"; repo_rc=0; }
    if (( repo_rc != 0 )); then
      [[ "$DRY_RUN" == true ]] || lease_registry_mutation_lock_exit || true
      rm -f "$inv" "$binding"
      echo "${repo_reason:-kept:check-failed}"
      return 0
    fi
  fi
  # A preview must reach the same verdict --clean would reach, so the override's
  # inventory and repository checks above run in both modes; only the removal
  # itself is preview-only. Without this, a dry run with approval would advertise
  # a would-remove for a secret-like tree that --clean actually keeps.
  if [[ "$DRY_RUN" == true ]]; then
    rm -f "$inv" "$binding"
    echo "would-remove:${override:-remove}"
    return 0
  fi
  out="$(python3 "$SCRIPT_DIR/quarantine_rename.py" remove "$entry" "$inv" "$binding" 2>/dev/null)" || out=kept:check-failed
  lease_registry_mutation_lock_exit || true
  rm -f "$inv" "$binding"
  case "$out" in
    removed:*)
      if [[ -n "$BUDGET_PCT" ]]; then echo "removed:scratch-lru:${override:-remove}"; else echo "removed:scratch-prune${override:+:$override}"; fi
      return 0 ;;
    *) echo "${out:-kept:check-failed}"; return 0 ;;
  esac
}

echo "=== SCRATCH TOP-LEVEL PRUNE ($([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo CLEAN)) — floor $([[ -n "$BUDGET_PCT" ]] && echo "${BUDGET_FLOOR_MINUTES}m" || echo "${MIN_HOURS}h"), cap ${MAX_GIB} GiB ==="
echo "root: $root"

# A scan of a large Scratch volume walks every candidate twice (content mtime
# then the C14 verdict), so honour the shared actuator deadline: a scheduled or
# bounded run stops cleanly with a summary instead of being killed mid-pass.
deadline_exceeded() {
  [[ -n "${ACT_DEADLINE_AT:-}" ]] || return 1
  python3 -c 'import sys,time
try: sys.exit(0 if time.monotonic() >= float(sys.argv[1]) else 1)
except (ValueError, IndexError): sys.exit(1)' "$ACT_DEADLINE_AT" 2>/dev/null
}

candidates=()
for _top in "$root"/*; do
  [[ -e "$_top" || -L "$_top" ]] || continue
  _base="${_top##*/}"
  case "$_base" in
    .*|tmp) continue ;;
    evidence|worldai_frontend|worldarchitect.ai|worldai_claw|disk_magician|mirrors|relocated-tmp|advice-11070)
      # Keep automatic cursor ordering/source identity on the existing queue.
      # Nested manual discovery must not replace its pending root item.
      if [[ "$root_registered" != true && "$SCRATCH_AUTOMATIC" != 1 && -d "$_top" && ! -L "$_top" ]]; then
        for _sub in "$_top"/*; do
          [[ -e "$_sub" || -L "$_sub" ]] || continue
          case "${_sub##*/}" in
            .*) continue ;;
            build|evidence|r10)
              if [[ -d "$_sub" && ! -L "$_sub" ]]; then
                for _grand in "$_sub"/*; do
                  [[ -e "$_grand" || -L "$_grand" ]] || continue
                  case "${_grand##*/}" in .*) continue ;; esac
                  candidates+=("$_grand")
                done
              fi ;;
            *) candidates+=("$_sub") ;;
          esac
        done
        continue
      fi ;;
  esac
  candidates+=("$_top")
done
if [[ -d "$root/tmp" && ! -L "$root/tmp" ]]; then
  _tmp_rest=()
  for _sub in "$root/tmp"/*; do
    [[ -e "$_sub" || -L "$_sub" ]] || continue
    case "${_sub##*/}" in
      .*) continue ;;
      advice*|pr*|merge*|review*|repro*|claude*|codex*|world*|share*|roadmap*) candidates+=("$_sub") ;;
      *) _tmp_rest+=("$_sub") ;;
    esac
  done
  for _sub in ${_tmp_rest[@]+"${_tmp_rest[@]}"}; do
    candidates+=("$_sub")
  done
fi

# A directory's newest-content age is an AGGREGATE. Batch artifact discovery
# once for all real-directory candidates before any candidate can be removed.
# On Bash 3.2, avoid an empty array expansion and do not create a temp file or
# invoke Python when there are no candidate directories.
if (( ${#candidates[@]} )); then
  candidate_dirs=()
  for _candidate in ${candidates[@]+"${candidates[@]}"}; do
    [[ -d "$_candidate" && ! -L "$_candidate" ]] || continue
    # The discovery helper fails closed for the entire batch when ANY candidate
    # subtree is unreadable (documented in scratch_budget_artifact_children.py
    # and pinned by tests/test_scratch_budget_artifact_children.sh case 15).
    # A single root-owned top-level entry therefore voided every pass: measured
    # 2026-11-10 on Linux, Scratch/lost+found (root:root 0700, 16K) made
    # scratch-prune report scanned=0 and reclaim nothing on a 163 GiB volume,
    # and /Volumes/diskm-scratch/.Spotlight-V100 did the same on macOS.
    # Skip candidates this process cannot read and keep the batch contract.
    [[ -r "$_candidate" && -x "$_candidate" ]] || continue
    if [[ "$root_registered" == true ]]; then
      python3 "$SCRIPT_DIR/lib/scratch_budget_artifact_children.py" scope "$root" "$_candidate"
      _scope_rc=$?
      case "$_scope_rc" in
        0) ;;
        3) continue ;;
        *) emit_discovery_deferred_summary unmeasurable-scope; exit 75 ;;
      esac
    fi
    candidate_dirs+=("$_candidate")
  done
  _artifact_extra=()
  if (( ${#candidate_dirs[@]} )); then
    artifact_batch_output_file="$(mktemp "${TMPDIR:-/tmp}/dm-sp-artifacts.XXXXXX")" || { emit_discovery_deferred_summary unmeasurable; exit 75; }
    _artifact_mode=batch
    [[ "$root_registered" == true ]] && _artifact_mode=batch-generic
    printf '%s\0' "${candidate_dirs[@]}" | scratch_budget_artifact_children_batch 3 "$_artifact_mode" >"$artifact_batch_output_file"
    _artifact_rc=$?
    if (( _artifact_rc != 0 )); then
      rm -f "$artifact_batch_output_file"
      artifact_batch_output_file=""
      if (( _artifact_rc == 124 )); then
        emit_discovery_deferred_summary deadline
      else
        emit_discovery_deferred_summary "unmeasurable-rc-$_artifact_rc"
      fi
      exit 75
    fi

    _artifact_fields=()
    _artifact_field=""
    while IFS= read -r -d '' _artifact_field; do
      _artifact_fields+=("$_artifact_field")
    done <"$artifact_batch_output_file"
    _artifact_tail="$_artifact_field"
    if [[ -n "$_artifact_tail" || ${#_artifact_fields[@]} -lt 2 || "${_artifact_fields[0]}" != diskm-artifact-children-v1 || ! "${_artifact_fields[1]}" =~ ^(0|[1-9][0-9]*)$ ]]; then
      rm -f "$artifact_batch_output_file"
      artifact_batch_output_file=""
      emit_discovery_deferred_summary malformed-header
      exit 75
    fi
    _artifact_expected_pairs=$(( (${#_artifact_fields[@]} - 2) / 2 ))
    if (( (${#_artifact_fields[@]} - 2) % 2 != 0 )) || [[ "${_artifact_fields[1]}" != "$_artifact_expected_pairs" ]]; then
      rm -f "$artifact_batch_output_file"
      artifact_batch_output_file=""
      emit_discovery_deferred_summary pair-count-mismatch
      exit 75
    fi
    for ((_artifact_i=2; _artifact_i<${#_artifact_fields[@]}; _artifact_i+=2)); do
      _artifact_parent="${_artifact_fields[_artifact_i]}"
      _artifact_child="${_artifact_fields[_artifact_i+1]}"
      _artifact_parent_submitted=false
      for _candidate in ${candidate_dirs[@]+"${candidate_dirs[@]}"}; do
        [[ "$_candidate" == "$_artifact_parent" ]] && { _artifact_parent_submitted=true; break; }
      done
      if [[ "$_artifact_parent_submitted" != true || "$_artifact_child" != "$_artifact_parent"/* ]]; then
        rm -f "$artifact_batch_output_file"
        artifact_batch_output_file=""
        emit_discovery_deferred_summary candidate-child-mismatch
        exit 75
      fi
      _artifact_relative="${_artifact_child#"$_artifact_parent"/}"
      if [[ -z "$_artifact_relative" || "$_artifact_relative" == */ || "$_artifact_relative" == *//* ]]; then
        rm -f "$artifact_batch_output_file"
        artifact_batch_output_file=""
        emit_discovery_deferred_summary invalid-child-path
        exit 75
      fi
      IFS='/' read -r -a _artifact_components <<<"$_artifact_relative"
      _artifact_check_path="$_artifact_parent"
      for _artifact_component in "${_artifact_components[@]}"; do
        if [[ -z "$_artifact_component" || "$_artifact_component" == . || "$_artifact_component" == .. ]]; then
          rm -f "$artifact_batch_output_file"
          artifact_batch_output_file=""
          emit_discovery_deferred_summary invalid-child-component
          exit 75
        fi
        _artifact_check_path="$_artifact_check_path/$_artifact_component"
        if [[ -L "$_artifact_check_path" ]]; then
          rm -f "$artifact_batch_output_file"
          artifact_batch_output_file=""
          emit_discovery_deferred_summary symlink-component
          exit 75
        fi
      done
      if [[ ! -d "$_artifact_child" || -L "$_artifact_parent" ]]; then
        rm -f "$artifact_batch_output_file"
        artifact_batch_output_file=""
        emit_discovery_deferred_summary path-changed
        exit 75
      fi
      _artifact_extra+=("$_artifact_child")
    done
    rm -f "$artifact_batch_output_file"
    artifact_batch_output_file=""
  fi
  for _artifact_child in ${_artifact_extra[@]+"${_artifact_extra[@]}"}; do
    candidates+=("$_artifact_child")
  done
fi

# LRU budget mode: measure first (fail closed), then order every candidate past
# the floor by canonical content mtime, oldest first. Usage is re-measured before
# each eviction in the main loop; the ordering is all-or-nothing under a deadline.
LRU_LIST="" budget_used=0 budget_quota=0 budget_stop="" budget_unmet=0 budget_now=0 lru_priors=""
if [[ -n "$BUDGET_PCT" ]] && (( ! CURSOR_ERROR )); then
  budget_pair="$(scratch_usage_pair)" || { echo skipped:measurement-unavailable; exit 75; }
  read -r budget_used budget_quota <<<"$budget_pair"
  budget_target_bytes=$(( budget_quota * BUDGET_PCT / 100 ))
  budget_gap_before_bytes=$(( budget_used - budget_target_bytes ))
  (( budget_gap_before_bytes < 0 )) && budget_gap_before_bytes=0
  echo "budget: used_pct=$(( budget_used * 100 / budget_quota )) target_pct=${BUDGET_PCT} floor=${BUDGET_FLOOR_MINUTES}m gap_before_bytes=${budget_gap_before_bytes}"
  if (( budget_used * 100 <= budget_quota * BUDGET_PCT )); then
    if [[ "$DRY_RUN" == true ]]; then
      echo "budget_unmet=not-run projected_budget_unmet=unknown projected_gap_bytes=unknown"
    else
      echo "budget_unmet=0 target_reached=true budget_gap_after_bytes=0"
    fi
    echo "skipped:budget-target-met"
    exit 0
  fi
  floor_epoch=$(( now - BUDGET_FLOOR_MINUTES * 60 ))
  # scratch-new artifacts are LRU units too, so one hot sibling cannot pin a
  # whole <repo> container; a vanished nested unit is skipped in the main loop.
  # Expand each level only after checking it: a leaf-only symlink check does
  # not prevent a glob from traversing a symlinked repository or unit parent.
  for _top in "$root"/*; do
    [[ -d "$_top" && ! -L "$_top" ]] || continue
    for _unit_parent in "$_top/build" "$_top/evidence"; do
      [[ -d "$_unit_parent" && ! -L "$_unit_parent" ]] || continue
      for _sub in "$_unit_parent"/*; do
        [[ -d "$_sub" && ! -L "$_sub" ]] || continue
        # Managed containers above may already have supplied this exact unit.
        _already_candidate=0
        for _candidate in ${candidates[@]+"${candidates[@]}"}; do
          if [[ "$_candidate" == "$_sub" ]]; then
            _already_candidate=1
            break
          fi
        done
        (( _already_candidate )) || candidates+=("$_sub")
      done
    done
  done
  LRU_LIST="$(mktemp "${TMPDIR:-/tmp}/dm-sp-lru.XXXXXX")" || { echo skipped:measurement-unavailable; exit 75; }
  for entry in ${candidates[@]+"${candidates[@]}"}; do
    if deadline_exceeded; then
      rm -f "$LRU_LIST"
      echo "deferred:deadline (LRU ordering incomplete; nothing evicted)"
      exit 0
    fi
    if [[ -L "$entry" ]]; then echo "kept:symlink $entry"; kept=$(( kept + 1 )); continue; fi
    [[ -d "$entry" ]] || continue
    # Manual minimum-size filtering is a prioritization control, not an
    # automatic retention gate. Apply it before the expensive age walk so a
    # tiny slow sibling cannot consume the entire bounded ordering pass.
    if [[ "$SCRATCH_AUTOMATIC" != 1 && "${DISK_MAGICIAN_SCRATCH_MIN_KB:-0}" =~ ^[0-9]+$ ]] && (( 10#${DISK_MAGICIAN_SCRATCH_MIN_KB:-0} > 0 )); then
      _pre_kb="$(deletion_size_kb "$entry" 2>/dev/null)" || _pre_kb=0
      [[ "$_pre_kb" =~ ^[0-9]+$ ]] || _pre_kb=0
      if (( _pre_kb < 10#${DISK_MAGICIAN_SCRATCH_MIN_KB:-0} )); then
        echo "kept:below-min-size $entry (${_pre_kb} KB)"
        kept=$(( kept + 1 )); continue
      fi
    fi
    mtime="$(scratch_budget_content_mtime "$entry" 2>/dev/null)"
    if ! [[ "$mtime" =~ ^[0-9]+$ ]]; then
      echo "kept:mtime-unmeasurable $entry"; kept=$(( kept + 1 )); continue
    fi
    if (( mtime > floor_epoch )); then
      echo "kept:recent-activity $entry (age $(( (now - mtime) / 60 ))m < ${BUDGET_FLOOR_MINUTES}m)"
      kept=$(( kept + 1 )); continue
    fi
    printf '%s\t%s\0' "$mtime" "$entry" >>"$LRU_LIST"
  done
fi

if (( ! CURSOR_ERROR )); then
while IFS= read -r -d '' entry; do
  [[ -e "$entry" || -L "$entry" ]] || continue
  base="${entry##*/}"
  case "$base" in .*) continue ;; esac
  if [[ "$root_registered" == true && -d "$entry" && ! -L "$entry" ]] &&
      ! python3 "$SCRIPT_DIR/lib/scratch_budget_artifact_children.py" scope "$root" "$entry"; then
    echo "kept:discovery-boundary $entry"
    kept=$(( kept + 1 ))
    continue
  fi
  _artifact_blocked=false
  for _blocked in ${_artifact_discovery_blocked[@]+"${_artifact_discovery_blocked[@]}"}; do
    if [[ "$entry" == "$_blocked" ]]; then _artifact_blocked=true; break; fi
  done
  if [[ "$SCRATCH_AUTOMATIC" == 1 && "$DRY_RUN" != true && -n "$CURSOR_RESUME_TARGET" ]]; then
    [[ "$entry" == "$CURSOR_RESUME_TARGET" ]] || continue
    # The resume target is now VISITED, whether or not it turns out to be
    # unmeasurable below. Clear it here, before any `continue` path, so an
    # unreadable root cannot leave the cursor pinned to itself forever.
    # (Previously the blocked check ran FIRST and `continue`d past this line,
    # so an unmeasurable resume target never cleared and every later candidate
    # was skipped by the equality gate -- the whole pass stalled.)
    CURSOR_RESUME_TARGET=""
  fi
  if [[ "$_artifact_blocked" == true ]]; then
    # Complete this visit THROUGH the cursor, not merely past it. Clearing
    # CURSOR_RESUME_TARGET in memory only fixes the current pass; the persisted
    # cursor still points at this entry, so the next invocation resumes onto the
    # same unreadable root and stalls again. The keep-only helper never invokes
    # C14/quarantine, but persists the finished visit and keeps the same
    # deferred/cursor break contract as the unproven-content branch.
    kept=$(( kept + 1 ))
    if [[ "$SCRATCH_AUTOMATIC" == 1 && "$DRY_RUN" != true ]]; then
      outcome="$(scratch_budget_quarantine_remove "$entry" --keep-unproven-content)"
      echo "${outcome/kept:unproven-content/kept:artifact-discovery-unmeasurable} $entry"
      case "$outcome" in deferred:deadline-before-unit|kept:cursor-*) break ;; esac
    else
      echo "kept:artifact-discovery-unmeasurable $entry"
    fi
    continue
  fi
  if deadline_exceeded; then
    if [[ "$SCRATCH_AUTOMATIC" == 1 && "$DRY_RUN" != true ]]; then
      outcome="$(scratch_budget_quarantine_remove "$entry")"
      echo "$outcome $entry"
    else
      echo "deferred:deadline (stopped before $(basename "${entry%%/}"))"
    fi
    break
  fi
  # Read-only metadata coverage is independent of removal age/provenance.
  # Fresh and protected repository units still need granular size reporting.
  if [[ -d "$entry" && ! -L "$entry" ]]; then
    if report_candidate_detail "$entry"; then
      :
    else
      DEFERRED_CANDIDATES=$(( DEFERRED_CANDIDATES + 1 ))
      MEASUREMENT_INCOMPLETE=1
      echo "kept:measurement-unfinished $entry"
      continue
    fi
  fi
  if [[ "$SCRATCH_AUTOMATIC" == 1 ]] && ! c14_ephemeral_retention "$entry" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" != true ]]; then
      outcome="$(scratch_budget_quarantine_remove "$entry" --keep-unproven-content)"
      echo "$outcome $entry"
      kept=$(( kept + 1 ))
      case "$outcome" in deferred:deadline-before-unit|kept:cursor-*) break ;; esac
    else
      echo "kept:unproven-content $entry"
      kept=$(( kept + 1 ))
    fi
    continue
  fi
  scanned=$(( scanned + 1 ))
  (( scanned % 25 == 0 )) && echo "progress: scanned=${scanned} kept=${kept} removable=${removable} removed=${removed}"
  if [[ -L "$entry" ]]; then echo "kept:symlink $entry"; kept=$(( kept + 1 )); continue; fi
  if [[ ! -d "$entry" ]]; then continue; fi
  if [[ -z "$BUDGET_PCT" ]]; then
  dir_mtime="$(stat -f '%m' "$entry" 2>/dev/null || stat -c '%Y' "$entry" 2>/dev/null)"
  if [[ "$dir_mtime" =~ ^[0-9]+$ ]] && (( dir_mtime > floor_epoch )); then
    mtime="$dir_mtime"
  else
    mtime="$(scratch_budget_content_mtime "$entry" 2>/dev/null)"
  fi
  if ! [[ "$mtime" =~ ^[0-9]+$ ]]; then
    echo "kept:mtime-unmeasurable $entry"; kept=$(( kept + 1 )); continue
  fi
  if (( mtime > floor_epoch )); then
    echo "kept:recent-activity $entry (age $(( (now - mtime) / 3600 ))h < ${MIN_HOURS}h)"
    kept=$(( kept + 1 )); continue
  fi
  fi
  if ! reason="$(safety_gate "$entry" 2>/dev/null)"; then
    echo "kept:${reason:-safety} $entry"; kept=$(( kept + 1 )); continue
  fi
  kb="$(deletion_size_kb "$entry" 2>/dev/null)" || kb=0
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  # Manual prioritization must not alter the automatic retention/cursor queue.
  if [[ "$SCRATCH_AUTOMATIC" != 1 && "${DISK_MAGICIAN_SCRATCH_MIN_KB:-0}" =~ ^[0-9]+$ ]] && (( 10#${DISK_MAGICIAN_SCRATCH_MIN_KB:-0} > 0 && kb < 10#${DISK_MAGICIAN_SCRATCH_MIN_KB:-0} )); then
    kept=$(( kept + 1 ))
    continue
  fi
  if [[ -n "$BUDGET_PCT" ]]; then
    # A preview subtracts what it would have freed; a clean rechecks the
    # canonical usage/quota identity before each possible eviction.
    if [[ "$DRY_RUN" == true ]]; then
      budget_now=$(( budget_used - planned_kb * 1024 ))
    else
      budget_pair="$(scratch_usage_pair)" || { budget_stop=measurement-unavailable; break; }
      read -r budget_now budget_quota_now <<<"$budget_pair"
      [[ "$budget_quota_now" == "$budget_quota" ]] || { budget_stop=measurement-unavailable; break; }
    fi
    if (( budget_now * 100 <= budget_quota * BUDGET_PCT )); then
      budget_stop=target-reached; break
    fi
  fi
  if (( MAX_KB > 0 && planned_kb + removed_kb + kb > MAX_KB )); then
    echo "capped:max-gib $entry ($(( kb / 1024 )) MB) — rerun with --max-gib to raise"
    capped=1
    continue
  fi
  automatic_logged=false
  if [[ "$SCRATCH_AUTOMATIC" == 1 ]]; then
    if [[ "$DRY_RUN" != true ]]; then
      if [[ "$AVAILABLE_FLOOR" == true ]]; then
        scratch_available="$(scratch_available_bytes)" || { echo skipped:measurement-unavailable; exit 75; }
        if (( scratch_available >= 50 * 1024 * 1024 * 1024 )); then
          echo "skipped:available-floor:$scratch_available"
          break
        fi
      fi
      outcome="$(scratch_budget_quarantine_remove "$entry")"
      automatic_logged=true
    else
      preview_args=(--kind ephemeral)
      [[ -n "$ACT_DEADLINE_AT" ]] && preview_args+=(--deadline-at "$ACT_DEADLINE_AT")
      auto_verdict="$(artifact_removal_verdict "$entry" "${preview_args[@]}")"
      case "$auto_verdict" in
        remove) outcome=would-remove:remove ;;
        *) outcome="$auto_verdict" ;;
      esac
    fi
  else
    outcome="$(verdict_and_maybe_remove "$entry")"
  fi
  case "$outcome" in
    removed:*)
      [[ "$automatic_logged" == true ]] || deletion_log_removal "$entry" "$kb" "${outcome#removed:}${RECENCY_SPEC:+:recency=$RECENCY_SPEC}"
      removed=$(( removed + 1 )); removed_kb=$(( removed_kb + kb ))
      [[ -n "$BUDGET_PCT" ]] && lru_priors+="${outcome#removed:scratch-lru:}"$'\n'
      echo "$outcome $entry (${kb} KB)" ;;
    would-remove:*)
      removable=$(( removable + 1 )); planned_kb=$(( planned_kb + kb ))
      [[ -n "$BUDGET_PCT" ]] && lru_priors+="${outcome#would-remove:}"$'\n'
      echo "$outcome $entry (${kb} KB)" ;;
    kept:lease-busy)
      kept=$(( kept + 1 ))
      busy_streak=$(( busy_streak + 1 ))
      echo "$outcome $entry"
      if [[ "$SCRATCH_AUTOMATIC" == 1 ]]; then
        echo "skipped:lease-busy (registry lock held by a producer; rerun when the sweeper finishes)"
        budget_stop=lease-busy; break
      fi
      if (( busy_streak >= 10 )); then
        echo "skipped:lease-busy (registry lock held by a producer; rerun when the sweeper finishes)"
        budget_stop=lease-busy; break
      fi
      continue ;;
    *)
      busy_streak=0
      kept=$(( kept + 1 ))
      echo "$outcome $entry" ;;
  esac
  case "$outcome" in
    deferred:deadline-before-unit|kept:cursor-*) budget_stop=deferred; break ;;
  esac
  busy_streak=0
done < <(
  if [[ -n "$BUDGET_PCT" ]]; then
    sort -z -t $'\t' -k1,1n "$LRU_LIST" | while IFS= read -r -d '' _row; do printf '%s\0' "${_row#*$'\t'}"; done
  else
  for candidate in ${candidates[@]+"${candidates[@]}"}; do printf '%s\0' "$candidate"; done
  fi
)
fi
[[ -n "$LRU_LIST" ]] && rm -f "$LRU_LIST"

echo "=== Summary ==="
data_free_after_bytes="$(data_volume_free_bytes 2>/dev/null || echo unknown)"
if [[ "$data_free_before_bytes" =~ ^[0-9]+$ && "$data_free_after_bytes" =~ ^[0-9]+$ ]]; then
  data_free_delta_bytes=$(( data_free_after_bytes - data_free_before_bytes ))
else
  data_free_delta_bytes=unknown
fi
printf 'scanned=%s kept=%s removable=%s removed=%s eligible_estimate=%s candidate_size_estimate_kb=%s deletion_size_estimate_kb=%s deferred_candidates=%s data_free_before_bytes=%s data_free_after_bytes=%s data_free_interval_delta_bytes=%s\n' \
  "$scanned" "$kept" "$removable" "$removed" "$removable" "$(( planned_kb + removed_kb ))" "$removed_kb" "$DEFERRED_CANDIDATES" \
  "$data_free_before_bytes" "$data_free_after_bytes" "$data_free_delta_bytes"
echo "keep_count=$kept"
(( capped )) && echo "capped: at least one candidate skipped by --max-gib ${MAX_GIB}"
if [[ -n "$BUDGET_PCT" ]]; then
  _estimated_after_bytes=$(( budget_used - planned_kb * 1024 ))
  ((_estimated_after_bytes < 0)) && _estimated_after_bytes=0
  _estimated_gap_bytes=$((_estimated_after_bytes - budget_target_bytes))
  ((_estimated_gap_bytes < 0)) && _estimated_gap_bytes=0
  if [[ "$DRY_RUN" == true ]]; then
    echo "budget_unmet=not-run projected_budget_unmet=unknown projected_gap_bytes=${_estimated_gap_bytes} (candidate-size estimate; physical allocation may be shared)"
    echo "lru: stop=${budget_stop:-preview-complete} would_evict=$removable"
  else
    budget_pair_after="$(scratch_usage_pair 2>/dev/null)" || budget_pair_after=""
    if [[ "$budget_pair_after" =~ ^[0-9]+\ [0-9]+$ ]]; then
      read -r budget_after_bytes budget_after_quota <<<"$budget_pair_after"
      if [[ "$budget_after_quota" != "$budget_quota" ]]; then
        budget_unmet_status=unknown
        budget_reason=quota-changed
      else
        budget_gap_after_bytes=$(( budget_after_bytes - budget_target_bytes ))
        (( budget_gap_after_bytes < 0 )) && budget_gap_after_bytes=0
        if (( budget_after_bytes * 100 <= budget_quota * BUDGET_PCT )); then
          budget_unmet_status=0
          budget_reason=target-reached
        elif [[ -z "$budget_stop" || "$budget_stop" == candidates-exhausted ]] && (( ! capped )); then
          budget_unmet_status=1
          budget_reason=safe-candidates-exhausted
        else
          budget_unmet_status=unknown
          budget_reason="incomplete-${budget_stop:-scan}"
        fi
      fi
    else
      budget_unmet_status=unknown
      budget_reason=post-measurement-unavailable
      budget_gap_after_bytes=unknown
    fi
    echo "budget_unmet=${budget_unmet_status} projected_budget_unmet=not-applicable target_reached=$([[ "$budget_unmet_status" == 0 ]] && echo true || echo false) reason=${budget_reason} budget_gap_before_bytes=${budget_gap_before_bytes} budget_gap_after_bytes=${budget_gap_after_bytes:-unknown}"
    echo "lru: stop=${budget_reason} evicted=$removed not_pushed_or_dirty=$(printf '%s' "$lru_priors" | grep -cE 'kept:(not-pushed|dirty)')"
    printf '%s' "$lru_priors" | sort | uniq -c | sed -E 's/^ *([0-9]+) (.*)$/lru: prior_verdict \2=\1/'
    if [[ "$budget_unmet_status" == unknown ]]; then
      echo "deferred:budget-result-unmeasurable reason=${budget_reason}"
      exit 75
    fi
    if [[ "$budget_unmet_status" == 1 ]]; then
      echo "partial:budget-target-unmet"
      exit 75
    fi
  fi
fi
if (( MEASUREMENT_INCOMPLETE )); then
  echo "deferred:measurement-unfinished"
  exit 75
fi
exit 0
