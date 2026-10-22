#!/usr/bin/env bash
# test_cleanup_xcode_custom_dd.sh — cleanup_xcode.sh clean_custom_derived_data:
# idle DerivedData-shaped dirs outside ~/Library are removed through C14 and
# logged; recent, non-DerivedData, symlinked and unmeasurable ones are kept.
# Temp HOME and temp scratch roots only; the script's /private/tmp and per-user temp
# globs are redirected into the fixture tree, and the test aborts if they are not.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPROOT="$(mktemp -d /tmp/dm-xcode-dd-test.XXXXXX)" || exit 1
[[ -d "$TMPROOT" && "$TMPROOT" == /tmp/dm-xcode-dd-test.* ]] || exit 1
TMPROOT="$(cd "$TMPROOT" && pwd -P)" || exit 1
cleanup() {
    case "$TMPROOT" in /tmp/dm-xcode-dd-test.*|/private/tmp/dm-xcode-dd-test.*) ;; *) return ;; esac
    [[ -d "$TMPROOT" ]] || return
    chmod -R u+rwx "$TMPROOT" 2>/dev/null
    /bin/rm -rf "$TMPROOT"
}
trap cleanup EXIT
export HOME="$TMPROOT/home"
mkdir -p "$HOME"
# lsof stub with no holders: a complete, empty cwd map for the live-cwd gate and no
# output for the open-file probe, so a shared host's unreadable foreign processes
# cannot turn either gate into kept:cwd-unknown / kept:open-file.
mkdir -p "$TMPROOT/fakebin"
cat >"$TMPROOT/fakebin/lsof" <<'STUB'
#!/bin/sh
case " $* " in
  *" -d cwd "*) printf 'p1\nfcwd\nn/\n' ;;
  *) exit 1 ;;
esac
STUB
# xcrun stub: --clean would otherwise run `simctl delete unavailable` on the real host.
printf '#!/bin/sh\nexit 0\n' >"$TMPROOT/fakebin/xcrun"
chmod +x "$TMPROOT/fakebin/lsof" "$TMPROOT/fakebin/xcrun"
export PATH="$TMPROOT/fakebin:$PATH"
mkdir -p "$TMPROOT/ptmp" "$TMPROOT/utmp"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$TMPROOT/ptmp"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp"
# Fuse: never run --clean unless every scan root resolves inside the fixture tree.
# shellcheck source=scripts/lib/scratch_roots.sh
source "$REPO_ROOT/scripts/lib/scratch_roots.sh"
[[ "$(scratch_roots_get_private_tmp)" == "$TMPROOT/ptmp" && "$(scratch_roots_get_user_tmp)" == "$TMPROOT/utmp" ]] \
    || { echo "FAIL: scratch roots not redirected into the fixture tree" >&2; exit 1; }
NOW="$(date +%s)"
stamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S; }
age() { find "$1" -exec touch -h -t "$(stamp $((NOW - $2 * 60)))" {} +; }

mkdir -p "$HOME/dd_idle/Build/Products" "$HOME/dd_idle/Index.noindex" \
    "$HOME/dd_recent/Build/Products" "$HOME/dd_recent/Index.noindex" \
    "$HOME/dd_notdd" "$HOME/proj_dd_nested/DerivedData/Build" "$HOME/proj_dd_nested/DerivedData/Logs.noindex" \
    "$HOME/real_dd/Build" "$HOME/real_dd/Index.noindex" "$HOME/dd_plist" "$HOME/dd_buildonly/Build"
mkdir -p "$TMPROOT/ptmp/pr7/dd/Build" "$TMPROOT/ptmp/pr7/dd/Index.noindex" \
    "$TMPROOT/ptmp/worldai_frontend/build-x/Build" "$TMPROOT/ptmp/worldai_frontend/build-x/ModuleCache.noindex" \
    "$TMPROOT/ptmp/worldai_frontend/evidence" "$TMPROOT/utmp/dd_t/Build" "$TMPROOT/utmp/dd_t/Index.noindex"
printf 'o' >"$TMPROOT/ptmp/pr7/dd/Build/a.o"
printf 'o' >"$TMPROOT/ptmp/worldai_frontend/build-x/Build/a.o"
printf 'shot' >"$TMPROOT/ptmp/worldai_frontend/evidence/shot.png"
printf 'o' >"$TMPROOT/utmp/dd_t/Build/a.o"
printf '<key>WorkspacePath</key>' >"$HOME/dd_plist/info.plist"
printf 'o' >"$HOME/dd_buildonly/Build/x.o"
printf 'o' >"$HOME/dd_idle/Build/Products/a.o"
printf 'o' >"$HOME/dd_recent/Build/Products/a.o"
printf 'notes' >"$HOME/dd_notdd/notes.txt"
printf 'o' >"$HOME/proj_dd_nested/DerivedData/Build/b.o"
printf 'keep' >"$HOME/proj_dd_nested/README.md"
printf 'o' >"$HOME/real_dd/Build/c.o"
ln -s "$HOME/real_dd" "$HOME/dd_link"
age "$TMPROOT/ptmp" 120 && age "$TMPROOT/utmp" 120 && age "$HOME/dd_plist" 120 && age "$HOME/dd_buildonly" 120 && age "$HOME/dd_idle" 120 && age "$HOME/dd_notdd" 120 && age "$HOME/proj_dd_nested" 120 && age "$HOME/real_dd" 120
age "$HOME/dd_recent" 5

run() { bash "$REPO_ROOT/scripts/cleanup_xcode.sh" "$@" 2>&1; }

echo "-- dry run --"
out="$(run --dry-run)"
[[ "$out" == *"would remove $HOME/dd_idle"* ]] && ok "dry-run names the idle dir" || bad "dry-run missed idle dir: $out"
[[ "$out" == *"keeping $HOME/dd_recent"* ]] && ok "dry-run keeps the recent dir" || bad "dry-run did not report recent dir"
[[ -d "$HOME/dd_idle" ]] && ok "dry-run removes nothing" || bad "dry-run removed dd_idle"

echo "-- clean --"
out="$(run --clean)"
[[ ! -e "$HOME/dd_idle" ]] && ok "idle DerivedData-shaped dir removed" || bad "dd_idle still present"
[[ -d "$HOME/dd_recent" ]] && ok "recent dir kept" || bad "recent dir removed"
[[ -f "$HOME/dd_notdd/notes.txt" ]] && ok "non-DerivedData dir kept" || bad "non-DerivedData dir removed"
[[ ! -e "$HOME/proj_dd_nested/DerivedData" && -f "$HOME/proj_dd_nested/README.md" ]] \
    && ok "only the DerivedData/ child of a parent is removed" || bad "nested DerivedData handling wrong"
[[ -L "$HOME/dd_link" ]] && ok "symlink itself left in place" || bad "symlink removed"
[[ ! -e "$HOME/real_dd" ]] && ok "real_dd (matched *_dd*, idle, shaped) removed via its own path" || bad "real_dd still present"
[[ ! -e "$HOME/dd_plist" ]] && ok "dir whose info.plist names a WorkspacePath removed" || bad "dd_plist still present"
[[ -d "$HOME/dd_buildonly" ]] && ok "Build/ without *.noindex kept" || bad "dd_buildonly removed"
[[ ! -e "$TMPROOT/ptmp/pr7/dd" ]] && ok "pr*/dd under the private tmp root removed" || bad "ptmp/pr7/dd still present"
[[ ! -e "$TMPROOT/ptmp/worldai_frontend/build-x" ]] && ok "worldai_frontend build dir removed" || bad "worldai_frontend/build-x still present"
[[ -f "$TMPROOT/ptmp/worldai_frontend/evidence/shot.png" ]] && ok "non-DerivedData worldai_frontend dir kept" || bad "worldai_frontend/evidence removed"
[[ ! -e "$TMPROOT/utmp/dd_t" ]] && ok "dd_* under the per-user temp root removed" || bad "utmp/dd_t still present"
log="$HOME/Library/Logs/disk-magician-deletions.log"
if [[ -f "$log" ]] && [[ "$(<"$log")" == *"$HOME/dd_idle"* ]]; then ok "removal recorded in the deletion log"; else bad "no deletion-log line for dd_idle"; fi

echo "-- unmeasurable recency --"
if [[ "$(id -u)" != 0 ]]; then
    mkdir -p "$HOME/dd_unmeasured/Build" "$HOME/dd_unmeasured/Index.noindex/sub"
    age "$HOME/dd_unmeasured" 120
    chmod 000 "$HOME/dd_unmeasured/Index.noindex/sub"
    run --clean >/dev/null
    chmod 755 "$HOME/dd_unmeasured/Index.noindex/sub"
    [[ -d "$HOME/dd_unmeasured" ]] && ok "unreadable tree is kept" || bad "unreadable tree removed"
fi

(( FAIL == 0 )) || printf '%s\n' "$out" | /usr/bin/grep -E "Custom|C14" >&2
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
