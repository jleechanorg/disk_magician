import json, os, subprocess, tempfile, unittest, pathlib
REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "resolve_state_repo_path.py"

def resolve(env_extra):
    env = {"PATH": "/usr/bin:/bin"}
    env.update(env_extra)
    r = subprocess.run(["python3", str(SCRIPT)], capture_output=True, text=True, env=env)
    return r.returncode, r.stdout.strip()

class TestResolveStateRepoPath(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)

    def test_env_override_wins_outright(self):
        rc, out = resolve({"HOME": self.home, "DISK_MAGICIAN_STATE_REPO": "/tmp/explicit-state"})
        self.assertEqual((rc, out), (0, "/tmp/explicit-state"))

    def test_xdg_config_state_repo_path_key_wins_over_default(self):
        cfg_dir = os.path.join(self.home, ".config", "disk-magician")
        os.makedirs(cfg_dir)
        legacy = os.path.join(self.home, "legacy-backup")
        with open(os.path.join(cfg_dir, "config.json"), "w") as f:
            json.dump({"state_repo_path": legacy}, f)
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, legacy))

    def test_default_is_xdg_state_home_disk_magician(self):
        rc, out = resolve({"HOME": self.home})
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith("/disk-magician"), out)
        self.assertIn("/.local/state/", out)

    def test_tilde_in_configured_path_expands_to_home(self):
        cfg_dir = os.path.join(self.home, ".config", "disk-magician")
        os.makedirs(cfg_dir)
        with open(os.path.join(cfg_dir, "config.json"), "w") as f:
            json.dump({"state_repo_path": "~/.disk_magician_backup"}, f)
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, os.path.join(self.home, ".disk_magician_backup")))

if __name__ == "__main__":
    unittest.main()
