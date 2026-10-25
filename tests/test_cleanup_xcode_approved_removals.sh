#!/usr/bin/env bash
# test_cleanup_xcode_approved_removals.sh — approval gates and refusals of the
# targeted removals in cleanup_xcode.sh (--delete-runtimes, --device-support,
# --delete-device, --remove-xcode-app). Fake xcrun/xcode-select/defaults/pgrep
# and a fixture HOME; nothing touches the real simulators or /Applications.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_xcode.sh"
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPROOT="$(mktemp -d /tmp/dm-xcode-approved-test.XXXXXX)" || exit 1
[[ -d "$TMPROOT" && "$TMPROOT" == /tmp/dm-xcode-approved-test.* ]] || exit 1
TMPROOT="$(cd "$TMPROOT" && pwd -P)" || exit 1
cleanup() {
  case "$TMPROOT" in /tmp/dm-xcode-approved-test.*|/private/tmp/dm-xcode-approved-test.*) ;; *) return ;; esac
  [[ -d "$TMPROOT" ]] && /bin/rm -rf "$TMPROOT"
}
trap cleanup EXIT

export HOME="$TMPROOT/home"
APPS="$TMPROOT/Applications"
CALLS="$TMPROOT/xcrun-calls"
export DISK_MAGICIAN_DELETION_LOG="$TMPROOT/deletions.log"
mkdir -p "$HOME" "$TMPROOT/bin" "$TMPROOT/ptmp" "$TMPROOT/utmp" "$APPS"

RT_USED=11111111-1111-1111-1111-111111111111  # iOS 26.5, has a Booted device
RT_FREE=22222222-2222-2222-2222-222222222222  # iOS 18.6, only Shutdown devices
cat >"$TMPROOT/rt.json" <<JSON
{"$RT_USED":{"identifier":"$RT_USED","build":"23F77","version":"26.5","sizeBytes":10737418240,"runtimeIdentifier":"rt.iOS-26-5"},
 "$RT_FREE":{"identifier":"$RT_FREE","build":"22G86","version":"18.6","sizeBytes":8589934592,"runtimeIdentifier":"rt.iOS-18-6"}}
JSON
cat >"$TMPROOT/dev.json" <<'JSON'
{"devices":{"rt.iOS-26-5":[
  {"udid":"BOOTED-1","name":"iPhone 17","state":"Booted","dataPathSize":3000000000},
  {"udid":"SHUT-1","name":"iPhone 17 Pro","state":"Shutdown","dataPathSize":2000000000}],
 "rt.iOS-18-6":[{"udid":"SHUT-2","name":"old","state":"Shutdown","dataPathSize":1000}]}}
JSON

cat >"$TMPROOT/bin/xcrun" <<STUB
#!/bin/sh
echo "\$*" >>"$CALLS"
[ "\${FAKE_XCRUN_FAIL:-}" = 1 ] && exit 1
case "\$*" in
  "simctl runtime list -j") cat "$TMPROOT/rt.json" ;;
  "simctl list devices -j") cat "$TMPROOT/dev.json" ;;
esac
exit 0
STUB
cat >"$TMPROOT/bin/xcode-select" <<STUB
#!/bin/sh
echo "$APPS/Xcode-active.app/Contents/Developer"
STUB
# Bundle id is "com.apple.dt.Xcode" except for the NotXcode fixture; version from the dir name.
cat >"$TMPROOT/bin/defaults" <<'STUB'
#!/bin/sh
case "$2" in
  */NotXcode.app/*) [ "$3" = CFBundleIdentifier ] && echo com.example.other || echo 1.0 ;;
  *) [ "$3" = CFBundleIdentifier ] && echo com.apple.dt.Xcode || echo 27.1 ;;
esac
STUB
cat >"$TMPROOT/bin/pgrep" <<'STUB'
#!/bin/sh
case "$*" in *Xcode-running.app*) exit 0 ;; esac
exit 1
STUB
cat >"$TMPROOT/bin/lsof" <<'STUB'
#!/bin/sh
case " $* " in
  *" -d cwd "*) printf 'p1\nfcwd\nn/\n' ;;
  *) exit 1 ;;
esac
STUB
# Host rm/du shims resolve $HOME, which is a fixture here; use the real binaries.
ln -s /bin/rm "$TMPROOT/bin/rm"
chmod +x "$TMPROOT"/bin/*
export PATH="$TMPROOT/bin:$PATH"

for n in Xcode-active Xcode-other Xcode-running NotXcode; do
  mkdir -p "$APPS/$n.app/Contents"
  echo x >"$APPS/$n.app/Contents/Info.plist"
done
mkdir -p "$HOME/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,4 26.6.2"
echo sym >"$HOME/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,4 26.6.2/sym"
# C14 keeps recently written entries; age the fixture past that window.
touch -t 202001010000 "$HOME/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,4 26.6.2/sym" \
  "$HOME/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,4 26.6.2"

run() { # <args...>; env assignments via ENVS
  : >"$CALLS"
  OUT="$(env HOME="$HOME" PATH="$PATH" DISK_MAGICIAN_XCODE_APP_ROOT="$APPS" \
      DISK_MAGICIAN_DELETION_LOG="$DISK_MAGICIAN_DELETION_LOG" \
      DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMPROOT/ptmp" \
      DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp" \
      $ENVS bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
}
has() { [[ "$OUT" == *"$1"* ]]; }
called() { grep -q -- "$1" "$CALLS"; }

echo "== approval gates: --clean without the env var refuses (rc 3), mutates nothing =="
ENVS="env"
for args in "--delete-runtimes 22G86" "--device-support" "--delete-device SHUT-1" "--remove-xcode-app $APPS/Xcode-other.app"; do
  # shellcheck disable=SC2086
  run --clean $args
  [[ "$RC" -eq 3 ]] && has "Refusing" && ok "refused: $args" || bad "not refused ($RC): $args"
done
called "delete" && bad "a delete reached xcrun without approval" || ok "no simctl delete without approval"
[[ -d "$APPS/Xcode-other.app" && -d "$HOME/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,4 26.6.2" ]] \
  && ok "app and DeviceSupport untouched" || bad "something was removed without approval"

echo "== dry-run needs no approval and deletes nothing =="
run --dry-run --delete-runtimes 22G86 --delete-device SHUT-1 --device-support --remove-xcode-app "$APPS/Xcode-other.app"
[[ "$RC" -eq 0 ]] && has "would run: xcrun simctl runtime delete $RT_FREE" && has "would run: xcrun simctl delete SHUT-1" \
  && has "would delete contents of" && has "would remove Xcode 27.1" \
  && ok "all four previewed" || bad "dry-run output wrong (rc=$RC): $OUT"
called "runtime delete" || called "simctl delete" && bad "dry-run called a delete" || ok "dry-run made no delete call"
has "delete unavailable" && bad "default sweep ran in targeted mode" || ok "default sweep skipped in targeted mode"

echo "== runtimes: in-use refused, free one deleted + logged =="
ENVS="RUNTIMES_APPROVED=1"
run --clean --delete-runtimes 23F77
[[ "$RC" -ne 0 ]] && has "REFUSED (runtime 26.5 in use by Booted device iPhone 17)" && ! called "runtime delete" \
  && ok "runtime with Booted device refused by build" || bad "booted runtime not refused ($RC): $OUT"
run --clean --delete-runtimes "$RT_USED"
has "REFUSED" && ! called "runtime delete" && ok "refused by image id too" || bad "booted runtime deleted by id"
run --clean --delete-runtimes "22G86,23F77"
called "runtime delete $RT_FREE" && ! called "runtime delete $RT_USED" && [[ "$RC" -ne 0 ]] \
  && ok "free runtime deleted, in-use kept, rc reflects the refusal" || bad "mixed list wrong ($RC)"
grep -q "remove_runtime.*simruntime:$RT_FREE" "$DISK_MAGICIAN_DELETION_LOG" && ok "deletion logged" || bad "deletion not logged"
run --clean --delete-runtimes NOPE
has "REFUSED (0 runtimes match NOPE)" && ok "unknown runtime refused" || bad "unknown runtime accepted"

echo "== devices: Booted refused, Shutdown deleted + logged, unknown refused =="
ENVS="DEVICES_APPROVED=1"
run --clean --delete-device BOOTED-1
has "REFUSED (device iPhone 17 is Booted)" && ! called "simctl delete" && ok "Booted device refused" || bad "booted device not refused"
run --clean --delete-device SHUT-1
called "simctl delete SHUT-1" && [[ "$RC" -eq 0 ]] && ok "Shutdown device deleted" || bad "shutdown device not deleted ($RC)"
grep -q "remove_sim_device.*simdevice:SHUT-1" "$DISK_MAGICIAN_DELETION_LOG" && ok "device deletion logged" || bad "device deletion not logged"
run --clean --delete-device GHOST
has "not found" && ! called "simctl delete" && ok "unknown device refused" || bad "unknown device accepted"

echo "== simctl listing failure fails closed =="
ENVS="RUNTIMES_APPROVED=1 FAKE_XCRUN_FAIL=1"
run --clean --delete-runtimes 22G86
[[ "$RC" -ne 0 ]] && ! called "runtime delete" && has "fail closed" && ok "no delete when listing fails" || bad "did not fail closed ($RC)"

echo "== xcode app: active/non-Xcode/running refused, other removed + logged =="
ENVS="XCODE_APP_APPROVED=1"
for n in Xcode-active NotXcode Xcode-running; do
  run --clean --remove-xcode-app "$APPS/$n.app"
  [[ "$RC" -ne 0 && -d "$APPS/$n.app" ]] && has "REFUSED" && ok "$n refused and kept" || bad "$n not refused ($RC)"
done
run --clean --remove-xcode-app /etc
has "REFUSED" && ok "path outside the app root refused" || bad "outside path accepted"
run --clean --remove-xcode-app "$APPS/Xcode-other.app"
[[ "$RC" -eq 0 && ! -e "$APPS/Xcode-other.app" ]] && ok "non-active Xcode removed" || bad "Xcode-other not removed ($RC): $OUT"
grep -q "Xcode-other.app" "$DISK_MAGICIAN_DELETION_LOG" && ok "app removal logged" || bad "app removal not logged"

echo "== device support: cleared through the C14 primitive with approval =="
ENVS="DEVICE_SUPPORT_APPROVED=1"
run --clean --device-support
[[ "$RC" -eq 0 && ! -e "$HOME/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,4 26.6.2" ]] \
  && ok "DeviceSupport entries removed" || bad "DeviceSupport not cleared ($RC): $OUT"

echo "Passed: $PASS Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
