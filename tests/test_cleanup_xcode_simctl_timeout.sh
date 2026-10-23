#!/usr/bin/env bash
# test_cleanup_xcode_simctl_timeout.sh — bead disk_magician-wcxs: every
# `xcrun simctl` call in cleanup_xcode.sh is bounded. A wedged CoreSimulator
# (fake xcrun sleeps 90s) must not hold the script past
# DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS: it completes, logs the SKIP and still
# prints its summary. Without a timeout binary it skips (logged) instead of
# calling simctl unbounded. A simctl that returns immediately is unchanged.
# Fixture HOME and fixture scratch roots only; the test aborts if the real
# DerivedData/scratch roots would be in scope.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_xcode.sh"
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

TMPROOT="$(mktemp -d /tmp/dm-xcode-simctl-test.XXXXXX)" || exit 1
[[ -d "$TMPROOT" && "$TMPROOT" == /tmp/dm-xcode-simctl-test.* ]] || exit 1
TMPROOT="$(cd "$TMPROOT" && pwd -P)" || exit 1
cleanup() {
    case "$TMPROOT" in /tmp/dm-xcode-simctl-test.*|/private/tmp/dm-xcode-simctl-test.*) ;; *) return ;; esac
    [[ -d "$TMPROOT" ]] || return
    /bin/rm -rf "$TMPROOT"
}
trap cleanup EXIT

export HOME="$TMPROOT/home"
mkdir -p "$HOME" "$TMPROOT/bin" "$TMPROOT/ptmp" "$TMPROOT/utmp"
CALLS="$TMPROOT/xcrun-calls"

# Fake xcrun: FAKE_XCRUN_MODE=hang sleeps far past any configured bound and
# records that it was invoked (so "no hang" cannot be confused with "not called").
cat >"$TMPROOT/bin/xcrun" <<STUB
#!/bin/sh
echo "\$*" >>"$CALLS"
case "\${FAKE_XCRUN_MODE:-fast}" in
  hang) sleep 90 ;;
esac
exit 0
STUB
# lsof stub with no holders: no live-cwd/open-file probe against the host.
cat >"$TMPROOT/bin/lsof" <<'STUB'
#!/bin/sh
case " $* " in
  *" -d cwd "*) printf 'p1\nfcwd\nn/\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMPROOT/bin/xcrun" "$TMPROOT/bin/lsof"
export PATH="$TMPROOT/bin:$PATH"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMPROOT/ptmp"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp"
# shellcheck source=scripts/lib/scratch_roots.sh
source "$REPO_ROOT/scripts/lib/scratch_roots.sh"
[[ "$(scratch_roots_get_private_tmp)" == "$TMPROOT/ptmp" && "$(scratch_roots_get_user_tmp)" == "$TMPROOT/utmp" ]] \
    || { echo "FAIL: scratch roots not redirected into the fixture tree" >&2; exit 1; }

# A timeout binary must exist for the bounded cases; the script must fail closed
# (skip, logged) when it does not, which case 3 exercises via TIMEOUT_BIN.
HAVE_TIMEOUT=false
for cand in timeout gtimeout /opt/homebrew/bin/gtimeout /opt/homebrew/bin/timeout \
    /usr/local/bin/gtimeout /usr/local/bin/timeout; do
  if [[ "$cand" == /* ]]; then
    [[ -x "$cand" ]] && { HAVE_TIMEOUT=true; break; }
  elif command -v "$cand" >/dev/null 2>&1; then
    HAVE_TIMEOUT=true
    break
  fi
done

run_case() { # <label> <mode> <seconds> [env assignments...]
  local label="$1" mode="$2" seconds="$3"
  shift 3
  : >"$CALLS"
  CASE_START="$(date +%s)"
  CASE_OUT="$(env HOME="$HOME" PATH="$PATH" \
      DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMPROOT/ptmp" \
      DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp" \
      FAKE_XCRUN_MODE="$mode" DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS="$seconds" \
      "$@" bash "$SCRIPT" --clean 2>&1)"
  CASE_RC=$?
  CASE_ELAPSED=$(( $(date +%s) - CASE_START ))
  echo "  ($label: rc=$CASE_RC elapsed=${CASE_ELAPSED}s)"
}

out_has() { [[ "$CASE_OUT" == *"$1"* ]]; }
invoked() { [[ -s "$CALLS" ]]; }

echo "== case 1: hanging simctl delete unavailable is bounded, logged, non-fatal =="
if [[ "$HAVE_TIMEOUT" == true ]]; then
  run_case "unavailable-hang" hang 2
  [[ "$CASE_RC" -eq 0 ]] && ok "rc=0 despite hung simctl (non-fatal)" || bad "rc=$CASE_RC (expected 0)"
  invoked && ok "fake xcrun was actually invoked (the hang is real)" || bad "fake xcrun never invoked"
  out_has "running: xcrun simctl delete unavailable" && ok "normal log line preserved" || bad "missing 'running: xcrun simctl delete unavailable'"
  out_has "CoreSimulator unavailable (simctl timed out after 2s) — skipping simulator housekeeping" \
      && ok "timeout logged as a visible SKIP" || bad "timeout SKIP line missing"
  out_has "summary: simulator housekeeping degraded" && ok "summary reports degraded" || bad "summary missing/degraded not reported"
  (( CASE_ELAPSED >= 2 )) && ok "bound applied (elapsed ${CASE_ELAPSED}s >= 2s)" || bad "elapsed ${CASE_ELAPSED}s < 2s: bound not applied?"
  (( CASE_ELAPSED < 40 )) && ok "did not block past the bound (${CASE_ELAPSED}s << 90s hang)" || bad "blocked ${CASE_ELAPSED}s: still unbounded"
else
  bad "no timeout/gtimeout binary on this host; cannot exercise the bounded path"
fi

echo "== case 2: immediate simctl is unchanged (no false SKIP) =="
if [[ "$HAVE_TIMEOUT" == true ]]; then
  run_case "unavailable-fast" fast 2
  [[ "$CASE_RC" -eq 0 ]] && ok "rc=0" || bad "rc=$CASE_RC (expected 0)"
  invoked && ok "simctl was invoked" || bad "simctl not invoked on the fast path"
  out_has "running: xcrun simctl delete unavailable" && ok "normal log line preserved" || bad "missing normal log line"
  out_has "CoreSimulator unavailable" && bad "false timeout SKIP on a fast simctl" || ok "no false timeout SKIP"
  out_has "summary: simulator housekeeping completed" && ok "summary reports completed" || bad "summary missing/completed not reported"
  (( CASE_ELAPSED < 40 )) && ok "fast path completes promptly (${CASE_ELAPSED}s)" || bad "fast path took ${CASE_ELAPSED}s"
else
  bad "no timeout/gtimeout binary on this host; cannot exercise the fast path"
fi

echo "== case 3: no timeout binary means logged SKIP, never an unbounded call =="
run_case "no-timeout-binary" hang 2 DISK_MAGICIAN_TIMEOUT_BIN=/nonexistent/dm-timeout
[[ "$CASE_RC" -eq 0 ]] && ok "rc=0 without a timeout binary" || bad "rc=$CASE_RC (expected 0)"
invoked && bad "simctl was called unbounded (no timeout binary)" || ok "simctl not called unbounded"
out_has "simulator housekeeping skipped: no timeout(1)/gtimeout available" \
    && ok "skip is logged" || bad "logged skip missing"
out_has "summary: simulator housekeeping skipped (no timeout binary)" \
    && ok "summary reports the skip" || bad "summary missing/does not report the skip"
(( CASE_ELAPSED < 40 )) && ok "no unbounded wait (${CASE_ELAPSED}s)" || bad "waited ${CASE_ELAPSED}s"

echo "== case 4: --all-simulators bounds both shutdown all and delete all =="
if [[ "$HAVE_TIMEOUT" == true ]]; then
  # run_case always runs the default form; --all-simulators needs its own invocation.
  : >"$CALLS"
  CASE_START="$(date +%s)"
  CASE_OUT="$(env HOME="$HOME" PATH="$PATH" \
      DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMPROOT/ptmp" \
      DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp" \
      FAKE_XCRUN_MODE=hang DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS=2 SIMULATORS_APPROVED=1 \
      bash "$SCRIPT" --clean --all-simulators 2>&1)"
  CASE_RC=$?
  CASE_ELAPSED=$(( $(date +%s) - CASE_START ))
  [[ "$CASE_RC" -eq 0 ]] && ok "rc=0 although both simctl calls hung" || bad "rc=$CASE_RC (expected 0)"
  out_has "running: xcrun simctl shutdown all" && ok "shutdown all attempted" || bad "shutdown all not attempted"
  out_has "running: xcrun simctl delete all" && ok "delete all still runs after a timed-out shutdown (fail-open preserved)" \
      || bad "delete all skipped after a timed-out shutdown"
  [[ "$(grep -c 'CoreSimulator unavailable (simctl timed out after 2s)' <<<"$CASE_OUT")" -eq 2 ]] \
      && ok "both calls logged their SKIP" || bad "expected 2 SKIP lines, got $(grep -c 'CoreSimulator unavailable' <<<"$CASE_OUT")"
  out_has "summary: simulator housekeeping degraded" && ok "summary reports degraded" || bad "summary missing/degraded not reported"
  (( CASE_ELAPSED < 40 )) && ok "both calls bounded (${CASE_ELAPSED}s << 180s of hang)" || bad "blocked ${CASE_ELAPSED}s"
else
  bad "no timeout/gtimeout binary on this host; cannot exercise --all-simulators"
fi

echo
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
