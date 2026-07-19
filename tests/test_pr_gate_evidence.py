#!/usr/bin/env python3
"""Behavioral tests for the PR evidence schema used by GitHub Actions."""

from __future__ import annotations

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


if __name__ == "__main__":
    unittest.main()
