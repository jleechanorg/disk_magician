import errno
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("volume_native", ROOT / "scripts" / "volume.py")
volume = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = volume
spec.loader.exec_module(volume)


class NativeFstabPublicCliTest(unittest.TestCase):
    def setUp(self):
        # This class drives fake Linux paths. macOS lacks os.listxattr; provide
        # an empty fake-filesystem result only when the host API is absent.
        if not hasattr(volume.os, "listxattr"):
            self.fake_listxattr = mock.patch.object(volume.os, "listxattr", create=True, return_value=[])
            self.fake_listxattr.start()
            self.addCleanup(self.fake_listxattr.stop)
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
        self.runtime = self.root / "runtime"
        (self.runtime / "scripts").mkdir(mode=0o700, parents=True)
        (self.runtime / "systemd").mkdir(mode=0o700)
        (self.runtime / "disk_magician.sh").write_text("#!/bin/sh\\n")
        source_template = Path(volume.__file__).resolve().parent.parent / "systemd/diskm-scratch.service.in"
        (self.runtime / "systemd/diskm-scratch.service.in").write_bytes(source_template.read_bytes())
        self.runtime_script = self.runtime / "scripts/volume.py"
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

    def create_prior_candidate(self):
        prior_runtime = self.root / ".local/share/disk-magician/candidates" / ("a" * 40)
        (prior_runtime / "systemd").mkdir(mode=0o700, parents=True)
        (prior_runtime / "disk_magician.sh").write_text("#!/bin/sh\n")
        template = self.runtime / "systemd/diskm-scratch.service.in"
        (prior_runtime / "systemd/diskm-scratch.service.in").write_bytes(template.read_bytes())
        return prior_runtime

    def run_fixture_fstab(self, action):
        base = [action, "scratch", "--config", str(self.config), "--state-dir", str(self.state),
                "--user-uid", str(os.getuid()), "--fixture-root", str(self.root), "--execute"]
        with (
            mock.patch.object(volume.sys, "platform", "linux"),
            mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab),
            mock.patch.object(volume, "linux_fstab_lock_path", return_value=self.root / "fstab.lock"),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume.os, "geteuid", return_value=0),
        ):
            return volume.main(["fstab", *base])

    def test_public_fstab_dispatch_rejects_wrong_owner_on_intermediate_path(self):
        home = self.root / "isolated-home"
        config = home / ".config/disk-magician/linux-scratch.json"
        state = home / ".disk_magician_state"
        image = home / ".local/share/disk-magician/volumes/scratch.ext4"
        mountpoint = home / "Scratch"
        config.parent.mkdir(mode=0o700, parents=True)
        state.mkdir(mode=0o700, parents=True)
        image.parent.mkdir(mode=0o700, parents=True)
        image.write_bytes(b"fixture")
        mountpoint.mkdir(mode=0o700)
        config.write_text(json.dumps({"volumes": {"classes": {"scratch": {
            "image_path": str(image), "mountpoint": str(mountpoint)}}}}))
        original = self.fstab.read_bytes()
        unsafe_parent = home / ".local/share/disk-magician"
        original_lstat = Path.lstat

        def wrong_owner(path):
            result = original_lstat(path)
            if path == unsafe_parent:
                values = list(result)
                values[4] = os.getuid() + 1
                return os.stat_result(values)
            return result

        args = ["fstab", "install", "scratch", "--config", str(config),
                "--state-dir", str(state), "--user-uid", str(os.getuid()), "--execute"]
        with (
            mock.patch.object(volume.sys, "platform", "linux"),
            mock.patch.object(volume.pwd, "getpwuid", return_value=mock.Mock(pw_dir=str(home))),
            mock.patch.object(volume, "linux_fstab_path") as fstab_path,
            mock.patch.object(volume, "linux_fstab_lock") as fstab_lock,
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
            mock.patch.object(Path, "lstat", new=wrong_owner),
            mock.patch.object(volume.os, "geteuid", return_value=0),
            mock.patch.object(volume.subprocess, "run") as run,
        ):
            self.assertEqual(volume.main(args), 75)
        self.assertEqual(self.fstab.read_bytes(), original)
        run.assert_not_called()
        fstab_lock.assert_not_called()
        fstab_path.assert_not_called()

    def test_fstab_write_refuses_extended_attributes_before_backup_or_write(self):
        original = self.fstab.read_bytes()
        details = self.fstab.stat()
        try:
            os.setxattr(self.fstab, "user.diskm-test", b"metadata")
        except (AttributeError, OSError) as error:
            self.skipTest("user extended attributes unavailable: " + str(error))
        backup = self.fstab.with_name(self.fstab.name + ".diskm-backup-" +
                                      volume.hashlib.sha256(original).hexdigest()[:16])
        with mock.patch.object(volume.os, "geteuid", return_value=0):
            with self.assertRaises(OSError):
                volume.linux_fstab_write(self.fstab, original, original + b"# replacement\n")
        self.assertEqual(self.fstab.read_bytes(), original)
        restored = self.fstab.stat()
        self.assertEqual((restored.st_mode, restored.st_uid, restored.st_gid, restored.st_mtime_ns),
                         (details.st_mode, details.st_uid, details.st_gid, details.st_mtime_ns))
        self.assertEqual(os.getxattr(self.fstab, "user.diskm-test"), b"metadata")
        self.assertFalse(backup.exists())
        self.assertEqual(list(self.root.glob(".fstab-diskm-*")), [])

    def test_fstab_write_refuses_missing_xattr_enumerator_before_backup_or_write(self):
        original = self.fstab.read_bytes()
        details = self.fstab.stat()
        backup = self.fstab.with_name(self.fstab.name + ".diskm-backup-" +
                                      volume.hashlib.sha256(original).hexdigest()[:16])
        with mock.patch.object(volume.os, "geteuid", return_value=0), \
             mock.patch.object(volume.os, "listxattr", create=True, return_value=[]):
            delattr(volume.os, "listxattr")
            with self.assertRaises(OSError):
                volume.linux_fstab_write(self.fstab, original, original + b"# replacement\n")
        self.assertEqual(self.fstab.read_bytes(), original)
        restored = self.fstab.stat()
        self.assertEqual((restored.st_mode, restored.st_uid, restored.st_gid, restored.st_mtime_ns),
                         (details.st_mode, details.st_uid, details.st_gid, details.st_mtime_ns))
        self.assertFalse(backup.exists())
        self.assertEqual(list(self.root.glob(".fstab-diskm-*")), [])

    def test_fstab_write_refuses_xattr_enumeration_error_without_effects(self):
        original = self.fstab.read_bytes()
        details = self.fstab.stat()
        backup = self.fstab.with_name(self.fstab.name + ".diskm-backup-" +
                                      volume.hashlib.sha256(original).hexdigest()[:16])
        with (
            mock.patch.object(volume.os, "geteuid", return_value=0),
            mock.patch.object(volume.os, "listxattr", side_effect=OSError("metadata unavailable")),
        ):
            with self.assertRaises(OSError):
                volume.linux_fstab_write(self.fstab, original, original + b"# replacement\n")
        self.assertEqual(self.fstab.read_bytes(), original)
        restored = self.fstab.stat()
        self.assertEqual((restored.st_mode, restored.st_uid, restored.st_gid, restored.st_mtime_ns),
                         (details.st_mode, details.st_uid, details.st_gid, details.st_mtime_ns))
        self.assertFalse(backup.exists())
        self.assertEqual(list(self.root.glob(".fstab-diskm-*")), [])

    def test_fstab_write_restores_original_when_readback_fails_twice(self):
        self.fstab.chmod(0o640)
        original = self.fstab.read_bytes()
        details = self.fstab.stat()
        block = volume.linux_fstab_block(str(os.getuid()), self.config, self.state,
                                         self.image, self.mountpoint)
        replacement = original + block
        read_bytes = Path.read_bytes

        def fail_target_read(path):
            if path == self.fstab:
                raise OSError(errno.EIO, "injected readback failure")
            return read_bytes(path)

        with (
            mock.patch.object(volume.os, "geteuid", return_value=0),
            mock.patch.object(Path, "read_bytes", new=fail_target_read),
        ):
            with self.assertRaises(OSError):
                volume.linux_fstab_write(self.fstab, original, replacement)
        self.assertEqual(read_bytes(self.fstab), original)
        restored = self.fstab.stat()
        self.assertEqual((restored.st_mode & 0o777, restored.st_uid, restored.st_gid,
                          restored.st_mtime_ns),
                         (details.st_mode & 0o777, details.st_uid, details.st_gid,
                          details.st_mtime_ns))

    def test_public_fstab_install_rejects_octal_escaped_conflicts_unchanged(self):
        for field in ("source", "target"):
            with self.subTest(field=field):
                escaped_image = str(self.image).replace("/", r"\057")
                escaped_mount = str(self.mountpoint).replace("/", r"\057")
                fields = [escaped_image, "/unrelated", "ext4", "defaults", "0", "2"]
                if field == "target":
                    fields = ["/unrelated", escaped_mount, "ext4", "defaults", "0", "2"]
                original = self.original_fstab + (" ".join(fields) + "\n").encode()
                self.fstab.write_bytes(original)
                self.assertEqual(self.run_fixture_fstab("install"), 75)
                self.assertEqual(self.fstab.read_bytes(), original)

    def test_public_fstab_install_preserves_existing_block_before_trailing_record(self):
        block = volume.linux_fstab_block(str(os.getuid()), self.config, self.state,
                                         self.image, self.mountpoint)
        original = self.original_fstab + block + b"/dev/trailing /trailing ext4 defaults 0 2\n"
        self.fstab.write_bytes(original)
        self.assertEqual(self.run_fixture_fstab("install"), 0)
        self.assertEqual(self.fstab.read_bytes(), original)

    def test_fstab_round_trip_preserves_eof_without_final_newline(self):
        original = b"# exact bytes\n/dev/example /example ext4 defaults 0 2"
        self.fstab.write_bytes(original)
        self.assertEqual(self.run_fixture_fstab("install"), 0)
        self.assertNotEqual(self.fstab.read_bytes(), original)
        self.assertEqual(self.run_fixture_fstab("remove"), 0)
        self.assertEqual(self.fstab.read_bytes(), original)

    def test_public_fstab_install_rejects_other_fixture_markers_unchanged(self):
        marker = b"a" * 64
        begin = b"# diskm-scratch:" + marker + b":begin\n"
        end = b"# diskm-scratch:" + marker + b":end\n"
        record = b"/other-image /other-mount ext4 loop,user,noauto,nosuid,nodev,noatime,exec 0 0\n"
        cases = {
            "orphan begin": self.original_fstab + begin,
            "duplicate pair": self.original_fstab + begin + record + end + begin + record + end,
            "mismatched pair": self.original_fstab + begin + record + b"# diskm-scratch:" + b"b" * 64 + b":end\n",
        }
        for label, original in cases.items():
            with self.subTest(case=label):
                self.fstab.write_bytes(original)
                self.assertEqual(self.run_fixture_fstab("install"), 75)
                self.assertEqual(self.fstab.read_bytes(), original)

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
            mock.patch.object(volume, "linux_fstab_lock_path", return_value=self.root / "fstab.lock"),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
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

    def test_fstab_install_reenters_root_only_after_allowlist_validation(self):
        runtime = self.root / "installed"
        (runtime / "scripts").mkdir(mode=0o700, parents=True)
        (runtime / "disk_magician.sh").write_text("#!/bin/sh\\n")
        script = runtime / "scripts/volume.py"
        base = ["scratch", "--config", str(self.config), "--state-dir", str(self.state),
                "--user-uid", str(os.getuid()), "--fixture-root", str(self.root), "--execute"]
        with (
            mock.patch.object(volume.sys, "platform", "linux"),
            mock.patch.object(volume, "__file__", str(script)),
            mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab),
            mock.patch.object(volume.os, "geteuid", return_value=os.getuid()),
            mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="ok\\n", stderr="")) as run,
        ):
            self.assertEqual(volume.main(["fstab", "install", *base]), 0)
        self.assertEqual(self.fstab.read_bytes(), self.original_fstab)
        self.assertEqual(run.call_args.args[0][:4], ["sudo", "-n", "bash", str(runtime / "disk_magician.sh")])

    def test_remove_refuses_live_loop_mapping_and_writer(self):
        base = ["scratch", "--config", str(self.config), "--state-dir", str(self.state),
                "--user-uid", str(os.getuid()), "--fixture-root", str(self.root)]
        block = volume.linux_fstab_block(str(os.getuid()), self.config, self.state,
                                         self.image, self.mountpoint)
        self.fstab.write_bytes(self.original_fstab + block)
        with (
            mock.patch.object(volume.sys, "platform", "linux"),
            mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab),
            mock.patch.object(volume, "linux_fstab_lock_path", return_value=self.root / "fstab.lock"),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=True),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume.os, "geteuid", return_value=0),
        ):
            self.assertEqual(volume.main(["fstab", "remove", *base, "--execute"]), 75)
        self.assertEqual(self.fstab.read_bytes(), self.original_fstab + block)

        with (
            mock.patch.object(volume.sys, "platform", "linux"),
            mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab),
            mock.patch.object(volume, "linux_fstab_lock_path", return_value=self.root / "fstab.lock"),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=True),
            mock.patch.object(volume.os, "geteuid", return_value=0),
        ):
            self.assertEqual(volume.main(["fstab", "remove", *base, "--execute"]), 75)
        self.assertEqual(self.fstab.read_bytes(), self.original_fstab + block)

    def test_fuser_permission_error_is_unknown_and_fails_closed(self):
        with mock.patch.object(volume.subprocess, "run",
                               return_value=mock.Mock(returncode=1, stdout=b"", stderr=b"Permission denied")):
            self.assertTrue(volume.linux_image_has_open_writers(self.image))

    def test_fuser_uses_linux_psmisc_compatible_arguments(self):
        with mock.patch.object(volume.subprocess, "run",
                               return_value=mock.Mock(returncode=1, stdout=b"", stderr=b"")) as run:
            self.assertFalse(volume.linux_image_has_open_writers(self.image))
        run.assert_called_once_with(["fuser", "-w", str(self.image)],
                                    capture_output=True, timeout=10, check=False)

    @unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("fuser"),
                         "requires the Linux PSmisc fuser binary")
    def test_linux_psmisc_fuser_no_writer_probe_accepts_real_fixture(self):
        self.assertFalse(volume.linux_image_has_open_writers(self.image))

    def test_concurrent_fixture_installs_both_survive(self):
        second = self.root / "second"
        second.mkdir(mode=0o700)
        state, mountpoint = second / "state", second / "Scratch"
        image, config = second / "scratch.ext4", second / "config.json"
        state.mkdir(mode=0o700)
        mountpoint.mkdir(mode=0o700)
        image.write_bytes(b"second fixture")
        config.write_text(json.dumps({"volumes": {
            "swap_headroom_gb": 40, "alarm_floor_gb": 20,
            "encryption": "none", "encryption_acknowledged_at": "ack",
            "classes": {"scratch": {"name": "diskm-scratch", "quota_gb": 2,
                "mountpoint": str(mountpoint), "image_path": str(image)}}}}))
        first_args = ["fstab", "install", "scratch", "--config", str(self.config),
            "--state-dir", str(self.state), "--user-uid", str(os.getuid()),
            "--fixture-root", str(self.root), "--execute"]
        second_args = ["fstab", "install", "scratch", "--config", str(config),
            "--state-dir", str(state), "--user-uid", str(os.getuid()),
            "--fixture-root", str(second), "--execute"]
        with (
            mock.patch.object(volume.sys, "platform", "linux"),
            mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab),
            mock.patch.object(volume, "linux_fstab_lock_path", return_value=self.root / "fstab.lock"),
            mock.patch.object(volume.os, "geteuid", return_value=0),
        ):
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(volume.main, (first_args, second_args)))
        self.assertEqual(results, [0, 0])
        actual = self.fstab.read_bytes()
        self.assertIn(str(self.mountpoint).encode(), actual)
        self.assertIn(str(mountpoint).encode(), actual)
        self.assertTrue(actual.startswith(self.original_fstab))

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

    def test_malformed_full_table_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "invalid fstab record"):
            volume.linux_fstab_validate(b"/dev/example /bad ext4 defaults\n")
        with self.assertRaisesRegex(ValueError, "invalid fstab record"):
            volume.linux_fstab_validate(b"/dev/example /bad\x01 ext4 defaults 0 2\n")

    def test_fixture_target_overlapping_state_is_rejected(self):
        document = json.loads(self.config.read_text())
        nested = self.state / "Scratch"
        nested.mkdir(mode=0o700)
        document["volumes"]["classes"]["scratch"]["mountpoint"] = str(nested)
        self.config.write_text(json.dumps(document))
        self.assertIsNone(volume.linux_fixture_paths(str(self.config), str(self.state),
                                                     str(os.getuid()), str(self.root)))

    def test_fstab_paths_with_backslash_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "fstab paths"):
            volume.linux_fstab_block(str(os.getuid()), self.config, self.state,
                                     self.image, self.root / "bad\\path")

    def test_native_identity_requires_exact_loop_device_and_matching_uuid(self):
        device = Path("/dev/loop42")
        fs_uuid = "12345678-1234-1234-1234-123456789abc"
        scratch = {"image_path": str(self.image), "mountpoint": str(self.mountpoint), "quota_gb": 1}
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": volume.GIB,
                 "filesystem_uuid": fs_uuid}
        with (
            mock.patch.object(volume.Path, "stat", return_value=mock.Mock(st_size=volume.GIB)),
            mock.patch.object(volume, "linux_loop_devices", return_value=[device]),
            mock.patch.object(volume, "linux_mount_record", return_value=("ext4", str(device))),
            mock.patch.object(volume, "linux_command", return_value=fs_uuid),
            mock.patch.object(volume, "linux_fs_uuid", return_value=fs_uuid),
        ):
            self.assertEqual(volume.linux_validate_native_mount({}, scratch, entry), fs_uuid)
        with mock.patch.object(volume, "linux_mount_record", return_value=("ext4", "/dev/loop43")):
            with self.assertRaisesRegex(ValueError, "identity"):
                volume.linux_validate_native_mount({}, scratch, entry)

    def test_mount_record_rejects_stacked_rows_for_target(self):
        rows = "".join(
            f"{mount_id} 1 0:42 / {self.mountpoint} rw - {fs_type} {source} rw\n"
            for mount_id, fs_type, source in (
                (100, "ext4", "/dev/loop42"),
                (101, "overlay", "overlay"),
            )
        )
        with mock.patch.object(Path, "read_text", return_value=rows):
            with self.assertRaisesRegex(ValueError, "ambiguous mountpoint"):
                volume.linux_mount_record(self.mountpoint)

    def test_ambiguous_native_mount_refuses_ballast_release_and_unmount(self):
        device = Path("/dev/loop42")
        with self.image.open("wb") as stream:
            stream.truncate(volume.GIB)
        scratch = {"backend": "native", "image_path": str(self.image),
                   "mountpoint": str(self.mountpoint), "quota_gb": 1}
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        reserve = volume.ballast_path(str(self.mountpoint))
        reserve.write_bytes(b"protected reserve")
        handle = mock.Mock()
        with (
            mock.patch.object(volume, "linux_backend_enabled", return_value=True),
            mock.patch.object(volume, "cls", return_value=({}, scratch)),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "locked_registry", return_value=(self.root / "registry", handle)),
            mock.patch.object(volume, "linux_paths", return_value=(self.image, self.mountpoint)),
            mock.patch.object(volume, "linux_loop_devices", return_value=[device]),
            mock.patch.object(volume, "linux_mount_record", side_effect=ValueError("ambiguous mountpoint")),
            mock.patch.object(volume, "linux_command") as command,
            mock.patch.object(volume, "log_ballast_release") as log_release,
        ):
            self.assertEqual(volume.ballast_cmd("release", "scratch"), 75)
            with self.assertRaisesRegex(ValueError, "ambiguous mountpoint"):
                volume.linux_native_unmount_cmd(scratch, entry)
        self.assertEqual(reserve.read_bytes(), b"protected reserve")
        command.assert_not_called()
        log_release.assert_not_called()
        handle.close.assert_called_once()

    def test_native_mount_refuses_open_writer_before_mount(self):
        scratch = {"image_path": str(self.image), "mountpoint": str(self.mountpoint), "quota_gb": 1}
        with (
            mock.patch.object(volume, "linux_paths", return_value=(self.image, self.mountpoint)),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=True),
            mock.patch.object(volume, "linux_validate_native_mount", return_value="12345678-1234-1234-1234-123456789abc"),
            mock.patch.object(volume, "linux_command") as command,
        ):
            result = volume.linux_native_mount_cmd(scratch, {"state": "active"})
        command.assert_not_called()
        self.assertEqual(result, 75)

    def test_native_mount_refuses_hardlinked_image_before_mount(self):
        alias = self.root / "scratch-alias.ext4"
        os.link(self.image, alias)
        scratch = {"image_path": str(self.image), "mountpoint": str(self.mountpoint), "quota_gb": 1}
        with (
            mock.patch.object(volume, "linux_paths", return_value=(self.image, self.mountpoint)),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume, "linux_validate_native_mount", return_value="12345678-1234-1234-1234-123456789abc"),
            mock.patch.object(volume, "linux_command") as command,
        ):
            result = volume.linux_native_mount_cmd(scratch, {"state": "active"})
        command.assert_not_called()
        self.assertEqual(result, 75)

    def test_native_mount_refuses_unavailable_image_metadata_before_mount(self):
        scratch = {"image_path": str(self.image), "mountpoint": str(self.mountpoint), "quota_gb": 1}
        original_stat = Path.stat
        def fail_image_stat(path, *args, **kwargs):
            if path == self.image:
                raise OSError("image metadata unavailable")
            return original_stat(path, *args, **kwargs)
        with (
            mock.patch.object(volume, "linux_paths", return_value=(self.image, self.mountpoint)),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume.Path, "stat", new=fail_image_stat),
            mock.patch.object(volume, "linux_command") as command,
        ):
            result = volume.linux_native_mount_cmd(scratch, {"state": "active"})
        command.assert_not_called()
        self.assertEqual(result, 75)

    def test_native_mount_keeps_existing_mount_identity_validation(self):
        scratch = {"image_path": str(self.image), "mountpoint": str(self.mountpoint), "quota_gb": 1}
        with (
            mock.patch.object(volume, "linux_paths", return_value=(self.image, self.mountpoint)),
            mock.patch.object(volume, "linux_mount_record", return_value=("ext4", "/dev/loop42")),
            mock.patch.object(volume, "linux_validate_native_mount", return_value="12345678-1234-1234-1234-123456789abc") as validate,
            mock.patch.object(volume, "linux_image_has_loop_mapping") as loop,
            mock.patch.object(volume, "linux_image_has_open_writers") as writers,
            mock.patch.object(volume, "linux_command") as command,
        ):
            self.assertEqual(volume.linux_native_mount_cmd(scratch, {"state": "active"}), 0)
        validate.assert_called_once()
        loop.assert_not_called()
        writers.assert_not_called()
        command.assert_not_called()

    def test_native_mount_rolls_back_only_the_exact_invalid_mount(self):
        device = Path("/dev/loop42")
        scratch = {"image_path": str(self.image), "mountpoint": str(self.mountpoint), "quota_gb": 1}
        with (
            mock.patch.object(volume, "linux_paths", return_value=(self.image, self.mountpoint)),
            mock.patch.object(volume, "linux_mount_record", side_effect=[None, ("ext4", str(device)), None]),
            mock.patch.object(volume, "linux_image_has_loop_mapping", side_effect=[False, False]),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume, "linux_loop_devices", return_value=[device]),
            mock.patch.object(volume, "linux_validate_native_mount", side_effect=ValueError("UUID mismatch")),
            mock.patch.object(volume, "linux_command", return_value="") as command,
        ):
            with self.assertRaisesRegex(ValueError, "UUID mismatch"):
                volume.linux_native_mount_cmd(scratch, {"state": "active"})
        self.assertEqual(command.call_args_list[0].args[0], ["mount", str(self.mountpoint)])
        self.assertEqual(command.call_args_list[1].args[0], ["umount", str(self.mountpoint)])

    def test_loop_backing_file_resolves_the_exact_kernel_device(self):
        backing = self.root / "sys/block/loop7/loop/backing_file"
        backing.parent.mkdir(mode=0o700, parents=True)
        backing.write_text(str(self.image) + "\n")
        with mock.patch.object(volume.Path, "glob", return_value=[backing]):
            self.assertEqual(volume.linux_loop_devices(self.image), [Path("/dev/loop7")])

    def test_busy_native_rollback_restores_captured_files_without_restarting_fuse(self):
        config_bytes = self.config.read_bytes()
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        prior_runtime = self.create_prior_candidate()
        unit_bytes = volume.linux_service_render(prior_runtime,
                                                  str(self.config), self.state, "fuse").encode()
        unit.write_bytes(unit_bytes)
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        settings, scratch = {"classes": {"scratch": {}}}, json.loads(config_bytes)["volumes"]["classes"]["scratch"]
        calls = []
        def command(args, timeout=30):
            if args[:2] == ["systemctl", "--user"]:
                calls.append(args[2])
            return ""
        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "cls", return_value=(settings, scratch)),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_validate_native_mount", side_effect=ValueError("forced native validation failure")),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", side_effect=[False, True]),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume, "linux_command", side_effect=command),
            mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=b'{"changed":true}')),
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 75)
        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(unit.read_bytes(), unit_bytes)
        self.assertEqual(calls, ["stop", "daemon-reload", "start", "stop", "daemon-reload"])

    def test_failed_rollback_stop_restores_exact_files_without_restarting_fuse(self):
        config_bytes = self.config.read_bytes()
        self.config.chmod(0o640)
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        prior_runtime = self.create_prior_candidate()
        unit_bytes = volume.linux_service_render(prior_runtime, str(self.config), self.state, "fuse").encode()
        unit.write_bytes(unit_bytes)
        unit.chmod(0o600)
        config_bytes = self.config.read_bytes()
        config_stat, unit_stat = self.config.stat(), unit.stat()
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        settings, scratch = {"classes": {"scratch": {}}}, json.loads(config_bytes)["volumes"]["classes"]["scratch"]
        calls = []

        def command(args, timeout=30):
            if args[:2] == ["systemctl", "--user"]:
                calls.append(args[2])
                if args[2] == "stop" and calls.count("stop") == 2:
                    raise RuntimeError("injected busy stop failure")
            return ""

        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "cls", return_value=(settings, scratch)),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_validate_native_mount", side_effect=ValueError("forced native validation failure")),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", side_effect=[False, True]),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume, "linux_command", side_effect=command),
            mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=b'{"changed":true}')),
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 75)

        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(unit.read_bytes(), unit_bytes)
        self.assertEqual((self.config.stat().st_mode & 0o777, self.config.stat().st_uid,
                          self.config.stat().st_gid, self.config.stat().st_mtime_ns),
                         (config_stat.st_mode & 0o777, config_stat.st_uid,
                          config_stat.st_gid, config_stat.st_mtime_ns))
        self.assertEqual((unit.stat().st_mode & 0o777, unit.stat().st_uid,
                          unit.stat().st_gid, unit.stat().st_mtime_ns),
                         (unit_stat.st_mode & 0o777, unit_stat.st_uid,
                          unit_stat.st_gid, unit_stat.st_mtime_ns))
        self.assertEqual(calls.count("start"), 1)
        self.assertEqual(calls[-1], "daemon-reload")

    def test_native_migration_rejects_modified_prior_candidate_unit_before_stop(self):
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        prior_runtime = self.create_prior_candidate()
        unit_bytes = volume.linux_service_render(prior_runtime, str(self.config), self.state, "fuse").encode()
        unit_bytes = unit_bytes.replace(b"RestartSec=5", b"RestartSec=6")
        unit.write_bytes(unit_bytes)
        config_bytes = self.config.read_bytes()
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "cls", return_value=({"classes": {"scratch": {}}}, json.loads(config_bytes)["volumes"]["classes"]["scratch"])),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_command") as command,
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 75)
        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(unit.read_bytes(), unit_bytes)
        command.assert_not_called()

    def test_migration_reconciles_fstab_install_failure_after_commit_and_timeout(self):
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        unit_bytes = volume.linux_service_render(self.runtime, str(self.config), self.state, "fuse").encode()
        unit.write_bytes(unit_bytes)
        config_bytes = self.config.read_bytes()
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        scratch = json.loads(config_bytes)["volumes"]["classes"]["scratch"]
        for failure in ("returncode", "timeout", "before_commit", "unknown_timeout"):
            with self.subTest(failure=failure):
                events = []

                def run(command, capture_output=False, timeout=45, check=False):
                    action = command[6]
                    self.assertEqual(command[4:6], ["volume", "fstab"])
                    events.append("fstab-" + action + "-begin")
                    if action == "install" and failure == "before_commit":
                        return mock.Mock(returncode=1, stdout=b'{"changed":true}')
                    before = self.fstab.read_bytes()
                    result = volume.linux_fstab_cmd(action, command[7:])
                    self.assertEqual(result, 0)
                    after = self.fstab.read_bytes()
                    events.append("fstab-" + action + "-complete")
                    receipt = json.dumps({"changed": before != after}).encode()
                    if action == "install":
                        if failure == "timeout":
                            raise volume.subprocess.TimeoutExpired(command, timeout, output=receipt)
                        if failure == "unknown_timeout":
                            raise volume.subprocess.TimeoutExpired(command, timeout)
                        return mock.Mock(returncode=1, stdout=receipt)
                    return mock.Mock(returncode=0, stdout=receipt)

                def command_hook(args, timeout=30):
                    if args[:2] == ["systemctl", "--user"]:
                        events.append(args[2])
                    return ""

                with (
                    mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
                    mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab),
                    mock.patch.object(volume, "linux_fstab_lock_path", return_value=self.root / "fstab.lock"),
                    mock.patch.object(volume, "cls", return_value=({"classes": {"scratch": {}}}, scratch)),
                    mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
                    mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
                    mock.patch.object(volume, "linux_mount_record", return_value=None),
                    mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
                    mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
                    mock.patch.object(volume, "linux_command", side_effect=command_hook),
                    mock.patch.object(volume.subprocess, "run", side_effect=run),
                    mock.patch.object(volume.os, "geteuid", side_effect=[os.getuid(), os.getuid(), 0, 0, os.getuid(), 0, 0]),
                    mock.patch.object(volume.Path, "home", return_value=self.root),
                    mock.patch.object(volume, "__file__", str(self.runtime_script)),
                ):
                    args = ["scratch", "--backend", "native", "--config", str(self.config),
                            "--state-dir", str(self.state), "--user-uid", str(os.getuid()), "--execute"]
                    self.assertEqual(volume.linux_service_migrate_cmd(args), 75)
                created_block = volume.linux_fstab_block(str(os.getuid()), self.config, self.state,
                                                         self.image, self.mountpoint)
                if failure == "unknown_timeout":
                    self.assertEqual(self.fstab.read_bytes(), self.original_fstab + created_block)
                    self.assertEqual(events.count("fstab-remove-complete"), 0)
                    self.assertNotIn("start", events)
                else:
                    self.assertEqual(self.fstab.read_bytes(), self.original_fstab)
                    self.assertEqual(events.count("fstab-remove-complete"), 1)
                    self.assertGreater(events.index("start"), events.index("fstab-remove-complete"))
                    self.assertEqual(events[-1], "start")
                self.assertEqual(self.config.read_bytes(), config_bytes)
                self.assertEqual(unit.read_bytes(), unit_bytes)
                self.assertEqual(events.count("fstab-install-complete"),
                                 0 if failure == "before_commit" else 1)
                self.fstab.write_bytes(self.original_fstab)

    def test_native_migration_rollback_preserves_preexisting_managed_fstab_block(self):
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        unit_bytes = volume.linux_service_render(self.runtime, str(self.config), self.state, "fuse").encode()
        unit.write_bytes(unit_bytes)
        config_bytes = self.config.read_bytes()
        block = volume.linux_fstab_block(str(os.getuid()), self.config, self.state,
                                         self.image, self.mountpoint)
        original_fstab = self.original_fstab + block + b"/dev/trailing /trailing ext4 defaults 0 2\n"
        self.fstab.write_bytes(original_fstab)
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        scratch = json.loads(config_bytes)["volumes"]["classes"]["scratch"]

        actions = []

        def run(command, capture_output=False, timeout=45, check=False):
            actions.append(command[6])
            before = self.fstab.read_bytes()
            result = volume.linux_fstab_cmd(command[6], command[7:])
            self.assertEqual(result, 0)
            return mock.Mock(returncode=0, stdout=json.dumps({"changed": self.fstab.read_bytes() != before}))

        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "linux_fstab_path", return_value=self.fstab),
            mock.patch.object(volume, "linux_fstab_lock_path", return_value=self.root / "fstab.lock"),
            mock.patch.object(volume, "cls", return_value=({"classes": {"scratch": {}}}, scratch)),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_validate_native_mount", side_effect=ValueError("forced post-install rollback")),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume, "linux_command", return_value=""),
            mock.patch.object(volume.subprocess, "run", side_effect=run),
            mock.patch.object(volume.os, "geteuid", side_effect=[os.getuid(), os.getuid(), 0, os.getuid(), 0, 0]),
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.getuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 75)
        self.assertEqual(self.fstab.read_bytes(), original_fstab)
        self.assertEqual(actions, ["install"])
        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(unit.read_bytes(), unit_bytes)

    def test_native_migration_refuses_extended_attributes_before_service_calls(self):
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        unit_bytes = volume.linux_service_render(self.runtime, str(self.config), self.state, "fuse").encode()
        unit.write_bytes(unit_bytes)
        config_bytes = self.config.read_bytes()
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        scratch = json.loads(config_bytes)["volumes"]["classes"]["scratch"]
        config_xattr = b"metadata"
        try:
            os.setxattr(self.config, "user.diskm-test", config_xattr)
        except (AttributeError, OSError) as error:
            self.skipTest("user extended attributes unavailable: " + str(error))
        calls = []
        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "cls", return_value=({"classes": {"scratch": {}}}, scratch)),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_command", side_effect=lambda *args, **kwargs: calls.append("service")),
            mock.patch.object(volume.subprocess, "run", side_effect=lambda *args, **kwargs: calls.append("fstab")),
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 75)
        self.assertEqual(calls, [])
        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(unit.read_bytes(), unit_bytes)
        self.assertEqual(os.getxattr(self.config, "user.diskm-test"), config_xattr)

    def test_native_migration_refuses_unit_extended_attributes_before_service_calls(self):
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        unit_bytes = volume.linux_service_render(self.runtime, str(self.config), self.state, "fuse").encode()
        unit.write_bytes(unit_bytes)
        config_bytes = self.config.read_bytes()
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        scratch = json.loads(config_bytes)["volumes"]["classes"]["scratch"]
        unit_xattr = b"metadata"
        try:
            os.setxattr(unit, "user.diskm-test", unit_xattr)
        except (AttributeError, OSError) as error:
            self.skipTest("user extended attributes unavailable: " + str(error))
        calls = []
        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "cls", return_value=({"classes": {"scratch": {}}}, scratch)),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_command", side_effect=lambda *args, **kwargs: calls.append("service")),
            mock.patch.object(volume.subprocess, "run", side_effect=lambda *args, **kwargs: calls.append("fstab")),
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 75)
        self.assertEqual(calls, [])
        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(unit.read_bytes(), unit_bytes)
        self.assertEqual(os.getxattr(unit, "user.diskm-test"), unit_xattr)

    def test_native_migration_refuses_metadata_enumeration_error_before_service_calls(self):
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        unit_bytes = volume.linux_service_render(self.runtime, str(self.config), self.state, "fuse").encode()
        unit.write_bytes(unit_bytes)
        config_bytes = self.config.read_bytes()
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        scratch = json.loads(config_bytes)["volumes"]["classes"]["scratch"]
        calls = []
        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "cls", return_value=({"classes": {"scratch": {}}}, scratch)),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume.os, "listxattr", side_effect=OSError("metadata unavailable")),
            mock.patch.object(volume, "linux_command", side_effect=lambda *args, **kwargs: calls.append("service")),
            mock.patch.object(volume.subprocess, "run", side_effect=lambda *args, **kwargs: calls.append("fstab")),
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 75)
        self.assertEqual(calls, [])
        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(unit.read_bytes(), unit_bytes)

    def test_native_migration_binds_explicit_config_and_state_paths(self):
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        prior_runtime = self.root / ".local/share/disk-magician/candidates" / ("a" * 40)
        (prior_runtime / "systemd").mkdir(mode=0o700, parents=True)
        (prior_runtime / "disk_magician.sh").write_text("#!/bin/sh\n")
        template = self.runtime / "systemd/diskm-scratch.service.in"
        (prior_runtime / "systemd/diskm-scratch.service.in").write_bytes(template.read_bytes())
        unit.write_bytes(volume.linux_service_render(prior_runtime, str(self.config), self.state, "fuse").encode())
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        registry_path = self.state / "volumes/registry.json"
        registry_path.parent.mkdir(mode=0o700)
        registry_path.write_text(json.dumps({"schema_version": 1, "volumes": {"scratch": entry}}))
        ambient_config = self.root / "ambient-config.json"
        ambient_document = json.loads(self.config.read_text())
        ambient_document["volumes"]["classes"]["scratch"]["backend"] = "native"
        ambient_config.write_text(json.dumps(ambient_document))
        ambient_state = self.root / "ambient-state"
        (ambient_state / "volumes").mkdir(mode=0o700, parents=True)
        (ambient_state / "volumes/registry.json").write_text(json.dumps({"schema_version": 1, "volumes": {}}))
        ambient_bytes = ambient_config.read_bytes()
        os.environ["DISK_MAGICIAN_CONFIG"] = str(ambient_config)
        os.environ["DISK_MAGICIAN_STATE_DIR"] = str(ambient_state)
        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_validate_native_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume, "linux_command", return_value=""),
            mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=b'{"changed":true}')),
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 0)
        self.assertEqual(json.loads(self.config.read_text())["volumes"]["classes"]["scratch"]["backend"], "native")
        self.assertEqual(ambient_config.read_bytes(), ambient_bytes)
        self.assertEqual(volume.registry(self.state)["volumes"]["scratch"], entry)

    def test_native_migration_commits_backend_and_oneshot_service(self):
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        unit.write_bytes(volume.linux_service_render(self.runtime,
            str(self.config), self.state, "fuse").encode())
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        settings, scratch = {"classes": {"scratch": {}}}, json.loads(self.config.read_text())["volumes"]["classes"]["scratch"]
        calls = []
        def command(args, timeout=30):
            if args[:2] == ["systemctl", "--user"]:
                calls.append(args[2])
            return ""
        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "cls", return_value=(settings, scratch)),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_validate_native_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume, "linux_command", side_effect=command),
            mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=b'{"changed":true}')),
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 0)
        self.assertEqual(json.loads(self.config.read_text())["volumes"]["classes"]["scratch"]["backend"], "native")
        self.assertIn(b"Type=oneshot\nRemainAfterExit=yes", unit.read_bytes())
        self.assertEqual(calls, ["stop", "daemon-reload", "start", "is-active"])

    def test_safe_native_rollback_removes_fstab_and_restarts_fuse(self):
        config_bytes = self.config.read_bytes()
        unit = self.root / ".config/systemd/user/diskm-scratch.service"
        unit.parent.mkdir(mode=0o700, parents=True)
        unit_bytes = volume.linux_service_render(self.runtime,
                                                  str(self.config), self.state, "fuse").encode()
        unit.write_bytes(unit_bytes)
        entry = {"state": "active", "image_path": str(self.image),
                 "mountpoint": str(self.mountpoint), "quota_bytes": 2 * volume.GIB,
                 "filesystem_uuid": "12345678-1234-1234-1234-123456789abc"}
        settings, scratch = {"classes": {"scratch": {}}}, json.loads(config_bytes)["volumes"]["classes"]["scratch"]
        calls = []
        def command(args, timeout=30):
            if args[:2] == ["systemctl", "--user"]:
                calls.append(args[2])
            return ""
        with (
            mock.patch.object(volume, "linux_fstab_allowed_paths", return_value=(self.config, self.state, self.image, self.mountpoint)),
            mock.patch.object(volume, "cls", return_value=(settings, scratch)),
            mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}),
            mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]),
            mock.patch.object(volume, "linux_validate_native_mount", side_effect=ValueError("forced safe rollback")),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", return_value=False),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume, "linux_command", side_effect=command),
            mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0, stdout=b'{"changed":true}')) as run,
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 75)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(unit.read_bytes(), unit_bytes)
        self.assertEqual(calls, ["stop", "daemon-reload", "start", "stop", "daemon-reload", "start"])


if __name__ == "__main__":
    unittest.main()
