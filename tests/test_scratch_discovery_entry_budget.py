import io
import os
import stat
import sys
import unittest
from pathlib import Path
from contextlib import nullcontext
from types import SimpleNamespace
from unittest.mock import patch

import scripts.lib.scratch_budget_artifact_children as discovery


class FakeDirEntry:
    def __init__(self, path, mode, device):
        self.path = path
        self.name = os.path.basename(path)
        self.mode = mode
        self.device = device

    def is_dir(self, *, follow_symlinks):
        assert not follow_symlinks
        return stat.S_ISDIR(self.mode)

    def stat(self, *, follow_symlinks):
        assert not follow_symlinks
        return SimpleNamespace(st_mode=self.mode, st_dev=self.device)


class ScandirFixture:
    def __init__(self, root, device):
        self.root = root
        self.device = device

    def __call__(self, path):
        if path == self.root:
            def entries():
                for index in range(100_000):
                    yield FakeDirEntry(os.path.join(path, f"file-{index:06}.dat"), stat.S_IFREG, self.device)
                yield FakeDirEntry(os.path.join(path, "candidate-after-100k"), stat.S_IFDIR, self.device)
            return nullcontext(entries())
        return nullcontext(iter(()))


class ScratchDiscoveryBudgetTests(unittest.TestCase):
    def test_generic_discovery_reaches_candidate_after_100000_entries(self):
        root_path = Path(__file__).resolve().parents[1]
        root = str(root_path / "synthetic-scratch-root")
        device = os.lstat(root_path).st_dev
        real_lstat = os.lstat

        def lstat(path):
            if path == root:
                return real_lstat(root_path)
            raise FileNotFoundError(path)

        stdout = SimpleNamespace(buffer=io.BytesIO())
        stdin = SimpleNamespace(buffer=io.BytesIO(os.fsencode(root) + b"\0"))
        argv = [str(discovery.__file__), "batch-generic", "3", ""]
        with (patch.object(discovery.os, "scandir", ScandirFixture(root, device)),
              patch.object(discovery.os, "lstat", lstat),
              patch.object(sys, "stdin", stdin),
              patch.object(sys, "stdout", stdout),
              patch.object(sys, "argv", argv)):
            result = discovery.main()

        self.assertEqual(result, 0)
        records = stdout.buffer.getvalue().split(b"\0")
        self.assertEqual(records[0], discovery.MARKER)
        self.assertEqual(int(records[1]), 1)
        self.assertEqual(records[2], os.fsencode(root))
        self.assertEqual(records[3], os.fsencode(root + "/candidate-after-100k"))
        self.assertEqual(records[-1], b"")


if __name__ == "__main__":
    unittest.main()
