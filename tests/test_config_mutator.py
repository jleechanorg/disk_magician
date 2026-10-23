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
                "monitored_globs": ["~/existing"],
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
        self.assertEqual(data["monitored_globs"], ["~/existing"])
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

    def test_malformed_config_fails_without_replacement(self):
        config = self.write_config()
        config.write_text('{"monitored_dirs": [')
        before = config.read_bytes()
        result = self.run_config(
            "add-monitored-dir", "--key", "bad", "--path", "/bad", config=config
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_bytes(), before)

    def test_packaged_template_is_read_only(self):
        template = REPO / "config.json.template"
        before = template.read_bytes()
        result = self.run_config(
            "add-monitored-dir", "--key", "template", "--path", "/tmp"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to write packaged config template", result.stderr)
        self.assertEqual(template.read_bytes(), before)

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
