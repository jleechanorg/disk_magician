#!/usr/bin/env bash
# test_cleanup_colima_stopped_recovery.sh — bead disk_magician-67xj
# Hermetic PATH stubs (colima/limactl/docker/ps); never touches the real Colima.
#   1. Stopped + approval -> restart allowed (no container proof needed, no colima stop).
#   2. status probe failure -> still refused.
#   3. stale disk lock, no live hostagent -> unlock + start retried once.
#   4. lock with live hostagent pid / process -> no unlock, fail closed.
#   5. no approval -> unchanged refusal.
#   6. --trim-only on a Stopped VM logs a clear Stopped line, not DEGRADED.
#   7-10. unlocked listing / ps failure / empty pid / non-default profile fail closed.
#  11. Stopped VM with no Docker socket -> guarded recovery still reachable (PR #150).
#  12. QEMU holds the disk (ps+lsof) -> never unlock.
#  13. VZ holds the disk with no colima token in cmdline -> never unlock (PR #150).
#  14. lsof holder probe fails -> never unlock, fail closed.
#  15. No proven holder -> stale lock still unlocks once.
#  16. lsof exit 1 with empty stdout but a stderr diagnostic -> fail closed (PR #150).
#  17. Explicit DOCKER_HOST at the expected Colima socket + Stopped -> recovery (PR #150).
#  18. Explicit DOCKER_CONTEXT at the expected Colima socket + Stopped -> recovery (PR #150).
#  19. Explicit DOCKER_CONTEXT at an unrelated endpoint -> stays refused (PR #150).
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
# A created VM always has the live VZ diffdisk sibling; production must scan it.
: > "$HOME_D/.colima/_lima/colima/diffdisk"

cat > "$BIN/colima" <<EOF
#!/bin/bash
echo "colima \$*" >> "$INV"
case "\$1" in
  list) case "\$(cat "$ST/list_mode")" in
          stopped) printf 'PROFILE STATUS ARCH\ndefault Stopped aarch64\n';;
          fail) exit 1;;
          *) printf 'PROFILE STATUS ARCH\ndefault Running aarch64\n';; esac ;;
  start) if [[ -e "$ST/startfail" ]]; then exit 1; fi
         if [[ -e "$ST/lock" ]]; then echo 'failed to run attach disk "colima", in use by instance "colima"' >&2; exit 1; fi
         touch "$ST/started" ;;
esac
exit 0
EOF
# Fixtures copied from real `limactl disk list colima` (lima 2.0.3).
printf 'NAME      SIZE      FORMAT    DIR                                              IN-USE-BY\ncolima    100GiB    raw       /Users/jleechan/.colima/_lima/_disks/colima      colima\n' > "$ST/dlist_locked"
printf 'NAME      SIZE      FORMAT    DIR\ncolima    100GiB    raw       /Users/jleechan/.colima/_lima/_disks/colima\n' > "$ST/dlist_unlocked"
cat > "$BIN/limactl" <<EOF
#!/bin/bash
echo "limactl \$*" >> "$INV"
case "\$1 \$2" in
  "disk list") cat "$ST/dlist_\$([[ -e "$ST/lock" ]] && echo locked || echo unlocked)" ;;
  "disk unlock") rm -f "$ST/lock" ;;
esac
exit 0
EOF
cat > "$BIN/docker" <<EOF
#!/bin/bash
echo "docker \$*" >> "$INV"
case "\$1 \$2" in
  "context show") echo colima;;
  "context inspect") case "\$3" in other) echo "unix:///var/run/docker.sock";; *) echo "unix://$HOME_D/.colima/default/docker.sock";; esac ;;
  "info "*) [[ -e "$ST/started" ]] || exit 1;;
  "ps -q") exit 1;;
esac
exit 0
EOF
cat > "$BIN/ps" <<EOF
#!/bin/bash
[[ -e "$ST/ps_fail" ]] && exit 1
cat "$ST/ps_out" 2>/dev/null || echo /sbin/launchd
exit 0
EOF
# lsof models the authoritative holder probe and MUST honor the requested
# scan target (argument-faithful): the datadisk dir and the VZ diffdisk
# sibling are answered independently. A non-{0,1} exit is a probe failure;
# exit 1 with a stderr diagnostic is an incomplete scan (fail closed).
cat > "$BIN/lsof" <<EOF
#!/bin/bash
echo "lsof \$*" >> "$INV"
target="\${!#}"
if [[ -e "$ST/lsof_fail" ]]; then exit 2; fi
if [[ -e "$ST/lsof_diag" ]]; then cat "$ST/lsof_diag" >&2; exit 1; fi
out=""
case "\$target" in
  */_disks/colima) out="$ST/lsof_out_datadisk" ;;
  */colima/diffdisk) out="$ST/lsof_out_diffdisk" ;;
esac
if [[ -n "\$out" && -e "\$out" ]]; then cat "\$out"; exit 0; fi
exit 1
EOF
cat > "$BIN/ssh" <<'EOF'
#!/bin/bash
exit 0
EOF
# Keep the trusted-socket ownership fixture independent of BSD/GNU stat syntax;
# the production guard still compares this value with the real current uid.
TEST_UID=$(id -u)
cat > "$BIN/stat" <<EOF
#!/bin/bash
printf '%s\n' '$TEST_UID'
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
  : > "$INV"; rm -f "$ST/started" "$ST/lock" "$ST/ps_out" "$ST/ps_fail" "$ST/startfail" "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk" "$ST/lsof_diag"
  echo "$mode" > "$ST/list_mode"
  [[ "$lock" == 1 ]] && touch "$ST/lock"
  RC=0
  env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 \
    ${appr:+VACATE_CI_RUNNERS_APPROVED=$appr} ${PROFILE:+COLIMA_PROFILE=$PROFILE} /bin/bash "$SCRIPT" "${@:---clean}" > "$TMP/out" 2>&1 || RC=$?
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
: > "$INV"; rm -f "$ST/started"; touch "$ST/lock"
echo "limactl hostagent --pidfile /x/colima/ha.pid colima" > "$ST/ps_out"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 VACATE_CI_RUNNERS_APPROVED=1 \
  /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^limactl disk unlock') -eq 0 && $(cnt '^colima start') -eq 1 ]] && grep -q 'failing closed' "$TMP/out"; then
  ok "live hostagent process: no unlock, fail closed"
else bad "live ps"; fi

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

# 7. unlocked listing (4 fields) + start failure -> never unlock
run stopped 0 1; : > "$INV"; rm -f "$ST/started"; touch "$ST/startfail"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 VACATE_CI_RUNNERS_APPROVED=1 /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^limactl disk unlock') -eq 0 && $(cnt '^colima start') -eq 1 ]]; then ok "unlocked disk: never unlocks"; else bad "unlocked"; fi

# 8. ps failure -> not proven stale
run stopped 1 1; : > "$INV"; rm -f "$ST/started"; touch "$ST/lock" "$ST/ps_fail"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 VACATE_CI_RUNNERS_APPROVED=1 /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^limactl disk unlock') -eq 0 && $(cnt '^colima start') -eq 1 ]] && grep -q 'failing closed' "$TMP/out"; then
  ok "ps failure: no unlock, fail closed"
else bad "ps failure"; fi

# 9. empty pid file -> not proven stale
: > "$HOME_D/.colima/_lima/colima/ha.pid"
run stopped 1 1
if [[ $(cnt '^limactl disk unlock') -eq 0 ]]; then ok "empty pid file: fail closed"; else bad "empty pid"; fi
rm -f "$HOME_D/.colima/_lima/colima/ha.pid"

# 10. non-default profile never acts on the default instance
PROFILE=other run stopped 1 1
if [[ $(cnt '^limactl disk unlock') -eq 0 && $(cnt '^colima start') -eq 0 ]]; then ok "non-default profile: no action on default instance"; else bad "profile"; fi

# --- PR #150 review regression cases (RED before the shared-cause fix). ---

# 11. Stopped VM with no Docker socket -> guarded recovery must still be reached.
rm -f "$HOME_D/.colima/default/docker.sock"
run stopped 0 1
if [[ $(cnt '^colima start') -eq 1 ]] && ! grep -qi 'could not prove' "$TMP/out"; then
  ok "no docker socket + stopped: guarded recovery reached"
else bad "no docker socket + stopped"; fi
python3 - "$HOME_D/.colima/default/docker.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sys.argv[1]); s.close()
PY

# 12. QEMU holds the datadisk (ps + lsof) -> never unlock.
: > "$INV"; rm -f "$ST/started" "$ST/ps_out" "$ST/ps_fail" "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk" "$ST/lsof_diag"
echo stopped > "$ST/list_mode"; touch "$ST/lock"
echo "qemu-system-aarch64 -drive file=$HOME_D/.colima/_lima/_disks/colima/datadisk,if=virtio" > "$ST/ps_out"
echo "qemu-syst 4242 jleechan 5u REG 1,18 107374182400 1 $HOME_D/.colima/_lima/_disks/colima/datadisk" > "$ST/lsof_out_datadisk"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 VACATE_CI_RUNNERS_APPROVED=1 /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^limactl disk unlock') -eq 0 && $(cnt '^colima start') -eq 1 ]] && grep -q 'failing closed' "$TMP/out"; then
  ok "qemu holds disk: no unlock, fail closed"
else bad "qemu holds disk"; fi

# 13. VZ holds the disk but its real cmdline has no colima token -> no unlock.
: > "$INV"; rm -f "$ST/started" "$ST/ps_out" "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk"; touch "$ST/lock"
echo "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine" > "$ST/ps_out"
echo "com.apple 93307 jleechan 4u REG 1,18 21474836480 1 $HOME_D/.colima/_lima/colima/diffdisk" > "$ST/lsof_out_diffdisk"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 VACATE_CI_RUNNERS_APPROVED=1 /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^limactl disk unlock') -eq 0 ]] && grep -q 'failing closed' "$TMP/out"; then
  ok "vz holds disk with clean ps: no unlock, fail closed"
else bad "vz holds disk"; fi

# 14. lsof cannot prove holder state (probe failure) -> no unlock.
: > "$INV"; rm -f "$ST/started" "$ST/ps_out" "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk"; touch "$ST/lock" "$ST/lsof_fail"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 VACATE_CI_RUNNERS_APPROVED=1 /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^limactl disk unlock') -eq 0 ]] && grep -q 'failing closed' "$TMP/out"; then
  ok "lsof failure: no unlock, fail closed"
else bad "lsof failure"; fi
rm -f "$ST/lsof_fail"

# 15. No disk holders proven -> stale lock still unlocks (no over-fail-closed).
: > "$INV"; rm -f "$ST/started" "$ST/ps_out" "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk" "$ST/lsof_fail"; touch "$ST/lock"
echo "limactl usernet --listen-qemu /x/user-v2_qemu.sock" > "$ST/ps_out"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 VACATE_CI_RUNNERS_APPROVED=1 /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^limactl disk unlock colima') -eq 1 && -e "$ST/started" ]]; then
  ok "no holders (lsof clean): unlock still allowed"
else bad "no holders unlock"; fi
rm -f "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk"

# --- PR #150 review r2 regression cases ---

# 16. lsof exit 1 with empty stdout but a stderr diagnostic -> unproven, fail closed.
: > "$INV"; rm -f "$ST/started" "$ST/ps_out" "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk" "$ST/lsof_diag"; touch "$ST/lock"
printf 'lsof: WARNING: cant stat(/x): No such file or directory\n' > "$ST/lsof_diag"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 VACATE_CI_RUNNERS_APPROVED=1 /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^limactl disk unlock') -eq 0 && $(cnt '^colima start') -eq 1 ]] && grep -q 'failing closed' "$TMP/out"; then
  ok "lsof exit1 + diagnostic: no unlock, fail closed"
else bad "lsof exit1 + diagnostic"; fi
rm -f "$ST/lsof_diag"

# 17. Explicit DOCKER_HOST at the expected Colima socket, Stopped, socket absent.
rm -f "$HOME_D/.colima/default/docker.sock"
: > "$INV"; rm -f "$ST/started" "$ST/lock" "$ST/ps_out" "$ST/ps_fail" "$ST/startfail" "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk" "$ST/lsof_diag"
echo stopped > "$ST/list_mode"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 \
  DOCKER_HOST="unix://$HOME_D/.colima/default/docker.sock" VACATE_CI_RUNNERS_APPROVED=1 \
  /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^colima start') -eq 1 ]] && ! grep -q 'does not match the expected Colima socket' "$TMP/out"; then
  ok "explicit DOCKER_HOST expected + stopped: guarded recovery reached"
else bad "explicit DOCKER_HOST expected + stopped"; fi

# 18. Explicit DOCKER_CONTEXT resolving to the expected Colima socket, Stopped.
: > "$INV"; rm -f "$ST/started" "$ST/lock" "$ST/ps_out" "$ST/ps_fail" "$ST/startfail" "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk" "$ST/lsof_diag"
echo stopped > "$ST/list_mode"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 \
  DOCKER_CONTEXT=colima VACATE_CI_RUNNERS_APPROVED=1 \
  /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^colima start') -eq 1 ]]; then
  ok "explicit DOCKER_CONTEXT expected + stopped: guarded recovery reached"
else bad "explicit DOCKER_CONTEXT expected + stopped"; fi

# 19. Explicit DOCKER_CONTEXT to an unrelated backend -> stays refused.
: > "$INV"; rm -f "$ST/started" "$ST/lock" "$ST/ps_out" "$ST/ps_fail" "$ST/startfail" "$ST/lsof_out_datadisk" "$ST/lsof_out_diffdisk" "$ST/lsof_diag"
echo stopped > "$ST/list_mode"
RC=0; env -i HOME="$HOME_D" PATH="$BIN:/usr/bin:/bin" DOCKER_PROBE_DEADLINE_SECONDS=2 \
  DOCKER_CONTEXT=other VACATE_CI_RUNNERS_APPROVED=1 \
  /bin/bash "$SCRIPT" --clean > "$TMP/out" 2>&1 || RC=$?
if [[ $(cnt '^colima start') -eq 0 && $(cnt '^limactl disk unlock') -eq 0 ]] && grep -q 'does not match the expected Colima socket' "$TMP/out"; then
  ok "unrelated explicit context: stays refused, nothing started"
else bad "unrelated explicit context"; fi

echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
