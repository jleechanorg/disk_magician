import json, pathlib, unittest

TEMPLATE = pathlib.Path(__file__).resolve().parents[1] / "config.json.template"

# Previously unowned rebuildable/stale roots (bead disk_magician-qwdh).
DIRS = {
    "worktrees_worldarchitect_ai": "~/.worktrees/worldarchitect.ai",
    "tmp_worldarchitect_ai": "/private/tmp/worldarchitect.ai",
    "tmp_dm_archive": "/private/tmp/_disk_magician_archive",
    "project_worldai_frontend": "~/project_worldai_frontend",
    "worldarchitect_ai_worktrees": "~/worldarchitect.ai.worktrees",
    "llm_wiki_worktrees": "~/llm_wiki.worktrees",
    "project_agento": "~/project_agento",
    "actions_runner": "~/actions-runner",
    "local_state": "~/.local/state",
}


class TestTemplateMonitored(unittest.TestCase):
    def setUp(self):
        self.cfg = json.loads(TEMPLATE.read_text())

    def test_new_dirs_present_with_timeouts(self):
        by_key = {e["key"]: e for e in self.cfg["monitored_dirs"]}
        for key, path in DIRS.items():
            self.assertEqual(by_key[key]["path"], path, key)
            self.assertGreater(by_key[key]["timeout"], 0, key)

    def test_ios_release_glob(self):
        by_key = {e["key"]: e for e in self.cfg["monitored_globs"]}
        self.assertEqual(by_key["tmp_worldai_ios_release"]["pattern"], "/private/tmp/worldai-ios-release-*")

    def test_keys_unique(self):
        keys = [e["key"] for e in self.cfg["monitored_dirs"] + self.cfg["monitored_globs"]]
        self.assertEqual(len(keys), len(set(keys)))


if __name__ == "__main__":
    unittest.main()
