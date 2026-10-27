#!/usr/bin/env bash
# test_cleanup_xcode_ios_release.sh — cleanup_xcode.sh clean_ios_release_scratch:
# only DerivedData/ and verify-unpacked/ of a finished (receipts/export.json), idle
# worldai-ios-release-<run>-<attempt> dir are removed; archive, export, receipts and the
# parent stay. Temp HOME and a scratch root redirected into the fixture tree; xcrun and lsof stubbed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPROOT="$(mktemp -d /tmp/dm-xcode-ios-test.XXXXXX)" || exit 1
[[ -d "$TMPROOT" && "$TMPROOT" == /tmp/dm-xcode-ios-test.* ]] || exit 1
TMPROOT="$(cd "$TMPROOT" && pwd -P)" || exit 1
cleanup() {
    case "$TMPROOT" in /tmp/dm-xcode-ios-test.*|/private/tmp/dm-xcode-ios-test.*) ;; *) return ;; esac
    [[ -d "$TMPROOT" ]] || return
    chmod -R u+rwx "$TMPROOT" 2>/dev/null
    /bin/rm -rf "$TMPROOT"
}
trap cleanup EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME" "$TMPROOT/fakebin" "$TMPROOT/ptmp" "$TMPROOT/utmp"
cat >"$TMPROOT/fakebin/lsof" <<'STUB'
#!/bin/sh
case " $* " in
  *" -d cwd "*) printf 'p1\nfcwd\nn/\n' ;;
  *) exit 1 ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' >"$TMPROOT/fakebin/xcrun"
chmod +x "$TMPROOT/fakebin/lsof" "$TMPROOT/fakebin/xcrun"
export PATH="$TMPROOT/fakebin:$PATH"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMPROOT/ptmp"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp"
# shellcheck source=scripts/lib/scratch_roots.sh
source "$REPO_ROOT/scripts/lib/scratch_roots.sh"
[[ "$(scratch_roots_get_private_tmp)" == "$TMPROOT/ptmp" ]] \
    || { echo "FAIL: scratch root not redirected into the fixture tree" >&2; exit 1; }

NOW="$(date +%s)"
stamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S; }
age() { find "$1" -exec touch -h -t "$(stamp $((NOW - $2 * 60)))" {} +; }

P="$TMPROOT/ptmp"
mk_release() { # <name> <with-export-receipt 0|1>
    local d="$P/$1"
    mkdir -p "$d/DerivedData/Build/Products" "$d/DerivedData/Index.noindex" "$d/verify-unpacked/Payload/App.app" \
        "$d/WorldAIClaw.xcarchive" "$d/export" "$d/receipts"
    printf 'o' >"$d/DerivedData/Build/Products/a.o"
    printf 'x' >"$d/verify-unpacked/Payload/App.app/bin"
    printf 'a' >"$d/WorldAIClaw.xcarchive/Info.plist"
    printf 'i' >"$d/export/App.ipa"
    printf '{}' >"$d/receipts/archive.json"
    (( $2 )) && printf '{}' >"$d/receipts/export.json"
    return 0
}
mk_release worldai-ios-release-100-1 1   # finished, idle
mk_release worldai-ios-release-200-1 1   # finished, recent
mk_release worldai-ios-release-300-1 0   # no export receipt
mk_release worldai-ios-release-400-1 1   # finished, idle, secret at root
printf 'K=v' >"$P/worldai-ios-release-400-1/verify-unpacked/.env"
mk_release not-ios-release-500-1 1       # name does not match
mk_release worldai-ios-release-600-1 1   # finished, idle, DerivedData is a symlink
/bin/rm -rf "$P/worldai-ios-release-600-1/DerivedData"
mkdir -p "$TMPROOT/real_dd/Build" "$TMPROOT/real_dd/Index.noindex"
ln -s "$TMPROOT/real_dd" "$P/worldai-ios-release-600-1/DerivedData"
for r in worldai-ios-release-100-1 worldai-ios-release-300-1 worldai-ios-release-400-1 not-ios-release-500-1 worldai-ios-release-600-1; do age "$P/$r" 1500; done
age "$TMPROOT/real_dd" 1500
age "$P" 1500
age "$P/worldai-ios-release-200-1" 5

run() { bash "$REPO_ROOT/scripts/cleanup_xcode.sh" "$@" 2>&1; }

echo "-- dry run --"
out="$(run --dry-run)"
[[ "$out" == *"would remove $P/worldai-ios-release-100-1/DerivedData"* && "$out" == *"would remove $P/worldai-ios-release-100-1/verify-unpacked"* ]] \
    && ok "dry-run names both rebuildable children" || bad "dry-run missed children: $out"
[[ -d "$P/worldai-ios-release-100-1/DerivedData" ]] && ok "dry-run removes nothing" || bad "dry-run removed DerivedData"

echo "-- clean --"
out="$(run --clean)"
r="$P/worldai-ios-release-100-1"
[[ ! -e "$r/DerivedData" && ! -e "$r/verify-unpacked" ]] && ok "idle finished dir loses DerivedData and verify-unpacked" || bad "children still present: $out"
[[ -d "$r/WorldAIClaw.xcarchive" && -f "$r/export/App.ipa" && -f "$r/receipts/export.json" && -d "$r" ]] \
    && ok "archive, export, receipts and parent kept" || bad "kept content removed"
r="$P/worldai-ios-release-200-1"
[[ -d "$r/DerivedData" && -d "$r/verify-unpacked" ]] && ok "recent dir untouched" || bad "recent dir removed"
r="$P/worldai-ios-release-300-1"
[[ -d "$r/DerivedData" && -d "$r/verify-unpacked" ]] && ok "dir without export receipt untouched" || bad "unreceipted dir removed"
r="$P/worldai-ios-release-400-1"
[[ -f "$r/verify-unpacked/.env" && ! -e "$r/DerivedData" ]] && ok "root .env keeps verify-unpacked; DerivedData still removed" || bad "secret handling wrong"
[[ -d "$P/not-ios-release-500-1/DerivedData" && -d "$P/not-ios-release-500-1/verify-unpacked" ]] && ok "non-matching dir name untouched" || bad "non-matching dir touched"
r="$P/worldai-ios-release-600-1"
[[ -L "$r/DerivedData" && -d "$TMPROOT/real_dd/Build" && ! -e "$r/verify-unpacked" ]] && ok "symlinked DerivedData left alone" || bad "symlink handling wrong"
log="$HOME/Library/Logs/disk-magician-deletions.log"
if [[ -f "$log" ]] && [[ "$(<"$log")" == *"worldai-ios-release-100-1/verify-unpacked"* ]]; then ok "removal recorded in the deletion log"; else bad "no deletion-log line"; fi

echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || printf '%s\n' "$out" | /usr/bin/grep -E "iOS|C14" >&2
[[ $FAIL -eq 0 ]]
