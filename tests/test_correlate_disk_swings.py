"""tests/test_correlate_disk_swings.py — bead disk_magician-rpv.

Builds a throwaway git repo (never the real ~/.disk_magician_backup) with a
fabricated commit history of snapshots/disk_snapshot.json, then runs the
real scripts/correlate_disk_swings.py against it as a subprocess and checks
its output — matching this repo's practice of executing the real artifact
rather than reimplementing its logic (see
test_disk_snapshot_frontier_precedence.py's rationale).

Fixture shape:
  - 3 "pre-deploy" commits with no non-file-signal keys at all (simulates
    history predating this bead) including one swing that must be reported
    NO_COVERAGE, never silently attributed.
  - 12 "post-deploy" commits with full non-file-signal coverage, containing
    10 synthetic swings (>=8 GiB within <=60 min) whose injected signal
    deltas are engineered to sum to >=80% of each swing — proving the
    attribution arithmetic itself, not fabricating a real-world result.
  - One small delta (<8 GiB) and one large delta spanning >60 minutes, to
    prove the min-swing/max-window filters.
  - One commit with corrupt (unparseable) JSON, to prove skip-not-crash.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORRELATOR = os.path.join(REPO_ROOT, "scripts", "correlate_disk_swings.py")
RELPATH = "snapshots/disk_snapshot.json"

BASE_TIME = datetime(2026, 9, 1, 0, 0, 0, tzinfo=timezone.utc)


def _git(repo, *args):
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=30)
    assert proc.returncode == 0, f"git {args} failed: {proc.stderr}"
    return proc.stdout


def _commit_snapshot(repo, t, content, corrupt=False):
    path = os.path.join(repo, RELPATH)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        if corrupt:
            f.write("{not valid json,,,")
        else:
            json.dump(content, f)
    _git(repo, "add", RELPATH)
    iso = t.strftime("%Y-%m-%dT%H:%M:%S+00:00")
    env_overrides = {"GIT_AUTHOR_DATE": iso, "GIT_COMMITTER_DATE": iso}
    old_env = {k: os.environ.get(k) for k in env_overrides}
    os.environ.update(env_overrides)
    try:
        _git(repo, "commit", "-q", "-m", f"snapshot {iso}")
    finally:
        for k, v in old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def _base_snapshot(disk_used_gb, covered):
    d = {
        "schema_version": 2,
        "timestamp": None,  # filled by caller via the commit's own logic if needed
        "disk_used_gb": disk_used_gb,
        "disk_free_gb": 50,
        "snapshot_coverage_pct": 90.0,
        "directories": {},
    }
    if covered:
        d.update(
            {
                "apfs_volumes_gb": {"Data": float(disk_used_gb), "VM": 20.0, "Preboot": 7.0, "Update": 0.01},
                "apfs_container_free_gb": 30.0,
                "apfs_container_capacity_gb": 1000.0,
                "apfs_purgeable_estimate_gb": 0.5,
                "local_snapshots_count": 0,
                "local_snapshot_names": [],
                "colima_diffdisk_stat_allocated_gb": 2.0,
                "colima_diffdisk_du_allocated_gb": 2.0,
                "swap_used_gb": 1.0,
                "vm_volume_used_gb": 20.0,
            }
        )
    return d


class TestCorrelateDiskSwings(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name
        _git(self.repo, "init", "-q")
        # This repo's global pre-commit identity guard rejects RFC 2606
        # placeholder (@example.com) emails; use a real non-placeholder
        # identity even though this fixture repo is a throwaway
        # TemporaryDirectory that is never pushed anywhere.
        _git(self.repo, "config", "user.email", "jleechan2015@users.noreply.github.com")
        _git(self.repo, "config", "user.name", "disk_magician fixture")
        self.commits = []  # (time, snapshot_dict_or_None_if_corrupt)

    def tearDown(self):
        self.tmp.cleanup()

    def _write(self, t, snapshot=None, corrupt=False):
        _commit_snapshot(self.repo, t, snapshot, corrupt=corrupt)

    def _run_correlator(self, extra_args=None):
        args = [sys.executable, CORRELATOR, "--repo", self.repo, "--path", RELPATH, "--json"]
        args += extra_args or []
        proc = subprocess.run(args, capture_output=True, text=True, timeout=30)
        return proc

    def _run_correlator_text(self, extra_args=None):
        args = [sys.executable, CORRELATOR, "--repo", self.repo, "--path", RELPATH]
        args += extra_args or []
        proc = subprocess.run(args, capture_output=True, text=True, timeout=30)
        return proc

    def test_no_coverage_swing_is_reported_not_attributed(self):
        # Two pre-deploy commits, 30 min apart, with a 15 GiB swing but no
        # non-file-signal keys at all.
        self._write(BASE_TIME, _base_snapshot(800, covered=False))
        self._write(BASE_TIME + timedelta(minutes=30), _base_snapshot(815, covered=False))

        proc = self._run_correlator_text()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("NO_COVERAGE swings", proc.stdout)
        self.assertIn("+15.0 GiB", proc.stdout)
        self.assertIn("VERDICT: NOT MET", proc.stdout)
        self.assertIn("zero swings have non-file-signal coverage", proc.stdout)

        proc_json = self._run_correlator()
        summary = json.loads(proc_json.stdout)
        self.assertEqual(summary["covered_swings"], 0)
        self.assertEqual(summary["uncovered_swings"], 1)

    def test_min_swing_and_window_filters(self):
        t = BASE_TIME
        # Below the 8 GiB floor.
        self._write(t, _base_snapshot(800, covered=True))
        self._write(t + timedelta(minutes=35), _base_snapshot(805, covered=True))
        # Above the floor but outside the 60-min window.
        self._write(t + timedelta(minutes=200), _base_snapshot(820, covered=True))

        proc = self._run_correlator()
        summary = json.loads(proc.stdout)
        self.assertEqual(summary["covered_swings"] + summary["uncovered_swings"], 0)

    def test_ten_covered_swings_reach_80pct_and_verdict_met(self):
        t = BASE_TIME
        used = 800.0
        self._write(t, _base_snapshot(used, covered=True))

        # 10 swings, each >= 8 GiB within 35 minutes, with a colima delta
        # engineered to cover >=80% of each swing (the remainder is left
        # unexplained on purpose — this is attribution, not a perfect model).
        deltas = [15, -20, 8.5, -9, 12, -14, 10, -11, 9.5, -13]
        prev_colima = 2.0
        prev_vm = 20.0
        for i, delta in enumerate(deltas):
            t = t + timedelta(minutes=35)
            used = used + delta
            colima_contrib = delta * 0.85  # 85% of the swing lands on colima
            snap = _base_snapshot(round(used, 2), covered=True)
            snap["apfs_volumes_gb"]["Data"] = round(used, 2)  # consistency check tracks disk_used_gb
            snap["colima_diffdisk_du_allocated_gb"] = round(prev_colima + colima_contrib, 3)
            snap["colima_diffdisk_stat_allocated_gb"] = snap["colima_diffdisk_du_allocated_gb"]
            prev_colima = snap["colima_diffdisk_du_allocated_gb"]
            self._write(t, snap)

        proc = self._run_correlator()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        summary = json.loads(proc.stdout)
        self.assertEqual(summary["covered_swings"], 10, summary)
        self.assertGreaterEqual(summary["hit_80pct_bar"], 10, summary)

        text_proc = self._run_correlator_text()
        self.assertIn("VERDICT: MET", text_proc.stdout)
        self.assertIn("Colima diffdisk (du)", text_proc.stdout)
        self.assertIn("Data volume confirms", text_proc.stdout)

    def test_corrupt_commit_is_skipped_not_fatal(self):
        t = BASE_TIME
        self._write(t, _base_snapshot(800, covered=True))
        self._write(t + timedelta(minutes=35), None, corrupt=True)
        self._write(t + timedelta(minutes=70), _base_snapshot(820, covered=True))

        proc = self._run_correlator_text()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("skipped/unparseable", proc.stdout)

    def test_refuses_non_git_repo(self):
        with tempfile.TemporaryDirectory() as not_a_repo:
            proc = subprocess.run(
                [sys.executable, CORRELATOR, "--repo", not_a_repo, "--path", RELPATH],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("not a git repository", proc.stderr)


if __name__ == "__main__":
    unittest.main()
