#!/usr/bin/env bash
# post_job_docker_prune.sh — Docker cleanup hook for self-hosted CI runners.
#
# Runs after every CI job to prevent builder-cache runaway. The Docker
# builder cache is the primary source of regrowth on the worldarchitect.ai
# self-hosted Actions runners; without a cap it grows ~1 GB per build and
# can blow the host .raw past 100 GB in days.
#
# Behavior:
#   1. docker system prune -f               (always; removes dangling images/containers)
#   2. docker builder prune -f --filter "until=24h"  (only when builder cache > threshold)
#
# Defaults to LIVE prune. Use --dry-run to preview the commands and the
# threshold check without running them.
#
# Installation on a self-hosted GitHub Actions runner:
#   ln -sf "$PWD/scripts/post_job_docker_prune.sh" "$RUNNER_ROOT/hooks/post-job.sh"
# GitHub Actions runner invokes $RUNNER_ROOT/hooks/post-job.sh after every
# job. The symlink keeps the script version-controlled in this repo.
set -euo pipefail

# ---- Defaults ------------------------------------------------------------
DRY_RUN=false
MAX_CACHE_MB=2048
# Resolve log file from env (LOG_FILE is the common name; POST_JOB_DOCKER_PRUNE_LOG
# is the script-specific override). Default lives under the disk_magician backup dir.
LOG_FILE="${LOG_FILE:-${POST_JOB_DOCKER_PRUNE_LOG:-$HOME/.disk_magician_backup/post-job.log}}"
RUNNER_NAME="${RUNNER_NAME:-unknown}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-unknown}"

# ---- Usage ---------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--max-cache-mb <N>] [--log <path>] [-h|--help]

Options:
  --dry-run             Print what would run; do not invoke docker.
  --max-cache-mb <N>    Builder cache threshold in MB before prune fires (default: 2048).
  --log <path>          Log file (default: \$POST_JOB_DOCKER_PRUNE_LOG or
                        $HOME/.disk_magician_backup/post-job.log).
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --dry-run)          DRY_RUN=true ;;
    --max-cache-mb)
      [[ $# -ge 2 ]] || { echo "ERROR: --max-cache-mb requires an argument" >&2; exit 2; }
      MAX_CACHE_MB="$2"
      shift
      ;;
    --max-cache-mb=*)   MAX_CACHE_MB="${1#*=}" ;;
    --log)
      [[ $# -ge 2 ]] || { echo "ERROR: --log requires an argument" >&2; exit 2; }
      LOG_FILE="$2"
      shift
      ;;
    --log=*)            LOG_FILE="${1#*=}" ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---- Helpers -------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ensure_log_dir() {
  local dir
  dir="$(dirname "$LOG_FILE")"
  if [[ ! -d "$dir" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log "[dry-run] would create log directory: $dir"
    else
      mkdir -p "$dir"
    fi
  fi
}

# Format a KB integer as a human-readable size (G/M/K).
fmt_kb() {
  local kb="${1:-0}"
  awk "BEGIN{
    if ($kb >= 1048576)  printf \"%.1fG\", $kb / 1048576
    else if ($kb >= 1024) printf \"%.0fM\", $kb / 1024
    else                  printf \"%dK\", $kb
  }"
}

# Read the current builder cache size in MB. Returns 0 when docker is
# unavailable or the call fails — better to under-prune than to crash
# and abandon the job hook.
get_builder_cache_mb() {
  if ! command -v docker &>/dev/null; then
    echo 0
    return
  fi
  if ! docker info &>/dev/null; then
    echo 0
    return
  fi

  # Prefer `docker builder du` (direct, parseable). Older engines may not
  # support it; fall back to parsing `docker system df` for the "Build
  # Cache" line.
  local out kb
  if out=$(docker builder du --format '{{size}}' 2>/dev/null); then
    if [[ -n "$out" ]]; then
      kb=$(du_format_to_kb "$out") || { echo 0; return; }
      echo $(( (kb + 1023) / 1024 ))   # KB -> MB, rounding up
      return
    fi
  fi

  out=$(docker system df 2>/dev/null || true)
  if [[ -z "$out" ]]; then
    echo 0
    return
  fi

  # Lines look like: "Build Cache     2.1G     2.1G     0B     0B"
  # or:               "Build cache     5.43GB   ...  "
  # Match the second column regardless of spacing.
  local line val
  line=$(echo "$out" | awk 'BEGIN{IGNORECASE=1} /build[ -]?cache/ {print; exit}')
  if [[ -z "$line" ]]; then
    echo 0
    return
  fi
  val=$(echo "$line" | awk '{for (i=1; i<=NF; i++) if ($i ~ /[0-9]/) { print $i; exit }}')
  if [[ -z "$val" ]]; then
    echo 0
    return
  fi
  kb=$(size_to_kb "$val") || { echo 0; return; }
  echo $(( (kb + 1023) / 1024 ))
}

# Convert a Docker-formatted size string (e.g. "2.1G", "543M", "1024kB",
# "0B") to KB. Returns 0 on parse failure. POSIX awk (no gsub-with-array)
# — bash 3.2 compatible.
du_format_to_kb() {
  local s="$1"
  if [[ -z "$s" ]]; then echo 0; return 1; fi
  awk -v s="$s" 'BEGIN{
    n = s; sub(/[A-Za-z]+$/, "", n);
    suffix = s; sub(/^[0-9.]+/, "", suffix);
    if (suffix == "" || suffix == "B")      mul = 1
    else if (suffix == "k" || suffix == "K" || suffix == "kB" || suffix == "KB") mul = 1
    else if (suffix == "M" || suffix == "MB") mul = 1024
    else if (suffix == "G" || suffix == "GB") mul = 1024 * 1024
    else if (suffix == "T" || suffix == "TB") mul = 1024 * 1024 * 1024
    else { print 0; exit 1 }
    printf "%d", (n * mul) + 0.5
  }'
}

# Convert a `du -h`-style size string (e.g. "2.1G", "543M", "1024K") to KB.
size_to_kb() {
  local s="$1"
  if [[ -z "$s" ]]; then echo 0; return 1; fi
  awk -v s="$s" 'BEGIN{
    n = s; sub(/[A-Za-z]+$/, "", n);
    suffix = s; sub(/^[0-9.]+/, "", suffix);
    if (suffix == "" || suffix == "B" || suffix == "K")      mul = 1
    else if (suffix == "M") mul = 1024
    else if (suffix == "G") mul = 1024 * 1024
    else if (suffix == "T") mul = 1024 * 1024 * 1024
    else { print 0; exit 1 }
    printf "%d", (n * mul) + 0.5
  }'
}

# ---- Main ----------------------------------------------------------------
ensure_log_dir

{
  log "=== post-job prune start ==="
  log "runner: $RUNNER_NAME"
  log "workspace: $GITHUB_WORKSPACE"
  log "max_cache_mb: $MAX_CACHE_MB"
  log "dry_run: $DRY_RUN"

  if ! command -v docker &>/dev/null; then
    log "docker not found in PATH; skipping prune (not an error)"
    log "=== post-job prune end (no-op) ==="
    exit 0
  fi

  if ! docker info &>/dev/null; then
    log "docker daemon not reachable; skipping prune (not an error)"
    log "=== post-job prune end (no-op) ==="
    exit 0
  fi

  # 1) Always run docker system prune (cheap, safe — only dangling objects).
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] would run: docker system prune -f"
  else
    log "running: docker system prune -f"
    if ! docker system prune -f 2>&1; then
      log "WARN: docker system prune failed (continuing)"
    fi
  fi

  # 2) Conditional builder cache prune when over the threshold.
  current_mb=$(get_builder_cache_mb)
  log "builder cache: ${current_mb}MB (threshold: ${MAX_CACHE_MB}MB)"

  if [[ "$current_mb" -gt "$MAX_CACHE_MB" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log "[dry-run] would run: docker builder prune -f --filter \"until=24h\""
    else
      log "running: docker builder prune -f --filter \"until=24h\""
      if ! docker builder prune -f --filter "until=24h" 2>&1; then
        log "WARN: docker builder prune failed (continuing)"
      fi
    fi
  else
    log "builder cache within threshold; skipping builder prune"
  fi

  log "=== post-job prune end ==="
} | tee -a "$LOG_FILE"
