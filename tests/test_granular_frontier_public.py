"""Same public CLI fixture runs against source-only baseline and working tree."""
import json
import os
import shutil
import pathlib
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(os.environ.get('GRANULAR_TEST_REPO', pathlib.Path(__file__).resolve().parents[1]))
SCRATCH_TEMP_ROOT = os.environ.get("PYTEST_DEBUG_TEMPROOT")
def scratch_tempdir():
    if not SCRATCH_TEMP_ROOT:
        raise RuntimeError("configure pytest debug temp root on Scratch")
    return tempfile.TemporaryDirectory(dir=SCRATCH_TEMP_ROOT)
class PublicFrontier(unittest.TestCase):
    def test_metadata_descent_and_rerun(self):
        with scratch_tempdir() as d:
            root = pathlib.Path(d)
            repo = root/'tree'; (repo/'.git'/'objects').mkdir(parents=True)
            payload = repo/'.git'/'objects'/'payload'
            # Real allocated exactly-100MiB file: no sparse-allocation ambiguity.
            with payload.open('wb') as f:
                for _ in range(100): f.write(b'x'*(1024*1024))
            os.link(payload, repo/'alias')
            os.symlink(repo, root/'symlink')
            env = dict(os.environ, DISK_MAGICIAN_GDU_CMD='', DISK_MAGICIAN_DUA_CMD='')
            def run(*extra):
                proc = subprocess.run(['bash', str(REPO/'disk_magician.sh'), 'frontier', '--root', d,
                    '--no-sibling-volumes', '--no-purgeable', '--workers', '1', '--max-depth', '20',
                    '--wall-clock-cap', '20', *extra], env=env, text=True, capture_output=True)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                return json.loads(proc.stdout)
            partial = run('--max-nodes', '1')
            self.assertTrue(partial['frontier_unfinished'])
            complete = run('--max-nodes', '1000')
            self.assertEqual(complete['config']['granularity_gib'], 100/1024)
            measured = complete['measured']
            self.assertTrue(str(payload) in measured or str(repo/'alias') in measured, measured)
            self.assertNotIn(str(repo), measured)
            self.assertFalse(complete['frontier_unfinished'], complete['frontier_unfinished'])
            file_allocation_kb = (payload.stat().st_blocks * 512 + 1023) // 1024
            self.assertEqual(payload.stat().st_size, 100 * 1024 * 1024)
            link_allocation_kb = ((root/'symlink').lstat().st_blocks * 512 + 1023) // 1024
            self.assertEqual(complete['measured_total_kb'],
                             file_allocation_kb + link_allocation_kb
                             + sum(complete['directory_metadata_kb'].values()))
            self.assertFalse(any('/symlink/' in path for path in measured))
            self.assertTrue(all(b.get('kind') != 'direct_allocation_segment' for b in complete['granularity_buckets']))

    def test_gnu_inventory_descends_sparse_file_in_apparent_large_directory(self):
        du = shutil.which("gdu") or shutil.which("du")
        self.assertIsNotNone(du, "GNU du is required for this backend fixture")
        version = subprocess.run([du, "--version"], capture_output=True, text=True)
        self.assertEqual(version.returncode, 0, version.stderr)
        self.assertIn("GNU coreutils", version.stdout)
        with scratch_tempdir() as tmp:
            root = pathlib.Path(tmp) / "root"
            parent = root / "group"
            parent.mkdir(parents=True)
            payload = parent / "large-sparse.bin"
            with payload.open("wb") as stream:
                stream.truncate(200 * 1024 * 1024)
            self.assertEqual(payload.stat().st_size, 200 * 1024 * 1024)
            self.assertEqual(payload.stat().st_blocks, 0)
            os.link(payload, parent / "alias")
            for backend, expected_backend in ((du, "gdu_one_pass"), ("", "frontier_per_node")):
                with self.subTest(backend=expected_backend):
                    env = dict(os.environ, DISK_MAGICIAN_GDU_CMD=backend, DISK_MAGICIAN_DUA_CMD="")
                    proc = subprocess.run([
                        "bash", str(REPO / "disk_magician.sh"), "frontier",
                        "--root", str(root), "--no-sibling-volumes", "--no-purgeable",
                        "--workers", "1", "--max-nodes", "1000", "--max-depth", "20",
                        "--wall-clock-cap", "20",
                    ], env=env, text=True, capture_output=True, timeout=30)
                    self.assertEqual(proc.returncode, 0, proc.stderr)
                    report = json.loads(proc.stdout)
                    self.assertEqual(report["config"]["scan_backend"], expected_backend)
                    file_leaves = [row for row in report.get("file_leaves", [])
                                   if row.get("path") == str(payload)]
                    self.assertEqual(len(file_leaves), 1, report)
                    self.assertEqual(file_leaves[0]["apparent_bytes"], 200 * 1024 * 1024)
                    self.assertEqual(file_leaves[0]["allocated_kb"], 0)
                    bucket_paths = {row["path"] for row in report["granularity_buckets"]}
                    self.assertNotIn(str(parent), bucket_paths)
                    self.assertEqual(sum(row["apparent_bytes"] for row in report["file_leaves"]
                                         if not row["inode_deduplicated"]), 200 * 1024 ** 2)
                    self.assertTrue(any(row["inode_deduplicated"] for row in report["file_leaves"]))

    def test_fallback_default_depth_does_not_hide_file_under_large_directory(self):
        du = shutil.which("gdu") or shutil.which("du")
        self.assertIsNotNone(du, "GNU du is required for this backend fixture")
        version = subprocess.run([du, "--version"], capture_output=True, text=True)
        self.assertEqual(version.returncode, 0, version.stderr)
        self.assertIn("GNU coreutils", version.stdout)
        scratch = os.environ.get("PYTEST_DEBUG_TEMPROOT")
        self.assertTrue(scratch, "test runner must use the configured Scratch temp root")
        with tempfile.TemporaryDirectory(dir=scratch) as tmp:
            root = pathlib.Path(tmp) / "root"
            parent = root
            for index in range(32):
                parent = parent / ("layer-%02d" % index)
            parent.mkdir(parents=True)
            payload = parent / "payload.bin"
            with payload.open("wb") as stream:
                stream.write(b"F" * (101 * 1024 * 1024))
            for backend, expected_backend in (("", "frontier_per_node"), (du, "gdu_one_pass")):
                with self.subTest(backend=expected_backend):
                    env = dict(os.environ, DISK_MAGICIAN_GDU_CMD=backend, DISK_MAGICIAN_DUA_CMD="")
                    command = [
                        "bash", str(REPO / "disk_magician.sh"), "frontier",
                        "--root", str(root), "--no-sibling-volumes", "--no-purgeable",
                        "--workers", "1", "--max-nodes", "1000", "--wall-clock-cap", "20",
                    ]
                    proc = subprocess.run(command, env=env, text=True, capture_output=True, timeout=30)
                    self.assertEqual(proc.returncode, 0, proc.stderr)
                    report = json.loads(proc.stdout)
                    self.assertEqual(report["config"]["scan_backend"], expected_backend)
                    self.assertEqual(report["mode"], "complete", report["frontier_unfinished"])
                    file_rows = [row for row in report["oversize_indivisible_files"]
                                 if row.get("path") == str(payload)]
                    self.assertEqual(len(file_rows), 1, report)
                    self.assertEqual(file_rows[0]["apparent_bytes"], 101 * 1024 ** 2)
                    self.assertGreaterEqual(file_rows[0]["measured_kb"], 100 * 1024)
                    bounded = subprocess.run(command + ["--max-depth", "8"], env=env,
                                             text=True, capture_output=True, timeout=30)
                    self.assertEqual(bounded.returncode, 0, bounded.stderr)
                    limited = json.loads(bounded.stdout)
                    self.assertEqual(limited["mode"], "partial")
                    self.assertTrue(any("max_depth" in item["reason"]
                                        for item in limited["frontier_unfinished"]))

    def test_symlink_root_with_trailing_slash_is_not_walked(self):
        with scratch_tempdir() as d:
            root = pathlib.Path(d); target = root/'target'; target.mkdir()
            (target/'payload').write_text('do not follow')
            link = root/'link'; link.symlink_to(target)
            env = dict(os.environ, DISK_MAGICIAN_GDU_CMD='', DISK_MAGICIAN_DUA_CMD='')
            proc = subprocess.run(['bash', str(REPO/'disk_magician.sh'), 'frontier',
                '--root', str(link)+'/', '--no-sibling-volumes', '--no-purgeable'],
                env=env, text=True, capture_output=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            report = json.loads(proc.stdout)
            self.assertEqual(set(report['measured']), {str(link)})

    def test_permission_and_deadline_are_partial_then_rerun(self):
        if os.geteuid() == 0:
            self.skipTest('mode000 permission fixture requires non-root')
        with scratch_tempdir() as d:
            root = pathlib.Path(d)
            blocked = root/'blocked'; blocked.mkdir()
            (blocked/'payload').write_text('metadata')
            blocked.chmod(0)
            env = dict(os.environ, DISK_MAGICIAN_GDU_CMD='', DISK_MAGICIAN_DUA_CMD='')
            def run(cap):
                p = subprocess.run(['bash', str(REPO/'disk_magician.sh'), 'frontier',
                    '--root', d, '--no-sibling-volumes', '--no-purgeable',
                    '--wall-clock-cap', str(cap)], env=env, text=True, capture_output=True)
                self.assertEqual(p.returncode, 0, p.stderr)
                return json.loads(p.stdout)
            try:
                denied = run(10)
                self.assertEqual(denied['mode'], 'partial')
                self.assertTrue(denied['frontier_unfinished'])
            finally:
                blocked.chmod(0o700)
            expired = run(0)
            self.assertEqual(expired['mode'], 'partial')
            self.assertTrue(expired['frontier_unfinished'])
            resumed = run(10)
            self.assertFalse(resumed['frontier_unfinished'])
            self.assertEqual(resumed['mode'], 'complete')

if __name__ == '__main__': unittest.main()
