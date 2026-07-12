#!/usr/bin/env bash
# test_frontier_scan.sh — TDD for scripts/disk_frontier_scan.{sh,py}
#
# Covers the critic BLOCKER-level correctness contract from
# roadmap/2026-07-11-total-coverage-snapshot-v2.md:
#   - symlink realpath dedup (never double-count an alias)
#   - exhaustive level-1 enumeration -> valid, complete JSON
#   - fixed timeout tiers + subdivide-on-exhaustion (not open-ended growth)
#   - single global worker pool never multiplied by subdivision
#   - graceful degrade under node/time budget exhaustion (never crash)
#   - signed residual clamping (clone/hardlink over-count case)
#
# Run: bash tests/test_frontier_scan.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCANNER="$REPO_ROOT/scripts/disk_frontier_scan.py"

WORK="$(mktemp -d -t frontier_scan_test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "── $1 ──"; }

json_get() {
  # json_get <file> <python-expr-on-loaded-dict-as-d>
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))
" "$1" "$2" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────
section "1. Valid JSON + required schema keys"
T1="$WORK/t1"
mkdir -p "$T1/a" "$T1/b"
dd if=/dev/zero of="$T1/a/f1" bs=1024 count=100 >/dev/null 2>&1
dd if=/dev/zero of="$T1/b/f2" bs=1024 count=50 >/dev/null 2>&1

OUT1="$WORK/out1.json"
if python3 "$SCANNER" --root "$T1" --no-sibling-volumes --no-purgeable \
     --workers 2 --wall-clock-cap 60 --output "$OUT1" >/dev/null 2>&1; then
  ok "scanner exits 0 on a tiny synthetic tree"
else
  bad "scanner exited non-zero on a tiny synthetic tree"
fi

if python3 -m json.tool "$OUT1" >/dev/null 2>&1; then
  ok "output is valid JSON"
else
  bad "output is NOT valid JSON"
fi

REQUIRED_KEYS="schema_version mode measured frontier_unfinished sibling_volumes purgeable_kb residual_kb elapsed_s"
for key in $REQUIRED_KEYS; do
  if json_get "$OUT1" "'$key' in d" 2>/dev/null | grep -q True; then
    ok "top-level key present: $key"
  else
    bad "top-level key MISSING: $key"
  fi
done

# ─────────────────────────────────────────────────────────────
section "2. Symlink realpath dedup — no double count (critic BLOCKER, live-verified /etc,/tmp,/var case)"
T2="$WORK/t2"
mkdir -p "$T2/real"
dd if=/dev/zero of="$T2/real/payload" bs=1024 count=200 >/dev/null 2>&1
ln -s "$T2/real" "$T2/alias_to_real"

OUT2="$WORK/out2.json"
python3 "$SCANNER" --root "$T2" --no-sibling-volumes --no-purgeable \
  --workers 2 --wall-clock-cap 60 --output "$OUT2" >/dev/null 2>&1

measured_total=$(json_get "$OUT2" "d['measured_total_kb']")
alias_kb=$(json_get "$OUT2" "d['measured'].get('$T2/alias_to_real', -1)")
real_kb=$(json_get "$OUT2" "d['measured'].get('$T2/real', -1)")

if [[ "$measured_total" == "200" ]]; then
  ok "measured_total_kb == 200 (payload counted exactly once, alias not double-counted)"
else
  bad "measured_total_kb == $measured_total (expected 200 — symlink alias was double-counted)"
fi

if [[ "$alias_kb" != "-1" && "$alias_kb" -lt 10 ]]; then
  ok "symlink alias measured as its own tiny size ($alias_kb KB), not recursed into"
else
  bad "symlink alias size unexpected: $alias_kb (du -P may have followed the symlink)"
fi

if [[ "$real_kb" == "200" ]]; then
  ok "real target measured once under its own path (200 KB)"
else
  bad "real target size unexpected: $real_kb"
fi

# ─────────────────────────────────────────────────────────────
section "3. RealpathDedupTrie unit test (direct, decoupled from symlink-skip path)"
TRIE_TEST_OUT=$(cd "$REPO_ROOT" && python3 -c "
import sys
sys.path.insert(0, 'scripts')
import disk_frontier_scan as m

trie = m.RealpathDedupTrie()
work = '$WORK/t3'
import os
os.makedirs(work + '/parent/child', exist_ok=True)

trie.add(work + '/parent')
covered_exact = trie.covered_by(work + '/parent')
covered_child = trie.covered_by(work + '/parent/child')
not_covered = trie.covered_by(work + '/unrelated')

print('exact=' + str(covered_exact is not None))
print('child=' + str(covered_child is not None))
print('unrelated=' + str(not_covered is None))
" 2>&1)

echo "$TRIE_TEST_OUT" | grep -q "^exact=True$" && ok "trie catches exact realpath re-visit" \
  || bad "trie did NOT catch exact realpath re-visit: $TRIE_TEST_OUT"
echo "$TRIE_TEST_OUT" | grep -q "^child=True$" && ok "trie catches a path nested under an already-covered real path" \
  || bad "trie did NOT catch nested-path containment: $TRIE_TEST_OUT"
echo "$TRIE_TEST_OUT" | grep -q "^unrelated=True$" && ok "trie does NOT false-positive on an unrelated path" \
  || bad "trie false-positived on an unrelated path: $TRIE_TEST_OUT"

# ─────────────────────────────────────────────────────────────
section "4. Timeout-tier escalation then subdivide-on-exhaustion (not open-ended growth)"
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/du" <<'FAKE_DU'
#!/usr/bin/env bash
# Fake du: hang forever for a dir literally named "slow_dir" (exact basename
# match, so its children — which contain "slow_dir" as a path prefix but not
# as their own basename — are unaffected and delegate to real du).
path="${@: -1}"
if [[ "$(basename "$path")" == "slow_dir" ]]; then
  sleep 30
  exit 1
fi
exec /usr/bin/du "$@"
FAKE_DU
chmod +x "$FAKEBIN/du"

T4="$WORK/t4"
mkdir -p "$T4/slow_dir/childA" "$T4/slow_dir/childB" "$T4/fast_dir"
dd if=/dev/zero of="$T4/slow_dir/childA/f" bs=1024 count=10 >/dev/null 2>&1
dd if=/dev/zero of="$T4/slow_dir/childB/f" bs=1024 count=20 >/dev/null 2>&1
dd if=/dev/zero of="$T4/fast_dir/f" bs=1024 count=5 >/dev/null 2>&1

OUT4="$WORK/out4.json"
PATH="$FAKEBIN:$PATH" python3 "$SCANNER" --root "$T4" --no-sibling-volumes --no-purgeable \
  --workers 4 --wall-clock-cap 60 --timeout-tiers 1,1,1,1 --output "$OUT4" >/dev/null 2>&1

slow_dir_measured=$(json_get "$OUT4" "'$T4/slow_dir' in d['measured']")
childA_measured=$(json_get "$OUT4" "d['measured'].get('$T4/slow_dir/childA', -1)")
childB_measured=$(json_get "$OUT4" "d['measured'].get('$T4/slow_dir/childB', -1)")
fast_measured=$(json_get "$OUT4" "d['measured'].get('$T4/fast_dir', -1)")

        # du reports allocated blocks, not raw byte count, so small files
        # round up (APFS observed: a 10K file -> 12K). Assert "measured and
        # in the right ballpark" (>= raw size, well under 2x), not byte-exact.
in_ballpark() { local got="$1" raw="$2"; [[ "$got" != "-1" ]] && (( got >= raw )) && (( got <= raw * 2 + 8 )); }

[[ "$slow_dir_measured" == "False" ]] && ok "slow_dir itself was NOT measured directly (subdivided after tier exhaustion)" \
  || bad "slow_dir was measured directly — subdivision did not trigger: $slow_dir_measured"
in_ballpark "$childA_measured" 10 && ok "slow_dir/childA measured after subdivision (~10 KB, got $childA_measured — du block-rounds)" \
  || bad "slow_dir/childA not measured correctly: $childA_measured"
in_ballpark "$childB_measured" 20 && ok "slow_dir/childB measured after subdivision (~20 KB, got $childB_measured — du block-rounds)" \
  || bad "slow_dir/childB not measured correctly: $childB_measured"
in_ballpark "$fast_measured" 5 && ok "sibling fast_dir unaffected by slow_dir's timeouts (~5 KB, got $fast_measured — du block-rounds)" \
  || bad "fast_dir measurement unexpected: $fast_measured"

# ─────────────────────────────────────────────────────────────
section "5. Global worker pool never exceeds configured cap (subdivision must not multiply workers)"
T5="$WORK/t5"
mkdir -p "$T5"
for i in $(seq 1 12); do
  mkdir -p "$T5/dir$i"
  dd if=/dev/zero of="$T5/dir$i/f" bs=1024 count=1 >/dev/null 2>&1
done

STDERR5="$WORK/stderr5.txt"
python3 "$SCANNER" --root "$T5" --no-sibling-volumes --no-purgeable \
  --workers 3 --wall-clock-cap 60 --debug-concurrency \
  --output "$WORK/out5.json" 2>"$STDERR5" >/dev/null

peak=$(grep -o 'MAX_CONCURRENT_DU=[0-9]*' "$STDERR5" | cut -d= -f2)
if [[ -n "$peak" && "$peak" -le 3 ]]; then
  ok "observed peak concurrent du ($peak) never exceeds configured worker cap (3)"
else
  bad "observed peak concurrent du ($peak) exceeded configured worker cap (3) — pool was multiplied"
fi

# ─────────────────────────────────────────────────────────────
section "6. Graceful degrade under node-budget exhaustion (never crash, name the unfinished paths)"
T6="$WORK/t6"
mkdir -p "$T6"
for i in $(seq 1 8); do
  mkdir -p "$T6/n$i"
  dd if=/dev/zero of="$T6/n$i/f" bs=1024 count=1 >/dev/null 2>&1
done

OUT6="$WORK/out6.json"
if python3 "$SCANNER" --root "$T6" --no-sibling-volumes --no-purgeable \
     --workers 4 --max-nodes 3 --wall-clock-cap 60 --output "$OUT6" >/dev/null 2>&1; then
  ok "scanner exits 0 even when node budget is exhausted mid-scan"
else
  bad "scanner crashed/non-zero exit under node-budget exhaustion"
fi

unfinished_count=$(json_get "$OUT6" "len(d['frontier_unfinished'])")
mode6=$(json_get "$OUT6" "d['mode']")
node_budget_reason=$(json_get "$OUT6" "any(f['reason']=='node_budget_exhausted' for f in d['frontier_unfinished'])")

[[ "${unfinished_count:-0}" -gt 0 ]] && ok "unfinished nodes are explicitly named ($unfinished_count entries), not silently dropped" \
  || bad "expected named unfinished frontier entries under a tight node budget, got none"
[[ "$mode6" == "partial" ]] && ok "mode correctly reports 'partial' when frontier_unfinished is non-empty" \
  || bad "mode should be 'partial', got: $mode6"
[[ "$node_budget_reason" == "True" ]] && ok "at least one unfinished entry cites node_budget_exhausted" \
  || bad "no unfinished entry cited node_budget_exhausted: $node_budget_reason"

# ─────────────────────────────────────────────────────────────
section "7. Signed residual clamping (clone/hardlink over-count must never crash or go negative in the display field)"
T7="$WORK/t7"
mkdir -p "$T7/x"
dd if=/dev/zero of="$T7/x/f" bs=1024 count=500 >/dev/null 2>&1

OUT7="$WORK/out7.json"
python3 "$SCANNER" --root "$T7" --no-sibling-volumes --no-purgeable \
  --workers 2 --wall-clock-cap 60 --disk-used-kb-override 10 \
  --output "$OUT7" >/dev/null 2>&1

residual_kb=$(json_get "$OUT7" "d['residual_kb']")
residual_raw=$(json_get "$OUT7" "d['residual_raw_kb']")
clamped=$(json_get "$OUT7" "d['residual_negative_clamped']")
clones=$(json_get "$OUT7" "d['clones_suspected']")

[[ "$residual_kb" == "0" ]] && ok "residual_kb clamped to 0 for display when measured exceeds forced disk_used_kb" \
  || bad "residual_kb not clamped: $residual_kb"
[[ "${residual_raw:-0}" -lt 0 ]] && ok "residual_raw_kb preserves the true negative value ($residual_raw) for audit" \
  || bad "residual_raw_kb should be negative, got: $residual_raw"
[[ "$clamped" == "True" ]] && ok "residual_negative_clamped flag set" \
  || bad "residual_negative_clamped flag not set: $clamped"
[[ "$clones" == "True" ]] && ok "clones_suspected flag set alongside the clamp" \
  || bad "clones_suspected flag not set: $clones"

# ─────────────────────────────────────────────────────────────
section "Summary"
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "TESTS FAILED"
  exit 1
fi
