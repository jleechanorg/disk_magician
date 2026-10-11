#!/usr/bin/env bash
# test_cleanup_colima_stopped_recovery.sh — bead disk_magician-67xj
# Hermetic PATH stubs (colima/limactl/docker/ps); never touches the real Colima.
#   1. Stopped + approval -> restart allowed (no container proof needed, no colima stop).
#   2. status probe failure -> still refused.
#   3. stale disk lock, no live hostagent -> unlock + start retried once.
#   4. lock with live hostagent pid / process -> no unlock, fail closed.
#   5. no approval -> unchanged refusal.
#   6. --trim-only on a Stopped VM logs a clear Stopped line, not DEGRADED.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/scripts/cleanup_colima.sh"
TMP=$(mktemp -d /tmp/dm-colima-stopped.XXXXXX)
trap 'kill "${LIVE_PID:-0}" 2>/dev/null; rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; HOME_D="$TMP/home"; ST="$TMP/state"; INV="$TMP/inv.log"
mkdir -p "$BIN" "$ST" "$HOME_D/.colima/default" "$HOME_D/.colima/_lima/colima" "$HOME_D/.colima/_lima/_disks/colima"
python3 - "$HOME_D/.colima/default/docker.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1]); s.close()
PY

cat > "$BIN/colima" <<EOF
#!/bin/bash
echo "colima \$*" >> "$INV"
case "\$1" in
  list) case "\$(cat "$ST/list_mode")" in
          stopped) printf 'PROFILE STATUS ARCH\ndefault Stopped aarch64\n';;
          fail) exit 1;;
          *) printf 'PROFILE STATUS ARCH\ndefault Running aarch64\n';; esac ;;
  start) if [[ -e "$ST/lock" ]]; then echo 'failed to run attach disk "colima", in use by instance "colima"' >&2; exit 1; fi
         touch "$ST/started" ;;
esac
exit 0
EOF
cat > "$BIN/limactl" <<EOF
#!/bin/bash
echo "limactl \$*" >> "$INV"
case "\$1 \$2" in
  "disk list") printf 'NAME SIZE FORMAT DIR IN-USE-BY\ncolima 100GiB raw /x/_disks/colima /x/colima\n'; [[ -e "$ST/lock" ]] || exit 0 ;;
  "disk unlock") rm -f "$ST/lock" ;;
esac
exit 0
EOF
cat > "$BIN/docker" <<EOF
#!/bin/bash
echo "docker \$*" >> "$INV"
case "\$1 \$2" in
  "context show") echo colima;;
  "context inspect") echo "unix://$HOME_D/.colima/default/docker.sock";;
  "info "*) [[ -e "$ST/started" ]] || exit 1;;
  "ps -q") exit 1;;
esac
exit 0
EOF
cat > "$BIN/ps" <<EOF
#!/bin/bash
cat "$ST/ps_out" 2>/dev/null
exit 0
EOF
cat > "$BIN/ssh" <<'EOF'
#!/bin/bash
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\t%%s\\n" 9437184 "${!#}"\n' > "$BIN/du"
chmod +x "$BIN"/*

PASS=0; FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); cat "$INV" "$TMP/out" 2>/dev/null | tail -30; }
cnt() { grep -c "$1" "$INV" || true; }

# $1 list_mode  $2 lock(0/1)  $3 approval(0/1)  rest: extra args
run() {
  local mode="$1" lock="$2" appr="$3"; shift 3
  : > "$INV"; rm -f "$ST/started" "$ST/lock" "$ST/ps_out"
  echo "$mode" > "$ST/list_mode"
  [[ "$lock" == 1 ]] && touch "$ST/lock"
  RC=0
  env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 \
    ${appr:+VACATE_CI_RUNNERS_APPROVED=$appr} /bin/bash "$SCRIPT" "${@:---clean}" > "$TMP/out" 2>&1 || RC=$?
}

# 1. Stopped + approval -> restart allowed
run stopped 0 1
if [[ $(cnt '^colima start') -eq 1 && $(cnt '^colima stop') -eq 0 ]] && ! grep -q 'could not prove' "$TMP/out"; then
  ok "Stopped + approval: start attempted, no stop, no refusal"
else bad "Stopped + approval"; fi

# 2. status probe failure -> still refused
run fail 0 1
if grep -q 'could not prove that no containers' "$TMP/out" && [[ $(cnt '^colima start') -eq 0 && $(cnt '^colima stop') -eq 0 ]]; then
  ok "status probe failure: fail-closed"
else bad "status probe failure"; fi

# 3. stale lock, no live hostagent -> unlock + retry once
run stopped 1 1
if [[ $(cnt '^limactl disk unlock colima') -eq 1 && $(cnt '^colima start') -eq 2 && -e "$ST/started" ]]; then
  ok "stale lock: unlock once + start retried once, then started"
else bad "stale lock"; fi

# 4a. live hostagent pid file -> no unlock
sleep 300 & LIVE_PID=$!
echo "$LIVE_PID" > "$HOME_D/.colima/_lima/colima/ha.pid"
run stopped 1 1
if [[ $(cnt '^limactl disk unlock') -eq 0 && $(cnt '^colima start') -eq 1 ]] && grep -q 'failing closed' "$TMP/out"; then
  ok "live hostagent pid: no unlock, fail closed"
else bad "live pid"; fi
rm -f "$HOME_D/.colima/_lima/colima/ha.pid"; kill "$LIVE_PID" 2>/dev/null

# 4b. live hostagent process visible via ps -> no unlock
run stopped 1 1
: > "$INV"; echo "limactl hostagent --pidfile /x/colima/ha.pid colima" > "$ST/ps_out"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 VACATE_CI_RUNNERS_APPROVED=1 \
  /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^limactl disk unlock') -eq 0 ]]; then ok "live hostagent process: no unlock"; else bad "live ps"; fi

# 5. no approval -> unchanged
run stopped 0 0
if grep -q 'requires VACATE_CI_RUNNERS_APPROVED=1' "$TMP/out" && [[ $(cnt '^colima start') -eq 0 ]]; then
  ok "no approval: refused, nothing started"
else bad "no approval"; fi

# 6. trim-only on Stopped VM
run stopped 0 "" --trim-only --clean
if grep -q 'trim-only: Colima VM is Stopped' "$TMP/out" && ! grep -q DEGRADED "$TMP/out" && [[ $RC -eq 0 ]]; then
  ok "trim-only Stopped: clear log line, no DEGRADED"
else bad "trim-only"; fi

echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
