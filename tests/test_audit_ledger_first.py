"""Offline CLI ordering and existing-ledger contracts; never scan the host."""
import contextlib
import datetime
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import reclaim_ledger


class AuditLedgerFirst(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.tree = self.root / "tree"
        (self.tree / "scripts/lib").mkdir(parents=True)
        for name in ("disk_magician.sh", "config.json.template"):
            shutil.copy2(ROOT / name, self.tree / name)
        for name in ["disk_diagnostic.sh"] + [p.name for p in (ROOT / "scripts").glob("*.py")]:
            shutil.copy2(ROOT / "scripts" / name, self.tree / "scripts" / name)
        # Real dispatcher/diagnostic/ledger/resolvers; only expensive lanes stubbed.
        (self.tree / "scripts/lib/resolve_snapshot_json.sh").write_text(
            'resolve_snapshot_json() { printf "%s\\n" "$HOME/no-snapshot.json"; }\n')
        (self.tree / "scripts/lib/agent_scratch.sh").write_text(
            'agent_scratch_create() { mkdir -p "$HOME/scratch"; echo "$HOME/scratch"; }\n'
            'agent_scratch_trap_cleanup() { :; }\n')
        for name, text in (("check_launchd_fleet.sh", "echo FLEET_FIRST"),
                           ("disk_history.sh", "echo HISTORY_STUB"),
                           ("disk_audit.sh", "echo QUICK_STUB")):
            p = self.tree / "scripts" / name
            p.write_text("#!/bin/bash\n" + text + "\n")
            p.chmod(0o755)
        (self.tree / "scripts/disk_frontier_scan.py").write_text(
            'import os, pathlib, sys\n'
            'text = pathlib.Path(os.environ["CAPTURE"]).read_text()\n'
            'pathlib.Path(os.environ["PROBE"]).write_text(text)\n'
            'print("SCANNER_STUB")\n'
            'sys.exit(3)\n')
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.home),
                    "XDG_STATE_HOME": str(self.home / "state"),
                    "XDG_CONFIG_HOME": str(self.home / "config"),
                    "CAPTURE": str(self.root / "output"), "PROBE": str(self.root / "probe")}
        self.state = self.home / "state/disk-magician"

    def ledger(self, text=None, state=None):
        p = (state or self.state) / reclaim_ledger.OUT_REL
        p.parent.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
        p.write_text(text if text is not None else f'# Known reclaim directories: fixture\nGenerated {stamp} by `diskm reclaim-ledger` (window 7d).\nLEDGER_SENTINEL\n')
        return p

    def run_audit(self):
        with open(self.env["CAPTURE"], "w") as out:
            result = subprocess.run(["bash", str(self.tree / "disk_magician.sh"), "audit"],
                                    env=self.env, stdout=out, stderr=subprocess.STDOUT, timeout=15)
        text = Path(self.env["CAPTURE"]).read_text()
        self.assertEqual(result.returncode, 1, text)  # intentional scanner failure survives
        return text, Path(self.env["PROBE"]).read_text()

    def test_existing_ledger_printed_before_scanner_and_not_regenerated(self):
        ledger = self.ledger()
        before = (ledger.read_bytes(), ledger.stat().st_mtime_ns)
        out, at_scan = self.run_audit()
        self.assertIn("LEDGER_SENTINEL", at_scan)
        self.assertLess(at_scan.index("FLEET_FIRST"), at_scan.index("LEDGER_SENTINEL"))
        self.assertIn("SCANNER_STUB", out)
        self.assertEqual(before, (ledger.read_bytes(), ledger.stat().st_mtime_ns))
        self.assertEqual(list(self.state.rglob('*')), [self.state / 'reclaim', ledger])

    def test_fleet_failure_survives_successful_scanner(self):
        self.ledger()
        (self.tree / "scripts/check_launchd_fleet.sh").write_text(
            "#!/bin/bash\necho FLEET_FIRST\nexit 7\n")
        scanner = self.tree / "scripts/disk_frontier_scan.py"
        scanner.write_text(scanner.read_text().replace("sys.exit(3)",
            'pathlib.Path(sys.argv[sys.argv.index("--output") + 1]).write_text("{}")\nsys.exit(0)'))
        out, at_scan = self.run_audit()
        self.assertIn("LEDGER_SENTINEL", at_scan)
        self.assertLess(at_scan.index("FLEET_FIRST"), at_scan.index("LEDGER_SENTINEL"))
        self.assertIn("Physical/APFS capacity:", out)
        self.assertIn("HISTORY_STUB", out)
        self.assertIn("QUICK_STUB", out)

    def test_missing_ledger_is_unknown_not_no_growth_and_scan_continues(self):
        out, at_scan = self.run_audit()
        self.assertIn("MISSING", at_scan)
        self.assertIn("not evidence of no growth", at_scan)
        self.assertIn("SCANNER_STUB", out)
        self.assertFalse(self.state.exists())

    def test_unreadable_ledger_continues(self):
        p = self.state / reclaim_ledger.OUT_REL
        p.mkdir(parents=True)  # reliably unreadable as a file, even for root
        out, at_scan = self.run_audit()
        self.assertIn("UNREADABLE", at_scan)
        self.assertIn("SCANNER_STUB", out)

    def test_mac_configured_legacy_root_not_linux_default(self):
        cfg = self.home / 'config/disk-magician/config.json'
        cfg.parent.mkdir(parents=True)
        cfg.write_text('{"state_repo_path":"~/.disk_magician_backup"}')
        p = self.ledger(state=self.home / '.disk_magician_backup')
        _, at_scan = self.run_audit()
        self.assertIn(str(p), at_scan)
        self.assertIn("LEDGER_SENTINEL", at_scan)

    def test_explicit_state_override(self):
        self.env['DISK_MAGICIAN_STATE_REPO'] = str(self.root / 'override')
        p = self.ledger(state=self.root / 'override')
        _, at_scan = self.run_audit()
        self.assertIn(str(p), at_scan)

    def test_stale_generated_time_warns_and_preserves_report(self):
        self.ledger('# Known reclaim directories: fixture\nGenerated 2020-01-01 00:00 UTC by `diskm reclaim-ledger`\nLEDGER_SENTINEL\n')
        _, at_scan = self.run_audit()
        self.assertIn("STALE RECLAIM REPORT", at_scan)
        self.assertIn("LEDGER_SENTINEL", at_scan)

    def test_missing_timestamp_unknown(self):
        self.ledger('LEDGER_SENTINEL\n')
        _, at_scan = self.run_audit()
        self.assertIn("UNKNOWN RECLAIM REPORT AGE", at_scan)
        self.assertIn("LEDGER_SENTINEL", at_scan)

    def test_underlying_stale_banner_preserved(self):
        self.ledger('Generated 2026-10-24 00:00 UTC by `diskm reclaim-ledger`\n> **STALE FULL-DISK LEDGER**: fixture\n')
        _, at_scan = self.run_audit()
        self.assertIn("STALE FULL-DISK LEDGER", at_scan)

    def test_empty_report_explicit(self):
        self.ledger('')
        _, at_scan = self.run_audit()
        self.assertIn('EMPTY reclaim ledger', at_scan)
        self.assertIn('not evidence of no growth', at_scan)

    def test_future_generation_is_unknown_not_fresh(self):
        self.ledger('Generated 2999-01-01 00:00 UTC by `diskm reclaim-ledger`\n')
        _, at_scan = self.run_audit()
        self.assertIn('UNKNOWN RECLAIM REPORT AGE', at_scan)

    def test_invalid_utf8_is_unreadable(self):
        self.ledger().write_bytes(b'\xff')
        _, at_scan = self.run_audit()
        self.assertIn('UNREADABLE reclaim ledger (UnicodeDecodeError)', at_scan)

    def test_fresh_report_has_no_stale_age_warning(self):
        self.ledger()
        _, at_scan = self.run_audit()
        self.assertNotIn('STALE RECLAIM REPORT', at_scan)
        self.assertNotIn('UNKNOWN RECLAIM REPORT AGE', at_scan)

    def test_permission_error_is_explicit_and_no_generation(self):
        out = io.StringIO()
        with patch.object(Path, 'read_text', side_effect=PermissionError('denied')), \
                patch.object(reclaim_ledger, 'render', side_effect=AssertionError('no regeneration')), \
                contextlib.redirect_stdout(out):
            reclaim_ledger.read_existing(self.state)
        self.assertIn('UNREADABLE', out.getvalue())


if __name__ == '__main__':
    unittest.main()
