#!/usr/bin/env bash
# Real CLI / real C14 regression; all cleanup candidates are disposable fixtures.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home/.Trash" "$WORK/tmp" "$WORK/state"
git init -q --bare -b main "$WORK/origin.git"
git init -q -b main "$WORK/base"
printf 'venv/\n' > "$WORK/base/.gitignore"
git -C "$WORK/base" add .gitignore
git -C "$WORK/base" -c user.name=t -c user.email=t@t commit -qm init
git -C "$WORK/base" remote add origin "$WORK/origin.git"
git -C "$WORK/base" worktree add -q -b fixture "$WORK/cwd"
git -C "$WORK/cwd" push -q -u origin fixture
mkdir "$WORK/cwd/venv"
printf sentinel > "$WORK/cwd/venv/sentinel"
python3 - "$WORK" <<'PY'
import os, pathlib, sys, time, json
r = pathlib.Path(sys.argv[1])
(r/'home/.Trash'/'payload\n1024\tvenv').write_bytes(b'x' * 2097152)
(r/'home/.Trash'/'outside-link').symlink_to(r/'cwd/venv', target_is_directory=True)
(r/'home/.Trash'/'normal-item').write_bytes(b'x' * 2097152)
old=time.time()-30*86400
for p in sorted((r/'cwd').rglob('*'),reverse=True): os.utime(p,(old,old))
os.utime(r/'cwd',(old,old))
(r/'safety.json').write_text(json.dumps({'never_delete':['/private/tmp/jest_dx','/private/tmp/worldai-ios-compilation-cache']}))
PY
# Capture the real host's du serialization, not a mocked du implementation.
du -sk "$WORK/home/.Trash/"* | cat -v
(cd "$WORK/cwd"; env -i PATH="$PATH" TZ=UTC HOME="$WORK/home" TMPDIR="$WORK/tmp" \
 DISK_MAGICIAN_SAFETY_FILE="$WORK/safety.json" DISK_MAGICIAN_STATE_DIR="$WORK/state" \
 DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$WORK" \
 DISK_MAGICIAN_DELETION_LOG="$WORK/deletions.log" \
 bash "$REPO_ROOT/disk_magician.sh" cleanup-dev-caches --clean) > "$WORK/clean.log" 2>&1
cat "$WORK/clean.log"
if [[ ! -f "$WORK/cwd/venv/sentinel" ]]; then
 echo 'FAIL: newline Trash filename caused deletion of outside-Trash CWD venv' >&2
 [[ ! -f "$WORK/deletions.log" ]] || cat "$WORK/deletions.log"
 exit 1
fi
if grep -Fq 'C14 kept: venv (' "$WORK/clean.log"; then
 echo 'FAIL: Trash scanner forwarded injected relative CWD path to C14' >&2
 exit 1
fi
python3 - "$WORK" <<'PY_CHECK'
import pathlib, sys
r = pathlib.Path(sys.argv[1])
assert (r/'home/.Trash'/'payload\n1024\tvenv').is_file()
assert (r/'home/.Trash'/'outside-link').is_symlink()
assert (r/'home/.Trash'/'normal-item').is_file()
log=(r/'clean.log').read_text()
assert 'C14 kept: '+str(r/'home/.Trash'/'normal-item')+' (kept:recent-activity)' in log
assert 'C14 kept: '+str(r/'home/.Trash'/'outside-link') not in log
PY_CHECK
echo 'PASS: exact filenames and outside-root sentinel preserved; normal item reaches real C14, symlink and injected relative candidate do not'
