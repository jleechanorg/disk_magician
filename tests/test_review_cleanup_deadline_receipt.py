#!/usr/bin/env python3
"""PR184 cleanup regressions; all mutation is confined to temporary fixtures.

Run: python3 tests/test_review_cleanup_deadline_receipt.py
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class CleanupReviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="review-cleanup-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        for name in ("home", "private-tmp", "tmp", "user-tmp", "state", "bin"):
            (self.root / name).mkdir()
        self.bin = self.root / "bin"
        self.write_shim("lsof", "printf 'p1234\\nfcwd\\nn/\\n'\n")
        # Keep receipt accounting deterministic even on hosts where awk prints
        # real df byte counts in scientific notation.
        self.write_shim("df", "printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\nfixture 2048 1024 1024 50%% /\\n'\n")
        # cleanup_tmp's archive-age probe uses BSD stat first. GNU stat -f
        # prints filesystem data before rejecting the BSD format, so adapt
        # that one query for Linux instead of changing unrelated production code.
        if os.uname().sysname == "Linux":
            self.write_shim("stat", 'if [[ "${1:-}" == -f && "${2:-}" == %m ]]; then shift 2; exec /usr/bin/stat -c %Y "$@"; fi\nexec /usr/bin/stat "$@"\n')
        safety = self.root / "safety.json"
        safety.write_text('{"never_delete": []}\n')
        self.env = {
            "HOME": str(self.root / "home"),
            # Keep test shims first, then the runner's Python so deadline
            # calculations and shell helpers use the same monotonic clock.
            "PATH": f"{self.bin}:{Path(sys.executable).parent}:/usr/bin:/bin",
            "REVIEW_PYTHON": sys.executable,
            "TMPDIR": str(self.root / "tmp"),
            "LC_ALL": "C",
            "DISK_MAGICIAN_TEST_CONTEXT": "1",
            "DISK_MAGICIAN_TEST_SANDBOX": str(self.root),
            "DISK_MAGICIAN_STATE_DIR": str(self.root / "state"),
            "DISK_MAGICIAN_DELETION_LOG": str(self.root / "deletions.jsonl"),
            "DISK_MAGICIAN_SAFETY_FILE": str(safety),
            "DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE": str(self.root / "private-tmp"),
            "DISK_MAGICIAN_TMP_ROOT_OVERRIDE": str(self.root / "tmp"),
            "DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE": str(self.root / "user-tmp"),
            "DISK_MAGICIAN_ARCHIVE_ROOT": str(self.root / "archive"),
            "DISK_MAGICIAN_LSOF_BIN": str(self.bin / "lsof"),
            "LARGE_TMP_APPROVED": "1",
            "LARGE_TMP_MIN_KB": "1",
            # A newly moved old directory must not be purged during this test.
            "LARGE_TMP_ARCHIVE_RETENTION_HOURS": "876000",
            "LARGE_TMP_ARCHIVE_MAX_HOURS": "876000",
        }

    def write_shim(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + body)
        path.chmod(0o755)

    def run_cleanup(self, script, *args):
        result = subprocess.run(
            ["/bin/bash", str(REPO_ROOT / "scripts" / script), *args],
            cwd=self.root, env=self.env, capture_output=True, text=True, timeout=60,
        )
        # Raw subprocess output accompanies both GREEN and RED test artifacts.
        print(f"\n{self.id()} exit={result.returncode}\n{result.stdout}{result.stderr}", flush=True)
        return result

    def receipt(self, job):
        return json.loads((self.root / "state" / "receipts" / f"{job}.json").read_text())

    def test_fixture_python_matches_runner(self):
        executable = subprocess.check_output(
            ["python3", "-c", "import sys; print(sys.executable)"],
            env=self.env, text=True, timeout=10,
        ).strip()
        self.assertEqual(Path(executable).resolve(), Path(sys.executable).resolve())
        self.assertEqual(self.env["PATH"].split(os.pathsep)[0], str(self.bin))

    def make_large_candidate(self, relative="pr_review-large-artifact"):
        # The `pr_` prefix gives the fixture a declared-ephemeral E2 row (2880
        # min). cleanup_tmp.sh only quarantines candidates with a declared
        # retention (bead disk_magician-archive-same-volume-regrowth-03bn), and
        # these tests exercise the archive/deadline machinery itself.
        path = self.root / "private-tmp" / relative
        path.mkdir(parents=True)
        (path / "payload.bin").write_bytes(b"fixture payload\n" * 1024)
        for entry in (path / "payload.bin", path):
            os.utime(entry, (1577836800, 1577836800))
        return path

    def test_expired_deadline_preserves_new_archive_candidate(self):
        candidate = self.make_large_candidate()
        before = candidate.stat()
        payload = (candidate / "payload.bin").read_bytes()
        result = self.run_cleanup("cleanup_tmp.sh", "--clean", "--large", "--deadline-at", "1")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(candidate.exists(), "expired deadline moved the source directory")
        self.assertEqual((candidate.stat().st_dev, candidate.stat().st_ino), (before.st_dev, before.st_ino))
        self.assertEqual((candidate / "payload.bin").read_bytes(), payload)
        self.assertFalse((self.root / "archive").exists(), "expired unit created archive state")
        self.assertIn("Dirs archived: 0", result.stderr)
        terminal = self.receipt("cleanup_tmp")["last_terminal"]
        self.assertEqual(terminal["outcome"], "partial")
        self.assertEqual(terminal["candidates"]["interrupted_count"], 1)
        self.assertEqual(terminal["candidates"]["removed_count"], 0)

    def test_expired_deadline_preserves_container_child(self):
        candidate = self.make_large_candidate("agent-scratch/review-large-artifact")
        result = self.run_cleanup("cleanup_tmp.sh", "--clean", "--large", "--deadline-at", "1")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Descending into active container", result.stderr)
        self.assertTrue((candidate / "payload.bin").is_file())
        self.assertFalse((self.root / "archive").exists())
        self.assertIn("Dirs archived: 0", result.stderr)
        terminal = self.receipt("cleanup_tmp")["last_terminal"]
        self.assertEqual(terminal["outcome"], "partial")
        self.assertEqual(terminal["candidates"]["interrupted_count"], 1)

    def test_deadline_expiring_during_receipt_prep_prevents_move(self):
        candidate = self.make_large_candidate()
        before = candidate.stat()
        marker = self.root / "receipt-prepared"
        self.env["REVIEW_RECEIPT_MARKER"] = str(marker)
        # Advance the shared helper's deadline clock only after the real
        # archive-receipt call completes. This avoids timing-sensitive sleeps
        # while proving the final move boundary rechecks the deadline.
        self.write_shim("python3", '''if [[ "${2:-}" == archive-receipt ]]; then
  "$REVIEW_PYTHON" "$@" || exit $?
  : >"$REVIEW_RECEIPT_MARKER"
  exit 0
fi
if [[ "$#" == 3 && "$1" == - && "$3" == 0 && -f "$REVIEW_RECEIPT_MARKER" ]]; then
  exec "$REVIEW_PYTHON" - 1 0
fi
exec "$REVIEW_PYTHON" "$@"
''')
        result = self.run_cleanup("cleanup_tmp.sh", "--clean", "--large", "--deadline-at", str(time.monotonic() + 300))
        self.assertEqual(result.returncode, 0)
        self.assertTrue(marker.exists(), "fixture must reach real archive receipt creation")
        self.assertTrue(candidate.exists(), "deadline expired during preparation but source was moved")
        self.assertEqual((candidate.stat().st_dev, candidate.stat().st_ino), (before.st_dev, before.st_ino))
        # Preserve the already-created exclusive receipt on interruption, as
        # the existing failed-mv path does; do not unlink a possibly replaced file.
        receipts = list((self.root / "archive").glob("*/*.c14-origin.json"))
        self.assertEqual(len(receipts), 1)
        self.assertEqual(json.loads(receipts[0].read_text())["ino"], before.st_ino)
        self.assertFalse(list((self.root / "archive").glob(f"*/{candidate.name}")))
        self.assertIn("Dirs archived: 0", result.stderr)
        terminal = self.receipt("cleanup_tmp")["last_terminal"]
        self.assertEqual(terminal["outcome"], "partial")
        self.assertEqual(terminal["candidates"]["interrupted_count"], 1)

    def assert_archive_allowed(self, *deadline):
        candidate = self.make_large_candidate()
        payload = (candidate / "payload.bin").read_bytes()
        result = self.run_cleanup("cleanup_tmp.sh", "--clean", "--large", *deadline)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(candidate.exists(), "eligible fixture did not reach archive mutation")
        moved = list((self.root / "archive").glob(f"*/{candidate.name}"))
        self.assertEqual(len(moved), 1)
        self.assertEqual((moved[0] / "payload.bin").read_bytes(), payload)
        self.assertTrue(moved[0].with_name(candidate.name + ".c14-origin.json").is_file())
        self.assertIn("Dirs archived: 1", result.stderr)
        self.assertEqual(self.receipt("cleanup_tmp")["last_terminal"]["candidates"]["interrupted_count"], 0)

    def test_future_deadline_allows_archive(self):
        self.assert_archive_allowed("--deadline-at", str(time.monotonic() + 300))

    def test_no_deadline_allows_archive(self):
        self.assert_archive_allowed()

    def test_expired_deadline_keeps_dry_run_preview(self):
        candidate = self.make_large_candidate()
        result = self.run_cleanup("cleanup_tmp.sh", "--dry-run", "--large", "--deadline-at", "1")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(candidate.exists())
        self.assertFalse((self.root / "archive").exists())
        self.assertIn("DRY RUN: would archive:", result.stderr)

    def make_codex_root(self):
        (self.root / "home" / "Documents" / "Codex").mkdir(parents=True)

    def test_terminal_receipt_write_failure_is_nonzero(self):
        self.make_codex_root()
        helper = self.root / "receipt_helper.py"
        helper.write_text(
            "import errno, sys\n"
            f"sys.path.insert(0, {str(REPO_ROOT / 'scripts')!r})\n"
            "import job_receipt\n"
            "if sys.argv[1] == 'finish':\n"
            "    def fail_save(*args, **kwargs):\n"
            "        raise OSError(errno.ENOSPC, 'injected terminal receipt write failure')\n"
            "    job_receipt.JobReceiptStore._atomic_save_unlocked = fail_save\n"
            "sys.exit(job_receipt.main())\n"
        )
        self.env["DISK_MAGICIAN_RECEIPT_HELPER"] = str(helper)
        result = self.run_cleanup("cleanup_codex_documents.sh", "--clean")
        self.assertIn("injected terminal receipt write failure", result.stdout + result.stderr)
        store = self.receipt("cleanup_codex_documents")
        self.assertEqual(len(store["active"]), 1, "begin must succeed before the injected finish failure")
        self.assertIsNone(store["last_terminal"])
        self.assertEqual(store["completed"], [])
        self.assertEqual(result.returncode, 1, "terminal persistence failure must fail the cleanup command")
        self.assertNotIn("Done. Task dirs removed:", result.stdout)

    def test_terminal_receipt_success_still_completes(self):
        self.make_codex_root()
        result = self.run_cleanup("cleanup_codex_documents.sh", "--clean")
        self.assertEqual(result.returncode, 0)
        store = self.receipt("cleanup_codex_documents")
        self.assertEqual(store["active"], [])
        self.assertEqual(store["last_terminal"]["outcome"], "success_noop")
        self.assertIn("Done. Task dirs removed: 0", result.stdout)

    def test_codex_dry_run_remains_receipt_free(self):
        self.make_codex_root()
        result = self.run_cleanup("cleanup_codex_documents.sh", "--dry-run")
        self.assertEqual(result.returncode, 0)
        self.assertFalse((self.root / "state" / "receipts").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
