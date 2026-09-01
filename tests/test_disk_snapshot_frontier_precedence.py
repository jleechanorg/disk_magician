import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK_SNAPSHOT_SH = os.path.join(REPO_ROOT, "scripts", "disk_snapshot.sh")

# Extract the actual embedded frontier-tiebreak Python heredoc from
# disk_snapshot.sh and execute it directly, instead of re-implementing the
# scoring logic here. A hand-copied reimplementation can silently drift from
# the real script (found in /advice review of PR #57: this file previously
# duplicated the pre-fix logic, so it kept passing even after the real
# heredoc's completeness/fail-closed bugs were fixed).
_HEREDOC_RE = re.compile(
    r"^TOPDOWN_JSON=\$\(python3 - .*?<<'PY'[^\n]*\n(.*?)\nPY\n\)",
    re.S | re.M,
)


def _extract_frontier_heredoc() -> str:
    with open(DISK_SNAPSHOT_SH) as f:
        content = f.read()
    match = _HEREDOC_RE.search(content)
    if not match:
        raise AssertionError(
            "could not find the TOPDOWN_JSON frontier-tiebreak heredoc in "
            f"{DISK_SNAPSHOT_SH} — has it been renamed or restructured?"
        )
    return match.group(1)


_FRONTIER_HEREDOC_SOURCE = _extract_frontier_heredoc()
compile(_FRONTIER_HEREDOC_SOURCE, "disk_snapshot.sh::frontier_heredoc", "exec")


def rank_frontier_candidates(enabled, explicit_override_path, root_path, user_path):
    """Run the real disk_snapshot.sh frontier-tiebreak heredoc as a subprocess."""
    proc = subprocess.run(
        [sys.executable, "-c", _FRONTIER_HEREDOC_SOURCE, enabled, explicit_override_path, root_path, user_path],
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert proc.returncode == 0, f"heredoc exited {proc.returncode}: {proc.stderr}"
    stdout = proc.stdout.strip()
    if not stdout or stdout == "null":
        return None
    return json.loads(stdout)


class TestFrontierCandidateRanking(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write_json(self, name, data):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            json.dump(data, f)
        return path

    def _write_raw(self, name, text):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as f:
            f.write(text)
        return path

    def _ts(self, **delta_kwargs):
        import datetime

        now = datetime.datetime.now(datetime.timezone.utc)
        return (now - datetime.timedelta(**delta_kwargs)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def test_complete_user_scan_beats_newer_partial_root_scan(self):
        user_file = self._write_json(
            "user.json",
            {
                "captured_at": self._ts(hours=2),
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 1000,
            },
        )
        root_file = self._write_json(
            "root.json",
            {
                "captured_at": self._ts(minutes=30),
                "mode": "partial",
                "coverage_envelope": {"complete": False},
                "measured_total_kb": 800,
            },
        )

        res = rank_frontier_candidates("true", "", root_file, user_file)
        self.assertIsNotNone(res)
        self.assertEqual(res["measured_total_kb"], 1000)

    def test_complete_root_scan_beats_older_complete_user_scan(self):
        user_file = self._write_json(
            "user.json",
            {
                "captured_at": self._ts(hours=5),
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 1000,
            },
        )
        root_file = self._write_json(
            "root.json",
            {
                "captured_at": self._ts(hours=1),
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 1200,
            },
        )

        res = rank_frontier_candidates("true", "", root_file, user_file)
        self.assertIsNotNone(res)
        self.assertEqual(res["measured_total_kb"], 1200)

    def test_explicit_override_is_used_strictly_without_fallback(self):
        override_file = self._write_json(
            "override.json",
            {
                "captured_at": self._ts(hours=1),
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 9999,
            },
        )
        root_file = self._write_json(
            "root.json",
            {
                "captured_at": self._ts(minutes=10),
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 1200,
            },
        )

        res = rank_frontier_candidates("true", override_file, root_file, "")
        self.assertIsNotNone(res)
        self.assertEqual(res["measured_total_kb"], 9999)

    def test_coverage_envelope_complete_false_beats_bare_mode_complete(self):
        # mode == "complete" alone must NOT be treated as equivalent to a
        # genuinely complete scan when coverage_envelope says otherwise
        # (e.g. FDA was not granted, so the scanner itself flagged the run
        # incomplete despite finishing without an unfinished frontier).
        unproven_file = self._write_json(
            "unproven.json",
            {
                "captured_at": self._ts(minutes=5),
                "mode": "complete",
                "coverage_envelope": {"complete": False},
                "measured_total_kb": 500,
            },
        )
        genuinely_complete_file = self._write_json(
            "genuine.json",
            {
                "captured_at": self._ts(hours=3),
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 700,
            },
        )

        res = rank_frontier_candidates("true", "", unproven_file, genuinely_complete_file)
        self.assertIsNotNone(res)
        self.assertEqual(res["measured_total_kb"], 700)

    def test_legacy_snapshot_without_coverage_envelope_falls_back_to_mode(self):
        legacy_file = self._write_json(
            "legacy.json",
            {
                "captured_at": self._ts(minutes=5),
                "mode": "complete",
                "measured_total_kb": 321,
            },
        )
        res = rank_frontier_candidates("true", "", legacy_file, "")
        self.assertIsNotNone(res)
        self.assertEqual(res["measured_total_kb"], 321)

    def test_corrupt_explicit_override_fails_closed_without_fallback(self):
        corrupt_override = self._write_raw("override.json", "{not valid json")
        root_file = self._write_json(
            "root.json",
            {
                "captured_at": self._ts(minutes=10),
                "mode": "complete",
                "coverage_envelope": {"complete": True},
                "measured_total_kb": 1200,
            },
        )

        res = rank_frontier_candidates("true", corrupt_override, root_file, "")
        self.assertIsNone(res)


if __name__ == "__main__":
    unittest.main()
