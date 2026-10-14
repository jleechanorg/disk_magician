#!/usr/bin/env python3
"""PR184 recovery regressions using real C14/Git in isolated temporary roots.

Linux substitutes renameat2(RENAME_NOREPLACE) only for Darwin's unavailable
renameatx_np. The fixture lsof reports no users; production liveness and Darwin
rename integration still require the native platform suite.
"""
import ctypes
import json
import os
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import quarantine_rename as qr
import worktree_quarantine as wrh


def linux_exclusive_rename(srcfd, src, dstfd, dst):
    fn = ctypes.CDLL(None, use_errno=True).renameat2
    if fn(srcfd, os.fsencode(src), dstfd, os.fsencode(dst), ctypes.c_uint(1)):
        raise OSError(ctypes.get_errno(), "renameat2(RENAME_NOREPLACE)")


class QuarantineRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dm-review-quarantine-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        home = self.root / "home"
        home.mkdir()
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        lsof = bin_dir / "lsof"
        lsof.write_text("#!/bin/sh\nexit 1\n")
        lsof.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith("DISK_MAGICIAN_TEST_")}
        env.update(HOME=str(home), DISK_MAGICIAN_STATE_DIR=str(self.root / "state"),
                   TMPDIR=str(self.root), GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                   GIT_AUTHOR_NAME="test", GIT_AUTHOR_EMAIL="test@example.com",
                   GIT_COMMITTER_NAME="test", GIT_COMMITTER_EMAIL="test@example.com",
                   PATH=str(bin_dir) + os.pathsep + os.environ.get("PATH", ""))
        patch = mock.patch.dict(os.environ, env, clear=True)
        patch.start()
        self.addCleanup(patch.stop)
        if sys.platform.startswith("linux"):
            patch = mock.patch.object(qr, "renamex", side_effect=linux_exclusive_rename)
            patch.start()
            self.addCleanup(patch.stop)
        elif sys.platform != "darwin":
            self.skipTest("exclusive rename fixture supports Linux and Darwin")
        self.quarantine = self.root / ".dm-quarantine"

    def run_cmd(self, *args, env=None):
        return subprocess.run([str(a) for a in args], check=True, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env).stdout.strip()

    def inventory(self, path, name="inventory"):
        out = self.root / (name + ".json")
        self.assertEqual(self.run_cmd(sys.executable, ROOT / "scripts/c14_probe.py",
                                      "inventory", path, out), "ok")
        return out

    def generic_fixture(self, kind="dir"):
        original = self.root / "candidate"
        if kind == "dir":
            (original / "nested").mkdir(parents=True)
            (original / "nested/payload").write_bytes(b"preserve these bytes\n")
            (original / "link").symlink_to("nested/payload")
        else:
            original.write_bytes(b"single file payload\n")
        inv = self.inventory(original)
        binding = self.root / "binding.json"
        self.assertEqual(qr.bind_parent(str(original), str(binding)), "ok")
        result = qr.phase1(str(original), str(inv), str(binding))
        self.assertTrue(result.startswith("quarantined:"), result)
        return original, result.split(":")[1], binding

    def worktree_fixture(self, symlink=False):
        main, worktree = self.root / "main", self.root / "checkout"
        self.run_cmd("git", "init", "-q", main)
        (main / "base").write_bytes(b"tracked payload\n")
        self.run_cmd("git", "-C", main, "add", "base")
        if symlink:
            (main / "base-link").symlink_to("base")
            self.run_cmd("git", "-C", main, "add", "base-link")
        self.run_cmd("git", "-C", main, "commit", "-qm", "base")
        self.run_cmd("git", "-C", main, "worktree", "add", "-q", "-b", "selected", worktree)
        sibling = self.root / "sibling"
        self.run_cmd("git", "-C", main, "worktree", "add", "-q", "-b", "sibling", sibling)
        admin = Path(self.run_cmd("git", "-C", worktree, "rev-parse", "--absolute-git-dir"))
        checkout_inventory = self.inventory(worktree, "checkout-inventory")
        admin_rows = self.root / "admin-rows.jsonl"
        env = dict(os.environ, C14_INVENTORY_OUT=str(admin_rows))
        self.run_cmd(sys.executable, ROOT / "scripts/c14_probe.py", "admin", admin, env=env)
        receipt = self.root / "receipt.json"
        self.run_cmd(sys.executable, ROOT / "scripts/c14_probe.py", "merge-inventory",
                     checkout_inventory, admin_rows, receipt)
        gitdir_before = (admin / "gitdir").read_bytes()
        result = wrh.phase1(str(main), str(worktree), str(receipt))
        self.assertTrue(result.startswith("quarantined:"), result)
        qid = result.split(":")[1]
        self.assertNotEqual((admin / "gitdir").read_bytes(), gitdir_before)
        self.assertTrue((admin / "locked").exists())
        return main, worktree, admin, qid, gitdir_before

    def sidecar(self, qid):
        return self.quarantine / (qid + ".json")

    def assert_finished(self, qid):
        self.assertFalse(self.sidecar(qid).exists())
        self.assertFalse((qr.index_dir() / (qid + ".json")).exists())

    def test_real_c14_directory_inventory_restores(self):
        original, qid, _ = self.generic_fixture()
        rows = json.loads(self.sidecar(qid).read_text())["inventory"]
        self.assertTrue(all("size" in e for e in rows if e["type"] == "dir"))
        self.assertEqual(qr.quarantine_restore(qid), "restored:" + qid)
        self.assertEqual((original / "nested/payload").read_bytes(), b"preserve these bytes\n")
        self.assertEqual(os.readlink(original / "link"), "nested/payload")
        self.assert_finished(qid)

    def test_changed_file_bytes_still_block_restore(self):
        original, qid, _ = self.generic_fixture()
        (self.quarantine / qid / "nested/payload").write_bytes(b"modified after capture\n")
        self.assertEqual(qr.quarantine_restore(qid), "kept:quarantine_partial_kept")
        self.assertFalse(original.exists())
        self.assertTrue(self.sidecar(qid).exists())

    def test_replacement_directory_still_blocks_restore(self):
        original, qid, _ = self.generic_fixture()
        (self.quarantine / qid).rename(self.root / "preserved-candidate")
        (self.quarantine / qid).mkdir()
        (self.quarantine / qid / "sentinel").write_bytes(b"replacement")
        self.assertEqual(qr.quarantine_restore(qid), "kept:identity-mismatch")
        self.assertFalse(original.exists())
        self.assertEqual((self.quarantine / qid / "sentinel").read_bytes(), b"replacement")
        self.assertTrue(self.sidecar(qid).exists())

    def test_single_file_crash_before_sidecar_drop_reconciles(self):
        original, qid, binding = self.generic_fixture("file")
        pid = os.fork()
        if pid == 0:
            os.environ["DISK_MAGICIAN_TEST_KILL_AT"] = "before_sidecar_drop"
            qr.phase2(str(binding), qid)
            os._exit(42)
        _, status = os.waitpid(pid, 0)
        self.assertTrue(os.WIFSIGNALED(status))
        self.assertEqual(os.WTERMSIG(status), signal.SIGKILL)
        record = json.loads(self.sidecar(qid).read_text())
        self.assertTrue(record["root_removed"])
        self.assertEqual(record["phase"], "deleting")
        self.assertNotIn(".", record.get("removed_paths", []))
        self.assertFalse(original.exists())
        self.assertFalse((self.quarantine / qid).exists())
        self.assertEqual(qr.reconcile_one(qid), "removed:" + qid)
        self.assert_finished(qid)

    def test_legacy_single_file_completed_root_journal_reconciles(self):
        _, qid, _ = self.generic_fixture("file")
        record = json.loads(self.sidecar(qid).read_text())
        (self.quarantine / qid).unlink()
        record.update(phase="deleting", root_removed=True, removed_paths=["."])
        self.sidecar(qid).write_text(json.dumps(record))
        self.assertEqual(qr.reconcile_one(qid), "removed:" + qid)
        self.assert_finished(qid)

    def test_missing_file_without_completion_marker_stays_unresolved(self):
        _, qid, _ = self.generic_fixture("file")
        record = json.loads(self.sidecar(qid).read_text())
        (self.quarantine / qid).rename(self.root / "moved-payload")
        record.update(phase="deleting", removed_paths=["."])
        self.sidecar(qid).write_text(json.dumps(record))
        self.assertEqual(qr.reconcile_one(qid), "kept:quarantine_partial_kept:" + qid)
        self.assertEqual((self.root / "moved-payload").read_bytes(), b"single file payload\n")
        self.assertTrue(self.sidecar(qid).exists())

    def test_corrupt_root_progress_journals_preserve_present_file(self):
        _, qid, _ = self.generic_fixture("file")
        record = json.loads(self.sidecar(qid).read_text())
        record.update(phase="deleting", root_removed=True)
        for removed in (["."], [".", "."], ["unknown"], [1], "."):
            with self.subTest(removed_paths=removed):
                record["removed_paths"] = removed
                self.sidecar(qid).write_text(json.dumps(record))
                self.assertEqual(qr.reconcile_one(qid), "kept:quarantine_partial_kept:" + qid)
                self.assertEqual((self.quarantine / qid).read_bytes(), b"single file payload\n")
                self.assertTrue(self.sidecar(qid).exists())

    def test_directory_root_progress_is_not_accepted_as_legacy_file(self):
        _, qid, _ = self.generic_fixture()
        record = json.loads(self.sidecar(qid).read_text())
        (self.quarantine / qid).rename(self.root / "preserved-candidate")
        record.update(phase="deleting", root_removed=True, removed_paths=["."])
        self.sidecar(qid).write_text(json.dumps(record))
        self.assertEqual(qr.reconcile_one(qid), "kept:quarantine_partial_kept:" + qid)
        self.assertTrue((self.root / "preserved-candidate/nested/payload").exists())
        self.assertTrue(self.sidecar(qid).exists())

    def test_generic_restore_repairs_worktree_registration_and_lock(self):
        main, original, admin, qid, gitdir_before = self.worktree_fixture()
        self.assertEqual(qr.quarantine_restore(qid), "restored:" + qid)
        self.assertEqual((admin / "gitdir").read_bytes(), gitdir_before)
        self.assertFalse((admin / "locked").exists())
        self.assertEqual(self.run_cmd("git", "-C", original, "status", "--porcelain"), "")
        listing = self.run_cmd("git", "-C", main, "worktree", "list", "--porcelain")
        self.assertIn("worktree " + str(original), listing)
        self.assertNotIn(str(self.quarantine), listing)
        self.assert_finished(qid)

    def test_generic_dispatch_precedes_payload_rename(self):
        _, original, _, qid, _ = self.worktree_fixture()
        with mock.patch.object(wrh, "restore", return_value="delegated") as restore, \
                mock.patch.object(qr, "renamex") as rename:
            self.assertEqual(qr.quarantine_restore(qid, None), "delegated")
        restore.assert_called_once_with(qid, None)
        rename.assert_not_called()
        self.assertFalse(original.exists())
        self.assertTrue(self.sidecar(qid).exists())

    def test_worktree_restore_normalizes_real_c14_symlink_sizes(self):
        _, original, admin, qid, gitdir_before = self.worktree_fixture(symlink=True)
        rows = json.loads(self.sidecar(qid).read_text())["inventory"]
        self.assertTrue(any(e["type"] == "symlink" and "size" in e for e in rows))
        self.assertEqual(qr.quarantine_restore(qid), "restored:" + qid)
        self.assertEqual(os.readlink(original / "base-link"), "base")
        self.assertEqual((admin / "gitdir").read_bytes(), gitdir_before)
        self.assertFalse((admin / "locked").exists())
        self.assertEqual(self.run_cmd("git", "-C", original, "status", "--porcelain"), "")
        self.assert_finished(qid)

    def test_public_quarantine_restore_repairs_worktree(self):
        main, original, admin, qid, gitdir_before = self.worktree_fixture()
        env = dict(os.environ)
        if sys.platform.startswith("linux"):
            if not shutil.which("cc"):
                self.skipTest("Linux public CLI rename adapter requires cc")
            source, adapter = self.root / "rename-adapter.c", self.root / "rename-adapter.so"
            source.write_text("#define _GNU_SOURCE\n#include <stdio.h>\n#include <errno.h>\n"
                              "int renameatx_np(int sfd, const char *s, int dfd, const char *d, unsigned f) {\n"
                              "  if (f != 4) { errno = EINVAL; return -1; }\n"
                              "  return renameat2(sfd, s, dfd, d, 1);\n}\n")
            self.run_cmd("cc", "-shared", "-fPIC", source, "-o", adapter)
            env["LD_PRELOAD"] = str(adapter)
        result = self.run_cmd("bash", ROOT / "disk_magician.sh", "quarantine", "restore", qid, env=env)
        self.assertEqual(result, "restored:" + qid)
        self.assertEqual((admin / "gitdir").read_bytes(), gitdir_before)
        self.assertFalse((admin / "locked").exists())
        self.assertEqual(self.run_cmd("git", "-C", original, "status", "--porcelain"), "")
        self.assertNotIn(str(self.quarantine), self.run_cmd("git", "-C", main, "worktree", "list", "--porcelain"))
        self.assert_finished(qid)

    def test_generic_worktree_restore_rejects_replaced_admin(self):
        _, original, admin, qid, _ = self.worktree_fixture()
        admin.rename(admin.with_name("preserved-admin"))
        admin.mkdir()
        (admin / "gitdir").write_bytes(b"replacement metadata\n")
        self.assertEqual(qr.quarantine_restore(qid), "kept:quarantine_partial_kept")
        self.assertEqual((admin / "gitdir").read_bytes(), b"replacement metadata\n")
        self.assertFalse(original.exists())
        self.assertTrue((self.quarantine / qid / "base").exists())
        self.assertTrue(self.sidecar(qid).exists())

    def test_worktree_restore_rejects_payload_swap_at_rename_boundary(self):
        _, original, admin, qid, _ = self.worktree_fixture()
        captured = (self.quarantine / qid).stat()
        saved = self.root / "captured-checkout"
        gitdir_before, lock_before = (admin / "gitdir").read_bytes(), (admin / "locked").read_bytes()
        rename = wrh.safe_rename
        def swap_before_rename(srcfd, src, dstfd, dst):
            (self.quarantine / qid).rename(saved)
            (self.quarantine / qid).mkdir()
            (self.quarantine / qid / ".git").write_bytes((saved / ".git").read_bytes())
            (self.quarantine / qid / "replacement").write_bytes(b"foreign checkout generation\n")
            return rename(srcfd, src, dstfd, dst)
        with mock.patch.object(wrh, "safe_rename", side_effect=swap_before_rename), \
                mock.patch.object(wrh, "run", wraps=wrh.run) as run, \
                mock.patch.object(wrh, "restore_gitdir", wraps=wrh.restore_gitdir) as restore_gitdir, \
                mock.patch.object(qr, "finish_sidecar", wraps=qr.finish_sidecar) as finish:
            result = qr.quarantine_restore(qid)
        self.assertEqual(result, "kept:restore-identity-mismatch")
        run.assert_not_called()
        restore_gitdir.assert_not_called()
        finish.assert_not_called()
        self.assertEqual((saved.stat().st_dev, saved.stat().st_ino), (captured.st_dev, captured.st_ino))
        self.assertEqual((saved / "base").read_bytes(), b"tracked payload\n")
        self.assertEqual((original / "replacement").read_bytes(), b"foreign checkout generation\n")
        self.assertEqual((admin / "gitdir").read_bytes(), gitdir_before)
        self.assertEqual((admin / "locked").read_bytes(), lock_before)
        record = json.loads(self.sidecar(qid).read_text())
        self.assertEqual(record["phase"], "restore_conflict")
        self.assertEqual(record["restore_conflict"]["expected"], {"dev": captured.st_dev, "ino": captured.st_ino})
        restored = original.stat()
        self.assertEqual(record["restore_conflict"]["observed"], {"dev": restored.st_dev, "ino": restored.st_ino})
        self.assertTrue((qr.index_dir() / (qid + ".json")).exists())

    def check_reconcile_root_binding(self, mode, journal_failure=False):
        main, original, admin, qid, original_gitdir = self.worktree_fixture()
        quarantine = self.quarantine / qid
        sibling = self.root / "sibling"
        sibling_admin = Path(self.run_cmd("git", "-C", sibling, "rev-parse", "--absolute-git-dir"))
        self.run_cmd("git", "-C", main, "worktree", "lock", "--reason", "foreign owner", sibling)
        captured, foreign = quarantine.stat(), sibling.stat()
        saved = self.root / "captured-checkout"
        foreign_before = {str(p.relative_to(sibling_admin)): p.read_bytes()
                          for p in sibling_admin.rglob("*") if p.is_file()}
        gitdir_before, lock_before = (admin / "gitdir").read_bytes(), (admin / "locked").read_bytes()
        record_before = self.sidecar(qid).read_bytes()
        rename = wrh.safe_rename
        def swap():
            quarantine.rename(saved)
            sibling.rename(quarantine)
        def boundary_rename(srcfd, src, dstfd, dst):
            if mode == "rename-boundary":
                swap()
            return rename(srcfd, src, dstfd, dst)
        if mode == "precheck":
            swap()
        with mock.patch.object(wrh, "safe_rename", side_effect=boundary_rename), \
                mock.patch.object(wrh, "run", wraps=wrh.run) as run, \
                mock.patch.object(qr, "finish_sidecar", wraps=qr.finish_sidecar) as finish, \
                mock.patch.object(qr, "update_sidecar", wraps=qr.update_sidecar,
                                  side_effect=OSError("injected conflict journal failure") if journal_failure else None):
            result = qr.reconcile_one(qid)
        self.assertEqual({str(p.relative_to(sibling_admin)): p.read_bytes()
                          for p in sibling_admin.rglob("*") if p.is_file()}, foreign_before)
        captured_location = original if mode == "unchanged" else saved
        foreign_location = original if mode == "rename-boundary" else (quarantine if mode == "precheck" else sibling)
        self.assertEqual((captured_location.stat().st_dev, captured_location.stat().st_ino), (captured.st_dev, captured.st_ino))
        self.assertEqual((foreign_location.stat().st_dev, foreign_location.stat().st_ino), (foreign.st_dev, foreign.st_ino))
        self.assertEqual((captured_location / "base").read_bytes(), b"tracked payload\n")
        self.assertEqual((foreign_location / "base").read_bytes(), b"tracked payload\n")
        if mode == "unchanged":
            self.assertEqual(result, "reconciled:" + qid + ":rolled-back")
            self.assertEqual((admin / "gitdir").read_bytes(), original_gitdir)
            self.assertFalse((admin / "locked").exists())
            self.assert_finished(qid)
            return
        self.assertTrue(result.startswith("alert:" + qid + ":quarantine_conflict:" + qid), result)
        self.assertEqual((admin / "gitdir").read_bytes(), gitdir_before)
        self.assertEqual((admin / "locked").read_bytes(), lock_before)
        finish.assert_not_called()
        self.assertTrue(self.sidecar(qid).exists())
        self.assertTrue((qr.index_dir() / (qid + ".json")).exists())
        if mode == "precheck":
            run.assert_not_called()
        else:
            # Only repair of the captured quarantine before the injected swap
            # may run. No original-path repair or foreign unlock may follow.
            self.assertEqual([call.args for call in run.call_args_list], [
                ("git", "-C", str(main), "worktree", "repair", str(quarantine))])
            if journal_failure:
                self.assertTrue(result.endswith(":restore-state-update-failed"), result)
                self.assertEqual(self.sidecar(qid).read_bytes(), record_before)
            else:
                record = json.loads(self.sidecar(qid).read_text())
                self.assertEqual(record["phase"], "restore_conflict")
                self.assertEqual(record["wrh_phase"], "restore_conflict")
                self.assertEqual(record["restore_conflict"]["expected"], {"dev": captured.st_dev, "ino": captured.st_ino})
                self.assertEqual(record["restore_conflict"]["observed"], {"dev": foreign.st_dev, "ino": foreign.st_ino})

    def test_reconcile_rollback_preserves_foreign_admin_and_lock_after_boundary_swap(self):
        self.check_reconcile_root_binding("rename-boundary")

    def test_reconcile_rollback_conflict_journal_failure_still_blocks_git_writes(self):
        self.check_reconcile_root_binding("rename-boundary", journal_failure=True)

    def test_reconcile_rollback_preserves_early_replacement_without_git_writes(self):
        self.check_reconcile_root_binding("precheck")

    def test_reconcile_rollback_same_generation_succeeds_and_preserves_foreign_lock(self):
        self.check_reconcile_root_binding("unchanged")

    def check_admin_journal_interruption(self, crash):
        main, original, admin, qid, _ = self.worktree_fixture()
        sibling_admin = Path(self.run_cmd("git", "-C", self.root / "sibling",
                                          "rev-parse", "--absolute-git-dir"))
        sibling_before = {str(p.relative_to(sibling_admin)): p.read_bytes()
                          for p in sibling_admin.rglob("*") if p.is_file()}
        old_hook = qr.hook
        def interrupt_admin(name, path, rel):
            if name == "DISK_MAGICIAN_TEST_AFTER_ENTRY_JOURNAL" and not path:
                if crash:
                    os.kill(os.getpid(), signal.SIGKILL)
                raise qr.DeadlineExceeded()
            return old_hook(name, path, rel)
        if crash:
            pid = os.fork()
            if pid == 0:
                qr.hook = interrupt_admin
                wrh.phase2(qid)
                os._exit(42)
            _, status = os.waitpid(pid, 0)
            self.assertTrue(os.WIFSIGNALED(status))
            self.assertEqual(os.WTERMSIG(status), signal.SIGKILL)
        else:
            with mock.patch.object(qr, "hook", side_effect=interrupt_admin):
                self.assertEqual(wrh.phase2(qid), "deferred:phase2")
        record = json.loads(self.sidecar(qid).read_text())
        self.assertTrue(record.get("admin_removed_paths"))
        self.assertEqual(record.get("phase"), "deleting")
        self.assertIs(record.get("root_removed"), True)
        self.assertEqual(record.get("wrh_phase"), "checkout_removed")
        self.assertFalse(original.exists())
        self.assertFalse((self.quarantine / qid).exists())
        self.assertEqual(qr.reconcile_one(qid), "reconciled:" + qid + ":removed")
        self.assertFalse(admin.exists())
        self.assert_finished(qid)
        self.assertEqual({str(p.relative_to(sibling_admin)): p.read_bytes()
                          for p in sibling_admin.rglob("*") if p.is_file()}, sibling_before)
        listing = self.run_cmd("git", "-C", main, "worktree", "list", "--porcelain")
        self.assertNotIn(str(self.quarantine), listing)

    def test_first_call_admin_journal_crash_preserves_checkout_completion(self):
        self.check_admin_journal_interruption(crash=True)

    def test_first_call_admin_deadline_preserves_checkout_completion(self):
        self.check_admin_journal_interruption(crash=False)


if __name__ == "__main__":
    unittest.main()
