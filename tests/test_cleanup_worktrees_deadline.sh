#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-worktrees-deadline.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
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
git -C "$REPO" worktree add -b wt-two "$WORKTREES/wt-two" HEAD >/dev/null

cursor="$TMP/state/cursor.json"
log="$TMP/candidates.log"
hook="$TMP/candidate-hook.sh"
cat > "$hook" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$CANDIDATE_LOG"
if [[ "${1##*/}" == wt-one ]]; then sleep 6; fi
SH
chmod +x "$hook"
deadline="$(python3 -c 'import time; print(time.monotonic()+5)')"
first_output="$(HOME="$HOME_DIR" CANDIDATE_LOG="$log" DISK_MAGICIAN_STATE_DIR="$TMP/state" \
  DISK_MAGICIAN_UNIT_BUDGET_S=1 DISK_MAGICIAN_TEST_CLEANUP_CANDIDATE_HOOK="$hook" \
  /bin/bash "$ROOT/scripts/cleanup_worktrees.sh" --repos "$REPO" \
    --deadline-at "$deadline" --cursor "$cursor")"
grep -q 'deadline_before_unit:' <<<"$first_output"
python3 - "$cursor" "$WORKTREES_REAL" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))
assert value["items"] == [sys.argv[2] + "/wt-one", sys.argv[2] + "/wt-two"]
assert value["next_index"] == 1, value
PY
first_receipt="$(HOME="$HOME_DIR" DISK_MAGICIAN_STATE_DIR="$TMP/state" python3 "$ROOT/scripts/job_receipt.py" read --job cleanup_worktrees --last)"
python3 - "$first_receipt" <<'PY'
import json,sys
value=json.loads(sys.argv[1])
assert value["outcome"] == "partial", value["outcome"]
# A not-started unit is interrupted, never a completed C14 deferral.
assert value["candidates"]["interrupted_count"] == 1, value["candidates"]
assert value["candidates"]["deferred_count"] == 0, value["candidates"]
PY
grep -q 'deadline_before_candidate' <<<"$first_output"
test "$(grep -Fc "$WORKTREES_REAL/wt-one" "$log")" = 1
echo 'PASS stop midway leaves the interrupted candidate pending and counts it as interrupted, not deferred'

far_deadline="$(python3 -c 'import time; print(time.monotonic()+120)')"
second_output="$(HOME="$HOME_DIR" CANDIDATE_LOG="$log" DISK_MAGICIAN_STATE_DIR="$TMP/state" \
  DISK_MAGICIAN_UNIT_BUDGET_S=1 DISK_MAGICIAN_TEST_CLEANUP_CANDIDATE_HOOK="$hook" \
  /bin/bash "$ROOT/scripts/cleanup_worktrees.sh" --repos "$REPO" \
    --deadline-at "$far_deadline" --cursor "$cursor")"
python3 - "$cursor" "$WORKTREES_REAL" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))
assert value["items"] == [sys.argv[2] + "/wt-one", sys.argv[2] + "/wt-two"]
assert value["next_index"] == 2, value
PY
test "$(grep -Fc "$WORKTREES_REAL/wt-one" "$log")" = 1
test "$(grep -Fc "$WORKTREES_REAL/wt-two" "$log")" = 1
receipt="$(HOME="$HOME_DIR" DISK_MAGICIAN_STATE_DIR="$TMP/state" python3 "$ROOT/scripts/job_receipt.py" read --job cleanup_worktrees --last)"
python3 - "$receipt" <<'PY'
import json,sys
value=json.loads(sys.argv[1])
assert value["outcome"] == "success"
assert value["candidates"]["removed_count"] == 0
assert value["postcondition"]["df_delta_bytes"] is not None
PY
echo 'PASS resume skips completed worktree and processes remaining candidate'

normal="$(HOME="$HOME_DIR" /bin/bash "$ROOT/scripts/cleanup_worktrees.sh" --repos "$REPO")"
grep -q 'WORKTREE CLEANUP (DRY-RUN)' <<<"$normal"
echo 'PASS no deadline preserves the normal dry-run path'

empty_cursor="$TMP/state/empty-cursor.json"
EMPTY_HOME="$TMP/empty-home"
mkdir -p "$EMPTY_HOME"
HOME="$EMPTY_HOME" DISK_MAGICIAN_STATE_DIR="$TMP/state" /bin/bash \
  "$ROOT/scripts/cleanup_worktrees.sh" --deadline-at "$far_deadline" --cursor "$empty_cursor" >/dev/null
python3 - "$empty_cursor" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))
assert value["items"] == [] and value["next_index"] == 0
PY
echo 'PASS explicit deadline flags tolerate an empty repo list under Bash 3.2'
