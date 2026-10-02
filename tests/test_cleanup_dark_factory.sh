#!/usr/bin/env bash
# Tests for scripts/cleanup_dark_factory.sh retention rules, in a sandboxed HOME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/cleanup_dark_factory.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/test_cleanup_dark_factory_XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

PASS=0
FAIL=0
check() {
  if eval "$2"; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi
}
age() { python3 - "$1" "$2" <<'PY'
import os, sys, time
root, days = sys.argv[1], float(sys.argv[2])
t = time.time() - days * 86400
for d, dirs, files in os.walk(root):
    for f in files + dirs:
        os.utime(os.path.join(d, f), (t, t))
os.utime(root, (t, t))
PY
}

REL="$T/.local/share/dark-factory/releases"
RUNS="$T/.dark-factory/runs"
SESS="$T/.ao-sessions"
mkdir -p "$REL" "$RUNS" "$SESS" "$T/.local/bin" "$T/.config/systemd/user"

# Six releases: r1 oldest .. r6 newest; r1 is the live symlink target.
for i in 1 2 3 4 5 6; do
  mkdir -p "$REL/r$i/bin"; echo x >"$REL/r$i/bin/dark-factory"
  age "$REL/r$i" $(( 100 - i ))
done
ln -s "$REL/r1/bin/dark-factory" "$T/.local/bin/dark-factory"

mkdir -p "$RUNS/old" "$RUNS/recent" "$RUNS/unreadable/inner"
echo x >"$RUNS/old/manifest.json"; age "$RUNS/old" 60
echo x >"$RUNS/recent/manifest.json"; age "$RUNS/recent" 60; touch "$RUNS/recent/manifest.json"
echo x >"$RUNS/unreadable/inner/f"; age "$RUNS/unreadable" 60; chmod 000 "$RUNS/unreadable/inner"; touch -d "@$(( $(date +%s) - 60*86400 ))" "$RUNS/unreadable" 2>/dev/null || python3 -c "import os,time,sys;t=time.time()-60*86400;os.utime(sys.argv[1],(t,t))" "$RUNS/unreadable"

mkdir -p "$SESS/df-old" "$SESS/df-recent" "$SESS/other-old"
for s in df-old df-recent other-old; do echo x >"$SESS/$s/f"; age "$SESS/$s" 60; done
touch "$SESS/df-recent/f"

run() {
  HOME="$T" DISK_MAGICIAN_TEST_SANDBOX="$T" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_dark_factory \
    DISK_MAGICIAN_DELETION_LOG="$T/deletions.log" bash "$SCRIPT" "$@"
}

echo "Test 1: dry-run deletes nothing"
run --dry-run >"$T/dry.out"
check "dry-run left old run" '[[ -d "$RUNS/old" ]]'
check "dry-run left oldest release" '[[ -d "$REL/r2" ]]'
check "dry-run reports would-remove" 'grep -q "would remove run: $RUNS/old" "$T/dry.out"'

echo "Test 2: --clean applies retention"
run --clean >"$T/clean.out"
check "live symlinked release r1 kept" '[[ -d "$REL/r1" ]]'
check "newest 3 releases kept" '[[ -d "$REL/r4" && -d "$REL/r5" && -d "$REL/r6" ]]'
check "stale unreferenced releases removed" '[[ ! -e "$REL/r2" && ! -e "$REL/r3" ]]'
check "stale run removed" '[[ ! -e "$RUNS/old" ]]'
check "run with a recent file kept" '[[ -d "$RUNS/recent" ]]'
check "unmeasurable run kept (fail closed)" '[[ -d "$RUNS/unreadable" ]]'
check "stale df-* session removed" '[[ ! -e "$SESS/df-old" ]]'
check "recent df-* session kept" '[[ -d "$SESS/df-recent" ]]'
check "non-df session untouched" '[[ -d "$SESS/other-old" ]]'
check "deletions logged" 'grep -q "remove_run" "$T/deletions.log"'

echo "Test 4: reference styles, non-dir entries, symlinked entries and roots"
H="$T/h4"; R4="$H/.local/share/dark-factory/releases"
mkdir -p "$R4" "$H/.local/bin" "$H/.config/systemd/user" "$H/.dark-factory/runs" "$H/.ao-sessions" "$H/outside/keepme"
for i in 1 2 3 4 5 6 7 8; do mkdir -p "$R4/r$i/bin"; echo x >"$R4/r$i/bin/dark-factory"; age "$R4/r$i" $(( 100 - i )); done
ln -s "$R4/r1/bin/dark-factory" "$H/.local/bin/abs"                       # absolute
ln -s "../share/dark-factory/releases/r2/bin/dark-factory" "$H/.local/bin/rel"  # relative
ln -s "$R4/r3" "$H/.local/share/dark-factory/current"; ln -s "$H/.local/share/dark-factory/current/bin/dark-factory" "$H/.local/bin/chain"
printf '[Service]\nExecStart=%%h/.local/share/dark-factory/releases/r4/bin/dark-factory\n' >"$H/.config/systemd/user/df.service"
echo x >"$R4/zz-newest-file"                                              # newest entry, not a dir
echo x >"$H/outside/keepme/f"; age "$H/outside" 60; ln -s "$H/outside" "$R4/zz-link"  # symlinked entry
mkdir -p "$H/elsewhere/oldrun"; echo x >"$H/elsewhere/oldrun/f"; age "$H/elsewhere/oldrun" 60
rmdir "$H/.dark-factory/runs"; ln -s "$H/elsewhere" "$H/.dark-factory/runs"   # symlinked root
HOME="$H" DISK_MAGICIAN_TEST_SANDBOX="$H" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_dark_factory \
  DISK_MAGICIAN_DELETION_LOG="$H/deletions.log" bash "$SCRIPT" --clean >"$T/t4.out" 2>&1 || true
check "absolute bin symlink release kept" '[[ -d "$R4/r1" ]]'
check "relative bin symlink release kept" '[[ -d "$R4/r2" ]]'
check "chained bin symlink release kept" '[[ -d "$R4/r3" ]]'
check "systemd %h release kept" '[[ -d "$R4/r4" ]]'
check "unreferenced stale release removed" '[[ ! -e "$R4/r5" ]]'
check "non-dir entry does not take a newest-3 slot" '[[ -d "$R4/r6" ]]'
check "symlinked release entry and target untouched" '[[ -L "$R4/zz-link" && -f "$H/outside/keepme/f" ]]'
check "symlinked runs root not traversed" '[[ -f "$H/elsewhere/oldrun/f" ]]'

echo "Test 3: empty install (no releases, no references) does not abort"
E="$T/empty"; mkdir -p "$E/.local/share/dark-factory/releases" "$E/.dark-factory/runs" "$E/.ao-sessions"
check "empty install exits 0" 'HOME="$E" DISK_MAGICIAN_TEST_SANDBOX="$E" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_dark_factory \
  DISK_MAGICIAN_DELETION_LOG="$E/deletions.log" bash "$SCRIPT" --dry-run >/dev/null 2>&1'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
