import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import quarantine_rename as q  # noqa: E402


class LsofStderrIncompleteTest(unittest.TestCase):
    """Codex #209 review: a `can't stat()` warning is only ignorable when the
    warned mount cannot contain the queried path."""

    QUERY = "/private/tmp/disk_magician/fixtures/x/.dm-quarantine/abc"

    def test_unrelated_mount_warning_is_ignorable(self):
        err = (
            b"lsof: WARNING: can't stat() tracefs file system /sys/kernel/tracing\n"
            b"Output information may be incomplete.\n"
        )
        self.assertFalse(q.lsof_stderr_incomplete(err, self.QUERY))

    def test_root_mount_warning_is_incomplete(self):
        # A warning about / could hide a user of any path.
        err = (
            b"lsof: WARNING: can't stat() apfs file system /\n"
            b"Output information may be incomplete.\n"
        )
        self.assertTrue(q.lsof_stderr_incomplete(err, self.QUERY))

    def test_query_ancestor_mount_warning_is_incomplete(self):
        err = b"lsof: WARNING: can't stat() fuse file system /private/tmp\n"
        self.assertTrue(q.lsof_stderr_incomplete(err, self.QUERY))

    def test_mount_path_with_spaces_is_relevant(self):
        # A mount path may contain spaces; the parser must capture the whole path.
        err = b"lsof: WARNING: can't stat() fuse file system /mnt/my disk\n"
        self.assertTrue(q.lsof_stderr_incomplete(err, "/mnt/my disk/sub/.dm-quarantine/abc"))

    def test_unknown_stderr_is_incomplete(self):
        self.assertTrue(q.lsof_stderr_incomplete(b"lsof: some other error\n", self.QUERY))

    def test_fsless_cant_stat_warning_is_incomplete(self):
        self.assertTrue(q.lsof_stderr_incomplete(b"lsof: WARNING: can't stat()\n", self.QUERY))

    def test_empty_stderr_is_complete(self):
        self.assertFalse(q.lsof_stderr_incomplete(b"", self.QUERY))


if __name__ == "__main__":
    unittest.main()
