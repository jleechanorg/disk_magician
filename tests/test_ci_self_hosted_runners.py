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
            text = path.read_text(encoding="utf-8")
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

    def test_ci_test_and_lint_targets_native_macos(self) -> None:
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
        self.assertIn(
            "self-hosted-native-macos",
            runs_on,
            f"'Test and lint' job must target self-hosted-native-macos, got runs-on={runs_on!r}",
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

    def test_ci_venv_path_precedence_and_explicit_venv_python(self) -> None:
        ci_path = WORKFLOWS_DIR / "ci.yml"
        lines = ci_path.read_text(encoding="utf-8").splitlines()
        text = "\n".join(lines)

        def _find_github_path_line(entry: str) -> int:
            for idx, line in enumerate(lines):
                if entry in line and "$GITHUB_PATH" in line:
                    return idx
            self.fail(f"Missing $GITHUB_PATH append for {entry!r} in {ci_path}")

        homebrew_idx = _find_github_path_line("/opt/homebrew/bin")
        home_bin_idx = _find_github_path_line("$HOME/bin")
        local_bin_idx = _find_github_path_line("$HOME/.local/bin")
        ci_shims_idx = _find_github_path_line("$CI_SHIMS")
        venv_bin_idx = _find_github_path_line("$VENV_DIR/bin")

        self.assertGreater(
            venv_bin_idx,
            homebrew_idx,
            "$VENV_DIR/bin must be appended to $GITHUB_PATH after /opt/homebrew/bin",
        )
        self.assertGreater(
            venv_bin_idx,
            home_bin_idx,
            "$VENV_DIR/bin must be appended to $GITHUB_PATH after $HOME/bin",
        )
        self.assertGreater(
            venv_bin_idx,
            local_bin_idx,
            "$VENV_DIR/bin must be appended to $GITHUB_PATH after $HOME/.local/bin",
        )
        self.assertGreater(
            venv_bin_idx,
            ci_shims_idx,
            "$VENV_DIR/bin must be appended to $GITHUB_PATH after $CI_SHIMS",
        )

        self.assertRegex(
            text,
            r'VENV_PYTHON=\$\{?VENV_DIR\}?/bin/python.*GITHUB_ENV',
            f"{ci_path} must export VENV_PYTHON to $GITHUB_ENV",
        )
        self.assertIn(
            "uv venv --seed",
            text,
            f"{ci_path} must seed pip inside uv venv for packaging tests",
        )
        self.assertNotIn(
            "pytest-xdist",
            text,
            f"{ci_path} must not install pytest-xdist into diskm-ci-venv",
        )
        self.assertIn(
            'pytest "PyYAML>=6.0"',
            text,
            f"{ci_path} must install pytest and PyYAML>=6.0 into diskm-ci-venv",
        )
        self.assertIn(
            '"$VENV_PYTHON" -m pytest -q tests --ignore=tests/test_lease_recover_lock.py',
            text,
            f'{ci_path} must run serial pytest with "$VENV_PYTHON"',
        )
        self.assertIn(
            '"$VENV_PYTHON" tests/test_lease_recover_lock.py',
            text,
            f'{ci_path} must run test_lease_recover_lock.py directly with "$VENV_PYTHON"',
        )
        self.assertIn(
            '"$VENV_PYTHON" -m pytest -q',
            text,
            f'{ci_path} must run inventory pytest with "$VENV_PYTHON"',
        )
        self.assertNotIn("unittest discover", text)
        self.assertNotIn("python3 -m unittest", text)
        self.assertNotIn("python3 -m pytest", text)

    def test_ci_isolates_home_git_config_and_serial_timing_suites(self) -> None:
        ci_path = WORKFLOWS_DIR / "ci.yml"
        steps = _parse_job_steps(ci_path, "test")

        setup_body = steps.get("Set up isolated Python 3.13 venv and verify tools", "")
        self.assertIn('CI_HOME="${RUNNER_TEMP}/ci-home"', setup_body)
        self.assertIn('CI_SHIMS="${RUNNER_TEMP}/ci-lowprio-shims"', setup_body)
        self.assertIn('GIT_CONFIG_GLOBAL="${RUNNER_TEMP}/gitconfig-ci"', setup_body)
        self.assertIn('echo "CI_HOME=${CI_HOME}" >> "$GITHUB_ENV"', setup_body)
        self.assertIn('echo "GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL}" >> "$GITHUB_ENV"', setup_body)
        self.assertIn(
            'echo "DISK_MAGICIAN_FRONTIER_ROOT_JSON=${RUNNER_TEMP}/nonexistent-frontier.json" >> "$GITHUB_ENV"',
            setup_body,
        )
        self.assertIn('echo "DISK_MAGICIAN_TEST_JOBS=4" >> "$GITHUB_ENV"', setup_body)
        self.assertIn('git config --global user.name', setup_body)
        self.assertIn('git config --global user.email', setup_body)
        self.assertIn("$CI_HOME/.local/bin/diskm", setup_body)
        self.assertIn("registry.json", setup_body)
        self.assertIn("./scripts/resolve_config.py", setup_body)
        self.assertIn("config.json.template", setup_body)
        self.assertIn("$CI_SHIMS/taskpolicy", setup_body)
        self.assertIn("$CI_SHIMS/nice", setup_body)

        for step_name in (
            "Run Python tests",
            "Run inventory integration tests",
            "Run shell tests",
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

        python_step = steps.get("Run Python tests", "")
        self.assertNotIn(
            "-n ",
            python_step,
            "Run Python tests must run serially without pytest-xdist -n workers",
        )
        self.assertIn(
            '"$VENV_PYTHON" -m pytest -q tests --ignore=tests/test_lease_recover_lock.py',
            python_step,
        )
        self.assertIn(
            '"$VENV_PYTHON" tests/test_lease_recover_lock.py',
            python_step,
        )

        cleanup_body = steps.get("Clean up isolated CI venv", "")
        self.assertIn("/ci-home", cleanup_body)
        self.assertIn("/ci-lowprio-shims", cleanup_body)
        self.assertIn("/gitconfig-ci", cleanup_body)

    def test_ci_timeout_and_caffeinate_guard(self) -> None:
        ci_path = WORKFLOWS_DIR / "ci.yml"
        jobs = _parse_workflow_jobs(ci_path)
        self.assertEqual(
            jobs.get("test", {}).get("timeout-minutes"),
            "150",
            f"{ci_path} jobs.test must keep timeout-minutes: 150",
        )
        steps = _parse_job_steps(ci_path, "test")
        guarded_steps = (
            "Check shell syntax and ShellCheck errors",
            "Run Python tests",
            "Run inventory integration tests",
            "Run shell tests",
        )
        for step_name in guarded_steps:
            self.assertIn(step_name, steps, f"Missing step {step_name!r} in {ci_path}")
            body = steps[step_name]
            self.assertIn(
                "-x /usr/bin/caffeinate",
                body,
                f"Step {step_name!r} must guard /usr/bin/caffeinate executability",
            )
            self.assertIn(
                "/usr/bin/caffeinate -i",
                body,
                f"Step {step_name!r} must run under /usr/bin/caffeinate -i",
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
