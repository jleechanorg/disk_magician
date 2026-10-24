"""Regression tests: a failed quarantine rename names its errno (bead disk_magician-273z).

Before this, `quarantine_rename.py phase1` collapsed every `renamex` failure
into the single string `kept:rename-failed`, so a caller could only report a
generic "rm failed" and no one could tell EXDEV from EPERM, EACCES or ENOSPC.
"""
import errno
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RENAME_PY = ROOT / "scripts" / "quarantine_rename.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("quarantine_rename_under_test", RENAME_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestQuarantineRenameErrno(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp", prefix="dm-q-errno-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(os.path.realpath(self.tmp.name))
        self.qr = _load_module()

    def _prepare(self):
        """A real candidate plus the parent binding + inventory phase1 expects."""
        candidate = self.root / "pr240_after_api.json"
        candidate.write_text("stale pr scratch\n", encoding="utf-8")
        st = os.lstat(candidate)
        binding_file = self.root / "binding.json"
        self.qr.bind_parent(str(candidate), str(binding_file))
        inv_file = self.root / "inventory.json"
        inv_file.write_text(
            json.dumps([{"path": ".", "type": "file", "dev": st.st_dev, "ino": st.st_ino,
                         "size": st.st_size, "sha256": "0" * 64}]),
            encoding="utf-8",
        )
        return candidate, inv_file, binding_file

    def _phase1_with_rename_error(self, exc):
        candidate, inv_file, binding_file = self._prepare()
        original_renamex = self.qr.renamex

        def boom(*_args, **_kwargs):
            raise exc

        self.qr.renamex = boom
        try:
            verdict = self.qr.phase1(str(candidate), str(inv_file), str(binding_file))
        finally:
            self.qr.renamex = original_renamex
        return candidate, verdict

    def test_exdev_rename_failure_names_exdev(self):
        candidate, verdict = self._phase1_with_rename_error(OSError(errno.EXDEV, "Cross-device link"))
        self.assertEqual(verdict, "kept:rename-failed:EXDEV")
        # Fail-closed: the artifact is untouched and no quarantine entry survives.
        self.assertTrue(candidate.exists(), "candidate must survive a failed rename")
        self.assertFalse((self.root / ".dm-quarantine" / "index.json").exists())

    def test_perm_rename_failure_names_eperm(self):
        candidate, verdict = self._phase1_with_rename_error(OSError(errno.EPERM, "Operation not permitted"))
        self.assertEqual(verdict, "kept:rename-failed:EPERM")
        self.assertTrue(candidate.exists())

    def test_no_space_rename_failure_names_enospc(self):
        candidate, verdict = self._phase1_with_rename_error(OSError(errno.ENOSPC, "No space left on device"))
        self.assertEqual(verdict, "kept:rename-failed:ENOSPC")
        self.assertTrue(candidate.exists())

    def test_missing_exclusive_symbol_stays_its_own_verdict(self):
        candidate, verdict = self._phase1_with_rename_error(LookupError())
        self.assertEqual(verdict, "kept:exclusive_rename_unavailable")
        self.assertTrue(candidate.exists())

    def test_verdict_still_classifies_as_a_removal_failure_prefix(self):
        """Callers key off the kept: prefix; the errno suffix must not break that."""
        _, verdict = self._phase1_with_rename_error(OSError(errno.EXDEV, "Cross-device link"))
        self.assertTrue(verdict.startswith("kept:rename-failed"))
        self.assertNotEqual(verdict, "kept:rename-failed", "the errno must be present")


if __name__ == "__main__":
    unittest.main()
