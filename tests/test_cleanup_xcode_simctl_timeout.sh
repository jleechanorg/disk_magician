#!/usr/bin/env bash
# test_cleanup_xcode_simctl_timeout.sh — cleanup_xcode.sh must bound every
# `xcrun simctl` call. A stub xcrun that sleeps far past the bound proves the
# sweep still finishes near the bound (not the stub's sleep), logs a timeout
# warning naming the subcommand, and keeps fail-open semantics (the next simctl
# call still runs). Both the coreutils path and the pure-bash watchdog fallback
# are exercised. Temp HOME and temp scratch roots only; the script's /private/tmp
# and per-user temp globs are redirected into the fixture tree.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPROOT="$(mktemp -d /tmp/dm-xcode-simctl-test.XXXXXX)" || exit 1
[[ -d "$TMPROOT" && "$TMPROOT" == /tmp/dm-xcode-simctl-test.* ]] || exit 1
TMPROOT="$(cd "$TMPROOT" && pwd -P)" || exit 1
cleanup() {
    case "$TMPROOT" in /tmp/dm-xcode-simctl-test.*|/private/tmp/dm-xcode-simctl-test.*) ;; *) return ;; esac
    [[ -d "$TMPROOT" ]] || return
    pkill -f "$TMPROOT/fakebin/xcrun" 2>/dev/null || true
    chmod -R u+rwx "$TMPROOT" 2>/dev/null
    /bin/rm -rf "$TMPROOT"
}
trap cleanup EXIT

export HOME="$TMPROOT/home"
mkdir -p "$HOME"
mkdir -p "$TMPROOT/fakebin" "$TMPROOT/ptmp" "$TMPROOT/utmp"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMPROOT/ptmp"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp"
# shellcheck source=scripts/lib/scratch_roots.sh
source "$REPO_ROOT/scripts/lib/scratch_roots.sh"
[[ "$(scratch_roots_get_private_tmp)" == "$TMPROOT/ptmp" && "$(scratch_roots_get_user_tmp)" == "$TMPROOT/utmp" ]] \
    || { echo "FAIL: scratch roots not redirected into the fixture tree" >&2; exit 1; }

# lsof stub with no holders: no unreadable foreign process can turn the live-cwd
# or open-file gate into kept:cwd-unknown / kept:open-file inside the fixture.
cat >"$TMPROOT/fakebin/lsof" <<'STUB'
#!/bin/sh
case " $* " in
  *" -d cwd "*) printf 'p1\nfcwd\nn/\n' ;;
  *) exit 1 ;;
esac
STUB

# xcrun stub: record the invocation, then hang far past the bound. HANG controls
# the sleep so one case can also prove a fast simctl succeeds silently.
cat >"$TMPROOT/xcrun-stub" <<STUB
#!/bin/sh
printf '%s\\n' "\$*" >>"$TMPROOT/xcrun.log"
sleep "\${STUB_SLEEP:-30}"
exit 0
STUB
chmod +x "$TMPROOT/fakebin/lsof" "$TMPROOT/xcrun-stub"
ln -s "$TMPROOT/xcrun-stub" "$TMPROOT/fakebin/xcrun"
[[ -x "$TMPROOT/fakebin/xcrun" ]] || { echo "FAIL: xcrun stub not installed" >&2; exit 1; }
export PATH="$TMPROOT/fakebin:$PATH"

run() { bash "$REPO_ROOT/scripts/cleanup_xcode.sh" "$@" 2>&1; }
reset_stub() { : >"$TMPROOT/xcrun.log"; }

have_timeout_bin=no
for c in timeout /opt/homebrew/bin/gtimeout /opt/homebrew/bin/timeout /usr/local/bin/gtimeout /usr/local/bin/timeout; do
    if [[ "$c" == /* ]]; then [[ -x "$c" ]] && { have_timeout_bin=yes; break; }
    else command -v "$c" >/dev/null 2>&1 && { have_timeout_bin=yes; break; }; fi
done
echo "host coreutils timeout available: $have_timeout_bin"

BOUND=2
echo "-- pure-bash watchdog fallback: delete unavailable --"
reset_stub
start=$(date +%s)
out="$(DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS=$BOUND DISK_MAGICIAN_TIMEOUT_BIN=none run --clean 2>&1)"; rc=$?
end=$(date +%s)
elapsed=$((end - start))
[[ $rc -eq 0 ]] && ok "cleanup_xcode exits 0 after a hung simctl" || bad "cleanup_xcode exited $rc"
[[ "$out" == *"simctl delete unavailable: timed out after ${BOUND}s"* ]] \
    && ok "timeout warning names the subcommand" || bad "missing/incorrect timeout warning: $out"
[[ $elapsed -lt 20 ]] && ok "bounded finish: ${elapsed}s well under the 30s stub sleep" \
    || bad "cleanup took ${elapsed}s ($BOUND s bound not enforced)"
[[ "$(<"$TMPROOT/xcrun.log")" == *"simctl delete unavailable"* ]] \
    && ok "hung simctl was invoked once" || bad "simctl delete unavailable never invoked"

echo "-- pure-bash watchdog fallback: shutdown all + delete all (fail-open) --"
reset_stub
start=$(date +%s)
out="$(SIMULATORS_APPROVED=1 DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS=$BOUND DISK_MAGICIAN_TIMEOUT_BIN=none run --clean --all-simulators 2>&1)"; rc=$?
end=$(date +%s)
elapsed=$((end - start))
[[ $rc -eq 0 ]] && ok "cleanup_xcode exits 0 with two hung simctl calls" || bad "cleanup_xcode exited $rc"
[[ "$out" == *"simctl shutdown all: timed out after ${BOUND}s"* ]] \
    && ok "shutdown-all timeout named" || bad "no shutdown-all timeout warning: $out"
[[ "$out" == *"simctl delete all: timed out after ${BOUND}s"* ]] \
    && ok "delete-all timeout named" || bad "no delete-all timeout warning: $out"
# Two 30s hangs would be 60s unbounded; a bounded run costs ~2 bounds + 1s kill grace each.
[[ $elapsed -lt 20 ]] && ok "two hung calls bounded: ${elapsed}s (not 60s)" \
    || bad "two hung calls took ${elapsed}s"
grep -qx "simctl shutdown all" "$TMPROOT/xcrun.log" && grep -qx "simctl delete all" "$TMPROOT/xcrun.log" \
    && ok "delete-all still ran after shutdown-all timed out (fail-open preserved)" \
    || bad "fail-open broken; xcrun.log: $(<"$TMPROOT/xcrun.log")"

echo "-- coreutils timeout path (skipped when absent) --"
if [[ "$have_timeout_bin" == yes ]]; then
    reset_stub
    start=$(date +%s)
    out="$(DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS=$BOUND DISK_MAGICIAN_TIMEOUT_BIN='' run --clean 2>&1)"; rc=$?
    end=$(date +%s)
    elapsed=$((end - start))
    [[ $rc -eq 0 && "$out" == *"simctl delete unavailable: timed out after ${BOUND}s"* ]] \
        && ok "coreutils timeout path bounds simctl and warns" || bad "coreutils path failed: rc=$rc $out"
    [[ $elapsed -lt 20 ]] && ok "coreutils path bounded finish: ${elapsed}s" || bad "coreutils path took ${elapsed}s"
else
    ok "no coreutils timeout on this host; pure-bash fallback is the only path (already proven above)"
fi

echo "-- fast simctl: no false timeout warning --"
reset_stub
out="$(STUB_SLEEP=0 DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS=$BOUND DISK_MAGICIAN_TIMEOUT_BIN=none run --clean 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "fast simctl run exits 0" || bad "fast simctl run exited $rc"
[[ "$out" != *"timed out"* ]] && ok "no timeout warning for a fast simctl" || bad "false timeout warning: $out"

echo "-- invalid env value fails safe, dry-run shape unchanged --"
out="$(DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS=abc STUB_SLEEP=0 run --clean 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" != *"timed out"* ]] && ok "non-numeric override falls back to the default bound" \
    || bad "non-numeric override broke the run: rc=$rc $out"
reset_stub
out="$(DISK_MAGICIAN_SIMCTL_TIMEOUT_SECONDS=$BOUND run --dry-run --all-simulators 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "dry-run exits 0" || bad "dry-run exited $rc"
[[ "$out" == *"[dry-run] would run: xcrun simctl shutdown all"* && "$out" == *"[dry-run] would run: xcrun simctl delete all"* ]] \
    && ok "dry-run output shape unchanged" || bad "dry-run output changed: $out"
[[ ! -s "$TMPROOT/xcrun.log" ]] && ok "dry-run runs no simctl" || bad "dry-run invoked simctl: $(<"$TMPROOT/xcrun.log")"
[[ "$out" != *"timed out"* ]] && ok "dry-run emits no timeout warning" || bad "dry-run emitted a timeout warning"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
