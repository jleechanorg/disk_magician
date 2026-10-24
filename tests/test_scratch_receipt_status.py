"""Fixture-only scheduler status contract, with no cleanup or live disk probes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ScratchReceiptStatus(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.scripts = self.root / 'scripts'
        (self.scripts / 'lib').mkdir(parents=True)
        for name in ('tmp_scratch_sweep.sh', 'lib/actuator_deadline.sh', 'lib/actuator_receipt.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.scripts / name)
        self.env = dict(os.environ, PATH=f'{self.scripts}:{os.environ["PATH"]}',
                        CAPTURE=str(self.root / 'receipt.json'))
        self.write('df', '#!/bin/bash\n[[ ${BAD_DF:-0} == 1 ]] && exit 1\nprintf "Filesystem blocks used available capacity mount\\nfixture 100 10 90 10%% /\\n"\n')
        self.write('cleanup_tmp.sh', '#!/bin/bash\nexit "${CHILD_RC:-0}"\n')
        self.write('cleanup_claude_state.sh', '#!/bin/bash\nexit "${STATE_RC:-0}"\n')
        self.write('job_receipt.py', '''import json, os, sys
args=sys.argv[1:]
if args[0]=='begin': print('run')
elif args[0]=='read':
    marker=os.environ['CAPTURE']+'.read'
    first=not os.path.exists(marker)
    open(marker,'w').close()
    if first or os.environ.get('MISSING_METRICS')=='1': print('{}')
    else: print(json.dumps({'id':'child','trigger':'tmp_scratch_sweep:run', 'candidates':{'removed_count':0,'deferred_count':int(os.environ.get('DEFERRED','0')),'interrupted_count':0},'postcondition':{'df_delta_bytes':0}}))
else:
    data=dict(zip(args[1::2],args[2::2]))
    open(os.environ['CAPTURE'],'w').write(json.dumps(data))
    sys.exit(int(os.environ.get('FINISH_RC','0')))
''')
        self.env['DISK_MAGICIAN_RECEIPT_HELPER'] = str(self.scripts / 'job_receipt.py')

    def write(self, name, content):
        path = self.scripts / name
        path.write_text(content)
        path.chmod(0o755)
        return path

    def run_wrapper(self, **env):
        Path(self.env['CAPTURE'] + '.read').unlink(missing_ok=True)
        result = subprocess.run(['bash', str(self.scripts / 'tmp_scratch_sweep.sh'), '--dry-run'],
                                env=dict(self.env, **env), capture_output=True, text=True)
        receipt = json.loads(Path(self.env['CAPTURE']).read_text())
        return result.returncode, receipt['--outcome']

    def test_missing_metrics_fails(self):
        self.assertEqual(self.run_wrapper(MISSING_METRICS='1'), (1, 'error'))

    def test_missing_df_fails(self):
        self.assertEqual(self.run_wrapper(BAD_DF='1'), (1, 'error'))

    def test_partial_cannot_downgrade_step_error(self):
        self.assertEqual(self.run_wrapper(STATE_RC='1', DEFERRED='1'), (1, 'error'))

    def test_finish_failure_fails(self):
        self.assertEqual(self.run_wrapper(FINISH_RC='1')[0], 1)

    def test_success_dryrun_and_partial_preserved(self):
        self.assertEqual(self.run_wrapper(), (0, 'success_noop'))
        self.assertEqual(self.run_wrapper(DEFERRED='1'), (0, 'partial'))

    def test_lockskip_preserved(self):
        self.assertEqual(self.run_wrapper(CHILD_RC='75', MISSING_METRICS='1'), (0, 'skipped_lock'))

    def run_adapter_terminal(self, status=0, **env):
        # Execute exact production receipt/trap functions, not the cleanup body.
        source = (ROOT / 'scripts/cleanup_tmp.sh').read_text()
        functions = source[source.index('cleanup_tmp_finish_receipt() {'):source.index('\nscratch_lock_set_traps', source.index('cleanup_tmp_finish_receipt() {'))]
        harness = self.write('terminal.sh', '''#!/bin/bash
set -uo pipefail
RECEIPT_FINISHED=false
RECEIPT_FREE_BEFORE=100
RECEIPT_RUN_ID=run
CANDIDATE_REMOVED_COUNT=0
CANDIDATE_DEFERRED_COUNT=0
CANDIDATE_INTERRUPTED_COUNT=0
DRY_RUN=true
RECEIPT_HELPER="$DISK_MAGICIAN_RECEIPT_HELPER"
log() { echo "$*" >&2; }
cleanup_tmp_df_free_bytes() { [[ ${BAD_DF:-0} == 1 ]] || echo 100; }
''' + functions + '\ntrap "cleanup_tmp_exit_trap 0" EXIT\nexit ' + str(status) + '\n')
        result = subprocess.run(['bash', str(harness)], env=dict(self.env, **env), capture_output=True, text=True)
        receipt = json.loads(Path(self.env['CAPTURE']).read_text())
        return result.returncode, receipt['--outcome']

    def test_adapter_df_failure_reaches_scheduler(self):
        self.assertEqual(self.run_adapter_terminal(BAD_DF='1'), (1, 'error'))

    def test_adapter_finish_failure_reaches_scheduler(self):
        self.assertEqual(self.run_adapter_terminal(FINISH_RC='1')[0], 1)

    def test_adapter_timeout_and_success_preserved(self):
        self.assertEqual(self.run_adapter_terminal(124), (124, 'timeout'))
        self.assertEqual(self.run_adapter_terminal(), (0, 'success_noop'))


if __name__ == '__main__':
    unittest.main()
