"""Read-only probe regressions for launchd PATH and escaped path names."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESTRICTED_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


class ProbeRuntimeBoundaries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="probe-runtime-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.target = self.root / "candidate"
        self.target.mkdir()
        self.marker = self.root / "lsof-called"
        self.lsof = self.root / "lsof"
        self.lsof.write_text(
            '#!/bin/sh\nprintf called > "$PROBE_MARKER"\n'
            'printf "p1\\nn%s\\n" "${PROBE_NAME:-/unrelated/path}"\n'
        )
        self.lsof.chmod(0o755)
        self.timeout = self.root / "timeout"
        self.timeout.write_text('#!/bin/sh\nshift\nshift\nexec "$@"\n')
        self.timeout.chmod(0o755)
        source = (ROOT / "scripts/cleanup_tmp.sh").read_text()
        marker = "has_ambiguous_lsof_path() {"
        if marker not in source:
            marker = "has_control_bytes() {"
        start = source.index(marker)
        end = source.index("# archive_path <dir>", start)
        self.guard = (
            'log() { printf "%s\\n" "$*"; };\n'
            + source[start:end]
            + '\nhas_open_files "$1"\n'
        )
        self.env = {
            "PATH": RESTRICTED_PATH,
            "HOME": str(self.root),
            "LC_ALL": "C",
            "DISK_MAGICIAN_LSOF_BIN": str(self.lsof),
            "PROBE_MARKER": str(self.marker),
        }

    def run_guard(self, target=None, **overrides):
        return subprocess.run(
            ["/bin/bash", "-c", self.guard, "probe", str(target or self.target)],
            env={**self.env, **overrides}, capture_output=True, text=True, timeout=20,
        )

    def test_escaped_candidate_names_are_preserved_without_probing(self):
        for name in ("café", "literal\\backslash", "line\nbreak"):
            with self.subTest(name=name):
                target = self.root / name
                target.mkdir()
                escaped = os.fsencode(os.path.realpath(target)).decode("ascii", "backslashreplace")
                result = self.run_guard(
                    target, PROBE_NAME=escaped + "/held",
                    DISK_MAGICIAN_TIMEOUT_BIN=str(self.timeout),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("non-ASCII bytes, or backslashes", result.stdout)
                self.assertFalse(self.marker.exists())

    def test_invalid_and_overflowing_lsof_deadlines_do_not_run_probe(self):
        for value in ("0", "61", "999", "18446744073709551617", "bad"):
            with self.subTest(value=value):
                result = self.run_guard(
                    DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS=value,
                    DISK_MAGICIAN_TIMEOUT_BIN="/usr/bin/true",
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("invalid timeout", result.stdout)
                self.assertFalse(self.marker.exists())

    def test_launchd_path_resolves_timeout_and_runs_closed_probe(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertTrue(self.marker.exists())

    def test_docker_timeout_resolver_supports_launchd_path(self):
        result = subprocess.run(
            ["/bin/bash", "-c", 'source "$1"; _resolve_timeout_cmd', "probe",
             str(ROOT / "scripts/lib/docker_probe.sh")],
            env=self.env, capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.access(result.stdout.strip(), os.X_OK))


if __name__ == "__main__":
    unittest.main()
