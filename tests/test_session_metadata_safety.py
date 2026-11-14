#!/usr/bin/env python3
"""Read-only metadata does not turn session internals into disposable units."""
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.prune_aside_sessions import get_dir_max_mtime, get_dir_size, parse_session_age_days
from scripts.cleanup_antigravity_brain import get_dir_mtime

class SessionMetadataSafety(unittest.TestCase):
    def test_old_name_with_fresh_descendant_is_recent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / '2000-01-01_old'
            path.mkdir()
            (path / 'fresh').write_text('active')
            os.utime(path, (1, 1))
            age, _ = parse_session_age_days(path)
            self.assertLess(age, 1)

    def test_symlink_is_not_followed_and_recency_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / 'session'
            session.mkdir()
            target = root / 'outside'
            target.write_bytes(b'x' * 4096)
            link = session / 'link'
            link.symlink_to(target)
            self.assertEqual(get_dir_size(session), link.lstat().st_size)
            self.assertEqual(get_dir_max_mtime(session), float('inf'))
            self.assertEqual(get_dir_mtime(session), float('inf'))

    def test_nested_git_boundary_makes_session_size_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / 'repo'
            (repo / '.git').mkdir(parents=True)
            (repo / 'source.py').write_text('preserve')
            with self.assertRaisesRegex(OSError, 'opaque/unmeasured'):
                get_dir_size(root)
            self.assertTrue((repo / 'source.py').exists())

    def test_hardlink_size_counted_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'first').write_bytes(b'x' * 1024)
            os.link(path / 'first', path / 'second')
            self.assertEqual(get_dir_size(path), 1024)

if __name__ == '__main__':
    unittest.main()
