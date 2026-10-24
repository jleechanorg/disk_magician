#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DM="$REPO_ROOT/disk_magician.sh"
python3 - "$DM" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
command = ["bash", sys.argv[1], "frontier"]
help_result = subprocess.run(command + ["--help"], text=True, capture_output=True)
assert help_result.returncode == 0, help_result.stderr
assert "--output-default" in help_result.stdout and "--wall-clock-cap" in help_result.stdout
print("PASS: frontier command routes to the packaged scanner")
scanner_path = Path(sys.argv[1]).parent / "scripts" / "disk_frontier_scan.py"
sys.path.insert(0, str(scanner_path.parent))
import disk_frontier_scan
fixed_root = disk_frontier_scan.DEFAULT_ROOT if sys.platform == "darwin" else "/"
parsed = disk_frontier_scan.parse_args(["--root", fixed_root, "--inventory", "--root-inventory"])
assert parsed.root_inventory and parsed.root == fixed_root
for invalid in (["--root", fixed_root + "/tmp", "--inventory", "--root-inventory"],
                ["--root", fixed_root, "--root-inventory"],
                ["--root", fixed_root, "--inventory", "--root-inventory", "--output", "/tmp/out"]):
    try:
        disk_frontier_scan.parse_args(invalid)
    except SystemExit as exc:
        assert exc.code == 2
    else:
        raise AssertionError(f"root inventory accepted unsafe args: {invalid}")
print("PASS: root inventory parser pins platform scope and rejects input/output overrides")
with tempfile.TemporaryDirectory(prefix="frontier-inventory-") as temp:
    root = Path(temp) / "root"
    (root / "nested" / "small").mkdir(parents=True)
    state = Path(temp) / "state"
    env = {**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state)}
    fixed_root_store = Path("/var/lib/disk-magician")
    result = subprocess.run(command + ["--root", str(root), "--inventory", "--max-depth", "4", "--max-nodes", "100", "--wall-clock-cap", "5", "--no-sibling-volumes", "--no-purgeable"], text=True, capture_output=True, env=env)
    assert not fixed_root_store.exists(), "fixture assumes the fixed privileged aggregate store is absent"
    assert result.returncode == 2, ("inventory admission must fail closed when the fixed aggregate is unavailable; " f"exit={result.returncode}, stderr={result.stderr!r}")
    report = json.loads(result.stdout)
    assert report["inventory"]["status"] == "report_only", report["inventory"]
    assert report["inventory"]["admission_allowed"] is False, report["inventory"]
    assert report["inventory"]["published"] is False, report["inventory"]
    assert report["inventory"]["reason"] == "aggregate_unavailable", report["inventory"]
    assert not (state / "inventory" / "current.json").exists()
    assert not list((state / "inventory").glob("**/*")) if (state / "inventory").exists() else True
    print("PASS: frontier --inventory reports admission_blocked and publishes nothing when fixed aggregate stores are unavailable")

with tempfile.TemporaryDirectory(prefix="frontier-fanout-") as temp:
    root = Path(temp) / "root"
    root.mkdir()
    for index in range(30):
        (root / f"child-{index:02d}").mkdir()
    state = Path(temp) / "state"
    env = {**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state)}
    result = subprocess.run(command + ["--root", str(root), "--inventory", "--max-depth", "4", "--max-nodes", "2", "--wall-clock-cap", "5", "--no-sibling-volumes", "--no-purgeable"], text=True, capture_output=True, env=env)
    assert result.returncode == 2, result.stderr
    report = json.loads(result.stdout)
    inventory = report["inventory"]
    assert inventory["scan_coverage_complete"] is False, inventory
    assert inventory["unresolved_frontier"], inventory
    assert any(item["reason"] == "inventory_child_entry_limit_exceeded" for item in inventory["unresolved_frontier"]), inventory
    assert inventory["discovery_entry_count"] <= 2, inventory
    assert inventory["discovered_directory_count"] <= 3, inventory
    assert not (state / "inventory" / "current.json").exists()
    legacy = subprocess.run(command + ["--root", str(root), "--max-depth", "4", "--max-nodes", "2", "--wall-clock-cap", "5", "--no-sibling-volumes", "--no-purgeable"], text=True, capture_output=True)
    assert legacy.returncode == 0, legacy.stderr
    assert "inventory" not in json.loads(legacy.stdout), legacy.stdout
    print("PASS: inventory fanout is bounded and partial; legacy frontier behavior is unchanged")

PY
