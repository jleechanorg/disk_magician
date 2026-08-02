#!/usr/bin/env bash
# test_disk_report_breakdown.sh — TDD for scripts/disk_report_breakdown.py
#
# Builds one small synthetic snapshot fixture (a handful of buckets summing
# to a known total, including one node that needs expansion past 5GiB and
# one clean opaque leaf), then asserts:
#   (a) list-opaque-leaves finds exactly the expected leaf
#   (b) render's invariant (a) (parent == sum(children)) holds with zero gap
#   (c) the rendered markdown row count matches a computed expected count
#   (d) both subcommands exit 0
#
# Run: bash tests/test_disk_report_breakdown.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/disk_report_breakdown.py"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d -t disk_report_breakdown_test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- Fixture -----------------------------------------------------------
# GIB=2^20 KB. Buckets (all >5GiB thresholds use 5*GIB=5242880 KB):
#   /Users/tester/small_a           2 GiB  (leaf, <=5GiB)
#   /Users/tester/small_b           1 GiB  (leaf, <=5GiB)
#   /Users/tester/bigdir/child1     3 GiB  (leaf under an expanded parent)
#   /Users/tester/bigdir/child2     4 GiB  (leaf under an expanded parent)
#     -> bigdir subtree = 7 GiB > 5GiB => MUST expand to child1+child2
#   /Users/tester/opaqueblob        8 GiB  (single bucket entry, no children)
#     -> subtree = 8 GiB > 5GiB, zero children => genuinely opaque leaf
# measured_total = (2+1+3+4+8) GiB = 18 GiB
# residual_kb    = 0.5 GiB
# free_kb        = 2 GiB
# df_total_kb    = 18 + 0.5 + 2 = 20.5 GiB  (chosen so invariant (b) gap == 0)
GIB=$((1024 * 1024))
SMALL_A=$((2 * GIB))
SMALL_B=$((1 * GIB))
CHILD1=$((3 * GIB))
CHILD2=$((4 * GIB))
OPAQUE=$((8 * GIB))
RESIDUAL=$((GIB / 2))
FREE_KB=$((2 * GIB))
MEASURED_TOTAL=$((SMALL_A + SMALL_B + CHILD1 + CHILD2 + OPAQUE))
TOTAL_KB=$((MEASURED_TOTAL + RESIDUAL + FREE_KB))

SNAPSHOT="$WORK/snapshot.json"
cat > "$SNAPSHOT" <<EOF
{
  "captured_at": "2026-08-01T00:00:00Z",
  "hostname": "test-fixture-host",
  "residual_kb": $RESIDUAL,
  "granularity_buckets": [
    {"path": "/Users/tester/small_a", "measured_kb": $SMALL_A},
    {"path": "/Users/tester/small_b", "measured_kb": $SMALL_B},
    {"path": "/Users/tester/bigdir/child1", "measured_kb": $CHILD1},
    {"path": "/Users/tester/bigdir/child2", "measured_kb": $CHILD2},
    {"path": "/Users/tester/opaqueblob", "measured_kb": $OPAQUE}
  ],
  "oversize_indivisible_files": []
}
EOF

# --- (a) list-opaque-leaves: exactly one expected leaf ------------------
echo "== list-opaque-leaves =="
OPAQUE_OUT="$WORK/opaque.json"
python3 "$SCRIPT" list-opaque-leaves --snapshot "$SNAPSHOT" > "$OPAQUE_OUT" 2>"$WORK/opaque.err"
RC_LIST=$?
[[ $RC_LIST -eq 0 ]] && ok "list-opaque-leaves exits 0" || bad "list-opaque-leaves exit code" "$RC_LIST: $(cat "$WORK/opaque.err")"

LEAF_COUNT=$(python3 -c "import json; print(len(json.load(open('$OPAQUE_OUT'))))")
[[ "$LEAF_COUNT" == "1" ]] && ok "exactly one opaque leaf found" || bad "opaque leaf count" "expected 1, got $LEAF_COUNT: $(cat "$OPAQUE_OUT")"

LEAF_PATH=$(python3 -c "import json; print(json.load(open('$OPAQUE_OUT'))[0]['path'])" 2>/dev/null || echo "PARSE_ERROR")
[[ "$LEAF_PATH" == "/Users/tester/opaqueblob" ]] && ok "opaque leaf is the expected path" \
  || bad "opaque leaf path" "expected /Users/tester/opaqueblob, got $LEAF_PATH"

LEAF_KB=$(python3 -c "import json; print(json.load(open('$OPAQUE_OUT'))[0]['subtree_kb'])" 2>/dev/null || echo "PARSE_ERROR")
[[ "$LEAF_KB" == "$OPAQUE" ]] && ok "opaque leaf subtree_kb matches fixture ($OPAQUE)" \
  || bad "opaque leaf subtree_kb" "expected $OPAQUE, got $LEAF_KB"

# bigdir must NOT appear (it has children, so it's expandable, not opaque)
BIGDIR_HIT=$(python3 -c "
import json
leaves = json.load(open('$OPAQUE_OUT'))
print('yes' if any(l['path'] == '/Users/tester/bigdir' for l in leaves) else 'no')
")
[[ "$BIGDIR_HIT" == "no" ]] && ok "bigdir (has children) correctly excluded from opaque leaves" \
  || bad "bigdir wrongly marked opaque" "$BIGDIR_HIT"

# --- (b)/(c)/(d) render: invariants + row count -------------------------
echo "== render (no scratch dir — must be robust to it being missing) =="
OUT_MD="$WORK/report.md"
python3 "$SCRIPT" render \
  --snapshot "$SNAPSHOT" \
  --scratch-dir "$WORK/does-not-exist-scratch-dir" \
  --df-total-kb "$TOTAL_KB" \
  --df-free-kb "$FREE_KB" \
  --out "$OUT_MD" 2>"$WORK/render.err"
RC_RENDER=$?
[[ $RC_RENDER -eq 0 ]] && ok "render exits 0" || bad "render exit code" "$RC_RENDER: $(cat "$WORK/render.err")"
[[ -f "$OUT_MD" ]] && ok "render wrote the output file" || bad "render output file" "missing: $OUT_MD"

grep -qF "Invariant (a) parent == sum(children):** PASS" "$OUT_MD" \
  && ok "invariant (a) PASS with zero gap" \
  || bad "invariant (a)" "$(grep 'Invariant (a)' "$OUT_MD" || echo 'line not found')"

INVARIANT_B_LINE=$(grep "Invariant (b)" "$OUT_MD")
[[ "$INVARIANT_B_LINE" == *"PASS"* ]] && ok "invariant (b) PASS (df total reconciles exactly)" \
  || bad "invariant (b)" "$INVARIANT_B_LINE"

# Expected row count (see fixture comment above for the full derivation):
#   Users(1) + tester(1) + opaqueblob[opaque](1) + bigdir(1) + child2(1) + child1(1)
#   + small_a(1) + small_b(1) = 8 displayed rows, 0 gap rows,
#   + 1 "(unaccounted vs df total capacity)" row = 9 table body rows.
EXPECTED_ROW_COUNT=9
grep -qF "Row count:** $EXPECTED_ROW_COUNT" "$OUT_MD" \
  && ok "report header states Row count: $EXPECTED_ROW_COUNT" \
  || bad "header row count" "$(grep 'Row count' "$OUT_MD" || echo 'line not found')"

# Independently recount actual table body lines (lines starting with "| ",
# i.e. pipe-space, which the "|---:|---|" separator does NOT match) minus
# the header line itself.
PIPE_SPACE_LINES=$(grep -c '^| ' "$OUT_MD")
ACTUAL_DATA_ROWS=$((PIPE_SPACE_LINES - 1))
[[ "$ACTUAL_DATA_ROWS" -eq "$EXPECTED_ROW_COUNT" ]] \
  && ok "actual markdown table body row count == $EXPECTED_ROW_COUNT" \
  || bad "actual table row count" "expected $EXPECTED_ROW_COUNT, got $ACTUAL_DATA_ROWS"

grep -q '\[opaque\]' "$OUT_MD" && ok "opaqueblob is tagged [opaque] in the table" \
  || bad "[opaque] tag" "not found in $OUT_MD"

grep -q 'bigdir' "$OUT_MD" && grep -q 'child1' "$OUT_MD" && grep -q 'child2' "$OUT_MD" \
  && ok "bigdir was fully expanded to child1 + child2" \
  || bad "bigdir expansion" "one of bigdir/child1/child2 missing from $OUT_MD"

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
