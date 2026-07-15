#!/usr/bin/env python3
"""Read-only inventory contracts for cache, workspace, and Simulator ledgers."""

import importlib.util
import json
import os
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "disk_inventory.py"


def load_module():
    spec = importlib.util.spec_from_file_location("disk_inventory", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


class DiskInventoryTest(unittest.TestCase):
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

    def test_path_inventory_attributes_artifacts_and_excludes_uncertain_reclaim(self):
        inventory = load_module()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / ".lvl-lanes"
            venv = root / "lane-a" / ".venv"
            node = root / "lane-b" / "node_modules"
            venv.mkdir(parents=True)
            node.mkdir(parents=True)
            (venv / "pyvenv.cfg").write_text("home=/usr/bin\n", encoding="utf-8")
            (node / "package.json").write_text("{}", encoding="utf-8")
            result = inventory.inventory_paths([root], now_epoch=int(time.time()), open_files=[])

        self.assertGreaterEqual(result["roots"][0]["coverage_pct"], 95)
        entries = result["roots"][0]["entries"]
        self.assertEqual({entry["name"] for entry in entries}, {"lane-a", "lane-b"})
        self.assertTrue(any(a["artifact_type"] == "venv" for a in entries[0]["artifacts"] + entries[1]["artifacts"]))
        self.assertTrue(any(a["artifact_type"] == "node_modules" for a in entries[0]["artifacts"] + entries[1]["artifacts"]))
        self.assertEqual(result["reclaim_ceiling_bytes"], 0)

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

    def test_cli_source_contains_no_delete_execution(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("shutil.rmtree", text)
        self.assertNotIn("os.unlink", text)
        self.assertNotIn("simctl\", \"delete", text)


if __name__ == "__main__":
    unittest.main()
