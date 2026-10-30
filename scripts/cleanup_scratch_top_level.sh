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
#   2. candidates are direct children only: never the root, never a symlink, and
#      never a dot entry;
#   3. newest content mtime must be at least SCRATCH_PRUNE_MIN_HOURS old
#      (48 h floor; a larger value is honoured, a smaller one is clamped up);
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
# Usage: cleanup_scratch_top_level.sh [--dry-run|--clean] [--min-hours N] [--max-gib N]
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

MIN_HOURS_FLOOR=48
MIN_HOURS="${SCRATCH_PRUNE_MIN_HOURS:-$MIN_HOURS_FLOOR}"
MAX_GIB="${SCRATCH_PRUNE_MAX_GIB:-25}"
DRY_RUN=true

usage() {
  cat <<'USAGE'
Usage: cleanup_scratch_top_level.sh [--dry-run|--clean] [--min-hours N] [--max-gib N]

  --dry-run       Preview candidates and their C14 verdicts (default).
  --clean         Actually remove eligible candidates. Requires
                  SCRATCH_TOP_LEVEL_APPROVED=1.
  --min-hours N   Recency floor in hours (default 48; values below 48 are
                  clamped up to 48).
  --max-gib N     Per-run removal cap in GiB (default 25; 0 means no cap).

Removes only direct children of the registered Scratch volume root that C14
would remove, plus the two content classes kept:secret-like and
kept:unproven-content when SCRATCH_TOP_LEVEL_APPROVED=1 is set.
USAGE
}

# The lock supervisor re-executes this script, so it must receive the caller's
# original argv: the parse loop below consumes the flags.
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --min-hours) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; MIN_HOURS="$2"; shift 2 ;;
    --max-gib) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; MAX_GIB="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

# The recency floor may rise but never fall below the 48 h default: a caller
# cannot make this cleaner more aggressive than its documented contract.
[[ "$MIN_HOURS" =~ ^[0-9]+$ ]] || MIN_HOURS="$MIN_HOURS_FLOOR"
MIN_HOURS=$((10#$MIN_HOURS))
(( MIN_HOURS < MIN_HOURS_FLOOR )) && MIN_HOURS="$MIN_HOURS_FLOOR"
[[ "$MAX_GIB" =~ ^[0-9]+$ ]] || MAX_GIB=25
MAX_GIB=$((10#$MAX_GIB))
MAX_KB=$(( MAX_GIB * 1024 * 1024 ))

if [[ "$DRY_RUN" != true && "${SCRATCH_TOP_LEVEL_APPROVED:-0}" != "1" ]]; then
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
  if [[ -z "$root" || "$root" == "/" || ! -d "$root" || -L "$root" ]]; then
    echo "Refusing unsafe scratch root: '${root}'" >&2
    exit 2
  fi
  sandbox_guard_roots "$root"
else
  root="$("$diskm" volume path scratch --for-reclaim 2>/dev/null)" || { echo skipped:unavailable; exit 0; }
  [[ -n "$root" ]] || { echo skipped:unavailable; exit 0; }
  "$diskm" volume verify-mount "$root" >/dev/null 2>&1 || { echo skipped:unavailable; exit 0; }
fi
if [[ -z "$root" || "$root" == "/" || ! -d "$root" || -L "$root" ]]; then
  echo "Refusing unsafe scratch root: '${root}'" >&2
  exit 2
fi
root="${root%/}"

if [[ "$DRY_RUN" != true ]]; then
  # Serialize with volume reclaim and the tmp sweeps; the supervisor execs this
  # script again, so pass the original argv (never the consumed one).
  if (( ${#ORIG_ARGS[@]} )); then
    scratch_lock_acquire scratch_prune "${ORIG_ARGS[@]}" || exit $?
  else
    scratch_lock_acquire scratch_prune || exit $?
  fi
fi

now="$(date +%s)"
floor_epoch=$(( now - MIN_HOURS * 3600 ))
scanned=0 kept=0 removable=0 removed=0 planned_kb=0 removed_kb=0 capped=0 busy_streak=0

# verdict_and_maybe_remove <entry> — C14 gate plus the operator-approved content
# override. Prints the outcome token only: it runs in a command-substitution
# subshell, so no caller-visible state can travel back out of it.
verdict_and_maybe_remove() {
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
  local tries=20
  if [[ "$DRY_RUN" != true ]]; then
    while (( tries-- > 0 )); do
      if lease_registry_mutation_lock_enter; then break; fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    if (( tries < 0 )); then rm -f "$inv" "$binding"; echo kept:lease-busy; return 0; fi
  fi
  verdict="$(artifact_removal_verdict "$verdict_path" --inventory-out "$inv" 2>/dev/null)" || verdict=kept:check-failed
  case "$verdict" in
    remove) ;;
    kept:secret-like|kept:unproven-content)
      # Ordered-gate guarantee: C14 evaluates owner lease, live cwd, open files
      # and recent activity BEFORE these content checks, so both are already
      # proven for this candidate when this branch runs.
      if [[ "${SCRATCH_TOP_LEVEL_APPROVED:-0}" == "1" ]]; then
        override="$verdict"
        verdict=remove
      fi ;;
  esac
  if [[ "$verdict" != remove ]]; then
    [[ "$DRY_RUN" == true ]] || lease_registry_mutation_lock_exit || true
    rm -f "$inv" "$binding"
    echo "$verdict"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    rm -f "$inv" "$binding"
    echo "would-remove:${override:-remove}"
    return 0
  fi
  if [[ -n "$override" ]]; then
    # C14 writes --inventory-out only after it approves, so an overridden content
    # keep has no inventory yet. Build it with the same canonical builder the
    # verdict uses. c14_probe.py inventory reports success on stdout ("ok"), not
    # through its exit status, so the output is what is checked.
    if [[ "$(python3 "$SCRIPT_DIR/c14_probe.py" inventory "$entry" "$inv" 2>/dev/null)" != ok ]]; then
      lease_registry_mutation_lock_exit || true
      rm -f "$inv" "$binding"
      echo kept:check-failed
      return 0
    fi
    # The secrets probe short-circuits BEFORE c14_repos_ok inside the verdict, so
    # a tree that is both secret-like and a dirty/unpushed repository returns
    # kept:secret-like without ever having its repositories checked. An override
    # must therefore re-run the repository provenance gate explicitly, or it
    # would delete unpushed work.
    local repo_reason
    if ! repo_reason="$(c14_repos_ok "$entry" "$inv" "${ACT_DEADLINE_AT:-}")"; then
      lease_registry_mutation_lock_exit || true
      rm -f "$inv" "$binding"
      echo "${repo_reason:-kept:check-failed}"
      return 0
    fi
  fi
  out="$(python3 "$SCRIPT_DIR/quarantine_rename.py" remove "$entry" "$inv" "$binding" 2>/dev/null)" || out=kept:check-failed
  lease_registry_mutation_lock_exit || true
  rm -f "$inv" "$binding"
  case "$out" in
    removed:*)
      echo "removed:scratch-prune${override:+:$override}"
      return 0 ;;
    *) echo "${out:-kept:check-failed}"; return 0 ;;
  esac
}

echo "=== SCRATCH TOP-LEVEL PRUNE ($([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo CLEAN)) — floor ${MIN_HOURS}h, cap ${MAX_GIB} GiB ==="
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

for entry in "$root"/*; do
  if deadline_exceeded; then
    echo "deferred:deadline (stopped before $(basename "${entry%%/}"))"
    break
  fi
  [[ -e "$entry" || -L "$entry" ]] || continue
  base="${entry##*/}"
  case "$base" in .*) continue ;; esac
  scanned=$(( scanned + 1 ))
  (( scanned % 25 == 0 )) && echo "progress: scanned=${scanned} kept=${kept} removable=${removable} removed=${removed}"
  if [[ -L "$entry" ]]; then echo "kept:symlink $entry"; kept=$(( kept + 1 )); continue; fi
  if [[ ! -d "$entry" ]]; then continue; fi
  mtime="$(scratch_budget_content_mtime "$entry" 2>/dev/null)"
  if ! [[ "$mtime" =~ ^[0-9]+$ ]]; then
    echo "kept:mtime-unmeasurable $entry"; kept=$(( kept + 1 )); continue
  fi
  if (( mtime > floor_epoch )); then
    echo "kept:recent-activity $entry (age $(( (now - mtime) / 3600 ))h < ${MIN_HOURS}h)"
    kept=$(( kept + 1 )); continue
  fi
  if ! reason="$(safety_gate "$entry" 2>/dev/null)"; then
    echo "kept:${reason:-safety} $entry"; kept=$(( kept + 1 )); continue
  fi
  kb="$(deletion_size_kb "$entry" 2>/dev/null)" || kb=0
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  if (( MAX_KB > 0 && planned_kb + removed_kb + kb > MAX_KB )); then
    echo "capped:max-gib $entry ($(( kb / 1024 )) MB) — rerun with --max-gib to raise"
    capped=1
    continue
  fi
  outcome="$(verdict_and_maybe_remove "$entry")"
  case "$outcome" in
    removed:*)
      deletion_log_removal "$entry" "$kb" "${outcome#removed:}"
      removed=$(( removed + 1 )); removed_kb=$(( removed_kb + kb ))
      echo "$outcome $entry (${kb} KB)" ;;
    would-remove:*)
      removable=$(( removable + 1 )); planned_kb=$(( planned_kb + kb ))
      echo "$outcome $entry (${kb} KB)" ;;
    kept:lease-busy)
      kept=$(( kept + 1 ))
      busy_streak=$(( busy_streak + 1 ))
      echo "$outcome $entry"
      if (( busy_streak >= 3 )); then
        echo "skipped:lease-busy (registry lock held by a producer; rerun when the sweeper finishes)"
        break
      fi
      continue ;;
    *)
      busy_streak=0
      kept=$(( kept + 1 ))
      echo "$outcome $entry" ;;
  esac
  busy_streak=0
done

echo "=== Summary ==="
echo "scanned=${scanned} kept=${kept} removable=${removable} removed=${removed} planned_mb=$(( (planned_kb + removed_kb) / 1024 ))"
(( capped )) && echo "capped: at least one candidate skipped by --max-gib ${MAX_GIB}"
exit 0
