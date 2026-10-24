import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import reclaim_ledger


class HistoricalSnapshotLineageTest(unittest.TestCase):
    def test_each_qualified_snapshot_is_an_immutable_timestamped_measurement(self):
        with tempfile.TemporaryDirectory(prefix="history_import_lineage_") as td:
            root = pathlib.Path(td)
            snapshots = []
            for name, stamp, size in (("old.json", "2026-10-20T00:00:00Z", 10),
                                      ("new.json", "2026-10-21T00:00:00Z", 30)):
                data = json.dumps({"directories": {"/fixture/repeated": size}}).encode()
                (root / name).write_bytes(data)
                snapshots.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(),
                                  "captured_at": stamp, "coverage_pct": 85})
            (root / "bundle.json").write_text(json.dumps({"schema_version": 1, "snapshots": snapshots}))
            imported = reclaim_ledger.parse_history_bundle(root)
            observations = [r for r in imported["rows"] if r.get("row_type") == "historical_measurement"]
            self.assertEqual(len(observations), 2)
            self.assertEqual({r["source_timestamp"] for r in observations}, {"2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z"})
            self.assertEqual({r["observation"]["allocated_bytes"] for r in observations}, {10 * 1024, 30 * 1024})
            self.assertEqual(len({r["import_row_key"] for r in observations}), 2)


def segment(root, name, text):
    data = text.encode()
    (root / name).write_bytes(data)
    return {"path": name, "sha256": hashlib.sha256(data).hexdigest(),
            "host": "jeff-ubuntu", "source_kind": "deletion_log",
            "lineage_id": "deletions-2026-10-20-part-a", "lineage_status": "verified"}


def test_import_parser_preserves_occurrences_and_dedupes_verified_segment_copies(tmp_path):
    text = ("2026-10-20T01:00:00Z\tcleanup_tmp.sh\tremove\t10\t/tmp/same\n"
            "2026-10-20T01:00:00Z\tcleanup_tmp.sh\tremove\t10\t/tmp/same\n")
    first = segment(tmp_path, "events.log", text)
    copied = dict(first, path="events-copy.log")
    (tmp_path / copied["path"]).write_text(text)
    (tmp_path / "bundle.json").write_text(json.dumps({"schema_version": 1,
        "sources": [first, copied]}))
    parsed = reclaim_ledger.parse_history_bundle(tmp_path)
    assert parsed["counts"]["verified_segments"] == 1
    assert parsed["counts"]["exact_events"] == 2
    rows = parsed["rows"]
    assert [row["occurrence_index"] for row in rows] == [1, 2]
    assert len({row["event_id"] for row in rows}) == 2
    assert all(row["row_type"] == "cleanup_event" for row in rows)


def test_import_parser_keeps_uncertain_rows_out_of_exact_totals_and_leads_unsized(tmp_path):
    text = "2026-10-20T01:00:00Z\tcleanup_tmp.sh\tremove\t20\t/tmp/ambiguous\n"
    src = segment(tmp_path, "copy.log", text)
    src["lineage_id"] = None
    src["lineage_status"] = "unresolved"
    leads = [{"path": f"/known/lead-{i:03d}", "source": "audit-2026-10-18",
              "source_ref": f"record-{i}"} for i in range(106)]
    (tmp_path / "leads.json").write_text(json.dumps(leads))
    (tmp_path / "bundle.json").write_text(json.dumps({"schema_version": 1,
        "sources": [src], "path_leads": "leads.json", "summaries": [
            {"source": "collapsed-report", "event_count": 91, "status": "rolling-summary"}]}))
    parsed = reclaim_ledger.parse_history_bundle(tmp_path)
    assert parsed["counts"]["exact_events"] == 0
    assert parsed["counts"]["uncertain_events"] == 1
    assert parsed["counts"]["path_leads"] == 106
    assert parsed["counts"]["summary_rows"] == 1
    ambiguous = next(row for row in parsed["rows"] if row["row_type"] == "cleanup_event")
    assert ambiguous["event_id"] is None
    assert ambiguous["event_status"] == "uncertain_lineage"
    lead = next(row for row in parsed["rows"] if row["row_type"] == "directory")
    assert lead["history_status"] == "historical-lead"
    assert lead["observation"]["allocated_bytes"] is None
    assert lead["observation"]["measurement_status"] == "lead_only"
    assert not any("hidden" in (row.get("canonical_path") or "") for row in parsed["rows"])


def test_import_cli_rejects_corrupt_source_hash_without_publication(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    src = segment(tmp_path, "events.log", "2026-10-20T01:00:00Z\tcleanup\tremove\t1\t/tmp/x\n")
    src["sha256"] = "0" * 64
    (tmp_path / "bundle.json").write_text(json.dumps({"schema_version": 1, "sources": [src]}))
    (tmp_path / "xdg").mkdir()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path / "home"),
           "XDG_CONFIG_HOME": str(tmp_path / "xdg"), "DISK_MAGICIAN_STATE_DIR": str(state),
           "DISK_MAGICIAN_DELETION_LOG": str(tmp_path / "missing.log")}
    result = subprocess.run([sys.executable, str(REPO / "scripts/reclaim_ledger.py"),
                             "--state-dir", str(tmp_path), "--import-history",
                             "--source-dir", str(tmp_path), "--now", "2026-10-24T00:00:00Z"],
                            env=env, text=True, capture_output=True)
    assert result.returncode != 0
    assert "hash" in result.stderr.lower()
    assert not (state / "inventory/current.json").exists()


def test_import_distinguishes_lineages_and_only_keeps_qualified_snapshots(tmp_path):
    content = "2026-10-20T01:00:00Z\tcleanup\tremove\t2\t/tmp/x\n"
    first = segment(tmp_path, "a.log", content)
    second = dict(first, path="b.log", lineage_id="different-verified-lineage")
    (tmp_path / "b.log").write_text(content)
    snap = {"directories": {"/fixture/measured": 2048}}
    snap_bytes = json.dumps(snap).encode()
    (tmp_path / "snap.json").write_bytes(snap_bytes)
    snapshots = [{"path": "snap.json", "sha256": hashlib.sha256(snap_bytes).hexdigest(),
                  "captured_at": "2026-10-20T00:00:00Z", "coverage_pct": 85},
                 {"path": "snap.json", "sha256": hashlib.sha256(snap_bytes).hexdigest(),
                  "captured_at": "2026-10-19T00:00:00Z", "coverage_pct": 69}]
    (tmp_path / "bundle.json").write_text(json.dumps({"schema_version": 1,
        "sources": [first, second], "snapshots": snapshots}))
    parsed = reclaim_ledger.parse_history_bundle(tmp_path)
    assert parsed["counts"]["exact_events"] == 2
    assert len({row["event_id"] for row in parsed["rows"] if row["row_type"] == "cleanup_event"}) == 2
    measured = [row for row in parsed["rows"] if row.get("history_status") == "historical-snapshot"]
    assert len(measured) == 1
    assert measured[0]["observation"]["allocated_bytes"] == 2048 * 1024


def test_import_cli_publishes_union_and_exports_lineage_events(tmp_path, monkeypatch):
    state = tmp_path / "state"
    state.mkdir()
    content = "2026-10-20T01:00:00Z\tcleanup\tremove\t3\t/tmp/imported\n"
    src = segment(tmp_path, "events.log", content)
    leads = [{"path": "/fixture/imported-dir", "source": "old-snapshot"}]
    (tmp_path / "leads.json").write_text(json.dumps(leads))
    (tmp_path / "bundle.json").write_text(json.dumps({"schema_version": 1,
        "sources": [src], "path_leads": "leads.json"}))
    xdg = tmp_path / "xdg"
    xdg.mkdir()
    env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path / "home"),
           "XDG_CONFIG_HOME": str(xdg), "DISK_MAGICIAN_STATE_DIR": str(state),
           "DISK_MAGICIAN_DELETION_LOG": str(tmp_path / "missing.log")}
    command = [sys.executable, str(REPO / "scripts/reclaim_ledger.py"),
               "--state-dir", str(tmp_path), "--import-history", "--source-dir", str(tmp_path)]
    first = subprocess.run(command, env=env, text=True, capture_output=True)
    assert first.returncode == 0, first.stderr
    second = subprocess.run(command, env=env, text=True, capture_output=True)
    assert second.returncode == 0, second.stderr
    current = reclaim_ledger.directory_inventory.read_current(state)
    events = current["manifest"]["scan_metadata"]["provenance"]["historical_events"]
    assert len(events) == 1
    assert events[0]["event_id"]
    assert any(row["canonical_path"] == "/fixture/imported-dir" for row in current["records"])
    monkeypatch.setenv("DISK_MAGICIAN_STATE_DIR", str(state))
    exported = reclaim_ledger.ledger_json(type("Args", (), {
        "days": 365, "home": str(tmp_path), "deletions_log": str(tmp_path / "missing.log")
    })(), tmp_path, reclaim_ledger.datetime.datetime.fromisoformat("2026-10-24T00:00:00+00:00"))
    assert any(row.get("event_id") == events[0]["event_id"] for row in exported["rows"])
    assert exported["counts"]["exact_cleanup_events"] == 1


def test_qualified_snapshot_import_preserves_each_timestamped_path_observation(tmp_path):
    state = tmp_path / "state"
    state.mkdir()
    snapshot_rows = []
    snapshots = []
    for name, stamp, size in (("old.json", "2026-10-20T00:00:00Z", 10),
                              ("new.json", "2026-10-21T00:00:00Z", 30)):
        data = json.dumps({"directories": {"/fixture/repeated": size}}).encode()
        (tmp_path / name).write_bytes(data)
        snapshots.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(),
                          "captured_at": stamp, "coverage_pct": 85})
    (tmp_path / "bundle.json").write_text(json.dumps({"schema_version": 1, "snapshots": snapshots}))
    imported = reclaim_ledger.parse_history_bundle(tmp_path)
    observations = [row for row in imported["rows"] if row.get("row_type") == "historical_measurement"]
    assert len(observations) == 2
    assert len({row["import_row_key"] for row in observations}) == 2
    assert {row["source_timestamp"] for row in observations} == {"2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z"}
    assert {row["observation"]["allocated_bytes"] for row in observations} == {10 * 1024, 30 * 1024}
