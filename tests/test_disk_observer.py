#!/usr/bin/env python3
"""Behavioral contract for the bounded disk swing observer."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "disk_observer.py"


def load_module():
    spec = importlib.util.spec_from_file_location("disk_observer", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


class DiskObserverTest(unittest.TestCase):
    def test_live_runner_label_and_never_exited_status_are_truthful(self):
        observer = load_module()

        def fake_run(argv, timeout=5):
            return observer.CommandResult(
                0, "state = waiting\nruns = 0\nlast exit code = (never exited)\n", "", False
            )

        self.assertIn("org.jleechanorg.ezgha", observer.DEFAULT_LABELS)
        self.assertNotIn("com.jleechan.ezgha-runner", observer.DEFAULT_LABELS)
        job = observer.collect_launchd(["org.jleechanorg.ezgha"], fake_run)[0]
        self.assertIsNone(job["last_exit_code"])
        self.assertEqual(job["last_exit_code_raw"], "(never exited)")

    def test_collect_sample_aligns_required_signals_without_arguments_or_env(self):
        observer = load_module()
        calls = []

        def fake_run(argv, timeout=5):
            calls.append(tuple(argv))
            if argv[0] == "df":
                return observer.CommandResult(0, "Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/disk 1000 600 400 60% /\n", "", False)
            if argv[:2] == ["du", "-sk"]:
                return observer.CommandResult(0, f"25\t{argv[-1]}\n", "", False)
            if argv[:3] == ["docker", "ps", "-aq"]:
                return observer.CommandResult(0, "abc123\n", "", False)
            if argv[:3] == ["docker", "inspect", "--size"]:
                payload = [{"Id": "abc123", "Name": "/worker", "SizeRw": 4096, "State": {"Status": "running", "StartedAt": "2026-07-14T01:00:00Z", "FinishedAt": ""}}]
                return observer.CommandResult(0, json.dumps(payload), "", False)
            if argv[:2] == ["docker", "events"]:
                return observer.CommandResult(0, '{"Action":"start","Actor":{"ID":"abc123","Attributes":{"name":"worker"}},"time":100}\n', "", False)
            if argv[0] == "launchctl":
                return observer.CommandResult(0, "state = running\npid = 99\nruns = 4\nlast exit code = 0\n", "", False)
            if argv[0] == "ps":
                return observer.CommandResult(0, "99 2048 docker\n100 1024 python3\n", "", False)
            if argv[0] == "lsof":
                return observer.CommandResult(0, "p99\ncDocker\nf7\ns2097152\nl0\nn/private/tmp/growing.bin\n", "", False)
            if argv[0] == "tmutil":
                return observer.CommandResult(0, "Snapshots for volume /:\ncom.apple.TimeMachine.2026-07-14-010000.local\n", "", False)
            if argv[:2] == ["sysctl", "-n"]:
                return observer.CommandResult(0, "1000", "", False)
            return observer.CommandResult(127, "", "missing", False)

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / ".colima" / "default").mkdir(parents=True)
            (home / ".colima" / "default" / "disk").write_bytes(b"x")
            sample = observer.collect_sample(
                home=home,
                now_epoch=1060,
                events_since_epoch=1000,
                run=fake_run,
                launchd_labels=["com.example.job"],
            )

        self.assertEqual(sample["host_disk"]["available_kb"], 400)
        self.assertEqual(sample["colima"]["root_allocated_kb"], 25)
        self.assertEqual(sample["docker"]["containers"][0]["writable_bytes"], 4096)
        self.assertEqual(sample["docker"]["events"][0]["action"], "start")
        self.assertEqual(sample["launchd"][0]["state"], "running")
        self.assertEqual(sample["processes"][0]["command"], "docker")
        self.assertNotIn("arguments", sample["processes"][0])
        self.assertEqual(sample["open_unlinked_files"][0]["size_bytes"], 2097152)
        self.assertEqual(sample["time_machine"]["local_snapshot_count"], 1)
        self.assertEqual(sample["boot"]["boot_epoch"], 1000)
        self.assertTrue(any(call[:2] == ("docker", "events") for call in calls))

    def test_rotation_is_size_bounded_and_report_correlates_deltas(self):
        observer = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "samples.jsonl"
            log.write_text("x" * 101, encoding="utf-8")
            observer.rotate_if_needed(log, max_bytes=100, keep=2)
            self.assertFalse(log.exists())
            self.assertTrue(Path(str(log) + ".1").exists())

        records = [
            {
                "timestamp": "2026-07-14T01:00:00Z", "epoch": 100,
                "host_disk": {"available_kb": 1000},
                "colima": {"root_allocated_kb": 100},
                "docker": {"total_writable_bytes": 10, "events": []},
                "processes": [{"pid": 1, "rss_kb": 20, "command": "idle"}],
            },
            {
                "timestamp": "2026-07-14T01:01:00Z", "epoch": 160,
                "host_disk": {"available_kb": 700},
                "colima": {"root_allocated_kb": 350},
                "docker": {"total_writable_bytes": 210, "events": [{"action": "start", "name": "builder"}]},
                "processes": [{"pid": 2, "rss_kb": 900, "command": "docker"}],
            },
        ]
        report = observer.build_report(records, limit=5)
        swing = report["largest_host_free_space_decreases"][0]
        self.assertEqual(swing["host_available_delta_kb"], -300)
        self.assertEqual(swing["colima_allocated_delta_kb"], 250)
        self.assertEqual(swing["docker_writable_delta_bytes"], 200)
        self.assertEqual(swing["docker_events"][0]["action"], "start")
        self.assertEqual(swing["top_processes"][0]["command"], "docker")


if __name__ == "__main__":
    unittest.main()
