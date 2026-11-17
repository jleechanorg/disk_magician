from __future__ import annotations

import os
import pathlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import scan_48h_every_file as s48  # noqa: E402


def _write_sized(path: pathlib.Path, size: int, mtime: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)
    os.utime(path, (mtime, mtime))


class TestScan48hEveryFile(unittest.TestCase):
    def test_byte_conservation_and_wholly_gt48h(self) -> None:
        cutoff = 1_700_000_000.0
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            old_dir = root / "old_only"
            mixed_dir = root / "mixed"
            _write_sized(old_dir / "a.bin", 4096, cutoff - 100.0)
            _write_sized(old_dir / "sub" / "b.bin", 2048, cutoff - 50.0)
            _write_sized(mixed_dir / "old.bin", 1024, cutoff - 10.0)
            _write_sized(mixed_dir / "fresh.bin", 3072, cutoff + 10.0)

            res = s48.scan_shards([(str(root), set())], cutoff, xdev=True, hardlink_bin_path=None)
            summary = res["summary"]
            self.assertEqual(summary["files"], 4)
            self.assertEqual(summary["gt48h_files"], 3)
            self.assertEqual(summary["le48h_files"], 1)
            self.assertEqual(summary["apparent_bytes"], 4096 + 2048 + 1024 + 3072)
            self.assertEqual(summary["gt48h_apparent_bytes"] + summary["le48h_apparent_bytes"], summary["apparent_bytes"])
            self.assertEqual(summary["gt48h_alloc_bytes"] + summary["le48h_alloc_bytes"], summary["alloc_bytes"])

            by_path = {d["path"]: d for d in res["dirs_ge_100m"]}
            root_rec = by_path[s48.display_path(os.path.abspath(root))]
            self.assertFalse(root_rec["wholly_gt48h"])

            # old_only is maximal wholly_gt48h (under 25 MiB threshold -> counted in small_maximal_wholly_gt48h)
            self.assertEqual(summary["small_maximal_wholly_gt48h_lt25m_count"], 1)
            self.assertEqual(summary["small_maximal_wholly_gt48h_lt25m_apparent_bytes"], 4096 + 2048)

            # Verify wholly_gt48h=True when entire root is >48h
            res_old = s48.scan_shards([(str(old_dir), set())], cutoff, xdev=True, hardlink_bin_path=None)
            old_root_rec = res_old["dirs_ge_100m"][0]
            self.assertTrue(old_root_rec["wholly_gt48h"])
            self.assertEqual(res_old["summary"]["le48h_files"], 0)

    def test_git_interior_attribution(self) -> None:
        cutoff = 1_700_000_000.0
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            pack = root / ".git" / "objects" / "pack" / "pack-abc.pack"
            _write_sized(pack, 8192, cutoff - 500.0)
            _write_sized(root / "README.md", 128, cutoff + 500.0)

            res = s48.scan_shards([(str(root), set())], cutoff, xdev=True, hardlink_bin_path=None)
            summary = res["summary"]
            self.assertEqual(summary["files"], 2)
            self.assertEqual(summary["gt48h_files"], 1)
            self.assertEqual(summary["gt48h_apparent_bytes"], 8192)
            self.assertEqual(summary["le48h_files"], 1)
            self.assertEqual(summary["le48h_apparent_bytes"], 128)

    def test_hardlink_dedup_and_sidecar(self) -> None:
        cutoff = 1_700_000_000.0
        with tempfile.TemporaryDirectory() as td, tempfile.TemporaryDirectory() as hl_td:
            root = pathlib.Path(td)
            f1 = root / "first.bin"
            f2 = root / "second.bin"
            hl_bin = pathlib.Path(hl_td) / "out.hl"
            _write_sized(f1, 16384, cutoff - 200.0)
            os.link(f1, f2)

            res = s48.scan_shards([(str(root), set())], cutoff, xdev=True, hardlink_bin_path=hl_bin)
            summary = res["summary"]
            self.assertEqual(summary["files"], 2)
            self.assertEqual(summary["apparent_bytes"], 16384)
            self.assertEqual(summary["unique_multilink_inodes_in_shard"], 1)
            self.assertGreaterEqual(summary["raw_alloc_bytes"], summary["alloc_bytes"] * 2 if summary["alloc_bytes"] else 0)

            raw = hl_bin.read_bytes()
            rec_size = struct.calcsize("<QQQQd")
            self.assertEqual(len(raw), rec_size)
            dev, ino, _raw_al, raw_ap, mt = struct.unpack("<QQQQd", raw)
            st = os.lstat(f1)
            self.assertEqual((dev, ino), (st.st_dev, st.st_ino))
            self.assertEqual(raw_ap, 16384)
            self.assertAlmostEqual(mt, cutoff - 200.0, places=2)

    def test_latest_file_and_latest_mtime_propagation(self) -> None:
        cutoff = 1_700_000_000.0
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            _write_sized(root / "top_old.txt", 100, cutoff - 1000.0)
            newest = root / "a" / "b" / "newest.txt"
            _write_sized(newest, 100, cutoff + 250.0)
            _write_sized(root / "a" / "mid.txt", 100, cutoff + 50.0)

            res = s48.scan_shards([(str(root), set())], cutoff, xdev=True, hardlink_bin_path=None)
            root_rec = res["dirs_ge_100m"][0]
            self.assertEqual(root_rec["latest_file"], s48.display_path(os.path.abspath(newest)))
            self.assertAlmostEqual(root_rec["latest_mtime"], round(cutoff + 250.0, 3), places=2)

    def test_xdev_skips_cross_device_mountpoint(self) -> None:
        cutoff = 1_700_000_000.0
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td).resolve()
            mnt = root / "mnt"
            mnt.mkdir()
            _write_sized(root / "local.txt", 512, cutoff - 10.0)
            _write_sized(mnt / "remote.txt", 4096, cutoff - 10.0)

            real_dev = os.lstat(root).st_dev
            fake_other_dev = real_dev + 999

            class FakeEntry:
                def __init__(self, real_entry: os.DirEntry) -> None:
                    self._e = real_entry
                    self.name = real_entry.name
                    self.path = real_entry.path

                def stat(self, follow_symlinks: bool = False) -> os.stat_result:
                    st = self._e.stat(follow_symlinks=follow_symlinks)
                    if self.name == "mnt" and stat.S_ISDIR(st.st_mode):
                        vals = list(st)
                        vals[stat.ST_DEV] = fake_other_dev
                        return os.stat_result(vals)
                    return st

            real_scandir = os.scandir

            class FakeScandir:
                def __init__(self, path: str) -> None:
                    self._ctx = real_scandir(path)

                def __enter__(self):
                    entries = self._ctx.__enter__()
                    return [FakeEntry(e) for e in entries]

                def __exit__(self, *args):
                    return self._ctx.__exit__(*args)

            with mock.patch("scan_48h_every_file.os.scandir", side_effect=lambda p: FakeScandir(p)):
                res = s48.scan_shards([(str(root), set())], cutoff, xdev=True, hardlink_bin_path=None)

            self.assertEqual(res["summary"]["files"], 1)
            self.assertEqual(res["summary"]["apparent_bytes"], 512)
            self.assertEqual(res["summary"]["skipped_mountpoints"], [str(mnt)])

    def test_cli_dispatch_help(self) -> None:
        proc = subprocess.run(
            ["bash", str(REPO_ROOT / "disk_magician.sh"), "scan-48h", "--help"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("--cutoff-hours", proc.stdout)
        self.assertIn("--cutoff-epoch", proc.stdout)
        self.assertIn("--spec", proc.stdout)
        self.assertIn("--out-json", proc.stdout)


if __name__ == "__main__":
    unittest.main()
