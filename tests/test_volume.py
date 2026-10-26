import importlib.util
import contextlib
import io
import json
import os
import pathlib
import tempfile
import sys
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("volume", ROOT / "scripts" / "volume.py")
volume = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = volume
spec.loader.exec_module(volume)

class VolumeTestBase(unittest.TestCase):
    def setUp(self):
        # Temp mountpoints belong to fake-diskutil, not the Darwin host.
        # The Darwin-only production guard has a dedicated test.
        self.platform_patch = mock.patch.object(volume.sys, "platform", "linux")
        self.platform_patch.start()
        self.addCleanup(self.platform_patch.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # macOS temp roots can traverse /var -> /private/var.
        self.root = pathlib.Path(self.temp.name).resolve()
        self.state = self.root / "diskutil.json"
        self.calls_file = self.root / "calls.jsonl"
        self.state_dir = self.root / "state"
        self.mp = self.root / "Volumes" / "diskm-scratch"
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"volumes": {"swap_headroom_gb": 40, "alarm_floor_gb": 20, "encryption": "none", "encryption_acknowledged_at": "2026-10-25T00:00:00Z", "classes": {"scratch": {"name": "diskm-scratch", "quota_gb": 30, "mountpoint": str(self.mp)}}}}))
        self.env = {k: os.environ.get(k) for k in ("DISK_MAGICIAN_DISKUTIL_BIN", "FAKE_DISKUTIL_STATE", "FAKE_DISKUTIL_CALLS", "DISK_MAGICIAN_STATE_DIR", "DISK_MAGICIAN_CONFIG", "DISK_MAGICIAN_DELETION_LOG", "FAKE_DISKUTIL_MOUNTPOINT")}
        os.environ["DISK_MAGICIAN_DISKUTIL_BIN"] = str(ROOT / "tests/lib/fake_diskutil.py")
        os.environ["FAKE_DISKUTIL_STATE"] = str(self.state)
        os.environ["FAKE_DISKUTIL_CALLS"] = str(self.calls_file)
        os.environ["DISK_MAGICIAN_STATE_DIR"] = str(self.state_dir)
        os.environ["DISK_MAGICIAN_CONFIG"] = str(self.config)
        os.environ["DISK_MAGICIAN_DELETION_LOG"] = str(self.root / "deletions.log")
        os.environ["FAKE_DISKUTIL_MOUNTPOINT"] = str(self.mp)
        self.addCleanup(self.restore_env)
        self.state.write_text(json.dumps({"container": {"ref": "disk3", "uuid": "CONTAINER-UUID", "ceiling": 994662584320, "free": 100 * 2**30}, "volumes": [
            {"uuid": "DATA-UUID", "name": "Data", "ref": "disk3s1", "device": "disk3s1", "used": 829 * 2**30, "quota": 0, "roles": ["Data"], "mountpoint": "/System/Volumes/Data"},
            {"uuid": "SYSTEM-UUID", "name": "System", "ref": "disk3s5", "device": "disk3s5", "used": 15 * 2**30, "quota": 0, "roles": ["System"], "mountpoint": "/"},
            {"uuid": "VM-UUID", "name": "VM", "ref": "disk3s6", "device": "disk3s6", "used": 4 * 2**30, "quota": 0, "roles": ["VM"], "mountpoint": "/System/Volumes/VM"}] }))
    def restore_env(self):
        for key, value in self.env.items():
            if value is None: os.environ.pop(key, None)
            else: os.environ[key] = value

class LinuxScratchTest(VolumeTestBase):
    def test_canonical_owner_release_requires_every_live_producer(self):
        artifact = self.root / "owned-artifact"
        artifact.mkdir()
        (artifact / "payload").write_bytes(b"preserve")
        owners = [volume.subprocess.Popen(["sleep", "60"]) for _ in range(2)]
        try:
            library = ROOT / "scripts/lib/worktree_lease.sh"
            command = ["bash", "-c", 'source "$1"; lease_write "$2" repo branch scratch-new --owner-pid "$3" --owner-pid "$4"',
                       "test", str(library), str(artifact), *[str(p.pid) for p in owners]]
            volume.subprocess.run(command, check=True, capture_output=True, text=True)
            lease = next((self.state_dir / "worktree_leases").glob("*.json"))
            for index, owner in enumerate(owners):
                self.assertTrue(all(p.poll() is None for p in owners))
                volume.subprocess.run(["bash", str(ROOT / "disk_magician.sh"), "lease-release-owner",
                    str(artifact), "--owner-pid", str(owner.pid)], check=True, capture_output=True)
                result = volume.subprocess.run(["bash", "-c", 'source "$1"; lease_owner_state "$2"',
                    "test", str(library), str(lease)], check=True, capture_output=True, text=True)
                self.assertEqual(result.stdout.strip(), "alive" if index == 0 else "released")
            self.assertEqual((artifact / "payload").read_bytes(), b"preserve")
        finally:
            for owner in owners:
                owner.terminate()
                owner.wait(timeout=5)

    def test_linux_ballast_uses_verified_mount_under_lock(self):
        self.set_linux_image_config(2)
        self.mp.mkdir(parents=True)
        volume.write_ballast(str(self.mp))
        with mock.patch.object(volume, "linux_validate_mount", return_value="fixture-uuid") as verify, \
             mock.patch.object(volume, "exact_entry", side_effect=AssertionError("APFS called")), \
             mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": {}}}):
            self.assertEqual(volume.ballast_cmd("release", "scratch"), 0)
            verify.assert_called_once()
            self.assertFalse(volume.ballast_ok(str(self.mp)))
            self.assertEqual(volume.ballast_cmd("ensure", "scratch"), 0)
            self.assertTrue(volume.ballast_ok(str(self.mp)))

    def test_linux_ballast_unknown_mount_preserves_reserve(self):
        self.set_linux_image_config(2)
        self.mp.mkdir(parents=True)
        volume.write_ballast(str(self.mp))
        with mock.patch.object(volume, "linux_validate_mount", side_effect=ValueError("identity")):
            self.assertEqual(volume.ballast_cmd("release", "scratch"), 75)
        self.assertTrue(volume.ballast_ok(str(self.mp)))

    def test_scheduler_dispatch_validates_interval(self):
        with mock.patch.object(volume, "linux_scheduler_install_cmd", return_value=0) as install:
            self.assertEqual(volume.main(["scheduler", "install", "scratch", "--interval-seconds", "20"]), 0)
            install.assert_called_once_with("scratch", 20)
            for suffix in (["--interval-seconds", "0"], ["--interval-seconds", "-1"],
                           ["--interval-seconds", "1.5"], ["--interval-seconds"], ["--unknown"]):
                self.assertEqual(volume.main(["scheduler", "install", "scratch", *suffix]), 2)

    def test_scheduler_renders_isolated_units_and_preserves_collisions(self):
        import hashlib
        import shutil
        self.set_linux_image_config(2)
        candidate = self.root / "candidate"
        (candidate / "scripts").mkdir(parents=True)
        (candidate / "systemd").mkdir()
        (candidate / "disk_magician.sh").touch()
        for suffix in ("service", "timer"):
            shutil.copy(ROOT / "systemd" / f"diskm-scratch-reclaim.{suffix}.in", candidate / "systemd")
        unit_name = "diskm-scratch-reclaim-" + hashlib.sha256(os.fsencode(self.config.resolve())).hexdigest()[:12]
        units = self.root / ".config/systemd/user"
        with mock.patch.object(volume, "__file__", str(candidate / "scripts/volume.py")), \
             mock.patch.object(volume.Path, "home", return_value=self.root), \
             mock.patch.object(volume, "linux_validate_mount"), \
             mock.patch.object(volume, "linux_command") as command:
            self.assertEqual(volume.linux_scheduler_install_cmd("scratch", 20), 0)
            timer = (units / (unit_name + ".timer")).read_text()
            service = (units / (unit_name + ".service")).read_text()
            self.assertIn("OnBootSec=5s\nOnUnitActiveSec=20s\nAccuracySec=1s", timer)
            self.assertNotIn("Persistent", timer)
            self.assertIn("volume reclaim --clean", service)
            self.assertIn("Restart=no", service)
            self.assertIn(str(self.config), service)
            self.assertIn(str(self.state_dir), service)
            self.assertFalse((units / "diskm-scratch.service").exists())
            self.assertNotIn(mock.call(["systemctl", "--user", "start", unit_name + ".service"]), command.call_args_list)
            (units / (unit_name + ".timer")).write_text("unrelated")
            command.reset_mock()
            self.assertEqual(volume.linux_scheduler_install_cmd("scratch", 20), 75)
            command.assert_not_called()
            self.assertEqual((units / (unit_name + ".timer")).read_text(), "unrelated")

    def test_scheduler_rejects_mutable_checkout(self):
        self.set_linux_image_config(2)
        with mock.patch.object(volume, "linux_validate_mount"), mock.patch.object(volume, "linux_command") as command:
            self.assertEqual(volume.linux_scheduler_install_cmd("scratch", 20), 75)
            command.assert_not_called()

    def test_scheduler_production_override_and_unverified_mount_fail_closed(self):
        self.set_linux_image_config(2)
        with mock.patch.object(volume, "linux_validate_mount", side_effect=ValueError("unmounted")), \
             mock.patch.object(volume, "linux_command") as command:
            self.assertEqual(volume.linux_scheduler_install_cmd("scratch", 20), 75)
            command.assert_not_called()
        document = json.loads(self.config.read_text())
        document["volumes"]["classes"]["scratch"]["mountpoint"] = str(pathlib.Path.home() / "Scratch")
        self.config.write_text(json.dumps(document))
        with mock.patch.object(volume, "linux_validate_mount"), mock.patch.object(volume, "linux_command") as command:
            self.assertEqual(volume.linux_scheduler_install_cmd("scratch", 20), 75)
            command.assert_not_called()

    def test_c14_resolves_active_config_and_rejects_unknown_config(self):
        scratch = self.set_linux_image_config(2)
        candidate = pathlib.Path(scratch["mountpoint"]) / "repo/evidence/old"
        candidate.mkdir(parents=True)
        xdg = self.root / "xdg/disk-magician"
        xdg.mkdir(parents=True)
        active = xdg / "config.json"
        active.write_text(self.config.read_text())
        env = dict(os.environ, XDG_CONFIG_HOME=str(xdg.parent))
        env.pop("DISK_MAGICIAN_CONFIG", None)
        command = ['bash', '-c', 'source "$1"; artifact_removal_verdict "$2" --kind ephemeral',
                   'c14', str(ROOT / 'scripts/lib/artifact_verdict.sh'), str(candidate)]
        result = volume.subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), "kept:volume-identity")
        for content in ('{', '{"volumes":null}'):
            active.write_text(content)
            result = volume.subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "kept:volume-config")

    def set_linux_image_config(self, quota=30):
        data = json.loads(self.config.read_text())
        scratch = data["volumes"]["classes"]["scratch"]
        scratch["image_path"] = str(self.root / "scratch.ext4")
        scratch["quota_gb"] = quota
        self.config.write_text(json.dumps(data))
        return scratch

    def test_mountinfo_path_escaping_preserves_kernel_escape_sequences(self):
        path = pathlib.Path("/tmp/back\\slash with\t tab\nline")
        escaped = str(path).replace("\\", "\\134").replace("\t", "\\011").replace(" ", "\\040").replace("\n", "\\012")
        self.assertEqual(escaped, "/tmp/back\\134slash\\040with\\011\\040tab\\012line")

    def test_linux_scratch_create_preview_is_sparse_and_capped(self):
        self.set_linux_image_config(200)
        usage = volume.shutil._ntuple_diskusage(total=500 * volume.GIB, used=0, free=500 * volume.GIB)
        output = io.StringIO()
        with mock.patch.object(volume.shutil, "disk_usage", return_value=usage), \
             contextlib.redirect_stdout(output):
            self.assertEqual(volume.linux_create_cmd("scratch"), 0)
        result = json.loads(output.getvalue())
        self.assertTrue(result["sparse"])
        self.assertEqual(result["quota_bytes"], 200 * volume.GIB)
        self.assertFalse(pathlib.Path(result["image_path"]).exists())

    def test_linux_scratch_rejects_capacity_above_requested_cap(self):
        self.set_linux_image_config(201)
        self.assertEqual(volume.linux_create_cmd("scratch", execute=True), 2)
        self.assertFalse((self.root / "scratch.ext4").exists())

    def test_linux_scratch_create_makes_missing_image_parent_under_lock(self):
        scratch = self.set_linux_image_config(1)
        image = self.root / "new-parent" / "nested" / "scratch.ext4"
        scratch["image_path"] = str(image)
        document = json.loads(self.config.read_text())
        document["volumes"]["classes"]["scratch"] = scratch
        self.config.write_text(json.dumps(document))

        commands = []

        def fake_linux_command(args, timeout=30):
            commands.append(args)
            return "4f9f36b2-6896-46b3-b909-8bedf1a2273f" if args[0] == "blkid" else ""

        usage = volume.shutil._ntuple_diskusage(total=500 * volume.GIB, used=0, free=500 * volume.GIB)
        with mock.patch.object(volume.shutil, "disk_usage", return_value=usage), \
             mock.patch.object(volume, "linux_command", side_effect=fake_linux_command):
            self.assertEqual(volume.linux_create_cmd("scratch", execute=True), 0)
        self.assertTrue(image.is_file())
        self.assertEqual(image.stat().st_size, volume.GIB)
        self.assertEqual(image.parent.stat().st_uid, os.geteuid())
        mkfs_args = next(args for args in commands if len(args) > 1 and args[1] == "-F")
        self.assertIn("ext4", mkfs_args)
        self.assertEqual(volume.registry()["volumes"]["scratch"]["image_path"], str(image))

    def test_linux_service_installer_refuses_mutable_source_checkout(self):
        scratch = self.set_linux_image_config(200)
        entry = {"state": "active", "image_path": scratch["image_path"],
                 "mountpoint": scratch["mountpoint"], "quota_bytes": 200 * volume.GIB}
        with mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}), \
             mock.patch.object(volume, "linux_mount_record", return_value=None):
            self.assertEqual(volume.linux_service_install_cmd("scratch"), 75)

    def test_linux_paths_reject_symlinked_image_and_mountpoint_parents(self):
        scratch = self.set_linux_image_config(1)
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        for key in ("image_path", "mountpoint"):
            with self.subTest(path=key):
                unsafe = dict(scratch)
                unsafe[key] = str(alias / pathlib.Path(scratch[key]).relative_to(self.root))
                with self.assertRaisesRegex(ValueError, "may not traverse symlinks"):
                    volume.linux_paths(unsafe)

    def test_linux_mount_temporarily_opens_underlay_then_restores_read_only_mode(self):
        scratch = self.set_linux_image_config(1)
        image = pathlib.Path(scratch["image_path"])
        with image.open("wb") as stream:
            stream.truncate(volume.GIB)
        mountpoint = pathlib.Path(scratch["mountpoint"])
        mountpoint.mkdir(parents=True, mode=0o500)
        mountpoint.chmod(0o500)
        entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
                 "quota_bytes": volume.GIB, "filesystem_uuid": "4f9f36b2-6896-46b3-b909-8bedf1a2273f"}
        mount_reads = iter([None, ("fuse.ext4", str(image)), ("fuse.ext4", str(image))])
        with mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}), \
             mock.patch.object(volume, "linux_fs_uuid", return_value=entry["filesystem_uuid"]), \
             mock.patch.object(volume, "linux_mount_record", side_effect=lambda _: next(mount_reads)), \
             mock.patch.object(volume.subprocess, "Popen") as popen:
            process = mock.Mock()
            process.poll.return_value = None
            popen.return_value = process
            def launch(command, **kwargs):
                self.assertEqual(mountpoint.stat().st_mode & 0o777, 0o700)
                self.assertNotIn("stdout", kwargs)
                self.assertNotIn("stderr", kwargs)
                self.assertNotIn(volume.subprocess.PIPE, kwargs.values())
                self.assertNotIn("rw+", command)
                return process
            popen.side_effect = launch
            self.assertEqual(volume.linux_mount_cmd("scratch"), 0)
        self.assertEqual(mountpoint.stat().st_mode & 0o777, 0o500)

    def test_linux_mount_validation_failure_unmounts_only_its_image(self):
        scratch = self.set_linux_image_config(1)
        image = pathlib.Path(scratch["image_path"])
        with image.open("wb") as stream:
            stream.truncate(volume.GIB)
        mountpoint = pathlib.Path(scratch["mountpoint"])
        mountpoint.mkdir(parents=True, mode=0o500)
        mountpoint.chmod(0o500)
        entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
                 "quota_bytes": volume.GIB, "filesystem_uuid": "4f9f36b2-6896-46b3-b909-8bedf1a2273f"}
        mount_reads = iter([None, ("fuse.ext4", str(image)), ("fuse.ext4", str(image))])
        process = mock.Mock()
        process.poll.return_value = 0
        with mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}), \
             mock.patch.object(volume, "linux_fs_uuid", return_value=entry["filesystem_uuid"]), \
             mock.patch.object(volume, "linux_mount_record", side_effect=lambda _: next(mount_reads)), \
             mock.patch.object(volume, "linux_validate_mount", side_effect=ValueError("invalid UUID")), \
             mock.patch.object(volume, "linux_command") as command, \
             mock.patch.object(volume.subprocess, "Popen", return_value=process):
            self.assertEqual(volume.linux_mount_cmd("scratch"), 75)
        command.assert_called_once_with(["fusermount3", "-u", str(mountpoint)])
        self.assertEqual(mountpoint.stat().st_mode & 0o777, 0o500)

    def test_linux_mount_failure_restores_underlay_mode(self):
        scratch = self.set_linux_image_config(1)
        image = pathlib.Path(scratch["image_path"])
        image.write_bytes(b"image")
        mountpoint = pathlib.Path(scratch["mountpoint"])
        mountpoint.mkdir(parents=True, mode=0o500)
        mountpoint.chmod(0o500)
        entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
                 "quota_bytes": volume.GIB, "filesystem_uuid": "4f9f36b2-6896-46b3-b909-8bedf1a2273f"}
        process = mock.Mock()
        process.poll.return_value = 1
        with mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}), \
             mock.patch.object(volume, "linux_fs_uuid", return_value=entry["filesystem_uuid"]), \
             mock.patch.object(volume, "linux_mount_record", return_value=None), \
             mock.patch.object(volume.subprocess, "Popen", return_value=process):
            self.assertEqual(volume.linux_mount_cmd("scratch"), 75)
        self.assertEqual(mountpoint.stat().st_mode & 0o777, 0o500)

    def test_linux_underlay_mountpoint_must_not_be_writable(self):
        mountpoint = self.root / "underlay"
        mountpoint.mkdir(mode=0o500)
        mountpoint.chmod(0o500)
        self.assertTrue(volume.linux_mountpoint_safe(mountpoint))
        mountpoint.chmod(0o700)
        self.assertFalse(volume.linux_mountpoint_safe(mountpoint))

    def test_linux_path_never_returns_unmounted_mountpoint(self):
        self.set_linux_image_config(200)
        self.assertEqual(volume.path_cmd("scratch"), 3)


    def test_linux_foreground_mount_refuses_an_existing_mount_without_owning_it(self):
        scratch = self.set_linux_image_config(1)
        entry = {"state": "active", "image_path": scratch["image_path"],
                 "mountpoint": scratch["mountpoint"], "quota_bytes": volume.GIB,
                 "filesystem_uuid": "4f9f36b2-6896-46b3-b909-8bedf1a2273f"}
        with mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}), \
             mock.patch.object(volume, "linux_mount_record", return_value=("fuse.ext4", scratch["image_path"])), \
             mock.patch.object(volume, "linux_validate_mount") as validate, \
             mock.patch.object(volume.subprocess, "Popen") as popen:
            self.assertEqual(volume.linux_mount_cmd("scratch", foreground=True), 75)
        validate.assert_called_once()
        popen.assert_not_called()

    def test_linux_service_install_rejects_an_unmanaged_existing_mount(self):
        scratch = self.set_linux_image_config(1)
        entry = {"state": "active", "image_path": scratch["image_path"],
                 "mountpoint": scratch["mountpoint"], "quota_bytes": volume.GIB,
                 "filesystem_uuid": "4f9f36b2-6896-46b3-b909-8bedf1a2273f"}
        with mock.patch.object(volume, "cls", return_value=({}, scratch)), \
             mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}), \
             mock.patch.object(volume, "linux_mount_record", return_value=("fuse.ext4", scratch["image_path"])), \
             mock.patch.object(volume, "linux_validate_mount"), \
             mock.patch.object(volume, "linux_command", side_effect=RuntimeError("inactive")) as command:
            self.assertEqual(volume.linux_service_install_cmd("scratch"), 75)
        command.assert_called_once_with(["systemctl", "--user", "is-active", "--quiet", "diskm-scratch.service"], 15)

    def test_linux_mount_recovers_only_empty_owned_0700_interrupted_underlay(self):
        mountpoint = self.root / "underlay"
        mountpoint.mkdir(mode=0o700)
        mountpoint.chmod(0o700)
        image = self.root / "scratch.ext4"
        entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint)}
        with mock.patch.object(volume, "linux_mount_record", return_value=None):
            self.assertTrue(volume.linux_recover_underlay(mountpoint, image, entry))
            self.assertEqual(mountpoint.stat().st_mode & 0o777, 0o500)
            mountpoint.chmod(0o700)
            (mountpoint / "unexpected").touch()
            self.assertFalse(volume.linux_recover_underlay(mountpoint, image, entry))
            self.assertEqual(mountpoint.stat().st_mode & 0o777, 0o700)

    def test_linux_status_uses_shared_volume_schema(self):
        scratch = self.set_linux_image_config(1)
        image, mountpoint = volume.linux_paths(scratch)
        entry = {"state": "active", "image_path": str(image), "mountpoint": str(mountpoint),
                 "quota_bytes": volume.GIB, "filesystem_uuid": "4f9f36b2-6896-46b3-b909-8bedf1a2273f"}
        usage = volume.shutil._ntuple_diskusage(total=volume.GIB, used=100, free=volume.GIB - 100)
        output = io.StringIO()
        with mock.patch.object(volume, "cls", return_value=({}, scratch)), \
             mock.patch.object(volume, "registry", return_value={"volumes": {"scratch": entry}}), \
             mock.patch.object(volume, "linux_mount_record", return_value=("fuse.ext4", str(image))), \
             mock.patch.object(volume, "linux_validate_mount", return_value=entry["filesystem_uuid"]), \
             mock.patch.object(volume.shutil, "disk_usage", return_value=usage), \
             contextlib.redirect_stdout(output):
            self.assertEqual(volume.linux_status(), 0)
        data = json.loads(output.getvalue())
        self.assertIn("measured_at", data)
        self.assertIn("alarms", data)
        row = next(x for x in data["volumes"] if x["class"] == "scratch")
        self.assertEqual((row["status"], row["available"], row["allocated_bytes"],
                          row["quota_bytes"], row["filesystem_id"], row["path"]),
                         ("active", True, 100, volume.GIB, entry["filesystem_uuid"], str(mountpoint)))

class ParseTest(VolumeTestBase):
    def test_container_rows(self):
        c = volume.load_container()
        self.assertEqual((c.ref, c.ceiling), ("disk3", 994662584320))
        self.assertEqual(c.volume_by_role("Data").used, 829 * 2**30)
    def test_fake_bin_in_use(self):
        self.assertNotEqual(volume.diskutil_bin(), "/usr/sbin/diskutil")

    def test_fake_diskutil_distinguishes_decimal_g_and_binary_gi(self):
        volume.run_diskutil([
            "apfs", "addVolume", "disk3", "APFS", "decimal", "-quota", "10g",
        ])
        volume.run_diskutil([
            "apfs", "addVolume", "disk3", "APFS", "binary", "-quota", "10Gi",
        ])
        added = json.loads(self.state.read_text())["volumes"][3:]
        self.assertEqual([row["quota"] for row in added], [10 * 10**9, 10 * 2**30])

class FitAndAuditTest(VolumeTestBase):
    def test_fit_uses_live_data_and_vm_headroom(self):
        result = volume.fit_result()
        self.assertEqual(result["data_used_bytes"], 829 * 2**30)
        self.assertEqual(result["vm_reserve_bytes"], 40 * 2**30)
        self.assertEqual(result["quota_bytes"], 30 * 2**30)
        self.assertFalse(result["fits"])

    def test_fit_unknown_capacity_fails_closed(self):
        data = json.loads(self.state.read_text())
        data["volumes"][0]["used"] = None
        self.state.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            volume.fit_result()

    def test_fit_counts_every_same_container_volume_allocation(self):
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1005 * 2**30
        data["volumes"][0]["used"] = 900 * 2**30
        data["volumes"].extend([
            {"uuid": "PREBOOT-UUID", "name": "Preboot", "ref": "disk3s2",
             "device": "disk3s2", "used": 10 * 2**30, "quota": 0,
             "roles": ["Preboot"]},
            {"uuid": "RECOVERY-UUID", "name": "Recovery", "ref": "disk3s3",
             "device": "disk3s3", "used": 10 * 2**30, "quota": 0,
             "roles": ["Recovery"]},
            {"uuid": "AUX-UUID", "name": "Auxiliary", "ref": "disk3s4",
             "device": "disk3s4", "used": 2 * 2**30, "quota": 0,
             "roles": []},
        ])
        self.state.write_text(json.dumps(data))

        result = volume.fit_result()

        expected = 900 + 15 + 10 + 10 + 2 + 40 + 30 + 20
        self.assertEqual(result["container_volume_allocations_bytes"], (900 + 15 + 4 + 10 + 10 + 2) * 2**30)
        self.assertEqual(result["required_bytes"], expected * 2**30)
        self.assertFalse(result["fits"])

    def test_fit_counts_active_scratch_quota_once_not_actual_plus_quota(self):
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))
        self.assertEqual(volume.create_cmd("scratch", execute=True), 0)
        data = json.loads(self.state.read_text())
        scratch = next(row for row in data["volumes"] if row["name"] == "diskm-scratch")
        scratch["used"] = 5 * 2**30
        self.state.write_text(json.dumps(data))

        result = volume.fit_result()

        self.assertEqual(result["scratch_reservation_bytes"], 30 * 2**30)
        self.assertEqual(result["container_volume_allocations_bytes"], (829 + 15 + 4 + 5) * 2**30)
        self.assertEqual(result["other_volume_allocations_bytes"], (829 + 15) * 2**30)
        self.assertEqual(result["required_bytes"], (829 + 15 + 40 + 30 + 20) * 2**30)

    def test_fit_unknown_nonstandard_volume_usage_fails_closed(self):
        data = json.loads(self.state.read_text())
        data["volumes"].append({
            "uuid": "AUX-UUID", "name": "Auxiliary", "ref": "disk3s4",
            "device": "disk3s4", "used": None, "quota": 0, "roles": [],
        })
        self.state.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            volume.fit_result()

    def test_snapshot_audit_only_reports_measured_large_tmp_rows(self):
        snapshot = self.root / "snapshot.json"
        snapshot.write_text(json.dumps({"snapshot_ts": "2026-10-25T12:00:00Z", "directories": [
            {"path": "/private/tmp/cache", "size_bytes": 2 * 2**30},
            {"path": "/private/tmp/small", "size_bytes": 2**30 - 1},
            {"path": "/Users/example", "size_bytes": 4 * 2**30}]}))
        result = volume.audit_tmp(snapshot)
        self.assertEqual(result["status"], "measured")
        self.assertEqual([x["path"] for x in result["candidates"]], ["/private/tmp/cache"])
        self.assertEqual(result["candidates"][0]["measured_at"], "2026-10-25T12:00:00Z")

    def test_snapshot_audit_reads_source_directory_map_in_kib(self):
        snapshot = self.root / "source-snapshot.json"
        snapshot.write_text(json.dumps({
            "timestamp": "2026-10-25T12:00:00Z",
            "directories": {
                "/private/tmp/cache": 5 * 1024 * 1024,
                "/private/tmp/unmeasured": None,
                "/Users/example": 6 * 1024 * 1024,
            },
        }))

        result = volume.audit_tmp(snapshot)

        self.assertEqual(result["status"], "measured")
        self.assertEqual(result["candidates"], [{
            "path": "/private/tmp/cache",
            "size_bytes": 5 * 2**30,
            "measured_at": "2026-10-25T12:00:00Z",
        }])

    def test_missing_snapshot_is_unknown_not_empty_measurement(self):
        result = volume.audit_tmp(self.root / "missing.json")
        self.assertEqual(result["status"], "unknown")
        self.assertEqual(result["candidates"], [])

class LifecycleTest(VolumeTestBase):
    def make_fit(self):
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))

    def _run_create_race(self, lock_number, mutation):
        case_root = self.root / f"create-race-{lock_number}-{id(mutation)}"
        case_root.mkdir()
        disk_state = case_root / "diskutil.json"
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        disk_state.write_text(json.dumps(data))
        mountpoint = case_root / "Volumes" / "diskm-scratch"
        config_path = case_root / "config.json"
        config = json.loads(self.config.read_text())
        config["volumes"]["classes"]["scratch"]["mountpoint"] = str(mountpoint)
        config_path.write_text(json.dumps(config))
        calls_path = case_root / "calls.jsonl"
        state_dir = case_root / "state"
        env = {
            "DISK_MAGICIAN_DISKUTIL_BIN": str(ROOT / "tests/lib/fake_diskutil.py"),
            "FAKE_DISKUTIL_STATE": str(disk_state),
            "FAKE_DISKUTIL_CALLS": str(calls_path),
            "DISK_MAGICIAN_STATE_DIR": str(state_dir),
            "DISK_MAGICIAN_CONFIG": str(config_path),
            "DISK_MAGICIAN_DELETION_LOG": str(case_root / "deletions.log"),
            "FAKE_DISKUTIL_MOUNTPOINT": str(mountpoint),
        }
        lock_calls = 0
        observed_state = {}
        real_locked_registry = volume.locked_registry

        def locked_registry_with_mutation():
            nonlocal lock_calls
            result = real_locked_registry()
            lock_calls += 1
            if lock_calls == lock_number:
                current = json.loads(disk_state.read_text())
                mutation(current, mountpoint)
                disk_state.write_text(json.dumps(current))
                observed_state["diskutil"] = current
            return result

        with mock.patch.dict(os.environ, env), \
                mock.patch.object(volume, "locked_registry", side_effect=locked_registry_with_mutation), \
                contextlib.redirect_stdout(io.StringIO()):
            result = volume.main(["create", "scratch", "--execute"])
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
        registry_path = state_dir / "volumes" / "registry.json"
        registry = json.loads(registry_path.read_text()) if registry_path.exists() else {"volumes": {}}
        return result, lock_calls, observed_state, json.loads(disk_state.read_text()), calls, mountpoint, registry

    def test_create_revalidates_fit_free_and_collisions_after_both_registry_locks(self):
        def low_free(data, _mountpoint):
            data["container"]["free"] = 19 * 2**30

        def no_fit(data, _mountpoint):
            data["container"]["ceiling"] = 933 * 2**30

        def volume_name_collision(data, _mountpoint):
            data["volumes"].append({
                "uuid": "RACE-UUID", "name": "diskm-scratch", "ref": "disk3s9",
                "device": "disk3s9", "used": 0, "quota": 30 * 2**30,
                "roles": [], "mountpoint": "/Volumes/existing-scratch",
            })

        def mountpoint_collision(_data, mountpoint):
            mountpoint.mkdir(parents=True)
            (mountpoint / "preserve.txt").write_text("existing user data")

        mutations = (
            ("free below floor", low_free),
            ("fit no longer holds", no_fit),
            ("volume name appears", volume_name_collision),
            ("mountpoint appears", mountpoint_collision),
        )
        for lock_number in (1, 2):
            for label, mutation in mutations:
                with self.subTest(lock_number=lock_number, change=label):
                    result, lock_calls, observed, disk_after, calls, mountpoint, registry = \
                        self._run_create_race(lock_number, mutation)
                    self.assertGreaterEqual(lock_calls, lock_number)
                    self.assertIn("diskutil", observed)
                    self.assertNotEqual(result, 0)
                    self.assertFalse(any(call[:2] == ["apfs", "addVolume"] for call in calls))
                    self.assertEqual(disk_after, observed["diskutil"])
                    self.assertNotIn("scratch", registry["volumes"])
                    if label == "mountpoint appears":
                        self.assertEqual((mountpoint / "preserve.txt").read_text(), "existing user data")

    def _run_other_container_collision(self, lock_number):
        case_root = self.root / f"other-container-collision-{lock_number}"
        case_root.mkdir()
        disk_state = case_root / "diskutil.json"
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        disk_state.write_text(json.dumps(data))
        mountpoint = case_root / "Volumes" / "diskm-scratch"
        config_path = case_root / "config.json"
        config = json.loads(self.config.read_text())
        config["volumes"]["classes"]["scratch"]["mountpoint"] = str(mountpoint)
        config_path.write_text(json.dumps(config))
        calls_path = case_root / "calls.jsonl"
        state_dir = case_root / "state"
        registry_path = state_dir / "volumes" / "registry.json"
        registry_path.parent.mkdir(parents=True)
        registry_path.write_text(json.dumps({
            "schema_version": volume.REGISTRY_SCHEMA_VERSION,
            "volumes": {"other": {"state": "active", "name": "other-preserved"}},
        }))
        env = {
            "DISK_MAGICIAN_DISKUTIL_BIN": str(ROOT / "tests/lib/fake_diskutil.py"),
            "FAKE_DISKUTIL_STATE": str(disk_state),
            "FAKE_DISKUTIL_CALLS": str(calls_path),
            "DISK_MAGICIAN_STATE_DIR": str(state_dir),
            "DISK_MAGICIAN_CONFIG": str(config_path),
            "DISK_MAGICIAN_DELETION_LOG": str(case_root / "deletions.log"),
            "FAKE_DISKUTIL_MOUNTPOINT": str(mountpoint),
        }
        lock_calls = 0
        observed = {}
        other_container = {
            "ref": "disk8", "uuid": "OTHER-CONTAINER-UUID",
            "ceiling": 200 * 2**30, "free": 100 * 2**30,
            "volumes": [{
                "uuid": "OTHER-CONTAINER-SCRATCH-UUID", "name": "diskm-scratch",
                "ref": "disk8s9", "device": "disk8s9", "used": 17 * 2**30,
                "quota": 30 * 2**30, "roles": [],
            }],
        }
        real_locked_registry = volume.locked_registry

        def locked_registry_with_collision():
            nonlocal lock_calls
            result = real_locked_registry()
            lock_calls += 1
            if lock_calls == lock_number:
                current_data = json.loads(disk_state.read_text())
                current_data["distractor_containers"] = [other_container]
                disk_state.write_text(json.dumps(current_data))
                observed["diskutil"] = current_data
            return result

        with mock.patch.dict(os.environ, env), \
                mock.patch.object(volume, "locked_registry", side_effect=locked_registry_with_collision), \
                contextlib.redirect_stdout(io.StringIO()):
            result = volume.main(["create", "scratch", "--execute"])
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
        return result, lock_calls, observed, json.loads(disk_state.read_text()), calls, \
            json.loads(registry_path.read_text()), mountpoint

    def test_create_rejects_other_container_name_collision_at_both_locks(self):
        for lock_number in (1, 2):
            with self.subTest(lock_number=lock_number):
                result, lock_calls, observed, disk_after, calls, registry, mountpoint = \
                    self._run_other_container_collision(lock_number)
                self.assertGreaterEqual(lock_calls, lock_number)
                self.assertIn("diskutil", observed)
                self.assertNotEqual(result, 0)
                self.assertFalse(any(call[:2] == ["apfs", "addVolume"] for call in calls))
                self.assertEqual(disk_after, observed["diskutil"])
                self.assertEqual(registry["volumes"], {
                    "other": {"state": "active", "name": "other-preserved"}
                })
                self.assertFalse(mountpoint.exists())

    def _run_config_drift_race(self, lock_number):
        case_root = self.root / f"config-drift-{lock_number}"
        case_root.mkdir()
        disk_state = case_root / "diskutil.json"
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        disk_state.write_text(json.dumps(data))
        mountpoint = case_root / "Volumes" / "diskm-scratch"
        config_path = case_root / "config.json"
        config = json.loads(self.config.read_text())
        config["volumes"]["classes"]["scratch"]["quota_gb"] = 70
        config["volumes"]["classes"]["scratch"]["mountpoint"] = str(mountpoint)
        config_path.write_text(json.dumps(config))
        calls_path = case_root / "calls.jsonl"
        state_dir = case_root / "state"
        registry_path = state_dir / "volumes" / "registry.json"
        registry_path.parent.mkdir(parents=True)
        preserved_entry = {"state": "active", "name": "other-preserved"}
        registry_path.write_text(json.dumps({
            "schema_version": volume.REGISTRY_SCHEMA_VERSION,
            "volumes": {"other": preserved_entry},
        }))
        env = {
            "DISK_MAGICIAN_DISKUTIL_BIN": str(ROOT / "tests/lib/fake_diskutil.py"),
            "FAKE_DISKUTIL_STATE": str(disk_state),
            "FAKE_DISKUTIL_CALLS": str(calls_path),
            "DISK_MAGICIAN_STATE_DIR": str(state_dir),
            "DISK_MAGICIAN_CONFIG": str(config_path),
            "DISK_MAGICIAN_DELETION_LOG": str(case_root / "deletions.log"),
            "FAKE_DISKUTIL_MOUNTPOINT": str(mountpoint),
        }
        lock_calls = 0
        observed = {}
        real_locked_registry = volume.locked_registry

        def locked_registry_with_config_drift():
            nonlocal lock_calls
            result = real_locked_registry()
            lock_calls += 1
            if lock_calls == lock_number:
                current_data = json.loads(disk_state.read_text())
                data_volume = next(row for row in current_data["volumes"] if row["name"] == "Data")
                data_volume["used"] = 870 * 2**30
                disk_state.write_text(json.dumps(current_data))
                current_config = json.loads(config_path.read_text())
                current_config["volumes"]["classes"]["scratch"]["quota_gb"] = 30
                config_path.write_text(json.dumps(current_config))
                observed["diskutil"] = current_data
                observed["config"] = current_config
            return result

        with mock.patch.dict(os.environ, env), \
                mock.patch.object(volume, "locked_registry", side_effect=locked_registry_with_config_drift), \
                contextlib.redirect_stdout(io.StringIO()):
            result = volume.main(["create", "scratch", "--execute"])
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
        return result, lock_calls, observed, json.loads(disk_state.read_text()), calls, \
            json.loads(config_path.read_text()), json.loads(registry_path.read_text()), mountpoint

    def test_create_rejects_config_drift_that_invalidates_original_quota_at_both_locks(self):
        for lock_number in (1, 2):
            with self.subTest(lock_number=lock_number):
                result, lock_calls, observed, disk_after, calls, config_after, registry, mountpoint = \
                    self._run_config_drift_race(lock_number)
                self.assertGreaterEqual(lock_calls, lock_number)
                self.assertIn("diskutil", observed)
                self.assertIn("config", observed)
                self.assertNotEqual(result, 0)
                self.assertFalse(any(call[:2] == ["apfs", "addVolume"] for call in calls))
                self.assertEqual(disk_after, observed["diskutil"])
                self.assertEqual(config_after, observed["config"])
                self.assertEqual(registry["volumes"], {
                    "other": {"state": "active", "name": "other-preserved"}
                })
                self.assertFalse(mountpoint.exists())

    def test_create_registers_only_after_verified_ballast_and_path_requires_active(self):
        self.make_fit()
        self.assertEqual(volume.path_cmd("scratch"), 3)
        self.assertEqual(volume.create_cmd("scratch", execute=True), 0)
        reg = json.loads((self.state_dir / "volumes/registry.json").read_text())
        self.assertEqual(reg["volumes"]["scratch"]["state"], "active")
        self.assertEqual(reg["volumes"]["scratch"]["uuid"], "SCRATCH-UUID")
        self.assertTrue(volume.ballast_ok(self.mp))
        self.assertEqual(volume.path_cmd("scratch"), 0)
        self.assertEqual(volume.main(["verify-mount", str(self.mp)]), 0)
        self.assertEqual(volume.main(["verify-mount", str(self.root / "wrong")]), 75)

    def test_path_uses_legacy_fallback_when_config_has_no_volume_block(self):
        self.config.write_text(json.dumps({"budgets": {"daily": 5}}))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(volume.path_cmd("scratch"), 3)
        self.assertEqual(output.getvalue(), "")

    def test_linux_template_config_without_registry_keeps_legacy_fallback(self):
        previous_config = os.environ.get("DISK_MAGICIAN_CONFIG")
        previous_diskutil = os.environ.get("DISK_MAGICIAN_DISKUTIL_BIN")
        os.environ["DISK_MAGICIAN_CONFIG"] = str(ROOT / "config.json.template")
        os.environ["DISK_MAGICIAN_DISKUTIL_BIN"] = str(self.root / "no-diskutil")
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output):
                self.assertEqual(volume.path_cmd("scratch"), 3)
        finally:
            if previous_config is None:
                os.environ.pop("DISK_MAGICIAN_CONFIG", None)
            else:
                os.environ["DISK_MAGICIAN_CONFIG"] = previous_config
            if previous_diskutil is None:
                os.environ.pop("DISK_MAGICIAN_DISKUTIL_BIN", None)
            else:
                os.environ["DISK_MAGICIAN_DISKUTIL_BIN"] = previous_diskutil
        self.assertEqual(output.getvalue(), "")
        self.assertFalse(self.calls_file.exists())

    def test_darwin_legacy_config_falls_back_only_when_apfs_confirms_absence(self):
        self.config.write_text(json.dumps({"budgets": {"daily": 5}}))
        absent = volume.Container("disk3", "CONTAINER-UUID", 100, 50, ())
        present = volume.Container(
            "disk3", "CONTAINER-UUID", 100, 50,
            (volume.Volume("diskm-scratch", "SCRATCH-UUID", "disk3s9", 0, 30, ()),),
        )
        for container, expected in ((absent, 3), (present, 75)):
            with self.subTest(expected=expected):
                output = io.StringIO()
                with mock.patch.object(volume.sys, "platform", "darwin"), \
                        mock.patch.object(volume, "load_container", return_value=container), \
                        contextlib.redirect_stdout(output):
                    self.assertEqual(volume.path_cmd("scratch"), expected)
                self.assertEqual(output.getvalue(), "")

    def test_darwin_legacy_config_fails_closed_when_apfs_inspection_fails(self):
        self.config.write_text(json.dumps({"budgets": {"daily": 5}}))
        output = io.StringIO()
        with mock.patch.object(volume.sys, "platform", "darwin"), \
                mock.patch.object(volume, "load_container", side_effect=RuntimeError("unavailable")), \
                contextlib.redirect_stdout(output):
            self.assertEqual(volume.path_cmd("scratch"), 75)
        self.assertEqual(output.getvalue(), "")

    def test_path_fails_closed_when_volumes_block_is_malformed(self):
        for malformed in (None, [], "bad"):
            with self.subTest(volumes=malformed):
                self.config.write_text(json.dumps({"volumes": malformed}))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(volume.path_cmd("scratch"), 75)
                self.assertEqual(output.getvalue(), "")

    def test_path_fails_closed_when_live_scratch_volume_has_no_registry_entry(self):
        data = json.loads(self.state.read_text())
        data["volumes"].append({
            "uuid": "SCRATCH-UUID", "name": "diskm-scratch", "ref": "disk3s9",
            "device": "disk3s9", "used": 0, "quota": 30 * 2**30,
            "roles": [], "mountpoint": str(self.mp),
        })
        self.state.write_text(json.dumps(data))
        output = io.StringIO()
        with mock.patch.object(volume.sys, "platform", "darwin"), \
                contextlib.redirect_stdout(output):
            self.assertEqual(volume.path_cmd("scratch"), 75)
        self.assertEqual(output.getvalue(), "")

    def test_linux_with_available_diskutil_fails_closed_for_live_unregistered_volume(self):
        data = json.loads(self.state.read_text())
        data["volumes"].append({
            "uuid": "SCRATCH-UUID", "name": "diskm-scratch", "ref": "disk3s9",
            "device": "disk3s9", "used": 0, "quota": 30 * 2**30,
            "roles": [], "mountpoint": str(self.mp),
        })
        self.state.write_text(json.dumps(data))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(volume.path_cmd("scratch"), 75)
        self.assertEqual(output.getvalue(), "")

    def test_path_fails_closed_for_malformed_existing_registry_entries(self):
        registry_path, _ = volume.registry_paths()
        for entry in (None, [], {"state": "unknown"}, {"state": None}):
            with self.subTest(entry=entry):
                registry_path.write_text(json.dumps({
                    "schema_version": volume.REGISTRY_SCHEMA_VERSION,
                    "volumes": {"scratch": entry},
                }))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(volume.path_cmd("scratch"), 75)
                self.assertEqual(output.getvalue(), "")

    def test_malformed_retired_entry_fails_closed_before_retired_fallback(self):
        registry_path, _ = volume.registry_paths()
        registry_path.write_text(json.dumps({
            "schema_version": volume.REGISTRY_SCHEMA_VERSION,
            "volumes": {"scratch": {"state": "retired"}},
        }))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(volume.path_cmd("scratch"), 75)
        self.assertEqual(output.getvalue(), "")

    def test_create_fails_closed_for_malformed_existing_registry_entry(self):
        self.make_fit()
        registry_path, _ = volume.registry_paths()
        registry_path.write_text(json.dumps({
            "schema_version": volume.REGISTRY_SCHEMA_VERSION,
            "volumes": {"scratch": []},
        }))
        self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        self.assertFalse(self.calls_file.exists())

    def test_create_does_not_allocate_when_free_below_threshold(self):
        self.make_fit()
        d = json.loads(self.state.read_text())
        d["container"]["free"] = 1088 * 2**20 - 1
        self.state.write_text(json.dumps(d))
        self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        self.assertFalse(self.calls_file.exists())

    def test_retired_path_is_disabled_but_reclaim_path_keeps_identity(self):
        self.make_fit()
        self.assertEqual(volume.create_cmd("scratch", execute=True), 0)
        self.assertEqual(volume.retire_cmd("scratch"), 0)
        self.assertEqual(volume.path_cmd("scratch"), 3)
        self.assertEqual(volume.path_cmd("scratch", for_reclaim=True), 0)


class StatusAndBallastTest(VolumeTestBase):
    def make_fit(self):
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))
        self.assertEqual(volume.create_cmd("scratch", execute=True), 0)

    def test_status_alarms_for_live_volume_without_complete_registry_state(self):
        cases = (
            ({}, "volume_registry_missing:scratch"),
            ({"scratch": {"state": "creating"}}, "volume_registry_incomplete:scratch"),
            ({"scratch": {"state": "needs_recovery"}}, "volume_registry_incomplete:scratch"),
        )
        registry_path, _ = volume.registry_paths()
        initial_state = self.state.read_text()
        for entries, expected_alarm in cases:
            with self.subTest(expected_alarm=expected_alarm):
                data = json.loads(initial_state)
                data["volumes"].append({
                    "uuid": "SCRATCH-UUID", "name": "diskm-scratch", "ref": "disk3s9",
                    "device": "disk3s9", "used": 0, "quota": 30 * 2**30,
                    "roles": [], "mountpoint": str(self.mp),
                })
                self.state.write_text(json.dumps(data))
                registry_path.write_text(json.dumps({
                    "schema_version": volume.REGISTRY_SCHEMA_VERSION,
                    "volumes": entries,
                }))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(volume.status(snapshot=True), 2)
                self.assertIn(expected_alarm, json.loads(output.getvalue())["alarms"])

    def test_status_fails_closed_for_malformed_present_registry_entry(self):
        registry_path, _ = volume.registry_paths()
        for entry in (None, [], "invalid", 7, {}, {"state": "unknown"}):
            with self.subTest(entry=entry):
                registry_path.write_text(json.dumps({
                    "schema_version": volume.REGISTRY_SCHEMA_VERSION,
                    "volumes": {"scratch": entry},
                }))
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(volume.status(snapshot=True), 2)
                result = json.loads(output.getvalue())
                self.assertIn("volume_registry_invalid:scratch", result["alarms"])

    def test_create_rejects_custom_mountpoint_on_macos_before_mutation(self):
        with mock.patch.object(volume.sys, "platform", "darwin"):
            self.assertEqual(volume.create_cmd("scratch", execute=True), 2)
        self.assertFalse(self.calls_file.exists())

    def test_create_passes_exact_binary_quota_bytes(self):
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))
        self.assertEqual(volume.create_cmd("scratch", execute=True), 0)
        calls = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        add = next(call for call in calls if call[:2] == ["apfs", "addVolume"])
        self.assertEqual(add[add.index("-quota") + 1], str(30 * 2**30))
        measured = next(
            row for row in json.loads(self.state.read_text())["volumes"]
            if row["name"] == "diskm-scratch"
        )
        self.assertEqual(measured["quota"], 30 * 2**30)

    def test_reclaim_clean_dispatches_to_shared_implementation(self):
        completed = type("Completed", (), {"returncode": 17})()
        with mock.patch.object(volume.subprocess, "run", return_value=completed) as run:
            self.assertEqual(volume.main(["reclaim", "--clean"]), 17)
        command = run.call_args.args[0]
        self.assertEqual(command[0:2], ["bash", str(ROOT / "scripts" / "volume_reclaim.sh")])
        self.assertEqual(command[-1], "--clean")

    def test_status_reports_identity_measurements_and_high_water_alarm(self):
        self.make_fit()
        data = json.loads(self.state.read_text())
        scratch = next(x for x in data["volumes"] if x["name"] == "diskm-scratch")
        scratch["used"] = 28 * 2**30
        data["container"]["free"] = 15 * 2**30
        self.state.write_text(json.dumps(data))
        from contextlib import redirect_stdout
        import io
        output = io.StringIO()
        with redirect_stdout(output):
            rc = volume.status(snapshot=True)
        result = json.loads(output.getvalue())
        self.assertEqual(rc, 1)
        self.assertEqual(set(result["alarms"]), {"container_low", "volume_high"})
        row = result["volumes"][0]
        self.assertEqual(row["filesystem_id"], "SCRATCH-UUID")
        self.assertEqual(row["allocated_bytes"], 28 * 2**30)
        self.assertEqual(row["quota_bytes"], 30 * 2**30)
        self.assertEqual(row["source"], "apfs_volume")
        self.assertEqual(result["container"]["filesystem_id"], "CONTAINER-UUID")

    def test_malformed_tmp_snapshot_does_not_suppress_live_scratch_high_water(self):
        self.make_fit()
        data = json.loads(self.state.read_text())
        scratch = next(x for x in data["volumes"] if x["name"] == "diskm-scratch")
        scratch["used"] = 28 * 2**30
        self.state.write_text(json.dumps(data))
        snapshot = self.root / "malformed-snapshot.json"
        snapshot.write_text(json.dumps({"directories": [None]}))
        previous = os.environ.get("DISK_MAGICIAN_SNAPSHOT_FILE")
        os.environ["DISK_MAGICIAN_SNAPSHOT_FILE"] = str(snapshot)
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output):
                self.assertEqual(volume.status(snapshot=True), 1)
        finally:
            if previous is None:
                os.environ.pop("DISK_MAGICIAN_SNAPSHOT_FILE", None)
            else:
                os.environ["DISK_MAGICIAN_SNAPSHOT_FILE"] = previous
        result = json.loads(output.getvalue())
        self.assertIn("volume_high", result["alarms"])
        self.assertEqual(result["volumes"][0]["allocated_bytes"], 28 * 2**30)
        self.assertNotIn("tmp_audit", result)

    def test_status_alarms_when_live_capacity_fit_fails(self):
        self.make_fit()
        data = json.loads(self.state.read_text())
        next(row for row in data["volumes"] if row["name"] == "Data")["used"] = 899 * 2**30
        self.state.write_text(json.dumps(data))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(volume.status(snapshot=True), 1)
        result = json.loads(output.getvalue())
        self.assertIn("scratch_capacity_unavailable", result["alarms"])
        self.assertFalse(result["capacity_fit"]["fits"])

    def test_status_degrades_when_active_scratch_ballast_is_missing_below_high_water(self):
        self.make_fit()
        data = json.loads(self.state.read_text())
        scratch = next(x for x in data["volumes"] if x["name"] == "diskm-scratch")
        scratch["used"] = 25 * 2**30  # 83.3%, below the reclaim high-water mark.
        self.state.write_text(json.dumps(data))

        from contextlib import redirect_stdout
        import io
        output = io.StringIO()
        with mock.patch.object(volume, "ballast_ok", return_value=False):
            with redirect_stdout(output):
                rc = volume.status(snapshot=True)

        result = json.loads(output.getvalue())
        self.assertEqual(rc, 1)
        self.assertIn("scratch_ballast_missing", result["alarms"])
        self.assertFalse(result["volumes"][0]["available"])

    def test_status_corrupt_config_returns_fatal_rc(self):
        self.config.write_text("{")
        from contextlib import redirect_stdout
        import io
        output = io.StringIO()
        with redirect_stdout(output):
            rc = volume.status(snapshot=True)
        self.assertEqual(rc, 2)
        result = json.loads(output.getvalue())
        self.assertIn("volume_measurement_unavailable", result["alarms"])

    def test_status_invalid_container_measurement_returns_fatal_rc(self):
        data = json.loads(self.state.read_text())
        data["container"]["free"] = None
        self.state.write_text(json.dumps(data))
        from contextlib import redirect_stdout
        import io
        output = io.StringIO()
        with redirect_stdout(output):
            rc = volume.status(snapshot=True)
        self.assertEqual(rc, 2)
        result = json.loads(output.getvalue())
        self.assertIn("volume_measurement_unavailable", result["alarms"])

    def test_status_corrupt_registry_returns_fatal_rc(self):
        registry_path, _ = volume.registry_paths()
        registry_path.write_text("{")
        from contextlib import redirect_stdout
        import io
        output = io.StringIO()
        with redirect_stdout(output):
            rc = volume.status(snapshot=True)
        self.assertEqual(rc, 2)
        result = json.loads(output.getvalue())
        self.assertIn("volume_measurement_unavailable", result["alarms"])

    def test_status_identity_mismatch_returns_fatal_rc(self):
        self.make_fit()
        data = json.loads(self.state.read_text())
        data["mounted_uuid"] = "OTHER-UUID"
        self.state.write_text(json.dumps(data))
        from contextlib import redirect_stdout
        import io
        output = io.StringIO()
        with redirect_stdout(output):
            rc = volume.status(snapshot=True)
        self.assertEqual(rc, 2)
        result = json.loads(output.getvalue())
        self.assertIn("volume_measurement_unavailable:scratch", result["alarms"])

    def test_plan_fit_includes_maximum_quota(self):
        result = volume.fit_result()
        self.assertEqual(result["max_quota_gb_that_fits"], 22)
        self.assertEqual(volume.main(["plan-fit", "--json"]), 0)

    def test_ballast_release_logs_verified_volume_identity(self):
        self.make_fit()
        log = pathlib.Path(os.environ["DISK_MAGICIAN_DELETION_LOG"])
        self.assertEqual(volume.ballast_cmd("release", "scratch"), 0)
        self.assertFalse((self.mp / ".diskm-ballast").exists())
        self.assertIn("release_ballast", log.read_text())
        self.assertIn("SCRATCH-UUID", log.read_text())

    def test_ballast_release_fails_when_durable_log_record_cannot_be_written(self):
        self.make_fit()
        failed_sink = self.root / "deletion-log-directory"
        failed_sink.mkdir()
        previous = os.environ.get("DISK_MAGICIAN_DELETION_LOG")
        os.environ["DISK_MAGICIAN_DELETION_LOG"] = str(failed_sink)
        try:
            self.assertEqual(volume.ballast_cmd("release", "scratch"), 75)
        finally:
            if previous is None:
                os.environ.pop("DISK_MAGICIAN_DELETION_LOG", None)
            else:
                os.environ["DISK_MAGICIAN_DELETION_LOG"] = previous
        self.assertTrue((self.mp / ".diskm-ballast").exists())

    def test_ballast_release_requires_final_log_after_unlink(self):
        self.make_fit()
        with mock.patch.object(volume, "log_ballast_release", side_effect=[True, False]):
            self.assertEqual(volume.ballast_cmd("release", "scratch"), 75)
        self.assertFalse((self.mp / ".diskm-ballast").exists())

    def test_ballast_release_detects_replacement_before_final_identity_check(self):
        self.make_fit()
        ballast = self.mp / ".diskm-ballast"
        original_stat = volume.os.stat
        sentinel = self.root / "sentinel"
        sentinel.write_text("preserve me")
        swapped = False

        def swap_before_identity_check(path, *args, **kwargs):
            nonlocal swapped
            if path == ballast.name and kwargs.get("dir_fd") is not None and not swapped:
                swapped = True
                ballast.rename(self.mp / "original-ballast")
                ballast.symlink_to(sentinel)
            return original_stat(path, *args, **kwargs)

        with mock.patch.object(volume.os, "stat", side_effect=swap_before_identity_check):
            self.assertEqual(volume.ballast_cmd("release", "scratch"), 75)
        self.assertTrue(swapped)
        self.assertTrue(ballast.is_symlink())
        self.assertEqual(sentinel.read_text(), "preserve me")
        self.assertTrue((self.mp / "original-ballast").is_file())

    def test_create_requires_unencrypted_acknowledgment(self):
        config = json.loads(self.config.read_text())
        config["volumes"]["encryption_acknowledged_at"] = None
        self.config.write_text(json.dumps(config))
        self.assertEqual(volume.create_cmd("scratch", execute=True), 2)
        self.assertFalse(self.calls_file.exists())


class SnapshotResolverTest(VolumeTestBase):
    def test_default_audit_uses_existing_snapshot_without_du(self):
        snap = self.root / "snapshot.json"
        snap.write_text(json.dumps({"snapshot_ts": "2026-10-25T12:00:00Z", "directories": [
            {"path": "/private/tmp/worldai_frontend", "size_bytes": 5 * 2**30}]}))
        old = os.environ.get("DISK_MAGICIAN_SNAPSHOT_FILE")
        os.environ["DISK_MAGICIAN_SNAPSHOT_FILE"] = str(snap)
        stub = self.root / "du-fails"
        stub.write_text("#!/bin/sh\nexit 99\n")
        stub.chmod(0o755)
        os.environ["DISK_MAGICIAN_DU_BIN"] = str(stub)
        try:
            result = volume.audit_tmp()
        finally:
            if old is None: os.environ.pop("DISK_MAGICIAN_SNAPSHOT_FILE", None)
            else: os.environ["DISK_MAGICIAN_SNAPSHOT_FILE"] = old
            os.environ.pop("DISK_MAGICIAN_DU_BIN", None)
        self.assertEqual(result["status"], "measured")
        self.assertEqual(result["candidates"][0]["path"], "/private/tmp/worldai_frontend")

class ApprovedR13RegressionTest(VolumeTestBase):
    def setUp(self):
        super().setUp()
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))

    def install_exact_registry(self, state="active"):
        self.assertEqual(volume.create_cmd("scratch", execute=True), 0)
        path, _ = volume.registry_paths()
        registry = json.loads(path.read_text())
        registry["volumes"]["scratch"]["state"] = state
        path.write_text(json.dumps(registry))

    def test_load_container_selects_container_containing_data_role(self):
        data = json.loads(self.state.read_text())
        data["distractor_containers"] = [{
            "ref": "disk8", "uuid": "DECOY-CONTAINER", "ceiling": 500 * 2**30,
            "free": 400 * 2**30,
            "volumes": [{"uuid": "DECOY-DATA", "name": "Data", "ref": "disk8s1",
                         "device": "disk8s1", "used": 20 * 2**30, "quota": 0,
                         "roles": ["Data"], "mountpoint": "/Volumes/decoy-data"}],
        }]
        self.state.write_text(json.dumps(data))
        c = volume.load_container()
        self.assertEqual(c.ref, "disk3")
        self.assertEqual(c.uuid, "CONTAINER-UUID")

    def test_create_rejects_existing_mountpoint_before_diskutil_mutation(self):
        self.mp.mkdir(parents=True)
        self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        self.assertFalse(self.calls_file.exists())

    def test_create_only_accepts_encryption_none_with_acknowledgment(self):
        for encryption in (None, "encrypted", "filevault", "unsupported"):
            with self.subTest(encryption=encryption):
                config = json.loads(self.config.read_text())
                config["volumes"]["encryption"] = encryption
                self.config.write_text(json.dumps(config))
                self.assertEqual(volume.create_cmd("scratch", execute=True), 2)
                self.assertFalse(self.calls_file.exists())

    def test_path_and_ballast_require_exact_registry_identity(self):
        self.assertEqual(volume.create_cmd("scratch", execute=True), 0)
        registry_path, _ = volume.registry_paths()
        registry = json.loads(registry_path.read_text())
        registry["volumes"]["scratch"] = {"name": "diskm-scratch", "state": "active"}
        registry_path.write_text(json.dumps(registry))
        self.assertEqual(volume.path_cmd("scratch"), 75)
        self.assertEqual(volume.ballast_cmd("release", "scratch"), 75)
        self.assertTrue(volume.ballast_ok(self.mp))

    def test_for_reclaim_path_survives_released_ballast(self):
        self.install_exact_registry(state="retired")
        self.assertEqual(volume.ballast_cmd("release", "scratch"), 0)
        self.assertEqual(volume.path_cmd("scratch"), 3)
        self.assertEqual(volume.path_cmd("scratch", for_reclaim=True), 0)

    def test_unmounted_retired_volume_is_unavailable_not_legacy_fallback(self):
        self.install_exact_registry(state="retired")
        data = json.loads(self.state.read_text())
        data["mounted_mountpoint"] = str(self.root / "unmounted")
        self.state.write_text(json.dumps(data))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(volume.path_cmd("scratch"), 75)
        self.assertEqual(output.getvalue(), "")

    def test_registered_quota_must_match_live_measured_quota(self):
        self.install_exact_registry()
        data = json.loads(self.state.read_text())
        next(v for v in data["volumes"] if v["name"] == "diskm-scratch")["quota"] += 1
        self.state.write_text(json.dumps(data))
        self.assertEqual(volume.path_cmd("scratch"), 75)
        self.assertEqual(volume.retire_cmd("scratch"), 75)

    def test_config_rejects_bool_negative_and_nonpositive_capacities(self):
        for key, value in (("quota_gb", True), ("quota_gb", -1),
                           ("swap_headroom_gb", 0), ("alarm_floor_gb", -1)):
            with self.subTest(key=key, value=value):
                config = json.loads(self.config.read_text())
                if key == "quota_gb":
                    config["volumes"]["classes"]["scratch"][key] = value
                else:
                    config["volumes"][key] = value
                self.config.write_text(json.dumps(config))
                with self.assertRaises(ValueError):
                    volume.fit_result()
        self.assertFalse(self.calls_file.exists())

    def test_config_rejects_unsupported_v1_classes(self):
        config = json.loads(self.config.read_text())
        config["volumes"]["classes"]["evidence"] = {
            "name": "diskm-evidence", "quota_gb": 2,
            "mountpoint": str(self.root / "Volumes" / "evidence"),
        }
        self.config.write_text(json.dumps(config))
        with self.assertRaises(ValueError):
            volume.fit_result()
        self.assertEqual(volume.create_cmd("scratch", execute=True), 2)
        self.assertFalse(self.calls_file.exists())

    def test_create_ballast_failure_preserves_replacement_and_needs_recovery(self):
        import hashlib

        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))
        path = volume.ballast_path(str(self.mp))
        renamed_original = self.mp / "renamed-original-ballast"
        replacement = b"unrelated replacement payload"
        observed = {}

        def digest(target):
            value = hashlib.sha256()
            with target.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    value.update(chunk)
            return value.hexdigest()

        def replace_before_failed_verification(mountpoint):
            target = volume.ballast_path(mountpoint)
            if not target.exists():
                return False
            target.rename(renamed_original)
            target.write_bytes(replacement)
            observed["original_hash"] = digest(renamed_original)
            observed["replacement_hash"] = digest(target)
            return False

        with mock.patch.object(volume, "ballast_ok", side_effect=replace_before_failed_verification), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(volume.main(["create", "scratch", "--execute"]), 75)

        registry_path, _ = volume.registry_paths()
        entry = json.loads(registry_path.read_text())["volumes"]["scratch"]
        self.assertEqual((entry["state"], entry["uuid"]), ("needs_recovery", "SCRATCH-UUID"))
        self.assertEqual(self.calls_file.read_text().count("addVolume"), 1)
        self.assertEqual(path.read_bytes(), replacement)
        self.assertEqual(digest(path), observed["replacement_hash"])
        self.assertEqual(digest(renamed_original), observed["original_hash"])
        self.assertFalse(volume.ballast_ok(str(self.mp)))

    def test_write_ballast_failure_leaves_partial_file_and_closes_descriptor(self):
        self.mp.mkdir(parents=True)
        descriptor_state = {}
        real_fdopen = os.fdopen

        class PartialWriter:
            def __init__(self, descriptor, mode):
                self.stream = real_fdopen(descriptor, mode)
                descriptor_state["fd"] = descriptor
                self.wrote = False

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback):
                self.stream.close()

            def write(self, block):
                if self.wrote:
                    raise OSError("injected partial ballast write failure")
                self.wrote = True
                return self.stream.write(block[:4096])

            def flush(self):
                return self.stream.flush()

            def fileno(self):
                return self.stream.fileno()

        path = volume.ballast_path(str(self.mp))
        with mock.patch.object(volume.os, "fdopen", side_effect=PartialWriter):
            with self.assertRaisesRegex(OSError, "injected partial ballast write failure"):
                volume.write_ballast(str(self.mp))

        self.assertTrue(path.exists())
        self.assertEqual(path.stat().st_size, 4096)
        self.assertFalse(volume.ballast_ok(str(self.mp)))
        with self.assertRaises(OSError):
            os.fstat(descriptor_state["fd"])

    def test_write_ballast_fdopen_failure_preserves_file_and_closes_descriptor(self):
        mountpoint = self.root / "fdopen-failure"
        mountpoint.mkdir()
        descriptor_state = {}
        path = volume.ballast_path(str(mountpoint))

        def fail_fdopen(descriptor, mode):
            descriptor_state["fd"] = descriptor
            raise OSError("injected fdopen failure")

        with mock.patch.object(volume.os, "fdopen", side_effect=fail_fdopen):
            with self.assertRaisesRegex(OSError, "injected fdopen failure"):
                volume.write_ballast(str(mountpoint))

        self.assertTrue(path.exists())
        self.assertEqual(path.stat().st_size, 0)
        with self.assertRaises(OSError):
            os.fstat(descriptor_state["fd"])

    def test_write_ballast_refuses_to_change_existing_valid_reserve(self):
        import hashlib

        self.mp.mkdir(parents=True)
        path = volume.ballast_path(str(self.mp))
        volume.write_ballast(str(self.mp))
        before = (path.stat().st_ino, path.stat().st_size, hashlib.sha256(path.read_bytes()).hexdigest())

        with self.assertRaises(FileExistsError):
            volume.write_ballast(str(self.mp))

        after = (path.stat().st_ino, path.stat().st_size, hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(after, before)
        self.assertTrue(volume.ballast_ok(str(self.mp)))

    def test_sparse_ballast_failure_does_not_activate_volume(self):
        with mock.patch.object(volume, "write_ballast", side_effect=self.write_sparse_ballast):
            self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        registry_path, _ = volume.registry_paths()
        entry = json.loads(registry_path.read_text())["volumes"]["scratch"]
        self.assertEqual(entry["state"], "needs_recovery")
        self.assertEqual(entry["uuid"], "SCRATCH-UUID")

    def test_create_retries_exact_recorded_volume_after_ballast_failure(self):
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))
        with mock.patch.object(volume, "write_ballast", side_effect=RuntimeError("injected")):
            self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        registry_path, _ = volume.registry_paths()
        entry = json.loads(registry_path.read_text())["volumes"]["scratch"]
        self.assertEqual((entry["state"], entry["uuid"]), ("needs_recovery", "SCRATCH-UUID"))
        calls_before = self.calls_file.read_text().count("addVolume")
        self.assertEqual(volume.create_cmd("scratch", execute=True), 0)
        self.assertEqual(self.calls_file.read_text().count("addVolume"), calls_before)
        active = json.loads(registry_path.read_text())["volumes"]["scratch"]
        self.assertEqual(active["state"], "active")
        self.assertTrue(volume.ballast_ok(self.mp))

    def test_recovery_rechecks_live_fit_after_data_growth(self):
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))
        with mock.patch.object(volume, "write_ballast", side_effect=RuntimeError("injected")):
            self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        registry_path, _ = volume.registry_paths()
        calls_before = self.calls_file.read_text().count("addVolume")
        data = json.loads(self.state.read_text())
        next(row for row in data["volumes"] if row["name"] == "Data")["used"] = 899 * 2**30
        self.state.write_text(json.dumps(data))

        self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        entry = json.loads(registry_path.read_text())["volumes"]["scratch"]
        self.assertEqual(entry["state"], "needs_recovery")
        self.assertEqual(self.calls_file.read_text().count("addVolume"), calls_before)
        self.assertFalse(volume.ballast_path(str(self.mp)).exists())

    def test_recovery_rechecks_container_alarm_floor(self):
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))
        with mock.patch.object(volume, "write_ballast", side_effect=RuntimeError("injected")):
            self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        registry_path, _ = volume.registry_paths()
        calls_before = self.calls_file.read_text().count("addVolume")
        data = json.loads(self.state.read_text())
        data["container"]["free"] = 19 * 2**30
        self.state.write_text(json.dumps(data))

        self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        entry = json.loads(registry_path.read_text())["volumes"]["scratch"]
        self.assertEqual(entry["state"], "needs_recovery")
        self.assertEqual(self.calls_file.read_text().count("addVolume"), calls_before)
        self.assertFalse(volume.ballast_path(str(self.mp)).exists())

    def test_create_refuses_ambiguous_intent_without_uuid(self):
        data = json.loads(self.state.read_text())
        data["container"]["ceiling"] = 1000 * 2**30
        self.state.write_text(json.dumps(data))
        path, _ = volume.registry_paths()
        path.write_text(json.dumps({"schema_version": 1, "volumes": {
            "scratch": {"state": "creating", "class": "scratch", "name": "diskm-scratch",
                        "container_uuid": "CONTAINER-UUID", "mountpoint": str(self.mp),
                        "quota_bytes": 30 * 2**30}
        }}))
        self.assertEqual(volume.create_cmd("scratch", execute=True), 75)
        self.assertFalse(self.calls_file.exists())

    def write_sparse_ballast(self, mountpoint):
        path = volume.ballast_path(mountpoint)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as stream:
            stream.truncate(volume.BALLAST_BYTES)
        details = path.stat()
        self.assertEqual(details.st_size, volume.BALLAST_BYTES)
        self.assertLess(details.st_blocks * 512, volume.BALLAST_BYTES)
        self.assertFalse(volume.ballast_ok(mountpoint))
        raise RuntimeError("sparse ballast did not allocate reserved blocks")

    def test_volume_identity_rejects_wrong_mount_uuid_container_and_roles(self):
        self.install_exact_registry()
        for field, value in (("mounted_uuid", "OTHER-UUID"),
                             ("mounted_container_ref", "disk9"),
                             ("mounted_mountpoint", str(self.root / "elsewhere")),
                             ("mounted_roles", ["Data"])):
            with self.subTest(field=field):
                data = json.loads(self.state.read_text())
                data[field] = value
                self.state.write_text(json.dumps(data))
                self.assertEqual(volume.path_cmd("scratch"), 75)
                data.pop(field)
                self.state.write_text(json.dumps(data))

    def test_ballast_ensure_threshold_is_inclusive_1088_mib(self):
        self.install_exact_registry()
        data = json.loads(self.state.read_text())
        scratch = next(v for v in data["volumes"] if v["name"] == "diskm-scratch")
        scratch["used"] = scratch["quota"] - 1088 * 2**20
        self.state.write_text(json.dumps(data))
        self.assertEqual(volume.ballast_cmd("release", "scratch"), 0)
        self.assertEqual(volume.ballast_cmd("ensure", "scratch"), 0)
        volume.ballast_cmd("release", "scratch")
        data = json.loads(self.state.read_text())
        scratch = next(v for v in data["volumes"] if v["name"] == "diskm-scratch")
        scratch["used"] += 1
        self.state.write_text(json.dumps(data))
        self.assertEqual(volume.ballast_cmd("ensure", "scratch"), 75)
        self.assertFalse(volume.ballast_ok(self.mp))

if __name__ == "__main__":
    unittest.main()
