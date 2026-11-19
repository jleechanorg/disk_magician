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


def _make_valid_canonical_ledger(captured_at: str) -> dict:
    probes = {
        "mobile_sync": "/Users/reviewer/Library/Application Support/MobileSync/Backup",
        "mail": "/Users/reviewer/Library/Mail",
        "messages": "/Users/reviewer/Library/Messages",
    }
    return {
        "schema_version": 2,
        "mode": "complete",
        "scope": {"hostname": "testhost", "root": "/Users/reviewer"},
        "hostname": "testhost",
        "root": "/Users/reviewer",
        "captured_at": captured_at,
        "run_id": "run-1",
        "run_started_at": 100.0,
        "run_finished_at": 102.0,
        "coverage_envelope": {
            "complete": True,
            "status": "complete",
            "fda_preflight_status": "granted",
            "fda_user_preflight_status": "granted",
            "reachable_top_level_roots": 1,
            "measured_top_level_roots": 1,
            "unfinished_top_level_roots": 0,
        },
        "fda_probe_paths": dict(probes),
        "fda_preflight": {
            "status": "granted",
            "probes": {name: {"path": p, "status": "readable"} for name, p in probes.items()},
        },
        "disk_used_kb": 10000000,
        "residual_kb": 1000000,
        "purgeable_kb": 0,
        "granularity_buckets": [{"path": "/Users/reviewer/a", "measured_kb": 4000000, "kind": "file"}],
        "oversize_indivisible_files": [],
        "frontier_unfinished": [],
        "opaque_intrinsic_gates": [],
        "accounting_equation": {
            "displayed_balanced": True,
            "display_ledger_valid": True,
            "data_used_kb": 10000000,
            "displayed_buckets_kb": 4000000,
            "oversize_indivisible_files_kb": 0,
            "sub_granularity_tail_kb": 5000000,
            "purgeable_kb": 0,
            "residual_kb": 1000000,
            "clone_shared_adjustment_kb": 0,
        },
    }


def _extract_section(markdown: str, label: str) -> str:
    import re
    m = re.search(rf"^### {re.escape(label)}\. [^\n]+\n(.*?)(?=^### |<!-- diskm|\Z)", markdown, re.M | re.S)
    assert m, f"Missing section {label} in:\n{markdown}"
    return m.group(1)


def test_b1_refuses_floor_when_newest_committed_ledger_stale_and_agrees_with_growth_top10(tmp_path):
    import datetime
    home = tmp_path / "home"
    home.mkdir()
    state_repo = tmp_path / "state"
    state_repo.mkdir()
    (state_repo / "config").mkdir()
    (state_repo / "snapshots").mkdir()
    (state_repo / "ledger").mkdir()
    subprocess.run(["git", "-C", str(state_repo), "init", "-q"], check=True)
    (state_repo / "config" / "config.json").write_text(
        json.dumps({"monitored_dirs": [{"key": "adir", "path": "~/a", "timeout": 60}]}),
        encoding="utf-8",
    )

    now = datetime.datetime.now(datetime.timezone.utc)
    stale_dt = now - datetime.timedelta(days=10)
    snap1_dt = now - datetime.timedelta(hours=30)
    snap2_dt = now - datetime.timedelta(hours=2)
    stale_iso = stale_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    snap1_iso = snap1_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    snap2_iso = snap2_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    def git_commit(rel_path: str, payload: dict, when_iso: str):
        (state_repo / rel_path).write_text(json.dumps(payload), encoding="utf-8")
        subprocess.run(["git", "-C", str(state_repo), "add", rel_path], check=True)
        env = dict(os.environ, GIT_AUTHOR_DATE=when_iso, GIT_COMMITTER_DATE=when_iso)
        subprocess.run(
            ["git", "-C", str(state_repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", rel_path],
            env=env,
            check=True,
        )

    git_commit("ledger/topdown-5g.json", _make_valid_canonical_ledger(stale_iso), stale_iso)
    gib_kb = 1024 * 1024
    git_commit("snapshots/disk_snapshot.json", {"snapshot_coverage_pct": 95, "directories": {"adir": 1 * gib_kb}, "carried_keys": []}, snap1_iso)
    git_commit("snapshots/disk_snapshot.json", {"snapshot_coverage_pct": 95, "directories": {"adir": 5 * gib_kb}, "carried_keys": []}, snap2_iso)

    xdg = tmp_path / "xdg"
    xdg.mkdir()
    env = {k: v for k, v in os.environ.items()
           if k not in ("DISK_MAGICIAN_CONFIG", "DISK_MAGICIAN_STATE_REPO", "XDG_CONFIG_HOME")}
    env.update(
        HOME=str(home),
        DISK_MAGICIAN_STATE_REPO=str(state_repo),
        DISK_MAGICIAN_DELETION_LOG=str(tmp_path / "missing.log"),
        XDG_CONFIG_HOME=str(xdg),
    )

    g10 = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "growth_top10.py"), "--days", "7", "--state-dir", str(state_repo), "--json"],
        env=env, text=True, capture_output=True,
    )
    assert g10.returncode == 2, g10.stderr
    assert json.loads(g10.stdout)["comparison_kind"] == "no_floor"

    rl = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "reclaim_ledger.py"),
         "--state-dir", str(state_repo), "--frontier", str(tmp_path / "missing-frontier.json"),
         "--stdout", "--no-sync-config"],
        env=env, text=True, capture_output=True,
    )
    assert rl.returncode == 0, rl.stderr
    b1 = _extract_section(rl.stdout, "B1")
    b2 = _extract_section(rl.stdout, "B2")
    assert "Unavailable:" in b1, b1
    assert "Unavailable:" in b2, b2
    assert "| `adir` |" not in b1, b1

    # Even with a fresh partial ledger, canonical_publication=stale must refuse B1 floor.
    rl_partial = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "reclaim_ledger.py"),
         "--state-dir", str(state_repo), "--frontier", str(tmp_path / "missing-frontier.json"),
         "--freshness-line", "OK\tpublished_age_hours=240\tstatus=partial\treason=coverage_incomplete\tlabel=PARTIAL\tcanonical_publication=stale",
         "--stdout", "--no-sync-config"],
        env=env, text=True, capture_output=True,
    )
    assert rl_partial.returncode == 0, rl_partial.stderr
    b1_partial = _extract_section(rl_partial.stdout, "B1")
    assert "Unavailable:" in b1_partial, b1_partial
    assert "| `adir` |" not in b1_partial, b1_partial

    # When canonical ledger is fresh (<= 48h), B1 prints the monitored directory floor.
    fresh_iso = (now - datetime.timedelta(hours=12)).strftime("%Y-%m-%dT%H:%M:%SZ")
    git_commit("ledger/topdown-5g.json", _make_valid_canonical_ledger(fresh_iso), fresh_iso)
    rl_fresh = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "reclaim_ledger.py"),
         "--state-dir", str(state_repo), "--frontier", str(tmp_path / "missing-frontier.json"),
         "--stdout", "--no-sync-config"],
        env=env, text=True, capture_output=True,
    )
    assert rl_fresh.returncode == 0, rl_fresh.stderr
    b1_fresh = _extract_section(rl_fresh.stdout, "B1")
    assert "| `adir` |" in b1_fresh, b1_fresh
