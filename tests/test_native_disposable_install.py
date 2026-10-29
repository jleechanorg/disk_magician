"""All manager calls are intercepted; no live service activation."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import native_disposable as native
import native_disposable_install as install

@unittest.skipUnless(sys.platform.startswith('linux'),'Linux user units only')
class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='dm-native-install-');self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name);self.root=self.base/'disposable'
        runtime=self.base/'runtime';runtime.mkdir(mode=0o700)
        self.env=mock.patch.dict(os.environ,{'XDG_RUNTIME_DIR':str(runtime),'XDG_CONFIG_HOME':str(self.base/'config'), 'DISK_MAGICIAN_TEST_CONTEXT':'1','DISK_MAGICIAN_TEST_SANDBOX':str(self.base)})
        self.env.start();self.addCleanup(self.env.stop)
        exists=Path.exists
        patch=mock.patch.object(Path,'exists',lambda p:False if str(p)=='/tmp/.git' else exists(p));patch.start();self.addCleanup(patch.stop)
        native.initialize(self.root)
        self.binary=self.base/'diskm';self.binary.write_text('from disk_magician.cli import main\n');self.binary.chmod(0o700)
        self.directory=self.base/'config/systemd/user'
        self.active=False;self.enabled=False;self.calls=[];self.fail=None
        self.real_run=install.subprocess.run
        patch=mock.patch.object(install.subprocess,'run',side_effect=self.manager_run);patch.start();self.addCleanup(patch.stop)

    def manager_run(self,command,**kwargs):
        if command[0]!=install.SYSTEMCTL:return self.real_run(command,**kwargs)
        self.assertEqual(command[:2],['/usr/bin/systemctl','--user'])
        self.assertEqual(kwargs['timeout'],8)
        self.assertEqual(set(kwargs['env']),{'PATH','HOME','LANG','XDG_RUNTIME_DIR','XDG_CONFIG_HOME'})
        args=command[2:];self.calls.append(args)
        if self.fail==args[0]:self.fail=None;return mock.Mock(returncode=1,stdout='',stderr='fixture manager failure')
        out='';rc=0
        if args[0]=='show':
            path=self.directory/args[-1]
            prop=args[1].split('=',1)[1]
            if prop=='FragmentPath':out=str(path) if path.is_file() else ''
            elif prop=='Transient':out='no'
            elif prop=='Unit':out=path.name.replace('.timer','.service')
            elif prop in ('NoNewPrivileges','UMask','KillMode'):out={'NoNewPrivileges':'yes','UMask':'0077','KillMode':'control-group'}[prop]
            elif prop=='Environment':
                import shlex
                if path.is_file():
                    out=' '.join(shlex.quote(value) for line in path.read_text().splitlines() if line.startswith('Environment=') for value in shlex.split(line.split('=',1)[1].replace('%%','%')))
            elif prop=='ExecStart':
                import shlex
                if path.is_file():
                    line=next(line.split('=',1)[1] for line in path.read_text().splitlines() if line.startswith('ExecStart='))
                    argv=shlex.split(line);out='{ path='+argv[0]+' ; argv[]='+' '.join(argv)+' ; ignore_errors=no ; }'
        elif args[0]=='is-active':
            out='active' if args[-1].endswith('.timer') and self.active else 'inactive';rc=0 if out=='active' else 3
        elif args[0]=='is-enabled':out='enabled' if self.enabled else 'disabled';rc=0 if self.enabled else 1
        elif args[0]=='enable':self.enabled=True
        elif args[0]=='disable':self.enabled=False
        elif args[0]=='start':self.active=True
        elif args[0]=='stop':self.active=False
        return mock.Mock(returncode=rc,stdout=out,stderr='')

    def perform(self,execute=True,recover=False,accepted=True):
        return install.install(self.root,self.binary,accepted,execute,native,recover)

    def test_explicit_ack_and_plan_never_touch_manager(self):
        with self.assertRaisesRegex(ValueError,'accept-cooperative'):self.perform(accepted=False)
        self.assertEqual(self.perform(False)['status'],'install-plan-only')
        self.assertEqual(self.calls,[]);self.assertFalse(self.directory.exists())

    def test_install_and_idempotence_exact_units(self):
        result=self.perform();self.assertEqual(result['status'],'installed-enabled')
        self.assertTrue(self.active and self.enabled)
        self.assertEqual(json.loads((self.root/'control/schedule-transaction.json').read_text())['phase'],'installed')
        self.assertEqual(self.perform()['status'],'installed-enabled')
        self.assertEqual(len(list(self.directory.glob('*.timer'))),1)

    def test_each_manager_mutation_failure_rolls_back_absent_units(self):
        for step in ('daemon-reload','enable','start'):
            self.fail=step
            with self.subTest(step=step),self.assertRaisesRegex(ValueError,'rolled back'):self.perform()
            self.assertFalse(self.active or self.enabled)
            self.assertFalse(list(self.directory.glob('*.timer')))
            self.assertFalse(list(self.directory.glob('*.service')))
            self.assertEqual(json.loads((self.root/'control/schedule-transaction.json').read_text())['phase'],'rolled-back')

    def test_existing_drift_is_preserved_without_manager_mutation(self):
        result=self.perform();path=self.directory/(result['unit']+'.service');path.write_text('foreign change')
        self.calls=[]
        with self.assertRaisesRegex(ValueError,'drift'):self.perform()
        self.assertEqual(path.read_text(),'foreign change');self.assertEqual(self.calls,[])

    def test_active_producer_blocks_installation(self):
        with native.gate(self.root,False):
            with self.assertRaises(BlockingIOError):self.perform()
        self.assertEqual(self.calls,[])

    def test_pending_native_attempt_and_unknown_payload_block(self):
        (self.root/'data/unknown').mkdir()
        with self.assertRaises(ValueError):self.perform()
        self.assertEqual(self.calls,[])

    def test_symlink_config_directory_refused(self):
        target=self.base/'target';target.mkdir();(self.base/'config').symlink_to(target,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'manager/config|non-symlink'):self.perform()
        self.assertEqual(self.calls,[])

    def test_interruption_retains_pending_blocks_clean_and_can_recover(self):
        original=install.manager
        def crash(*args,**kwargs):
            if args[0]=='start':raise KeyboardInterrupt('simulated process interruption')
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=crash),self.assertRaises(KeyboardInterrupt):self.perform()
        self.assertTrue(self.enabled)
        with self.assertRaisesRegex(ValueError,'installation'):native.require_idle(self.root)
        self.assertEqual(self.perform(recover=True)['status'],'rolled-back')
        self.assertFalse(self.enabled or self.active)
        native.require_idle(self.root)

    def test_recovery_preserves_foreign_file_replacement(self):
        original=install.manager
        def crash(*args,**kwargs):
            if args[0]=='start':raise KeyboardInterrupt()
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=crash),self.assertRaises(KeyboardInterrupt):self.perform()
        path=next(self.directory.glob('*.service'));content=path.read_text();path.rename(path.with_suffix('.old'));path.write_text(content)
        self.calls=[]
        with self.assertRaisesRegex(ValueError,'identity'):self.perform(recover=True)
        self.assertEqual(path.read_text(),content);self.assertEqual(self.calls,[])

    def test_manager_children_inherit_both_admission_locks(self):
        original=self.manager_run
        def check(command,**kwargs):
            if command[0]==install.SYSTEMCTL:
                self.assertEqual(len(kwargs['pass_fds']),2)
                for fd in kwargs['pass_fds']:self.assertEqual(os.fstat(fd).st_uid,os.getuid())
            return original(command,**kwargs)
        with mock.patch.object(install.subprocess,'run',side_effect=check):self.perform()

    def test_existing_enabled_active_timer_restored_on_failure(self):
        self.perform();self.fail='daemon-reload'
        with self.assertRaisesRegex(ValueError,'rolled back'):self.perform()
        self.assertTrue(self.enabled and self.active)
        self.assertEqual(len(list(self.directory.glob('*.timer'))),1)
        self.assertEqual(len(list(self.directory.glob('*.service'))),1)

    def test_rollback_failure_retains_pending_until_recovery(self):
        original=install.manager
        def fail(*args,**kwargs):
            if args[0] in ('start','disable'):raise ValueError('fixture unavailable manager')
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=fail),self.assertRaisesRegex(ValueError,'recovery required'):self.perform()
        self.assertEqual(native.read_json(self.root/'control/schedule-transaction.json')['phase'],'pending')
        self.assertEqual(self.perform(recover=True)['status'],'rolled-back')

    def test_recovery_rejects_corrupt_traversal_record(self):
        original=install.manager
        def crash(*args,**kwargs):
            if args[0]=='start':raise KeyboardInterrupt()
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=crash),self.assertRaises(KeyboardInterrupt):self.perform()
        path=self.root/'control/schedule-transaction.json';record=native.read_json(path)
        record['desired']['../../sentinel']='preserve';native.atomic_json(path,record);self.calls=[]
        with self.assertRaisesRegex(ValueError,'invalid installation'):self.perform(recover=True)
        self.assertEqual(self.calls,[])

    def test_shared_cli_dispatch_install_plan_and_explicit_gate(self):
        with mock.patch.object(sys,'argv',['diskm']):
            self.assertEqual(native.main(['schedule-install','--root',str(self.root),'--diskm-bin',str(self.binary)]),75)
            self.assertEqual(native.main(['schedule-install','--root',str(self.root),'--diskm-bin',str(self.binary),'--accept-cooperative-producers']),0)
        self.assertEqual(self.calls,[])

    def test_manager_timeout_rolls_back_and_is_not_success(self):
        original=install.manager
        once=[True]
        def timeout(*args,**kwargs):
            if args[0]=='start' and once[0]:
                once[0]=False
                raise install.subprocess.TimeoutExpired('fixture',8)
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=timeout),self.assertRaisesRegex(ValueError,'rolled back'):self.perform()
        self.assertFalse(self.active or self.enabled)

    def test_bad_manager_state_refuses_before_writing_units(self):
        original=install.manager
        def bad(*args,**kwargs):
            if args[0]=='is-enabled':return 'masked'
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=bad),self.assertRaisesRegex(ValueError,'unsupported'):self.perform()
        self.assertFalse(list(self.directory.glob('*.timer')))
        self.assertFalse(any(call[0] in ('enable','start','stop','disable') for call in self.calls))

    def pending_install(self):
        original=install.manager
        def crash(*args,**kwargs):
            if args[0]=='start':raise KeyboardInterrupt()
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=crash),self.assertRaises(KeyboardInterrupt):self.perform()

    def test_recovery_foreign_fragment_refuses_before_any_mutation(self):
        self.pending_install();original=install.manager;self.calls=[]
        def foreign(*args,**kwargs):
            if args[:2]==('show','--property=FragmentPath'):return '/runtime/foreign.timer'
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=foreign),self.assertRaisesRegex(ValueError,'fragment'):self.perform(recover=True)
        self.assertFalse(any(c[0] in ('stop','disable','enable','start','daemon-reload') for c in self.calls))
        self.assertEqual(len(list(self.directory.glob('*.timer'))),1)

    def test_dropins_refuse_before_any_manager_mutation(self):
        original=install.manager;self.calls=[]
        def override(*args,**kwargs):
            if args[:2]==('show','--property=DropInPaths'):return '/runtime/override.conf'
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=override),self.assertRaisesRegex(ValueError,'drop-in'):self.perform()
        self.assertFalse(any(c[0] in ('stop','disable','enable','start','daemon-reload') for c in self.calls))

    def test_outside_sandbox_config_refused_before_creation(self):
        with tempfile.TemporaryDirectory(prefix='dm-other-config-') as other:
            path=Path(other)/'must-not-create'
            with mock.patch.dict(os.environ,{'XDG_CONFIG_HOME':str(path)}),self.assertRaises(Exception):self.perform()
            self.assertFalse(path.exists());self.assertEqual(self.calls,[])

    def test_outside_sandbox_runtime_refused_before_manager_or_unit_write(self):
        with tempfile.TemporaryDirectory(prefix='dm-other-runtime-') as other:
            Path(other).chmod(0o700)
            with mock.patch.dict(os.environ,{'XDG_RUNTIME_DIR':other}),self.assertRaises(Exception):self.perform()
            self.assertEqual(self.calls,[]);self.assertFalse(self.directory.exists())

    def test_effective_timer_association_refuses_foreign_service(self):
        original=install.manager
        def wrong(*args,**kwargs):
            if args[:2]==('show','--property=Unit'):return 'foreign.service'
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=wrong),self.assertRaisesRegex(ValueError,'association'):self.perform()
        self.assertFalse(any(c[0] in ('enable','start') for c in self.calls))

    def test_effective_execstart_refuses_override_even_with_matching_fragment(self):
        original=install.manager
        def wrong(*args,**kwargs):
            if args[:2]==('show','--property=ExecStart'):return '{ path=/bin/false ; argv[]=/bin/false ; ignore_errors=no ; }'
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=wrong),self.assertRaisesRegex(ValueError,'ExecStart'):self.perform()
        self.assertFalse(any(c[0] in ('enable','start') for c in self.calls))

    def test_actual_offline_enable_uses_bound_custom_xdg_config(self):
        import shutil
        if not Path(install.SYSTEMCTL).is_file():self.skipTest('systemctl unavailable')
        rendered=native.render_schedule(self.root,self.binary)
        self.directory.mkdir(parents=True,mode=0o700)
        for suffix in ('service','timer'):
            (self.directory/(rendered['unit']+'.'+suffix)).write_text(rendered[suffix])
        env=install.manager_environment()
        # This real command only edits fixture enablement symlinks. --no-reload
        # prohibits a manager reload; fake runtime contains no bus socket.
        self.assertFalse((Path(env['XDG_RUNTIME_DIR'])/'bus').exists())
        command=[install.SYSTEMCTL,'--user','--no-reload','enable',rendered['unit']+'.timer']
        red_env=dict(env);red_env.pop('XDG_CONFIG_HOME')
        red_env['HOME']=str(self.base/'empty-home');Path(red_env['HOME']).mkdir(mode=0o700)
        red=self.real_run(command,env=red_env,text=True,capture_output=True,timeout=8)
        self.assertNotEqual(red.returncode,0,'missing config environment must reproduce unit lookup failure')
        env['HOME']=red_env['HOME']
        green=self.real_run(command,env=env,text=True,capture_output=True,timeout=8)
        self.assertEqual(green.returncode,0,green.stderr)
        link=self.directory/'timers.target.wants'/(rendered['unit']+'.timer')
        self.assertTrue(link.is_symlink());self.assertEqual(link.resolve(),self.directory/(rendered['unit']+'.timer'))
        self.assertFalse((Path(env['XDG_RUNTIME_DIR'])/'bus').exists())

    def test_installer_refuses_unsupported_spaced_launcher_before_mutation(self):
        binary=self.base/'diskm spaced';binary.write_text(self.binary.read_text());binary.chmod(0o700)
        with self.assertRaisesRegex(ValueError,'simple launcher'):
            install.install(self.root,binary,True,True,native)
        self.assertEqual(self.calls,[]);self.assertFalse(self.directory.exists())

    def test_dropin_appearing_after_reload_blocks_activation_and_rollback_mutation(self):
        original=install.manager;reloaded=[False]
        def race(*args,**kwargs):
            if args[:2]==('show','--property=DropInPaths') and reloaded[0]:return '/runtime/new-override.conf'
            result=original(*args,**kwargs)
            if args[0]=='daemon-reload':reloaded[0]=True
            return result
        with mock.patch.object(install,'manager',side_effect=race),self.assertRaisesRegex(ValueError,'drop-in'):self.perform()
        self.assertTrue(reloaded[0]);self.assertFalse(any(c[0] in ('enable','start','stop','disable') for c in self.calls))
        self.assertEqual(len(list(self.directory.glob('*.timer'))),1)
        self.assertEqual(native.read_json(self.root/'control/schedule-transaction.json')['phase'],'pending')

    def test_expired_manager_deadline_never_calls_manager(self):
        with self.assertRaisesRegex(ValueError,'deadline'):
            install.manager('daemon-reload',deadline=install.time.monotonic()-1)
        self.assertEqual(self.calls,[])

    def test_rollback_preserves_same_inode_edit_during_stop(self):
        original=install.manager;edited=[]
        def mutate(*args,**kwargs):
            if args[0]=='start':
                original(*args,**kwargs)  # Manager activated before reporting failure.
                raise ValueError('fixture activation failed after start')
            result=original(*args,**kwargs)
            if args[0]=='stop':
                path=next(self.directory.glob('*.service'));ino=path.stat().st_ino
                path.write_text(path.read_text()+'# operator in-place edit\n')
                edited.append((path,ino))
            return result
        with mock.patch.object(install,'manager',side_effect=mutate),self.assertRaises(ValueError):self.perform()
        self.assertTrue(edited)
        path,ino=edited[0]
        self.assertTrue(path.exists(),'in-place operator edit must not be unlinked')
        self.assertEqual(path.stat().st_ino,ino);self.assertIn('operator in-place edit',path.read_text())
        self.assertEqual(native.read_json(self.root/'control/schedule-transaction.json')['phase'],'pending')

    def test_policy_environment_edit_at_reload_blocks_activation(self):
        original=install.manager;changed=[]
        def mutate(*args,**kwargs):
            if args[0]=='daemon-reload' and not changed:
                path=next(self.directory.glob('*.service'));ino=path.stat().st_ino
                text=path.read_text().replace('DISK_MAGICIAN_SAFETY_FILE=', 'UNBOUND_SAFETY_FILE=')
                path.write_text(text);changed.append((path,ino))
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=mutate),self.assertRaises(ValueError):self.perform()
        self.assertFalse(any(c[0] in ('enable','start') for c in self.calls))
        path,ino=changed[0];self.assertEqual(path.stat().st_ino,ino)
        self.assertIn('UNBOUND_SAFETY_FILE=',path.read_text())
        self.assertEqual(native.read_json(self.root/'control/schedule-transaction.json')['phase'],'pending')

    def test_effective_environment_and_security_properties_must_match(self):
        original=install.manager
        for prop,value in (('Environment','HOME=/foreign'),('EnvironmentFiles','/foreign.env'),('NoNewPrivileges','no'),('UMask','0022'),('KillMode','process')):
            def wrong(*args,**kwargs):
                if args[:2]==('show','--property='+prop):return value
                return original(*args,**kwargs)
            with self.subTest(prop=prop),mock.patch.object(install,'manager',side_effect=wrong),self.assertRaisesRegex(ValueError,'Environment|security'):
                self.perform()
            self.assertFalse(any(c[0] in ('enable','start') for c in self.calls))
            # The refused newly-created source is preserved; repair requires an
            # explicit recovery after the offending effective property clears.
            if (self.root/'control/schedule-transaction.json').exists():self.perform(recover=True)
            self.calls=[]

    def test_post_rename_fsync_failure_and_failed_rollback_retains_admission_block(self):
        original_fsync=native.os.fsync;original_manager=install.manager;fired=[]
        def fail_fsync(fd):
            journal=self.root/'control/schedule-transaction.json'
            if not fired and Path('/proc/self/fd/'+str(fd)).resolve()==self.root/'control' and journal.exists() and json.loads(journal.read_text()).get('phase')=='installed':
                fired.append(True);raise OSError('actual post-rename directory fsync failure')
            return original_fsync(fd)
        def fail_stop(*args,**kwargs):
            if args[0]=='stop':raise ValueError('fixture rollback stop unavailable')
            return original_manager(*args,**kwargs)
        with mock.patch.object(native.os,'fsync',side_effect=fail_fsync),mock.patch.object(install,'manager',side_effect=fail_stop),self.assertRaises(ValueError):self.perform()
        self.assertTrue(fired);self.assertTrue(self.active)
        with self.assertRaisesRegex(ValueError,'installation'):native.require_idle(self.root)
        self.assertEqual(self.perform(recover=True)['status'],'rolled-back')
        self.assertFalse(self.active or self.enabled);native.require_idle(self.root)

    def test_audit_failure_before_units_recovers_without_stopping_absent_timer(self):
        original_audit=native.audit;original_run=self.manager_run
        def audit(root,event):
            if event['event']=='schedule-install-intent':raise OSError('fixture audit ENOSPC')
            return original_audit(root,event)
        with mock.patch.object(native,'audit',side_effect=audit),self.assertRaises(OSError):self.perform()
        def real_absence(command,**kwargs):
            if command[0]==install.SYSTEMCTL and command[2] in ('stop','disable') and not list(self.directory.glob('*.timer')):
                self.calls.append(command[2:]);return mock.Mock(returncode=5,stdout='',stderr='Unit not loaded')
            return original_run(command,**kwargs)
        with mock.patch.object(install.subprocess,'run',side_effect=real_absence):
            self.assertEqual(self.perform(recover=True)['status'],'rolled-back')
        native.require_idle(self.root)
        self.assertFalse(any(c[0] in ('stop','disable') for c in self.calls))

    def test_terminal_marker_post_rename_fsync_failure_has_durable_commit_and_verifiable_finalization(self):
        original=native.os.fsync;fired=[]
        def fail(fd):
            marker=self.root/'control/schedule-admission.json'
            if not fired and Path('/proc/self/fd/'+str(fd)).resolve()==self.root/'control' and marker.exists() and json.loads(marker.read_text()).get('phase')=='installed':
                fired.append(True);raise OSError('final marker post-rename fsync')
            return original(fd)
        with mock.patch.object(native.os,'fsync',side_effect=fail):result=self.perform()
        self.assertTrue(fired);self.assertEqual(result['status'],'incomplete');self.assertTrue(result['committed'])
        # A visible terminal marker is written only AFTER terminal journal fsync.
        # It proves a prior durable commit, unlike the ambiguous journal case.
        native.require_idle(self.root);self.calls=[]
        self.assertEqual(self.perform(recover=True)['status'],'finalization-verified')
        self.assertFalse(any(c[0] in ('stop','disable','start','enable') for c in self.calls))

    def test_terminal_marker_failure_before_write_retains_block_and_recovers(self):
        original=native.atomic_json
        def fail(path,value):
            if path.name=='schedule-admission.json' and value.get('phase')=='installed':raise OSError('marker write unavailable')
            return original(path,value)
        with mock.patch.object(native,'atomic_json',side_effect=fail):result=self.perform()
        self.assertEqual(result['status'],'incomplete');self.assertTrue(result['committed'])
        with self.assertRaisesRegex(ValueError,'installation'):native.require_idle(self.root)
        self.assertEqual(self.perform(recover=True)['status'],'rolled-back')
        native.require_idle(self.root)

    def test_mismatched_admission_marker_blocks_and_is_not_adopted(self):
        self.perform();path=self.root/'control/schedule-admission.json';marker=native.read_json(path)
        marker['transaction_id']='f'*32;native.atomic_json(path,marker);self.calls=[]
        with self.assertRaisesRegex(ValueError,'installation'):native.require_idle(self.root)
        with self.assertRaisesRegex(ValueError,'marker mismatch'):self.perform(recover=True)
        self.assertEqual(self.calls,[])

    def test_interrupted_idempotent_intent_marker_advance_preserves_existing_timer(self):
        self.perform();original=native.atomic_json;old=native.read_json(self.root/'control/schedule-admission.json')
        def fail(path,value):
            if path.name=='schedule-admission.json' and value.get('phase')=='pending':raise OSError('marker advance unavailable')
            return original(path,value)
        with mock.patch.object(native,'atomic_json',side_effect=fail),self.assertRaises(OSError):self.perform()
        self.assertEqual(native.read_json(self.root/'control/schedule-admission.json'),old)
        with self.assertRaisesRegex(ValueError,'installation'):native.require_idle(self.root)
        self.assertEqual(self.perform(recover=True)['status'],'rolled-back')
        self.assertTrue(self.active and self.enabled);native.require_idle(self.root)

    def test_launcher_replacement_after_render_refuses_before_host_mutation(self):
        original=native.render_schedule
        def replace(*args,**kwargs):
            result=original(*args,**kwargs)
            self.binary.rename(self.binary.with_name('original-launcher'))
            self.binary.write_text('from disk_magician.cli import main\n# replacement\n');self.binary.chmod(0o700)
            return result
        with mock.patch.object(native,'render_schedule',side_effect=replace),self.assertRaisesRegex(ValueError,'launcher'):self.perform()
        self.assertEqual(self.calls,[]);self.assertFalse(self.directory.exists())
        self.assertIn('replacement',self.binary.read_text())

    def test_launcher_inplace_edit_during_preflight_blocks_activation(self):
        original=install.manager;changed=[]
        def edit(*args,**kwargs):
            if args[0]=='show' and not changed:
                self.binary.write_text(self.binary.read_text()+'# edited preflight\n');changed.append(True)
            return original(*args,**kwargs)
        with mock.patch.object(install,'manager',side_effect=edit),self.assertRaisesRegex(ValueError,'launcher'):self.perform()
        self.assertFalse(any(c[0] in ('daemon-reload','enable','start','stop','disable') for c in self.calls))
        self.assertIn('edited preflight',self.binary.read_text())
        self.assertFalse(list(self.directory.glob('*.service')))

    def test_launcher_change_after_reload_blocks_enable_and_start(self):
        original=install.manager
        def edit(*args,**kwargs):
            result=original(*args,**kwargs)
            if args[0]=='daemon-reload':self.binary.write_text(self.binary.read_text()+'# edited reload\n')
            return result
        with mock.patch.object(install,'manager',side_effect=edit),self.assertRaisesRegex(ValueError,'launcher'):self.perform()
        self.assertFalse(any(c[0] in ('enable','start') for c in self.calls))

    def test_recovery_rejects_changed_launcher_without_mutating_it(self):
        self.perform();self.binary.write_text(self.binary.read_text()+'# operator update\n');self.calls=[]
        with self.assertRaisesRegex(ValueError,'launcher'):self.perform(recover=True)
        self.assertEqual(self.calls,[]);self.assertIn('operator update',self.binary.read_text())

    def test_launcher_mode_or_symlink_change_is_not_adopted_on_recovery(self):
        self.perform();self.binary.chmod(0o777);self.calls=[]
        with self.assertRaisesRegex(ValueError,'launcher'):self.perform(recover=True)
        self.assertEqual(self.calls,[])
        self.binary.chmod(0o700);self.binary.rename(self.binary.with_name('linked-target'))
        self.binary.symlink_to(self.binary.with_name('linked-target'))
        with self.assertRaisesRegex(ValueError,'launcher'):self.perform(recover=True)
        self.assertTrue(self.binary.is_symlink());self.assertEqual(self.calls,[])

    def test_launcher_edit_during_enable_prevents_start(self):
        original=install.manager
        def edit(*args,**kwargs):
            result=original(*args,**kwargs)
            if args[0]=='enable':self.binary.write_text(self.binary.read_text()+'# edit during enable\n')
            return result
        with mock.patch.object(install,'manager',side_effect=edit),self.assertRaisesRegex(ValueError,'launcher'):self.perform()
        self.assertFalse(any(c[0]=='start' for c in self.calls))
        self.assertEqual(native.read_json(self.root/'control/schedule-admission.json')['phase'],'pending')

    def test_launcher_writable_ancestor_refused_before_manager(self):
        directory=self.base/'unsafe-bin';directory.mkdir();self.binary.rename(directory/'diskm');self.binary=directory/'diskm'
        directory.chmod(0o777)
        with self.assertRaisesRegex(ValueError,'ancestor'):self.perform()
        self.assertEqual(self.calls,[])

    def test_launcher_foreign_owned_ancestor_refused_before_manager(self):
        directory=self.base/'foreign-bin';directory.mkdir();self.binary.rename(directory/'diskm');self.binary=directory/'diskm'
        original=Path.lstat
        def foreign(path,*args,**kwargs):
            result=original(path,*args,**kwargs)
            if path==directory:
                values=list(result);values[4]=os.getuid()+1;return os.stat_result(values)
            return result
        with mock.patch.object(Path,'lstat',foreign),self.assertRaisesRegex(ValueError,'ancestor'):self.perform()
        self.assertEqual(self.calls,[])

    def test_launcher_ancestor_substitution_keeps_leaf_but_refuses_recovery(self):
        directory=self.base/'trusted-bin';directory.mkdir();self.binary.rename(directory/'diskm');self.binary=directory/'diskm'
        self.perform();directory.rename(self.base/'old-bin');directory.mkdir()
        (self.base/'old-bin/diskm').rename(self.binary);self.calls=[]
        with self.assertRaisesRegex(ValueError,'launcher'):self.perform(recover=True)
        self.assertEqual(self.calls,[])

    def test_launcher_ancestor_mode_change_refuses_recovery(self):
        directory=self.base/'trusted-bin';directory.mkdir(mode=0o700);self.binary.rename(directory/'diskm');self.binary=directory/'diskm'
        self.perform();directory.chmod(0o755);self.calls=[]
        with self.assertRaisesRegex(ValueError,'launcher'):self.perform(recover=True)
        self.assertEqual(self.calls,[])
