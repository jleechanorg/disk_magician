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
    "$TMPROOT/ptmp/worldai-ios-release-123/DerivedData/Build" "$TMPROOT/ptmp/worldai-ios-release-123/DerivedData/ModuleCache.noindex" \
    "$TMPROOT/ptmp/worldai_frontend/build-x/Build" "$TMPROOT/ptmp/worldai_frontend/build-x/ModuleCache.noindex" \
    "$TMPROOT/ptmp/worldai_frontend/evidence" "$TMPROOT/utmp/dd_t/Build" "$TMPROOT/utmp/dd_t/Index.noindex"
printf 'o' >"$TMPROOT/ptmp/pr7/dd/Build/a.o"
printf 'o' >"$TMPROOT/ptmp/worldai-ios-release-123/DerivedData/Build/a.o"
printf 'r' >"$TMPROOT/ptmp/worldai-ios-release-123/release.json"
printf 'o' >"$TMPROOT/ptmp/worldai_frontend/build-x/Build/a.o"
printf 'shot' >"$TMPROOT/ptmp/worldai_frontend/evidence/shot.png"
printf 'o' >"$TMPROOT/utmp/dd_t/Build/a.o"
mkdir -p "$HOME/dd_gen/Build/Intermediates.noindex/Pods.build/Objects-normal/arm64" "$HOME/dd_gen/Index.noindex/DataStore/v5/records/K2" \
    "$HOME/dd_envroot/Build" "$HOME/dd_envroot/Index.noindex" "$HOME/dd_secretjson/Build" "$HOME/dd_secretjson/Index.noindex"
printf 'o' >"$HOME/dd_gen/Build/Intermediates.noindex/Pods.build/Objects-normal/arm64/NativeRequestCredentials.o"
printf 'h' >"$HOME/dd_gen/Index.noindex/DataStore/v5/records/K2/NSURLCredentialStorage.h-abc"
printf 'K=v' >"$HOME/dd_envroot/.env"
printf '{}' >"$HOME/dd_secretjson/secrets.json"
# Standard DerivedData (HOME is the fixture): per-project children share the xcode kind.
SDD="$HOME/Library/Developer/Xcode/DerivedData"
[[ "$SDD" == "$TMPROOT"/home/* ]] || { echo "FAIL: standard DerivedData is not in the fixture tree" >&2; exit 1; }
mkdir -p "$SDD/wf-gen/Build/Intermediates.noindex/Pods.build/Objects-normal/arm64" "$SDD/wf-gen/Index.noindex/DataStore/v5/records/K2" \
    "$SDD/wf-env/Build" "$SDD/wf-env/Index.noindex"
printf 'o' >"$SDD/wf-gen/Build/Intermediates.noindex/Pods.build/Objects-normal/arm64/NativeRequestCredentials.o"
printf 'h' >"$SDD/wf-gen/Index.noindex/DataStore/v5/records/K2/NSURLCredentialStorage.h-abc"
printf 'K=v' >"$SDD/wf-env/.env"
printf '<key>WorkspacePath</key>' >"$HOME/dd_plist/info.plist"
printf 'o' >"$HOME/dd_buildonly/Build/x.o"
printf 'o' >"$HOME/dd_idle/Build/Products/a.o"
printf 'o' >"$HOME/dd_recent/Build/Products/a.o"
printf 'notes' >"$HOME/dd_notdd/notes.txt"
printf 'o' >"$HOME/proj_dd_nested/DerivedData/Build/b.o"
printf 'keep' >"$HOME/proj_dd_nested/README.md"
printf 'o' >"$HOME/real_dd/Build/c.o"
ln -s "$HOME/real_dd" "$HOME/dd_link"
age "$TMPROOT/ptmp" 120 && age "$TMPROOT/utmp" 120 && age "$HOME/dd_gen" 120 && age "$HOME/dd_envroot" 120 && age "$HOME/dd_secretjson" 120 && age "$HOME/dd_plist" 120 && age "$HOME/dd_buildonly" 120 && age "$HOME/dd_idle" 120 && age "$HOME/dd_notdd" 120 && age "$HOME/proj_dd_nested" 120 && age "$HOME/real_dd" 120
age "$SDD" 120
age "$HOME/dd_recent" 5

run() { bash "$REPO_ROOT/scripts/cleanup_xcode.sh" "$@" 2>&1; }
run_with_env() { env "$1=$2" bash "$REPO_ROOT/scripts/cleanup_xcode.sh" --clean 2>&1; }

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
[[ ! -e "$TMPROOT/ptmp/worldai-ios-release-123/DerivedData" && -f "$TMPROOT/ptmp/worldai-ios-release-123/release.json" ]] \
    && ok "worldai-ios-release-*/DerivedData under private tmp removed while parent kept" || bad "worldai-ios-release-123/DerivedData handling wrong"
[[ ! -e "$TMPROOT/ptmp/worldai_frontend/build-x" ]] && ok "worldai_frontend build dir removed" || bad "worldai_frontend/build-x still present"
[[ -f "$TMPROOT/ptmp/worldai_frontend/evidence/shot.png" ]] && ok "non-DerivedData worldai_frontend dir kept" || bad "worldai_frontend/evidence removed"
[[ ! -e "$TMPROOT/utmp/dd_t" ]] && ok "dd_* under the per-user temp root removed" || bad "utmp/dd_t still present"
[[ ! -e "$HOME/dd_gen" ]] && ok "generated *Credentials* build outputs do not block removal" || bad "dd_gen kept by the secret scan"
[[ -f "$HOME/dd_envroot/.env" ]] && ok "root .env keeps the dir" || bad "dd_envroot removed"
[[ -f "$HOME/dd_secretjson/secrets.json" ]] && ok "root secrets.json keeps the dir" || bad "dd_secretjson removed"
[[ ! -e "$SDD/wf-gen" ]] && ok "standard DerivedData child with generated *Credentials* outputs removed" || bad "standard wf-gen kept by the secret scan"
[[ -f "$SDD/wf-env/.env" ]] && ok "standard DerivedData child with a top-level .env kept" || bad "standard wf-env removed"
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

echo "-- retention floors reject zero and malformed environment overrides --"
mkdir -p "$HOME/dd_zero/Build" "$HOME/dd_zero/Index.noindex" \
    "$HOME/dd_malformed/Build" "$HOME/dd_malformed/Index.noindex"
printf 'o' >"$HOME/dd_zero/Build/a.o"
printf 'o' >"$HOME/dd_malformed/Build/a.o"
out="$(run_with_env CUSTOM_DD_IDLE_MINUTES 0)"
[[ -d "$HOME/dd_zero" ]] && ok "zero custom-DerivedData override keeps fresh output" || bad "zero override removed fresh output: $out"
[[ "$out" == *"within 60m"* ]] && ok "custom-DerivedData retention floor stays 60m" || bad "custom retention floor not reported: $out"
out="$(run_with_env CUSTOM_DD_IDLE_MINUTES malformed)"
[[ -d "$HOME/dd_malformed" ]] && ok "malformed custom-DerivedData override keeps fresh output" || bad "malformed override removed fresh output: $out"
[[ "$out" == *"within 60m"* ]] && ok "malformed custom-DerivedData override retains the 60m floor" || bad "custom retention floor not reported for malformed value: $out"

for spec in '124 1 0' '125 1 malformed'; do
    read -r run_id attempt override <<<"$spec"
    dir="$TMPROOT/ptmp/worldai-ios-release-$run_id-$attempt"
    mkdir -p "$dir/receipts" "$dir/DerivedData/Build" "$dir/verify-unpacked"
    printf '{}' >"$dir/receipts/export.json"
    printf 'o' >"$dir/DerivedData/Build/a.o"
    printf 'v' >"$dir/verify-unpacked/v"
    out="$(run_with_env IOS_RELEASE_IDLE_MINUTES "$override")"
    [[ -d "$dir/DerivedData" && -d "$dir/verify-unpacked" ]] \
        && ok "iOS release override '$override' keeps fresh rebuildable output" \
        || bad "iOS release override '$override' removed fresh output: $out"
    [[ "$out" == *"within 1440m"* ]] \
        && ok "iOS release retention floor stays 1440m for '$override'" \
        || bad "iOS release retention floor not reported for '$override': $out"
done

(( FAIL == 0 )) || printf '%s\n' "$out" | /usr/bin/grep -E "Custom|C14" >&2
echo "-- secret scan is kind-scoped --"
inv="$TMPROOT/inv.json"
printf '[{"path":".","name":"x"},{"path":"Build/a/NativeRequestCredentials.o"}]' >"$inv"
[[ "$(python3 "$REPO_ROOT/scripts/c14_probe.py" secrets "$inv" xcode-derived-data)" == no ]] && ok "xcode kind ignores generated credentials name" || bad "xcode kind flagged generated name"
[[ "$(python3 "$REPO_ROOT/scripts/c14_probe.py" secrets "$inv" rebuildable)" == yes ]] && ok "other kinds still flag it" || bad "non-xcode kind lost the secret scan"
[[ "$(python3 "$REPO_ROOT/scripts/c14_probe.py" secrets "$inv")" == yes ]] && ok "no kind still flags it" || bad "kindless scan lost the secret scan"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
