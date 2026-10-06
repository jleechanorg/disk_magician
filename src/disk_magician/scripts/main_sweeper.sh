#!/usr/bin/env bash
# main_sweeper.sh — Single unified maintenance, snapshot, and pressure-recovery runner.
#
# Consolidates fragmented launchd sweepers (pressure-sweep, tmp-scratch,
# colima-prune, claude-state, codex-vacuum, code-sign-clones, worktree-venvs,
# sweeper-health) into a single deterministic, prioritized execution pipeline.
#
# Pipeline phases:
#   Phase 1: Acquire exclusive run lock (prevents overlapping/flapping runs).
#   Phase 2: Snapshot & Ledger Recording (snapshot_commit.sh).
#   Phase 3: Pressure Reclaim (if available GB < THRESHOLD_GB, default 40 GB):
#            - cleanup_tmp.sh --clean --large (accelerated 4h scratch eviction)
#            - cleanup_code_sign_clones.sh --clean (evict detached browser code_sign_clones)
#            - colima in-VM fstrim (if active)
#   Phase 4: Canonical 6-Tier Routine Maintenance Stack:
#            - Tier 1: Developer Caches & Ephemeral Temp (cleanup_dev_caches.sh, cleanup_tmp.sh, cleanup_pr_scratch.sh, cleanup_llm_inspector.sh)
#            - Tier 2: Xcode & Simulator Caches (cleanup_xcode.sh)
#            - Tier 3: Container VM Reclaim (cleanup_colima.sh --clean + post_job_docker_prune.sh)
#            - Tier 4: Browser Sessions & Dedup (prune_aside_sessions.sh --clean)
#            - Tier 5: Agent State Compaction & Rotated Logs (cleanup_antigravity_brain.sh --clean, cleanup_codex_db.sh --clean, cleanup_supervisor_logs.sh --clean, cleanup_uv_cache.sh --clean)
#            - Tier 6: Dormant Worktree Venvs >=7d (cleanup_worktree_venvs.sh --clean) & Claude State >=7d (cleanup_claude_state.sh --clean)
#   Phase 5: Health & Ledger Freshness Verification (sweeper_health_check.sh).
#
# Defaults to live clean. Pass --dry-run for non-destructive preview.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/safety_lib.sh
if [[ -f "$SCRIPT_DIR/safety_lib.sh" ]]; then
  source "$SCRIPT_DIR/safety_lib.sh"
fi

DRY_RUN=false
THRESHOLD_GB="${DISK_MAGICIAN_PRESSURE_THRESHOLD_GB:-40}"
SKIP_SNAPSHOT=false
SKIP_ROUTINE="${DISK_MAGICIAN_MAIN_SWEEPER_SKIP_ROUTINE:-false}"
SKIP_HEALTH="${DISK_MAGICIAN_MAIN_SWEEPER_SKIP_HEALTH:-false}"
FREE_GB_OVERRIDE="${DISK_MAGICIAN_PRESSURE_FREE_GB_OVERRIDE:-}"
FORCE_ROUTINE=false
STEP_TIMEOUT=600

usage() {
  cat <<'EOF'
Usage: main_sweeper.sh [OPTIONS]

Single unified disk maintenance, snapshot, and pressure runner.

Options:
  --clean           Execute maintenance cleanups (default).
  --dry-run         Preview actions without deleting files.
  --threshold-gb N  Pressure threshold in GB below which accelerated eviction triggers (default: 40).
  --skip-snapshot   Skip Phase 2 snapshot & ledger recording.
  --force           Force execution even if lock is held or under abnormal conditions.
  -h, --help        Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean) DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --threshold-gb)
      [[ $# -ge 2 ]] || { echo "--threshold-gb requires a value" >&2; exit 2; }
      THRESHOLD_GB="$2"
      shift
      ;;
    --skip-snapshot) SKIP_SNAPSHOT=true ;;
    --skip-routine) SKIP_ROUTINE=true ;;
    --skip-health) SKIP_HEALTH=true ;;
    --force) FORCE_ROUTINE=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
LOCK_DIR="$STATE_DIR/main_sweeper.lock"
LOCK_TTL_SEC="${DISK_MAGICIAN_MAIN_SWEEPER_LOCK_TTL_SEC:-3600}"
LOG_FILE="${DISK_MAGICIAN_MAIN_SWEEPER_LOG:-$HOME/Library/Logs/disk-magician-main-sweeper.log}"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() {
  local line
  line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [main_sweeper] $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE"
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

free_gb() {
  if [[ -n "$FREE_GB_OVERRIDE" ]]; then
    echo "$FREE_GB_OVERRIDE"
    return 0
  fi
  local check_path="/"
  if [[ "$OSTYPE" == "darwin"* ]] && df "/System/Volumes/Data" >/dev/null 2>&1; then
    check_path="/System/Volumes/Data"
  fi
  ( df -kP "$check_path" 2>/dev/null || true ) | awk 'NR==2{print int($4/1024/1024)}'
}

RECEIPT_HELPER="$SCRIPT_DIR/job_receipt.py"

cleanup_lock() {
  local sig="${1:-0}"
  trap - EXIT HUP INT TERM
  rm -rf "$LOCK_DIR"
  if [[ "$sig" -ne 0 ]]; then
    exit "$((128 + sig))"
  fi
}

set_lock_traps() {
  trap 'cleanup_lock 0' EXIT
  trap 'cleanup_lock 1' HUP
  trap 'cleanup_lock 2' INT
  trap 'cleanup_lock 15' TERM
}

acquire_lock() {
  if [[ "$FORCE_ROUTINE" == true ]]; then
    log "Warning: --force specified, overriding existing lock."
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ > "$LOCK_DIR/pid"
      set_lock_traps
      return 0
    fi
  fi
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    set_lock_traps
    return 0
  fi
  local held_pid age
  held_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  age=$(( $(date +%s) - $(stat -f '%m' "$LOCK_DIR" 2>/dev/null || stat -c '%Y' "$LOCK_DIR" 2>/dev/null || date +%s) ))
  if [[ "$age" -gt "$LOCK_TTL_SEC" ]] && { [[ -z "$held_pid" ]] || ! kill -0 "$held_pid" 2>/dev/null; }; then
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ > "$LOCK_DIR/pid"
      set_lock_traps
      return 0
    fi
  fi
  log "Already running (lock held by PID ${held_pid:-?}, age ${age}s) — exiting cleanly."
  if [[ -f "$RECEIPT_HELPER" ]]; then
    python3 "$RECEIPT_HELPER" finish --job main_sweeper \
      --outcome skipped_lock \
      --reason "lock held by another run" \
      --lock '{"held": true, "reason": "contention"}' \
      --safety '{"status": "not_applicable", "reason": "lock_contention_no_mutation", "delegated": false}' >/dev/null 2>&1 || true
  fi
  return 1
}

should_run_heavy_task() {
  local marker_file="$1"
  local interval_sec="${2:-86400}"

  if [[ "$FORCE_ROUTINE" == true ]]; then
    return 0
  fi
  local curr_free
  curr_free="$(free_gb || echo "")"
  if [[ -n "$curr_free" && "$curr_free" -lt "$THRESHOLD_GB" ]]; then
    return 0
  fi
  if [[ ! -f "$marker_file" ]]; then
    return 0
  fi
  local last_mtime now age
  last_mtime=$(stat -f '%m' "$marker_file" 2>/dev/null || stat -c '%Y' "$marker_file" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$(( now - last_mtime ))
  if [[ "$age" -ge "$interval_sec" ]]; then
    return 0
  fi
  return 1
}

mark_heavy_task_done() {
  local marker_file="$1"
  if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$(dirname "$marker_file")"
    touch "$marker_file" 2>/dev/null || true
  fi
}

CLEAN_ARG="--clean"
if [[ "$DRY_RUN" == true ]]; then
  CLEAN_ARG="--dry-run"
fi

main() {
  acquire_lock || exit 0

  RECEIPT_RUN_ID=""
  if [[ -f "$RECEIPT_HELPER" ]]; then
    RECEIPT_RUN_ID=$(python3 "$RECEIPT_HELPER" begin --job main_sweeper \
      --trigger "${DISK_MAGICIAN_TRIGGER:-scheduled}" \
      --safety '{"status": "safe_routine_maintenance", "reason": "canonical_6_tier_stack", "delegated": true}' 2>/dev/null || echo "")
  fi

  log "=== Starting Unified Main Sweeper ==="
  local start_free_gb
  start_free_gb="$(free_gb || echo "")"
  log "Initial available space: ${start_free_gb:-unknown} GiB (mode: ${CLEAN_ARG})"

  # Phase 1: Snapshot & Topdown Ledger
  if [[ "$SKIP_SNAPSHOT" == false ]]; then
    log "Phase 1: Recording disk snapshot & topdown ledger..."
    if [[ -f "$REPO_ROOT/scripts/snapshot_commit.sh" ]]; then
      run_step_timeout bash "$REPO_ROOT/scripts/snapshot_commit.sh" || log "WARN: snapshot_commit.sh exited with non-zero status"
    fi
  else
    log "Phase 1: Snapshot skipped (--skip-snapshot)."
  fi

  # Phase 2: Pressure Reclaim (Critical Low-Disk Guard)
  local current_free_gb
  current_free_gb="$(free_gb || echo "")"
  if [[ -n "$current_free_gb" && "$current_free_gb" -lt "$THRESHOLD_GB" ]]; then
    log "Phase 2: Disk pressure detected (${current_free_gb} GiB < ${THRESHOLD_GB} GiB) — executing accelerated reclaim..."
    if [[ "${DISK_MAGICIAN_SKIP_TMP_LARGE:-0}" != "1" && -f "$REPO_ROOT/scripts/cleanup_tmp.sh" ]]; then
      log "Running cleanup_tmp.sh with --large and accelerated quarantine..."
      LARGE_TMP_APPROVED=1 TMP_WORKTREES_APPROVED=1 \
        LARGE_TMP_ACTIVE_HOURS=4 LARGE_TMP_ARCHIVE_RETENTION_HOURS=4 \
        run_step_timeout bash "$REPO_ROOT/scripts/cleanup_tmp.sh" "$CLEAN_ARG" --large || log "WARN: cleanup_tmp --large failed"
    fi
    if [[ -f "$REPO_ROOT/scripts/cleanup_colima.sh" ]]; then
      log "Pruning Colima Docker containers/images before trim..."
      run_step_timeout bash "$REPO_ROOT/scripts/cleanup_colima.sh" "$CLEAN_ARG" || log "WARN: cleanup_colima failed"
    fi
    if [[ "$DRY_RUN" == false ]] && command -v colima &>/dev/null; then
      if colima status 2>/dev/null | grep -qi "running"; then
        log "Trimming Colima VM datadisk..."
        run_step_timeout colima ssh -- sudo fstrim -av 2>&1 || log "WARN: colima fstrim failed"
      fi
    elif [[ "$DRY_RUN" == true ]]; then
      log "[dry-run] Would trim Colima VM datadisk via colima ssh -- sudo fstrim -av"
    fi
    if [[ "${DISK_MAGICIAN_SKIP_CLONES:-0}" != "1" && -f "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" ]]; then
      log "Cleaning detached browser code_sign_clones..."
      CODE_SIGN_CLONES_APPROVED=1 run_step_timeout bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" "$CLEAN_ARG" || log "WARN: cleanup_code_sign_clones failed"
    fi
  else
    log "Phase 2: Disk space healthy (${current_free_gb:-unknown} GiB >= ${THRESHOLD_GB} GiB)."
  fi

  # Phase 3: Canonical 6-Tier Routine Maintenance Stack
  if [[ "$SKIP_ROUTINE" == true ]]; then
    log "Phase 3: Routine maintenance skipped (--skip-routine)."
  else
    log "Phase 3: Executing canonical 6-tier routine maintenance stack..."

    # Tier 1: Dev caches, temp, PR scratch, LLM inspector
    [[ -f "$REPO_ROOT/scripts/cleanup_dev_caches.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/cleanup_dev_caches.sh" "$CLEAN_ARG" || true
    [[ -f "$REPO_ROOT/scripts/cleanup_tmp.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/cleanup_tmp.sh" "$CLEAN_ARG" || true
    [[ -f "$REPO_ROOT/scripts/cleanup_pr_scratch.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/cleanup_pr_scratch.sh" "$CLEAN_ARG" || true
    [[ -f "$REPO_ROOT/scripts/cleanup_llm_inspector.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/cleanup_llm_inspector.sh" "$CLEAN_ARG" || true

    # Tier 2: Xcode DerivedData & simulator caches (debounced to 24h when healthy)
    if should_run_heavy_task "$STATE_DIR/last_xcode_clean" 86400; then
      [[ -f "$REPO_ROOT/scripts/cleanup_xcode.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/cleanup_xcode.sh" "$CLEAN_ARG" || true
      mark_heavy_task_done "$STATE_DIR/last_xcode_clean"
    else
      log "Tier 2: Xcode DerivedData clean skipped (debounced to 24h; disk space healthy)."
    fi

    # Tier 3: Colima VM & Docker reclaim (debounced to 24h when healthy)
    if should_run_heavy_task "$STATE_DIR/last_colima_routine_prune" 86400; then
      if [[ -f "$REPO_ROOT/scripts/cleanup_colima.sh" ]]; then
        run_step_timeout bash "$REPO_ROOT/scripts/cleanup_colima.sh" "$CLEAN_ARG" || true
      fi
      if [[ -f "$REPO_ROOT/scripts/post_job_docker_prune.sh" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
          run_step_timeout bash "$REPO_ROOT/scripts/post_job_docker_prune.sh" --dry-run || true
        else
          run_step_timeout bash "$REPO_ROOT/scripts/post_job_docker_prune.sh" || true
        fi
      fi
      mark_heavy_task_done "$STATE_DIR/last_colima_routine_prune"
    else
      log "Tier 3: Colima VM & Docker prune skipped (debounced to 24h; disk space healthy)."
    fi

    # Tier 4: Browser Sessions & Assets
    [[ -f "$REPO_ROOT/scripts/prune_aside_sessions.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/prune_aside_sessions.sh" "$CLEAN_ARG" || true

    # Tier 5: Agent State Compaction & Rotated Logs (Codex vacuum debounced to 24h when healthy)
    [[ -f "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" "$CLEAN_ARG" || true
    if should_run_heavy_task "$STATE_DIR/last_codex_vacuum" 86400; then
      [[ -f "$REPO_ROOT/scripts/cleanup_codex_db.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/cleanup_codex_db.sh" "$CLEAN_ARG" || true
      mark_heavy_task_done "$STATE_DIR/last_codex_vacuum"
    else
      log "Tier 5: Codex DB vacuum skipped (debounced to 24h; disk space healthy)."
    fi
    [[ -f "$REPO_ROOT/scripts/cleanup_supervisor_logs.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/cleanup_supervisor_logs.sh" "$CLEAN_ARG" || true
    [[ -f "$REPO_ROOT/scripts/cleanup_uv_cache.sh" ]] && run_step_timeout bash "$REPO_ROOT/scripts/cleanup_uv_cache.sh" "$CLEAN_ARG" || true

    # Routine code-sign clones maintenance
    if [[ -f "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" ]]; then
      CODE_SIGN_CLONES_APPROVED=1 run_step_timeout bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" "$CLEAN_ARG" || true
    fi

    # Tier 6: Dormant Worktree Venvs (>=7d) & Claude State (>=7d)
    if [[ -f "$REPO_ROOT/scripts/cleanup_worktree_venvs.sh" ]]; then
      if [[ "$DRY_RUN" == false && "${WORKTREE_APPROVED:-0}" != "1" ]]; then
        log "Tier 6: cleanup_worktree_venvs skipped (requires WORKTREE_APPROVED=1)"
      else
        run_step_timeout bash "$REPO_ROOT/scripts/cleanup_worktree_venvs.sh" "$CLEAN_ARG" || true
      fi
    fi
    if [[ -f "$REPO_ROOT/scripts/cleanup_claude_state.sh" ]]; then
      if [[ "$DRY_RUN" == false && "${CLAUDE_STATE_APPROVED:-0}" != "1" ]]; then
        log "Tier 6: cleanup_claude_state skipped (requires CLAUDE_STATE_APPROVED=1)"
      else
        run_step_timeout bash "$REPO_ROOT/scripts/cleanup_claude_state.sh" "$CLEAN_ARG" || true
      fi
    fi
    if [[ "${WORKTREE_APPROVED:-0}" == "1" && -f "$REPO_ROOT/scripts/cleanup_worktrees.sh" ]]; then
      run_step_timeout bash "$REPO_ROOT/scripts/cleanup_worktrees.sh" "$CLEAN_ARG" || true
    fi
  fi

  # Phase 4: Sweeper Health & Status Verification
  if [[ "$SKIP_HEALTH" == true ]]; then
    log "Phase 4: Sweeper health check skipped (--skip-health)."
  else
    log "Phase 4: Running sweeper health check..."
    if [[ -f "$REPO_ROOT/scripts/sweeper_health_check.sh" ]]; then
      run_step_timeout bash "$REPO_ROOT/scripts/sweeper_health_check.sh" || log "WARN: sweeper_health_check reported warnings"
    fi
  fi

  local end_free_gb
  end_free_gb="$(free_gb || echo "")"
  log "=== Unified Main Sweeper Complete ==="
  log "Final available space: ${end_free_gb:-unknown} GiB (initial: ${start_free_gb:-unknown} GiB)"

  if [[ -n "$RECEIPT_RUN_ID" && -f "$RECEIPT_HELPER" ]]; then
    python3 "$RECEIPT_HELPER" finish --job main_sweeper \
      --run-id "$RECEIPT_RUN_ID" \
      --outcome success \
      --safety '{"status": "safe_routine_maintenance", "reason": "canonical_6_tier_stack", "delegated": true}' \
      --postcondition "{\"start_free_gb\": ${start_free_gb:-null}, \"end_free_gb\": ${end_free_gb:-null}}" >/dev/null 2>&1 || true
  fi
}

main "$@"
