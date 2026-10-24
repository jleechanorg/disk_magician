import json
import os
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]


def test_all_json_exports_full_typed_inventory_and_cleanup_rows(tmp_path):
    state_repo = tmp_path / "state-repo"
    state_repo.mkdir()
    (state_repo / "config").mkdir()
    (state_repo / "config" / "config.json").write_text(json.dumps({
        "monitored_dirs": [{"key": "watched", "path": "/fixture/watched"}],
        "monitored_globs": [{"key": "logs", "pattern": "/fixture/*.log"}],
    }))
    inventory_state = tmp_path / "state"
    inventory_state.mkdir()
    sys.path.insert(0, str(REPO / "scripts"))
    import directory_inventory

    records = [
        {"filesystem_id": "fs-a", "canonical_path": f"/fixture/tree/{n:05d}",
         "row_type": "directory", "observation": {"allocated_bytes": n, "apparent_bytes": n,
         "measurement_status": "measured", "subtree_coverage_status": "complete"}}
        for n in range(75)
    ]
    records.extend([
        {"filesystem_id": "fs-a", "canonical_path": "/fixture/unknown-new-child",
         "row_type": "directory", "observation": {"allocated_bytes": None, "apparent_bytes": None,
         "measurement_status": "unobserved", "subtree_coverage_status": "unknown"}},
        {"filesystem_id": "fs-a", "canonical_path": "/fixture/old-only",
         "row_type": "directory", "history_status": "historical-only",
         "observation": {"allocated_bytes": None, "apparent_bytes": None,
         "measurement_status": "retention-expired", "subtree_coverage_status": "unknown"}},
        {"filesystem_id": "fs-a", "canonical_path": "/fixture/one.log",
         "row_type": "file_pattern", "pattern": "/fixture/*.log"},
    ])
    directory_inventory.publish_inventory(records, state_dir=inventory_state,
                                          git_state_repo=state_repo, complete=False,
                                          unresolved_frontier=["/fixture"])
    deletions = tmp_path / "deletions.log"
    deletions.write_text("2026-10-23T01:00:00Z\tcleanup_tmp.sh\tremove\t-1\t/fixture/cleanup-root/exact-child\n")
    env = {k: v for k, v in os.environ.items()
           if k not in ("DISK_MAGICIAN_CONFIG", "DISK_MAGICIAN_STATE_REPO", "XDG_CONFIG_HOME")}
    xdg = tmp_path / "xdg"
    xdg.mkdir()
    env.update(DISK_MAGICIAN_STATE_DIR=str(inventory_state),
               DISK_MAGICIAN_STATE_REPO=str(state_repo),
               XDG_CONFIG_HOME=str(xdg),
               DISK_MAGICIAN_DELETION_LOG=str(deletions))
    result = subprocess.run([
        sys.executable, str(REPO / "scripts" / "reclaim_ledger.py"),
        "--state-dir", str(state_repo), "--frontier", str(tmp_path / "missing.json"),
        "--freshness-line", "OK test", "--now", "2026-10-24T00:00:00Z",
        "--stdout", "--all", "--json",
    ], env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    exported = json.loads(result.stdout)
    rows = exported["rows"]
    assert len(rows) == len(records) + 4
    assert sum(row["row_type"] == "directory" for row in rows) == 78
    assert sum(row["row_type"] in ("file_pattern", "pattern") for row in rows) == 2
    assert any(row["canonical_path"] == "/fixture/old-only" and
               row["history_status"] == "historical-only" for row in rows)
    assert any(row["canonical_path"] == "/fixture/unknown-new-child" and
               row["observation"]["allocated_bytes"] is None for row in rows)
    assert any(row["canonical_path"] == "/fixture/cleanup-root/exact-child" and
               row["row_type"] == "cleanup_event" for row in rows)
    assert exported["counts"]["directories"] == 78
    assert exported["counts"]["file_patterns"] == 2
    assert exported["counts"]["total_rows"] == len(rows)
    assert exported["counts"]["cleanup_roots"] == 1
    assert exported["counts"]["cleanup_events"] == 1
    assert exported["inventory"]["complete"] is False
    assert exported["inventory"]["unresolved_frontier"] == ["/fixture"]


def test_default_markdown_reports_bounded_attention_and_total_counts(tmp_path):
    # More than the historical top-30 must stay available in JSON while the
    # human report says how many rows it displayed and how many exist in total.
    state_repo = tmp_path / "state-repo"
    state_repo.mkdir()
    (state_repo / "config").mkdir()
    (state_repo / "config" / "config.json").write_text('{\"monitored_dirs\":[]}')
    inventory_state = tmp_path / "state"
    inventory_state.mkdir()
    sys.path.insert(0, str(REPO / "scripts"))
    import directory_inventory
    records = [{"canonical_path": f"/fixture/d{i:03d}", "row_type": "directory",
                "observation": {"allocated_bytes": i, "apparent_bytes": i}}
               for i in range(40)]
    directory_inventory.publish_inventory(records, state_dir=inventory_state,
                                          git_state_repo=state_repo, complete=True)
    xdg = tmp_path / "xdg"
    xdg.mkdir()
    env = {k: v for k, v in os.environ.items()
           if k not in ("DISK_MAGICIAN_CONFIG", "DISK_MAGICIAN_STATE_REPO", "XDG_CONFIG_HOME")}
    env.update(DISK_MAGICIAN_STATE_DIR=str(inventory_state),
               DISK_MAGICIAN_STATE_REPO=str(state_repo), XDG_CONFIG_HOME=str(xdg))
    result = subprocess.run([sys.executable, str(REPO / "scripts" / "reclaim_ledger.py"),
                             "--state-dir", str(state_repo), "--stdout", "--now",
                             "2026-10-24T00:00:00Z"], env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert "Directory inventory: 40 total" in result.stdout
    assert "displayed 30" in result.stdout


def test_normal_regeneration_publishes_machine_readable_sidecar(tmp_path):
    state_repo = tmp_path / "state-repo"
    state_repo.mkdir()
    (state_repo / "config").mkdir()
    (state_repo / "config" / "config.json").write_text('{"monitored_dirs":[]}')
    xdg = tmp_path / "xdg"
    xdg.mkdir()
    env = {k: v for k, v in os.environ.items()
           if k not in ("DISK_MAGICIAN_CONFIG", "DISK_MAGICIAN_STATE_REPO", "XDG_CONFIG_HOME")}
    env.update(DISK_MAGICIAN_STATE_REPO=str(state_repo), XDG_CONFIG_HOME=str(xdg),
               DISK_MAGICIAN_DELETION_LOG=str(tmp_path / "missing.log"))
    result = subprocess.run([sys.executable, str(REPO / "scripts" / "reclaim_ledger.py"),
                             "--state-dir", str(state_repo), "--now",
                             "2026-10-24T00:00:00Z", "--freshness-line", "OK test"],
                            env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    sidecar = state_repo / "reclaim" / "directory-ledger.json"
    markdown = state_repo / "reclaim" / "known-reclaim-dirs.md"
    exported = json.loads(sidecar.read_text())
    assert exported["counts"]["total_rows"] == len(exported["rows"])
    assert "directory-ledger.json" in markdown.read_text()


def test_all_json_keeps_more_than_8047_directory_rows(tmp_path):
    state_repo = tmp_path / "state-repo"
    state_repo.mkdir()
    (state_repo / "config").mkdir()
    (state_repo / "config" / "config.json").write_text('{"monitored_dirs":[]}')
    inventory_state = tmp_path / "state"
    inventory_state.mkdir()
    sys.path.insert(0, str(REPO / "scripts"))
    import directory_inventory
    records = [{"canonical_path": f"/fixture/dir-{i:05d}", "row_type": "directory",
                "observation": {"allocated_bytes": None, "apparent_bytes": None,
                                "measurement_status": "unknown"}}
               for i in range(8048)]
    directory_inventory.publish_inventory(records, state_dir=inventory_state, complete=False)
    xdg = tmp_path / "xdg"
    xdg.mkdir()
    env = {k: v for k, v in os.environ.items()
           if k not in ("DISK_MAGICIAN_CONFIG", "DISK_MAGICIAN_STATE_REPO", "XDG_CONFIG_HOME")}
    env.update(DISK_MAGICIAN_STATE_DIR=str(inventory_state),
               DISK_MAGICIAN_STATE_REPO=str(state_repo), XDG_CONFIG_HOME=str(xdg),
               DISK_MAGICIAN_DELETION_LOG=str(tmp_path / "missing.log"))
    result = subprocess.run([sys.executable, str(REPO / "scripts" / "reclaim_ledger.py"),
                             "--state-dir", str(state_repo), "--all", "--json", "--now",
                             "2026-10-24T00:00:00Z"], env=env, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    exported = json.loads(result.stdout)
    assert exported["counts"]["directories"] == 8048
    assert exported["counts"]["total_rows"] == 8048
    assert len(exported["rows"]) == 8048
