"""Exercise hosted state-remote size checks with a local bare remote."""

import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GIT = shutil.which("git")


class StateRepoObjectCapTests(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        root = Path(fixture.name).resolve()
        self.home = root / "home"
        self.home.mkdir()
        self.state = root / "state-repo"
        self.remote = root / "remote.git"
        self.scan_mark = root / "secret-scan-called"
        self.range_mark = root / "size-check-range"
        bin_dir = root / "bin"
        bin_dir.mkdir()
        git = bin_dir / "git"
        git.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ ${3:-} == remote && ${4:-} == get-url &&\n"
            "      ( ${5:-} == --push || ( ${5:-} == origin && ${FIXTURE_SPLIT_URL:-} != 1 ) ) ]]; then\n"
            "  printf '%s\\n' https://github.com/test-fixture/remote.git\n"
            "  exit 0\n"
            "fi\n"
            "if [[ ${3:-} == ls-remote && ${6:-} == https://github.com/test-fixture/remote.git ]]; then\n"
            "  exit 2\n"
            "fi\n"
            "if [[ ${3:-} == rev-list && ${5:-} == --no-object-names ]]; then\n"
            "  printf '%s\\n' \"$6\" >\"$FIXTURE_RANGE_MARK\"\n"
            "fi\n"
            "if [[ ${3:-} == cat-file && ${4:-} == --batch-check=* ]]; then\n"
            "  cat >/dev/null\n"
            "  printf 'blob %s\\n' \"$FIXTURE_BLOB_BYTES\"\n"
            "  exit 0\n"
            "fi\n"
            f"exec {shlex.quote(GIT)} \"$@\"\n"
        )
        git.chmod(0o700)
        scanner = bin_dir / "gitleaks"
        scanner.write_text('#!/usr/bin/env bash\nprintf "called\\n" >"$FIXTURE_SCAN_MARK"\n')
        scanner.chmod(0o700)
        self.env = {
            "HOME": str(self.home), "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
            "DISK_MAGICIAN_STATE_REPO": str(self.state),
            "DISK_MAGICIAN_STATE_DIR": str(root / "runtime"),
            "DISK_MAGICIAN_ALLOW_PUBLIC_STATE": "1",
            "DISK_MAGICIAN_GITLEAKS_BIN": str(scanner),
            "FIXTURE_SCAN_MARK": str(self.scan_mark),
            "FIXTURE_RANGE_MARK": str(self.range_mark),
        }
        self.git("init", "--quiet", "--bare", self.remote)
        self.git("init", "--quiet", "-b", "main", self.state)
        (self.state / "MACHINE").write_text("synthetic fixture\n")
        self.git("-C", self.state, "add", "MACHINE")
        self.git("-C", self.state, "-c", "user.name=Fixture", "-c",
                 "user.email=fixture@localhost", "commit", "-qm", "state fixture")
        self.git("-C", self.state, "remote", "add", "origin", self.remote)

    def git(self, *args):
        return subprocess.check_output([GIT, *args], env=self.env, text=True, timeout=10)

    def push(self, size, split_url=False):
        return subprocess.run(
            ["bash", ROOT / "scripts/state_repo.sh", "push"],
            env={**self.env, "FIXTURE_BLOB_BYTES": str(size),
                 "FIXTURE_SPLIT_URL": "1" if split_url else "0"}, capture_output=True,
            text=True, timeout=15, check=False,
        )

    def test_object_over_github_limit_never_reaches_secret_scan_or_push(self):
        result = self.push(100 * 1024 * 1024 + 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("100 MiB", result.stderr)
        self.assertFalse(self.scan_mark.exists())
        self.assertEqual(self.git("-C", self.remote, "rev-list", "--all").strip(), "")

    def test_object_at_limit_still_reaches_secret_scan_and_push(self):
        result = self.push(100 * 1024 * 1024)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.scan_mark.is_file())
        self.assertEqual(
            self.git("-C", self.remote, "rev-parse", "refs/heads/main"),
            self.git("-C", self.state, "rev-parse", "HEAD"),
        )

    def test_distinct_github_push_url_uses_its_own_range(self):
        # The ordinary fetch remote already has the commit. The different
        # GitHub push destination reports an empty branch.
        self.git("-C", self.state, "push", "-q", "origin", "main")
        result = self.push(100 * 1024 * 1024 + 1, split_url=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("100 MiB", result.stderr)
        self.assertEqual(self.range_mark.read_text().strip(), "HEAD")
        self.assertFalse(self.scan_mark.exists())
