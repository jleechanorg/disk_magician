#!/usr/bin/env bash
# pressure_sweep.sh — Free-space-gated sweep runner.
#
# Addresses beads jleechan-6xzf (/tmp scratch sawtooths to 97G/day against a
# daily 04:05 sweep) and jleechan-etjw (Colima re-inflates ~30G/hr against
# sparse prunes): a cadence gap between how fast these two trees grow and how
# often the existing daily/weekly sweepers run. This script is a THRESHOLD
# trigger meant to run frequently (every 30min via launchd, tightened from 2h
# on 2026-08-01 after a 46->13.7 GiB free-space swing in 90 min blew past the
# old 2h cadence) — it only does real work when free space has actually
# dropped below threshold, so idle fires are a single log line and never
# touch the work lock below.
#
# Never runs anything beyond cleanup_tmp.sh (--clean [--large]),
# cleanup_colima.sh --clean, and cleanup_code_sign_clones.sh --clean — all
# three scripts own their own safety semantics (mtime thresholds, lsof
# gates, docker-prune semantics preserving in-use containers/volumes,
# safety.local.json protected_live_paths). When triggered, passes --large
# to cleanup_tmp and sets
# LARGE_TMP_APPROVED=1 for the pressure path only (bead jleechan-nkzj), and
# TMP_WORKTREES_APPROVED=1 for the same pressure-only path (roadmap
# 2026-07-22-disk-regrowth-rootcause.md §3.2 — without it, every
# wt_*/worktree_* dir under /private/tmp is structurally un-sweepable even
# under critical pressure). Under pressure, passes LARGE_TMP_ACTIVE_HOURS=4
# and LARGE_TMP_ARCHIVE_RETENTION_HOURS=4 (configurable via
# DISK_MAGICIAN_PRESSURE_TMP_ACTIVE_HOURS / DISK_MAGICIAN_PRESSURE_TMP_ARCHIVE_RETENTION_HOURS)
# to accelerate eviction of quarantined scratch archives without waiting 24h.
# cleanup_tmp.sh's own mtime/lsof/protected-root gates still apply unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RECEIPT_HELPER="$SCRIPT_DIR/job_receipt.py"

THRESHOLD_GB="${DISK_MAGICIAN_PRESSURE_THRESHOLD_GB:-40}"
# Size-budget scratch eviction (bead disk_magician-d45): passed through to
# cleanup_tmp.sh's --budget-gb so a pressure sweep reclaims young-but-stale
# (0-24h) scratch that the 4h/24h age-only gates above structurally cannot
# see. Default 0 (disabled): unlike --large (archive, reversible within its
# retention window), budget mode does an immediate, permanent `rm -rf` on
# every scratch root (/private/tmp, /tmp, DARWIN_USER_TEMP_DIR) once past a
# 2h-minimum floor -- a materially more aggressive default than anything
# else this script runs unattended. Same opt-in-gate pattern this repo
# already uses for LARGE_TMP_APPROVED / WORKTREE_APPROVED: an operator (or
# the launchd plist) sets DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB
# explicitly to activate it.
SCRATCH_BUDGET_GB="${DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB:-0}"
SCRATCH_BUDGET_FLOOR_MINUTES="${DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_FLOOR_MINUTES:-120}"
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
LOCK_DIR="$STATE_DIR/pressure_sweep.lock"
LOCK_TTL_SEC=3600
LOG_FILE="${DISK_MAGICIAN_PRESSURE_LOG:-$HOME/Library/Logs/disk-magician-pressure-sweep.log}"
STEP_TIMEOUT=600
DRY_RUN=false
# Testing hook: skip the real `df` read and use a fabricated free-GB value
# instead, so the triggered path can be exercised deterministically without
# depending on the box's actual disk state at test time.
FREE_GB_OVERRIDE="${DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE:-}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--threshold-gb N] [--dry-run]

Free-space-gated sweep: if free space (df /System/Volumes/Data) is >=
--threshold-gb (default: ${THRESHOLD_GB}; env DISK_MAGICIAN_PRESSURE_THRESHOLD_GB),
exit immediately (one log line, no work). Otherwise run, in order:
  1. scripts/cleanup_tmp.sh --clean --large --budget-gb N (mtime + large
     /private/tmp + size-budget eviction of young-but-stale scratch;
     LARGE_TMP_APPROVED=1; budget default ${SCRATCH_BUDGET_GB} GiB, env
     DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB, 0 disables)
  2. scripts/cleanup_colima.sh --clean (docker-prune semantics + fstrim)
  3. scripts/cleanup_code_sign_clones.sh --clean (per-launch Chrome/Aside/
     CodexBar code_sign_clone reclaim; CODE_SIGN_CLONES_APPROVED=1)
each under a ${STEP_TIMEOUT}s timeout, logging free-GB before/after to
${LOG_FILE}.

Options:
  --threshold-gb N  Free-space threshold in GB (default: ${THRESHOLD_GB})
  --dry-run         Pass --dry-run (not --clean) to all 3 sub-scripts instead —
                     lets the triggered path be verified with zero deletions.
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold-gb) THRESHOLD_GB="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() {
  local line
  line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE"
}

free_gb() {
  if [[ -n "$FREE_GB_OVERRIDE" ]]; then
    echo "$FREE_GB_OVERRIDE"
    return
  fi
  local check_path="/"
  if [[ "$OSTYPE" == "darwin"* ]] && df "/System/Volumes/Data" >/dev/null 2>&1; then
    check_path="/System/Volumes/Data"
  fi
  ( df -kP "$check_path" 2>/dev/null || true ) | awk 'NR==2{print int($4/1024/1024)}'
}

TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then TIMEOUT_CMD="gtimeout"; fi
run_step_timeout() {
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$STEP_TIMEOUT" "$@"
  else
    "$@"
  fi
}

current_free_gb="$(free_gb || echo "")"

if [[ -z "$current_free_gb" ]]; then
  log "pressure_sweep: could not read free space — no-op (fail safe, no cleanup attempted)."
  if ! python3 "$RECEIPT_HELPER" finish --job pressure_sweep \
    --outcome blocked_safety \
    --reason "could not read free space" \
    --safety '{"status": "blocked_safety", "reason": "could not read free space"}' \
    --precondition '{"free_gb": null}'; then
    log "ERROR: failed to record blocked_safety receipt"
  fi
  exit 0
fi

# Colima-size ceiling (2026-07-19 gap analysis): Colima's sparse disk can
# balloon from CI-runner churn while host free space stays comfortably above
# the pressure threshold, so a free-space-only gate never fires until the
# host is already in trouble. When Colima's allocated size crosses the
# ceiling, run ONLY the colima step proactively. 0 disables. Override via
# DISK_MAGICIAN_COLIMA_CEILING_GB; DISK_MAGICIAN_COLIMA_GB_OVERRIDE is the
# deterministic test hook (like FREE_GB_OVERRIDE above).
COLIMA_CEILING_GB="${DISK_MAGICIAN_COLIMA_CEILING_GB:-35}"
COLIMA_GB_OVERRIDE="${DISK_MAGICIAN_COLIMA_GB_OVERRIDE:-}"
du_size_gb() {
  local path="$1" output rc kb
  if output="$(run_step_timeout du -skx "$path" 2>/dev/null)"; then
    :
  else
    rc=$?
    log "pressure_sweep: size measurement failed or timed out for $path (du rc=$rc)."
    return 1
  fi
  if [[ "$output" == *$'\n'* || ! "$output" =~ ^[0-9]+[[:space:]]+.+$ ]]; then
    log "pressure_sweep: size measurement returned invalid output for $path."
    return 1
  fi
  kb="${output%%[[:space:]]*}"
  awk -v kb="$kb" 'BEGIN{if(kb !~ /^[0-9]+$/) exit 1; print int(kb/1024/1024)}'
}

colima_gb() {
  if [[ -n "$COLIMA_GB_OVERRIDE" ]]; then
    echo "$COLIMA_GB_OVERRIDE"
    return
  fi
  [[ -d "$HOME/.colima" ]] || { echo 0; return; }
  du_size_gb "$HOME/.colima"
}

# /private/tmp size ceiling (2026-07-20 gap analysis, bead jleechan-zx7g): AO
# /private/tmp PR-scratch churn (~40 GiB/day historical) is only cleaned when
# free < the pressure threshold or by the daily 04:05 sweep — between those,
# scratch accumulates while host free space and Colima both stay healthy, so
# neither existing gate fires. When /private/tmp crosses this ceiling while
# free space is healthy, run a tmp-only sweep proactively. 0 disables.
# Override via DISK_MAGICIAN_TMP_CEILING_GB; DISK_MAGICIAN_TMP_GB_OVERRIDE is
# the deterministic test hook (like COLIMA_GB_OVERRIDE above).
TMP_CEILING_GB="${DISK_MAGICIAN_TMP_CEILING_GB:-30}"
TMP_GB_OVERRIDE="${DISK_MAGICIAN_TMP_GB_OVERRIDE:-}"
tmp_gb() {
  if [[ -n "$TMP_GB_OVERRIDE" ]]; then
    echo "$TMP_GB_OVERRIDE"
    return
  fi
  [[ -d "/private/tmp" ]] || { echo 0; return; }
  du_size_gb "/private/tmp"
}

# Bead disk_magician-mux: when the full colima step will not run, still do a
# cheap in-VM fstrim (cleanup_colima.sh --trim-only owns the datadisk-size
# gate, timeout, and never-restart contract). Failure is logged, never fatal.
colima_trim_only() {
  [[ -d "$HOME/.colima/_lima/_disks/colima" ]] || return 0
  local flag="--clean"
  [[ "$DRY_RUN" == true ]] && flag="--dry-run"
  local rc=0
  run_step_timeout "$REPO_ROOT/scripts/cleanup_colima.sh" --trim-only "$flag" >> "$LOG_FILE" 2>&1 || rc=$?
  [[ $rc -eq 0 ]] || log "pressure_sweep: colima trim-only FAILED or timed out (rc=${rc}) — continuing."
}

SWEEP_MODE="full"
below_threshold=$(awk -v f="$current_free_gb" -v t="$THRESHOLD_GB" 'BEGIN{print (f < t) ? "1" : "0"}')
if [[ "$below_threshold" != "1" ]]; then
  measurement_error=""
  if current_colima_gb="$(colima_gb)"; then
    :
  else
    current_colima_gb=""
    measurement_error="colima"
  fi
  over_colima_ceiling=0
  if [[ "$COLIMA_CEILING_GB" != "0" && -n "$current_colima_gb" ]]; then
    over_colima_ceiling=$(awk -v c="$current_colima_gb" -v t="$COLIMA_CEILING_GB" 'BEGIN{print (c >= t) ? "1" : "0"}')
  fi

  if current_tmp_gb="$(tmp_gb)"; then
    :
  else
    current_tmp_gb=""
    if [[ -n "$measurement_error" ]]; then measurement_error+=" and "; fi
    measurement_error+="/private/tmp"
  fi
  if [[ -n "$measurement_error" ]]; then
    log "pressure_sweep: cannot safely evaluate size ceilings because measurement failed for $measurement_error — no pruning or scratch eviction attempted; independent guarded trim-only may still run."
    colima_trim_only
    colima_precondition="$current_colima_gb"
    tmp_precondition="$current_tmp_gb"
    [[ -n "$colima_precondition" ]] || colima_precondition=null
    [[ -n "$tmp_precondition" ]] || tmp_precondition=null
    if ! python3 "$RECEIPT_HELPER" finish --job pressure_sweep \
      --outcome blocked_safety \
      --reason "disk size measurement failed: $measurement_error; pruning and scratch eviction blocked; trim-only may have been attempted under its own guards" \
      --safety "{\"status\": \"blocked_safety\", \"reason\": \"size measurement failed; pruning and scratch eviction blocked; independent trim-only may run under its own safety guards\"}" \
      --precondition "{\"free_gb\": $current_free_gb, \"threshold_gb\": $THRESHOLD_GB, \"colima_gb\": $colima_precondition, \"tmp_gb\": $tmp_precondition}"; then
      log "ERROR: failed to record blocked_safety receipt"
    fi
    exit 0
  fi
  over_tmp_ceiling=0
  if [[ "$TMP_CEILING_GB" != "0" && -n "$current_tmp_gb" ]]; then
    over_tmp_ceiling=$(awk -v c="$current_tmp_gb" -v t="$TMP_CEILING_GB" 'BEGIN{print (c >= t) ? "1" : "0"}')
  fi

  if [[ "$over_colima_ceiling" != "1" && "$over_tmp_ceiling" != "1" ]]; then
    log "pressure_sweep: free ${current_free_gb} GB >= threshold ${THRESHOLD_GB} GB — no-op."
    colima_trim_only
    if ! python3 "$RECEIPT_HELPER" finish --job pressure_sweep \
      --outcome skipped_threshold \
      --reason "free >= threshold and neither colima nor tmp ceiling exceeded" \
      --safety '{"status": "not_applicable", "reason": "threshold_not_reached_no_mutation", "delegated": false}' \
      --precondition "{\"free_gb\": ${current_free_gb}, \"threshold_gb\": ${THRESHOLD_GB}}"; then
      log "ERROR: failed to record skipped_threshold receipt"
    fi
    exit 0
  fi

  if [[ "$over_colima_ceiling" == "1" && "$over_tmp_ceiling" == "1" ]]; then
    SWEEP_MODE="full"
    log "pressure_sweep: free healthy (${current_free_gb} GB) but Colima ${current_colima_gb} GB >= ceiling ${COLIMA_CEILING_GB} GB AND /private/tmp ${current_tmp_gb} GB >= ceiling ${TMP_CEILING_GB} GB — full sweep triggered (dry_run=${DRY_RUN})."
  elif [[ "$over_colima_ceiling" == "1" ]]; then
    SWEEP_MODE="colima-only"
    log "pressure_sweep: free healthy (${current_free_gb} GB) but Colima ${current_colima_gb} GB >= ceiling ${COLIMA_CEILING_GB} GB — colima-only sweep triggered (dry_run=${DRY_RUN})."
  else
    SWEEP_MODE="tmp-only"
    log "pressure_sweep: free healthy (${current_free_gb} GB) but /private/tmp ${current_tmp_gb} GB >= ceiling ${TMP_CEILING_GB} GB — tmp-only sweep triggered (dry_run=${DRY_RUN})."
  fi
else
  log "pressure_sweep: free ${current_free_gb} GB < threshold ${THRESHOLD_GB} GB — sweep triggered (dry_run=${DRY_RUN})."
fi

# ────────── LOCK (mkdir-based, TTL 60min) — overlapping fires skip ──────────
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    date -u +%s > "$LOCK_DIR/acquired_at"
    return 0
  fi
  local lock_ts now age
  lock_ts="$(cat "$LOCK_DIR/acquired_at" 2>/dev/null || echo 0)"
  now="$(date -u +%s)"
  age=$(( now - lock_ts ))
  if (( age > LOCK_TTL_SEC )); then
    log "pressure_sweep: stale lock (${age}s old, TTL ${LOCK_TTL_SEC}s) — reclaiming."
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null && date -u +%s > "$LOCK_DIR/acquired_at" && return 0
    return 1
  fi
  return 1
}

if ! acquire_lock; then
  log "pressure_sweep: lock held by another run (< ${LOCK_TTL_SEC}s old) — skipping this fire."
  if ! python3 "$RECEIPT_HELPER" finish --job pressure_sweep \
    --outcome skipped_lock \
    --reason "lock held by another run" \
    --lock '{"held": true, "reason": "contention"}'; then
    log "ERROR: failed to record skipped_lock receipt"
  fi
  exit 0
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

RECEIPT_RUN_ID=$(python3 "$RECEIPT_HELPER" begin --job pressure_sweep --trigger "$SWEEP_MODE" --precondition "{\"free_gb\": ${current_free_gb}, \"threshold_gb\": ${THRESHOLD_GB}}") || {
  log "ERROR: failed to record receipt begin"
  exit 1
}

clean_flag="--clean"
[[ "$DRY_RUN" == true ]] && clean_flag="--dry-run"

STEP1_RC=0
STEP2_RC=0
STEP3_RC=0
STEP1_TIMEOUT=false
STEP2_TIMEOUT=false
STEP3_TIMEOUT=false

# ────────── STEP 1: cleanup_tmp.sh (--large when sweeping) ──────────
if [[ "$SWEEP_MODE" == "colima-only" ]]; then
  log "pressure_sweep: step 1/3 skipped (colima-only mode — host free space is healthy)."
else
before_gb="$(free_gb)"
log "pressure_sweep: step 1/3 cleanup_tmp.sh ${clean_flag} --large — free before: ${before_gb} GB"
pressure_active_hours="${LARGE_TMP_ACTIVE_HOURS:-${DISK_MAGICIAN_PRESSURE_TMP_ACTIVE_HOURS:-4}}"
pressure_archive_hours="${LARGE_TMP_ARCHIVE_RETENTION_HOURS:-${DISK_MAGICIAN_PRESSURE_TMP_ARCHIVE_RETENTION_HOURS:-4}}"
tmp_step_extra_args=(--large)
if [[ "$SCRATCH_BUDGET_GB" != "0" ]]; then
  tmp_step_extra_args+=(--budget-gb "$SCRATCH_BUDGET_GB" --budget-floor-minutes "$SCRATCH_BUDGET_FLOOR_MINUTES")
fi
if [[ "$DRY_RUN" != true ]]; then
  tmp_step=(env LARGE_TMP_APPROVED=1 TMP_WORKTREES_APPROVED=1 LARGE_TMP_ACTIVE_HOURS="$pressure_active_hours" LARGE_TMP_ARCHIVE_RETENTION_HOURS="$pressure_archive_hours" "$REPO_ROOT/scripts/cleanup_tmp.sh" "$clean_flag" "${tmp_step_extra_args[@]}")
else
  tmp_step=(env LARGE_TMP_ACTIVE_HOURS="$pressure_active_hours" LARGE_TMP_ARCHIVE_RETENTION_HOURS="$pressure_archive_hours" "$REPO_ROOT/scripts/cleanup_tmp.sh" "$clean_flag" "${tmp_step_extra_args[@]}")
fi
if run_step_timeout "${tmp_step[@]}" >> "$LOG_FILE" 2>&1; then
  after_gb="$(free_gb)"
  log "pressure_sweep: step 1/3 cleanup_tmp.sh done — free after: ${after_gb} GB"
else
  STEP1_RC=$?
  if [[ $STEP1_RC -eq 124 || $STEP1_RC -eq 137 ]]; then
    STEP1_TIMEOUT=true
  fi
  log "pressure_sweep: step 1/3 cleanup_tmp.sh FAILED or timed out (rc=${STEP1_RC}) — continuing to step 2."
fi
fi

# ────────── STEP 2: cleanup_colima.sh ──────────
if [[ "$SWEEP_MODE" == "tmp-only" ]]; then
  log "pressure_sweep: step 2/3 skipped (tmp-only mode — Colima under ceiling); running trim-only."
  colima_trim_only
else
before_gb="$(free_gb)"
log "pressure_sweep: step 2/3 cleanup_colima.sh ${clean_flag} — free before: ${before_gb} GB"
if run_step_timeout "$REPO_ROOT/scripts/cleanup_colima.sh" "$clean_flag" >> "$LOG_FILE" 2>&1; then
  after_gb="$(free_gb)"
  log "pressure_sweep: step 2/3 cleanup_colima.sh done — free after: ${after_gb} GB"
else
  STEP2_RC=$?
  if [[ $STEP2_RC -eq 124 || $STEP2_RC -eq 137 ]]; then
    STEP2_TIMEOUT=true
  fi
  log "pressure_sweep: step 2/3 cleanup_colima.sh FAILED or timed out (rc=${STEP2_RC})."
fi
fi

# ────────── STEP 3: cleanup_code_sign_clones.sh ──────────
before_gb="$(free_gb)"
log "pressure_sweep: step 3/3 cleanup_code_sign_clones.sh ${clean_flag} — free before: ${before_gb} GB"
if [[ "$DRY_RUN" != true ]]; then
  codesign_step=(env CODE_SIGN_CLONES_APPROVED=1 "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" "$clean_flag")
else
  codesign_step=("$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" "$clean_flag")
fi
if run_step_timeout "${codesign_step[@]}" >> "$LOG_FILE" 2>&1; then
  after_gb="$(free_gb)"
  log "pressure_sweep: step 3/3 cleanup_code_sign_clones.sh done — free after: ${after_gb} GB"
else
  STEP3_RC=$?
  if [[ $STEP3_RC -eq 124 || $STEP3_RC -eq 137 ]]; then
    STEP3_TIMEOUT=true
  fi
  log "pressure_sweep: step 3/3 cleanup_code_sign_clones.sh FAILED or timed out (rc=${STEP3_RC})."
fi

FINAL_FREE_GB="$(free_gb)"
OUTCOME="success"
REASON=""

STEP_STATUS="STEP1_RC=${STEP1_RC}, STEP1_TIMEOUT=${STEP1_TIMEOUT}, STEP2_RC=${STEP2_RC}, STEP2_TIMEOUT=${STEP2_TIMEOUT}, STEP3_RC=${STEP3_RC}, STEP3_TIMEOUT=${STEP3_TIMEOUT}"

if [[ "$STEP1_TIMEOUT" == true || "$STEP2_TIMEOUT" == true || "$STEP3_TIMEOUT" == true ]]; then
  OUTCOME="timeout"
  REASON="step execution timed out (${STEP_STATUS})"
elif [[ $STEP1_RC -ne 0 || $STEP2_RC -ne 0 || $STEP3_RC -ne 0 ]]; then
  OUTCOME="error"
  REASON="step execution failed (${STEP_STATUS})"
elif [[ "$DRY_RUN" == true ]]; then
  OUTCOME="success_noop"
  REASON="dry-run sweep completed without deletions (${STEP_STATUS})"
else
  OUTCOME="success"
  REASON="sweep completed (${STEP_STATUS})"
fi

POSTCONDITION="{\"free_gb_before\": ${current_free_gb:-null}, \"free_gb_after\": ${FINAL_FREE_GB:-null}, \"freed_bytes\": null}"
if [[ "$DRY_RUN" == true ]]; then
  SAFETY='{"status": "no_mutation", "reason": "dry-run sweep completed without deletions", "delegated": false}'
else
  SAFETY="{\"status\": \"delegated\", \"reason\": \"delegated to cleanup_tmp, cleanup_colima, and cleanup_code_sign_clones (${STEP_STATUS})\", \"delegated\": true, \"steps\": {\"step1_rc\": ${STEP1_RC}, \"step1_timeout\": ${STEP1_TIMEOUT}, \"step2_rc\": ${STEP2_RC}, \"step2_timeout\": ${STEP2_TIMEOUT}, \"step3_rc\": ${STEP3_RC}, \"step3_timeout\": ${STEP3_TIMEOUT}}}"
fi

if ! python3 "$RECEIPT_HELPER" finish --job pressure_sweep \
  --run-id "$RECEIPT_RUN_ID" \
  --outcome "$OUTCOME" \
  --reason "$REASON" \
  --safety "$SAFETY" \
  --postcondition "$POSTCONDITION"; then
  log "ERROR: failed to record receipt finish"
  exit 1
fi

log "pressure_sweep: sweep complete."
