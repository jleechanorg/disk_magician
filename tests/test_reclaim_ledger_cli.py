import json
import os
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]


def test_all_json_cli_exports_every_inventory_row(tmp_path):
    state = tmp_path / "state"
    repo = tmp_path / "repo"
    state.mkdir()
    repo.mkdir()
    (repo / "config").mkdir()
    (repo / "config" / "config.json").write_text('{"monitored_dirs":[]}')
    sys.path.insert(0, str(REPO / "scripts"))
    import directory_inventory
    directory_inventory.publish_inventory([
        {"canonical_path": f"/all/item-{i}", "row_type": "directory",
         "observation": {"allocated_bytes": None, "apparent_bytes": None}}
        for i in range(33)], state_dir=state, complete=False)
    xdg = tmp_path / "xdg"
    xdg.mkdir()
    env = {k: v for k, v in os.environ.items()
           if k not in ("DISK_MAGICIAN_CONFIG", "DISK_MAGICIAN_STATE_REPO", "XDG_CONFIG_HOME")}
    env.update(DISK_MAGICIAN_STATE_DIR=str(state), DISK_MAGICIAN_STATE_REPO=str(repo),
               DISK_MAGICIAN_DELETION_LOG=str(tmp_path / "missing.log"), XDG_CONFIG_HOME=str(xdg))
    result = subprocess.run([sys.executable, str(REPO / "scripts" / "reclaim_ledger.py"),
                             "--state-dir", str(repo), "--all", "--json", "--stdout"],
                            env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    output = json.loads(result.stdout)
    assert output["counts"]["directories"] == 33
    assert output["counts"]["total_rows"] == 33
