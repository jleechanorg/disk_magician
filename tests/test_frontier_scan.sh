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
export DISK_MAGICIAN_GDU_CMD=""

WORK="$(mktemp -d -t frontier_scan_test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Production deliberately runs scanners through taskpolicy/nice. Under live
# runner I/O pressure that can starve even tiny fixtures, so tests preserve
# the argv contract while executing the wrapped command without throttling.
LOW_PRIORITY_BIN="$WORK/low-priority-bin"
mkdir -p "$LOW_PRIORITY_BIN"
cat > "$LOW_PRIORITY_BIN/taskpolicy" <<'TEST_TASKPOLICY'
#!/usr/bin/env bash
[[ "${1:-}" == "-b" ]] && shift
exec "$@"
TEST_TASKPOLICY
cat > "$LOW_PRIORITY_BIN/nice" <<'TEST_NICE'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then shift 2; fi
exec "$@"
TEST_NICE
chmod +x "$LOW_PRIORITY_BIN/taskpolicy" "$LOW_PRIORITY_BIN/nice"
export PATH="$LOW_PRIORITY_BIN:$PATH"

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

ROOT_PRIORITY_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import os
import sys
sys.path.insert(0, "scripts")
import disk_frontier_scan as m

root = "/System/Volumes/Data"
frontier = [
    (os.path.join(root, name), 1, False)
    for name in ("Applications", "zzz", "Library", "opt", ".Spotlight-V100", "private", "Users", "System")
]
ordered = sorted(frontier, key=lambda item: m.frontier_sort_key(root, item))
print(",".join(os.path.basename(item[0]) for item in ordered))
PY
)
expected_priority="Users,private,.Spotlight-V100,opt,Library,Applications,System,zzz"
[[ "$ROOT_PRIORITY_OUT" == "$expected_priority" ]] && ok "whole-disk frontier schedules high-value Data roots before app fan-out" \
  || bad "whole-disk frontier priority was '$ROOT_PRIORITY_OUT' (expected '$expected_priority')"

HOME_PRIORITY_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import os
import sys

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

root = "/System/Volumes/Data"
base = os.path.join(root, "Users", "fixture")
frontier = [
    (os.path.join(base, name), 3, False)
    for name in ("zzz", ".agents", ".codex", ".colima", "Library", "projects")
]
ordered = sorted(frontier, key=lambda item: m.frontier_sort_key(root, item))
print(",".join(os.path.basename(item[0]) for item in ordered))
PY
)
expected_home_priority="projects,Library,.colima,.codex,.agents,zzz"
[[ "$HOME_PRIORITY_OUT" == "$expected_home_priority" ]] && ok "home frontier schedules known high-volume roots before alphabetic dot-directory fan-out" \
  || bad "home frontier priority was '$HOME_PRIORITY_OUT' (expected '$expected_home_priority')"

PROJECT_CHILD_PRIORITY_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import os
import sys

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

root = "/System/Volumes/Data"
base = os.path.join(root, "Users", "fixture", "projects")
frontier = [
    (os.path.join(base, name), 4, False)
    for name in (".beads", ".claude", "worldarchitect.ai", "agent-orchestrator")
]
ordered = sorted(frontier, key=lambda item: m.frontier_sort_key(root, item))
print(",".join(os.path.basename(item[0]) for item in ordered))
PY
)
expected_project_child_priority="agent-orchestrator,worldarchitect.ai,.beads,.claude"
[[ "$PROJECT_CHILD_PRIORITY_OUT" == "$expected_project_child_priority" ]] && ok "project content outranks hidden metadata within a high-volume root" \
  || bad "project child priority was '$PROJECT_CHILD_PRIORITY_OUT' (expected '$expected_project_child_priority')"

CROSS_DEPTH_PRIORITY_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import os
import sys

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

root = "/System/Volumes/Data"
frontier = [
    (os.path.join(root, "Library", "Fonts"), 2, False),
    (os.path.join(root, "Users", "fixture", "projects", "repo"), 4, False),
    (os.path.join(root, "Users", "fixture"), 2, False),
    (os.path.join(root, "System", "Library"), 2, False),
]
ordered = sorted(frontier, key=lambda item: m.frontier_sort_key(root, item))
print(",".join(os.path.relpath(item[0], root) for item in ordered))
PY
)
expected_cross_depth="Users/fixture,Users/fixture/projects/repo,Library/Fonts,System/Library"
[[ "$CROSS_DEPTH_PRIORITY_OUT" == "$expected_cross_depth" ]] && ok "deep Users descendants outrank shallow system-dir fan-out (jleechan-ez97)" \
  || bad "cross-depth priority was '$CROSS_DEPTH_PRIORITY_OUT' (expected '$expected_cross_depth')"

SHALLOW_ENUMERATION_OUT=$(cd "$REPO_ROOT" && python3 - "$WORK" <<'PY'
import os
import sys
import time
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

root = os.path.join(sys.argv[1], "shallow-enumeration")
path = os.path.join(root, "Users", "fixture")
child = os.path.join(path, "projects")
os.makedirs(child, exist_ok=True)
args = SimpleNamespace(
    root=root, resolve_root=False, workers=1, max_depth=6, max_nodes=10,
    wall_clock_cap=10, timeout_tiers=[1], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=5, shallow_enumeration_depth=2,
)
scanner = m.FrontierScanner(args)
scanner.start_time = time.time()
scanner.root_dev = os.lstat(root).st_dev
with mock.patch.object(scanner, "measure_one", return_value=1) as measure:
    next_frontier = scanner.process_node(path, 2, False)
print(measure.call_count == 0,
      next_frontier == [(child, 3, False)],
      path not in scanner.measured)
PY
)
[[ "$SHALLOW_ENUMERATION_OUT" == "True True True" ]] && ok "shallow namespace directories enumerate before expensive parent aggregation" \
  || bad "shallow directory wasted budget on a parent total: $SHALLOW_ENUMERATION_OUT"

STREAMING_FRONTIER_OUT=$(cd "$REPO_ROOT" && python3 - "$WORK" <<'PY'
import os
import sys
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

root = os.path.join(sys.argv[1], "streaming-frontier")
first = os.path.join(root, "a")
child = os.path.join(first, "child")
last = os.path.join(root, "z")
os.makedirs(child, exist_ok=True)
os.makedirs(last, exist_ok=True)
args = SimpleNamespace(
    root=root, resolve_root=False, workers=1, max_depth=6, max_nodes=10,
    wall_clock_cap=10, timeout_tiers=[1], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=5,
)
scanner = m.FrontierScanner(args)
order = []

def process(path, depth, is_symlink):
    rel = os.path.relpath(path, root)
    order.append(rel)
    if path == first:
        return [(child, depth + 1, False)]
    return None

with mock.patch.object(scanner, "process_node", side_effect=process), \
     mock.patch.object(scanner, "maybe_throttle"):
    scanner.run()
print(order == ["a", "z", os.path.join("a", "child")], order)
PY
)
[[ "$STREAMING_FRONTIER_OUT" == "True ['a', 'z', 'a/child']" ]] && ok "streaming frontier preserves breadth fairness before deeper children" \
  || bad "deeper children starved shallower siblings: $STREAMING_FRONTIER_OUT"

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
limit_named = any(item.get("reason") == "granularity_max_depth_reached"
                  for item in scanner.frontier_unfinished)
buckets = m.build_granularity_buckets(scanner.measured, path, 5 * 1024 * 1024)
print(limit_named, path not in scanner.measured, buckets == [])
PY
)
[[ "$GRANULARITY_LIMIT_OUT" == "True True True" ]] && ok "large unfinished parent stays out of the <=5 GiB leaf ledger" \
  || bad "large parent falsely looked complete at requested granularity: $GRANULARITY_LIMIT_OUT"

MAX_BUCKET_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import sys

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

gib = 1024 * 1024
root = "/fixture"
measured = {
    f"{root}/large/a": 4 * gib,
    f"{root}/large/b": 4 * gib,
    f"{root}/large/c": 4 * gib,
}
buckets = m.build_granularity_buckets(measured, root, 5 * gib)
expected = [
    {"path": f"{root}/large/a", "measured_kb": 4 * gib},
    {"path": f"{root}/large/b", "measured_kb": 4 * gib},
    {"path": f"{root}/large/c", "measured_kb": 4 * gib},
]
print(buckets == expected,
      all(item["measured_kb"] <= 5 * gib for item in buckets),
      sum(item["measured_kb"] for item in buckets) == 12 * gib)
PY
)
[[ "$MAX_BUCKET_OUT" == "True True True" ]] && ok "display partition recursively subdivides every directory above 5 GiB" \
  || bad "display partition emitted an oversized parent or lost bytes: $MAX_BUCKET_OUT"

OVERSIZE_FILE_OUT=$(cd "$REPO_ROOT" && python3 - "$WORK" <<'PY'
import os
import sys
import time
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

gib = 1024 * 1024
root = os.path.join(sys.argv[1], "oversize-file")
os.makedirs(root, exist_ok=True)
path = os.path.join(root, "large.bin")
with open(path, "wb") as f:
    f.write(b"x" * 4096)
args = SimpleNamespace(
    root=root, resolve_root=False, workers=1, max_depth=6, max_nodes=10,
    wall_clock_cap=10, timeout_tiers=[1], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=5,
)
scanner = m.FrontierScanner(args)
scanner.start_time = time.time()
scanner.root_dev = os.lstat(root).st_dev
real = os.lstat(path)
fake = SimpleNamespace(
    st_dev=real.st_dev,
    st_mode=real.st_mode,
    st_blocks=12 * gib,
)
with mock.patch.object(m.os, "lstat", return_value=fake):
    scanner.process_node(path, 1, False)
print(scanner.measured.get(path) == 6 * gib,
      scanner.oversize_files == [
          {"path": path, "measured_kb": 6 * gib, "reason": "indivisible_file"}
      ],
      m.build_granularity_buckets(scanner.measured, root, 5 * gib) == [])
PY
)
[[ "$OVERSIZE_FILE_OUT" == "True True True" ]] && ok "indivisible file above 5 GiB is separate from bounded directory buckets" \
  || bad "oversize file was hidden or emitted as a normal bucket: $OVERSIZE_FILE_OUT"

REGULAR_FILE_BACKEND_OUT=$(cd "$REPO_ROOT" && python3 - "$WORK" <<'PY'
import os
import sys
import time
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

root = os.path.join(sys.argv[1], "regular-file-backend")
os.makedirs(root, exist_ok=True)
path = os.path.join(root, "payload.bin")
with open(path, "wb") as f:
    f.write(b"x" * 4096)
args = SimpleNamespace(
    root=root, resolve_root=False, workers=1, max_depth=6, max_nodes=10,
    wall_clock_cap=10, timeout_tiers=[1], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=5,
)
scanner = m.FrontierScanner(args)
scanner.start_time = time.time()
scanner.root_dev = os.lstat(root).st_dev
with mock.patch.object(scanner, "measure_one", return_value=1) as measure:
    scanner.process_node(path, 1, False)
expected_kb = (os.lstat(path).st_blocks * 512 + 1023) // 1024
print(measure.call_count == 0,
      scanner.measured.get(path) == expected_kb)
PY
)
[[ "$REGULAR_FILE_BACKEND_OUT" == "True True" ]] && ok "regular files use native allocated blocks without a subprocess" \
  || bad "regular file was sent through a subprocess backend: $REGULAR_FILE_BACKEND_OUT"

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

GDU_BACKEND_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import subprocess
import sys
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

completed = subprocess.CompletedProcess(
    ["/fake/gdu"], 0, stdout="6144\t/fixture\n", stderr=""
)
with mock.patch.object(m, "GDU_CMD", "/fake/gdu"), \
     mock.patch.object(m, "DUA_CMD", "/fake/dua"), \
     mock.patch.object(m.subprocess, "run", return_value=completed) as run:
    kb = m.run_du("/fixture", 1, m.ConcurrencyTracker())
cmd = run.call_args.args[0]
print(kb, cmd)
PY
)
[[ "$GDU_BACKEND_OUT" == "6144 ['/fake/gdu', '-x', '-k', '-s', '/fixture']" ]] && ok "installed GNU du backend is preferred and parsed as allocated KiB" \
  || bad "GNU du backend was not preferred or parsed correctly: $GDU_BACKEND_OUT"

GDU_INVENTORY_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import subprocess
import sys
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

gib = 1024 * 1024
raw = "".join(
    f"{kb}\t{path}\0"
    for kb, path in [
        (4 * gib, "/fixture/shard-a/one"),
        (4 * gib, "/fixture/shard-a/two"),
        (8 * gib, "/fixture/shard-a"),
    ]
)
completed = subprocess.CompletedProcess(["/fake/gdu"], 0, stdout=raw, stderr="")
with mock.patch.object(m, "GDU_CMD", "/fake/gdu"), \
     mock.patch.object(m.subprocess, "run", return_value=completed) as run:
    result = m.run_gdu_inventory(
        ["/fixture/shard-a"], 10, m.ConcurrencyTracker(), 10_000_000
    )
cmd = run.call_args.args[0]
print(
    run.call_count == 1,
    cmd == ["/fake/gdu", "-x", "-k", "--null", "--", "/fixture/shard-a"],
    "-s" not in cmd,
    result["records"]["/fixture/shard-a"] == 8 * gib,
    len(result["records"]) == 3,
)
PY
)
[[ "$GDU_INVENTORY_OUT" == "True True True True True" ]] && ok "GNU du inventory walks a shard once and retains postorder records" \
  || bad "GNU du one-pass inventory contract failed: $GDU_INVENTORY_OUT"

GDU_UNKNOWN_ERROR_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import subprocess
import sys
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

completed = subprocess.CompletedProcess(
    ["/fake/gdu"], 1, stdout="4\t/fixture/clean\0", stderr="gdu: unexpected diagnostic"
)
with mock.patch.object(m, "GDU_CMD", "/fake/gdu"), \
     mock.patch.object(m.subprocess, "run", return_value=completed):
    result = m.run_gdu_inventory(
        ["/fixture/clean"], 10, m.ConcurrencyTracker(), 10_000_000
    )
print(result["usable"], bool(result["unknown_errors"]))
PY
)
[[ "$GDU_UNKNOWN_ERROR_OUT" == "False True" ]] && ok "unknown GNU du diagnostics fail closed instead of accepting partial totals" \
  || bad "unknown GNU du diagnostic entered the accepted inventory: $GDU_UNKNOWN_ERROR_OUT"

GDU_INVENTORY_PARTITION_OUT=$(cd "$REPO_ROOT" && python3 - "$WORK" <<'PY'
import os
import subprocess
import sys
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

gib = 1024 * 1024
root = os.path.join(sys.argv[1], "gdu-inventory-partition")
shard_a = os.path.join(root, "shard-a")
one = os.path.join(shard_a, "one")
two = os.path.join(shard_a, "two")
shard_b = os.path.join(root, "shard-b")
huge = os.path.join(root, "huge.bin")
protected = os.path.join(root, "protected")
for path in (one, two, shard_b, protected):
    os.makedirs(path, exist_ok=True)
for path in (os.path.join(one, "payload.bin"), os.path.join(two, "payload.bin"),
             os.path.join(shard_b, "payload.bin"), huge):
    with open(path, "wb") as f:
        f.write(b"x")

rows = [
    (4 * gib, one),
    (4 * gib, two),
    (8 * gib, shard_a),
    (3 * gib, shard_b),
    (7 * gib, huge),
    (1, protected),
]
raw = "".join(f"{kb}\t{path}\0" for kb, path in rows)
stderr = f"gdu: cannot read directory '{protected}': Permission denied\n"
completed = subprocess.CompletedProcess(["/fake/gdu"], 1, stdout=raw, stderr=stderr)
args = SimpleNamespace(
    root=root, resolve_root=False, workers=2, max_depth=6, max_nodes=10_000_000,
    wall_clock_cap=10, timeout_tiers=[10], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=5, shallow_enumeration_depth=0,
)
scanner = m.FrontierScanner(args)
with mock.patch.object(m, "GDU_CMD", "/fake/gdu"), \
     mock.patch.object(m.subprocess, "run", return_value=completed) as run:
    error = scanner.run()

commands = [call.args[0] for call in run.call_args_list]
buckets = getattr(scanner, "inventory_buckets", [])
bucket_paths = [item["path"] for item in buckets]
oversize = scanner.oversize_files
unfinished = scanner.frontier_unfinished
measured_total = sum(scanner.measured.values())
nonoverlap = not any(
    left != right and (
        left.startswith(right.rstrip(os.sep) + os.sep)
        or right.startswith(left.rstrip(os.sep) + os.sep)
    )
    for left in bucket_paths for right in bucket_paths
)
print(
    error is None,
    len(commands) == 1,
    set(commands[0][5:]) == {shard_a, shard_b, huge, protected},
    all(item["measured_kb"] <= 5 * gib for item in buckets),
    set(bucket_paths) == {one, two, shard_b},
    oversize == [{"path": huge, "measured_kb": 7 * gib, "reason": "indivisible_file"}],
    any(item.get("path") == protected and item.get("reason") == "inventory_permission_denied"
        for item in unfinished),
    all(not path.startswith(protected + os.sep) and path != protected for path in bucket_paths),
    measured_total == 18 * gib,
    sum(item["measured_kb"] for item in buckets) + sum(item["measured_kb"] for item in oversize)
        == measured_total,
    nonoverlap,
)
PY
)
[[ "$GDU_INVENTORY_PARTITION_OUT" == "True True True True True True True True True True True" ]] && ok "one-pass inventory yields a bounded, failure-isolated, exactly reconciled partition" \
  || bad "one-pass inventory partition contract failed: $GDU_INVENTORY_PARTITION_OUT"

GDU_DIRECT_SEGMENTS_OUT=$(cd "$REPO_ROOT" && python3 - "$WORK" <<'PY'
import os
import subprocess
import sys
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

gib = 1024 * 1024
root = os.path.join(sys.argv[1], "gdu-direct-segments")
heavy = os.path.join(root, "direct-heavy")
os.makedirs(heavy, exist_ok=True)
raw = f"{12 * gib}\t{heavy}\0"
completed = subprocess.CompletedProcess(["/fake/gdu"], 0, stdout=raw, stderr="")
args = SimpleNamespace(
    root=root, resolve_root=False, workers=1, max_depth=6, max_nodes=100_000_000,
    wall_clock_cap=10, timeout_tiers=[10], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=5, shallow_enumeration_depth=0,
)
scanner = m.FrontierScanner(args)
with mock.patch.object(m, "GDU_CMD", "/fake/gdu"), \
     mock.patch.object(m.subprocess, "run", return_value=completed):
    scanner.run()
sizes = sorted(item["measured_kb"] for item in scanner.inventory_buckets)
print(
    sizes == [2 * gib, 5 * gib, 5 * gib],
    all(item.get("kind") == "direct_allocation_segment" for item in scanner.inventory_buckets),
    sum(sizes) == 12 * gib,
    not scanner.oversize_files,
)
PY
)
[[ "$GDU_DIRECT_SEGMENTS_OUT" == "True True True True" ]] && ok "large direct-file allocation is split into honest <=5 GiB path segments" \
  || bad "direct allocation stayed as an oversized hidden tail: $GDU_DIRECT_SEGMENTS_OUT"

GDU_MISSING_ANCESTOR_OUT=$(cd "$REPO_ROOT" && python3 - "$WORK" <<'PY'
import os
import subprocess
import sys
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

gib = 1024 * 1024
root = os.path.join(sys.argv[1], "gdu-missing-ancestor")
shard = os.path.join(root, "System")
safe = os.path.join(shard, "Library", "AssetsV2")
failed = os.path.join(shard, "Library", "Speech")
os.makedirs(safe, exist_ok=True)
raw = f"{4 * gib}\t{safe}\0"
stderr = f"gdu: fts_read failed: {failed}: No such file or directory\n"
completed = subprocess.CompletedProcess(["/fake/gdu"], 1, stdout=raw, stderr=stderr)
args = SimpleNamespace(
    root=root, resolve_root=False, workers=1, max_depth=6, max_nodes=100_000_000,
    wall_clock_cap=10, timeout_tiers=[10], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=5, shallow_enumeration_depth=0,
)
scanner = m.FrontierScanner(args)
with mock.patch.object(m, "GDU_CMD", "/fake/gdu"), \
     mock.patch.object(m.subprocess, "run", return_value=completed):
    scanner.run()
print(
    scanner.measured == {safe: 4 * gib},
    scanner.inventory_buckets == [{"path": safe, "measured_kb": 4 * gib}],
    any(item.get("path") == failed and item.get("reason") == "inventory_path_disappeared"
        for item in scanner.frontier_unfinished),
)
PY
)
[[ "$GDU_MISSING_ANCESTOR_OUT" == "True True True" ]] && ok "missing tainted ancestor preserves clean descendant attribution" \
  || bad "missing GNU du ancestor orphaned clean descendant rows: $GDU_MISSING_ANCESTOR_OUT"

GDU_DUA_FALLBACK_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import subprocess
import sys
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

calls = []
def run(cmd, **kwargs):
    calls.append(cmd[0])
    if cmd[0] == "/fake/gdu":
        return subprocess.CompletedProcess(cmd, 1, stdout="bad partial\n", stderr="failed")
    if cmd[0] == "/fake/dua":
        return subprocess.CompletedProcess(cmd, 0, stdout="6291456 b total\n", stderr="")
    raise AssertionError(f"unexpected backend: {cmd}")

with mock.patch.object(m, "GDU_CMD", "/fake/gdu"), \
     mock.patch.object(m, "DUA_CMD", "/fake/dua"), \
     mock.patch.object(m.subprocess, "run", side_effect=run):
    kb = m.run_du("/fixture", 1, m.ConcurrencyTracker())
print(kb, calls)
PY
)
[[ "$GDU_DUA_FALLBACK_OUT" == "6144 ['/fake/gdu', '/fake/dua']" ]] && ok "failed GNU du falls through to dua before macOS du" \
  || bad "GNU du failure skipped or broke the dua fallback: $GDU_DUA_FALLBACK_OUT"

DUA_ATTEMPT_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import sys
import time
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

args = SimpleNamespace(
    root="/fixture", resolve_root=False, workers=1, max_depth=6, max_nodes=10,
    wall_clock_cap=300, timeout_tiers=[10, 30, 90, 180], no_sibling_volumes=True,
    no_purgeable=True, granularity_gib=0,
)
scanner = m.FrontierScanner(args)
scanner.start_time = time.time()
with mock.patch.object(m, "DUA_CMD", "/fake/dua"), \
     mock.patch.object(m, "run_du", return_value=None) as run:
    scanner.measure_one("/fixture/slow")
print(run.call_count, run.call_args.args[1])
PY
)
[[ "$DUA_ATTEMPT_OUT" == "1 1" ]] && ok "dua gets one short capped attempt per node before subdivision" \
  || bad "dua repeated timeout tiers instead of subdividing: $DUA_ATTEMPT_OUT"

# ─────────────────────────────────────────────────────────────
section "4. Timeout-tier escalation then subdivide-on-exhaustion (not open-ended growth)"
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/dua" <<'FAKE_DUA_DISABLED'
#!/usr/bin/env bash
exit 1
FAKE_DUA_DISABLED
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
chmod +x "$FAKEBIN/dua" "$FAKEBIN/du"

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
cat > "$PARTIAL_BIN/dua" <<'PARTIAL_DUA_DISABLED'
#!/usr/bin/env bash
exit 1
PARTIAL_DUA_DISABLED
cat > "$PARTIAL_BIN/du" <<'PARTIAL_DU'
#!/usr/bin/env bash
path="${@: -1}"
printf '123\t%s\n' "$path"
echo "du: protected child: Operation not permitted" >&2
exit 1
PARTIAL_DU
chmod +x "$PARTIAL_BIN/dua" "$PARTIAL_BIN/du"

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

section "9. dua is preferred, rejects partial output, and falls back to du"
DUA_BIN="$WORK/dua_bin"
mkdir -p "$DUA_BIN"
cat > "$DUA_BIN/dua" <<'FAKE_DUA_OK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DUA_MARKER"
printf '\033[32m6291456 b\033[39m total\n'
FAKE_DUA_OK
cat > "$DUA_BIN/du" <<'FAKE_DU_MUST_NOT_RUN'
#!/usr/bin/env bash
exit 99
FAKE_DU_MUST_NOT_RUN
chmod +x "$DUA_BIN/dua" "$DUA_BIN/du"

T9_DUA="$WORK/t9_dua"
mkdir -p "$T9_DUA/large"
DUA_MARKER="$WORK/dua-ok.marker" PATH="$DUA_BIN:$PATH" \
  python3 "$SCANNER" --root "$T9_DUA" --no-sibling-volumes --no-purgeable \
  --workers 1 --wall-clock-cap 10 --timeout-tiers 1 --output "$WORK/out9_dua.json" \
  >/dev/null 2>&1

dua_kb=$(json_get "$WORK/out9_dua.json" "d['measured'].get('$T9_DUA/large', -1)")
if [[ -s "$WORK/dua-ok.marker" ]] && grep -q -- '-x' "$WORK/dua-ok.marker" &&
   [[ "$dua_kb" == "6144" ]]; then
  ok "dua is preferred and its byte total is converted to allocated KiB"
else
  bad "dua was not preferred or parsed correctly (marker=$(test -s "$WORK/dua-ok.marker" && echo yes || echo no), kb=$dua_kb)"
fi

cat > "$DUA_BIN/dua" <<'FAKE_DUA_PARTIAL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DUA_MARKER"
printf '\033[32m999999999 b\033[39m total\n'
exit 1
FAKE_DUA_PARTIAL
cat > "$DUA_BIN/du" <<'FAKE_DU_FALLBACK'
#!/usr/bin/env bash
path="${@: -1}"
printf '321\t%s\n' "$path"
FAKE_DU_FALLBACK
chmod +x "$DUA_BIN/dua" "$DUA_BIN/du"

DUA_MARKER="$WORK/dua-partial.marker" PATH="$DUA_BIN:$PATH" \
  python3 "$SCANNER" --root "$T9_DUA" --no-sibling-volumes --no-purgeable \
  --workers 1 --wall-clock-cap 10 --timeout-tiers 1 --output "$WORK/out9_fallback.json" \
  >/dev/null 2>&1
fallback_kb=$(json_get "$WORK/out9_fallback.json" "d['measured'].get('$T9_DUA/large', -1)")
if [[ -s "$WORK/dua-partial.marker" && "$fallback_kb" == "321" ]]; then
  ok "nonzero dua partial output is rejected and bounded du fallback is used"
else
  bad "dua partial output was accepted or du fallback failed (kb=$fallback_kb)"
fi

# ─────────────────────────────────────────────────────────────
section "10. --output state-file mode (atomic write, stdout stays intact, --output-default resolution)"
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
