import errno
import pathlib
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import disk_frontier_scan as frontier  # noqa: E402


class _FakeScandirCM:
    def __init__(self, entries, raise_on_iter=None):
        self._entries = entries
        self._raise_on_iter = raise_on_iter

    def __enter__(self):
        return self._iter()

    def __exit__(self, exc_type, exc, tb):
        return False

    def _iter(self):
        for entry in self._entries:
            yield entry
        if self._raise_on_iter is not None:
            raise self._raise_on_iter


class TestListChildrenEintrRetry(unittest.TestCase):
    def test_list_children_retries_scandir_on_eintr_and_succeeds(self):
        entry = SimpleNamespace(
            path="/System/Volumes/Data/Users/jleechan/Library/Containers/com.apple.photoanalysisd/Data/tmp/item",
            is_symlink=mock.Mock(return_value=False),
        )
        calls = []

        def fake_scandir(path):
            calls.append(path)
            if len(calls) == 1:
                raise OSError(errno.EINTR, "Interrupted system call")
            return _FakeScandirCM([entry])

        unfinished = []
        with mock.patch.object(frontier.os, "scandir", side_effect=fake_scandir):
            children, err = frontier.list_children(
                "/System/Volumes/Data/Users/jleechan/Library/Containers/com.apple.photoanalysisd/Data/tmp",
                unfinished=unfinished,
            )

        self.assertIsNone(err)
        self.assertEqual(children, [(entry.path, False)])
        self.assertEqual(unfinished, [])
        self.assertEqual(len(calls), 2)

    def test_list_children_retries_mid_iteration_eintr_without_duplicates(self):
        entry1 = SimpleNamespace(path="/fixture/a", is_symlink=mock.Mock(return_value=False))
        entry2 = SimpleNamespace(path="/fixture/b", is_symlink=mock.Mock(return_value=True))
        calls = []

        def fake_scandir(path):
            calls.append(path)
            if len(calls) == 1:
                return _FakeScandirCM(
                    [entry1],
                    raise_on_iter=OSError(errno.EINTR, "Interrupted system call"),
                )
            return _FakeScandirCM([entry1, entry2])

        unfinished = []
        with mock.patch.object(frontier.os, "scandir", side_effect=fake_scandir):
            children, err = frontier.list_children("/fixture", unfinished=unfinished)

        self.assertIsNone(err)
        self.assertEqual(children, [("/fixture/a", False), ("/fixture/b", True)])
        self.assertEqual(unfinished, [])
        self.assertEqual(len(calls), 2)

    def test_list_children_retries_is_symlink_on_eintr(self):
        is_symlink = mock.Mock(
            side_effect=[OSError(errno.EINTR, "Interrupted system call"), True]
        )
        entry = SimpleNamespace(path="/fixture/link", is_symlink=is_symlink)
        unfinished = []
        with mock.patch.object(
            frontier.os, "scandir", return_value=_FakeScandirCM([entry])
        ):
            children, err = frontier.list_children("/fixture", unfinished=unfinished)

        self.assertIsNone(err)
        self.assertEqual(children, [("/fixture/link", True)])
        self.assertEqual(unfinished, [])
        self.assertEqual(is_symlink.call_count, 2)

    def test_list_children_preserves_fallback_after_exhausting_eintr_retries(self):
        with mock.patch.object(
            frontier.os,
            "scandir",
            side_effect=OSError(errno.EINTR, "Interrupted system call"),
        ) as mocked_scandir:
            children, err = frontier.list_children("/fixture")

        self.assertIsNone(children)
        self.assertEqual(err, f"enumeration_errno_{errno.EINTR}")
        self.assertEqual(mocked_scandir.call_count, 3)


if __name__ == "__main__":
    unittest.main()
