#!/usr/bin/env bash
# Focused Task 14 deadline test for worktree_reap.sh:
#   - the cooperative soft deadline is forwarded into C14 and WRH
#   - a deferred C14 verdict is a completed-for-this-pass unit (cursor advances,
#     deferred_count increments, removed_count stays zero)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/worktree-reap-deadline.XXXXXX)" || exit 1
[[ "$TMP" == /tmp/worktree-reap-deadline.* && -d "$TMP" && ! -L "$TMP" ]] || exit 1
TMP="$(cd -- "$TMP" && pwd -P)" || exit 1
trap '[[ "$TMP" == /tmp/worktree-reap-deadline.* || "$TMP" == /private/tmp/worktree-reap-deadline.* ]] && rm -rf "$TMP"' EXIT
export HOME="$TMP/home" STANDARD_WORKTREE_ROOT="$TMP/worktrees" DISK_MAGICIAN_STATE_DIR="$TMP/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
mkdir -p "$HOME" "$TMP/bin" "$TMP/ps/fail"
cat > "$TMP/bin/ps" <<'MOCK'
#!/bin/bash
pid= spec=
while [[ $# -gt 0 ]]; do case "$1" in -p) pid="$2"; shift 2;; -o) spec="$2"; shift 2;; *) shift;; esac; done
if [[ -f "$DISK_MAGICIAN_PS_DIR/fail/$pid" ]]; then read -r rc msg < "$DISK_MAGICIAN_PS_DIR/fail/$pid"; [[ -z "${msg:-}" ]] || echo "$msg" >&2; exit "$rc"; fi
case "$spec" in lstart=) cat "$DISK_MAGICIAN_PS_DIR/lstart/$pid" 2>/dev/null;; args=) cat "$DISK_MAGICIAN_PS_DIR/args/$pid" 2>/dev/null;; ppid=,comm=) cat "$DISK_MAGICIAN_PS_DIR/comm/$pid" 2>/dev/null;; pid=) /bin/kill -0 "$pid" 2>/dev/null;; *) exit 1;; esac
MOCK
cat > "$TMP/bin/lsof" <<'MOCK'
#!/bin/bash
for a in "$@"; do
  [[ "$a" == ^cwd ]] && exit 1
  [[ "$a" == +D ]] && exit 1
done
printf 'p999999\nfcwd\nn/\n'
MOCK
cat > "$TMP/bin/timeout" <<'MOCK'
#!/bin/bash
shift
exec "$@"
MOCK
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export DISK_MAGICIAN_PS_BIN="$TMP/bin/ps" DISK_MAGICIAN_PS_DIR="$TMP/ps"
printf '1\n' > "$TMP/ps/fail/401"

/bin/bash "$ROOT/scripts/worktree_reap.sh" > "$TMP/no-args.log" 2>&1
echo 'PASS empty argument list on system Bash'

source "$ROOT/scripts/lib/worktree_lease.sh"
git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
printf 'base\n' > "$TMP/repo/file"
git -C "$TMP/repo" add file
git -C "$TMP/repo" commit -qm base
git -C "$TMP/repo" push -q origin HEAD:main
WT="$STANDARD_WORKTREE_ROOT/repo/c1"
git -C "$TMP/repo" worktree add -qb worktree-c1 "$WT" origin/main
git -C "$WT" push -q -u origin worktree-c1
lease_write "$WT" "$TMP/repo" "worktree-c1" test
LF="$(lease_path_for "$WT")"
python3 - "$LF" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["owner"] = {"pid": 401, "start_epoch": 1760000000, "comm": "claude"}
d["owner_dead_seen_at"] = time.time() - 2400
json.dump(d, open(p, "w"))
PY
python3 - "$WT" <<'PY'
import os, sys, time
old = time.time() - 8 * 86400
for base, dirs, files in os.walk(sys.argv[1]):
    for name in files:
        os.utime(os.path.join(base, name), (old, old))
    for name in dirs:
        os.utime(os.path.join(base, name), (old, old))
os.utime(sys.argv[1], (old, old))
PY

cd "$TMP"
cp -R "$ROOT/scripts" "$TMP/root-scripts"
echo 'removal_activation_ok() { return 0; }' > "$TMP/root-scripts/lib/removal_activation.sh"
C14_LOG="$TMP/c14.log"
: > "$C14_LOG"
cat > "$TMP/root-scripts/lib/quarantine.sh" <<SH
artifact_removal_verdict() { printf 'C14 %s\n' "\$*" >> "$C14_LOG"; echo "deferred:c14-step"; return 0; }
wrh_remove_now() { printf 'WRH %s\n' "\$*" >> "$C14_LOG"; return 1; }
SH

touch "$DISK_MAGICIAN_STATE_DIR/test_gate_open"
touch "$DISK_MAGICIAN_STATE_DIR/worktree_reap.remove_approved"
cursor="$TMP/cursor.json"
far="$(python3 -c 'import time; print(time.monotonic()+120)')"
bash "$TMP/root-scripts/worktree_reap.sh" --mode remove --deadline-at "$far" --cursor "$cursor" > "$TMP/run.log" 2>&1
rc=$?

test "$rc" = 0
echo 'PASS reap exit zero'
grep -q 'C14 .*--deadline-at' "$C14_LOG"
echo 'PASS deadline forwarded into the reap C14 call'
test -d "$WT"
echo 'PASS deferred C14 left the worktree in place'
python3 - "$cursor" "$LF" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value["items"] == [sys.argv[2]], value
assert value["next_index"] == 1, value
PY
echo 'PASS deferred C14 advanced the reap cursor'
receipt="$(python3 "$TMP/root-scripts/job_receipt.py" read --job worktree_reap --last)"
python3 - "$receipt" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value["candidates"]["deferred_count"] == 1, value["candidates"]
assert value["candidates"]["removed_count"] == 0, value["candidates"]
assert value["candidates"]["interrupted_count"] == 0, value["candidates"]
PY
echo 'PASS receipt counts exactly one deferred reap unit and zero removals'

echo 'ALL PASS'
