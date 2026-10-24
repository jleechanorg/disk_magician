import json, os, subprocess, tempfile, unittest, pathlib
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

    def test_snapshot_measure_overlay_does_not_hide_state_config(self):
        xdg = self._mk("home/.config/disk-magician/config.json")
        with open(xdg, "w") as f:
            f.write('{"snapshot_measure": {"path_max_seconds": 7}}\n')
        state = self._mk("home/.local/state/disk-magician/config/config.json")
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, state))

    def test_snapshot_overlay_is_usable_without_state_config(self):
        xdg = self._mk("home/.config/disk-magician/config.json")
        with open(xdg, "w") as f:
            f.write('{"snapshot_measure": {"path_max_seconds": 7}}\n')
        rc, out = resolve({"HOME": self.home})
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith("config.json.template"), out)

    def test_snapshot_overlay_uses_its_configured_state_repo(self):
        xdg = self._mk("home/.config/disk-magician/config.json")
        state_root = os.path.join(self.tmp, "custom-state")
        with open(xdg, "w") as f:
            f.write(json.dumps({
                "state_repo_path": state_root,
                "snapshot_measure": {"path_max_seconds": 7},
            }) + "\n")
        state = self._mk("custom-state/config/config.json")
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, state))

    def test_snapshot_measure_with_other_settings_is_full_xdg_config(self):
        xdg = self._mk("home/.config/disk-magician/config.json")
        with open(xdg, "w") as f:
            json.dump({"snapshot_measure": {"path_max_seconds": 7}, "budgets": {}}, f)
        state = self._mk("home/.local/state/disk-magician/config/config.json")
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, xdg))

    def test_state_repo_only_xdg_config_is_overlay(self):
        xdg = self._mk("home/.config/disk-magician/config.json")
        state_root = os.path.join(self.tmp, "custom-state")
        with open(xdg, "w") as f:
            json.dump({"state_repo_path": state_root}, f)
        state = self._mk("custom-state/config/config.json")
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, state))

    def test_non_string_state_repo_path_uses_default_chain(self):
        xdg = self._mk("home/.config/disk-magician/config.json")
        with open(xdg, "w") as f:
            json.dump({"snapshot_measure": {"path_max_seconds": 7}, "state_repo_path": 7}, f)
        rc, out = resolve({"HOME": self.home})
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith("config.json.template"), out)

    def test_state_repo_beats_packaged(self):
        st = self._mk("home/.local/state/disk-magician/config/config.json")
        rc, out = resolve({"HOME": self.home})
        self.assertEqual((rc, out), (0, st))

    def test_packaged_template_is_last_resort(self):
        rc, out = resolve({"HOME": self.home})
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith("config.json.template"), out)

    def test_invalid_explicit_override_does_not_fall_back(self):
        fallback = self._mk("home/.config/disk-magician/config.json")
        invalid = [
            os.path.join(self.tmp, "missing.json"),
            os.path.join(self.tmp, "config-dir"),
            os.path.join(self.tmp, "broken-link.json"),
        ]
        os.mkdir(invalid[1])
        os.symlink(os.path.join(self.tmp, "nowhere.json"), invalid[2])
        for path in invalid:
            with self.subTest(path=path):
                rc, out = resolve(
                    {"HOME": self.home, "DISK_MAGICIAN_CONFIG": path}
                )
                self.assertEqual((rc, out), (1, ""))
        self.assertEqual(open(fallback).read(), "{}")

if __name__ == "__main__":
    unittest.main()
