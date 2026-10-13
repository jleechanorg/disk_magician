#!/usr/bin/env bash
# Focused Task 14 deadline tests for cleanup_worktrees.sh:
#   - the cooperative soft deadline is forwarded into C14 and the quarantine path
#   - a deferred C14 verdict is a completed-for-this-pass unit (cursor advances,
#     ACT_DEFERRED_COUNT increments, removed_count does not)
#   - an early checkpoint error still closes the begun govern receipt (EXIT path)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/cw-c14-deadline.XXXXXX)" || exit 1
[[ "$TMP" == /tmp/cw-c14-deadline.* && -d "$TMP" && ! -L "$TMP" ]] || exit 1
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
REPO="$TMP/repo"
WORKTREES="$HOME_DIR/.worktrees/fixture"
mkdir -p "$HOME_DIR" "$REPO" "$WORKTREES"
WORKTREES_REAL="$(cd "$WORKTREES" && pwd -P)"
git -C "$REPO" init -b main >/dev/null
git -C "$REPO" config user.email fixture@users.noreply.github.com
git -C "$REPO" config user.name fixture
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md
HERMES_SKIP_EXAMPLE_COM_GUARD=1 git -C "$REPO" commit -m base >/dev/null
git -C "$REPO" worktree add -b wt-one "$WORKTREES/wt-one" HEAD >/dev/null
python3 - "$WORKTREES/wt-one" <<'PY'
import os, sys, time
old = time.time() - 8 * 86400
for base, dirs, files in os.walk(sys.argv[1]):
    for name in files:
        os.utime(os.path.join(base, name), (old, old))
    for name in dirs:
        os.utime(os.path.join(base, name), (old, old))
os.utime(sys.argv[1], (old, old))
PY

# Copy the tree so C14/quarantine are deterministic stubs that log their args.
SCRIPTS="$TMP/scripts"
cp -R "$ROOT/scripts" "$SCRIPTS"
C14_LOG="$TMP/c14.log"
: > "$C14_LOG"
cat > "$SCRIPTS/lib/quarantine.sh" <<SH
artifact_removal_verdict() { printf 'C14 %s\n' "\$*" >> "$C14_LOG"; echo "deferred:c14-step"; return 0; }
wrh_remove_now() { printf 'WRH %s\n' "\$*" >> "$C14_LOG"; return 1; }
quarantine_remove() { printf 'QR %s\n' "\$*" >> "$C14_LOG"; echo "deferred:quarantine-step"; return 0; }
SH

far_deadline="$(python3 -c 'import time; print(time.monotonic()+120)')"
cursor="$TMP/state/cursor.json"
HOME="$HOME_DIR" DISK_MAGICIAN_STATE_DIR="$TMP/state" WORKTREE_APPROVED=1 \
  /bin/bash "$SCRIPTS/cleanup_worktrees.sh" --repos "$REPO" --clean \
  --deadline-at "$far_deadline" --cursor "$cursor" > "$TMP/out" 2>&1

grep -q -- '--deadline-at' "$C14_LOG"
echo 'PASS deadline forwarded into the C14 call'
grep -q 'C14 .*--t3-owner-null' "$C14_LOG"
echo 'PASS C14 kept its t3-owner-null scope'
grep -q '^WRH ' "$C14_LOG" && { echo 'FAIL quarantine ran despite a deferred C14'; exit 1; }
echo 'PASS deferred C14 did not run the quarantine remover'
test -d "$WORKTREES/wt-one"
echo 'PASS deferred candidate left in place'
python3 - "$cursor" "$WORKTREES_REAL/wt-one" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
assert value["items"] == [sys.argv[2]], value
assert value["next_index"] == 1, value
PY
echo 'PASS deferred candidate advanced the cursor'
receipt="$(HOME="$HOME_DIR" DISK_MAGICIAN_STATE_DIR="$TMP/state" python3 "$SCRIPTS/job_receipt.py" read --job cleanup_worktrees --last)"
python3 - "$receipt" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value["outcome"] == "success", value
assert value["candidates"]["deferred_count"] == 1, value["candidates"]
assert value["candidates"]["interrupted_count"] == 0, value["candidates"]
assert value["candidates"]["removed_count"] == 0, value["candidates"]
PY
echo 'PASS receipt counts exactly one deferred unit and zero removals'

# Early checkpoint error: the candidate hook makes the cursor directory
# unwritable so act_candidate_done fails mid-pass, after begin().
STATE_ERR="$TMP/state-error"
cursor_err="$STATE_ERR/cursor.json"
ro_hook="$TMP/ro-hook.sh"
cat > "$ro_hook" <<SH
#!/bin/bash
chmod 500 "$STATE_ERR"
SH
chmod +x "$ro_hook"
rc=0
HOME="$HOME_DIR" DISK_MAGICIAN_STATE_DIR="$STATE_ERR" DISK_MAGICIAN_UNIT_BUDGET_S=1 \
  DISK_MAGICIAN_TEST_CLEANUP_CANDIDATE_HOOK="$ro_hook" \
  /bin/bash "$SCRIPTS/cleanup_worktrees.sh" --repos "$REPO" --deadline-at "$far_deadline" \
  --cursor "$cursor_err" > "$TMP/out-err" 2>&1 || rc=$?
chmod 700 "$STATE_ERR"
test "$rc" -ne 0
echo 'PASS early checkpoint error fails the run'
err_receipt="$(HOME="$HOME_DIR" DISK_MAGICIAN_STATE_DIR="$STATE_ERR" python3 "$SCRIPTS/job_receipt.py" read --job cleanup_worktrees --last)"
python3 - "$err_receipt" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value["outcome"] not in ("success", "success_noop"), value
assert value["reason"] == "early_exit", value
PY
echo 'PASS early checkpoint error closed the begun receipt with a terminal outcome'

echo 'ALL PASS'
