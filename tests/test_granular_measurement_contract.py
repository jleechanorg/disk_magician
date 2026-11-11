import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import disk_frontier_scan as f
import render_topdown_ledger as r

class GranularMeasurementContract(unittest.TestCase):
    def test_default_and_invalid_ceiling(self):
        self.assertEqual(f.parse_args([]).granularity_gib, 100 / 1024)
        for ceiling in ('0', '5', '-1', 'nan', 'inf'):
            with self.subTest(ceiling=ceiling), self.assertRaises(SystemExit):
                f.parse_args(['--granularity-gib', ceiling])

    def test_exact_boundary_descends(self):
        with tempfile.TemporaryDirectory() as d:
            child = pathlib.Path(d, 'child'); child.mkdir()
            (child / 'file').write_text('a')
            scanner = f.FrontierScanner(f.parse_args(['--root', d]))
            scanner.start_time = time.time()
            scanner.granularity_kb = 100 * 1024
            with mock.patch.object(scanner, 'measure_one', return_value=100 * 1024):
                result = scanner.process_node(str(child), 1, False)
            self.assertTrue(result)
            self.assertNotIn(str(child), scanner.measured)

    def test_inventory_never_synthesizes_direct_leaves(self):
        with tempfile.TemporaryDirectory() as d:
            child = pathlib.Path(d, 'child'); child.mkdir()
            scanner = f.FrontierScanner(f.parse_args(['--root', d]))
            scanner.granularity_kb = 100 * 1024
            scanner._apply_inventory_partition({str(child): 200 * 1024}, [], [str(child)])
            self.assertFalse(any(b.get('kind') == 'direct_allocation_segment' for b in scanner.inventory_buckets))
            self.assertTrue(scanner.frontier_unfinished)

    def test_real_gnu_inventory_accounts_directory_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            child = pathlib.Path(d, 'child'); child.mkdir()
            payload = child/'payload'
            with payload.open('wb') as out:
                for _ in range(100): out.write(b'x' * (1024 * 1024))
            du = shutil.which("gdu") or shutil.which("du")
            version = subprocess.run([du, "--version"], capture_output=True, text=True)
            if version.returncode or "GNU coreutils" not in version.stdout:
                self.skipTest("GNU du unavailable")
            result = subprocess.run([du, '-a', '-k', '--null', str(child)], capture_output=True, check=True)
            records = {os.fsdecode(row.split(b'\t', 1)[1]): int(row.split(b'\t', 1)[0])
                       for row in result.stdout.split(b'\0') if row}
            scanner = f.FrontierScanner(f.parse_args(['--root', d]))
            scanner._apply_inventory_partition(records, [], [str(child)])
            self.assertFalse(scanner.frontier_unfinished)
            self.assertEqual(scanner.directory_metadata[str(child)],
                             (child.stat().st_blocks * 512 + 1023)//1024)
            self.assertFalse(any(b.get('kind') == 'direct_allocation_segment' for b in scanner.inventory_buckets))

    def test_directory_metadata_counts_toward_rollup_ceiling(self):
        buckets = f.build_granularity_buckets({'/fixture/dir/file': 102396},
                    '/fixture', 102400, {'/fixture/dir': 4})
        self.assertEqual([b['path'] for b in buckets], ['/fixture/dir/file'])

    def test_history_never_certifies_partial_or_oversize_directory(self):
        import copy
        import history_diff as history
        from test_history_diff import ledger
        valid = ledger(204800, 0, [{'path': '/fixture/file', 'kind': 'file', 'measured_kb': 204800}])
        history.validate_full_attribution_ledger(valid, label='valid-file')
        cases = []
        partial = copy.deepcopy(valid); partial['canonical'] = False; cases.append(partial)
        directory = copy.deepcopy(valid); directory['buckets'][0]['kind'] = 'dir'; cases.append(directory)
        for reason in ('permission_denied_intrinsic', 'vanished_during_scan', 'cross_device_boundary'):
            case = copy.deepcopy(valid)
            case['opaque_intrinsic_gates'] = [{'path': '/fixture/missing', 'reason': reason,
                'verification': 'attested', 'reclaimable': False}]
            cases.append(case)
        for case in cases:
            with self.subTest(case=case), self.assertRaises(history.LedgerError):
                history.validate_full_attribution_ledger(case, label='incomplete')

    def test_history_checks_apparent_directory_ceiling_and_preserves_file_metrics(self):
        import history_diff as history
        from test_history_diff import ledger
        row = {"path": "/fixture/sparse", "kind": "dir", "measured_kb": 4,
               "apparent_bytes": 200 * 1024 ** 2}
        directory = ledger(4, 0, [row])
        with self.assertRaises(history.LedgerError):
            history.validate_full_attribution_ledger(directory, label="sparse-directory")
        row["kind"] = "file"
        history.validate_full_attribution_ledger(directory, label="sparse-file")
        directory["file_leaves"] = [{"path": row["path"], "apparent_bytes": row["apparent_bytes"],
                                     "allocated_kb": 4}]
        rendered = r.build_ledger_dict(directory, "2026-11-11T08:00:00Z")
        self.assertEqual(rendered["file_leaves"], directory["file_leaves"])
        self.assertEqual(rendered["granularity_buckets"][0]["apparent_bytes"], 200 * 1024 ** 2)

    def test_renderer_rejects_synthetic_kind_and_large_ceiling(self):
        self.assertNotIn('direct_allocation_segment', r.BUCKET_KINDS)
        self.assertEqual(r.GRANULARITY_CEILING_KB, 100 * 1024)

    def test_attested_permission_and_identity_failures_remain_unfinished(self):
        from test_frontier_intrinsic_accounting import TestIntrinsicGateAccounting
        fixture = TestIntrinsicGateAccounting()
        scanner = fixture.scanner()
        report = fixture.report(scanner)
        self.assertEqual(report['mode'], 'partial')
        self.assertTrue(report['frontier_unfinished'])
        self.assertFalse(any(g['reason'] in ('permission_denied_intrinsic', 'vanished_during_scan', 'cross_device_boundary')
                             for g in report['opaque_intrinsic_gates']))

    def test_trailing_slash_symlink_root_is_only_a_link_leaf(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d); (root/'target').mkdir()
            (root/'target'/'secret').write_text('not followed')
            os.symlink(root/'target', root/'link')
            result = subprocess.run(['bash', '-c',
                'source scripts/lib/scratch_budget.sh; scratch_budget_measure_files "$1"',
                '_', str(root/'link')+'/'], cwd=ROOT, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('\tL\t', result.stdout)
            self.assertNotIn('secret', result.stdout)

    def test_shared_measurement_caps_dedups_and_reports_boundaries(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            (root/'a').mkdir(); (root/'b').mkdir()
            with open(root/'a'/'file', 'wb') as out: out.truncate(100*1024*1024)
            os.link(root/'a'/'file', root/'b'/'alias')
            command = 'source scripts/lib/scratch_budget.sh; scratch_budget_measure_files "$1" 500'
            result = subprocess.run(['bash', '-c', command, '_', d], cwd=ROOT, text=True, capture_output=True)
            rows = [line.split('\t', 4) for line in result.stdout.splitlines()]
            self.assertEqual(sum(int(row[0]) for row in rows), 100*1024*1024)
            self.assertTrue(any(row[3] == 'F' for row in rows), rows)
            (root/'repo').mkdir(); (root/'repo'/'.git').mkdir()
            os.symlink(root/'a', root/'link')
            result = subprocess.run(['bash', '-c', command, '_', d], cwd=ROOT, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertNotIn('\tG\t', result.stdout)
            self.assertIn('\tL\t', result.stdout)

if __name__ == '__main__': unittest.main()
