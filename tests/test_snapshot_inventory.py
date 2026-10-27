"""Snapshot rendering keeps immutable inventory references without traversal."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SnapshotInventoryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)

    def render(self, previous=None):
        source = (ROOT / "scripts/disk_snapshot.sh").read_text()
        source = source.split("pretty_json=$(", 1)[1]
        code = re.search(r"<<'PY'[^\n]*\n(.*?)\nPY\n\)", source, re.S).group(1)
        dirs = self.state / "dirs.tsv"
        dirs.write_text("watched\t0\t/fixture/empty\nunknown\tnull\t/fixture/unknown\n")
        env = dict(PATH=os.defpath, HOME=str(self.state), SNAP_TIMESTAMP="2026-10-24T22:00:00Z",
                   SNAP_COVERAGE_PCT="90", SNAP_COVERAGE_EFFECTIVE_PCT="90",
                   SNAP_DISK_USED="5", SNAP_DISK_USED_KB="5242880",
                   SNAP_INVENTORY_STATE=str(self.state),
                   SNAP_INVENTORY_PREVIOUS=json.dumps(previous or {}),
                   PYTHONPATH=str(ROOT / "scripts"))
        result = subprocess.run([sys.executable, "-c", code, str(dirs)],
                                env=env, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def publish(self, *, published="2026-10-24T21:00:00Z", df_samples=None):
        sys.path.insert(0, str(ROOT / "scripts"))
        from directory_inventory import publish_inventory
        return publish_inventory([], state_dir=self.state, complete=True,
                                 now=published, scan_metadata={"df_samples": df_samples or [],
                                 "selection_epoch": "selection-1", "selected_set_sha256": "set-1"})

    def test_missing_inventory_has_explicit_unknown_and_legacy_label(self):
        result = self.render()
        self.assertEqual(result["directory_inventory"]["status"], "unavailable")
        self.assertIsNone(result["directory_inventory"]["manifest_sha256"])
        self.assertEqual(result["legacy_root_df"]["used_bytes"], 5 * 1024**3)
        self.assertEqual(result["legacy_root_df"]["scope"], "legacy_root_df")
        self.assertEqual(result["directories"]["watched"], 0)
        self.assertIsNone(result["directories"]["unknown"])

    def test_fresh_manifest_and_per_filesystem_samples_are_referenced(self):
        sample = {"filesystem_id": "fs-home", "mountpoint": "/home", "sampled_at": "2026-10-24T21:00:00Z", "used_bytes": 512, "free_bytes": 1024}
        publication = self.publish(df_samples=[sample])
        result = self.render()
        self.assertEqual(result["directory_inventory"]["manifest_sha256"], publication["pointer"]["manifest_sha256"])
        self.assertEqual(result["directory_inventory"]["status"], "fresh")
        self.assertEqual(result["selected_filesystem_df_samples"], [sample])
        self.assertIsNone(result["selected_filesystem_df_aggregate"])

    def test_stale_manifest_never_gets_fresh_capture_time(self):
        self.publish(published="2026-10-20T21:00:00Z")
        result = self.render()["directory_inventory"]
        self.assertEqual(result["status"], "stale")
        self.assertEqual(result["captured_at"], "2026-10-20T21:00:00Z")

    def test_invalid_pointer_retains_verified_previous_reference(self):
        old = self.publish()
        previous = {"manifest_sha256": old["pointer"]["manifest_sha256"], "captured_at": "2026-10-24T21:00:00Z"}
        (self.state / "inventory/current.json").write_text('{"manifest_sha256":"' + "0"*64 + '"}')
        result = self.render(previous)["directory_inventory"]
        self.assertEqual(result["manifest_sha256"], previous["manifest_sha256"])
        self.assertEqual(result["status"], "stale")

    def test_expired_previous_reference_never_substitutes_current(self):
        previous = {"manifest_sha256": "a"*64, "captured_at": "2026-09-01T00:00:00Z"}
        result = self.render(previous)["directory_inventory"]
        self.assertEqual(result["status"], "retention-expired")
        self.assertEqual(result["manifest_sha256"], previous["manifest_sha256"])

    def test_missing_historical_measurement_is_retention_expired(self):
        old = self.publish()
        previous = {"manifest_sha256": old["pointer"]["manifest_sha256"],
                    "captured_at": old["manifest"]["published_at"]}
        digest = old["manifest"]["measurement_manifest_sha256"]
        (self.state / "inventory/objects" / (digest + ".jsonl.gz")).unlink()
        (self.state / "inventory/current.json").write_text("{}")
        result = self.render(previous)
        self.assertEqual(result["directory_inventory"]["status"], "retention-expired")
        self.assertFalse(result["directory_inventory"]["complete"])
        self.assertEqual(result["selected_filesystem_df_samples"], [])


if __name__ == "__main__":
    unittest.main()
