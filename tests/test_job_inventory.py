#!/usr/bin/env python3
"""Focused, fixture-only tests for the read-only launchd inventory."""

import json
import os
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest import mock
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

    def test_receipt_owners_use_exact_owned_labels_and_commands(self):
        pressure = job_inventory._owners(
            "com.jleechanorg.disk-magician-pressure-sweep", ["/bin/bash", "pressure-sweep"]
        )
        scratch = job_inventory._owners(
            "com.jleechanorg.disk-magician-tmp-scratch", ["/bin/bash", "tmp-scratch-sweep"]
        )
        unowned = job_inventory._owners("com.example.unowned", ["/bin/bash", "pressure-sweepish"])
        self.assertEqual(pressure[0], "pressure_sweep.sh")
        self.assertEqual(scratch[0], "tmp_scratch_sweep.sh")
        self.assertEqual(unowned[0], "unknown")

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

    def test_parser_falls_back_to_plistlib_without_plutil(self):
        template = ROOT / "launchd" / "com.disk-magician.claude-state.plist.template"
        with mock.patch.object(job_inventory.subprocess, "run", side_effect=FileNotFoundError("plutil")):
            parsed, error = job_inventory.parse_plist(template)
        self.assertIsNone(error)
        self.assertEqual(parsed["Label"], "com.disk-magician.claude-state")

    def test_launchctl_missing_service_is_degraded_and_timeout_is_unknown(self):
        missing = subprocess.CompletedProcess(
            ["launchctl", "print", "system/example"], 113, "", "Could not find service\n"
        )
        with mock.patch.object(job_inventory.subprocess, "run", return_value=missing):
            loaded, error = job_inventory._launchctl_print("system", "example")
        self.assertFalse(loaded)
        self.assertIsNone(error)
        with mock.patch.object(
            job_inventory.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(["launchctl", "print"], 3),
        ):
            loaded, error = job_inventory._launchctl_print("user", "example")
        self.assertIsNone(loaded)
        self.assertIn("timed out", error)

    def test_invalid_catalog_record_is_preserved_and_cli_returns_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            launchd = root / "launchd"
            launchd.mkdir()
            (root / "disk_magician.sh").write_text("#!/bin/sh\n")
            (launchd / "bad.plist.template").write_text("not a plist")
            env = os.environ.copy()
            env["DISK_MAGICIAN_OSTYPE"] = "linux-test"
            proc = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "job_inventory.py"), "--repo-root", str(root), "--json"],
                env=env,
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(proc.returncode, 2, proc.stderr)
            result = json.loads(proc.stdout)
            bad = next(record for record in result["records"] if record["label"] == "bad")
            self.assertEqual(result["status"], "invalid")
            self.assertEqual(bad["domain"], "unknown")
            self.assertEqual(bad["status"], "invalid")

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
                        "ProgramArguments": [str(Path(os.environ.get("HOME", "~")) / ".local/bin/diskm"), "snapshot"],
                        "StartInterval": 1800,
                    }
                else:
                    payload = plistlib.loads(job_inventory._strip_comments(source.read_bytes()))
                    def render(value):
                        if isinstance(value, str):
                            return job_inventory._materialize_args([value], ROOT)[0]
                        if isinstance(value, list):
                            return [render(item) for item in value]
                        if isinstance(value, dict):
                            return {key: render(item) for key, item in value.items()}
                        return value
                    payload = render(payload)
                destination = (daemons if record["domain"] == "system" else agents) / f"{record['label']}.plist"
                destination.write_bytes(plistlib.dumps(payload))
            labels = [record["label"] for record in records]
            (fakebin / "launchctl").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = print ]; then printf '%s = {\\n' \"$2\"; exit 0; fi\n"
                "echo 'unexpected launchctl query' >&2; exit 2\n"
            )
            (fakebin / "launchctl").chmod(stat.S_IRWXU)
            env = os.environ.copy()
            env.update(
                OSTYPE="darwin24",
                PATH=f"{fakebin}:{env['PATH']}",
                DISK_MAGICIAN_LAUNCHCTL_UID="501",
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
            frontier_root = next(
                record for record in result["records"] if record["label"] == "com.jleechanorg.disk-magician-frontier-root"
            )
            self.assertEqual(frontier_root["domain"], "system")
            self.assertEqual(frontier_root["identity_source"], "installed_plist")
            self.assertEqual(frontier_root["program_arguments"], frontier_root["expected_program_arguments"])
            self.assertEqual(frontier_root["execution_root"], "/usr/local/libexec/disk-magician")

            pressure = next(
                record for record in result["records"] if record["label"] == "com.jleechanorg.disk-magician-pressure-sweep"
            )
            self.assertEqual(pressure["receipt_owner"], "pressure_sweep.sh")
            self.assertEqual(pressure["expected_receipt_owner"], "pressure_sweep.sh")

    def test_successful_print_from_wrong_domain_is_not_healthy(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            agents, daemons, fakebin = tmp / "agents", tmp / "daemons", tmp / "bin"
            agents.mkdir(); daemons.mkdir(); fakebin.mkdir()
            records, _ = job_inventory.catalog(ROOT)
            for record in records:
                source = Path(record["source_path"])
                data = {"Label": record["label"], "ProgramArguments": record["args"]}
                if source.name != "disk_magician.sh":
                    data = plistlib.loads(job_inventory._strip_comments(source.read_bytes()))
                def render(value):
                    if isinstance(value, str):
                        return job_inventory._materialize_args([value], ROOT)[0]
                    if isinstance(value, list):
                        return [render(item) for item in value]
                    if isinstance(value, dict):
                        return {key: render(item) for key, item in value.items()}
                    return value
                data = render(data)
                target = daemons if record["domain"] == "system" else agents
                (target / f"{record['label']}.plist").write_bytes(plistlib.dumps(data))
            (fakebin / "launchctl").write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = print ]; then\n"
                "  case \"$2\" in\n"
                "    system/*) printf 'gui/501/%s = {\\n' \"${2#system/}\" ;;\n"
                "    gui/*) printf '%s = {\\n' \"$2\" ;;\n"
                "  esac\n"
                "  exit 0\n"
                "fi\nexit 2\n"
            )
            (fakebin / "launchctl").chmod(stat.S_IRWXU)
            env = os.environ.copy()
            env.update(
                DISK_MAGICIAN_OSTYPE="darwin24",
                DISK_MAGICIAN_LAUNCHCTL_UID="501",
                PATH=f"{fakebin}:{env['PATH']}",
                DISK_MAGICIAN_LAUNCHAGENTS_DIR=str(agents),
                DISK_MAGICIAN_LAUNCHDAEMONS_DIR=str(daemons),
            )
            result = json.loads(
                subprocess.run(
                    [sys.executable, str(ROOT / "scripts" / "job_inventory.py"), "--json"],
                    cwd=ROOT, env=env, text=True, capture_output=True, timeout=10,
                ).stdout
            )
            frontier_root = next(
                record for record in result["records"] if record["label"] == "com.jleechanorg.disk-magician-frontier-root"
            )
            self.assertNotEqual(frontier_root["status"], "healthy")
            self.assertEqual(frontier_root["status"], "unknown")
            self.assertIn("unrelated", frontier_root["reason"])


if __name__ == "__main__":
    unittest.main()
