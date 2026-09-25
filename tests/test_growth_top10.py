#!/usr/bin/env python3
"""test_growth_top10.py — CLI-integration tests for scripts/growth_top10.py
(bead disk_magician-zyn Component G): sandboxed tempfile git repos, no real
$HOME. Mirrors tests/test_history_diff.py's fixture style."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "growth_top10.py"

GIB_KB = 1024 * 1024
USER_PROBE_PATHS = {
    "mobile_sync": os.path.join(os.path.expanduser("~"), "Library", "Application Support", "MobileSync", "Backup"),
    "mail": os.path.join(os.path.expanduser("~"), "Library", "Mail"),
    "messages": os.path.join(os.path.expanduser("~"), "Library", "Messages"),
}


def full_attribution_ledger(disk_used_kb, residual_kb, buckets, captured_at="2026-09-01T00:00:00Z"):
    """A ledger that passes both validate_ledger AND
    validate_full_attribution_ledger — eligible as a floor candidate."""
    bucket_total = sum(item.get("measured_kb", 0) for item in buckets)
    tail = disk_used_kb - bucket_total - residual_kb
    return {
        "schema_version": 2,
        "mode": "complete",
        "coverage_envelope": {
            "complete": True,
            "fda_preflight_status": "granted",
            "fda_user_preflight_status": "granted",
            "reachable_top_level_roots": 1,
            "measured_top_level_roots": 1,
            "unfinished_top_level_roots": 0,
        },
        "frontier_unfinished": [],
        "fda_probe_paths": dict(USER_PROBE_PATHS),
        "fda_preflight": {
            "status": "granted",
            "probes": {
                name: {"path": path, "status": "readable"}
                for name, path in USER_PROBE_PATHS.items()
            },
        },
        "accounting_equation": {
            "displayed_balanced": tail >= 0, "display_ledger_valid": tail >= 0,
            "data_used_kb": disk_used_kb, "displayed_buckets_kb": bucket_total,
            "oversize_indivisible_files_kb": 0, "sub_granularity_tail_kb": tail,
            "purgeable_kb": 0, "residual_kb": residual_kb,
            "clone_shared_adjustment_kb": 0,
        },
        "captured_at": captured_at,
        "hostname": "sandbox-host",
        "disk_used_kb": disk_used_kb,
        "residual_kb": residual_kb,
        "granularity_buckets": buckets,
        "oversize_indivisible_files": [],
        "opaque_intrinsic_gates": [],
    }


def structural_ledger(disk_used_kb, residual_kb, buckets, mode="partial", captured_at="2026-09-10T00:00:00Z",
                       measured=3, reachable=7):
    """A structurally-valid but NOT full-attribution ledger — the shape
    topdown-5g.partial.json takes on an incomplete scan."""
    return {
        "schema_version": 2,
        "mode": mode,
        "coverage_envelope": {
            "measured_top_level_roots": measured,
            "reachable_top_level_roots": reachable,
        },
        "captured_at": captured_at,
        "hostname": "sandbox-host",
        "disk_used_kb": disk_used_kb,
        "residual_kb": residual_kb,
        "granularity_buckets": buckets,
        "oversize_indivisible_files": [],
        "opaque_intrinsic_gates": [],
    }


def _git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, check=True,
    )


def _commit_ledger(repo, ledger_obj, msg):
    ledger_dir = repo / "ledger"
    ledger_dir.mkdir(exist_ok=True)
    (ledger_dir / "topdown-5g.json").write_text(json.dumps(ledger_obj))
    _git(repo, "add", "ledger/topdown-5g.json")
    subprocess.run(
        ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", msg],
        capture_output=True, text=True, check=True,
    )


def _write_working_tree(repo, rel, obj):
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj))


class TestGrowthTop10(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.repo = self.tmp / "state"
        self.repo.mkdir()
        try:
            _git(self.repo, "init", "-q", "-b", "main")
        except subprocess.CalledProcessError:
            _git(self.repo, "init", "-q")
            _git(self.repo, "symbolic-ref", "HEAD", "refs/heads/main")

    def _run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--state-dir", str(self.repo), *args],
            capture_output=True, text=True,
        )

    def test_prefers_working_tree_partial_over_committed_canonical(self):
        floor = full_attribution_ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        _commit_ledger(self.repo, floor, "floor")
        # Canonical HEAD still shows the floor's numbers (no new complete scan).
        canonical_stale = full_attribution_ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        # Partial working-tree file is the freshest scan, showing real growth.
        partial = structural_ledger(9 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 4 * GIB_KB},
            {"path": "/fixture_growth", "measured_kb": 5 * GIB_KB},
        ])
        _write_working_tree(self.repo, "ledger/topdown-5g.partial.json", partial)

        result = self._run_cli()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("current (partial)", result.stdout)
        self.assertIn("+5.00 GiB  /fixture_growth", result.stdout)
        self.assertIn("gap: +5.00 GiB", result.stdout)
        self.assertIn("(partial: 3/7 roots measured)", result.stdout)

    def test_falls_back_to_canonical_when_no_partial_present(self):
        floor = full_attribution_ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        _commit_ledger(self.repo, floor, "floor")
        target = full_attribution_ledger(6 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 4 * GIB_KB},
            {"path": "/growth", "measured_kb": 2 * GIB_KB},
        ])
        _commit_ledger(self.repo, target, "target")

        result = self._run_cli()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("current (canonical)", result.stdout)
        self.assertIn("+2.00 GiB  /growth", result.stdout)

    def test_falls_back_to_canonical_when_partial_is_structurally_invalid(self):
        floor = full_attribution_ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        _commit_ledger(self.repo, floor, "floor")
        target = full_attribution_ledger(6 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 4 * GIB_KB},
            {"path": "/growth", "measured_kb": 2 * GIB_KB},
        ])
        _commit_ledger(self.repo, target, "target")
        # Missing required keys (disk_used_kb/residual_kb) -> LedgerError.
        _write_working_tree(self.repo, "ledger/topdown-5g.partial.json", {"schema_version": 2})

        result = self._run_cli()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("current (canonical)", result.stdout)

    def test_exit_2_when_no_full_attribution_floor_in_window(self):
        # Only a structural (partial) ledger is committed — never qualifies
        # as a floor candidate (select_floor_ref requires full attribution).
        partial = structural_ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        _commit_ledger(self.repo, partial, "only partial ever committed")

        result = self._run_cli()

        self.assertEqual(result.returncode, 2)
        self.assertIn("disk_magician-4y6", result.stderr)

    def test_exit_1_when_no_valid_current_ledger(self):
        floor = full_attribution_ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        # A repo with a real floor commit, but whose HEAD working-tree
        # canonical file is corrupted and has no partial to fall back to —
        # exercises the CLI's exit-1 "no valid current" path specifically
        # (distinct from exit-2 "no floor", which fires first if both are
        # missing).
        floor_repo = self.tmp / "floor-only"
        floor_repo.mkdir()
        _git(floor_repo, "init", "-q")
        _git(floor_repo, "symbolic-ref", "HEAD", "refs/heads/main")
        _commit_ledger(floor_repo, floor, "floor")
        # Corrupt HEAD's canonical file content on disk (working tree) so the
        # working-tree read (not git show) fails validation, with no partial
        # file to fall back to either.
        (floor_repo / "ledger" / "topdown-5g.json").write_text("not json")

        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--state-dir", str(floor_repo)],
            capture_output=True, text=True,
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("no valid ledger snapshot found", result.stderr)

    def test_limits_and_sorts_growth_to_positive_deltas_only(self):
        # Bucket sizes stay well under the 5 GiB per-bucket ceiling
        # validate_ledger enforces (100 MiB base + up to 900 MiB growth).
        unit_kb = 100 * 1024
        floor = full_attribution_ledger(10 * unit_kb, 0, [
            {"path": f"/p{i}", "measured_kb": unit_kb} for i in range(10)
        ])
        _commit_ledger(self.repo, floor, "floor")
        buckets = [{"path": f"/p{i}", "measured_kb": (1 + i) * unit_kb} for i in range(10)]  # p0..p9 grow by i units
        buckets.append({"path": "/shrunk", "measured_kb": 0})
        target = full_attribution_ledger(sum(b["measured_kb"] for b in buckets), 0, buckets)
        _commit_ledger(self.repo, target, "target")

        result = self._run_cli("--limit", "3")

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [ln for ln in result.stdout.splitlines() if "GiB  /" in ln]
        self.assertEqual(len(lines), 3)
        self.assertIn("/p9", lines[0])  # largest delta (+9 GiB) first
        self.assertIn("/p8", lines[1])
        self.assertIn("/p7", lines[2])
        self.assertNotIn("/shrunk", result.stdout)  # negative delta excluded

    def test_falls_back_to_canonical_when_partial_has_non_dict_bucket_item(self):
        # /advice round 2 (Codex): validate_ledger assumes each bucket item
        # is a dict and calls .get() on it directly, so a bare string bucket
        # entry raises AttributeError, not LedgerError. load_current must
        # catch that broadly and fall back to canonical rather than crash
        # the whole CLI.
        floor = full_attribution_ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        _commit_ledger(self.repo, floor, "floor")
        target = full_attribution_ledger(6 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 4 * GIB_KB},
            {"path": "/growth", "measured_kb": 2 * GIB_KB},
        ])
        _commit_ledger(self.repo, target, "target")
        malformed = structural_ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        malformed["granularity_buckets"].append("not-a-dict-bucket-entry")
        _write_working_tree(self.repo, "ledger/topdown-5g.partial.json", malformed)

        result = self._run_cli()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("current (canonical)", result.stdout)

    def test_coverage_suffix_does_not_crash_on_non_dict_coverage_envelope(self):
        # /advice round 2 (Codex): coverage_suffix crashes on a list
        # coverage_envelope (`envelope.get(...)` on a list). validate_ledger
        # does not constrain this field's type, so a malformed-but-otherwise-
        # valid partial must degrade gracefully instead of crashing the CLI.
        floor = full_attribution_ledger(4 * GIB_KB, 0, [{"path": "/a", "measured_kb": 4 * GIB_KB}])
        _commit_ledger(self.repo, floor, "floor")
        partial = structural_ledger(5 * GIB_KB, 0, [
            {"path": "/a", "measured_kb": 4 * GIB_KB},
            {"path": "/growth", "measured_kb": 1 * GIB_KB},
        ])
        partial["coverage_envelope"] = ["not", "a", "dict"]
        _write_working_tree(self.repo, "ledger/topdown-5g.partial.json", partial)

        result = self._run_cli()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("current (partial)", result.stdout)
        self.assertIn("(partial)", result.stdout)

    def test_days_and_limit_must_be_positive(self):
        result_days = self._run_cli("--days", "0")
        self.assertNotEqual(result_days.returncode, 0)
        result_limit = self._run_cli("--limit", "-1")
        self.assertNotEqual(result_limit.returncode, 0)


if __name__ == "__main__":
    unittest.main()
