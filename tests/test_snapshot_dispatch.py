"""Exercise the public dispatcher's argument boundary without running collectors."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SnapshotDispatchTest(unittest.TestCase):
    def test_snapshot_preserves_scheduled_refresh_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "disk_magician.sh").write_bytes((ROOT / "disk_magician.sh").read_bytes())
            (root / "scripts/snapshot_commit.sh").write_text('printf "%s\\n" "$@"\n')
            result = subprocess.run(["bash", str(root / "disk_magician.sh"), "snapshot",
                                     "--inventory-refresh", "--receipt", "a path"],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(),
                             ["--inventory-refresh", "--receipt", "a path"])
