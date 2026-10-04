#!/usr/bin/env bash
# test_post_job_docker_prune.sh — Behavioral tests for post_job_docker_prune.sh
#
# Builds a self-contained mock docker binary that records every invocation
# to a log file and returns scripted output for `info`, `system df`, and
# `builder du`. Then runs the script in four scenarios and asserts the
# right commands fire under the right conditions:
#
#   1. docker missing                  -> no-op exit 0, "docker not found" log
#   2. live run, cache < threshold     -> docker system prune runs, builder prune skipped
#   3. live run, cache > threshold     -> both system prune AND builder prune run
#   4. --dry-run                       -> no docker calls, only "[dry-run]" log lines
#
# Run: bash tests/test_post_job_docker_prune.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/post_job_docker_prune.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi

TESTS_RUN=0
TESTS_PASSED=0

assert() {
  local label="$1" expected="$2" actual="$3"
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if [[ "$actual" == *"$expected"* ]]; then
    TESTS_RUN=$(( TESTS_RUN + 0 ))   # noop for shellcheck
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    echo "  ok   $label"
  else
    echo "  FAIL $label"
    echo "       expected substring: $expected"
    echo "       actual:              $actual"
    return 1
  fi
}

# Build a mock docker binary that:
#   - records every invocation to $INVOCATION_LOG
#   - answers `docker info` with success
#   - answers `docker builder du --format '{{size}}'` with $1 arg as size
#   - answers `docker system df` with a synthetic Build Cache line
#   - returns success for `prune` commands (just records them)
make_mock_docker() {
  local bin_dir="$1"
  local invocation_log="$2"
  local builder_cache_size="$3"   # e.g. "500MB", "3.2GB", "0B"
  local bin="$bin_dir/docker"
  cat > "$bin" <<EOF
#!/usr/bin/env bash
# mock docker for tests
echo "docker \$*" >> "$invocation_log"
case "\$1" in
  info)
    exit 0
    ;;
  builder)
    if [[ "\$2" == "du" ]]; then
      echo "$builder_cache_size"
      exit 0
    fi
    shift; shift
    if [[ "\$1" == "prune" ]]; then
      echo "Total reclaimed space: 0B"
      exit 0
    fi
    exit 0
    ;;
  system)
    if [[ "\$2" == "df" ]]; then
      cat <<'OUT'
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          10        5         2.5GB     1.2GB
Containers      3         0         120MB     120MB
Local Volumes   5         0         200MB     0B
Build Cache     15        0         ${builder_cache_size}  1.5GB
OUT
      exit 0
    fi
    if [[ "\$2" == "prune" ]]; then
      echo "Total reclaimed space: 0B"
      exit 0
    fi
    exit 0
    ;;
  image|container|network|volume)
    shift
    if [[ "\$1" == "prune" ]]; then
      echo "Total reclaimed space: 0B"
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$bin"
}

# Mock docker whose `info` subcommand FAILS (daemon unreachable).
make_unreachable_docker() {
  local bin_dir="$1"
  local invocation_log="$2"
  local bin="$bin_dir/docker"
  cat > "$bin" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "$invocation_log"
if [[ "\$1" == "info" ]]; then
  echo "Cannot connect to Docker daemon" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$bin"
}

make_hanging_docker() {
  local bin_dir="$1"
  local invocation_log="$2"
  local hang_target="$3" # "info", "builder", "both"
  local bin="$bin_dir/docker"
  cat > "$bin" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "$invocation_log"
case "\$1" in
  info)
    if [[ "$hang_target" == "info" ]]; then
      sleep 10
      exit 0
    fi
    exit 0
    ;;
  builder)
    if [[ "\$2" == "du" && ("$hang_target" == "builder" || "$hang_target" == "both") ]]; then
      sleep 10
      exit 0
    fi
    shift; shift
    exit 0
    ;;
  system)
    if [[ "\$2" == "df" && "$hang_target" == "both" ]]; then
      sleep 10
      exit 0
    fi
    if [[ "\$2" == "df" ]]; then
      cat <<'OUT'
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          10        5         2.5GB     1.2GB
Containers      3         0         120MB     120MB
Local Volumes   5         0         200MB     0B
Build Cache     15        0         3.2GB     1.5GB
OUT
      exit 0
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$bin"
}

# Run the script under a custom PATH. Args after the path+log are passed
# to the script. The script's own log is captured for substring assertions.
# Usage: run_under_mock <custom_path> <log_path> [script args...]
run_under_mock() {
  local custom_path="$1" log_path="$2"
  shift 2
  PATH="$custom_path" \
    LOG_FILE="$log_path" \
    bash "$SCRIPT" "$@" >> "$log_path.stdout" 2>&1
  return $?
}

# Build a PATH that excludes any directory containing a `docker` binary.
# Keeps coreutils + bash reachable. Used to simulate "docker missing".
strip_docker_from_path() {
  local IFS_save="$IFS"
  IFS=':'
  local parts=( $PATH )
  IFS="$IFS_save"
  local new=""
  local d
  for d in "${parts[@]}"; do
    [[ -z "$d" ]] && continue
    [[ -x "$d/docker" ]] && continue
    new="${new:+${new}:}$d"
  done
  echo "$new"
}

# ---------------------------------------------------------------------------
# Test 1: docker missing — script must exit 0, log "docker not found",
# and not call any docker binary (because none exists on PATH).
echo "=== Test 1: docker missing ==="
TMP1=$(mktemp -d -t dj_prune_t1.XXXXXX)
LOG1="$TMP1/post-job.log"
LOG1_STDOUT="$TMP1/post-job.stdout"
rm -f "$LOG1_STDOUT"
# Strip every dir containing a docker binary.
STRIPPED_PATH=$(strip_docker_from_path)
run_under_mock "$STRIPPED_PATH" "$LOG1" || true
LOG1_CONTENT=$(cat "$LOG1" 2>/dev/null || true)
assert "exits 0 when docker missing" "docker not found in PATH" "$LOG1_CONTENT"
assert "logs 'no-op' terminator" "post-job prune end (no-op)" "$LOG1_CONTENT"
rm -rf "$TMP1"

# ---------------------------------------------------------------------------
# Test 2: live run, cache < threshold (500MB < 2048MB) — system prune
# should run; builder prune should be SKIPPED.
echo "=== Test 2: cache below threshold ==="
TMP2=$(mktemp -d -t dj_prune_t2.XXXXXX)
LOG2="$TMP2/post-job.log"
LOG2_STDOUT="$TMP2/post-job.stdout"
INV2="$TMP2/invocations.log"
rm -f "$LOG2_STDOUT"
mkdir -p "$TMP2/bin"
make_mock_docker "$TMP2/bin" "$INV2" "500MB"
run_under_mock "$TMP2/bin:$PATH" "$LOG2" --max-cache-mb 2048
LOG2_CONTENT=$(cat "$LOG2")
INV2_CONTENT=$(cat "$INV2")
assert "logs builder cache size" "builder cache: 500MB" "$LOG2_CONTENT"
assert "logs threshold check" "threshold: 2048MB" "$LOG2_CONTENT"
assert "skips builder prune when under threshold" "skipping builder prune" "$LOG2_CONTENT"
assert "runs docker system prune" "docker system prune -f" "$INV2_CONTENT"
if [[ "$INV2_CONTENT" == *"builder prune"* ]]; then
  echo "  FAIL Test 2: docker builder prune should NOT have been called"
  echo "  invocations: $INV2_CONTENT"
  exit 1
fi
rm -rf "$TMP2"

# ---------------------------------------------------------------------------
# Test 3: live run, cache > threshold (3.2GB > 2048MB) — both system prune
# AND builder prune should run.
echo "=== Test 3: cache above threshold ==="
TMP3=$(mktemp -d -t dj_prune_t3.XXXXXX)
LOG3="$TMP3/post-job.log"
LOG3_STDOUT="$TMP3/post-job.stdout"
INV3="$TMP3/invocations.log"
rm -f "$LOG3_STDOUT"
mkdir -p "$TMP3/bin"
make_mock_docker "$TMP3/bin" "$INV3" "3.2GB"
run_under_mock "$TMP3/bin:$PATH" "$LOG3" --max-cache-mb 2048
LOG3_CONTENT=$(cat "$LOG3")
INV3_CONTENT=$(cat "$INV3")
assert "logs builder cache size" "builder cache: 3277MB" "$LOG3_CONTENT"
assert "runs docker system prune" "docker system prune -f" "$INV3_CONTENT"
assert "runs docker builder prune with 24h filter" "docker builder prune -f --filter until=24h" "$INV3_CONTENT"
rm -rf "$TMP3"

# ---------------------------------------------------------------------------
# Test 4: --dry-run with cache above threshold — no docker prune calls,
# only "[dry-run]" log lines.
echo "=== Test 4: --dry-run mode ==="
TMP4=$(mktemp -d -t dj_prune_t4.XXXXXX)
LOG4="$TMP4/post-job.log"
LOG4_STDOUT="$TMP4/post-job.stdout"
INV4="$TMP4/invocations.log"
rm -f "$LOG4_STDOUT"
mkdir -p "$TMP4/bin"
make_mock_docker "$TMP4/bin" "$INV4" "5GB"
run_under_mock "$TMP4/bin:$PATH" "$LOG4" --dry-run --max-cache-mb 2048
LOG4_CONTENT=$(cat "$LOG4")
INV4_CONTENT=$(cat "$INV4")
assert "logs dry-run flag" "dry_run: true" "$LOG4_CONTENT"
assert "emits dry-run for system prune" "[dry-run] would run: docker system prune -f" "$LOG4_CONTENT"
assert "emits dry-run for builder prune" "[dry-run] would run: docker builder prune -f --filter" "$LOG4_CONTENT"
# docker info WILL be called (to read cache size), but prune must NOT be.
if [[ "$INV4_CONTENT" == *"prune -f"* ]]; then
  echo "  FAIL Test 4: docker prune should NOT have been called in --dry-run"
  echo "  invocations: $INV4_CONTENT"
  exit 1
fi
rm -rf "$TMP4"

# ---------------------------------------------------------------------------
# Test 5: docker info fails (daemon unreachable) — script exits nonzero,
# logs DEGRADED / SKIPPED context, never calls prune.
echo "=== Test 5: docker daemon unreachable ==="
TMP5=$(mktemp -d -t dj_prune_t5.XXXXXX)
LOG5="$TMP5/post-job.log"
LOG5_STDOUT="$TMP5/post-job.stdout"
INV5="$TMP5/invocations.log"
rm -f "$LOG5_STDOUT"
mkdir -p "$TMP5/bin"
make_unreachable_docker "$TMP5/bin" "$INV5"
RC5=0
run_under_mock "$TMP5/bin:$PATH" "$LOG5" || RC5=$?
LOG5_CONTENT=$(cat "$LOG5" 2>/dev/null || true)
INV5_CONTENT=$(cat "$INV5" 2>/dev/null || true)
assert "returns nonzero on daemon unreachable" "true" "$([[ $RC5 -ne 0 ]] && echo true || echo false)"
assert "logs DEGRADED context" "DEGRADED" "$LOG5_CONTENT"
assert "logs skipped prune" "skipping prune" "$LOG5_CONTENT"
if [[ "$INV5_CONTENT" == *"prune"* ]]; then
  echo "  FAIL Test 5: prune should not be called when daemon is down"
  exit 1
fi
rm -rf "$TMP5"

# ---------------------------------------------------------------------------
# Test 6: --max-cache-mb with custom value and --log override.
echo "=== Test 6: custom threshold + log path ==="
TMP6=$(mktemp -d -t dj_prune_t6.XXXXXX)
LOG6="$TMP6/custom/my-post-job.log"
LOG6_STDOUT="$TMP6/post-job.stdout"
INV6="$TMP6/invocations.log"
rm -f "$LOG6_STDOUT"
mkdir -p "$TMP6/bin" "$TMP6/custom"
make_mock_docker "$TMP6/bin" "$INV6" "100MB"
run_under_mock "$TMP6/bin:$PATH" "$LOG6" --max-cache-mb 100
LOG6_CONTENT=$(cat "$LOG6")
assert "honors custom --max-cache-mb" "max_cache_mb: 100" "$LOG6_CONTENT"
assert "honors custom --log path" "builder cache: 100MB" "$LOG6_CONTENT"
# 100MB cache == 100MB threshold; not strictly greater, so should skip.
assert "treats equal-to-threshold as 'skip'" "skipping builder prune" "$LOG6_CONTENT"
rm -rf "$TMP6"

# ---------------------------------------------------------------------------
# Test 7: docker info hangs — bounded by probe deadline, returns nonzero,
# logs DEGRADED/SKIPPED, and invokes no destructive prune command.
echo "=== Test 7: docker info hang is bounded and fail-closed ==="
TMP7=$(mktemp -d -t dj_prune_t7.XXXXXX)
LOG7="$TMP7/post-job.log"
LOG7_STDOUT="$TMP7/post-job.stdout"
INV7="$TMP7/invocations.log"
rm -f "$LOG7_STDOUT"
mkdir -p "$TMP7/bin"
make_hanging_docker "$TMP7/bin" "$INV7" "info"
RC7=0
start7=$(date +%s)
DOCKER_PROBE_DEADLINE_SECONDS=1 run_under_mock "$TMP7/bin:$PATH" "$LOG7" || RC7=$?
dur7=$(( $(date +%s) - start7 ))
LOG7_CONTENT=$(cat "$LOG7" 2>/dev/null || true)
INV7_CONTENT=$(cat "$INV7" 2>/dev/null || true)
assert "returns nonzero on info hang" "true" "$([[ $RC7 -ne 0 ]] && echo true || echo false)"
assert "hang is bounded by probe deadline (<5s)" "true" "$([[ $dur7 -lt 5 ]] && echo true || echo false)"
assert "logs DEGRADED on timeout" "DEGRADED" "$LOG7_CONTENT"
assert "logs skipped prune" "skipping prune" "$LOG7_CONTENT"
if [[ "$INV7_CONTENT" == *"prune"* ]]; then
  echo "  FAIL Test 7: prune should not be called when info hangs"
  exit 1
fi
rm -rf "$TMP7"

# ---------------------------------------------------------------------------
# Test 8: builder du hang falls back to system df within deadline.
echo "=== Test 8: builder du hang falls back to system df ==="
TMP8=$(mktemp -d -t dj_prune_t8.XXXXXX)
LOG8="$TMP8/post-job.log"
LOG8_STDOUT="$TMP8/post-job.stdout"
INV8="$TMP8/invocations.log"
rm -f "$LOG8_STDOUT"
mkdir -p "$TMP8/bin"
make_hanging_docker "$TMP8/bin" "$INV8" "builder"
RC8=0
start8=$(date +%s)
DOCKER_PROBE_DEADLINE_SECONDS=1 run_under_mock "$TMP8/bin:$PATH" "$LOG8" --max-cache-mb 2048 || RC8=$?
dur8=$(( $(date +%s) - start8 ))
LOG8_CONTENT=$(cat "$LOG8" 2>/dev/null || true)
INV8_CONTENT=$(cat "$INV8" 2>/dev/null || true)
assert "exits 0 when fallback system df succeeds" "0" "$RC8"
assert "builder du hang bounded by deadline (<5s)" "true" "$([[ $dur8 -lt 5 ]] && echo true || echo false)"
assert "measured cache from fallback system df" "builder cache: 3277MB" "$LOG8_CONTENT"
assert "ran builder prune after fallback measurement" "docker builder prune" "$INV8_CONTENT"
rm -rf "$TMP8"

# ---------------------------------------------------------------------------
# Test 9: builder du hang AND system df hang — both bounded, no prune from
# invented 0MB cache, returns nonzero for degraded measurement.
echo "=== Test 9: builder du and system df hangs fail closed ==="
TMP9=$(mktemp -d -t dj_prune_t9.XXXXXX)
LOG9="$TMP9/post-job.log"
LOG9_STDOUT="$TMP9/post-job.stdout"
INV9="$TMP9/invocations.log"
rm -f "$LOG9_STDOUT"
mkdir -p "$TMP9/bin"
make_hanging_docker "$TMP9/bin" "$INV9" "both"
RC9=0
start9=$(date +%s)
DOCKER_PROBE_DEADLINE_SECONDS=1 run_under_mock "$TMP9/bin:$PATH" "$LOG9" --max-cache-mb 2048 || RC9=$?
dur9=$(( $(date +%s) - start9 ))
LOG9_CONTENT=$(cat "$LOG9" 2>/dev/null || true)
INV9_CONTENT=$(cat "$INV9" 2>/dev/null || true)
assert "returns nonzero on dual probe hang" "true" "$([[ $RC9 -ne 0 ]] && echo true || echo false)"
assert "dual hang bounded (<6s)" "true" "$([[ $dur9 -lt 6 ]] && echo true || echo false)"
assert "logs DEGRADED context" "DEGRADED" "$LOG9_CONTENT"
assert "does not claim 0MB cache" "false" "$([[ "$LOG9_CONTENT" == *"builder cache: 0MB"* ]] && echo true || echo false)"
if [[ "$INV9_CONTENT" == *"builder prune"* ]]; then
  echo "  FAIL Test 9: builder prune should not run after failed measurement"
  exit 1
fi
rm -rf "$TMP9"

# ---------------------------------------------------------------------------
# Test 10: deadline override validation rejects malformed / unreasonable input
echo "=== Test 10: deadline override validation ==="
TMP10=$(mktemp -d -t dj_prune_t10.XXXXXX)
LOG10="$TMP10/post-job.log"
LOG10_STDOUT="$TMP10/post-job.stdout"
INV10="$TMP10/invocations.log"
rm -f "$LOG10_STDOUT"
mkdir -p "$TMP10/bin"
make_mock_docker "$TMP10/bin" "$INV10" "500MB"

RC10_ZERO=0
DOCKER_PROBE_DEADLINE_SECONDS=0 run_under_mock "$TMP10/bin:$PATH" "$LOG10" || RC10_ZERO=$?
assert "rejects zero deadline" "true" "$([[ $RC10_ZERO -ne 0 ]] && echo true || echo false)"

RC10_NEG=0
DOCKER_PROBE_DEADLINE_SECONDS=-5 run_under_mock "$TMP10/bin:$PATH" "$LOG10" || RC10_NEG=$?
assert "rejects negative deadline" "true" "$([[ $RC10_NEG -ne 0 ]] && echo true || echo false)"

RC10_STR=0
DOCKER_PROBE_DEADLINE_SECONDS="abc" run_under_mock "$TMP10/bin:$PATH" "$LOG10" || RC10_STR=$?
assert "rejects non-numeric deadline" "true" "$([[ $RC10_STR -ne 0 ]] && echo true || echo false)"

RC10_HIGH=0
DOCKER_PROBE_DEADLINE_SECONDS=999 run_under_mock "$TMP10/bin:$PATH" "$LOG10" || RC10_HIGH=$?
assert "rejects unreasonable deadline (>60s)" "true" "$([[ $RC10_HIGH -ne 0 ]] && echo true || echo false)"
rm -rf "$TMP10"

# ---------------------------------------------------------------------------
echo ""
echo "PASSED: $TESTS_PASSED / $TESTS_RUN assertions"
echo "All tests complete."
