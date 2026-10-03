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
# Hosts usually have own non-dumpable processes (systemd --user); Test 10b
# covers the gate itself, every other case runs with it approved.
export DARK_FACTORY_UNSCANNABLE_APPROVED=1
# wait_exec <pid> <pattern>: poll until the process's argv matches (it has exec'd).
wait_exec() { local i; for i in $(seq 1 100); do ps -p "$1" -o command= 2>/dev/null | grep -q -- "$2" && return 0; sleep 0.1; done; return 1; }
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
check "dry-run reports would-remove" 'grep -qF "would remove run: $(cd -P "$RUNS" && pwd)/old" "$T/dry.out"'

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

echo "Test 5: symlinked HOME, symlinked unit file, plain-file shim, open file handle"
mkdir -p "$T/h5real"; ln -s "$T/h5real" "$T/h5link"; H5="$T/h5link"; R5="$H5/.local/share/dark-factory/releases"
mkdir -p "$R5" "$H5/.local/bin" "$H5/.config/systemd/user" "$H5/.dark-factory/runs" "$H5/.ao-sessions" "$H5/unitsrc"
for i in 1 2 3 4 5 6 7; do mkdir -p "$R5/r$i/bin"; echo x >"$R5/r$i/bin/dark-factory"; age "$R5/r$i" $(( 100 - i )); done
ln -s "$R5/r1/bin/dark-factory" "$H5/.local/bin/abs"                                  # logical path through symlinked HOME
printf '[Service]\nExecStart=%%h/.local/share/dark-factory/releases/r2/bin/dark-factory\n' >"$H5/unitsrc/df.service"
ln -s "$H5/unitsrc/df.service" "$H5/.config/systemd/user/df.service"                   # symlinked unit file
printf '#!/bin/sh\nexec %s/r3/bin/dark-factory "$@"\n' "$R5" >"$H5/.local/bin/shim"; chmod +x "$H5/.local/bin/shim"  # plain-file shim
mkdir -p "$H5/.dark-factory/runs/held"; echo x >"$H5/.dark-factory/runs/held/f"; age "$H5/.dark-factory/runs/held" 60
sleep 120 <"$H5/.dark-factory/runs/held/f" & HOLDER=$!                                 # open fd only, cwd elsewhere
wait_exec "$HOLDER" "sleep 120"
HOME="$H5" DISK_MAGICIAN_TEST_SANDBOX="$H5" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_dark_factory \
  DISK_MAGICIAN_DELETION_LOG="$T/h5.log" bash "$SCRIPT" --clean >"$T/t5.out" 2>&1 || true
kill "$HOLDER" 2>/dev/null || true
check "release linked via symlinked HOME kept" '[[ -d "$R5/r1" ]]'
check "release in symlinked unit file kept" '[[ -d "$R5/r2" ]]'
check "release named in plain-file shim kept" '[[ -d "$R5/r3" ]]'
check "unreferenced stale release removed (symlinked HOME)" '[[ ! -e "$R5/r4" ]]'
check "run held open by a live process kept" '[[ -d "$H5/.dark-factory/runs/held" ]]'

echo "Test 6: unreadable reference source refuses --clean"
H6="$T/h6"; R6="$H6/.local/share/dark-factory/releases"
mkdir -p "$R6/r1/bin" "$H6/.local/bin" "$H6/.config/systemd/user" "$H6/.dark-factory/runs/old" "$H6/.ao-sessions"
echo x >"$R6/r1/bin/dark-factory"; age "$R6/r1" 90; echo x >"$H6/.dark-factory/runs/old/f"; age "$H6/.dark-factory/runs/old" 60
chmod 000 "$H6/.config/systemd/user"
rc6=0; HOME="$H6" DISK_MAGICIAN_TEST_SANDBOX="$H6" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_dark_factory \
  DISK_MAGICIAN_DELETION_LOG="$T/h6.log" bash "$SCRIPT" --clean --keep-releases 0 >"$T/t6.out" 2>&1 || rc6=$?
chmod 755 "$H6/.config/systemd/user"
check "--clean exits nonzero when unit dir unreadable" '[[ "$rc6" -ne 0 ]]'
check "nothing deleted when a reference source is unreadable" '[[ -d "$R6/r1" && -d "$H6/.dark-factory/runs/old" ]]'

echo "Test 7: per-file unreadable references refuse --clean; \$HOME/~ shims, logical argv, env refs"
can_lock() { local d; d="$(mktemp -d "$T/lockprobe.XXXX")"; echo x >"$d/f"; chmod 000 "$d/f"; ! cat "$d/f" >/dev/null 2>&1; local r=$?; chmod 644 "$d/f"; return $r; }
mk7() {  # mk7 <home>: 6 releases r1..r6 (r1 oldest), one stale run
  local h="$1"; mkdir -p "$h/.local/share/dark-factory/releases" "$h/.local/bin" "$h/.config/systemd/user" "$h/.dark-factory/runs/old" "$h/.ao-sessions"
  for i in 1 2 3 4 5 6; do mkdir -p "$h/.local/share/dark-factory/releases/r$i/bin"; echo x >"$h/.local/share/dark-factory/releases/r$i/bin/dark-factory"; age "$h/.local/share/dark-factory/releases/r$i" $(( 100 - i )); done
  echo x >"$h/.dark-factory/runs/old/f"; age "$h/.dark-factory/runs/old" 60
}
run7() { local h="$1"; shift; HOME="$h" DISK_MAGICIAN_TEST_SANDBOX="$h" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_dark_factory DISK_MAGICIAN_DELETION_LOG="$h/del.log" bash "$SCRIPT" "$@"; }
if can_lock; then
  H7a="$T/h7a"; mk7 "$H7a"
  printf '[Service]\nExecStart=%%h/.local/share/dark-factory/releases/r1/bin/dark-factory\n' >"$H7a/.config/systemd/user/df.service"; chmod 000 "$H7a/.config/systemd/user/df.service"
  rc=0; run7 "$H7a" --clean >"$T/t7a.out" 2>&1 || rc=$?; chmod 644 "$H7a/.config/systemd/user/df.service"
  check "unreadable unit file refuses --clean, nothing deleted" '[[ "$rc" -ne 0 && -d "$H7a/.local/share/dark-factory/releases/r1" && -d "$H7a/.dark-factory/runs/old" ]]'
  H7b="$T/h7b"; mk7 "$H7b"
  printf '#!/bin/sh\nexec %s/.local/share/dark-factory/releases/r1/bin/dark-factory\n' "$H7b" >"$H7b/.local/bin/shim"; chmod 000 "$H7b/.local/bin/shim"
  rc=0; run7 "$H7b" --clean >"$T/t7b.out" 2>&1 || rc=$?; chmod 755 "$H7b/.local/bin/shim"
  check "unreadable bin shim refuses --clean, nothing deleted" '[[ "$rc" -ne 0 && -d "$H7b/.local/share/dark-factory/releases/r1" ]]'
else
  check "SKIPPED unreadable-file cases (privileged user)" 'true'
fi
H7c="$T/h7c"; mk7 "$H7c"
printf '#!/bin/sh\nexec "$HOME/.local/share/dark-factory/releases/r1/bin/dark-factory"\n' >"$H7c/.local/bin/s1"
printf '#!/bin/sh\nexec ${HOME}/.local/share/dark-factory/releases/r2/bin/dark-factory\n' >"$H7c/.local/bin/s2"
printf '#!/bin/sh\nexec ~/.local/share/dark-factory/releases/r3/bin/dark-factory\n' >"$H7c/.local/bin/s3"
run7 "$H7c" --clean >"$T/t7c.out" 2>&1 || true
check "\$HOME, \${HOME}, ~ shims protect their releases" '[[ -d "$H7c/.local/share/dark-factory/releases/r1" && -d "$H7c/.local/share/dark-factory/releases/r2" && -d "$H7c/.local/share/dark-factory/releases/r3" ]]'
mkdir -p "$T/h7dreal"; ln -s "$T/h7dreal" "$T/h7d"; H7d="$T/h7d"; mk7 "$H7d"
mkdir -p "$H7d/.dark-factory/runs/argv"; echo x >"$H7d/.dark-factory/runs/argv/f"; age "$H7d/.dark-factory/runs/argv" 60
( cd /; exec -a "df-worker $H7d/.dark-factory/runs/argv/f" sleep 120 ) & ARGVP=$!
DARK_FACTORY_RELEASE="$H7d/.local/share/dark-factory/releases/r1" sleep 120 & ENVP=$!
wait_exec "$ARGVP" "df-worker"; wait_exec "$ENVP" "sleep 120"
run7 "$H7d" --clean >"$T/t7d.out" 2>&1 || true
kill "$ARGVP" "$ENVP" 2>/dev/null || true
check "run named by logical path in a live argv kept" '[[ -d "$T/h7dreal/.dark-factory/runs/argv" ]]'
check "release named only in a live process env kept" '[[ -d "$T/h7dreal/.local/share/dark-factory/releases/r1" ]]'

echo "Test 8: systemd \\xHH-escaped unit path; macOS-branch partial ps/lsof scans refuse --clean"
H8="$T/h8"; mk7 "$H8"
printf '[Service]\nExecStart=%%h/.local/share/dark\\x2dfactory/releases/r1/bin/dark-factory\n' >"$H8/.config/systemd/user/esc.service"
run7 "$H8" --clean >"$T/t8.out" 2>&1 || true
check "release named via \\x2d-escaped unit path kept" '[[ -d "$H8/.local/share/dark-factory/releases/r1" ]]'
# Shimmed ps/lsof drive the macOS branch on any host.
SHIM="$T/shim"; mkdir -p "$SHIM"
mkshims() {  # mkshims <ps_rc> <lsof_rc>
  printf '#!/bin/sh\necho "bash %s"\nexit %s\n' "$SCRIPT cleanup_dark_factory" "$1" >"$SHIM/ps"
  printf '#!/bin/sh\nprintf "p1\\nn%%s\\n" "$(pwd -P)"\nexit %s\n' "$2" >"$SHIM/lsof"
  chmod +x "$SHIM/ps" "$SHIM/lsof"
}
run8() { local h="$1"; shift; PATH="$SHIM:$PATH" DISK_MAGICIAN_TEST_NO_PROC=1 run7 "$h" "$@"; }
mkshims 0 0; H8b="$T/h8b"; mk7 "$H8b"; rc=0; run8 "$H8b" --clean >"$T/t8b.out" 2>&1 || rc=$?
check "macOS branch with complete ps/lsof proceeds (control)" '[[ "$rc" -eq 0 && ! -e "$H8b/.dark-factory/runs/old" ]]'
mkshims 0 1; H8c="$T/h8c"; mk7 "$H8c"; rc=0; run8 "$H8c" --clean >"$T/t8c.out" 2>&1 || rc=$?
check "partial lsof (nonzero exit with output) refuses --clean" '[[ "$rc" -ne 0 && -d "$H8c/.dark-factory/runs/old" ]]'
mkshims 1 0; H8d="$T/h8d"; mk7 "$H8d"; rc=0; run8 "$H8d" --clean >"$T/t8d.out" 2>&1 || rc=$?
check "failing ps refuses --clean" '[[ "$rc" -ne 0 && -d "$H8d/.dark-factory/runs/old" ]]'

echo "Test 9: symlinked ~/.local/bin and unit dir are scanned; non-numeric args rejected"
H9a="$T/h9a"; mk7 "$H9a"; mkdir -p "$H9a/dotfiles/bin"; rmdir "$H9a/.local/bin"; ln -s "$H9a/dotfiles/bin" "$H9a/.local/bin"
ln -s "$H9a/.local/share/dark-factory/releases/r1/bin/dark-factory" "$H9a/dotfiles/bin/dark-factory"
rc=0; run7 "$H9a" --clean --keep-releases 0 >"$T/t9a.out" 2>&1 || rc=$?
check "release linked from a symlinked ~/.local/bin kept, --clean ran" '[[ "$rc" -eq 0 && -d "$H9a/.local/share/dark-factory/releases/r1" && ! -e "$H9a/.local/share/dark-factory/releases/r2" ]]'
H9="$T/h9"; mk7 "$H9"; mkdir -p "$H9/dotfiles/units"; rmdir "$H9/.config/systemd/user"; ln -s "$H9/dotfiles/units" "$H9/.config/systemd/user"
printf '[Service]\nExecStart=%%h/.local/share/dark-factory/releases/r2/bin/dark-factory\n' >"$H9/dotfiles/units/df.service"
rc=0; run7 "$H9" --clean --keep-releases 0 >"$T/t9.out" 2>&1 || rc=$?
check "release named in a symlinked unit dir kept, --clean ran" '[[ "$rc" -eq 0 && -d "$H9/.local/share/dark-factory/releases/r2" && ! -e "$H9/.local/share/dark-factory/releases/r3" ]]'
for bad in "--keep-releases foo" "--days 1x"; do
  rc=0; run7 "$H9" --dry-run $bad >/dev/null 2>&1 || rc=$?
  check "rejects $bad" '[[ "$rc" -eq 2 ]]'
done

echo "Test 10: odd reference terminators; own unscannable processes gate --clean"
H10="$T/h10"; mk7 "$H10"
printf '[Service]\nEnvironment=PYTHONPATH=%%h/.local/share/dark-factory/releases/r1:/usr/lib\nExecStart=/bin/sh -c "cd %%h/.local/share/dark-factory/releases/r2; ./bin/df"\n' >"$H10/.config/systemd/user/df.service"
run7 "$H10" --clean --keep-releases 0 >"$T/t10.out" 2>&1 || true
check "release referenced with ':' terminator kept" '[[ -d "$H10/.local/share/dark-factory/releases/r1" ]]'
check "release referenced with ';' terminator kept" '[[ -d "$H10/.local/share/dark-factory/releases/r2" && ! -e "$H10/.local/share/dark-factory/releases/r3" ]]'
if [[ -d /proc/self ]] && python3 -c 'import ctypes; ctypes.CDLL(None).prctl' 2>/dev/null; then
  H10b="$T/h10b"; mk7 "$H10b"
  ( cd "$H10b/.dark-factory/runs/old" && exec python3 -c 'import ctypes,time; ctypes.CDLL(None).prctl(4,0,0,0,0); time.sleep(120)' ) & NDP=$!
  for _ in $(seq 1 100); do readlink "/proc/$NDP/cwd" >/dev/null 2>&1 || break; sleep 0.1; done  # prctl applied
  rc=0; DARK_FACTORY_UNSCANNABLE_APPROVED= run7 "$H10b" --clean >"$T/t10b.out" 2>&1 || rc=$?
  check "own non-dumpable process refuses --clean without approval" '[[ "$rc" -ne 0 && -d "$H10b/.dark-factory/runs/old" ]]'
  check "refusal names the unscannable process" 'grep -q "$NDP" "$T/t10b.out"'
  rc=0; DARK_FACTORY_UNSCANNABLE_APPROVED=1 run7 "$H10b" --clean >"$T/t10c.out" 2>&1 || rc=$?
  check "explicit approval lets --clean proceed" '[[ "$rc" -eq 0 ]]'
  kill "$NDP" 2>/dev/null || true
else
  check "SKIPPED non-dumpable gate (no /proc or prctl)" 'true'
fi

echo "Test 11: HOME containing sed replacement metacharacters (& \\ #)"
H11="$T/h&a#b"; mk7 "$H11"
printf '[Service]\nExecStart=%%h/.local/share/dark-factory/releases/r1/bin/dark-factory\n' >"$H11/.config/systemd/user/df.service"
printf '#!/bin/sh\nexec "$HOME/.local/share/dark-factory/releases/r2/bin/dark-factory"\n' >"$H11/.local/bin/shim"
run7 "$H11" --clean --keep-releases 0 >"$T/t11.out" 2>&1 || true
check "%h reference kept when HOME contains & and #" '[[ -d "$H11/.local/share/dark-factory/releases/r1" ]]'
check "\$HOME shim reference kept when HOME contains & and #" '[[ -d "$H11/.local/share/dark-factory/releases/r2" && ! -e "$H11/.local/share/dark-factory/releases/r3" ]]'

echo "Test 12: binary launcher with an embedded release path; leading-zero --days honors the floor"
H12="$T/h12"; mk7 "$H12"
printf '\177ELF\0\0\0%s/.local/share/dark-factory/releases/r1/bin/dark-factory\0\1\2' "$H12" >"$H12/.local/bin/launcher"; chmod +x "$H12/.local/bin/launcher"
run7 "$H12" --clean --keep-releases 0 >"$T/t12.out" 2>&1 || true
check "release path embedded in a binary launcher kept" '[[ -d "$H12/.local/share/dark-factory/releases/r1" && ! -e "$H12/.local/share/dark-factory/releases/r2" ]]'
H12b="$T/h12b"; mk7 "$H12b"; mkdir -p "$H12b/.config/disk-magician"; echo '{"min_stale_days": 14}' >"$H12b/.config/disk-magician/safety.local.json"
run7 "$H12b" --dry-run --days 09 >"$T/t12b.out" 2>&1 || true
check "--days 09 is raised to a 14-day floor" 'grep -q "threshold 14d" "$T/t12b.out"'

echo "Test 13: hidden launchers; a NUL deep in a bin text file does not hide later references"
H13="$T/h13"; mk7 "$H13"
printf '#!/bin/sh\nexec %s/.local/share/dark-factory/releases/r1/bin/dark-factory\n' "$H13" >"$H13/.local/bin/.df-hidden-text"
printf '\177ELF\0\0%s/.local/share/dark-factory/releases/r2/bin/dark-factory\0' "$H13" >"$H13/.local/bin/.df-hidden-bin"
run7 "$H13" --clean --keep-releases 0 >"$T/t13.out" 2>&1 || true
check "hidden text and binary launchers protect their releases" '[[ -d "$H13/.local/share/dark-factory/releases/r1" && -d "$H13/.local/share/dark-factory/releases/r2" && ! -e "$H13/.local/share/dark-factory/releases/r3" ]]'
H13b="$T/h13b"; mk7 "$H13b"
{ printf '#!/bin/sh\n'; head -c 1100000 /dev/zero | tr '\0' 'x'; printf '\n\0tail\n'; } >"$H13b/.local/bin/aaa-text-with-late-nul"
ln -s "$H13b/.local/share/dark-factory/releases/r1" "$H13b/.local/share/dark-factory/releases/current"
printf '[Service]\nExecStart=%%h/.local/share/dark-factory/releases/current/bin/dark-factory\n' >"$H13b/.config/systemd/user/df.service"
run7 "$H13b" --clean --keep-releases 0 >"$T/t13b.out" 2>&1 || true
check "unit reference via releases/current survives a late NUL in a bin text file" '[[ -d "$H13b/.local/share/dark-factory/releases/r1" && ! -e "$H13b/.local/share/dark-factory/releases/r2" ]]'

echo "Test 3: empty install (no releases, no references) does not abort"
E="$T/empty"; mkdir -p "$E/.local/share/dark-factory/releases" "$E/.dark-factory/runs" "$E/.ao-sessions"
check "empty install exits 0" 'HOME="$E" DISK_MAGICIAN_TEST_SANDBOX="$E" DISK_MAGICIAN_TEST_CONTEXT=test_cleanup_dark_factory \
  DISK_MAGICIAN_DELETION_LOG="$E/deletions.log" bash "$SCRIPT" --dry-run >/dev/null 2>&1'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
