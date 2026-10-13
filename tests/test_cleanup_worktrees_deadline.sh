#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cleanup-worktrees-deadline.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/repo"
cursor="$TMP/state/cursor.json"
output="$(HOME="$TMP/home" bash "$ROOT/scripts/cleanup_worktrees.sh" \
  --repos "$TMP/repo" --deadline-at 1 --cursor "$cursor")"
grep -q 'deferred:deadline-before-unit' <<<"$output"
python3 - "$cursor" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))
assert value == {"schema":1,"source":value["source"],"items":["cleanup"],"next_index":0}
PY
receipt="$(HOME="$TMP/home" python3 "$ROOT/scripts/job_receipt.py" read --job cleanup_worktrees --last)"
python3 - "$receipt" <<'PY'
import json,sys
value=json.loads(sys.argv[1])
assert value["outcome"] == "partial"
assert value["candidates"] == {"removed_count":0,"deferred_count":1,"interrupted_count":1}
assert isinstance(value["postcondition"]["df_delta_bytes"],int)
PY
echo 'PASS deadline before cleanup unit leaves cursor pending'

normal="$(HOME="$TMP/home" bash "$ROOT/scripts/cleanup_worktrees.sh" --repos "$TMP/repo")"
grep -q 'WORKTREE CLEANUP (DRY-RUN)' <<<"$normal"
echo 'PASS no deadline preserves the normal dry-run path'

far_deadline="$(python3 -c 'import time; print(time.monotonic()+500)')"
HOME="$TMP/home" bash "$ROOT/scripts/cleanup_worktrees.sh" --repos "$TMP/repo" \
  --deadline-at "$far_deadline" --cursor "$cursor" >/dev/null
test "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["next_index"])' "$cursor")" = 1
receipt="$(HOME="$TMP/home" python3 "$ROOT/scripts/job_receipt.py" read --job cleanup_worktrees --last)"
python3 - "$receipt" <<'PY'
import json,sys
value=json.loads(sys.argv[1])
assert value["outcome"] == "success"
assert value["candidates"]["removed_count"] == 0
assert isinstance(value["postcondition"]["df_delta_bytes"],int)
PY
echo 'PASS completed cleanup unit advances cursor'
