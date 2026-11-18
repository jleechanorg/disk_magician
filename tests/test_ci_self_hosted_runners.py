"""Contract tests verifying disk_magician CI workflows use self-hosted runners."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"

HOSTED_RUNNERS = (
    "macos-15",
    "macos-14",
    "macos-latest",
    "ubuntu-latest",
    "ubuntu-24.04",
    "ubuntu-22.04",
)


def _strip_yaml_comment(line: str) -> str:
    """Strip trailing YAML comments outside single/double quotes."""
    in_single = False
    in_double = False
    for idx, ch in enumerate(line):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            return line[:idx]
    return line


def _parse_workflow_jobs(workflow_path: Path) -> dict[str, dict[str, str]]:
    """Extract top-level job IDs and their `name` / `runs-on` fields using stdlib only."""
    jobs: dict[str, dict[str, str]] = {}
    in_jobs = False
    current_job: str | None = None

    for raw_line in workflow_path.read_text(encoding="utf-8").splitlines():
        line = _strip_yaml_comment(raw_line).rstrip()
        if not line.strip():
            continue

        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()

        if indent == 0:
            in_jobs = stripped == "jobs:"
            current_job = None
            continue

        if not in_jobs:
            continue

        if indent == 2 and stripped.endswith(":"):
            current_job = stripped[:-1].strip()
            jobs[current_job] = {}
            continue

        if current_job is not None and indent == 4:
            if stripped.startswith("name:"):
                val = stripped[len("name:") :].strip().strip("'\"")
                jobs[current_job]["name"] = val
            elif stripped.startswith("runs-on:"):
                val = stripped[len("runs-on:") :].strip()
                jobs[current_job]["runs-on"] = val

    return jobs


class TestCISelfHostedRunners(unittest.TestCase):
    """Ensure CI and Evidence Gate workflows target self-hosted runners."""

    def test_no_github_hosted_runners_in_workflows(self) -> None:
        for name in ("ci.yml", "evidence-gate.yml"):
            path = WORKFLOWS_DIR / name
            text = path.read_text(encoding="utf-8")
            for runner in HOSTED_RUNNERS:
                pattern = re.compile(rf"(?<![\w-]){re.escape(runner)}(?![\w-])")
                self.assertIsNone(
                    pattern.search(text),
                    f"{path} still references GitHub-hosted runner {runner!r}",
                )

    def test_ci_test_and_lint_targets_native_macos(self) -> None:
        ci_path = WORKFLOWS_DIR / "ci.yml"
        jobs = _parse_workflow_jobs(ci_path)
        matching = [
            job for job in jobs.values() if job.get("name") == "Test and lint"
        ]
        self.assertEqual(
            len(matching),
            1,
            f"Expected exactly one job with exact name 'Test and lint' in {ci_path}, got: {jobs}",
        )
        runs_on = matching[0].get("runs-on", "")
        self.assertIn(
            "self-hosted-native-macos",
            runs_on,
            f"'Test and lint' job must target self-hosted-native-macos, got runs-on={runs_on!r}",
        )

    def test_evidence_gate_targets_self_hosted_mikey(self) -> None:
        gate_path = WORKFLOWS_DIR / "evidence-gate.yml"
        jobs = _parse_workflow_jobs(gate_path)
        matching = [
            job for job in jobs.values() if job.get("name") == "Evidence Gate"
        ]
        self.assertEqual(
            len(matching),
            1,
            f"Expected exactly one job with exact name 'Evidence Gate' in {gate_path}, got: {jobs}",
        )
        runs_on = matching[0].get("runs-on", "")
        self.assertIn(
            "self-hosted",
            runs_on,
            f"'Evidence Gate' job must target self-hosted, got runs-on={runs_on!r}",
        )
        self.assertIn(
            "self-hosted-mikey",
            runs_on,
            f"'Evidence Gate' job must target self-hosted-mikey, got runs-on={runs_on!r}",
        )


if __name__ == "__main__":
    unittest.main()
