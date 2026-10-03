#!/usr/bin/env python3
"""Focused, fixture-only tests for the read-only launchd inventory."""

import json
import os
import plistlib
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(ROOT / "scripts"))
import job_inventory


class JobInventoryTests(unittest.TestCase):
    def test_catalog_is_template_derived_and_matches_compatibility_labels(self):
        records, _ = job_inventory.catalog(ROOT)
        labels = {record["label"] for record in records}
        expected = {
            "com.disk-magician.apfs-snapshots",
            "com.disk-magician.claude-state",
            "com.disk-magician.codex-vacuum",
            "com.disk-magician.colima-prune",
            "com.disk-magician.cursor-logs-watchdog",
            "com.disk-magician.fsevents-projects",
            "com.disk-magician.hermes-vacuum",
            "com.disk-magician.playwright-dedup",
            "com.disk-magician.sweeper-health",
            "com.disk-magician.worktree-venvs",
            "com.jleechanorg.disk-magician",
            "com.jleechanorg.disk-magician-downloads-evidence",
            "com.jleechanorg.disk-magician-drilldown",
            "com.jleechanorg.disk-magician-frontier-nightly",
            "com.jleechanorg.disk-magician-frontier-root",
            "com.jleechanorg.disk-magician-observer",
            "com.jleechanorg.disk-magician-pressure-sweep",
            "com.jleechanorg.disk-magician-tmp-scratch",
            "com.jleechanorg.disk-magician-worktree-hygiene",
        }
        self.assertEqual(labels, expected)
        for record in records:
            for key in ("entrypoint", "args", "schedule", "execution_kind", "receipt_owner", "coverage_owner"):
                self.assertIn(key, record)

    def test_parser_rejects_top_level_array_and_wrong_label(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.plist"
            path.write_bytes(plistlib.dumps(["not", "a", "job"]))
            parsed, error = job_inventory.parse_plist(path)
            self.assertIsNone(parsed)
            self.assertIn("top-level plist", error)
            path.write_bytes(plistlib.dumps({"Label": "other"}))
            parsed, error = job_inventory.parse_plist(path)
            self.assertEqual(parsed["Label"], "other")
            self.assertIsNone(error)

    def test_fleet_uses_exact_loaded_labels_and_user_system_separation(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            agents = tmp / "agents"
            daemons = tmp / "daemons"
            fakebin = tmp / "bin"
            agents.mkdir()
            daemons.mkdir()
            fakebin.mkdir()
            records, _ = job_inventory.catalog(ROOT)
            for record in records:
                source = Path(record["source_path"])
                if source.name == "disk_magician.sh":
                    payload = {
                        "Label": record["label"],
                        "ProgramArguments": ["/tmp/diskm", "snapshot"],
                        "StartInterval": 1800,
                    }
                else:
                    payload = plistlib.loads(job_inventory._strip_comments(source.read_bytes()))
                destination = (daemons if record["domain"] == "system" else agents) / f"{record['label']}.plist"
                destination.write_bytes(plistlib.dumps(payload))
            labels = [record["label"] for record in records]
            (fakebin / "launchctl").write_text(
                "#!/bin/sh\n"
                + "for label in " + " ".join(labels) + "; do printf '0\\t0\\t%s\\n' \"$label\"; done\n"
            )
            (fakebin / "launchctl").chmod(stat.S_IRWXU)
            env = os.environ.copy()
            env.update(
                OSTYPE="darwin24",
                PATH=f"{fakebin}:{env['PATH']}",
                DISK_MAGICIAN_LAUNCHAGENTS_DIR=str(agents),
                DISK_MAGICIAN_LAUNCHDAEMONS_DIR=str(daemons),
            )
            proc = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "job_inventory.py"), "--json"],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            result = json.loads(proc.stdout)
            self.assertEqual(result["status"], "healthy")
            self.assertTrue(all(record["status"] == "healthy" for record in result["records"]))
            self.assertEqual(
                result["records"][[r["label"] for r in result["records"]].index("com.jleechanorg.disk-magician-frontier-root")]["domain"],
                "system",
            )


if __name__ == "__main__":
    unittest.main()
