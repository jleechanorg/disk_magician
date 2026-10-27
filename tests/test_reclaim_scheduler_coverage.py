#!/usr/bin/env python3
"""Task 6 contracts through an isolated installed console entrypoint.

Canonical root scripts are staged as package data, without rewriting generated
mirrors. Platform commands and the expensive snapshot measurement are fixtures;
the real CLI, dispatcher, orchestrator, receipts and Git publication execute.
"""
import datetime
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SchedulerFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="scheduler-contract-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.home / ".disk_magician_state"
        self.state_repo = self.root / "state-repo"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.package = self.root / "site-packages" / "disk_magician"
        self.package.mkdir(parents=True)
        for filename in ("__init__.py", "cli.py"):
            shutil.copy2(ROOT / "src/disk_magician" / filename, self.package / filename)
        shutil.copy2(ROOT / "disk_magician.sh", self.package / "disk_magician.sh")
        shutil.copytree(ROOT / "scripts", self.package / "scripts")
        shutil.copytree(ROOT / "launchd", self.package / "launchd")
        if (ROOT / "templates").exists():
            shutil.copytree(ROOT / "templates", self.package / "templates")
        for name in ("diskm", "disk-magician"):
            entry = self.bin / name
            entry.write_text(f"#!{sys.executable}\nfrom disk_magician.cli import main\nmain()\n")
            entry.chmod(0o755)
        (self.bin / "python3").symlink_to(sys.executable)
        self.snapshot_marker = self.root / "snapshot-started"
        snapshot = self.bin / "snapshot-fixture"
        snapshot.write_text('''#!/usr/bin/env bash
printf started > "$SNAPSHOT_MARKER"
printf '{"disk_free_gb":100,"schema_version":2}\\n' > "$2"
''')
        snapshot.chmod(0o755)
        config = self.home / ".config/disk-magician/config.json"
        config.parent.mkdir(parents=True)
        config.write_text('{"monitored_dirs":[],"monitored_dir_globs":[]}\n')
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "PATH": str(self.bin) + os.pathsep + "/usr/bin:/bin",
            "PYTHONPATH": str(self.package.parent),
            "DISK_MAGICIAN_STATE_DIR": str(self.state),
            "DISK_MAGICIAN_STATE_REPO": str(self.state_repo),
            "DISK_MAGICIAN_SNAPSHOT_BIN": str(snapshot),
            "DISK_MAGICIAN_OSTYPE": "linux",
            "SNAPSHOT_MARKER": str(self.snapshot_marker),
        }

    def cli(self, *args):
        return subprocess.run([str(self.bin / "diskm"), *args], env=self.env,
                              capture_output=True, text=True, timeout=30)


class SnapshotDispatchTests(SchedulerFixture):
    def test_invalid_stale_age_rejected_before_snapshot_or_state_mutation(self):
        result = self.cli("snapshot", "--refresh-inventory-if-stale=banana")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("invalid", (result.stdout + result.stderr).lower())
        self.assertFalse(self.snapshot_marker.exists())
        self.assertFalse(self.state_repo.exists())


class SnapshotRefreshTests(SchedulerFixture):
    """Run the parent-authored dispatcher with the owned handler and codec fixture.

    The codec is an explicitly authorized callable boundary fixture, not proof of
    real root import/hash validation or deployed scheduled execution.
    """
    def setUp(self):
        super().setUp()
        self.state.mkdir()
        self.fixture_current = self.state / 'fixture-publication.json'
        self.root_publication = self.root / 'root-publication.json'
        self.root_receipt = self.root / 'root-receipt.json'
        self.collector_calls = self.root / 'collector-calls.json'
        self.import_calls = self.root / 'import-calls.json'
        self.env.update(ROOT_PUBLICATION_FIXTURE=str(self.root_publication),
                        ROOT_RECEIPT_FIXTURE=str(self.root_receipt),
                        COLLECTOR_CALLS=str(self.collector_calls), IMPORT_CALLS=str(self.import_calls),
                        COLLECTOR_STATUS='success', COLLECTOR_EXIT='0')
        self.write_publication(self.fixture_current, 'a' * 64, hours=48)
        self.write_publication(self.root_publication, 'b' * 64, hours=0)
        (self.package / 'scripts/directory_inventory.py').write_text(r'''
import json, os
from pathlib import Path

def validate_state_separation(state_dir, git_state_repo):
    state = Path(state_dir).resolve()
    repo = Path(git_state_repo).resolve()
    if state == repo or state in repo.parents or repo in state.parents:
        raise ValueError("inventory state must be separate from Git state repository")

def read_current(state_dir, verify=True):
    assert verify is True
    path = Path(state_dir) / 'fixture-publication.json'
    if str(state_dir) in ('/var/lib/disk-magician', '/var/db/disk-magician'):
        path = Path(os.environ['ROOT_PUBLICATION_FIXTURE'])
    return json.loads(path.read_text())

def import_root_publication(source_root, *, state_dir, now=None, retries=3, trusted_uid=0):
    Path(os.environ['IMPORT_CALLS']).write_text(json.dumps({'source_root': str(source_root), 'retries': retries}))
    if os.environ.get('IMPORT_LOCK'):
        raise BlockingIOError('fixture publication lock contention')
    if os.environ.get('IMPORT_FAIL'):
        raise ValueError('fixture dependency hash mismatch')
    data = Path(os.environ['ROOT_PUBLICATION_FIXTURE']).read_bytes()
    (Path(state_dir) / 'fixture-publication.json').write_bytes(data)
''')
        # Map only the fixed read-only root receipt path at the filesystem edge.
        (self.package.parent / 'sitecustomize.py').write_text(r'''
import io, os
_original_open = io.open

def fixture_open(file, *args, **kwargs):
    if isinstance(file, (str, os.PathLike)) and str(file) in (
        '/var/lib/disk-magician/inventory-root-receipt.json',
        '/var/db/disk-magician/inventory-root-receipt.json'):
        file = os.environ['ROOT_RECEIPT_FIXTURE']
        kwargs.pop('opener', None)
    return _original_open(file, *args, **kwargs)
io.open = fixture_open
''')
        collector = self.bin / 'systemctl'
        collector.write_text('#!' + sys.executable + '\n' + r'''
import json, os, sys
from pathlib import Path
Path(os.environ['COLLECTOR_CALLS']).write_text(json.dumps(sys.argv[1:]))
pub = json.loads(Path(os.environ['ROOT_PUBLICATION_FIXTURE']).read_text())
receipt = {'status': os.environ['COLLECTOR_STATUS'],
           'published_at': pub['manifest']['published_at'],
           'manifest_sha256': pub['pointer']['manifest_sha256'],
           'complete': True, 'unresolved_frontier': [], 'records_count': 1}
Path(os.environ['ROOT_RECEIPT_FIXTURE']).write_text(json.dumps(receipt))
raise SystemExit(int(os.environ['COLLECTOR_EXIT']))
''')
        collector.chmod(0o755)

    def write_publication(self, path, digest, hours=0):
        when = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)).strftime('%Y-%m-%dT%H:%M:%SZ')
        path.write_text(json.dumps({'pointer': {'manifest_sha256': digest},
                                   'manifest': {'published_at': when, 'complete': True},
                                   'records': []}))

    def inventory_receipt(self):
        path = self.state / 'receipts/directory_inventory.json'
        self.assertTrue(path.is_file(), 'independent directory_inventory receipt absent')
        return json.loads(path.read_text())['last_terminal']

    def refresh(self):
        return self.cli('snapshot', '--refresh-inventory-if-stale=24h')

    def test_fresh_skips_root_request_and_records_independent_noop(self):
        self.write_publication(self.fixture_current, 'a' * 64)
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.collector_calls.exists())
        self.assertEqual(self.inventory_receipt()['outcome'], 'success_noop')
        self.assertTrue(self.snapshot_marker.exists())

    def test_stale_requests_fixed_root_unit_and_imports_before_snapshot(self):
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.collector_calls.is_file(), 'stale refresh did not request root collector')
        args = json.loads(self.collector_calls.read_text())
        self.assertEqual(args, ['--system', '--no-ask-password', 'start', 'disk-magician-inventory-root.service'])
        self.assertTrue(self.import_calls.is_file())
        self.assertEqual(self.inventory_receipt()['outcome'], 'success')
        self.assertEqual(json.loads(self.fixture_current.read_text())['pointer']['manifest_sha256'], 'b' * 64)
        snap = json.loads((self.state / 'receipts/snapshot_commit.json').read_text())['last_terminal']
        self.assertLessEqual(self.inventory_receipt()['times']['ended_at'], snap['times']['ended_at'])

    def test_root_failure_preserves_previous_generation_and_aborts_snapshot(self):
        self.env['COLLECTOR_EXIT'] = '1'
        prior = self.fixture_current.read_bytes()
        result = self.refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.snapshot_marker.exists())
        self.assertEqual(self.fixture_current.read_bytes(), prior)
        self.assertIn('privileged_collector_unavailable', self.inventory_receipt()['reason'])

    def test_collector_contention_has_skip_receipt_and_no_snapshot(self):
        self.env['COLLECTOR_STATUS'] = 'skipped_lock'
        prior = self.fixture_current.read_bytes()
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.snapshot_marker.exists())
        self.assertEqual(self.fixture_current.read_bytes(), prior)
        self.assertEqual(self.inventory_receipt()['outcome'], 'skipped_lock')
        self.assertFalse(self.import_calls.exists())

    def test_import_failure_preserves_generation_and_no_publication(self):
        self.env['IMPORT_FAIL'] = '1'
        prior = self.fixture_current.read_bytes()
        result = self.refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.snapshot_marker.exists())
        self.assertEqual(self.fixture_current.read_bytes(), prior)
        self.assertEqual(self.inventory_receipt()['outcome'], 'error')

    def test_user_publication_contention_is_a_skip_not_failed_collection(self):
        self.env['IMPORT_LOCK'] = '1'
        prior = self.fixture_current.read_bytes()
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.snapshot_marker.exists())
        self.assertEqual(self.fixture_current.read_bytes(), prior)
        self.assertEqual(self.inventory_receipt()['outcome'], 'skipped_lock')

    def test_snapshot_lock_skip_has_both_independent_receipts(self):
        lock = self.state / 'snapshot.lock'
        lock.mkdir()
        (lock / 'pid').write_text(str(os.getpid()))
        result = self.refresh()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.collector_calls.exists())
        self.assertFalse(self.snapshot_marker.exists())
        self.assertEqual(self.inventory_receipt()['outcome'], 'skipped_lock')
        self.assertEqual(json.loads((self.state / 'receipts/snapshot_commit.json').read_text())['last_terminal']['outcome'], 'skipped_lock')

    def test_missing_codec_is_explicitly_unavailable_not_unprivileged_scan(self):
        (self.package / 'scripts/directory_inventory.py').unlink()
        result = self.refresh()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.collector_calls.exists())
        self.assertFalse(self.snapshot_marker.exists())
        self.assertIn('unavailable', self.inventory_receipt()['reason'])


class SystemdCoverageTests(SchedulerFixture):
    def setUp(self):
        super().setUp()
        self.calls = self.root / "platform-calls.jsonl"
        self.units_path = self.root / "units.json"
        self.units = {}
        fake = self.bin / "systemctl"
        fake.write_text("#!" + sys.executable + "\n" + r"""
import json, os, sys
args = sys.argv[1:]
with open(os.environ['PLATFORM_CALLS'], 'a') as f:
    f.write(json.dumps(args) + '\n')
namespace = 'user' if '--user' in args else 'system'
if 'list-unit-files' in args:
    print('disk-magician-snapshot.timer enabled' if namespace == 'user' else '')
    raise SystemExit(0)
if 'show' not in args:
    raise SystemExit('Unexpected mutating platform command')
unit = next((arg for arg in args if arg.endswith(('.service', '.timer'))), '')
data = json.load(open(os.environ['UNITS_FIXTURE'])).get(namespace + '/' + unit)
if data is None:
    print('Id=' + unit + '\nLoadState=not-found')
    raise SystemExit(0)
if data == 'unreadable':
    print('Failed to connect to bus: Access denied', file=sys.stderr)
    raise SystemExit(1)
for key, value in data.items():
    print(key + '=' + value)
""")
        fake.chmod(0o755)
        cron = self.bin / "crontab"
        cron.write_text('#!/bin/sh\necho "no crontab for fixture" >&2\nexit 1\n')
        cron.chmod(0o755)
        self.env.update(PLATFORM_CALLS=str(self.calls), UNITS_FIXTURE=str(self.units_path))
        self.snapshot_args = [str(self.home / '.local/bin/diskm'), 'snapshot',
                              '--refresh-inventory-if-stale=24h']
        self.units['user/disk-magician-snapshot.service'] = {
            'Id': 'disk-magician-snapshot.service', 'LoadState': 'loaded',
            'ActiveState': 'inactive', 'UnitFileState': 'static',
            'FragmentPath': str(self.home / '.config/systemd/user/disk-magician-snapshot.service'),
            'ExecStart': '{ path=' + self.snapshot_args[0] + ' ; argv[]=' + ' '.join(self.snapshot_args) + ' ; ignore_errors=no ; }',
            'Result': 'success', 'ExecMainStatus': '0', 'User': '', 'Group': '',
        }
        self.units['user/disk-magician-snapshot.timer'] = {
            'Id': 'disk-magician-snapshot.timer', 'LoadState': 'loaded',
            'ActiveState': 'active', 'UnitFileState': 'enabled',
            'Triggers': 'disk-magician-snapshot.service', 'Persistent': 'yes',
            'TimersCalendar': '{ OnCalendar=*-*-* 00/2:15:00 ; next_elapse=Sat 2026-10-24 22:15:00 UTC ; }',
        }
        self.units_path.write_text(json.dumps(self.units))
        # Use the production receipt format for independent observed evidence.
        sys.path.insert(0, str(ROOT / 'scripts'))
        from job_receipt import JobReceiptStore
        store = JobReceiptStore(str(self.state))
        for job in ('snapshot_commit', 'directory_inventory'):
            run = store.begin(job, trigger='scheduled')
            store.finish(job, run, 'success', postcondition={'manifest_hash': 'a' * 64})

    def fleet(self):
        self.units_path.write_text(json.dumps(self.units))
        result = self.cli('check-launchd-fleet', '--fleet-only', '--json')
        self.assertIn(result.returncode, (0, 1, 2), result.stderr)
        return json.loads(result.stdout)

    def snapshot_record(self, data):
        records = [r for r in data['records'] if r.get('label') == 'disk-magician-snapshot.service'
                   and r.get('namespace') == 'user']
        self.assertEqual(len(records), 1, [(r.get("label"), r.get("reason")) for r in data["records"]])
        return records[0]

    def test_linux_effective_snapshot_argv_and_independent_receipts(self):
        record = self.snapshot_record(self.fleet())
        self.assertEqual(record['program_arguments'], self.snapshot_args)
        self.assertEqual(record['registration'], 'registered')
        self.assertEqual(record['loading'], 'loaded')
        self.assertEqual(record['effective_schedule'], 'scheduled')
        self.assertEqual(record['freshness'], 'fresh')
        self.assertEqual(record['inventory_freshness'], 'fresh')
        self.assertEqual(record['schedule']['Persistent'], True)
        self.assertEqual(record['schedule']['OnCalendar'], '*-*-* 00/2:15:00')
        self.assertTrue(record['effective_coverage'])
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertTrue(any('--system' in args for args in calls))
        self.assertTrue(all('show' in args or 'list-unit-files' in args for args in calls))

    def test_same_label_wrong_argv_never_proves_coverage(self):
        self.units['user/disk-magician-snapshot.service']['ExecStart'] = '{ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no ; }'
        record = self.snapshot_record(self.fleet())
        self.assertFalse(record['effective_coverage'])
        self.assertEqual(record['effective_schedule'], 'uncovered')
        self.assertEqual(record['status'], 'degraded')

    def test_status_reads_linux_fleet_instead_of_claiming_not_applicable(self):
        result = self.cli('status', '--json')
        data = json.loads(result.stdout)
        record = self.snapshot_record(data['dimensions']['fleet'])
        self.assertEqual(record['program_arguments'], self.snapshot_args)
        self.assertNotEqual(data['dimensions']['fleet']['reason'], 'launchd_not_applicable_on_platform')

    def test_disabled_timer_and_same_name_system_unit_do_not_cover_user_job(self):
        self.units['system/disk-magician-snapshot.service'] = self.units['user/disk-magician-snapshot.service']
        self.units['user/disk-magician-snapshot.timer']['UnitFileState'] = 'disabled'
        record = self.snapshot_record(self.fleet())
        self.assertEqual(record['effective_schedule'], 'disabled')
        self.assertFalse(record['effective_coverage'])

    def test_failed_receipt_does_not_inherit_older_success(self):
        from job_receipt import JobReceiptStore
        store = JobReceiptStore(str(self.state))
        run = store.begin('snapshot_commit')
        store.finish('snapshot_commit', run, 'error')
        record = self.snapshot_record(self.fleet())
        self.assertEqual(record['run_result'], 'error')
        self.assertEqual(record['effective_schedule'], 'failed')
        self.assertFalse(record['effective_coverage'])

    def test_unreadable_evidence_is_unknown_not_manual_only(self):
        self.units['user/disk-magician-snapshot.service'] = 'unreadable'
        record = self.snapshot_record(self.fleet())
        self.assertEqual(record['registration'], 'unknown')
        self.assertEqual(record['effective_schedule'], 'unknown')
        self.assertFalse(record['effective_coverage'])

    def test_verified_absence_is_manual_only(self):
        del self.units['user/disk-magician-snapshot.service']
        record = self.snapshot_record(self.fleet())
        self.assertEqual(record['registration'], 'absent')
        self.assertEqual(record['effective_schedule'], 'manual_only')

    def test_wrapper_or_changed_scope_is_not_equivalent_to_expected_argv(self):
        for args in (["/bin/sh", "-c", ' '.join(self.snapshot_args)],
                     self.snapshot_args + ["--root=/tmp"]):
            with self.subTest(args=args):
                self.units['user/disk-magician-snapshot.service']['ExecStart'] = '{ path=' + args[0] + ' ; argv[]=' + ' '.join(args) + ' ; ignore_errors=no ; }'
                record = self.snapshot_record(self.fleet())
                self.assertFalse(record['effective_coverage'])
                self.assertEqual(record['effective_schedule'], 'uncovered')

    def test_plain_fleet_check_inspects_linux_not_successful_skip(self):
        result = self.cli('check-launchd-fleet', '--fleet-only')
        self.assertNotIn('check skipped', result.stdout)
        self.assertIn('disk-magician-snapshot.service', result.stdout)

    def test_stale_success_is_not_effective_scheduled_coverage(self):
        path = self.state / 'receipts/snapshot_commit.json'
        data = json.loads(path.read_text())
        old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=2)).strftime('%Y-%m-%dT%H:%M:%SZ')
        for record in [data['last_success'], data['last_terminal'], *data['completed']]:
            record['times']['started_at'] = old
            record['times']['ended_at'] = old
            record['times']['duration_seconds'] = 0
        path.write_text(json.dumps(data))
        record = self.snapshot_record(self.fleet())
        self.assertEqual(record['freshness'], 'stale')
        self.assertEqual(record['effective_schedule'], 'stale')
        self.assertFalse(record['effective_coverage'])

    def test_cron_command_not_label_determines_coverage(self):
        cron = self.bin / 'crontab'
        cron.write_text('#!/bin/sh\nprintf "*/30 * * * * /bin/true # diskm snapshot\\n"\n')
        cron.chmod(0o755)
        records = [r for r in self.fleet()['records'] if r.get('scheduler') == 'cron']
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['namespace'], 'user')
        self.assertFalse(records[0]['effective_coverage'])
        self.assertEqual(records[0]['effective_schedule'], 'uncovered')

    def test_cron_inspection_error_stays_unknown(self):
        cron = self.bin / 'crontab'
        cron.write_text('#!/bin/sh\necho "permission denied" >&2\nexit 1\n')
        cron.chmod(0o755)
        records = [r for r in self.fleet()['records'] if r.get('scheduler') == 'cron']
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['registration'], 'unknown')
        self.assertEqual(records[0]['effective_schedule'], 'unknown')


class LaunchdCoverageTests(SchedulerFixture):
    def setUp(self):
        super().setUp()
        self.agents = self.root / 'agents'
        self.daemons = self.root / 'daemons'
        self.agents.mkdir(); self.daemons.mkdir()
        sys.path.insert(0, str(ROOT / 'scripts'))
        import job_inventory
        records, _ = job_inventory.catalog(self.package)
        for record in records:
            args = [arg.replace(str(Path.home()), str(self.home)) for arg in job_inventory._materialize_args(record['args'], self.package)]
            payload = {'Label': record['label'], 'ProgramArguments': args,
                       **(record['schedule'] or {})}
            if record['domain'] == 'system':
                payload['UserName'] = 'root'
            target = self.daemons if record['domain'] == 'system' else self.agents
            (target / (record['label'] + '.plist')).write_bytes(plistlib.dumps(payload))
        launchctl = self.bin / 'launchctl'
        launchctl.write_text(r'''#!/bin/sh
case "$1" in
print) printf '%s = {\n' "$2" ;;
print-disabled) printf 'disabled services = {\n"com.jleechanorg.disk-magician" => true\n}\n' ;;
*) exit 2 ;;
esac
''')
        launchctl.chmod(0o755)
        self.env.update(DISK_MAGICIAN_OSTYPE='darwin',
                        DISK_MAGICIAN_LAUNCHAGENTS_DIR=str(self.agents),
                        DISK_MAGICIAN_LAUNCHDAEMONS_DIR=str(self.daemons))

    def snapshot_record(self):
        result = self.cli('check-launchd-fleet', '--fleet-only', '--json')
        return next(r for r in json.loads(result.stdout)['records']
                    if r['label'] == 'com.jleechanorg.disk-magician')

    def test_loaded_but_disabled_launchd_job_does_not_prove_effective_coverage(self):
        record = self.snapshot_record()
        self.assertEqual(record.get('registration'), 'registered')
        self.assertEqual(record.get('loading'), 'loaded')
        self.assertEqual(record.get('effective_schedule'), 'disabled')
        self.assertFalse(record['effective_coverage'])

    def test_wrong_launchd_executable_is_not_covered_by_matching_label(self):
        path = self.agents / 'com.jleechanorg.disk-magician.plist'
        payload = plistlib.loads(path.read_bytes())
        payload['ProgramArguments'] = ['/bin/true']
        path.write_bytes(plistlib.dumps(payload))
        record = self.snapshot_record()
        self.assertFalse(record.get('effective_coverage', True))
        self.assertEqual(record['coverage_owner'], 'unknown')

    def test_partial_ok_line_never_promotes_stale_canonical_publication(self):
        try:
            from tests.test_disk_status import make_valid_partial_ledger
        except ImportError:
            from test_disk_status import make_valid_partial_ledger
        ledger = self.state_repo / 'ledger'
        ledger.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(self.state_repo)], check=True,
                       capture_output=True, env=self.env)
        partial = make_valid_partial_ledger(captured_at=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
        partial['granularity_buckets'] = [{'path': '/fixture', 'measured_kb': 100}]
        partial['residual_kb'] = 100
        partial['accounting_equation'].update(displayed_buckets_kb=100, residual_kb=100)
        (ledger / 'topdown-5g.partial.json').write_text(json.dumps(partial))
        # Platform boundary fixtures, not a substituted ledger/status helper.
        labels = [p.stem for p in self.agents.glob('*.plist')]
        listing = self.root / 'loaded-labels'
        listing.write_text(''.join('1 0 ' + label + '\n' for label in labels))
        launchctl = self.bin / 'launchctl'
        launchctl.write_text('#!/bin/sh\nif [ "$1" = list ]; then cat "' + str(listing) + '"; fi\nexit 0\n')
        launchctl.chmod(0o755)
        plutil = self.bin / 'plutil'
        plutil.write_text('#!' + sys.executable + '\n' + r'''
import json, plistlib, sys
try:
    data = plistlib.load(open(sys.argv[-1], 'rb'))
    if '-extract' in sys.argv:
        if not isinstance(data, dict) or 'Label' not in data: raise ValueError('Label')
        print(data['Label'])
    elif '-convert' in sys.argv:
        print(json.dumps(data))
except Exception:
    raise SystemExit(1)
''')
        plutil.chmod(0o755)
        freshness = self.cli('ledger-freshness')
        self.assertTrue(freshness.stdout.startswith('OK'), freshness.stdout + freshness.stderr)
        self.assertIn('canonical_publication=stale', freshness.stdout)
        result = self.cli('check-launchd-fleet')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('canonical publication stale', result.stdout.lower())


class SnapshotTimerInstallerTests(SchedulerFixture):
    def test_stage_exact_existing_timer_without_activation(self):
        target = self.root / 'staged-user-units'
        result = subprocess.run(['bash', str(self.package / 'scripts/install_snapshot_timer.sh'),
                                 '--stage-dir', str(target)], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        service = target / 'disk-magician-snapshot.service'
        timer = target / 'disk-magician-snapshot.timer'
        self.assertTrue(service.is_file(), 'existing named snapshot service was not staged')
        self.assertTrue(timer.is_file(), 'existing named snapshot timer was not staged')
        self.assertIn('ExecStart=%h/.local/bin/diskm snapshot --refresh-inventory-if-stale=24h', service.read_text())
        self.assertIn('OnCalendar=*-*-* 00/2:15:00', timer.read_text())
        self.assertIn('Persistent=true', timer.read_text())
        self.assertEqual([p.name for p in target.glob('*.timer')], ['disk-magician-snapshot.timer'])
        receipt = json.loads((target / 'disk-magician-snapshot.install.json').read_text())
        self.assertFalse(receipt['activated'])
        self.assertEqual(receipt['files']['disk-magician-snapshot.service']['uid'], os.getuid())
        self.assertEqual(receipt['files']['disk-magician-snapshot.service']['mode'], '0644')
        self.assertFalse((self.home / '.config/systemd/user').exists())


if __name__ == "__main__":
    unittest.main()
