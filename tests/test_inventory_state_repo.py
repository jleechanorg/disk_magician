import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATE_REPO = ROOT / "scripts" / "state_repo.sh"


class InventoryStateRepoContainmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()

    def run_init(self, repo, state):
        env = {
            "HOME": str(self.home),
            "PATH": "/usr/bin:/bin",
            "DISK_MAGICIAN_STATE_REPO": str(repo),
            "DISK_MAGICIAN_STATE_DIR": str(state),
        }
        return subprocess.run(["bash", str(STATE_REPO), "init"], cwd=ROOT,
                              env=env, text=True, capture_output=True)

    def test_rejects_equal_state_and_repo_before_staging(self):
        repo = self.root / "shared"
        result = self.run_init(repo, repo)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("separate", result.stderr.lower())
        self.assertFalse((repo / ".git" / "index").exists())

    def test_rejects_inventory_below_git_repo_before_staging(self):
        repo = self.root / "repo"
        state = repo / "nested" / "state"
        result = self.run_init(repo, state)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((repo / ".git" / "index").exists())

    def test_rejects_git_repo_below_inventory_root_before_staging(self):
        state = self.root / "state"
        repo = state / "nested-repo"
        result = self.run_init(repo, state)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((repo / ".git" / "index").exists())

    def test_rejects_symlink_alias_overlap(self):
        physical = self.root / "physical"
        alias = self.root / "alias"
        physical.mkdir()
        alias.symlink_to(physical, target_is_directory=True)
        repo = alias / "git-state"
        state = physical
        result = self.run_init(repo, state)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((physical / "git-state" / ".git" / "index").exists())

    def test_separate_inventory_store_is_not_tracked_by_state_repo(self):
        state = self.root / "inventory-state"
        inventory = state / "inventory"
        (inventory / "objects").mkdir(parents=True)
        (inventory / "indexes").mkdir()
        (inventory / "manifests").mkdir()
        (inventory / "objects" / "fixture.jsonl.gz").write_bytes(b"private inventory payload")
        (inventory / "indexes" / "fixture.json").write_text("{}")
        (inventory / "manifests" / "fixture.json").write_text("{}")
        repo = self.root / "git-state"
        result = self.run_init(repo, state)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        tracked = subprocess.check_output(
            ["git", "-C", str(repo), "ls-tree", "-r", "--name-only", "HEAD"],
            text=True,
        ).splitlines()
        self.assertFalse(any("/inventory/" in "/" + path or path.startswith("inventory/")
                             for path in tracked), tracked)
        self.assertTrue((inventory / "objects" / "fixture.jsonl.gz").exists())


if __name__ == "__main__":
    unittest.main()
