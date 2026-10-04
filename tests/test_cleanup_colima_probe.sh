#!/usr/bin/env bash
# test_cleanup_colima_probe.sh — Focused probe deadline tests for cleanup_colima.sh
#
# Hermetic fixture asserting bounded Docker probe deadlines and fail-closed
# contracts required by Bead disk_magician-3ma:
#   1. Docker missing is a clean exit 0 no-op.
#   2. Proven non-Colima backend is a clean exit 0 skip.
#   3. Context identity hang is bounded, returns nonzero DEGRADED, no prune/restart.
#   4. Context identity failure returns nonzero DEGRADED, no prune/restart.
#   5. Docker info hang is bounded, returns nonzero DEGRADED, no prune/restart.
#   6. Docker info failure (daemon down) in dry-run returns nonzero DEGRADED.
#   7. Docker system df hang is bounded, returns nonzero DEGRADED.
#   8. Orphan volume probe failure/hang never removes volume (no volume rm).
#   9. Guarded restart refuses Colima restart when docker ps -q fails/hangs.
#  10. Deadline override validation rejects malformed / out-of-range values.
#
# Run: bash tests/test_cleanup_colima_probe.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_colima.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi

TMP_ROOT=$(mktemp -d /tmp/dm-colima-probe.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

COLIMA_HOME="$TMP_ROOT/colima_home"
COLIMA_BIN="$TMP_ROOT/bin"
COLIMA_INVOCATIONS="$TMP_ROOT/invocations.log"
COLIMA_SSH_DIR="$COLIMA_HOME/.colima/_lima/colima"

mkdir -p "$COLIMA_BIN" "$COLIMA_HOME/.colima/default" "$COLIMA_SSH_DIR"

# Create a genuine UNIX domain socket owned by the current user
python3 - "$COLIMA_HOME/.colima/default/docker.sock" <<'PY'
import socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.close()
PY

touch "$COLIMA_SSH_DIR/ssh.sock"
cat > "$COLIMA_SSH_DIR/ssh.config" <<EOF
Host lima-colima
  ControlPath "$COLIMA_SSH_DIR/ssh.sock"
EOF

# Mock colima and ssh
cat > "$COLIMA_BIN/colima" <<EOF
#!/usr/bin/env bash
printf 'colima %s\n' "\$*" >> "$COLIMA_INVOCATIONS"
exit 0
EOF
cat > "$COLIMA_BIN/ssh" <<EOF
#!/usr/bin/env bash
printf 'ssh %s\n' "\$*" >> "$COLIMA_INVOCATIONS"
exit 0
EOF
chmod +x "$COLIMA_BIN/colima" "$COLIMA_BIN/ssh"

TESTS_RUN=0
TESTS_PASSED=0

assert() {
  local label="$1" expected="$2" actual="$3"
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if [[ "$actual" == *"$expected"* ]]; then
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    echo "  ok   $label"
  else
    echo "  FAIL $label"
    echo "       expected substring: $expected"
    echo "       actual:              $actual"
    return 1
  fi
}

make_mock_docker() {
  local mode="$1" # normal, hang_context, fail_context, hang_info, fail_info, hang_df, hang_ps_a, fail_ps_a, fail_ps_q
  cat > "$COLIMA_BIN/docker" <<EOF
#!/usr/bin/env bash
printf 'docker %s\n' "\$*" >> "$COLIMA_INVOCATIONS"

case "\$1 \$2" in
  "context show")
    if [[ "$mode" == "hang_context" ]]; then
      sleep 10
      exit 0
    elif [[ "$mode" == "fail_context" ]]; then
      exit 1
    fi
    printf 'colima\n'
    exit 0
    ;;
  "context inspect")
    if [[ "$mode" == "hang_context" ]]; then
      sleep 10
      exit 0
    elif [[ "$mode" == "fail_context" ]]; then
      exit 1
    fi
    printf '%s\n' "unix://$COLIMA_HOME/.colima/default/docker.sock"
    exit 0
    ;;
  "info "*)
    if [[ "$mode" == "hang_info" ]]; then
      sleep 10
      exit 0
    elif [[ "$mode" == "fail_info" || "$mode" == "fail_ps_q" ]]; then
      exit 1
    fi
    exit 0
    ;;
  "system df"*)
    if [[ "$mode" == "hang_df" ]]; then
      sleep 10
      exit 0
    fi
    printf 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\nBuild Cache 10 0 1.0GB 500MB\n'
    exit 0
    ;;
  "ps -q"*)
    if [[ "$mode" == "fail_ps_q" ]]; then
      sleep 10
      exit 1
    fi
    exit 0
    ;;
  "volume ls"*)
    printf 'orphan-test-vol\n'
    exit 0
    ;;
  "ps -a"*)
    if [[ "$mode" == "hang_ps_a" ]]; then
      sleep 10
      exit 0
    elif [[ "$mode" == "fail_ps_a" ]]; then
      exit 1
    fi
    exit 0
    ;;
  "volume rm"*)
    printf 'DESTRUCTIVE: docker volume rm %s\n' "\$3" >> "$COLIMA_INVOCATIONS"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$COLIMA_BIN/docker"
}

strip_docker_path() {
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

echo "=== Focused Probe Deadline Tests: cleanup_colima.sh ==="

# ---------------------------------------------------------------------------
# Test 1: Docker CLI missing from PATH -> exit 0 (normal no-op)
echo "--- Test 1: Docker missing ---"
STRIPPED_PATH=$(strip_docker_path)
OUT1="$TMP_ROOT/t1.out"
RC1=0
env -i PATH="$STRIPPED_PATH" HOME="$COLIMA_HOME" bash "$SCRIPT" --dry-run > "$OUT1" 2>&1 || RC1=$?
assert "exits 0 when docker missing" "0" "$RC1"
assert "logs docker CLI not found" "docker CLI not found" "$(cat "$OUT1")"

# ---------------------------------------------------------------------------
# Test 2: Proven non-Colima backend -> exit 0 (normal skip)
echo "--- Test 2: Proven non-Colima backend ---"
make_mock_docker "normal"
OUT2="$TMP_ROOT/t2.out"
RC2=0
: > "$COLIMA_INVOCATIONS"
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" DOCKER_HOST="unix:///tmp/not-colima.sock" \
  bash "$SCRIPT" --dry-run > "$OUT2" 2>&1 || RC2=$?
assert "exits 0 for proven non-Colima" "0" "$RC2"
assert "logs socket mismatch skip" "does not match the expected Colima socket" "$(cat "$OUT2")"

# ---------------------------------------------------------------------------
# Test 3: docker context show hangs -> bounded, returns nonzero DEGRADED
echo "--- Test 3: docker context show hang ---"
make_mock_docker "hang_context"
OUT3="$TMP_ROOT/t3.out"
RC3=0
: > "$COLIMA_INVOCATIONS"
start3=$(date +%s)
DOCKER_PROBE_DEADLINE_SECONDS=1 env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" \
  DOCKER_PROBE_DEADLINE_SECONDS=1 bash "$SCRIPT" --dry-run > "$OUT3" 2>&1 || RC3=$?
dur3=$(( $(date +%s) - start3 ))
assert "returns nonzero on context hang" "true" "$([[ $RC3 -ne 0 ]] && echo true || echo false)"
assert "context hang bounded by deadline (<5s)" "true" "$([[ $dur3 -lt 5 ]] && echo true || echo false)"
assert "logs DEGRADED/SKIPPED" "DEGRADED" "$(cat "$OUT3")"
assert "does not restart colima" "false" "$([[ "$(cat "$COLIMA_INVOCATIONS")" == *"colima stop"* ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 4: docker context show fails -> returns nonzero DEGRADED
echo "--- Test 4: docker context show failure ---"
make_mock_docker "fail_context"
OUT4="$TMP_ROOT/t4.out"
RC4=0
: > "$COLIMA_INVOCATIONS"
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" \
  bash "$SCRIPT" --dry-run > "$OUT4" 2>&1 || RC4=$?
assert "returns nonzero on context failure" "true" "$([[ $RC4 -ne 0 ]] && echo true || echo false)"
assert "logs DEGRADED/SKIPPED" "DEGRADED" "$(cat "$OUT4")"

# ---------------------------------------------------------------------------
# Test 5: docker info hangs -> bounded, returns nonzero DEGRADED
echo "--- Test 5: docker info hang ---"
make_mock_docker "hang_info"
OUT5="$TMP_ROOT/t5.out"
RC5=0
: > "$COLIMA_INVOCATIONS"
start5=$(date +%s)
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" \
  DOCKER_PROBE_DEADLINE_SECONDS=1 bash "$SCRIPT" --dry-run > "$OUT5" 2>&1 || RC5=$?
dur5=$(( $(date +%s) - start5 ))
assert "returns nonzero on info hang" "true" "$([[ $RC5 -ne 0 ]] && echo true || echo false)"
assert "info hang bounded by deadline (<5s)" "true" "$([[ $dur5 -lt 5 ]] && echo true || echo false)"
assert "logs DEGRADED" "DEGRADED" "$(cat "$OUT5")"
assert "does not restart colima" "false" "$([[ "$(cat "$COLIMA_INVOCATIONS")" == *"colima stop"* ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 6: docker info fails in dry-run -> returns nonzero DEGRADED
echo "--- Test 6: docker info failure in dry-run ---"
make_mock_docker "fail_info"
OUT6="$TMP_ROOT/t6.out"
RC6=0
: > "$COLIMA_INVOCATIONS"
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" \
  bash "$SCRIPT" --dry-run > "$OUT6" 2>&1 || RC6=$?
assert "returns nonzero on info failure in dry-run" "true" "$([[ $RC6 -ne 0 ]] && echo true || echo false)"
assert "logs DEGRADED" "DEGRADED" "$(cat "$OUT6")"

# ---------------------------------------------------------------------------
# Test 7: docker system df hangs -> bounded, returns nonzero DEGRADED
echo "--- Test 7: docker system df hang ---"
make_mock_docker "hang_df"
OUT7="$TMP_ROOT/t7.out"
RC7=0
: > "$COLIMA_INVOCATIONS"
start7=$(date +%s)
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" \
  DOCKER_PROBE_DEADLINE_SECONDS=1 bash "$SCRIPT" --dry-run > "$OUT7" 2>&1 || RC7=$?
dur7=$(( $(date +%s) - start7 ))
assert "returns nonzero on system df hang" "true" "$([[ $RC7 -ne 0 ]] && echo true || echo false)"
assert "system df hang bounded by deadline (<5s)" "true" "$([[ $dur7 -lt 5 ]] && echo true || echo false)"
assert "logs DEGRADED" "DEGRADED" "$(cat "$OUT7")"
assert "no prune executed" "false" "$([[ "$(cat "$COLIMA_INVOCATIONS")" == *"prune"* ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 8: Orphan volume probe with failed/hung docker ps -a never removes volume
echo "--- Test 8: orphan volume probe failure fails closed ---"
make_mock_docker "fail_ps_a"
OUT8="$TMP_ROOT/t8.out"
RC8=0
: > "$COLIMA_INVOCATIONS"
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" DOCKER_VOLUMES_APPROVED=1 \
  bash "$SCRIPT" --clean --prune-volumes > "$OUT8" 2>&1 || RC8=$?
assert "preserves volume when ps -a fails" "preserving volume" "$(cat "$OUT8")"
assert "never removes volume on ps -a failure" "false" "$([[ "$(cat "$COLIMA_INVOCATIONS")" == *"volume rm"* ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 9: Guarded recovery refuses restart when docker ps -q fails/hangs
echo "--- Test 9: restart refused when ps -q fails/hangs ---"
make_mock_docker "fail_ps_q"
OUT9="$TMP_ROOT/t9.out"
RC9=0
: > "$COLIMA_INVOCATIONS"
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" VACATE_CI_RUNNERS_APPROVED=1 \
  DOCKER_PROBE_DEADLINE_SECONDS=1 bash "$SCRIPT" --clean > "$OUT9" 2>&1 || RC9=$?
assert "refuses Colima restart when ps cannot prove containers" "could not prove that no containers are running" "$(cat "$OUT9")"
assert "never stops Colima without container proof" "false" "$([[ "$(cat "$COLIMA_INVOCATIONS")" == *"colima stop"* ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 10: Deadline validation rejects malformed / out-of-range input
echo "--- Test 10: deadline validation ---"
make_mock_docker "normal"
OUT10="$TMP_ROOT/t10.out"

RC10_ZERO=0
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" DOCKER_PROBE_DEADLINE_SECONDS=0 \
  bash "$SCRIPT" --dry-run > "$OUT10" 2>&1 || RC10_ZERO=$?
assert "rejects zero deadline" "true" "$([[ $RC10_ZERO -ne 0 ]] && echo true || echo false)"

RC10_NEG=0
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" DOCKER_PROBE_DEADLINE_SECONDS=-5 \
  bash "$SCRIPT" --dry-run > "$OUT10" 2>&1 || RC10_NEG=$?
assert "rejects negative deadline" "true" "$([[ $RC10_NEG -ne 0 ]] && echo true || echo false)"

RC10_STR=0
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" DOCKER_PROBE_DEADLINE_SECONDS=invalid \
  bash "$SCRIPT" --dry-run > "$OUT10" 2>&1 || RC10_STR=$?
assert "rejects non-numeric deadline" "true" "$([[ $RC10_STR -ne 0 ]] && echo true || echo false)"

RC10_HIGH=0
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" DOCKER_PROBE_DEADLINE_SECONDS=999 \
  bash "$SCRIPT" --dry-run > "$OUT10" 2>&1 || RC10_HIGH=$?
assert "rejects unreasonable deadline (>60s)" "true" "$([[ $RC10_HIGH -ne 0 ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 11: TERM-ignoring probe child is killed by deadline + kill-after grace
echo "--- Test 11: TERM-ignoring probe child killed by kill-after grace ---"
TERM_PID_FILE="$TMP_ROOT/term_ignoring.pid"
rm -f "$TERM_PID_FILE"
cat > "$COLIMA_BIN/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "$COLIMA_INVOCATIONS"
if [[ "\$1" == "context" && "\$2" == "show" ]]; then
  trap '' TERM
  sleep 30 &
  sleeper=\$!
  echo "\$sleeper" > "$TERM_PID_FILE"
  wait "\$sleeper"
  exit 0
fi
exit 0
EOF
chmod +x "$COLIMA_BIN/docker"

OUT11="$TMP_ROOT/t11.out"
RC11=0
: > "$COLIMA_INVOCATIONS"
start11=$(date +%s)
# Outer cap of 10s prevents task hang if regression occurs
timeout 10s env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" DOCKER_PROBE_DEADLINE_SECONDS=1 \
  bash "$SCRIPT" --dry-run > "$OUT11" 2>&1 || RC11=$?
dur11=$(( $(date +%s) - start11 ))
CHILD_PID=$(cat "$TERM_PID_FILE" 2>/dev/null || echo "")
assert "returns nonzero on timeout" "true" "$([[ $RC11 -ne 0 ]] && echo true || echo false)"
assert "probe killed within deadline + grace (<6s)" "true" "$([[ $dur11 -lt 6 ]] && echo true || echo false)"
assert "spawned sleeper child PID was recorded" "true" "$([[ -n "$CHILD_PID" ]] && echo true || echo false)"
if [[ -n "$CHILD_PID" ]]; then
  child_alive=0
  kill -0 "$CHILD_PID" 2>/dev/null && child_alive=1 || child_alive=0
  assert "leaves no lingering TERM-ignoring child behind" "0" "$child_alive"
fi

# ---------------------------------------------------------------------------
# Test 12: Timeout utility lacking -k fails closed and NEVER invokes docker
echo "--- Test 12: Timeout lacking -k fails closed without invoking docker ---"
FAKE_TIMEOUT_DIR="$TMP_ROOT/fake_timeout_bin"
mkdir -p "$FAKE_TIMEOUT_DIR"
cat > "$FAKE_TIMEOUT_DIR/timeout" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "-k" || "$arg" == "--kill-after"* ]]; then
    echo "timeout: unrecognized option: -k" >&2
    exit 1
  fi
done
shift
"$@"
EOF
chmod +x "$FAKE_TIMEOUT_DIR/timeout"

cat > "$COLIMA_BIN/docker" <<EOF
#!/usr/bin/env bash
echo "DOCKER INVOKED: \$*" >> "$COLIMA_INVOCATIONS"
exit 0
EOF
chmod +x "$COLIMA_BIN/docker"

OUT12="$TMP_ROOT/t12.out"
RC12=0
: > "$COLIMA_INVOCATIONS"
env -i PATH="$FAKE_TIMEOUT_DIR:$COLIMA_BIN:/usr/bin:/bin" HOME="$COLIMA_HOME" \
  bash "$SCRIPT" --dry-run > "$OUT12" 2>&1 || RC12=$?
assert "returns nonzero when timeout lacks -k" "true" "$([[ $RC12 -ne 0 ]] && echo true || echo false)"
assert "logs DEGRADED context" "DEGRADED" "$(cat "$OUT12")"
assert "never invokes docker when timeout lacks -k" "false" "$([[ "$(cat "$COLIMA_INVOCATIONS")" == *"DOCKER INVOKED"* ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 13: Successful docker context show with empty output fails closed
echo "--- Test 13: Empty context show fails closed ---"
cat > "$COLIMA_BIN/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "$COLIMA_INVOCATIONS"
if [[ "\$1" == "context" && "\$2" == "show" ]]; then
  exit 0
fi
if [[ "\$1" == "info" ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "$COLIMA_BIN/docker"

OUT13="$TMP_ROOT/t13.out"
RC13=0
: > "$COLIMA_INVOCATIONS"
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" \
  bash "$SCRIPT" --dry-run > "$OUT13" 2>&1 || RC13=$?
assert "returns nonzero on empty context show" "true" "$([[ $RC13 -ne 0 ]] && echo true || echo false)"
assert "logs DEGRADED/SKIPPED on empty context show" "DEGRADED" "$(cat "$OUT13")"
assert "never falls back to Colima socket on empty context" "false" "$([[ "$(cat "$OUT13")" == *"Selected proven Colima Docker socket"* ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 14: Successful docker context inspect with empty endpoint fails closed
echo "--- Test 14: Empty context inspect endpoint fails closed ---"
cat > "$COLIMA_BIN/docker" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >> "$COLIMA_INVOCATIONS"
if [[ "\$1" == "context" && "\$2" == "show" ]]; then
  echo "colima"
  exit 0
fi
if [[ "\$1" == "context" && "\$2" == "inspect" ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "$COLIMA_BIN/docker"

OUT14="$TMP_ROOT/t14.out"
RC14=0
: > "$COLIMA_INVOCATIONS"
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" \
  bash "$SCRIPT" --dry-run > "$OUT14" 2>&1 || RC14=$?
assert "returns nonzero on empty context inspect" "true" "$([[ $RC14 -ne 0 ]] && echo true || echo false)"
assert "logs DEGRADED/SKIPPED on empty endpoint" "DEGRADED" "$(cat "$OUT14")"
assert "never falls back to Colima socket on empty endpoint" "false" "$([[ "$(cat "$OUT14")" == *"Selected proven Colima Docker socket"* ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test 15: Explicit DOCKER_CONTEXT with empty endpoint fails closed
echo "--- Test 15: Explicit DOCKER_CONTEXT with empty endpoint fails closed ---"
OUT15="$TMP_ROOT/t15.out"
RC15=0
: > "$COLIMA_INVOCATIONS"
env -i PATH="$COLIMA_BIN:$PATH" HOME="$COLIMA_HOME" DOCKER_CONTEXT="explicit-empty" \
  bash "$SCRIPT" --dry-run > "$OUT15" 2>&1 || RC15=$?
assert "returns nonzero on explicit DOCKER_CONTEXT empty endpoint" "true" "$([[ $RC15 -ne 0 ]] && echo true || echo false)"
assert "logs DEGRADED/SKIPPED on explicit empty endpoint" "DEGRADED" "$(cat "$OUT15")"

echo ""
echo "PASSED: $TESTS_PASSED / $TESTS_RUN assertions"
echo "All focused Colima probe tests complete."
