#!/usr/bin/env python3
"""tests/test_check_version_monotonic.py — Unit tests for monotonic version verification.

Bead: disk_magician-fo6 ("Verify pyproject version regressions are caught in CI")
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from scripts.check_version_monotonic import (
    FallbackVersion,
    extract_pyproject_version,
    find_historical_versions,
    get_git_tags,
    parse_version,
    run_check,
    verify_version_monotonic,
)

SCRIPT_PATH = REPO_ROOT / "scripts" / "check_version_monotonic.py"
GIT = shutil.which("git") or "/usr/bin/git"


class TestVersionParsingAndComparison(unittest.TestCase):
    """Test version parsing and ordering across standard semver and pre-releases."""

    def test_basic_ordering(self):
        v1 = parse_version("0.1.0")
        v2 = parse_version("0.2.0")
        v3 = parse_version("0.2.5")
        v4 = parse_version("0.2.46")
        v5 = parse_version("0.2.54")
        v6 = parse_version("0.2.55")

        self.assertTrue(v1 < v2 < v3 < v4 < v5 < v6)
        self.assertTrue(v5 > v4 > v3 > v2 > v1)
        self.assertEqual(v5, parse_version("0.2.54"))
        self.assertEqual(v5, parse_version("v0.2.54"))

    def test_semver_numeric_not_lexicographical(self):
        # In lexicographical string sort, "0.2.5" > "0.2.49", which is WRONG.
        # Monotonic check must use semver/PEP440 numeric ordering.
        v_low = parse_version("0.2.5")
        v_high = parse_version("0.2.49")
        self.assertTrue(v_low < v_high)
        self.assertFalse(v_high < v_low)

    def test_rebase_regression_artifact_case(self):
        # Reproduces the exact incident in bead disk_magician-fo6 (c346819):
        # 0.2.46 regressed to 0.2.23
        v_regressed = parse_version("0.2.23")
        v_previous = parse_version("0.2.46")
        v_target = parse_version("0.2.54")

        self.assertTrue(v_regressed < v_previous)
        self.assertTrue(v_previous < v_target)
        self.assertTrue(v_regressed < v_target)

    def test_prereleases(self):
        v_alpha = parse_version("0.3.0a1")
        v_beta = parse_version("0.3.0b1")
        v_rc = parse_version("0.3.0rc1")
        v_final = parse_version("0.3.0")

        self.assertTrue(v_alpha < v_beta < v_rc < v_final)
        self.assertTrue(parse_version("0.2.54") < v_alpha)

    def test_fallback_version_standalone(self):
        fv1 = FallbackVersion("0.2.5")
        fv2 = FallbackVersion("0.2.49")
        fv3 = FallbackVersion("0.2.54")
        self.assertTrue(fv1 < fv2 < fv3)
        self.assertEqual(fv3, FallbackVersion("v0.2.54"))
        self.assertTrue(fv3 <= FallbackVersion("0.2.54"))
        self.assertTrue(fv3 >= FallbackVersion("0.2.54"))
        self.assertFalse(fv3 < fv2)


class TestVerifyVersionMonotonic(unittest.TestCase):
    """Test verify_version_monotonic logic with various historical version sets."""

    def test_current_equal_to_highest(self):
        history = ["0.1.0", "0.2.0", "0.2.46", "0.2.54"]
        is_valid, curr, max_hist = verify_version_monotonic("0.2.54", history)
        self.assertTrue(is_valid)
        self.assertEqual(curr, "0.2.54")
        self.assertEqual(max_hist, "0.2.54")

    def test_current_greater_than_highest(self):
        history = ["0.1.0", "0.2.0", "0.2.46", "0.2.54"]
        is_valid, curr, max_hist = verify_version_monotonic("0.2.55", history)
        self.assertTrue(is_valid)
        self.assertEqual(curr, "0.2.55")
        self.assertEqual(max_hist, "0.2.54")

    def test_current_lower_than_highest_fails(self):
        history = ["0.1.0", "0.2.0", "0.2.46", "0.2.54"]
        is_valid, curr, max_hist = verify_version_monotonic("0.2.23", history)
        self.assertFalse(is_valid)
        self.assertEqual(curr, "0.2.23")
        self.assertEqual(max_hist, "0.2.54")

    def test_empty_history_passes(self):
        is_valid, curr, max_hist = verify_version_monotonic("0.1.0", [])
        self.assertTrue(is_valid)
        self.assertEqual(curr, "0.1.0")
        self.assertIsNone(max_hist)

    def test_history_with_v_prefixes_and_tags(self):
        history = ["v0.1.0", "0.2.0", "v0.2.50", "0.2.49"]
        is_valid, curr, max_hist = verify_version_monotonic("0.2.50", history)
        self.assertTrue(is_valid)
        self.assertEqual(max_hist, "v0.2.50")

        is_valid, curr, max_hist = verify_version_monotonic("0.2.48", history)
        self.assertFalse(is_valid)


class TestExtractPyprojectVersion(unittest.TestCase):
    """Test extracting version from pyproject.toml."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_valid_pyproject(self):
        p = self.tmp / "pyproject.toml"
        p.write_text('[project]\nname = "test-pkg"\nversion = "0.2.54"\n', encoding="utf-8")
        version = extract_pyproject_version(p)
        self.assertEqual(version, "0.2.54")

    def test_missing_file_raises(self):
        p = self.tmp / "nonexistent.toml"
        with self.assertRaises(FileNotFoundError):
            extract_pyproject_version(p)

    def test_missing_version_raises(self):
        p = self.tmp / "pyproject.toml"
        p.write_text('[project]\nname = "test-pkg"\n', encoding="utf-8")
        with self.assertRaises(ValueError):
            extract_pyproject_version(p)


class TestGitHistoryMonotonicIntegration(unittest.TestCase):
    """End-to-end integration tests using isolated git repositories."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()

        # Initialize git repo
        subprocess.run([GIT, "init", "-b", "main", str(self.repo)], check=True, capture_output=True)
        subprocess.run([GIT, "-C", str(self.repo), "config", "user.name", "Test Runner"], check=True)
        subprocess.run([GIT, "-C", str(self.repo), "config", "user.email", "fixture@users.noreply.github.com"], check=True)
        subprocess.run([GIT, "-C", str(self.repo), "config", "commit.gpgsign", "false"], check=True)

    def tearDown(self):
        self._tmp.cleanup()

    def _write_pyproject(self, version: str):
        p = self.repo / "pyproject.toml"
        p.write_text(
            f'[build-system]\nrequires = ["setuptools"]\n\n'
            f'[project]\nname = "test-pkg"\nversion = "{version}"\n',
            encoding="utf-8",
        )

    def _commit(self, msg: str):
        env = dict(os.environ)
        env["HERMES_SKIP_EXAMPLE_COM_GUARD"] = "1"
        subprocess.run([GIT, "-C", str(self.repo), "add", "pyproject.toml"], check=True, capture_output=True, env=env)
        subprocess.run([GIT, "-C", str(self.repo), "commit", "--no-verify", "-m", msg], check=True, capture_output=True, env=env)

    def test_initial_commit_passes(self):
        self._write_pyproject("0.1.0")
        self._commit("feat: initial commit")

        passed, msg = run_check(repo_dir=self.repo)
        self.assertTrue(passed)
        self.assertIn("0.1.0", msg)

    def test_version_bump_passes(self):
        self._write_pyproject("0.1.0")
        self._commit("v1")
        self._write_pyproject("0.2.0")
        self._commit("v2")
        self._write_pyproject("0.2.1")
        self._commit("v3")

        passed, msg = run_check(repo_dir=self.repo)
        self.assertTrue(passed)
        self.assertIn("0.2.1", msg)

    def test_version_regression_fails(self):
        self._write_pyproject("0.1.0")
        self._commit("v1")
        self._write_pyproject("0.2.50")
        self._commit("v2")
        # Regress version in working tree
        self._write_pyproject("0.2.23")

        passed, msg = run_check(repo_dir=self.repo)
        self.assertFalse(passed)
        self.assertIn("Version regression detected", msg)
        self.assertIn("0.2.23", msg)
        self.assertIn("0.2.50", msg)

    def test_git_tag_catches_regression(self):
        self._write_pyproject("0.1.0")
        self._commit("v1")
        subprocess.run([GIT, "-C", str(self.repo), "tag", "v0.3.0"], check=True)

        # pyproject is 0.1.0, but tag is v0.3.0
        passed, msg = run_check(repo_dir=self.repo)
        self.assertFalse(passed)
        self.assertIn("Version regression detected", msg)
        self.assertIn("0.3.0", msg)

    def test_cli_invocation_pass_and_fail(self):
        self._write_pyproject("0.1.0")
        self._commit("v1")
        self._write_pyproject("0.2.0")
        self._commit("v2")

        # Pass case
        r_pass = subprocess.run(
            [sys.executable, str(SCRIPT_PATH), "--repo", str(self.repo)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r_pass.returncode, 0, f"Expected 0, got {r_pass.returncode}: {r_pass.stderr}")
        self.assertIn("Version monotonic check passed", r_pass.stdout)

        # Regress
        self._write_pyproject("0.1.5")
        r_fail = subprocess.run(
            [sys.executable, str(SCRIPT_PATH), "--repo", str(self.repo)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r_fail.returncode, 1, f"Expected 1, got {r_fail.returncode}: {r_fail.stdout}")
        self.assertIn("Version regression detected", r_fail.stderr)

    def test_non_git_directory_passes_gracefully(self):
        non_git = self.tmp / "nongit"
        non_git.mkdir()
        p = non_git / "pyproject.toml"
        p.write_text('[project]\nversion = "0.1.0"\n', encoding="utf-8")

        passed, msg = run_check(repo_dir=non_git)
        self.assertTrue(passed)
        self.assertIn("Not inside a git repository", msg)

    def test_real_repo_check_passes(self):
        passed, msg = run_check(repo_dir=REPO_ROOT)
        self.assertTrue(passed, f"Real repo monotonic check should pass: {msg}")
        self.assertIn("Version monotonic check passed", msg)


if __name__ == "__main__":
    unittest.main()
