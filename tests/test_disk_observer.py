#!/usr/bin/env python3
"""Behavioral contract for the bounded disk swing observer."""

import importlib.util
import json
import os
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "disk_observer.py"


def load_module():
    spec = importlib.util.spec_from_file_location("disk_observer", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


class DiskObserverTest(unittest.TestCase):
    def test_docker_commands_use_live_colima_socket(self):
        observer = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            socket_path = home / ".colima" / "default" / "docker.sock"
            socket_path.parent.mkdir(parents=True)
            server = socket.socket(socket.AF_UNIX)
            server.bind(str(socket_path))
            try:
                completed = subprocess.CompletedProcess(["docker", "ps"], 0, "", "")
                with mock.patch.object(observer.Path, "home", return_value=home), mock.patch.object(
                    observer.subprocess, "run", return_value=completed
                ) as run:
                    observer.run_command(["docker", "ps"])
            finally:
                server.close()

        env = run.call_args.kwargs.get("env", {})
        self.assertEqual(env.get("DOCKER_HOST"), f"unix://{socket_path}")

    def test_observer_launchd_declares_colima_docker_host(self):
        template = ROOT / "launchd" / "com.jleechanorg.disk-magician-observer.plist.template"
        text = template.read_text(encoding="utf-8")
        self.assertIn("<key>DOCKER_HOST</key>", text)
        self.assertIn("unix://@HOME@/.colima/default/docker.sock", text)

    def test_frontier_launchd_requests_five_gib_buckets(self):
        relative = Path(
            "launchd/com.jleechanorg.disk-magician-frontier-nightly.plist.template"
        )
        for template in (ROOT / relative, ROOT / "src" / "disk_magician" / relative):
            text = template.read_text(encoding="utf-8")
            self.assertIn(
                "<string>--granularity-gib</string>\n    <string>5</string>",
                text,
                str(template),
            )

    def test_swap_sample_parses_bytes_and_surfaces_failure(self):
        observer = load_module()
        self.assertTrue(hasattr(observer, "collect_swap"), "swap collector is missing")

        def success_run(argv, timeout=3):
            return observer.CommandResult(
                0, "total = 4096.00M  used = 1536.50M  free = 2559.50M  (encrypted)\n", "", False
            )

        swap = observer.collect_swap(success_run)
        self.assertEqual(swap["total_bytes"], 4096 * 1024 * 1024)
        self.assertEqual(swap["used_bytes"], int(1536.5 * 1024 * 1024))
        self.assertEqual(swap["free_bytes"], int(2559.5 * 1024 * 1024))
        self.assertIsNone(swap["error"])

        def failure_run(argv, timeout=3):
            return observer.CommandResult(1, "", "unsupported", False)

        failed = observer.collect_swap(failure_run)
        self.assertEqual(failed["error"], "exit_1")
        self.assertIsNone(failed["total_bytes"])
        self.assertIsNone(failed["used_bytes"])
        self.assertIsNone(failed["free_bytes"])

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
            if argv[:3] == ["sysctl", "-n", "vm.swapusage"]:
                return observer.CommandResult(0, "total = 2.00G used = 512.00M free = 1.50G", "", False)
            if argv[:2] == ["sysctl", "-n"]:
                return observer.CommandResult(0, "1000", "", False)
            return observer.CommandResult(127, "", "missing", False)

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            (home / ".colima" / "default").mkdir(parents=True)
            (home / ".colima" / "default" / "disk").write_bytes(b"x")
            deep_disk = home / ".colima" / "_lima" / "colima" / "diffdisk"
            deep_disk.parent.mkdir(parents=True)
            deep_disk.write_bytes(b"y")
            sample = observer.collect_sample(
                home=home,
                now_epoch=1060,
                events_since_epoch=1000,
                run=fake_run,
                launchd_labels=["com.example.job"],
            )

        self.assertEqual(sample["host_disk"]["available_kb"], 400)
        self.assertEqual(sample["colima"]["root_allocated_kb"], 25)
        self.assertIn(str(deep_disk), {item["path"] for item in sample["colima"]["datadisks"]})
        self.assertEqual(sample["docker"]["containers"][0]["writable_bytes"], 4096)
        self.assertEqual(sample["docker"]["events"][0]["action"], "start")
        self.assertEqual(sample["launchd"][0]["state"], "running")
        self.assertEqual(sample["processes"][0]["command"], "docker")
        self.assertNotIn("arguments", sample["processes"][0])
        self.assertEqual(sample["open_unlinked_files"][0]["size_bytes"], 2097152)
        self.assertEqual(sample["time_machine"]["local_snapshot_count"], 1)
        self.assertEqual(sample["boot"]["boot_epoch"], 1000)
        self.assertIn("swap", sample)
        self.assertEqual(sample["swap"]["used_bytes"], 512 * 1024 * 1024)
        self.assertTrue(any(call[:2] == ("docker", "events") for call in calls))

    def test_step_event_not_triggered_below_threshold(self):
        observer = load_module()
        threshold_kb = 10 * 1024 * 1024  # 10 GiB
        history = [(0, 500_000_000)]
        # +9 GiB over 10 minutes: below the 10 GiB threshold.
        event = observer.check_step_event(
            history, now_epoch=600, used_kb=500_000_000 + 9 * 1024 * 1024,
            window_seconds=1800, threshold_kb=threshold_kb,
        )
        self.assertIsNone(event)
        # The sample is still recorded in history for future window checks.
        self.assertEqual(history[-1], (600, 500_000_000 + 9 * 1024 * 1024))

    def test_step_event_triggered_above_threshold_with_expected_fields(self):
        observer = load_module()
        threshold_kb = 10 * 1024 * 1024  # 10 GiB
        history = [(0, 500_000_000)]
        # +28.4 GiB over 28 minutes: mirrors the disk_magician-pkq incident.
        delta_kb = int(28.4 * 1024 * 1024)
        event = observer.check_step_event(
            history, now_epoch=28 * 60, used_kb=500_000_000 + delta_kb,
            window_seconds=1800, threshold_kb=threshold_kb,
        )
        self.assertIsNotNone(event)
        self.assertEqual(event["delta_kb"], delta_kb)
        self.assertEqual(event["direction"], "grew")
        self.assertEqual(event["window_seconds"], 28 * 60)

        # Shrinking past the threshold reports "shrank" with a negative delta.
        history2 = [(0, 500_000_000)]
        shrink_event = observer.check_step_event(
            history2, now_epoch=900, used_kb=500_000_000 - delta_kb,
            window_seconds=1800, threshold_kb=threshold_kb,
        )
        self.assertEqual(shrink_event["direction"], "shrank")
        self.assertEqual(shrink_event["delta_kb"], -delta_kb)

    def test_default_hot_dirs_and_collect_hot_dir_sizes_paths(self):
        observer = load_module()
        self.assertIn(".aside", observer.DEFAULT_HOT_DIRS)
        self.assertIn("/private/tmp", observer.DEFAULT_HOT_DIRS)
        self.assertIn(".ollama", observer.DEFAULT_HOT_DIRS)
        self.assertIn(".openclaw", observer.DEFAULT_HOT_DIRS)
        self.assertIn(".hermes", observer.DEFAULT_HOT_DIRS)
        self.assertIn(".gemini", observer.DEFAULT_HOT_DIRS)
        self.assertIn("/private/var/folders", observer.DEFAULT_HOT_DIRS)
        self.assertIn("Library/Application Support/Cursor", observer.DEFAULT_HOT_DIRS)
        self.assertIn("Library/Application Support/Aside", observer.DEFAULT_HOT_DIRS)
        self.assertIn("Library/Caches", observer.DEFAULT_HOT_DIRS)

        calls = []

        def fake_run(argv, timeout=8):
            calls.append(tuple(argv))
            return observer.CommandResult(0, f"54321\t{argv[-1]}\n", "", False)

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "user_home"
            home.mkdir()
            abs_target = Path(tmp) / "custom_abs"
            abs_target.mkdir()
            (home / ".codex").mkdir()
            (home / ".aside" / "u" / "0").mkdir(parents=True)

            with mock.patch.dict(os.environ, {"HOME": str(home)}):
                sizes = observer.collect_hot_dir_sizes(
                    home,
                    fake_run,
                    hot_dirs=[
                        ".codex",
                        "missing_rel",
                        str(abs_target),
                        "/missing/abs",
                        "~/.aside/u/0",
                        "~/missing_tilde",
                    ],
                )

        self.assertEqual(sizes[".codex"], 54321)
        self.assertIsNone(sizes["missing_rel"])
        self.assertEqual(sizes[str(abs_target)], 54321)
        self.assertIsNone(sizes["/missing/abs"])
        self.assertEqual(sizes["~/.aside/u/0"], 54321)
        self.assertIsNone(sizes["~/missing_tilde"])
        du_targets = [call[2] for call in calls if call[0] == "du"]
        self.assertIn(str(home / ".codex"), du_targets)
        self.assertIn(str(abs_target), du_targets)
        self.assertIn(str(home / ".aside" / "u" / "0"), du_targets)

    def test_step_event_record_includes_non_recursive_hot_dir_sizes(self):
        observer = load_module()
        calls = []

        def fake_run(argv, timeout=8):
            calls.append(tuple(argv))
            # Fake du output: single summary line, no per-subdirectory rows —
            # proves the caller only issues one non-recursive `du -sk` per
            # hot dir rather than a deep sweep.
            return observer.CommandResult(0, f"12345\t{argv[-1]}\n", "", False)

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            home.mkdir()
            abs_dir = Path(tmp) / "private_tmp"
            abs_dir.mkdir()

            (home / ".codex").mkdir()
            (home / ".cache").mkdir()
            (home / ".aside" / "u" / "0").mkdir(parents=True)
            # "missing_dir" deliberately not created, to exercise the
            # does-not-exist -> None path without shelling out.

            hot_dirs = [
                ".codex",
                ".cache",
                "missing_dir",
                str(abs_dir),
                "/nonexistent/abs/path",
                "~/.aside/u/0",
                "~/nonexistent/tilde/path",
            ]

            event = {"delta_kb": 11 * 1024 * 1024, "direction": "grew", "window_seconds": 1500}
            with mock.patch.dict(os.environ, {"HOME": str(home)}):
                record = observer.build_step_event_record(1_700_000_000, event, home, fake_run, hot_dirs)

        self.assertEqual(record["schema_version"], 1)
        self.assertEqual(record["tool"], "disk_observer_step_event")
        self.assertEqual(record["delta_kb"], 11 * 1024 * 1024)
        self.assertEqual(record["direction"], "grew")
        self.assertEqual(record["window_seconds"], 1500)
        self.assertEqual(record["hot_dirs_kb"][".codex"], 12345)
        self.assertEqual(record["hot_dirs_kb"][".cache"], 12345)
        self.assertEqual(record["hot_dirs_kb"][str(abs_dir)], 12345)
        self.assertEqual(record["hot_dirs_kb"]["~/.aside/u/0"], 12345)
        self.assertIsNone(record["hot_dirs_kb"]["missing_dir"])
        self.assertIsNone(record["hot_dirs_kb"]["/nonexistent/abs/path"])
        self.assertIsNone(record["hot_dirs_kb"]["~/nonexistent/tilde/path"])
        # Exactly one du call per existing hot dir — no recursive tree walk.
        du_calls = [call for call in calls if call[0] == "du"]
        self.assertEqual(len(du_calls), 4)
        for call in du_calls:
            self.assertEqual(call[0:2], ("du", "-sk"))

    def test_rotation_is_size_bounded_and_report_correlates_deltas(self):
        observer = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "samples.jsonl"
            log.write_text("x" * 101, encoding="utf-8")
            observer.rotate_if_needed(log, max_bytes=100, keep=2)
            self.assertFalse(log.exists())
            self.assertTrue(Path(str(log) + ".1").exists())

            old_rotation = Path(str(log) + ".2")
            old_rotation.write_text("old", encoding="utf-8")
            old = time.time() - 8 * 86400
            os.utime(old_rotation, (old, old))
            observer.rotate_if_needed(log, max_bytes=100, keep=2)
            self.assertFalse(old_rotation.exists())

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
        step_events = [
            {
                "schema_version": 1,
                "tool": "disk_observer_step_event",
                "timestamp": "2026-07-14T01:01:00Z",
                "epoch": 160,
                "delta_kb": 15 * 1024 * 1024,
                "direction": "grew",
                "window_seconds": 60,
                "hot_dirs_kb": {".codex": 5000},
            }
        ]
        report = observer.build_report(records, limit=5, step_events=step_events)
        swing = report["largest_host_free_space_decreases"][0]
        self.assertEqual(swing["host_available_delta_kb"], -300)
        self.assertEqual(swing["colima_allocated_delta_kb"], 250)
        self.assertEqual(swing["docker_writable_delta_bytes"], 200)
        self.assertEqual(swing["docker_events"][0]["action"], "start")
        self.assertEqual(swing["top_processes"][0]["command"], "docker")
        self.assertEqual(report["step_event_count"], 1)
        self.assertEqual(report["recent_step_events"][0]["direction"], "grew")

    def test_seed_step_event_history_filters_by_window(self):
        observer = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "samples.jsonl"
            samples = [
                {"epoch": 1000, "host_disk": {"used_kb": 100_000}},
                {"epoch": 2000, "host_disk": {"used_kb": 110_000}},
                {"epoch": 3000, "host_disk": {"used_kb": 120_000}},
            ]
            with log.open("w", encoding="utf-8") as f:
                for s in samples:
                    f.write(json.dumps(s) + "\n")

            # Window of 1500s at now=3200 -> only epoch 2000 and 3000 in window (3200-2000=1200 <= 1500; 3200-1000=2200 > 1500)
            history = observer.seed_step_event_history(log, window_seconds=1500, now_epoch=3200)
            self.assertEqual(history, [(2000, 110_000), (3000, 120_000)])

    def test_default_hot_dirs_are_strictly_portable(self):
        observer = load_module()
        disallowed = {"cb-demo", "project_jleechanclaw", "worktrees", ".cmuxterm"}
        for item in observer.DEFAULT_HOT_DIRS:
            self.assertNotIn(item, disallowed, f"Host-specific path {item!r} found in DEFAULT_HOT_DIRS")
            self.assertFalse(item.startswith("project_"), f"Host-specific project path {item!r} found in DEFAULT_HOT_DIRS")
        expected_dirs = [
            ".codex",
            ".cache",
            ".aside",
            ".ollama",
            ".openclaw",
            ".hermes",
            ".gemini",
            "/private/tmp",
            "/private/var/folders",
            "Library/Application Support/Cursor",
            "Library/Application Support/Aside",
            "Library/Caches",
        ]
        self.assertEqual(observer.DEFAULT_HOT_DIRS, expected_dirs)

    def test_config_template_contains_no_host_specific_defaults(self):
        template_path = ROOT / "config.json.template"
        with template_path.open(encoding="utf-8") as f:
            cfg = json.load(f)
        monitored_paths = [m.get("path", "") for m in cfg.get("monitored_dirs", [])]
        monitored_keys = [m.get("key", "") for m in cfg.get("monitored_dirs", [])]
        self.assertNotIn("dev_cache_bazel", monitored_keys)
        for p in monitored_paths:
            self.assertNotIn("Snapchat", p)
            self.assertNotIn("jleechan", p)
        for g in cfg.get("monitored_globs", []):
            self.assertNotIn("wa-", g.get("pattern", ""))
            self.assertNotIn("project_", g.get("pattern", ""))
        self.assertEqual(cfg.get("protected_tmp_roots"), [])
        self.assertEqual(cfg.get("downloads_evidence_patterns"), [])


if __name__ == "__main__":
    unittest.main()

