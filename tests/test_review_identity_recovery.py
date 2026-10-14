#!/usr/bin/env python3
"""PR184 regressions; only temporary roots and mocked operational commands."""
import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import birth_audit
import disk_budget
import worktree_quarantine as wrh


class MeasurementRecoveryTest(unittest.TestCase):
    def test_daily_failure_then_tick_success_records_freshness(self):
        with tempfile.TemporaryDirectory(prefix="dm-review-measure-") as tmp:
            state = Path(tmp)
            root = state / "worktrees"
            root.mkdir()
            budgets = {"classes": {"worktrees": {"measure": "du"}}}
            (state / "budget.json").write_text(json.dumps({"classes": {
                "worktrees": {"used_gb": 1, "measured_at": 100}}}))
            with mock.patch.object(disk_budget, "class_measure_roots", return_value=[str(root)]), \
                    mock.patch.object(disk_budget, "_du_kb", return_value=None):
                self.assertEqual(disk_budget.daily_measure(state, budgets), 0)
            self.assertTrue(json.loads((state / "budget.json").read_text())["classes"]["worktrees"]["carried"])
            with mock.patch.object(disk_budget, "class_measure_roots", return_value=[str(root)]), \
                    mock.patch.object(disk_budget, "_du_kb", return_value=2048):
                self.assertEqual(disk_budget.measure_tick_class(state, budgets, 200, None), "worktrees")
            self.assert_fresh(state, budgets, "worktrees", 200)

    def test_daily_failure_then_fresh_observer_records_freshness(self):
        with tempfile.TemporaryDirectory(prefix="dm-review-observer-") as tmp:
            state = Path(tmp)
            budgets = {"classes": {"colima": {"measure": "observer"}}}
            (state / "budget.json").write_text(json.dumps({"classes": {
                "colima": {"used_gb": 1, "measured_at": 100}}}))
            with mock.patch.object(disk_budget, "_observer_colima", return_value=None):
                self.assertEqual(disk_budget.daily_measure(state, budgets), 0)
                disk_budget.observer_refresh(state, budgets, 190)
            self.assertTrue(json.loads((state / "budget.json").read_text())["classes"]["colima"]["carried"])
            with mock.patch.object(disk_budget, "_observer_colima", return_value={
                    "kb": 2048, "observed_at": 199, "fresh": True}):
                disk_budget.observer_refresh(state, budgets, 200)
            self.assert_fresh(state, budgets, "colima", 199)

    def assert_fresh(self, state, budgets, name, stamp):
        stats = json.loads((state / "budget.json").read_text())["classes"][name]
        self.assertEqual(stats["measured_at"], stamp)
        self.assertFalse(stats["carried"])
        with mock.patch.object(disk_budget.budget_history, "collect_fleet_health", return_value=("healthy", None)), \
                mock.patch.object(disk_budget.budget_history, "collect_colima_status", return_value=None), \
                mock.patch.object(disk_budget.budget_history, "record_tick") as record:
            disk_budget._record_govern_tick(state, budgets, 200, 999, "GREEN")
        fresh = record.call_args.kwargs["classes_fresh"]
        if budgets["classes"][name]["measure"] == "du":
            self.assertTrue(fresh[name])
        else:
            self.assertNotIn(name, fresh)  # history's coverage is du-only


class BirthGenerationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dm-review-birth-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "birth"
        self.path.mkdir()
        st = self.path.lstat()
        self.birth = {"path": str(self.path), "dev": st.st_dev, "ino": st.st_ino,
                      "cls": "worktrees", "status": "admitted", "bytes": None,
                      "charge": "estimate", "estimate_bytes": 8192, "unknown_retries": 1}

    def replace(self):
        self.path.rename(self.path.with_name("old"))
        self.path.mkdir()

    def measure(self):
        return birth_audit.measure_births({"old": self.birth}, {}, 200, 10, None)

    def test_replacement_before_retry_is_not_measured_as_old_birth(self):
        old = dict(self.birth)
        self.replace()
        with mock.patch.object(birth_audit, "_du_bytes", return_value=4096) as du:
            largest = self.measure()
        self.assertEqual(self.birth, old)
        self.assertEqual(largest, {})
        du.assert_not_called()

    def test_replacement_during_measurement_discards_unbound_bytes(self):
        old = dict(self.birth)
        def replace_during_du(*args):
            self.replace()
            return 4096
        with mock.patch.object(birth_audit, "_du_bytes", side_effect=replace_during_du):
            largest = self.measure()
        self.assertEqual(self.birth, old)
        self.assertEqual(largest, {})

    def test_missing_generation_keeps_estimate(self):
        old = dict(self.birth)
        self.path.rename(self.path.with_name("gone"))
        with mock.patch.object(birth_audit, "_du_bytes") as du:
            self.assertEqual(self.measure(), {})
        self.assertEqual(self.birth, old)
        du.assert_not_called()

    def test_same_generation_success_replaces_estimate(self):
        with mock.patch.object(birth_audit, "_du_bytes", return_value=4096):
            self.assertEqual(self.measure(), {"worktrees": 4096})
        self.assertEqual(self.birth["bytes"], 4096)
        self.assertEqual(self.birth["charge"], "measured")
        self.assertEqual(self.birth["unknown_retries"], 0)

    def test_same_generation_failure_consumes_one_retry(self):
        with mock.patch.object(birth_audit, "_du_bytes", return_value=None):
            self.assertEqual(self.measure(), {})
        self.assertIsNone(self.birth["bytes"])
        self.assertEqual(self.birth["charge"], "estimate")
        self.assertEqual(self.birth["unknown_retries"], 2)


class RollbackIdentityTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dm-review-rollback-")
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.quarantine = self.parent / ".dm-quarantine"
        self.quarantine.mkdir()
        self.qid = "0123456789abcdef"
        self.checkout = self.quarantine / self.qid
        self.checkout.mkdir()
        (self.checkout / "payload").write_bytes(b"preserve checkout")
        self.admin = self.parent / "admin"
        self.admin.mkdir()
        self.gitdir = self.admin / "gitdir"
        self.gitdir.write_bytes(b"original gitdir\n")
        st, ast, gst = self.checkout.stat(), self.admin.stat(), self.gitdir.stat()
        self.record = {"original": str(self.parent / "checkout"), "dev": st.st_dev, "ino": st.st_ino,
                       "worktree_admin_path": str(self.admin), "worktree_main": str(self.parent / "main"),
                       "original_gitdir_hex": self.gitdir.read_bytes().hex(),
                       "worktree_admin_inventory": [
                           {"path": ".", "type": "dir", "dev": ast.st_dev, "ino": ast.st_ino},
                           {"path": "gitdir", "type": "file", "dev": gst.st_dev, "ino": gst.st_ino,
                            "size": gst.st_size, "sha256": hashlib.sha256(self.gitdir.read_bytes()).hexdigest()}]}
        self.pfd = os.open(self.parent, wrh.DIR)
        self.qfd = os.open(self.quarantine, wrh.DIR)
        self.addCleanup(os.close, self.pfd)
        self.addCleanup(os.close, self.qfd)
        run_patch = mock.patch.object(wrh, "run")
        self.run = run_patch.start()
        self.addCleanup(run_patch.stop)
        finish_patch = mock.patch.object(wrh.qr, "finish_sidecar", return_value=True)
        self.finish = finish_patch.start()
        self.addCleanup(finish_patch.stop)
        def rename(srcfd, src, dstfd, dst):
            os.rename(src, dst, src_dir_fd=srcfd, dst_dir_fd=dstfd)
        rename_patch = mock.patch.object(wrh, "safe_rename", side_effect=rename)
        rename_patch.start()
        self.addCleanup(rename_patch.stop)

    def rollback(self):
        return wrh.rollback(self.pfd, self.qfd, self.qid, self.record)

    def assert_conflict_preserves_replacement(self, original=False):
        before = self.gitdir.read_bytes()
        result = self.rollback()
        self.assertEqual(self.gitdir.read_bytes(), before)
        self.assertEqual(result, "quarantine_conflict:" + self.qid)
        checkout = Path(self.record["original"]) if original else self.checkout
        self.assertEqual((checkout / "payload").read_bytes(), b"preserve checkout")
        self.run.assert_not_called()
        self.finish.assert_not_called()

    def test_replacement_admin_keeps_quarantined_checkout_and_metadata(self):
        self.admin.rename(self.parent / "old-admin")
        self.admin.mkdir()
        self.gitdir.write_bytes(b"replacement metadata must survive\n")
        self.assert_conflict_preserves_replacement()

    def test_replacement_admin_keeps_original_checkout_and_metadata(self):
        self.checkout.rename(self.record["original"])
        self.admin.rename(self.parent / "old-admin")
        self.admin.mkdir()
        self.gitdir.write_bytes(b"replacement metadata must survive\n")
        self.assert_conflict_preserves_replacement(original=True)

    def test_replaced_gitdir_is_not_truncated(self):
        self.gitdir.rename(self.admin / "old-gitdir")
        self.gitdir.write_bytes(b"new gitdir inode must survive\n")
        self.assert_conflict_preserves_replacement()

    def test_same_admin_and_gitdir_can_roll_back(self):
        original = self.gitdir.read_bytes()
        self.assertEqual(self.rollback(), "kept:admin-changed")
        self.assertEqual(self.gitdir.read_bytes(), original)
        self.assertEqual((Path(self.record["original"]) / "payload").read_bytes(), b"preserve checkout")
        self.finish.assert_called_once()

    def test_missing_admin_proof_keeps_payload(self):
        self.record["worktree_admin_inventory"] = []
        self.assert_conflict_preserves_replacement()

    def test_symlink_admin_keeps_payload(self):
        self.admin.rename(self.parent / "old-admin")
        self.admin.symlink_to(self.parent / "old-admin", target_is_directory=True)
        self.assert_conflict_preserves_replacement()

    def test_explicit_restore_rejects_replacement_before_moving_checkout(self):
        self.admin.rename(self.parent / "old-admin")
        self.admin.mkdir()
        self.gitdir.write_bytes(b"replacement metadata must survive\n")
        before = self.gitdir.read_bytes()
        self.record.update(worktree_admin=True, phase="quarantined", inventory=[])
        with mock.patch.object(wrh.qr, "indexed_item", return_value=(
                {"parent_path": str(self.parent)}, os.dup(self.pfd), os.dup(self.qfd), self.record)), \
                mock.patch.object(wrh.qr, "visit", return_value=[]):
            self.assertEqual(wrh.restore(self.qid), "kept:quarantine_partial_kept")
        self.assertEqual(self.gitdir.read_bytes(), before)
        self.assertTrue(self.checkout.exists())
        self.run.assert_not_called()
        self.finish.assert_not_called()


if __name__ == "__main__":
    unittest.main()
