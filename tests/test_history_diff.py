#!/usr/bin/env python3
"""test_history_diff.py — unit + CLI-integration tests for
scripts/history_diff.py (sandboxed: tempfile git repos, no real $HOME)."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "history_diff.py"
sys.path.insert(0, str(REPO / "scripts"))
import history_diff as hd  # noqa: E402

GIB_KB = 1024 * 1024


def ledger(disk_used_kb, residual_kb, buckets, residual_label="test-residual"):
    return {
        "schema_version": 1,
        "captured_at": "2026-07-21T00:00:00Z",
        "hostname": "sandbox-host",
        "disk_used_kb": disk_used_kb,
        "residual_kb": residual_kb,
        "residual_label": residual_label,
        "buckets": buckets,
    }


class TestValidateLedger(unittest.TestCase):
    def test_valid_ledger_passes(self):
        led = ledger(3 * GIB_KB, 1 * GIB_KB, [
            {"path": "/a", "measured_kb": 1 * GIB_KB},
            {"path": "/b", "measured_kb": 1 * GIB_KB},
        ])
        hd.validate_ledger(led, label="valid")  # must not raise

    def test_missing_key_rejected(self):
        led = ledger(1, 1, [])
        del led["residual_kb"]
        with self.assertRaises(hd.LedgerError):
            hd.validate_ledger(led, label="missing-key")

    def test_oversize_bucket_rejected(self):
        led = ledger(6 * GIB_KB, 0, [{"path": "/big", "measured_kb": 5 * GIB_KB}])
        with self.assertRaises(hd.LedgerError) as ctx:
            hd.validate_ledger(led, label="oversize")
        self.assertIn("/big", str(ctx.exception))

    def test_reconciliation_mismatch_rejected(self):
        led = ledger(10, 1, [{"path": "/a", "measured_kb": 5}])
        with self.assertRaises(hd.LedgerError) as ctx:
            hd.validate_ledger(led, label="unbalanced")
        self.assertIn("reconciliation", str(ctx.exception))

    def test_bucket_missing_measured_kb_rejected(self):
        led = ledger(1, 1, [{"path": "/a"}])
        with self.assertRaises(hd.LedgerError):
            hd.validate_ledger(led, label="null-size")

    def test_oversize_dir_rejected_but_oversize_file_allowed(self):
        # A >=5 GiB directory aggregate without child breakdown is an
        # unexplained opaque node (refused). A >=5 GiB single FILE is a leaf
        # by construction — it can't be broken down further, mirroring
        # scripts/disk_frontier_scan.py's oversize_indivisible_files, which
        # is tracked outside the <=5 GiB granularity_buckets ceiling.
        oversize_dir = ledger(6 * GIB_KB, 0, [{"path": "/big_dir", "measured_kb": 6 * GIB_KB, "kind": "dir"}])
        with self.assertRaises(hd.LedgerError):
            hd.validate_ledger(oversize_dir, label="oversize-dir")
        oversize_file = ledger(6 * GIB_KB, 0, [{"path": "/big.img", "measured_kb": 6 * GIB_KB, "kind": "file"}])
        hd.validate_ledger(oversize_file, label="oversize-file")  # must not raise


class TestComputeDeltas(unittest.TestCase):
    def test_growth_sorted_first_shrink_last(self):
        base = ledger(4 * GIB_KB, 1 * GIB_KB, [
            {"path": "/grew", "measured_kb": 1 * GIB_KB},
            {"path": "/shrank", "measured_kb": 2 * GIB_KB},
        ])
        target = ledger(4 * GIB_KB, 1 * GIB_KB, [
            {"path": "/grew", "measured_kb": 3 * GIB_KB},
            {"path": "/shrank", "measured_kb": 0},
        ])
        deltas, residual_delta = hd.compute_deltas(base, target)
        self.assertEqual(deltas[0][0], "/grew")
        self.assertGreater(deltas[0][1], 0)
        self.assertEqual(deltas[-1][0], "/shrank")
        self.assertLess(deltas[-1][1], 0)
        self.assertEqual(residual_delta, 0)

    def test_added_and_removed_buckets_diff_against_zero(self):
        base = ledger(1 * GIB_KB, 0, [{"path": "/old", "measured_kb": 1 * GIB_KB}])
        target = ledger(1 * GIB_KB, 0, [{"path": "/new", "measured_kb": 1 * GIB_KB}])
        deltas, _ = hd.compute_deltas(base, target)
        by_path = dict(deltas)
        self.assertEqual(by_path["/new"], 1 * GIB_KB)
        self.assertEqual(by_path["/old"], -1 * GIB_KB)

    def test_residual_delta_sign(self):
        base = ledger(2 * GIB_KB, 1 * GIB_KB, [])
        target = ledger(2 * GIB_KB, 2 * GIB_KB, [])
        _, residual_delta = hd.compute_deltas(base, target)
        self.assertEqual(residual_delta, 1 * GIB_KB)


class TestFormatDiff(unittest.TestCase):
    def test_top_line_is_largest_growth_last_line_is_residual(self):
        deltas = [("/grew", 6 * GIB_KB), ("/flat", 0), ("/shrank", -1 * GIB_KB)]
        out = hd.format_diff(deltas, 0)
        lines = out.splitlines()
        self.assertIn("/grew", lines[0])
        self.assertTrue(lines[0].startswith("+"))
        self.assertEqual(lines[-1], "residual delta: +0.00 GiB")
        # zero-delta buckets are noise in a diff view — omitted, not printed as +0.00.
        self.assertFalse(any("/flat" in l for l in lines))


if __name__ == "__main__":
    unittest.main()
