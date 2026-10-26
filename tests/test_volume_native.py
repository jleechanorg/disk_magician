import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("volume_native", ROOT / "scripts" / "volume.py")
volume = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = volume
spec.loader.exec_module(volume)


class NativeFstabPublicCliTest(unittest.TestCase):
    def setUp(self):
        self.previous = {key: os.environ.get(key) for key in ("DISK_MAGICIAN_CONFIG", "DISK_MAGICIAN_STATE_DIR")}
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.image = self.root / "scratch.ext4"
        self.mountpoint = self.root / "Scratch"
        self.state = self.root / "state"
        self.config = self.root / "config.json"
        self.fstab = self.root / "etc-fstab"
        self.mountpoint.mkdir(mode=0o700)
        self.state.mkdir(mode=0o700)
        self.image.write_bytes(b"fixture")
        self.config.write_text(json.dumps({"volumes": {
            "swap_headroom_gb": 40,
            "alarm_floor_gb": 20,
            "encryption": "none",
            "encryption_acknowledged_at": "2026-10-26T00:00:00Z",
            "classes": {"scratch": {
                "name": "diskm-scratch",
                "quota_gb": 2,
                "mountpoint": str(self.mountpoint),
                "image_path": str(self.image),
            }},
        }}))
        self.original_fstab = b"# preserve this unrelated entry\n/dev/example /example ext4 defaults 0 2\n"
        self.fstab.write_bytes(self.original_fstab)
        os.environ["DISK_MAGICIAN_CONFIG"] = str(self.config)
        os.environ["DISK_MAGICIAN_STATE_DIR"] = str(self.state)
        self.addCleanup(self.restore_environment)

    def restore_environment(self):
        for key, value in self.previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_unrelated_image_and_mount_are_rejected_before_fstab_write(self):
        document = json.loads(self.config.read_text())
        scratch = document["volumes"]["classes"]["scratch"]
        scratch["image_path"] = str(self.root.parent / "unrelated.ext4")
        scratch["mountpoint"] = str(self.root.parent / "unrelated-mount")
        self.config.write_text(json.dumps(document))
        args = [
            "fstab", "install", "scratch",
            "--config", str(self.config),
            "--state-dir", str(self.state),
            "--user-uid", str(os.getuid()),
            "--fixture-root", str(self.root),
            "--execute",
        ]
        with mock.patch.object(volume.sys, "platform", "linux"), \
             mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab, create=True), \
             mock.patch.object(volume.subprocess, "run") as run:
            self.assertEqual(volume.main(args), 75)
            run.assert_not_called()
        self.assertEqual(self.fstab.read_bytes(), self.original_fstab)

    def test_preview_install_remove_round_trip_preserves_unrelated_bytes(self):
        base = ["scratch", "--config", str(self.config), "--state-dir", str(self.state),
                "--user-uid", str(os.getuid()), "--fixture-root", str(self.root)]
        with (
            mock.patch.object(volume.sys, "platform", "linux"),
            mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
        ):
            self.assertEqual(volume.main(["fstab", "preview", *base]), 0)
            self.assertEqual(self.fstab.read_bytes(), self.original_fstab)
            with mock.patch.object(volume.os, "geteuid", return_value=0):
                self.assertEqual(volume.main(["fstab", "install", *base, "--execute"]), 0)
                installed = self.fstab.read_bytes()
                self.assertTrue(installed.startswith(self.original_fstab))
                self.assertIn(b"ext4 loop,user,noauto,nosuid,nodev,noatime,exec 0 0", installed)
                self.assertEqual(volume.main(["fstab", "remove", *base, "--execute"]), 0)
            self.assertEqual(self.fstab.read_bytes(), self.original_fstab)

    def test_remove_refuses_live_loop_mapping_and_writer(self):
        base = ["scratch", "--config", str(self.config), "--state-dir", str(self.state),
                "--user-uid", str(os.getuid()), "--fixture-root", str(self.root)]
        block = volume.linux_fstab_block(str(os.getuid()), self.config, self.state,
                                         self.image, self.mountpoint)
        self.fstab.write_bytes(self.original_fstab + block)
        with (
            mock.patch.object(volume.sys, "platform", "linux"),
            mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=True),
            mock.patch.object(volume.os, "geteuid", return_value=0),
        ):
            self.assertEqual(volume.main(["fstab", "remove", *base, "--execute"]), 75)
        self.assertEqual(self.fstab.read_bytes(), self.original_fstab + block)

    def test_fstab_write_preserves_mode_and_restores_after_bad_readback(self):
        self.fstab.chmod(0o640)
        original = self.fstab.read_bytes()
        with mock.patch.object(volume.os, "geteuid", return_value=0):
            with mock.patch.object(volume.Path, "read_bytes", autospec=True) as read_bytes:
                read_bytes.side_effect = [b"corrupt", b"corrupt"]
                with self.assertRaises(OSError):
                    volume.linux_fstab_write(self.fstab, original, b"replacement")
        self.assertEqual(self.fstab.read_bytes(), original)
        self.assertEqual(self.fstab.stat().st_mode & 0o777, 0o640)
        backup = self.fstab.with_name(self.fstab.name + ".diskm-backup-" +
                                      volume.hashlib.sha256(original).hexdigest()[:16])
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o640)

    def test_duplicate_managed_markers_fail_closed(self):
        block = volume.linux_fstab_block(str(os.getuid()), self.config, self.state,
                                         self.image, self.mountpoint)
        with self.assertRaises(ValueError):
            volume.linux_fstab_transform(block + block, block, self.image,
                                         self.mountpoint, "remove")

    def test_conflicting_unmarked_entry_is_preserved_and_rejected(self):
        block = volume.linux_fstab_block(str(os.getuid()), self.config, self.state,
                                         self.image, self.mountpoint)
        conflict = self.original_fstab + f"{self.root}/other {self.mountpoint} ext4 defaults 0 2\n".encode()
        with self.assertRaisesRegex(ValueError, "conflicting unmanaged"):
            volume.linux_fstab_transform(conflict, block, self.image, self.mountpoint, "install")


if __name__ == "__main__":
    unittest.main()
