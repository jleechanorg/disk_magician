import fcntl
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
DISKM = REPO / "disk_magician.sh"


class TestConfigMutator(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_config(self, *args, config=None):
        env = self.config_env(config)
        return subprocess.run(
            ["bash", str(DISKM), "config", *args],
            env=env,
            capture_output=True,
            text=True,
        )

    def run_snapshot(self, output, config=None):
        env = self.config_env(config)
        env.update(
            {
                "DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS": "5",
                "DISK_MAGICIAN_LIBRARY_FRONTIER_BUDGET_SECONDS": "1",
                "DISK_MAGICIAN_STATE_DIR": str(self.root / "snapshot-state"),
            }
        )
        return subprocess.run(
            ["bash", str(REPO / "scripts" / "disk_snapshot.sh"), "--output", str(output)],
            env=env,
            capture_output=True,
            text=True,
        )

    def config_env(self, config=None):
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(self.home),
                "XDG_CONFIG_HOME": str(self.root / "xdg"),
                "XDG_STATE_HOME": str(self.root / "state"),
                "PATH": "/usr/bin:/bin",
            }
        )
        env.pop("DISK_MAGICIAN_STATE_REPO", None)
        if config is not None:
            env["DISK_MAGICIAN_CONFIG"] = str(config)
        else:
            env.pop("DISK_MAGICIAN_CONFIG", None)
        return env

    def write_config(self, name="config.json", data=None):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data or {"unrelated": {"keep": True}}) + "\n")
        return path

    def test_dispatch_adds_dir_and_preserves_unrelated_json(self):
        config = self.write_config(
            data={
                "unrelated": {"keep": True},
                "monitored_globs": [{"key": "existing", "pattern": "~/existing"}],
                "monitored_dirs": [],
            }
        )
        result = self.run_config(
            "add-monitored-dir",
            "--key",
            "linux_usr_lib",
            "--path",
            "/usr/lib",
            "--timeout",
            "90",
            config=config,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(config.read_text())
        self.assertEqual(data["unrelated"], {"keep": True})
        self.assertEqual(
            data["monitored_globs"], [{"key": "existing", "pattern": "~/existing"}]
        )
        self.assertEqual(
            data["monitored_dirs"],
            [{"key": "linux_usr_lib", "path": "/usr/lib", "timeout": 90}],
        )

    def test_effective_env_config_beats_xdg_config(self):
        explicit = self.write_config(data={"monitored_dirs": []})
        xdg = self.root / "xdg" / "disk-magician" / "config.json"
        xdg.parent.mkdir(parents=True)
        xdg.write_text(json.dumps({"monitored_dirs": []}))
        result = self.run_config(
            "add-monitored-file-glob",
            "--key",
            "swapfile",
            "--pattern",
            "/swapfile",
            config=explicit,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(explicit.read_text())["monitored_file_globs"][0]["key"], "swapfile")
        self.assertNotIn("monitored_file_globs", json.loads(xdg.read_text()))

    def test_default_snapshot_consumer_reads_config_cli_mutation(self):
        target = self.home / "ledger-root"
        target.mkdir()
        config = self.root / "xdg" / "disk-magician" / "config.json"
        config.parent.mkdir(parents=True)
        config.write_text(
            json.dumps({"library_frontier_enabled": False, "monitored_dirs": []}) + "\n"
        )
        result = self.run_config(
            "add-monitored-dir",
            "--key",
            "ledger_root",
            "--path",
            "~/ledger-root",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        output = self.root / "snapshot.json"
        snapshot = self.run_snapshot(output)
        self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
        self.assertEqual(set(json.loads(output.read_text())["directories"]), {"ledger_root"})

    def test_snapshot_overlay_preserves_state_inventory_for_cli_and_snapshot(self):
        state_config = self.root / "state" / "disk-magician" / "config" / "config.json"
        state_config.parent.mkdir(parents=True)
        state_config.write_text(
            json.dumps({
                "monitored_dirs": [
                    {"key": "baseline", "path": "~/baseline", "timeout": 60}
                ]
            }) + "\n"
        )
        (self.home / "baseline").mkdir()
        xdg_config = self.root / "xdg" / "disk-magician" / "config.json"
        xdg_config.parent.mkdir(parents=True)
        xdg_config.write_text(
            json.dumps({"snapshot_measure": {"path_max_seconds": 7}}) + "\n"
        )

        result = self.run_config(
            "add-monitored-dir", "--key", "added", "--path", "~/added"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(xdg_config.read_text()),
            {"snapshot_measure": {"path_max_seconds": 7}},
        )
        state = json.loads(state_config.read_text())
        self.assertEqual(
            [entry["key"] for entry in state["monitored_dirs"]],
            ["baseline", "added"],
        )

        output = self.root / "snapshot-overlay.json"
        snapshot = self.run_snapshot(output)
        self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
        self.assertEqual(
            set(json.loads(output.read_text())["directories"]),
            {"baseline", "added"},
        )

    def test_snapshot_only_overlay_materializes_template_inventory_for_cli(self):
        xdg_config = self.root / "xdg" / "disk-magician" / "config.json"
        xdg_config.parent.mkdir(parents=True)
        xdg_config.write_text(
            json.dumps({"snapshot_measure": {"path_max_seconds": 7}}) + "\n"
        )
        (self.home / ".claude").mkdir()
        (self.home / "added").mkdir()

        result = self.run_config(
            "add-monitored-dir", "--key", "added", "--path", "~/added"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state_config = self.root / "state" / "disk-magician" / "config" / "config.json"
        self.assertTrue(state_config.is_file())
        self.assertEqual(
            json.loads(xdg_config.read_text()),
            {"snapshot_measure": {"path_max_seconds": 7}},
        )
        state = json.loads(state_config.read_text())
        self.assertIn("claude_root", {entry["key"] for entry in state["monitored_dirs"]})
        self.assertIn("added", {entry["key"] for entry in state["monitored_dirs"]})

        output = self.root / "snapshot-overlay-template.json"
        snapshot = self.run_snapshot(output)
        self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
        self.assertIn("claude_root", json.loads(output.read_text())["directories"])
        self.assertIn("added", json.loads(output.read_text())["directories"])

    def test_repeat_is_idempotent_and_conflict_preserves_file(self):
        config = self.write_config(data={"monitored_dirs": []})
        args = ("add-monitored-dir", "--key", "swap", "--path", "/swapfile")
        first = self.run_config(*args, config=config)
        self.assertEqual(first.returncode, 0, first.stderr)
        after_first = config.read_bytes()
        second = self.run_config(*args, config=config)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(config.read_bytes(), after_first)
        conflict = self.run_config(
            "add-monitored-dir", "--key", "swap", "--path", "/other", config=config
        )
        self.assertNotEqual(conflict.returncode, 0)
        self.assertEqual(config.read_bytes(), after_first)

    def test_cross_field_key_conflict_preserves_file(self):
        config = self.write_config(
            data={
                "monitored_dirs": [{"key": "shared", "path": "/existing", "timeout": 60}],
                "monitored_file_globs": [],
            }
        )
        before = config.read_bytes()
        result = self.run_config(
            "add-monitored-file-glob",
            "--key",
            "shared",
            "--pattern",
            "/other/*",
            config=config,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already used in field 'monitored_dirs'", result.stderr)
        self.assertEqual(config.read_bytes(), before)

    def test_record_delimiters_are_rejected_without_replacement(self):
        cases = [
            ("add-monitored-dir", "--key", "bad\tkey", "--path", "/new"),
            ("add-monitored-dir", "--key", "bad\nkey", "--path", "/new"),
            ("add-monitored-dir", "--key", "new", "--path", "/bad\rpath"),
            (
                "add-monitored-file-glob",
                "--key",
                "new",
                "--pattern",
                "/bad\npattern",
            ),
        ]
        for command in cases:
            with self.subTest(command=command):
                config = self.write_config(data={"monitored_dirs": []})
                before = config.read_bytes()
                result = self.run_config(*command, config=config)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must not contain tabs or newline characters", result.stderr)
                self.assertEqual(config.read_bytes(), before)

    def test_malformed_config_fails_without_replacement(self):
        config = self.write_config()
        config.write_text('{"monitored_dirs": [')
        before = config.read_bytes()
        result = self.run_config(
            "add-monitored-dir", "--key", "bad", "--path", "/bad", config=config
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_bytes(), before)

    def test_invalid_explicit_config_fails_closed_for_mutator_and_snapshot(self):
        fallback = self.root / "xdg" / "disk-magician" / "config.json"
        fallback.parent.mkdir(parents=True)
        fallback.write_text(json.dumps({"monitored_dirs": []}) + "\n")
        before = fallback.read_bytes()
        invalid = [
            self.root / "missing.json",
            self.root / "config-dir",
            self.root / "broken-link.json",
        ]
        invalid[1].mkdir()
        invalid[2].symlink_to(self.root / "nowhere.json")
        for config in invalid:
            with self.subTest(config=config):
                result = self.run_config(
                    "add-monitored-dir", "--key", "wrong", "--path", "/wrong",
                    config=config,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(fallback.read_bytes(), before)
                output = self.root / f"snapshot-{config.name}.json"
                snapshot = self.run_snapshot(output, config=config)
                self.assertNotEqual(snapshot.returncode, 0)
                self.assertIn("missing file", snapshot.stderr)
                self.assertFalse(output.exists())

    def test_null_monitored_fields_fail_without_replacement(self):
        for field, args in (
            (
                "monitored_dirs",
                ("add-monitored-dir", "--key", "null-dir", "--path", "/null"),
            ),
            (
                "monitored_file_globs",
                (
                    "add-monitored-file-glob",
                    "--key",
                    "null-glob",
                    "--pattern",
                    "/null/*",
                ),
            ),
        ):
            with self.subTest(field=field):
                config = self.write_config(data={field: None, "unrelated": {"keep": True}})
                before = config.read_bytes()
                result = self.run_config(*args, config=config)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"config field '{field}' must be a JSON array", result.stderr)
                self.assertEqual(config.read_bytes(), before)

    def test_malformed_monitored_schema_fails_without_replacement(self):
        cases = [
            ("monitored_dirs", "not-an-array"),
            ("monitored_globs", None),
            ("monitored_file_globs", 7),
            ("monitored_dirs", [None]),
            ("monitored_globs", ["~/glob*"]),
            ("monitored_file_globs", [{}]),
            ("monitored_dirs", [{"key": "dir"}]),
            ("monitored_dirs", [{"key": "dir", "path": None}]),
            ("monitored_globs", [{"key": None, "pattern": "~/glob*"}]),
            ("monitored_file_globs", [{"key": "glob", "pattern": 4}]),
            (
                "monitored_dirs",
                [{"key": "dir", "path": "/tmp", "timeout": None}],
            ),
            (
                "monitored_dirs",
                [{"key": "dir", "path": "/tmp", "retry_timeout": "5"}],
            ),
        ]
        for field, value in cases:
            with self.subTest(field=field, value=value):
                config = self.write_config(data={field: value, "unrelated": {"keep": True}})
                before = config.read_bytes()
                result = self.run_config(
                    "add-monitored-dir", "--key", "new", "--path", "/new", config=config
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(config.read_bytes(), before)

    def test_duplicate_monitored_keys_fail_without_replacement(self):
        config = self.write_config(
            data={
                "monitored_dirs": [{"key": "shared", "path": "/one"}],
                "monitored_globs": [{"key": "shared", "pattern": "/two/*"}],
            }
        )
        before = config.read_bytes()
        result = self.run_config(
            "add-monitored-dir", "--key", "new", "--path", "/new", config=config
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicated", result.stderr)
        self.assertEqual(config.read_bytes(), before)

    def test_packaged_template_is_read_only(self):
        template = REPO / "config.json.template"
        before = template.read_bytes()
        result = self.run_config(
            "add-monitored-dir", "--key", "template", "--path", "/tmp", config=template
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to write packaged config template", result.stderr)
        self.assertEqual(template.read_bytes(), before)

    def test_fresh_install_materializes_state_config_without_template_write(self):
        before = (REPO / "config.json.template").read_bytes()
        result = self.run_config(
            "add-monitored-dir", "--key", "fresh", "--path", "/fresh"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        state_config = self.root / "state" / "disk-magician" / "config" / "config.json"
        self.assertTrue(state_config.is_file())
        self.assertIn("fresh", {entry["key"] for entry in json.loads(state_config.read_text())["monitored_dirs"]})
        self.assertEqual((REPO / "config.json.template").read_bytes(), before)

    def test_failed_fresh_mutation_does_not_materialize_state_config(self):
        xdg_config = self.root / "xdg" / "disk-magician" / "config.json"
        xdg_config.parent.mkdir(parents=True)
        xdg_config.write_text(json.dumps({"snapshot_measure": {}}) + "\n")

        result = self.run_config(
            "add-monitored-dir", "--key", "tmp", "--path", "/newtmp"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already has a different entry", result.stderr)
        state_root = self.root / "state" / "disk-magician"
        state_config = self.root / "state" / "disk-magician" / "config" / "config.json"
        lock_path = state_root / "config" / ".config.json.lock"
        self.assertFalse(state_config.exists())
        self.assertFalse(state_root.exists())
        self.assertFalse(lock_path.exists())

    def test_symlink_config_updates_target_and_keeps_link(self):
        target = self.write_config(data={"monitored_dirs": []})
        link = self.root / "config-link.json"
        link.symlink_to(target)
        result = self.run_config(
            "add-monitored-dir", "--key", "linked", "--path", "/linked", config=link
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual(json.loads(target.read_text())["monitored_dirs"][0]["key"], "linked")

    def test_symlink_to_packaged_template_is_rejected_without_replacing_link(self):
        template = REPO / "config.json.template"
        link = self.root / "template-link.json"
        link.symlink_to(template)
        before = template.read_bytes()
        result = self.run_config(
            "add-monitored-dir", "--key", "template", "--path", "/tmp", config=link
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(link.is_symlink())
        self.assertEqual(template.read_bytes(), before)

    def test_simultaneous_distinct_adds_are_serialized(self):
        config = self.write_config(data={"monitored_dirs": []})
        lock_path = config.with_name(f".{config.name}.lock")
        commands = [
            ("one", "/one"),
            ("two", "/two"),
        ]
        processes = []
        with lock_path.open("a+") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            try:
                for key, path in commands:
                    processes.append(
                        subprocess.Popen(
                            [
                                "bash",
                                str(DISKM),
                                "config",
                                "add-monitored-dir",
                                "--key",
                                key,
                                "--path",
                                path,
                            ],
                            env=self.config_env(config),
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            text=True,
                        )
                    )
                time.sleep(0.5)
                self.assertTrue(
                    any(process.poll() is None for process in processes),
                    "config writers did not wait for the shared lock",
                )
            finally:
                fcntl.flock(held, fcntl.LOCK_UN)
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stderr or stdout)
        self.assertEqual(
            {row["key"] for row in json.loads(config.read_text())["monitored_dirs"]},
            {"one", "two"},
        )


if __name__ == "__main__":
    unittest.main()
