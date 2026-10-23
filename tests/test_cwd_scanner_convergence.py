#!/usr/bin/env python3
"""Regression tests for diskm-cwd-scan completeness (bead disk_magician-cjph).

The helper is a root-privileged read-only /proc cwd walker that the Linux live-cwd
gate trusts. Its contract is fail-closed: if it cannot prove it covered every live
process, it must exit non-zero, because the caller treats a failure as
`kept:cwd-unknown` (refuse all removal) rather than as an empty cwd map.

Two historical failures are pinned here:

1. The original rule demanded a SINGLE pass during which no new pid appeared
   (`if pids() <= names`), retried 5 times. On a host that forks continuously that
   is unsatisfiable, so it exited rc 1 with "process table kept changing" on every
   attempt -- measured on jeff-ubuntu 2026-10-23 (3/3 attempts, 0 records), which
   blocked all /tmp reclaim and kept the runner fleet below its disk floor.

2. A "fix" that broke early on a deadline/attempt budget and returned success with
   pids still unscanned. That is unsafe: a child can chdir() immediately after
   being skipped, so fork's cwd inheritance does not prove coverage. Coverage must
   never be traded for a verdict.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import sys
import unittest


SCANNER = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "diskm_cwd_scan.py"


def load_scanner():
    spec = importlib.util.spec_from_file_location("diskm_cwd_scan_under_test", SCANNER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class ScannerHarness:
    """Drives main() with a scripted /proc model instead of the real one."""

    def __init__(self, module, snapshots, records_for=None):
        self.module = module
        self.snapshots = list(snapshots)
        self.calls = 0
        self.scanned: set[bytes] = set()
        self.records_for = records_for or (lambda pid: [pid + b"\t1000\t/tmp/work\0"])

    def pids(self):
        # Serve each scripted snapshot once, then repeat the last one forever.
        index = min(self.calls, len(self.snapshots) - 1)
        self.calls += 1
        return set(self.snapshots[index])

    def scan(self, names):
        self.scanned |= set(names)
        out = []
        for pid in sorted(names, key=int):
            out.extend(self.records_for(pid))
        return out

    def run(self):
        module = self.module
        out = io.BytesIO()

        class _Stdout:
            buffer = out

        real_pids, real_scan, real_stdout = module.pids, module.scan, sys.stdout
        module.pids, module.scan = self.pids, self.scan
        try:
            sys.stdout = _Stdout()  # the helper writes to sys.stdout.buffer
            rc = None
            try:
                module.main()
            except SystemExit as exc:
                rc = exc.code if exc.code is not None else 0
            return (0 if rc is None else rc), out.getvalue()
        finally:
            module.pids, module.scan, sys.stdout = real_pids, real_scan, real_stdout


class TestCompleteness(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_scanner()
        # main() inspects argv: it must look like a bare invocation.
        self._argv = sys.argv
        sys.argv = ["diskm-cwd-scan"]

    def tearDown(self) -> None:
        sys.argv = self._argv

    def test_continuous_churn_still_converges(self) -> None:
        """New pids on every pass must not be fatal: scan only the unseen ones."""
        # Pass 1 sees 1-3, pass 2 sees 1-6 (children forked), pass 3 sees 1-8,
        # then it stabilises at 1-8. The old rule never accepted this.
        snapshots = [
            [b"1", b"2", b"3"],
            [b"1", b"2", b"3", b"4", b"5", b"6"],
            [b"1", b"2", b"3", b"4", b"5", b"6", b"7", b"8"],
            [b"1", b"2", b"3", b"4", b"5", b"6", b"7", b"8"],
        ]
        harness = ScannerHarness(self.module, snapshots)
        rc, out = harness.run()
        self.assertEqual(rc, 0, "continuous churn must converge, not fail closed")
        self.assertEqual(
            harness.scanned,
            {b"1", b"2", b"3", b"4", b"5", b"6", b"7", b"8"},
            "every live pid must be scanned",
        )
        self.assertEqual(out.count(b"\0"), 8, "one record per covered pid")

    def test_child_appearing_late_is_covered_even_if_it_chdirs(self) -> None:
        """A pid absent from the first snapshot must still be scanned for real.

        This is the exact hazard behind 'inherit cwd' reasoning: the child can
        chdir() immediately, so it has to be read, not assumed.
        """
        snapshots = [[b"1"], [b"1", b"2"]]

        def records_for(pid):
            # pid 2 moved itself somewhere else the instant it started.
            cwd = b"/tmp/candidate" if pid == b"2" else b"/tmp/work"
            return [pid + b"\t1000\t" + cwd + b"\0"]

        harness = ScannerHarness(self.module, snapshots, records_for)
        rc, out = harness.run()
        self.assertEqual(rc, 0)
        self.assertIn(b"2\t1000\t/tmp/candidate\0", out, "the late child's real cwd must be reported")
        self.assertIn(b"2", {p for p in harness.scanned})

    def test_unreachable_coverage_fails_closed(self) -> None:
        """If coverage can never be established, the helper must NOT claim success."""
        # Every pass introduces a brand-new pid: no pass ever covers the live set.
        snapshots = [[bytes(str(i), "ascii")] for i in range(1, 400)]
        harness = ScannerHarness(self.module, snapshots)
        rc, out = harness.run()
        self.assertNotEqual(rc, 0, "must fail closed rather than return partial coverage")
        self.assertEqual(out, b"", "a failed scan must emit no records")

    def test_no_processes_is_an_error(self) -> None:
        harness = ScannerHarness(self.module, [[]])
        rc, out = harness.run()
        self.assertNotEqual(rc, 0)
        self.assertEqual(out, b"")

    def test_arguments_are_refused(self) -> None:
        sys.argv = ["diskm-cwd-scan", "--help"]
        harness = ScannerHarness(self.module, [[b"1"]])
        rc, out = harness.run()
        self.assertNotEqual(rc, 0, "the helper takes no arguments")
        self.assertEqual(out, b"")


if __name__ == "__main__":
    unittest.main()
