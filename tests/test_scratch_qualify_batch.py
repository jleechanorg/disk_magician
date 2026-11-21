"""Tests for lossless, bounded, read-only Scratch qualification batches."""

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import scratch_qualify_batch


class ScratchQualifyBatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def fake_diskm(self):
        executable = self.root / "fake-diskm"
        executable.write_text(
            "#!/usr/bin/env python3\n"
            "import sys, time\n"
            "path = sys.argv[3]\n"
            "if path.endswith('slow'):\n"
            "    time.sleep(2)\n"
            "print('remove' if path.endswith('remove') else 'kept:recent-activity')\n"
        )
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
        return executable

    def test_nul_input_preserves_non_utf8_path_and_verdict_order(self):
        raw_path = os.fsencode(self.root) + b"/old-<$>{v}\n\xff-remove"
        second_path = os.fsencode(self.root) + b"/held"
        paths_file = self.root / "paths.bin"
        paths_file.write_bytes(raw_path + b"\0" + second_path + b"\0")
        results = scratch_qualify_batch.qualify_paths(
            [raw_path, second_path], str(self.fake_diskm()), jobs=2, timeout_seconds=2
        )

        self.assertEqual([result["index"] for result in results], [0, 1])
        self.assertEqual([result["path_bytes_hex"] for result in results],
                         [raw_path.hex(), second_path.hex()])
        self.assertEqual([result["verdict"] for result in results],
                         ["remove", "kept:recent-activity"])
        self.assertEqual([result["returncode"] for result in results], [0, 0])

    def test_public_dispatch_preserves_placeholder_like_path_as_json(self):
        raw_path = os.fsencode(self.root) + b"/literal-<$>{v}-remove"
        paths_file = self.root / "paths.bin"
        paths_file.write_bytes(raw_path + b"\0")
        environment = dict(os.environ)
        environment["DISK_MAGICIAN_QUARANTINE_VERDICT_BIN"] = str(self.fake_diskm())
        result = subprocess.run(
            ["bash", str(ROOT / "disk_magician.sh"), "quarantine", "scratch-qualify",
             "--paths-from", str(paths_file), "--jobs", "2", "--timeout-seconds", "2"],
            env=environment, capture_output=True, text=True, timeout=5, check=False,
        )

        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["path_bytes_hex"], raw_path.hex())
        self.assertEqual(rows[0]["verdict"], "remove")

    def test_cli_emits_a_deferred_result_when_global_deadline_expires(self):
        executable = self.fake_diskm()
        paths_file = self.root / "paths.bin"
        paths_file.write_bytes(os.fsencode(self.root / "slow") + b"\0" +
                               os.fsencode(self.root / "later-remove") + b"\0")
        environment = dict(os.environ)
        environment["DISK_MAGICIAN_QUARANTINE_VERDICT_BIN"] = str(executable)
        started = __import__("time").monotonic()
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "scratch_qualify_batch.py"),
             "--paths-from", str(paths_file), "--jobs", "1", "--timeout-seconds", "0.1"],
            env=environment, capture_output=True, text=True, timeout=2, check=False,
        )
        elapsed = __import__("time").monotonic() - started

        rows = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row["index"] for row in rows], [0, 1])
        self.assertEqual([row["verdict"] for row in rows],
                         ["deferred:deadline", "deferred:deadline"])
        self.assertLess(elapsed, 1)

    def test_paths_file_rejects_relative_and_empty_entries(self):
        paths_file = self.root / "invalid.bin"
        for content in (b"relative/path\0", b"/tmp/one\0\0/tmp/two\0"):
            with self.subTest(content=content):
                paths_file.write_bytes(content)
                with self.assertRaises(ValueError):
                    scratch_qualify_batch.read_paths(paths_file)


if __name__ == "__main__":
    unittest.main()
