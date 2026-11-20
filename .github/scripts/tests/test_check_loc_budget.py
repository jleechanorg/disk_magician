#!/usr/bin/env python3
"""Contract tests for the repository production LOC budget."""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check_loc_budget.py"


class LocBudgetContract(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="loc-budget-")
        self.repo = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "LOC budget fixture")
        self.git("config", "user.email", "loc-budget@example.invalid")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def write(self, path: str, body: bytes | str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body.encode() if isinstance(body, str) else body)

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", message], check=True)
        return self.git("rev-parse", "HEAD")

    def check(self, base: str, head: str, rust_limit: int = 10_500, legacy_limit: int = 250):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.repo), "--base", base,
             "--head", head, "--rust-limit", str(rust_limit),
             "--legacy-net-limit", str(legacy_limit)],
            capture_output=True, text=True, check=False,
        )

    def test_checker_exists(self) -> None:
        self.assertTrue(SCRIPT.exists(), "production LOC budget checker has not been implemented")

    def test_legacy_budget_counts_net_production_growth_and_excludes_tests_and_generated_mirror(self) -> None:
        self.write("scripts/old.sh", "old\n" * 250)
        base = self.commit("base")
        self.write("scripts/new.sh", "new\n" * 500)
        self.write("scripts/old.sh", "")
        self.write("tests/test_new.sh", "test\n" * 900)
        self.write("src/disk_magician/cli.py", "generated\n" * 900)
        head = self.commit("replace code and add excluded sources")

        result = self.check(base, head, legacy_limit=250)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(": +250 / +250", result.stdout)
        self.write("scripts/extra.py", "extra\n")
        over = self.commit("one line over budget")
        result = self.check(base, over, legacy_limit=250)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(": +251 / +250", result.stdout)

    def test_rust_production_ceiling_counts_full_source_and_excludes_test_paths(self) -> None:
        self.write("rust/src/main.rs", "fn main() {}")
        self.write("rust/build.rs", "fn build() {}")
        self.write("rust/src/nested/module.rs", "#[cfg(test)]\nmod tests {\n let raw = r#\" } { \"#;\n fn fixture() {}\n}\nfn prod() {}")
        self.write("rust/tests/contract.rs", "test\n" * 500)
        self.write("rust/src/module.rs", "fn prod() {}\n")
        base = self.commit("rust base")
        self.write("rust/src/module.rs", "fn prod() {}\nfn extra() {}")
        head = self.commit("rust ceiling")

        result = self.check(base, head, rust_limit=9)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Rust production LOC: 10 / 9", result.stdout)

    def test_renaming_production_source_does_not_change_the_net_total(self) -> None:
        old_path = "scripts/" + "old.sh"
        self.write(old_path, "line\n" * 3)
        base = self.commit("base")
        self.git("mv", old_path, "scripts/new.sh")
        head = self.commit("rename production source")
        result = self.check(base, head, legacy_limit=0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(": +0 / +0", result.stdout)

    def test_uses_merge_base_not_the_latest_base_branch_tip(self) -> None:
        self.write("scripts/base.sh", "common\n")
        common = self.commit("common ancestor")
        self.git("checkout", "-qb", "base-line")
        self.write("scripts/base_extra.sh", "base\n" * 100)
        base = self.commit("base-only growth")
        self.git("checkout", "-qb", "head-line", common)
        self.write("scripts/head.sh", "head\n")
        head = self.commit("head growth")

        result = self.check(base, head, legacy_limit=0)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(": +1 / +0", result.stdout)
        self.assertIn(": +1 / +0", result.stdout)

    def test_non_rust_source_under_rust_tree_counts_toward_legacy_delta(self) -> None:
        self.write("scripts/main.sh", "main\n")
        base = self.commit("base")
        self.write("rust/helper.py", "helper\n")
        head = self.commit("non-Rust source in Rust directory")
        result = self.check(base, head, legacy_limit=0)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(": +1 / +0", result.stdout)

    def test_symlink_and_binary_blobs_do_not_count(self) -> None:
        self.write("scripts/real.sh", b"first\n")
        base = self.commit("base")
        (self.repo / "scripts/link.sh").symlink_to("real.sh")
        self.write("scripts/blob.py", b"\x00\xffbinary payload\n")
        head = self.commit("symlink and binary")
        result = self.check(base, head, legacy_limit=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(": +0 / +1", result.stdout)


if __name__ == "__main__":
    unittest.main()
