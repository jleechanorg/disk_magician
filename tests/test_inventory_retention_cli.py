"""Retention uses the shared public dispatcher and defaults to preview."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from directory_inventory import publish_inventory


def test_retention_preview_and_apply_through_diskm(tmp_path):
    state = tmp_path / "state"
    old = publish_inventory([{"canonical_path": "/old"}], state_dir=state,
                            now="2026-01-01T00:00:00Z")
    publish_inventory([{"canonical_path": "/current"}], state_dir=state)
    dependency = state / "inventory" / "objects" / (
        old["manifest"]["measurement_manifest_sha256"] + ".jsonl.gz")
    home = tmp_path / "home"
    home.mkdir()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(home),
           "DISK_MAGICIAN_STATE_DIR": str(state)}
    command = ["bash", str(ROOT / "disk_magician.sh"), "state", "inventory-retain", "--json"]
    preview = subprocess.run(command, env=env, capture_output=True, text=True)
    assert preview.returncode == 0, preview.stderr
    json.loads(preview.stdout)
    assert dependency.exists(), "preview must not delete expired objects"
    cleaned = subprocess.run(command + ["--apply"], env=env,
                             capture_output=True, text=True)
    assert cleaned.returncode == 0, cleaned.stderr
    json.loads(cleaned.stdout)
    assert not dependency.exists()
