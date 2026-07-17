#!/usr/bin/env bash
# Contract test for the default three-lane disk diagnostic.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d -t disk_audit_topdown.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "── 1. Default entrypoint and skill contract ──"
if [[ -x "$REPO_ROOT/scripts/disk_diagnostic.sh" ]] &&
   grep -q 'scripts/disk_diagnostic.sh' "$REPO_ROOT/disk_magician.sh"; then
  ok "disk-magician audit routes through the executable diagnostic orchestrator"
else
  bad "default audit does not route through scripts/disk_diagnostic.sh"
fi

SKILL="$REPO_ROOT/skills/disk-root-cause/SKILL.md"
if grep -q 'disk-magician audit' "$SKILL" &&
   grep -qi 'three.lane' "$SKILL" &&
   grep -q '5 GiB' "$SKILL" &&
   grep -qi 'dua.*du' "$SKILL" &&
   grep -qi 'residual.*not.*reclaimable' "$SKILL"; then
  ok "skill requires the three-lane >=5 GiB workflow and protects residual attribution"
else
  bad "skill is missing the default three-lane/5 GiB/residual contract"
fi
if [[ -f "$REPO_ROOT/.agents/skills/disk-root-cause/SKILL.md" ]] &&
   grep -q 'disk-magician audit' "$REPO_ROOT/skills/codex/SKILL.md" &&
   grep -q 'disk-magician audit' "$REPO_ROOT/skills/claude/SKILL.md" &&
   grep -q 'skills/disk-root-cause/SKILL.md' "$REPO_ROOT/install.sh" &&
   [[ -f "$REPO_ROOT/skills/disk-audit/SKILL.md" ]] &&
   grep -q '^name: disk-audit$' "$REPO_ROOT/skills/disk-audit/SKILL.md" &&
   grep -q '../disk-root-cause/SKILL.md' "$REPO_ROOT/skills/disk-audit/SKILL.md" &&
   grep -q 'skills/disk-audit/SKILL.md.*CLAUDE_DIR.*skills/disk-audit' "$REPO_ROOT/install.sh" &&
   grep -q 'skills/disk-audit/SKILL.md.*HOME.*agents/skills/disk-audit' "$REPO_ROOT/install.sh"; then
  ok "repo-native and installed skill surfaces route to the canonical workflow"
else
  bad "skill discovery/install surfaces still route to a stale workflow"
fi

echo
echo "── 2. Frontier report exposes finest non-overlapping >=5 GiB buckets ──"
if python3 - "$REPO_ROOT/scripts/disk_frontier_scan.py" <<'PY'
import importlib.util
import sys
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("frontier", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
gib = 1024 * 1024
root = "/fixture"
measured = {f"{root}/large/child": 6 * gib, f"{root}/large/small": 2 * gib,
            f"{root}/other/a": 1 * gib, f"{root}/other/b": 1 * gib}
measured.update({f"{root}/grouped/leaf-{i}": 1 * gib for i in range(10)})
observed = {f"{root}/large": 8 * gib, f"{root}/large/child": 6 * gib,
            f"{root}/large/small": 2 * gib, f"{root}/other": 10 * gib,
            f"{root}/other/a": 1 * gib, f"{root}/other/b": 1 * gib,
            f"{root}/grouped": 10 * gib}
scanner = SimpleNamespace(
    root=root,
    measured=measured,
    observed=observed,
    frontier_unfinished=[], deduped=[], warnings=[], nodes_processed=3,
    tracker=SimpleNamespace(peak=lambda: 2),
    level1_paths=[f"{root}/large"],
)
args = SimpleNamespace(workers=2, max_depth=6, max_nodes=50,
                       wall_clock_cap=10, timeout_tiers=[1], granularity_gib=5.0)
report = mod.build_report(
    scanner,
    {"total_kb": 30 * gib, "used_kb": 20 * gib, "free_kb": 10 * gib},
    {},
    {"purgeable_kb": 0, "purgeable_estimate_method": "fixture",
     "local_snapshots": [], "local_snapshots_count": 0},
    0.1,
    args,
    apfs_accounting={
        "physical_stores": [{"device": "disk0s2", "size_kb": 20 * gib}],
        "container_capacity_kb": 30 * gib,
        "container_free_kb": 5 * gib,
        "volumes": [
            {"name": "Data", "roles": ["Data"], "capacity_in_use_kb": 20 * gib},
            {"name": "VM", "roles": ["VM"], "capacity_in_use_kb": 4 * gib},
        ],
        "volume_allocations_kb": 24 * gib,
        "shared_allocation_kb": 1 * gib,
        "equation_balanced": True,
    },
    disk_stats_before={"total_kb": 30 * gib, "used_kb": 21 * gib, "free_kb": 9 * gib},
)
buckets = report["granularity_buckets"]
assert buckets == [
    {"path": f"{root}/grouped", "measured_kb": 10 * gib},
    {"path": f"{root}/large/child", "measured_kb": 6 * gib},
]
assert report["granularity_bucket_total_kb"] == 16 * gib
assert report["granularity_tail_kb"] == 4 * gib
assert report["accounting_equation"]["balanced"] is True
assert report["accounting_equation"]["displayed_balanced"] is True
assert report["accounting_equation"]["displayed_buckets_kb"] == 16 * gib
assert report["accounting_equation"]["sub_granularity_tail_kb"] == 4 * gib
assert report["accounting_equation"]["measurement_non_atomic"] is True
assert report["measurement_window"]["disk_used_delta_kb"] == -1 * gib
assert report["measurement_window"]["residual_interval_kb"] == {"min": 0, "max": 1 * gib}
assert report["config"]["granularity_gib"] == 5.0
assert report["apfs_accounting"]["equation_balanced"] is True
assert report["apfs_accounting"]["volumes"][0]["roles"] == ["Data"]
assert report["limits"]["sudo_used"] is False
assert report["limits"]["full_disk_access"] == "not_inferred"
assert mod.DEFAULT_MAX_NODES >= 8000
PY
then
  ok "frontier report keeps the finest >=5 GiB bucket and an exact Data equation"
else
  bad "frontier report lacks granularity buckets or exact accounting equation"
fi

echo
echo "── 3. Snapshot coverage changes cannot masquerade as physical growth ──"
HISTORY_REPO="$WORK/history-repo"
HISTORY_SNAPSHOT="$HISTORY_REPO/backup/fixture-host/disk_snapshot.json"
mkdir -p "$(dirname "$HISTORY_SNAPSHOT")"
git -C "$WORK" init -q history-repo
git -C "$HISTORY_REPO" config user.name "Disk Diagnostic Test"
git -C "$HISTORY_REPO" config user.email "disk-diagnostic-test@invalid.local"
for spec in "20 5242880 2026-07-14T12:00:00Z" "80 41943040 2026-07-15T12:00:00Z"; do
  read -r coverage measured timestamp <<<"$spec"
  python3 - "$HISTORY_SNAPSHOT" "$coverage" "$measured" "$timestamp" <<'PY'
import json, sys
path, coverage, measured, timestamp = sys.argv[1:]
json.dump({
    "timestamp": timestamp,
    "disk_total_gb": 100,
    "disk_used_gb": 50,
    "disk_free_gb": 50,
    "disk_pct": 50,
    "snapshot_coverage_pct": float(coverage),
    "snapshot_metadata": {"measurement_status": "partial", "coverage_pct": float(coverage)},
    "directories": {"fixture": int(measured)},
}, open(path, "w"))
PY
  git -C "$HISTORY_REPO" add backup/fixture-host/disk_snapshot.json
  GIT_AUTHOR_DATE="$timestamp" GIT_COMMITTER_DATE="$timestamp" \
    git -C "$HISTORY_REPO" commit -q -m "coverage $coverage"
done
HISTORY_OUT="$WORK/history.txt"
DISK_SNAPSHOT_JSON="$HISTORY_SNAPSHOT" \
  "$REPO_ROOT/scripts/disk_history.sh" --days 7 >"$HISTORY_OUT" 2>&1
if grep -q 'Physical used delta: +0.0 GiB' "$HISTORY_OUT" &&
   grep -q 'Coverage changed: +60.0 percentage points' "$HISTORY_OUT" &&
   grep -q 'do not prove physical growth' "$HISTORY_OUT" &&
   ! grep -q 'fixture:+' "$HISTORY_OUT" &&
   grep -q 'COVERAGE_CHANGE.*directory deltas incomparable' "$HISTORY_OUT"; then
  ok "physical usage remains authoritative when directory coverage changes"
else
  bad "history report conflates or omits physical-vs-coverage delta: $(tr '\n' ';' < "$HISTORY_OUT")"
fi

echo
echo "── 4. Normal diagnostic launches all three lanes concurrently ──"
TREE="$WORK/tree"
mkdir -p "$TREE/scripts" "$WORK/home"
if [[ -f "$REPO_ROOT/scripts/disk_diagnostic.sh" ]]; then
  cp "$REPO_ROOT/scripts/disk_diagnostic.sh" "$TREE/scripts/"
  chmod +x "$TREE/scripts/disk_diagnostic.sh"
fi

cat > "$TREE/scripts/disk_frontier_scan.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
time.sleep(2)
out = sys.argv[sys.argv.index("--output") + 1]
with open(os.environ["FRONTIER_ARGS_CAPTURE"], "w") as fh:
    fh.write("\n".join(sys.argv[1:]))
gib = 1024 * 1024
data = {
  "mode": "partial", "disk_total_kb": 20*gib, "disk_used_kb": 10*gib,
  "disk_free_kb": 10*gib, "measured_total_kb": 6*gib,
  "purgeable_kb": 0, "residual_kb": 4*gib,
  "granularity_buckets": [{"path": "/fixture/big", "measured_kb": 6*gib}],
  "granularity_bucket_total_kb": 6*gib, "granularity_tail_kb": 0,
  "sibling_volumes": {"VM": {"capacity_in_use_kb": 6*gib, "roles": ["VM"]}},
  "frontier_unfinished": [
    {"path": "/fixture/protected", "reason": "permission_denied_or_tcc"},
    {"path": "/fixture/slow", "reason": "time_budget_exhausted"},
    {"path": "/fixture/wide", "reason": "node_budget_exhausted"},
  ],
  "accounting_equation": {
    "balanced": True, "displayed_balanced": True,
    "displayed_buckets_kb": 6*gib, "sub_granularity_tail_kb": 0,
  },
  "apfs_accounting": {
    "physical_stores": [{"device": "disk0s2", "size_kb": 20*gib}],
    "container_capacity_kb": 20*gib, "container_free_kb": 5*gib,
    "volume_allocations_kb": 14*gib, "shared_allocation_kb": 1*gib,
    "equation_balanced": True,
    "volumes": [
      {"name": "Data", "roles": ["Data"], "capacity_in_use_kb": 10*gib},
      {"name": "VM", "roles": ["VM"], "capacity_in_use_kb": 4*gib},
    ],
  },
  "limits": {"sudo_used": False, "full_disk_access": "not_inferred"},
}
with open(out, "w") as fh:
    json.dump(data, fh)
PY
chmod +x "$TREE/scripts/disk_frontier_scan.py"

cat > "$TREE/scripts/disk_history.sh" <<'SH'
#!/usr/bin/env bash
sleep 2
echo "SNAPSHOT_DELTA_MARKER"
SH
cat > "$TREE/scripts/disk_audit.sh" <<'SH'
#!/usr/bin/env bash
sleep 2
echo "QUICK_WIN_MARKER"
SH
cat > "$TREE/scripts/worktree_hygiene.sh" <<'SH'
#!/usr/bin/env bash
[[ "$*" == *"--skip-push"* && "$*" == *"--skip-gh"* ]] || exit 9
sleep 2
echo "WORKTREE_PREVIEW_MARKER"
SH
chmod +x "$TREE/scripts/disk_history.sh" "$TREE/scripts/disk_audit.sh" \
  "$TREE/scripts/worktree_hygiene.sh"

OUT="$WORK/out.txt"
FRONTIER_ARGS_CAPTURE="$WORK/frontier-args.txt"
start=$(python3 -c 'import time; print(time.time())')
HOME="$WORK/home" FRONTIER_ARGS_CAPTURE="$FRONTIER_ARGS_CAPTURE" \
  DISK_MAGICIAN_TOPDOWN_BUDGET_SECONDS=10 \
  "$TREE/scripts/disk_diagnostic.sh" >"$OUT" 2>&1
rc=$?
elapsed=$(python3 - "$start" <<'PY'
import sys, time
print(time.time() - float(sys.argv[1]))
PY
)

if [[ "$rc" -eq 0 ]] && awk -v e="$elapsed" 'BEGIN { exit !(e < 4.8) }'; then
  ok "three 2-second lanes complete concurrently (elapsed=${elapsed}s)"
else
  bad "diagnostic was not concurrent or failed (rc=$rc elapsed=${elapsed}s)"
fi

if grep -q 'Lane 1/3.*top-down' "$OUT" &&
   grep -q 'Lane 2/3.*snapshot' "$OUT" &&
   grep -q 'Lane 3/3.*quick' "$OUT" &&
   grep -q '/fixture/big' "$OUT" &&
   grep -q '6.0 GiB' "$OUT" &&
   grep -q 'Displayed Data equation:' "$OUT" &&
   grep -q '0.0 GiB sub-5 GiB tail' "$OUT" &&
   grep -q 'Physical store disk0s2' "$OUT" &&
   grep -q 'APFS container equation: 14.0 GiB volumes + 1.0 GiB shared' "$OUT" &&
   grep -q 'sudo_used=false' "$OUT" &&
   grep -q 'full_disk_access=not_inferred' "$OUT" &&
   grep -q 'permission_denied_or_tcc' "$OUT" &&
   grep -q 'time_budget_exhausted' "$OUT" &&
   grep -q 'node_budget_exhausted' "$OUT" &&
   grep -q 'SNAPSHOT_DELTA_MARKER' "$OUT" &&
   grep -q 'QUICK_WIN_MARKER' "$OUT" &&
   grep -q 'WORKTREE_PREVIEW_MARKER' "$OUT" &&
   grep -q 'pushes and GitHub lookups disabled' "$OUT"; then
  ok "ordered report includes top-down accounting, limits, deltas, and quick wins"
else
  bad "three-lane report is incomplete: $(tr '\n' ';' < "$OUT")"
fi

if ! grep -q '^--max-nodes$' "$FRONTIER_ARGS_CAPTURE"; then
  ok "diagnostic delegates the default node budget to the scanner's single source of truth"
else
  configured=$(awk '/^--max-nodes$/{getline; print; exit}' "$FRONTIER_ARGS_CAPTURE")
  if [[ "$configured" =~ ^[0-9]+$ ]] && [[ "$configured" -ge 8000 ]]; then
    ok "diagnostic passes an empirically sufficient node budget ($configured)"
  else
    bad "diagnostic still overrides the scanner with an insufficient node budget ($configured)"
  fi
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
