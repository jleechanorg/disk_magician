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
        self.root = pathlib.Path(self.temp.name)
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
        for entries, expected_alarm in cases:
            with self.subTest(expected_alarm=expected_alarm):
                data = json.loads(self.state.read_text())
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
