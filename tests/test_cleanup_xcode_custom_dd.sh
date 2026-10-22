#!/usr/bin/env bash
# test_cleanup_xcode_custom_dd.sh — cleanup_xcode.sh clean_custom_derived_data:
# idle DerivedData-shaped dirs outside ~/Library are removed through C14 and
# logged; recent, non-DerivedData, symlinked and unmeasurable ones are kept.
# Temp HOME only; nothing outside it is touched.
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
NOW="$(date +%s)"
stamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S; }
age() { find "$1" -exec touch -h -t "$(stamp $((NOW - $2 * 60)))" {} +; }

mkdir -p "$HOME/dd_idle/Build/Products" "$HOME/dd_idle/Index.noindex" \
    "$HOME/dd_recent/Build/Products" "$HOME/dd_recent/Index.noindex" \
    "$HOME/dd_notdd" "$HOME/proj_dd_nested/DerivedData/Build" "$HOME/proj_dd_nested/DerivedData/Logs.noindex" \
    "$HOME/real_dd/Build" "$HOME/real_dd/Index.noindex"
printf 'o' >"$HOME/dd_idle/Build/Products/a.o"
printf 'o' >"$HOME/dd_recent/Build/Products/a.o"
printf 'notes' >"$HOME/dd_notdd/notes.txt"
printf 'o' >"$HOME/proj_dd_nested/DerivedData/Build/b.o"
printf 'keep' >"$HOME/proj_dd_nested/README.md"
printf 'o' >"$HOME/real_dd/Build/c.o"
ln -s "$HOME/real_dd" "$HOME/dd_link"
age "$HOME/dd_idle" 120 && age "$HOME/dd_notdd" 120 && age "$HOME/proj_dd_nested" 120 && age "$HOME/real_dd" 120
age "$HOME/dd_recent" 5

run() { bash "$REPO_ROOT/scripts/cleanup_xcode.sh" "$@" 2>&1; }

echo "-- dry run --"
out="$(run --dry-run)"
[[ "$out" == *"would remove $HOME/dd_idle"* ]] && ok "dry-run names the idle dir" || bad "dry-run missed idle dir: $out"
[[ "$out" == *"keeping $HOME/dd_recent"* ]] && ok "dry-run keeps the recent dir" || bad "dry-run did not report recent dir"
[[ -d "$HOME/dd_idle" ]] && ok "dry-run removes nothing" || bad "dry-run removed dd_idle"

echo "-- clean --"
out="$(run --clean)"
[[ ! -e "$HOME/dd_idle" ]] && ok "idle DerivedData-shaped dir removed" || bad "dd_idle still present: $out"
[[ -d "$HOME/dd_recent" ]] && ok "recent dir kept" || bad "recent dir removed"
[[ -f "$HOME/dd_notdd/notes.txt" ]] && ok "non-DerivedData dir kept" || bad "non-DerivedData dir removed"
[[ ! -e "$HOME/proj_dd_nested/DerivedData" && -f "$HOME/proj_dd_nested/README.md" ]] \
    && ok "only the DerivedData/ child of a parent is removed" || bad "nested DerivedData handling wrong"
[[ -L "$HOME/dd_link" ]] && ok "symlink itself left in place" || bad "symlink removed"
[[ ! -e "$HOME/real_dd" ]] && ok "real_dd (matched *_dd*, idle, shaped) removed via its own path" || bad "real_dd still present"
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

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
