#!/usr/bin/env python3
"""test_agent_scratch_registry.py — verifies sweeper_roots.txt entries and expansion

Ensures:
1. /private/tmp/agent-scratch/disk_diagnostic is registered for scripts/lib/agent_scratch.sh
   and covers only disk_diagnostic scratch, refusing generic runtime coverage.
2. $DARWIN_USER_TEMP_DIR is registered for cleanup_tmp.sh / cleanup_pr_scratch.sh with
   budget ceiling and safety guards documented.
3. Expanded registry covers exact expected paths and rejects unrelated paths.
"""

import os
import sys
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO_ROOT, "scripts"))
import check_uncovered_roots as cur

REGISTRY_PATH = os.path.join(REPO_ROOT, "config", "sweeper_roots.txt")


class TestAgentScratchRegistry(unittest.TestCase):
    def test_registry_contains_disk_diagnostic_namespace(self):
        with open(REGISTRY_PATH) as f:
            lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]
        found = False
        for line in lines:
            parts = line.split("\t")
            if parts[0] == "/private/tmp/agent-scratch/disk_diagnostic":
                self.assertEqual(parts[1], "scripts/lib/agent_scratch.sh")
                found = True
                break
        self.assertTrue(found, "missing /private/tmp/agent-scratch/disk_diagnostic in sweeper_roots.txt")

    def test_registry_contains_darwin_user_temp_dir_budget_row(self):
        with open(REGISTRY_PATH) as f:
            lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]
        found = False
        for line in lines:
            parts = line.split("\t")
            if parts[0] == "$DARWIN_USER_TEMP_DIR":
                self.assertIn("cleanup_tmp.sh", parts[1])
                self.assertIn("cleanup_pr_scratch.sh", parts[1])
                note = parts[2] if len(parts) > 2 else ""
                self.assertIn("15 GiB", note)
                self.assertIn("safety", note)
                found = True
                break
        self.assertTrue(found, "missing $DARWIN_USER_TEMP_DIR budget-owned row in sweeper_roots.txt")

    def test_expansion_and_coverage(self):
        mock_home = "/Users/testuser"
        mock_darwin_tmp = "/private/var/folders/xx/mock_darwin_tmp/T"
        roots = cur.load_registry(REGISTRY_PATH, home=mock_home, darwin_tmp=mock_darwin_tmp)

        agent_scratch_roots = [(r, o) for r, o in roots if "agent_scratch" in o]
        # 1. Exact disk_diagnostic namespace covered by agent_scratch.sh
        self.assertTrue(
            cur.is_covered("/private/tmp/agent-scratch/disk_diagnostic/pid-12345", agent_scratch_roots),
            "disk_diagnostic run-id leaf should be covered by agent_scratch",
        )
        # 2. Generic unassigned runtime must NOT be covered by agent_scratch
        self.assertFalse(
            cur.is_covered("/private/tmp/agent-scratch/unassigned_runtime/run1", agent_scratch_roots),
            "generic unassigned runtime under agent-scratch must not be covered by agent_scratch",
        )
        self.assertFalse(
            cur.is_covered("/private/tmp/agent-scratch", agent_scratch_roots),
            "bare /private/tmp/agent-scratch must not be claimed as covered by agent_scratch",
        )

        # 3. DARWIN_USER_TEMP_DIR coverage
        self.assertTrue(
            cur.is_covered(mock_darwin_tmp, roots),
            "DARWIN_USER_TEMP_DIR root itself should be covered",
        )
        self.assertTrue(
            cur.is_covered(os.path.join(mock_darwin_tmp, "pr_scratch_dir"), roots),
            "subtree under DARWIN_USER_TEMP_DIR should be covered",
        )

        # 4. Unrelated paths not covered
        self.assertFalse(
            cur.is_covered("/opt/unrelated_dir", roots),
            "unrelated /opt path should not be covered",
        )
        self.assertFalse(
            cur.is_covered("/var/log/unrelated", roots),
            "unrelated var/log path should not be covered",
        )


if __name__ == "__main__":
    unittest.main()
