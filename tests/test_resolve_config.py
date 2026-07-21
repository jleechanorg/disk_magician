import os, subprocess, tempfile, unittest, pathlib
REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "resolve_config.py"

def resolve(env_extra):
    env = {"PATH": "/usr/bin:/bin"}
    env.update(env_extra)
    r = subprocess.run(["python3", str(SCRIPT)], capture_output=True, text=True, env=env)
    return r.returncode, r.stdout.strip()

class TestResolveConfig(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "home"); os.makedirs(self.home)

    def _mk(self, rel):
        p = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write("{}")
        return p

    def test_env_override_wins(self):
        explicit = self._mk("explicit/config.json")
        xdg = self._mk("home/.config/disk-magician/config.json")
        rc, out = resolve({"HOME": self.home, "DISK_MAGICIAN_CONFIG": explicit})
        self.assertEqual((rc, out), (0, explicit))

    def test_xdg_beats_state_repo(self):
        xdg = self._mk("home/.config/disk-magician/config.json")
        self._mk("home/.local/state/disk-magician/config/config.json")
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, xdg))

    def test_state_repo_beats_packaged(self):
        st = self._mk("home/.local/state/disk-magician/config/config.json")
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, st))

    def test_packaged_template_is_last_resort(self):
        rc, out = resolve({"HOME": self.home})
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith("config.json.template"), out)

if __name__ == "__main__":
    unittest.main()
