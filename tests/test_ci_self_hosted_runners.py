"""Contract tests verifying disk_magician CI workflows use self-hosted runners."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"

HOSTED_RUNNER_RE = re.compile(
    r"(?<![\w-])(?:ubuntu|macos|windows)-[A-Za-z0-9._-]+"
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
    """Extract top-level job IDs and their `name` / `runs-on` / `if` / `timeout-minutes` fields."""
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
            elif stripped.startswith("if:"):
                val = stripped[len("if:") :].strip()
                jobs[current_job]["if"] = val
            elif stripped.startswith("timeout-minutes:"):
                val = stripped[len("timeout-minutes:") :].strip()
                jobs[current_job]["timeout-minutes"] = val

    return jobs


def _parse_job_steps(workflow_path: Path, job_id: str) -> dict[str, str]:
    """Extract step name -> step body text for a top-level job using stdlib only."""
    steps: dict[str, str] = {}
    in_jobs = False
    in_target_job = False
    in_steps = False
    current_name: str | None = None
    current_lines: list[str] = []

    def _flush() -> None:
        if current_name is not None:
            steps[current_name] = "\n".join(current_lines)

    for raw_line in workflow_path.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip():
            if current_name is not None:
                current_lines.append("")
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        stripped = raw_line.strip()

        if indent == 0:
            _flush()
            current_name = None
            current_lines = []
            in_jobs = stripped == "jobs:"
            in_target_job = False
            in_steps = False
            continue
        if not in_jobs:
            continue
        if indent == 2 and stripped.endswith(":"):
            _flush()
            current_name = None
            current_lines = []
            in_target_job = stripped[:-1].strip() == job_id
            in_steps = False
            continue
        if not in_target_job:
            continue
        if indent == 4:
            if stripped == "steps:":
                in_steps = True
            else:
                _flush()
                current_name = None
                current_lines = []
                in_steps = False
            continue
        if not in_steps:
            continue
        if indent == 6 and stripped.startswith("- name:"):
            _flush()
            current_name = stripped[len("- name:") :].strip().strip("'\"")
            current_lines = [raw_line]
            continue
        if current_name is not None:
            current_lines.append(raw_line)

    _flush()
    return steps


class TestCISelfHostedRunners(unittest.TestCase):
    """Ensure CI and Evidence Gate workflows target self-hosted runners."""

    def test_no_github_hosted_runners_in_workflows(self) -> None:
        workflow_paths = sorted(WORKFLOWS_DIR.glob("*.yml"))
        self.assertTrue(workflow_paths, f"No workflow files found in {WORKFLOWS_DIR}")
        for path in workflow_paths:
            lines = [
                _strip_yaml_comment(raw_line)
                for raw_line in path.read_text(encoding="utf-8").splitlines()
            ]
            text = "\n".join(lines)
            match = HOSTED_RUNNER_RE.search(text)
            self.assertIsNone(
                match,
                f"{path} still references GitHub-hosted runner {match.group(0)!r}"
                if match
                else "",
            )
            self.assertNotIn(
                "sudo ",
                text,
                f"{path} must not use sudo (ezgha containers enforce no-new-privileges)",
            )

    def test_ci_test_and_lint_targets_self_hosted_linux(self) -> None:
        ci_path = WORKFLOWS_DIR / "ci.yml"
        jobs = _parse_workflow_jobs(ci_path)
        self.assertIn("test", jobs, f"Expected job 'test' in {ci_path}, got: {jobs}")
        matching = [
            job for job in jobs.values() if job.get("name") == "Test and lint"
        ]
        self.assertEqual(
            len(matching),
            1,
            f"Expected exactly one job with exact name 'Test and lint' in {ci_path}, got: {jobs}",
        )
        runs_on = matching[0].get("runs-on", "")
        fallback_match = re.search(r"\|\|\s*'([^']+)'", runs_on)
        self.assertIsNotNone(
            fallback_match,
            f"Expected JSON fallback label list in runs-on={runs_on!r}",
        )
        labels = json.loads(fallback_match.group(1))
        self.assertEqual(
            labels,
            ["self-hosted", "Linux", "self-hosted-mikey"],
            f"'Test and lint' default labels must pin self-hosted Linux, got {labels!r}",
        )

    def test_ci_native_macos_leg_gated_when_parked(self) -> None:
        ci_path = WORKFLOWS_DIR / "ci.yml"
        jobs = _parse_workflow_jobs(ci_path)
        self.assertIn("test-macos", jobs, f"Expected job 'test-macos' in {ci_path}")
        macos_job = jobs["test-macos"]
        self.assertIn(
            "self-hosted-native-macos",
            macos_job.get("runs-on", ""),
            "jobs.test-macos must target self-hosted-native-macos",
        )
        if_expr = macos_job.get("if", "")
        self.assertIn(
            "vars.EZGHA_NATIVE_MACOS_LEG == 'enabled'",
            if_expr,
            f"jobs.test-macos must be gated on EZGHA_NATIVE_MACOS_LEG while parked, got if={if_expr!r}",
        )
        self.assertIn(
            "github.event.pull_request.head.repo.full_name == github.repository",
            if_expr,
            f"jobs.test-macos must gate fork PRs, got if={if_expr!r}",
        )

    def test_ci_guards_untrusted_fork_prs(self) -> None:
        ci_path = WORKFLOWS_DIR / "ci.yml"
        jobs = _parse_workflow_jobs(ci_path)
        test_job = jobs.get("test", {})
        if_expr = test_job.get("if", "")
        self.assertIn(
            "github.event.pull_request.head.repo.full_name == github.repository",
            if_expr,
            f"jobs.test in {ci_path} must gate fork PRs, got if={if_expr!r}",
        )
        self.assertIn(
            "github.event_name != 'pull_request'",
            if_expr,
            f"jobs.test in {ci_path} must allow non-PR events, got if={if_expr!r}",
        )

    def test_ci_linux_venv_isolation_and_rootless_tools(self) -> None:
        ci_path = WORKFLOWS_DIR / "ci.yml"
        steps = _parse_job_steps(ci_path, "test")
        setup_body = steps.get(
            "Set up isolated Python venv and rootless Linux CI tools", ""
        )
        self.assertIn('CI_HOME="${RUNNER_TEMP}/ci-home"', setup_body)
        self.assertIn('CI_SHIMS="${RUNNER_TEMP}/ci-lowprio-shims"', setup_body)
        self.assertIn('GIT_CONFIG_GLOBAL="${RUNNER_TEMP}/gitconfig-ci"', setup_body)
        self.assertIn('echo "VENV_PYTHON=${VENV_DIR}/bin/python" >> "$GITHUB_ENV"', setup_body)
        self.assertIn('echo "CI_HOME=${CI_HOME}" >> "$GITHUB_ENV"', setup_body)
        self.assertIn('echo "GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL}" >> "$GITHUB_ENV"', setup_body)
        self.assertIn("shellcheck-py", setup_body)
        self.assertNotIn("pytest-xdist", setup_body)

        for step_name in (
            "Run Python tests",
            "Run inventory integration tests",
            "Run Linux and cross-platform shell tests",
        ):
            step_body = steps.get(step_name, "")
            self.assertIn(
                "HOME: ${{ env.CI_HOME }}",
                step_body,
                f"Step {step_name!r} must isolate HOME to env.CI_HOME",
            )
            self.assertIn(
                "unset BASH_ENV",
                step_body,
                f"Step {step_name!r} must unset BASH_ENV",
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
        fallback_match = re.search(r"\|\|\s*'([^']+)'", runs_on)
        self.assertIsNotNone(
            fallback_match,
            f"Expected JSON fallback label list in runs-on={runs_on!r}",
        )
        labels = json.loads(fallback_match.group(1))
        self.assertEqual(
            labels,
            ["self-hosted", "Linux", "self-hosted-mikey"],
            f"'Evidence Gate' default labels must pin Linux, got {labels!r}",
        )


if __name__ == "__main__":
    unittest.main()
