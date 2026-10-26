import importlib.util
import json
import os
from pathlib import Path
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
            mock.patch.object(volume, "linux_validate_native_mount", side_effect=ValueError("forced native validation failure")),
            mock.patch.object(volume, "linux_mount_record", return_value=None),
            mock.patch.object(volume, "linux_image_has_loop_mapping", side_effect=[False, True]),
            mock.patch.object(volume, "linux_image_has_open_writers", return_value=False),
            mock.patch.object(volume, "linux_command", side_effect=command),
            mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0)),
            mock.patch.object(volume.Path, "home", return_value=self.root),
            mock.patch.object(volume, "__file__", str(self.runtime_script)),
        ):
            args = ["scratch", "--backend", "native", "--config", str(self.config),
                    "--state-dir", str(self.state), "--user-uid", str(os.geteuid()), "--execute"]
            self.assertEqual(volume.linux_service_migrate_cmd(args), 75)
        self.assertEqual(self.config.read_bytes(), config_bytes)
        self.assertEqual(unit.read_bytes(), unit_bytes)
        self.assertEqual(calls, ["stop", "daemon-reload", "start", "stop", "daemon-reload"])

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
            mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0)),
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
            mock.patch.object(volume.subprocess, "run", return_value=mock.Mock(returncode=0)) as run,
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
