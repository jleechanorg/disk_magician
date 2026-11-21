import fcntl
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import time
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]
DISKM = REPO / "disk_magician.sh"


class ScratchManifestApplyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="diskm-scratch-manifest-")
        self.temp_root = pathlib.Path(self.temp.name)
        self.bin = self.temp_root / "bin"
        self.bin.mkdir()
        self.state = self.temp_root / "state"
        self.state.mkdir()
        self.fixture_home = self.temp_root / 'home'
        self.fixture_home.mkdir(mode=0o700)
        self.log = self.temp_root / "deletions.log"
        self.manifest = self.temp_root / "manifest.json"
        self.scratch_root = pathlib.Path(os.path.realpath("/tmp"))
        self.selected = pathlib.Path("pr-diskm-manifest-{}-{}".format(os.getpid(), time.time_ns()))
        self.target = self.scratch_root / self.selected
        self.target.write_bytes(b"old generated fixture")
        old_ns = time.time_ns() - 72 * 60 * 60 * 1_000_000_000
        os.utime(self.target, ns=(old_ns, old_ns))
        st = self.target.lstat()
        self.manifest_value = {
            "version": 1,
            "root": {
                "path": str(self.scratch_root),
                "dev": self.scratch_root.stat().st_dev,
                "ino": self.scratch_root.stat().st_ino,
            },
            "before_epoch_seconds": int(time.time()) - 6 * 60 * 60,
            "entries": [
                {
                    "path": self.selected.as_posix(),
                    "kind": "regular_file",
                    "dev": st.st_dev,
                    "ino": st.st_ino,
                    "size": st.st_size,
                    "mtime_ns": st.st_mtime_ns,
                    "ctime_ns": st.st_ctime_ns,
                }
            ],
        }
        self.write_manifest()
        fake_disk_magician = self.bin / "disk-magician"
        fake_disk_magician.write_text(
            "#!/bin/sh\n"
            "case \"$*\" in\n"
            "  \"volume path scratch\") printf \"%s\\n\" \"$FIXTURE_SCRATCH_ROOT\" ;;\n"
            "  \"volume verify-mount $FIXTURE_SCRATCH_ROOT\") test \"${FIXTURE_MOUNT_UNVERIFIED:-0}\" = 0 ;;\n"
            "  *) exit 64 ;;\n"
            "esac\n"
        )
        fake_disk_magician.chmod(0o755)

    def tearDown(self):
        try:
            self.target.unlink(missing_ok=True)
        finally:
            self.temp.cleanup()

    def write_manifest(self):
        self.manifest_bytes = json.dumps(
            self.manifest_value, separators=(",", ":")
        ).encode()
        self.manifest.write_bytes(self.manifest_bytes)
        self.digest = hashlib.sha256(self.manifest_bytes).hexdigest()

    def run_apply(self, *paths, extra_env=None, all_entries=False, lock_fd=None, timeout=None):
        args = [
            "bash",
            str(DISKM),
            "quarantine",
            "scratch-apply",
            "--manifest",
            str(self.manifest),
            "--manifest-sha256",
            self.digest,
        ]
        if all_entries:
            args.append("--all")
        for path in paths:
            args.extend(["--path", path])
        env = dict(os.environ)
        env.update(
            {
                "PATH": str(self.bin) + os.pathsep + env.get("PATH", ""),
                "BASH_ENV": "/dev/null",
                "HOME": str(self.fixture_home),
                "FIXTURE_SCRATCH_ROOT": str(self.scratch_root),
                "DISK_MAGICIAN_STATE_DIR": str(self.state),
                "DISK_MAGICIAN_DELETION_LOG": str(self.log),
            }
        )
        env.pop("DISK_MAGICIAN_SCRATCH_LOCK_FD", None)
        env.pop("DISK_MAGICIAN_SCRATCH_LOCK_PID", None)
        env.pop("DISK_MAGICIAN_AGE_FLOOR_MINUTES", None)
        env.pop("DISK_MAGICIAN_OPERATOR_TARGETS", None)
        if extra_env:
            env.update(extra_env)
        if lock_fd is not None:
            env["DISK_MAGICIAN_SCRATCH_LOCK_FD"] = str(lock_fd)
        process = subprocess.run(
            args, cwd=REPO, env=env, capture_output=True, text=True,
            pass_fds=() if lock_fd is None else (lock_fd,), timeout=timeout,
        )
        if process.returncode == 0:
            return json.loads(process.stdout)
        return process

    def test_direct_apply_skips_while_the_canonical_scratch_writer_is_held(self):
        locks = self.fixture_home / ".disk_magician_locks"
        locks.mkdir(mode=0o700)
        fd = os.open(locks / "scratch_cleanup.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_apply(self.selected.as_posix(), timeout=3)
            self.assertEqual(getattr(result, "returncode", 0), 75)
            self.assertTrue(self.target.exists())
            self.assertFalse(self.log.exists())
        finally:
            os.close(fd)

    def test_target_coordinator_can_pass_the_canonical_writer_to_the_bridge(self):
        locks = self.fixture_home / ".disk_magician_locks"
        locks.mkdir(mode=0o700)
        fd = os.open(locks / "scratch_cleanup.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_apply(self.selected.as_posix(), lock_fd=fd)
            self.assertIsInstance(result, dict, getattr(result, "stderr", ""))
            self.assertTrue(result["results"][0]["result"].startswith("removed:"))
            self.assertFalse(self.target.exists())
        finally:
            os.close(fd)

    def test_exact_unchanged_selected_file_uses_quarantine_and_logs(self):
        result = self.run_apply(self.selected.as_posix())
        self.assertIsInstance(result, dict, getattr(result, "stderr", ""))
        self.assertEqual(result["results"][0]["path"], self.selected.as_posix())
        self.assertTrue(result["results"][0]["result"].startswith("removed:"))
        self.assertFalse(self.target.exists())
        rows = self.log.read_text().splitlines()
        self.assertEqual(len(rows), 1)
        self.assertIn(self.target.as_posix(), rows[0])

    def test_exact_apply_uses_selected_backend_for_nested_volume_checks(self):
        from_path = self.bin / "disk-magician"
        selected_backend = self.temp_root / "legacy-backend"
        from_path.rename(selected_backend)
        from_path.write_text("#!/bin/sh\nexit 91\n")
        from_path.chmod(0o755)
        result = self.run_apply(
            self.selected.as_posix(),
            extra_env={"DISKM_LEGACY_COMPAT_CLI": str(selected_backend)},
        )
        self.assertIsInstance(result, dict, getattr(result, "stderr", ""))
        self.assertTrue(result["results"][0]["result"].startswith("removed:"))
        self.assertFalse(self.target.exists())

    def test_explicit_batch_keeps_changed_member_and_removes_unchanged_member(self):
        with tempfile.TemporaryDirectory(prefix="dm-batch-", dir=self.scratch_root) as temp:
            changed = pathlib.Path(temp) / "changed"
            relative = changed.relative_to(self.scratch_root).as_posix()
            changed.write_bytes(b"initial content")
            old_ns = self.target.stat().st_mtime_ns
            os.utime(changed, ns=(old_ns, old_ns))
            st = changed.stat()
            self.manifest_value["entries"].append({
                "path": relative, "kind": "regular_file", "dev": st.st_dev,
                "ino": st.st_ino, "size": st.st_size,
                "mtime_ns": st.st_mtime_ns, "ctime_ns": st.st_ctime_ns,
            })
            self.write_manifest()
            changed.write_bytes(b"replacement content")
            result = self.run_apply(all_entries=True)
            self.assertIsInstance(result, dict, getattr(result, "stderr", ""))
            outcomes = {entry["path"]: entry["result"] for entry in result["results"]}
            self.assertTrue(outcomes[self.selected.as_posix()].startswith("removed:"))
            self.assertEqual(outcomes[relative], "kept:identity-mismatch")
            self.assertFalse(self.target.exists())
            self.assertEqual(changed.read_bytes(), b"replacement content")
            self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_unverified_scratch_mount_refuses_apply(self):
        result = self.run_apply(self.selected.as_posix(), extra_env={"FIXTURE_MOUNT_UNVERIFIED": "1"})
        self.assertIsInstance(result, subprocess.CompletedProcess)
        self.assertIn("Scratch mount verification failed", result.stderr)
        self.assertTrue(self.target.exists())
        self.assertFalse(self.log.exists())

    def test_path_that_would_split_deletion_log_is_preserved(self):
        old = self.target
        self.selected = old.name + "\nextra"
        self.target = old.with_name(self.selected)
        old.rename(self.target)
        st = self.target.stat()
        entry = self.manifest_value["entries"][0]
        entry.update(path=self.selected, ctime_ns=st.st_ctime_ns)
        self.write_manifest()
        result = self.run_apply(self.selected)
        self.assertIsInstance(result, dict, getattr(result, "stderr", ""))
        self.assertEqual(result["results"][0]["result"], "kept:unsupported-log-path")
        self.assertTrue(self.target.exists())
        self.assertFalse(self.log.exists())

    def test_changed_target_identity_is_kept_without_c14_or_removal(self):
        replacement = self.target.with_name(self.target.name + ".replacement")
        self.target.rename(replacement)
        self.target.write_bytes(b"replacement content")
        result = self.run_apply(self.selected.as_posix())
        self.assertEqual(result["results"][0]["result"], "kept:identity-mismatch")
        self.assertTrue(self.target.exists())
        self.assertTrue(replacement.exists())
        self.assertFalse(self.log.exists())

    def test_manifest_change_and_root_identity_mismatch_fail_closed(self):
        self.manifest.write_bytes(self.manifest_bytes + b" ")
        changed = self.run_apply(self.selected.as_posix())
        self.assertEqual(changed.returncode, 2)
        self.assertTrue(self.target.exists())

        self.write_manifest()
        self.manifest_value["root"]["ino"] += 1
        self.write_manifest()
        wrong_root = self.run_apply(self.selected.as_posix())
        self.assertEqual(wrong_root.returncode, 2)
        self.assertTrue(self.target.exists())

    def test_selection_must_be_exact_manifest_member(self):
        result = self.run_apply("some-other-path")
        self.assertEqual(result.returncode, 2)
        self.assertTrue(self.target.exists())

    def test_symlink_ancestor_and_cutoff_boundary_are_rejected(self):
        parent = self.scratch_root / ("pr-diskm-link-parent-{}".format(os.getpid()))
        parent.mkdir()
        child = parent / "child"
        child.write_bytes(b"fixture")
        link = self.scratch_root / ("pr-diskm-link-{}".format(os.getpid()))
        link.symlink_to(parent, target_is_directory=True)
        try:
            self.manifest_value["entries"][0]["path"] = (link.name + "/child")
            self.write_manifest()
            linked = self.run_apply(link.name + "/child")
            self.assertEqual(linked["results"][0]["result"], "kept:symlink-ancestor")
            self.assertTrue(child.exists())

            self.manifest_value["entries"][0]["path"] = self.selected.as_posix()
            cutoff_ns = self.manifest_value["before_epoch_seconds"] * 1_000_000_000
            os.utime(self.target, ns=(cutoff_ns, cutoff_ns))
            st = self.target.lstat()
            self.manifest_value["entries"][0].update(
                {
                    "dev": st.st_dev,
                    "ino": st.st_ino,
                    "size": st.st_size,
                    "mtime_ns": st.st_mtime_ns,
                    "ctime_ns": st.st_ctime_ns,
                }
            )
            self.write_manifest()
            cutoff = self.run_apply(self.selected.as_posix())
            self.assertEqual(cutoff["results"][0]["result"], "kept:outside-date-window")
            self.assertTrue(self.target.exists())
        finally:
            link.unlink(missing_ok=True)
            child.unlink(missing_ok=True)
            parent.rmdir()

    def test_target_replaced_after_c14_verdict_is_not_quarantined(self):
        self.write_manifest()
        replacement = self.target.with_name(self.target.name + ".replaced")
        hook = 'mv "$DM_Q_PATH" "$DM_Q_PATH.replaced"; printf replacement > "$DM_Q_PATH"'
        result = self.run_apply(
            self.selected.as_posix(),
            extra_env={"DISK_MAGICIAN_TEST_AFTER_VERDICT": hook},
        )
        self.assertEqual(result["results"][0]["result"], "kept:identity-mismatch")
        self.assertEqual(self.target.read_bytes(), b"replacement")
        self.assertTrue(replacement.exists())
        self.assertFalse(self.log.exists())


    def test_interrupted_manifest_quarantine_reports_uncertain_outcome(self):
        result = self.run_apply(
            self.selected.as_posix(),
            extra_env={"DISK_MAGICIAN_TEST_KILL_AT": "after_rename"},
        )
        records = list((self.state / "quarantine-index").glob("*.json"))
        self.assertEqual(len(records), 1)
        record = json.loads(records[0].read_text())
        self.assertEqual(record["original"], self.target.as_posix())
        self.assertFalse(self.target.exists())
        env = dict(os.environ, DISK_MAGICIAN_STATE_DIR=str(self.state), BASH_ENV="/dev/null")
        restored = subprocess.run(
            ["bash", str(DISKM), "quarantine", "restore", record["id"]],
            env=env, capture_output=True, text=True,
        )
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertIn("restored:", restored.stdout)
        self.assertEqual(self.target.read_bytes(), b"old generated fixture")
        self.assertEqual(result["results"][0]["result"], "deferred:quarantine-error")

    def test_managed_run_inventory_binds_nested_changes_before_quarantine(self):
        volume = self.temp_root.resolve() / "volume"
        repo = volume / "runs/20261120/disk-magician"
        run = repo / "build-20261120T120000Z-123-456"
        payload = run / "nested/output"
        payload.parent.mkdir(parents=True)
        marker = repo / ".dm-quarantine"
        marker.mkdir(mode=0o700)
        marker.chmod(0o700)
        payload.write_bytes(b"original")
        old_ns = self.target.stat().st_mtime_ns
        os.utime(payload, ns=(old_ns, old_ns))
        cutoff = int(time.time()) - 48 * 3600
        config = dict(os.environ)
        config.pop("DISKM_LEGACY_COMPAT_CLI", None)
        config.update({
            "PATH": str(self.bin) + os.pathsep + config.get("PATH", ""),
            "BASH_ENV": "/dev/null",
            "FIXTURE_SCRATCH_ROOT": str(volume),
            "DISK_MAGICIAN_STATE_DIR": str(self.state),
            "DISK_MAGICIAN_DELETION_LOG": str(self.log),
        })
        args = ["bash", str(DISKM), "quarantine", "scratch-apply", "--fingerprint-run"]
        result = subprocess.run([*args, str(run), str(cutoff)], env=config, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        digest = result.stdout.strip()
        self.assertRegex(digest, "^[0-9a-f]{64}$")
        rejected = subprocess.run([*args, str(repo), str(cutoff)], env=config, capture_output=True, text=True)
        self.assertEqual(rejected.returncode, 2)
        at_cutoff = subprocess.run([*args, str(run), str(old_ns // 1_000_000_000)],
                                   env=config, capture_output=True, text=True)
        self.assertEqual(at_cutoff.returncode, 2)
        self.assertIn("at or after the cutoff", at_cutoff.stderr)

        # Substitute the C14 verdict on the fixture, while keeping the real
        # binding, inventory check, rename, and quarantine phase 2.
        shell = r'''
source "$1/scripts/lib/quarantine.sh"
probe="$1/scripts/c14_probe.py"
shift
artifact_removal_verdict() {
    [[ "$(python3 "$probe" inventory "$1" "$3")" == ok ]] || { echo kept:check-failed; return; }
    echo remove
}
quarantine_remove "$@"
'''
        st = run.lstat()
        identity = ",".join(str(value) for value in
                            (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns))
        command = ["bash", "-c", shell, "managed-run-fixture", str(REPO), str(run),
                   "--kind", "ephemeral", "--expected-target-identity", identity,
                   "--expected-inventory", f"{digest},{cutoff}"]
        payload.write_bytes(b"replaced")
        os.utime(payload, ns=(old_ns, old_ns))
        changed = subprocess.run(command, env=config, capture_output=True, text=True)
        self.assertEqual(changed.stdout.strip(), "kept:inventory-mismatch", changed.stderr)
        self.assertEqual(payload.read_bytes(), b"replaced")
        self.assertFalse(self.log.exists())

        payload.write_bytes(b"original")
        os.utime(payload, ns=(old_ns, old_ns))
        result = subprocess.run(command, env=config, capture_output=True, text=True)
        self.assertTrue(result.stdout.strip().startswith("removed:"), result.stdout + result.stderr)
        self.assertFalse(run.exists())
        self.assertTrue(repo.is_dir())
        self.assertTrue(marker.is_dir())
        self.assertEqual(len(self.log.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
