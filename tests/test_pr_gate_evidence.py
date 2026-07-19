#!/usr/bin/env python3
"""Behavioral tests for the PR evidence schema used by GitHub Actions."""

from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / ".github" / "scripts" / "validate_evidence.py"


def validate(body: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(VALIDATOR)],
        input=body,
        text=True,
        capture_output=True,
        check=False,
    )


class EvidenceGateTest(unittest.TestCase):
    def test_rejects_missing_evidence_section(self) -> None:
        result = validate("## Summary\nSmall tooling change.\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("## Evidence", result.stderr)

    def test_rejects_unfilled_template(self) -> None:
        result = validate(
            """## Evidence
**Claim class:** <!-- tooling | documentation-only | production -->
**Verdict:** <!-- PASS | PARTIAL | INSUFFICIENT | FAIL -->
**Commands and results:** <!-- exact commands and observed results -->
**What this proves:** <!-- bounded claim -->
**What this does not prove:** <!-- explicit limitation -->
"""
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("placeholder", result.stderr.lower())

    def test_accepts_tooling_partial_with_bounded_evidence(self) -> None:
        result = validate(
            """## Evidence
**Claim class:** tooling
**Verdict:** PARTIAL
**Commands and results:** `python3 -m unittest` — 8 tests passed.
**Evidence URL:** <!-- required for production; optional for tooling -->
**What this proves:** The local validator accepts and rejects the documented schema.
**What this does not prove:** External review services are installed or available.
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Evidence Gate: PASS", result.stdout)

    def test_accepts_documentation_pass_without_artifact_url(self) -> None:
        result = validate(
            """## Evidence
**Claim class:** documentation-only
**Verdict:** PASS
**Commands and results:** `cmp -s AGENTS.md CLAUDE.md` — exit 0.
**What this proves:** The documented policies remain mirrored.
**What this does not prove:** Runtime disk behavior changed.
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_partial_production_claim(self) -> None:
        result = validate(
            """## Evidence
**Claim class:** production
**Verdict:** PARTIAL
**Commands and results:** `bash tests/test_cleanup_safety.sh` — passed.
**What this proves:** The isolated test suite passed.
**What this does not prove:** The deployed launchd path ran this version.
"""
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production", result.stderr.lower())
        self.assertIn("PASS", result.stderr)

    def test_accepts_production_pass_with_gist(self) -> None:
        result = validate(
            """## Evidence
**Claim class:** production
**Verdict:** PASS
**Commands and results:** `bash tests/test_cleanup_safety.sh` — passed.
**Evidence URL:** https://gist.github.com/jleechan2015/0123456789abcdef
**What this proves:** The real operator call path completed at this commit.
**What this does not prove:** External reviewers will approve future changes.
"""
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_placeholder_evidence_fields(self) -> None:
        result = validate(
            """## Evidence
**Claim class:** production
**Verdict:** PASS
**Commands and results:** N/A
**Evidence URL:** https://gist.github.com/jleechan2015/0123456789abcdef
**What this proves:** trust me
**What this does not prove:** N/A
"""
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("placeholder", result.stderr.lower())

    def test_rejects_gist_url_without_owner_and_artifact_id(self) -> None:
        result = validate(
            """## Evidence
**Claim class:** production
**Verdict:** PASS
**Commands and results:** `bash tests/test_cleanup_safety.sh` — passed.
**Evidence URL:** https://gist.github.com/
**What this proves:** The real operator call path completed at this commit.
**What this does not prove:** External reviewers will approve future changes.
"""
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owner", result.stderr.lower())


class WorkflowContractTest(unittest.TestCase):
    def test_runtime_shell_scripts_avoid_known_bash4_only_primitives(self) -> None:
        violations = []
        for script in (ROOT / "scripts").glob("*.sh"):
            for line_number, line in enumerate(
                script.read_text(encoding="utf-8").splitlines(), start=1
            ):
                code = line.split("#", 1)[0]
                if re.search(r"\b(?:mapfile|readarray)\b|\bdeclare\s+-A\b", code):
                    violations.append(f"{script.name}:{line_number}")
        self.assertEqual(
            violations,
            [],
            "runtime scripts must run under macOS stock Bash 3.2",
        )

    def test_ci_fetches_history_for_pinned_regression_proofs(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "fetch-depth: 0",
            workflow,
            "CI must fetch pinned pre-fix commits used by regression tests",
        )

    def test_pull_request_gates_run_for_stacked_base_branches(self) -> None:
        for workflow_name, event_name in (
            ("ci.yml", "pull_request"),
            ("evidence-gate.yml", "pull_request_target"),
        ):
            lines = (ROOT / ".github" / "workflows" / workflow_name).read_text(
                encoding="utf-8"
            ).splitlines()
            start = lines.index(f"  {event_name}:")
            block = []
            for line in lines[start + 1 :]:
                if line and not line.startswith("    "):
                    break
                block.append(line)
            self.assertFalse(
                any(line.strip().startswith("branches:") for line in block),
                f"{workflow_name} must run when a PR is stacked on a non-main base",
            )

    def test_evidence_gate_runs_only_trusted_validator_code(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "evidence-gate.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("  pull_request_target:", workflow)
        self.assertNotIn("  pull_request:\n", workflow)
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", workflow)
        self.assertIn("path: trusted-gate", workflow)
        self.assertIn(
            "python3 trusted-gate/.github/scripts/validate_evidence.py",
            workflow,
        )
        self.assertNotIn("python3 .github/scripts/validate_evidence.py", workflow)


if __name__ == "__main__":
    unittest.main()
