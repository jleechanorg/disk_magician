#!/usr/bin/env python3
"""Read-only inventory contracts for cache, workspace, and Simulator ledgers."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "disk_inventory.py"


def load_module():
    spec = importlib.util.spec_from_file_location("disk_inventory", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


class DiskInventoryTest(unittest.TestCase):
    def test_lsof_failure_fail_closes_managed_cache_reclaim(self):
        now = int(time.time())
        old = now - 40 * 86400
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            root = home / "Library" / "Caches"
            old_entry = root / "go-build" / "old-entry"
            old_entry.mkdir(parents=True)
            (old_entry / "payload").write_bytes(b"x" * 4096)
            os.utime(old_entry / "payload", (old, old))
            os.utime(old_entry, (old, old))
            fake_bin = home / "bin"
            fake_bin.mkdir()
            fake_lsof = fake_bin / "lsof"
            fake_lsof.write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
            fake_lsof.chmod(0o755)
            output = home / "cache.json"
            env = {"HOME": str(home), "PATH": f"{fake_bin}:{os.environ['PATH']}"}
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--output", str(output), "caches", "--root", str(root)],
                env=env, capture_output=True, text=True, check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(output.read_text(encoding="utf-8"))

        cache = result["entries"][0]
        self.assertFalse(result.get("open_file_attribution_complete", True))
        self.assertEqual(result.get("open_file_attribution_error"), "lsof_exit_1")
        self.assertEqual(cache["classification"], "unknown")
        self.assertEqual(cache["reclaim_ceiling_bytes"], 0)

    def test_cache_reclaim_matches_existing_top_level_age_gate_and_refuses_symlink(self):
        inventory = load_module()
        now = int(time.time())
        old = now - 40 * 86400
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Library" / "Caches"
            recent_entry = root / "go-build" / "recent-entry"
            old_entry = root / "go-build" / "old-entry"
            outside = Path(tmp) / "outside-cache"
            recent_entry.mkdir(parents=True)
            old_entry.mkdir(parents=True)
            outside.mkdir()
            recent_payload = recent_entry / "old-payload"
            old_payload = old_entry / "payload"
            recent_payload.write_bytes(b"r" * 4096)
            old_payload.write_bytes(b"o" * 8192)
            os.utime(recent_payload, (old, old))
            os.utime(old_payload, (old, old))
            os.utime(old_entry, (old, old))
            (root / "claude-cli-nodejs").symlink_to(outside, target_is_directory=True)

            expected = inventory._walk_measure(old_entry, now)["allocated_bytes"]
            result = inventory.inventory_caches(root, now_epoch=now, open_files=[])

        by_name = {item["name"]: item for item in result["entries"]}
        self.assertEqual(by_name["go-build"]["reclaim_ceiling_bytes"], expected)
        self.assertGreater(by_name["go-build"]["age_buckets"]["older_than_30d_bytes"], expected)
        self.assertEqual(by_name["claude-cli-nodejs"]["classification"], "protected")
        self.assertEqual(by_name["claude-cli-nodejs"]["reclaim_ceiling_bytes"], 0)

    def test_cache_inventory_has_coverage_age_owner_and_fail_closed_classification(self):
        inventory = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Library" / "Caches"
            managed = root / "go-build" / "old"
            active = root / "mystery" / "live"
            unknown = root / "other"
            managed.mkdir(parents=True)
            active.mkdir(parents=True)
            unknown.mkdir(parents=True)
            (managed / "payload").write_bytes(b"x" * 8192)
            (active / "payload").write_bytes(b"y" * 4096)
            (unknown / "payload").write_bytes(b"z" * 4096)
            old = time.time() - 40 * 86400
            os.utime(managed / "payload", (old, old))

            result = inventory.inventory_caches(
                root, now_epoch=int(time.time()),
                open_files=[{"path": str(active / "payload"), "pid": 77, "command": "builder"}],
            )

        by_name = {item["name"]: item for item in result["entries"]}
        self.assertGreaterEqual(result["coverage_pct"], 95)
        self.assertEqual(by_name["go-build"]["classification"], "safe_automatic")
        self.assertEqual(by_name["go-build"]["cleanup_owner"], "cleanup_dev_caches.sh")
        self.assertGreater(by_name["go-build"]["age_buckets"]["older_than_30d_bytes"], 0)
        self.assertEqual(by_name["mystery"]["classification"], "active")
        self.assertEqual(by_name["mystery"]["active_processes"][0]["pid"], 77)
        self.assertEqual(by_name["other"]["classification"], "unknown")
        self.assertEqual(by_name["other"]["reclaim_ceiling_bytes"], 0)
        self.assertTrue(by_name["other"].get("upgrade_path"))

    def test_github_pr_ownership_is_bounded_and_surfaces_timeout(self):
        inventory = load_module()
        self.assertTrue(
            hasattr(inventory, "_github_pr_ownership"),
            "branch-to-PR ownership lookup is missing",
        )
        payload = [{
            "number": 42,
            "html_url": "https://github.com/jleechanorg/example/pull/42",
            "state": "open",
            "draft": False,
            "head": {
                "ref": "feature",
                "repo": {"full_name": "jleechanorg/example"},
            },
            "base": {"ref": "main"},
        }, {
            "number": 43,
            "html_url": "https://github.com/someone/example/pull/43",
            "state": "open",
            "draft": False,
            "head": {
                "ref": "feature",
                "repo": {"full_name": "someone/example"},
            },
            "base": {"ref": "main"},
        }]
        completed = subprocess.CompletedProcess(["gh", "api"], 0, json.dumps(payload), "")
        with mock.patch.object(inventory.subprocess, "run", return_value=completed) as run:
            result = inventory._github_pr_ownership(
                "https://jleechan2015@github.com/jleechanorg/example.git",
                "feature",
                timeout=4,
            )

        self.assertTrue(result["complete"])
        self.assertEqual(result["pull_requests"][0]["number"], 42)
        self.assertEqual(result["pull_requests"][0]["url"], payload[0]["html_url"])
        self.assertEqual(result["pull_requests"][0]["head_repo"], "jleechanorg/example")
        self.assertEqual(len(result["pull_requests"]), 1)
        self.assertEqual(run.call_args.kwargs["timeout"], 4)

        missing_repo_payload = [{
            "number": 44,
            "html_url": "https://github.com/jleechanorg/example/pull/44",
            "state": "open",
            "draft": False,
            "head": {"ref": "feature", "repo": None},
            "base": {"ref": "main"},
        }]
        missing_repo = subprocess.CompletedProcess(
            ["gh", "api"], 0, json.dumps(missing_repo_payload), ""
        )
        with mock.patch.object(inventory.subprocess, "run", return_value=missing_repo):
            incomplete = inventory._github_pr_ownership(
                "https://github.com/jleechanorg/example.git", "feature", timeout=4
            )
        self.assertFalse(incomplete["complete"])
        self.assertEqual(incomplete["error"], "missing_head_repo")
        self.assertEqual(incomplete["pull_requests"], [])
        inventory._github_open_pulls.cache_clear()

        with mock.patch.object(
            inventory.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(["gh", "api"], 4),
        ):
            timed_out = inventory._github_pr_ownership(
                "https://github.com/jleechanorg/example.git", "feature", timeout=4
            )
        self.assertFalse(timed_out["complete"])
        self.assertEqual(timed_out["error"], "timeout")
        self.assertEqual(timed_out["pull_requests"], [])

        full_page = subprocess.CompletedProcess(
            ["gh", "api"], 0, json.dumps(payload * 100), ""
        )
        with mock.patch.object(inventory.subprocess, "run", return_value=full_page):
            truncated = inventory._github_pr_ownership(
                "git@github.com:jleechanorg/full-page.git", "feature", timeout=4
            )
        self.assertFalse(truncated["complete"])
        self.assertEqual(truncated["error"], "pagination_limit")

    def test_ao_native_scan_timeout_is_incomplete(self):
        inventory = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            candidate = base / "lanes" / "lane"
            candidate.mkdir(parents=True)
            ao_root = base / ".ao"
            ao_root.mkdir()
            (ao_root / "session.json").write_text(
                json.dumps({"worktree": str(candidate)}), encoding="utf-8"
            )
            with mock.patch.object(
                inventory.subprocess,
                "run",
                side_effect=subprocess.TimeoutExpired(["rg"], 30),
            ):
                references, complete = inventory._ao_reference_map(
                    [candidate], [ao_root]
                )

        self.assertFalse(complete)
        self.assertEqual(references[str(candidate.resolve())], [])

    def test_path_inventory_attributes_artifacts_and_excludes_uncertain_reclaim(self):
        inventory = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / ".lvl-lanes"
            venv = root / "lane-a" / ".venv"
            node = root / "lane-b" / "node_modules"
            venv.mkdir(parents=True)
            node.mkdir(parents=True)
            ao_root = Path(tmp) / ".ao"
            ao_root.mkdir()
            (venv / "pyvenv.cfg").write_text("home=/usr/bin\n", encoding="utf-8")
            (node / "package.json").write_text("{}", encoding="utf-8")
            (ao_root / "session.json").write_text(
                json.dumps({"worktree": str(root / "lane-a")}), encoding="utf-8"
            )
            result = inventory.inventory_paths(
                [root], now_epoch=int(time.time()), open_files=[], ao_metadata_roots=[ao_root]
            )

        self.assertGreaterEqual(result["roots"][0]["coverage_pct"], 95)
        entries = result["roots"][0]["entries"]
        self.assertEqual({entry["name"] for entry in entries}, {"lane-a", "lane-b"})
        self.assertTrue(any(a["artifact_type"] == "venv" for a in entries[0]["artifacts"] + entries[1]["artifacts"]))
        self.assertTrue(any(a["artifact_type"] == "node_modules" for a in entries[0]["artifacts"] + entries[1]["artifacts"]))
        by_name = {entry["name"]: entry for entry in entries}
        self.assertTrue(result["ao_attribution_complete"])
        self.assertTrue(by_name["lane-a"]["ao_metadata_references"])
        self.assertIn("captured_at", result)
        self.assertEqual(result["history"]["status"], "baseline_only")
        self.assertIsNone(result["history"]["child_growth_7d_bytes"])
        self.assertIsNone(result["history"]["child_growth_30d_bytes"])
        self.assertIn("aggregate", result["history"]["blocker"])
        ranked_types = {item["artifact_type"] for item in result["artifact_class_ranking"]}
        self.assertTrue({"venv", "node_modules"} <= ranked_types)
        self.assertEqual(result["roots"][0]["coverage_status"], "complete")
        self.assertTrue(result["roots"][0]["coverage_target_met"])
        self.assertEqual(result["reclaim_ceiling_bytes"], 0)

    def test_ao_timeout_fail_closes_an_otherwise_eligible_worktree(self):
        inventory = load_module()
        now = int(time.time())
        old = now - 40 * 86400
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            remote = base / "remote.git"
            main = base / "main"
            lanes = base / "lanes"
            worktree = lanes / "lane"
            ao_root = base / ".ao"
            ao_root.mkdir()
            subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True)
            subprocess.run(["git", "init", "-b", "main", str(main)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(main), "config", "user.email", "fixture@users.noreply.github.com"], check=True)
            subprocess.run(["git", "-C", str(main), "config", "user.name", "Fixture User"], check=True)
            (main / "README.md").write_text("base\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(main), "add", "README.md"], check=True)
            subprocess.run(["git", "-C", str(main), "commit", "-m", "base"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(main), "remote", "add", "origin", str(remote)], check=True)
            subprocess.run(["git", "-C", str(main), "push", "-u", "origin", "main"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(main), "worktree", "add", "-b", "lane", str(worktree)], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(worktree), "branch", "--set-upstream-to", "origin/main"], check=True, capture_output=True)
            for path in sorted(worktree.rglob("*"), key=lambda item: len(item.parts), reverse=True):
                os.utime(path, (old, old), follow_symlinks=False)
            os.utime(worktree, (old, old))
            (ao_root / "session.json").write_text("{}", encoding="utf-8")

            with mock.patch.object(inventory, "_ao_reference_map", return_value=({}, False)):
                result = inventory.inventory_paths(
                    [lanes], now_epoch=now, open_files=[], ao_metadata_roots=[ao_root]
                )
            with mock.patch.object(inventory, "_ao_reference_map", return_value=({}, True)), mock.patch.object(
                inventory,
                "_github_pr_ownership",
                return_value={"complete": False, "error": "timeout", "pull_requests": []},
                create=True,
            ):
                pr_failure_result = inventory.inventory_paths(
                    [lanes], now_epoch=now, open_files=[], ao_metadata_roots=[]
                )
            open_failure_result = inventory.inventory_paths(
                [lanes], now_epoch=now, open_files=[], ao_metadata_roots=[],
                open_file_attribution_complete=False,
                open_file_attribution_error="lsof_timeout",
            )

        lane = result["roots"][0]["entries"][0]
        self.assertFalse(result["ao_attribution_complete"])
        self.assertEqual(lane["classification"], "unknown")
        self.assertEqual(lane["reclaim_ceiling_bytes"], 0)
        self.assertEqual(result["reclaim_ceiling_bytes"], 0)
        pr_failure_lane = pr_failure_result["roots"][0]["entries"][0]
        self.assertFalse(pr_failure_lane["git"].get("pr_attribution_complete", True))
        self.assertEqual(pr_failure_lane["classification"], "unknown")
        self.assertEqual(pr_failure_lane["reclaim_ceiling_bytes"], 0)
        open_failure_lane = open_failure_result["roots"][0]["entries"][0]
        self.assertFalse(open_failure_result["open_file_attribution_complete"])
        self.assertEqual(open_failure_lane["classification"], "unknown")
        self.assertEqual(open_failure_lane["reclaim_ceiling_bytes"], 0)

    def test_simulator_inventory_is_ledger_only_with_supported_commands(self):
        inventory = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            udid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            device_dir = home / "Library" / "Developer" / "CoreSimulator" / "Devices" / udid
            device_dir.mkdir(parents=True)
            (device_dir / "data.bin").write_bytes(b"x" * 4096)
            simctl = {
                "devices": {
                    "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
                        {"name": "iPhone 16", "udid": udid, "state": "Shutdown", "isAvailable": False}
                    ]
                }
            }
            result = inventory.inventory_simulators(home, simctl, now_epoch=int(time.time()))

        device = result["devices"][0]
        self.assertFalse(device["available"])
        self.assertGreater(device["allocated_bytes"], 0)
        self.assertEqual(device["supported_delete_command"], ["xcrun", "simctl", "delete", udid])
        self.assertEqual(result["executed_commands"], [])

    def test_simctl_failure_is_surfaced_instead_of_empty_success(self):
        inventory = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            result = inventory.inventory_simulators(
                Path(tmp), {"devices": {}, "error": "simctl_exit_127"}
            )

        self.assertEqual(result.get("error"), "simctl_exit_127")
        self.assertEqual(result["inventory_status"], "unavailable")
        self.assertEqual(result["unavailable_reclaim_ceiling_bytes"], 0)

    def test_existing_dev_cache_cleanup_contract_is_dry_run_and_top_level_age_gated(self):
        now = int(time.time())
        old = now - 40 * 86400
        cleanup = ROOT / "scripts" / "cleanup_dev_caches.sh"
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            opencode_entry = home / ".local" / "share" / "opencode" / "repos" / "old-entry"
            cursor_versions = home / ".local" / "share" / "cursor-agent" / "versions"
            cache = home / "Library" / "Caches" / "go-build"
            old_entry = cache / "old-entry"
            recent_entry = cache / "recent-entry"
            opencode_entry.mkdir(parents=True)
            for version in ("v1", "v2", "v3"):
                (cursor_versions / version).mkdir(parents=True)
            old_entry.mkdir(parents=True)
            recent_entry.mkdir()
            (opencode_entry / "payload").write_text("old", encoding="utf-8")
            (old_entry / "payload").write_text("old", encoding="utf-8")
            (recent_entry / "payload").write_text("recent", encoding="utf-8")
            os.utime(opencode_entry / "payload", (old, old))
            os.utime(opencode_entry, (old, old))
            os.utime(old_entry / "payload", (old, old))
            os.utime(old_entry, (old, old))
            completed = subprocess.run(
                ["/bin/bash", str(cleanup), "--dry-run"],
                env={"HOME": str(home), "PATH": os.environ["PATH"]},
                capture_output=True, text=True, check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(str(opencode_entry), completed.stdout)
        self.assertIn(str(cursor_versions / "v1"), completed.stdout)
        self.assertIn(str(old_entry), completed.stdout)
        self.assertNotIn(str(recent_entry), completed.stdout)
        self.assertIn("no files deleted", completed.stdout)

    def test_cli_source_contains_no_delete_execution(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("shutil.rmtree", text)
        self.assertNotIn("os.unlink", text)
        self.assertNotIn("simctl\", \"delete", text)


if __name__ == "__main__":
    unittest.main()
