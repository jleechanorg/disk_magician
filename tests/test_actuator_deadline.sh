#!/usr/bin/env bash
# Cooperative deadline and crash-safe cursor helper contracts; temp fixtures only.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib/actuator_deadline.sh"
T="$(mktemp -d /tmp/actuator-deadline-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0
check() { local label="$1"; shift; if "$@"; then echo "PASS: $label"; PASS=$((PASS+1)); else echo "FAIL: $label"; FAIL=$((FAIL+1)); fi; }

act_parse_deadline_args --deadline-at 9999999999.125 --cursor "$T/cur sor.json" --clean --large
check 'deadline parsed as monotonic decimal' test "$ACT_DEADLINE_AT" = 9999999999.125
check 'cursor path preserves spaces' test "$ACT_CURSOR" = "$T/cur sor.json"
check 'unknown actuator args preserved in order' test "${ACT_ARGS[*]}" = '--clean --large'
act_parse_deadline_args --deadline-at invalid >/dev/null 2>&1
check 'invalid deadline rejected' test "$?" -eq 2
act_parse_deadline_args --cursor >/dev/null 2>&1
check 'missing cursor value rejected' test "$?" -eq 2

ACT_DEADLINE_AT=9999999999.125
act_unit_fits 20
check 'unit fits before a far deadline' test "$?" -eq 0
ACT_DEADLINE_AT=1
act_unit_fits 20 >/dev/null 2>&1
check 'unit defers after deadline' test "$?" -eq 1
ACT_DEADLINE_AT=""
act_unit_fits 20
check 'absent deadline preserves unbounded legacy behavior' test "$?" -eq 0

items='["space path","line\nfeed","unicode-λ"]'
act_cursor_save "$T/cursor.json" scratch "$items" 1
check 'cursor saved atomically' test -s "$T/cursor.json"
loaded="$(act_cursor_load "$T/cursor.json" scratch)"
check 'cursor roundtrip preserves list and index' python3 - "$loaded" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
assert d["items"] == ["space path", "line\nfeed", "unicode-λ"]
assert d["next_index"] == 1
PY
check 'cursor source mismatch is rejected' test "$(act_cursor_load "$T/cursor.json" other >/dev/null 2>&1; echo $?)" -eq 2
act_cursor_save "$T/cursor.json" scratch "$items" 4 >/dev/null 2>&1
check 'out of range cursor index rejected' test "$?" -eq 2
printf '{broken' > "$T/cursor.json"
check 'corrupt cursor is rejected, not reset' test "$(act_cursor_load "$T/cursor.json" scratch >/dev/null 2>&1; echo $?)" -eq 2

echo "$PASS passed; $FAIL failed"
[[ "$FAIL" == 0 ]]
