import importlib.util
import json
import os
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("volume", ROOT / "scripts" / "volume.py")
volume = importlib.util.module_from_spec(spec)
spec.loader.exec_module(volume)

class VolumeTestBase(unittest.TestCase):
    def setUp(self):
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

if __name__ == "__main__": unittest.main()

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
