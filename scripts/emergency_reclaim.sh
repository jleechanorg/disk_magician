#!/usr/bin/env bash
# emergency_reclaim.sh — one-off emergency reclaim (bead disk_magician-kyo9).
#
# Usage: emergency_reclaim.sh [--target-gb N] [--max-age-hours H] [--dry-run] [--include-worktrees]
#
# Runs the tmp lane then the Scratch lane under ONE scratch-lock hold, stepping the
# age floor down H -> 12 -> 6 -> 2 hours (never below 2 h) and stopping the moment
# measured host free space reaches the target. Running the command without --dry-run
# is the operator's approval: LARGE_TMP_APPROVED / SCRATCH_TOP_LEVEL_APPROVED (and
# WORKTREE_APPROVED with --include-worktrees) are set for the cleaner children only.
#
# Exit: 0 target met, 3 target_unmet (0 B freed never reads as success), 2 usage,
# 75 scratch lock held.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/scratch_lock.sh
source "$SCRIPT_DIR/lib/scratch_lock.sh"

MIN_FLOOR_HOURS=2
DEFAULT_TARGET_GB=40
TARGET_GB="$DEFAULT_TARGET_GB"
MAX_AGE_HOURS=24
DRY_RUN=false
INCLUDE_WORKTREES=false
ORIG_ARGS=("$@")

usage() {
  cat <<EOF
Usage: $(basename "$0") [--target-gb N] [--max-age-hours H] [--dry-run] [--include-worktrees]

Emergency reclaim of tmp + Scratch under one lock hold. The age floor starts at
--max-age-hours (default 24) and steps down 12, 6, 2 hours; it never goes below 2 h.
Stops as soon as host free space reaches --target-gb (default ${DEFAULT_TARGET_GB}).
  --dry-run            Run the cleaners in dry-run mode; print projected bytes per floor step.
  --include-worktrees  Last step: cleanup-worktrees with WORKTREE_APPROVED=1.
Exit 3 (target_unmet) when the target is not met after the 2 h step.
EOF
}

while (($#)); do
  case "$1" in
    --target-gb)   [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; TARGET_GB=$((10#$2)); shift 2 ;;
    --target-gb=*) v="${1#*=}"; [[ "$v" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; TARGET_GB=$((10#$v)); shift ;;
    --max-age-hours)   [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; MAX_AGE_HOURS=$((10#$2)); shift 2 ;;
    --max-age-hours=*) v="${1#*=}"; [[ "$v" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }; MAX_AGE_HOURS=$((10#$v)); shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --include-worktrees) INCLUDE_WORKTREES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "emergency: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
((TARGET_GB >= 1)) || { echo "emergency: --target-gb must be >= 1" >&2; exit 2; }

# Hard minimum: a requested ceiling below 2 h is raised to 2 h.
((MAX_AGE_HOURS < MIN_FLOOR_HOURS)) && MAX_AGE_HOURS=$MIN_FLOOR_HOURS

# Cleaner overrides are test-only so a stray env var can never aim this at other scripts.
CLEANER_DIR="$SCRIPT_DIR"
if [[ -n "${DISKM_EMERGENCY_CLEANER_DIR:-}" ]]; then
  if [[ "${DISK_MAGICIAN_TEST_CONTEXT:-}" != "1" || -z "${DISK_MAGICIAN_TEST_SANDBOX:-}" ]]; then
    echo "emergency: cleaner override refused outside the test sandbox" >&2
    exit 2
  fi
  CLEANER_DIR="$DISKM_EMERGENCY_CLEANER_DIR"
fi

# One lock hold for every lane. Dry-run mutates nothing and skips the lock, as the cleaners do.
if [[ "$DRY_RUN" != true ]]; then
  export DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS="${DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS:-120}"
  scratch_lock_acquire "emergency" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} || exit $?
fi

# Floor steps: MAX_AGE_HOURS, then each of 12/6/2 strictly below it.
steps=("$MAX_AGE_HOURS")
for h in 12 6 2; do ((h < MAX_AGE_HOURS)) && steps+=("$h"); done

DATA_ROOT="${DISKM_EMERGENCY_DATA_ROOT:-}"
if [[ -z "$DATA_ROOT" ]]; then
  if [[ -d /System/Volumes/Data ]]; then DATA_ROOT=/System/Volumes/Data; else DATA_ROOT=/; fi
fi
SCRATCH_ROOT=""
if [[ -n "${DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE:-}" ]]; then
  SCRATCH_ROOT="$DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE"
else
  SCRATCH_ROOT="$("${DISK_MAGICIAN_DISKM_BIN:-$SCRIPT_DIR/../disk_magician.sh}" volume path scratch --for-reclaim 2>/dev/null || true)"
fi

# free_bytes PATH -> available bytes (empty when df cannot answer).
free_bytes() {
  local kb
  kb="$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$kb" =~ ^[0-9]+$ ]] && echo $((kb * 1024))
}
gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.2f", b / 1073741824 }'; }

TARGET_BYTES=$((TARGET_GB * 1073741824))
host_free="$(free_bytes "$DATA_ROOT")"
if [[ -z "$host_free" ]]; then
  echo "emergency: cannot measure free space on $DATA_ROOT; refusing to guess" >&2
  exit 1
fi
start_free="$host_free"
scratch_free_start=""
[[ -n "$SCRATCH_ROOT" && -d "$SCRATCH_ROOT" ]] && scratch_free_start="$(free_bytes "$SCRATCH_ROOT")"

echo "=== EMERGENCY RECLAIM ($([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo CLEAN)) ==="
echo "target=${TARGET_GB}GiB free on $DATA_ROOT; free_now=$(gib "$host_free")GiB; floors(h)=${steps[*]}; min_floor=${MIN_FLOOR_HOURS}h"
if frontier_pids="$(pgrep -f -- 'disk_frontier_scan\.(py|sh)' 2>/dev/null | grep -v -x "$$" | tr '\n' ' ')" && [[ -n "${frontier_pids// }" ]]; then
  echo "frontier: scan running (pid ${frontier_pids% }); left running — emergency reclaim does not start, stop or wait on scans"
fi

if ((host_free >= TARGET_BYTES)) && [[ "$DRY_RUN" != true ]]; then
  echo "freed_so_far 0.00GiB / ${TARGET_GB}GiB"
  echo "result: target_met (already at or above target; nothing removed)"
  exit 0
fi

# run_cleaner LABEL CMD... — runs a cleaner as a child that may reuse this lock hold
# (the lock guard accepts only the exact PID that inherited the descriptor), echoes
# its output, and leaves the combined output in LAST_OUT.
LAST_OUT=""
run_cleaner() {
  local label="$1"; shift
  LAST_OUT="$(bash -c 'export DISK_MAGICIAN_SCRATCH_LOCK_PID=$$; exec "$@"' _ "$@" 2>&1)"
  local rc=$?
  [[ -n "$LAST_OUT" ]] && sed "s/^/  [$label] /" <<<"$LAST_OUT"
  echo "  [$label] rc=$rc"
  return $rc
}

# Projected KiB from a cleaner's dry-run output (scratch: candidate_size_estimate_kb; tmp: "Total freed: N KB").
projected_kb() {
  local kb
  kb="$(grep -o 'candidate_size_estimate_kb=[0-9]*' <<<"$LAST_OUT" | tail -1 | cut -d= -f2)"
  [[ -n "$kb" ]] || kb="$(grep -o 'Total freed: [0-9]* KB' <<<"$LAST_OUT" | tail -1 | grep -o '[0-9]*')"
  echo "${kb:-0}"
}

TMP_FREED=0; SCRATCH_FREED=0; WT_FREED=0
FLOOR_REACHED=""; met=false

for hours in "${steps[@]}"; do
  FLOOR_REACHED="$hours"
  minutes=$((hours * 60))
  echo "--- floor ${hours}h (${minutes} min) ---"
  export DISK_MAGICIAN_AGE_FLOOR_MINUTES="$minutes"
  # Existing scratch-prune override (honoured for 12..23 h) so the 12 h step bites before
  # the shared age-floor contract lands in every cleaner.
  if ((hours >= 12 && hours < 24)); then export DISK_MAGICIAN_SCRATCH_FLOOR_HOURS="$hours"; else unset DISK_MAGICIAN_SCRATCH_FLOOR_HOURS; fi

  # Lane 1: tmp.
  tmp_args=(--aged --budget-floor-minutes "$minutes")
  if [[ "$DRY_RUN" == true ]]; then
    run_cleaner tmp "$CLEANER_DIR/cleanup_tmp.sh" --dry-run "${tmp_args[@]}"
    echo "projected tmp ${hours}h: $(gib $(($(projected_kb) * 1024)))GiB"
  else
    before="$(free_bytes "$DATA_ROOT")"
    LARGE_TMP_APPROVED=1 run_cleaner tmp "$CLEANER_DIR/cleanup_tmp.sh" --clean "${tmp_args[@]}"
    after="$(free_bytes "$DATA_ROOT")"; host_free="$after"
    d=$((after - before)); ((d < 0)) && d=0; TMP_FREED=$((TMP_FREED + d))
    echo "freed_so_far $(gib $((host_free - start_free)))GiB / ${TARGET_GB}GiB (tmp lane ${hours}h: +$(gib $d)GiB)"
    if ((host_free >= TARGET_BYTES)); then met=true; break; fi
  fi

  # Lane 2: Scratch. Incremental: cap each pass at the remaining gap so it stops at the target.
  if [[ -z "$SCRATCH_ROOT" ]]; then
    echo "  [scratch] skipped:unavailable (no registered Scratch volume)"
  elif [[ "$DRY_RUN" == true ]]; then
    run_cleaner scratch "$CLEANER_DIR/cleanup_scratch_top_level.sh" --dry-run --min-hours "$hours" --max-gib 0
    echo "projected scratch ${hours}h: $(gib $(($(projected_kb) * 1024)))GiB"
  else
    gap=$((TARGET_BYTES - host_free)); gap_gib=$(((gap + 1073741823) / 1073741824))
    before="$(free_bytes "$DATA_ROOT")"
    SCRATCH_TOP_LEVEL_APPROVED=1 run_cleaner scratch "$CLEANER_DIR/cleanup_scratch_top_level.sh" \
      --clean --min-hours "$hours" --max-gib "$gap_gib"
    after="$(free_bytes "$DATA_ROOT")"; host_free="$after"
    d=$((after - before)); ((d < 0)) && d=0; SCRATCH_FREED=$((SCRATCH_FREED + d))
    echo "freed_so_far $(gib $((host_free - start_free)))GiB / ${TARGET_GB}GiB (scratch lane ${hours}h: +$(gib $d)GiB)"
    if ((host_free >= TARGET_BYTES)); then met=true; break; fi
  fi
done

# Optional last step. Worktree cleaners run one at a time, only here, never concurrently.
if [[ "$INCLUDE_WORKTREES" == true && "$met" != true ]]; then
  echo "--- worktrees (last step) ---"
  if [[ "$DRY_RUN" == true ]]; then
    run_cleaner worktrees "$CLEANER_DIR/cleanup_worktrees.sh" --dry-run
  else
    before="$(free_bytes "$DATA_ROOT")"
    WORKTREE_APPROVED=1 run_cleaner worktrees "$CLEANER_DIR/cleanup_worktrees.sh" --clean
    after="$(free_bytes "$DATA_ROOT")"; host_free="$after"
    d=$((after - before)); ((d < 0)) && d=0; WT_FREED=$d
    echo "freed_so_far $(gib $((host_free - start_free)))GiB / ${TARGET_GB}GiB (worktrees: +$(gib $d)GiB)"
    ((host_free >= TARGET_BYTES)) && met=true
  fi
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "result: dry_run (no data removed; projections above are per-lane candidate estimates, not df-measured)"
  exit 0
fi

host_free="$(free_bytes "$DATA_ROOT")"
scratch_free_end=""
[[ -n "$SCRATCH_ROOT" && -d "$SCRATCH_ROOT" ]] && scratch_free_end="$(free_bytes "$SCRATCH_ROOT")"
echo "=== EMERGENCY RECEIPT (bytes measured by df before/after each lane) ==="
echo "host_free_before=$(gib "$start_free")GiB host_free_after=$(gib "$host_free")GiB freed_total=$(gib $((host_free - start_free)))GiB target=${TARGET_GB}GiB floor_reached=${FLOOR_REACHED}h"
echo "lane tmp=$(gib "$TMP_FREED")GiB lane scratch=$(gib "$SCRATCH_FREED")GiB lane worktrees=$(gib "$WT_FREED")GiB"
[[ -n "$scratch_free_start" && -n "$scratch_free_end" ]] && echo "scratch_volume_free_before=$(gib "$scratch_free_start")GiB scratch_volume_free_after=$(gib "$scratch_free_end")GiB"
if [[ "$met" == true || "$host_free" -ge "$TARGET_BYTES" ]]; then
  echo "result: target_met"
  exit 0
fi
echo "result: target_unmet (free $(gib "$host_free")GiB < ${TARGET_GB}GiB after the ${FLOOR_REACHED}h step; hard minimum ${MIN_FLOOR_HOURS}h)"
exit 3
