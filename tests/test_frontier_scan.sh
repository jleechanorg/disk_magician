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

PERMISSION_TEST_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import sys
from unittest import mock
sys.path.insert(0, "scripts")
import disk_frontier_scan as m

with mock.patch.object(m.os, "scandir", side_effect=PermissionError(1, "Operation not permitted")):
    print(m.list_children("/protected") == (None, "permission_denied_or_tcc"))
PY
)
[[ "$PERMISSION_TEST_OUT" == "True" ]] && ok "child enumeration identifies permission/TCC denial explicitly" \
  || bad "child enumeration hid permission/TCC denial: $PERMISSION_TEST_OUT"

SYMLINK_ORDER_OUT=$(cd "$REPO_ROOT" && python3 - "$WORK" <<'PY'
import os
import sys
import time
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

work = os.path.join(sys.argv[1], "symlink-order")
os.makedirs(os.path.join(work, "real"), exist_ok=True)
alias = os.path.join(work, "alias")
os.symlink(os.path.join(work, "real"), alias)
args = SimpleNamespace(
    root=work, resolve_root=False, workers=1, max_depth=6, max_nodes=10,
    wall_clock_cap=10, timeout_tiers=[1], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=0,
)
scanner = m.FrontierScanner(args)
scanner.start_time = time.time()
scanner.root_dev = os.lstat(alias).st_dev
with mock.patch.object(scanner, "measure_one", return_value=0):
    scanner.process_node(alias, 1, True)
print(scanner.trie.covered_by(os.path.join(work, "real")) is None)
PY
)
[[ "$SYMLINK_ORDER_OUT" == "True" ]] && ok "measuring a symlink first does not mark its real payload covered" \
  || bad "symlink-first ordering hid the real payload: $SYMLINK_ORDER_OUT"

GRANULARITY_LIMIT_OUT=$(cd "$REPO_ROOT" && python3 - "$WORK" <<'PY'
import os
import sys
import time
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

path = os.path.join(sys.argv[1], "granularity-limit")
os.makedirs(path, exist_ok=True)
args = SimpleNamespace(
    root=path, resolve_root=False, workers=1, max_depth=1, max_nodes=10,
    wall_clock_cap=10, timeout_tiers=[1], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=5,
)
scanner = m.FrontierScanner(args)
scanner.start_time = time.time()
scanner.root_dev = os.lstat(path).st_dev
with mock.patch.object(scanner, "measure_one", return_value=6 * 1024 * 1024):
    scanner.process_node(path, 1, False)
print(any(item.get("reason") == "granularity_max_depth_reached"
          for item in scanner.frontier_unfinished))
PY
)
[[ "$GRANULARITY_LIMIT_OUT" == "True" ]] && ok "large parent names the limit when 5 GiB subdivision cannot continue" \
  || bad "large parent falsely looked complete at requested granularity: $GRANULARITY_LIMIT_OUT"

APFS_CONTAINER_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import plistlib
import sys
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

apfs = {"Containers": [
    {"ContainerReference": "disk7", "CapacityCeiling": 20_000,
     "CapacityFree": 1_000, "PhysicalStores": [{"DeviceIdentifier": "disk6s1", "Size": 20_000}],
     "Volumes": [{"Name": "Simulator", "Roles": [], "CapacityInUse": 19_000}]},
    {"ContainerReference": "disk3", "CapacityCeiling": 1_000_000,
     "CapacityFree": 100_000, "PhysicalStores": [{"DeviceIdentifier": "disk0s2", "Size": 1_000_000}],
     "Volumes": [{"Name": "Data", "Roles": ["Data"], "CapacityInUse": 800_000},
                 {"Name": "VM", "Roles": ["VM"], "CapacityInUse": 50_000}]},
]}
root = {"APFSContainerReference": "disk3"}
accounting = {}
with mock.patch.object(
    m.subprocess, "check_output",
    side_effect=[plistlib.dumps(apfs), plistlib.dumps(root)],
):
    m.get_sibling_volumes("/System/Volumes/Data", [], accounting)
print(accounting.get("container_reference") == "disk3" and
      accounting.get("physical_stores", [{}])[0].get("device") == "disk0s2")
PY
)
[[ "$APFS_CONTAINER_OUT" == "True" ]] && ok "Data mount selects its APFSContainerReference, not a simulator container" \
  || bad "APFS accounting selected the wrong container: $APFS_CONTAINER_OUT"

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
section "8. Partial du output with a failing exit code is never reported as complete"
T8_PARTIAL="$WORK/t8_partial"
PARTIAL_BIN="$WORK/partial_bin"
mkdir -p "$T8_PARTIAL/protected" "$PARTIAL_BIN"
cat > "$PARTIAL_BIN/du" <<'PARTIAL_DU'
#!/usr/bin/env bash
path="${@: -1}"
printf '123\t%s\n' "$path"
echo "du: protected child: Operation not permitted" >&2
exit 1
PARTIAL_DU
chmod +x "$PARTIAL_BIN/du"

OUT8_PARTIAL="$WORK/out8_partial.json"
PATH="$PARTIAL_BIN:$PATH" python3 "$SCANNER" --root "$T8_PARTIAL" \
  --no-sibling-volumes --no-purgeable --workers 1 --max-depth 1 \
  --timeout-tiers 1 --wall-clock-cap 10 --output "$OUT8_PARTIAL" \
  >/dev/null 2>&1

if python3 - "$OUT8_PARTIAL" "$T8_PARTIAL/protected" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
path = sys.argv[2]
assert path not in d["measured"]
assert d["mode"] == "partial"
assert any(item["path"] == path for item in d["frontier_unfinished"])
PY
then
  ok "nonzero du exit with partial stdout stays on the named unfinished frontier"
else
  bad "nonzero du exit was silently accepted as a complete measurement"
fi

section "9. --output state-file mode (atomic write, stdout stays intact, --output-default resolution)"
T8="$WORK/t8"
mkdir -p "$T8/x"
dd if=/dev/zero of="$T8/x/f" bs=1024 count=30 >/dev/null 2>&1

OUT8="$WORK/state_out.json"
STDOUT8="$WORK/stdout8.txt"
python3 "$SCANNER" --root "$T8" --no-sibling-volumes --no-purgeable \
  --workers 2 --wall-clock-cap 60 --output "$OUT8" >"$STDOUT8" 2>&1

if [[ -s "$OUT8" ]] && python3 -m json.tool "$OUT8" >/dev/null 2>&1; then
  ok "--output writes a complete, valid JSON file (atomic write landed cleanly)"
else
  bad "--output file missing or not valid JSON"
fi

if [[ -s "$STDOUT8" ]] && python3 -m json.tool "$STDOUT8" >/dev/null 2>&1; then
  ok "stdout still carries the same valid JSON when --output is also used (additive, not replaced)"
else
  bad "stdout was empty or invalid when --output was used — should be additive per contract"
fi

stdout_measured=$(json_get "$STDOUT8" "d['measured_total_kb']")
file_measured=$(json_get "$OUT8" "d['measured_total_kb']")
if [[ -n "$stdout_measured" && "$stdout_measured" == "$file_measured" ]]; then
  ok "stdout and --output file contain the same report (measured_total_kb: $stdout_measured)"
else
  bad "stdout ($stdout_measured) and --output file ($file_measured) disagree"
fi

perm=$(stat -f "%Mp%Lp" "$OUT8" 2>/dev/null || stat -c "%a" "$OUT8" 2>/dev/null)
[[ "$perm" == *"644" ]] && ok "--output file has 0644 permissions ($perm)" \
  || bad "--output file has unexpected permissions: $perm"

# --output-default: point HOME at a scratch dir so we never touch the
# real ~/.disk_magician_state, and confirm the resolved path + dir creation.
HOME_SCRATCH="$WORK/home_scratch"
mkdir -p "$HOME_SCRATCH"
EXPECTED_DEFAULT="$HOME_SCRATCH/.disk_magician_state/frontier_last.json"

if [[ -e "$EXPECTED_DEFAULT" ]]; then
  bad "--output-default target already exists before the run (test setup bug)"
else
  ok "--output-default target does not pre-exist (clean scratch HOME)"
fi

HOME="$HOME_SCRATCH" python3 "$SCANNER" --root "$T8" --no-sibling-volumes --no-purgeable \
  --workers 2 --wall-clock-cap 60 --output-default >/dev/null 2>&1

if [[ -s "$EXPECTED_DEFAULT" ]] && python3 -m json.tool "$EXPECTED_DEFAULT" >/dev/null 2>&1; then
  ok "--output-default resolved to ~/.disk_magician_state/frontier_last.json and wrote valid JSON (parent dir auto-created)"
else
  bad "--output-default did not produce a valid file at $EXPECTED_DEFAULT"
fi

# Atomicity check: no leftover .tmp files after a normal run.
leftover_tmp=$(find "$WORK" -name ".disk_frontier_scan.*.tmp" 2>/dev/null | wc -l | tr -d ' ')
[[ "$leftover_tmp" == "0" ]] && ok "no leftover atomic-write temp files after successful runs" \
  || bad "found $leftover_tmp leftover .tmp file(s) — atomic write did not clean up"

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
