import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
import sys
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(sys.platform.startswith("linux"), "native disposable contract is Linux-only")
class NativeDisposableTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('native_disposable', ROOT / 'scripts/native_disposable.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory(prefix='dm-disposable-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'namespace'
        sandbox = mock.patch.dict(os.environ, {'DISK_MAGICIAN_TEST_CONTEXT':'1', 'DISK_MAGICIAN_TEST_SANDBOX':str(self.root.parent)})
        sandbox.start(); self.addCleanup(sandbox.stop)
        # Cloud sandbox injects an empty /tmp/.git sentinel; hide only that
        # harness marker, not any repository marker in the fixture itself.
        exists = Path.exists
        patcher = mock.patch.object(Path, 'exists', lambda path: False if str(path) == '/tmp/.git' else exists(path))
        patcher.start(); self.addCleanup(patcher.stop)

    def test_fresh_namespace_only_and_owned_marker(self):
        self.module.initialize(self.root)
        self.assertTrue((self.root / 'control/identity.json').is_file())
        with self.assertRaises(Exception):
            self.module.initialize(self.root)

    def test_unknown_namespace_is_never_adopted(self):
        self.root.mkdir()
        (self.root / 'important').write_text('preserve')
        with self.assertRaises(Exception):
            self.module.clean(self.root, Path('/usr/bin/systemd-tmpfiles'), execute=True)
        self.assertEqual((self.root / 'important').read_text(), 'preserve')

    def test_symlink_root_refused(self):
        target = self.root.parent / 'target'; target.mkdir()
        self.root.symlink_to(target, target_is_directory=True)
        with self.assertRaises(Exception):
            self.module.initialize(self.root)

    def make_job(self, content='fixture'):
        self.module.initialize(self.root)
        self.assertEqual(self.module.producer(self.root, ['/bin/sh', '-c', 'printf fixture > item']), 0)
        return next((self.root / 'data').iterdir())

    def test_repository_fixture_is_refused(self):
        (self.root.parent / '.git').mkdir()
        with self.assertRaisesRegex(ValueError, 'repository'):
            self.module.initialize(self.root)

    def test_replaced_admission_lock_is_refused(self):
        self.module.initialize(self.root)
        lock = self.root / 'control/gate.lock'
        lock.rename(lock.with_name('old.lock')); lock.touch(mode=0o600)
        with self.assertRaisesRegex(ValueError, 'gate identity'):
            with self.module.gate(self.root, True): pass

    def test_active_producer_gate_refuses_cleanup(self):
        import fcntl
        self.module.initialize(self.root)
        with self.module.gate(self.root, False):
            with self.assertRaises(BlockingIOError):
                self.module.clean(self.root, Path('/usr/bin/systemd-tmpfiles'))

    def test_symlink_and_hardlink_payloads_preserved(self):
        job = self.make_job()
        (job / 'link').symlink_to(job / 'item')
        with self.assertRaisesRegex(ValueError, 'symlink/hardlink'):
            self.module.clean(self.root, Path('/usr/bin/systemd-tmpfiles'))
        (job / 'link').unlink(); os.link(job / 'item', job / 'link')
        with self.assertRaisesRegex(ValueError, 'symlink/hardlink'):
            self.module.clean(self.root, Path('/usr/bin/systemd-tmpfiles'))
        self.assertTrue((job / 'item').exists())

    def test_pending_intent_blocks_until_explicit_reconciliation(self):
        job = self.make_job()
        self.module.atomic_json(self.root / 'control/pending.json', {'phase':'pending', 'id':'interrupted', 'before':self.module.snapshot(self.root)})
        with self.assertRaisesRegex(ValueError, 'reconciliation'):
            self.module.clean(self.root, Path('/usr/bin/systemd-tmpfiles'))
        result = self.module.reconcile(self.root)
        self.assertEqual(result['status'], 'unknown-attribution')
        self.assertTrue((job / 'item').exists())

    def test_native_environment_drops_credential_and_loader_injection(self):
        with mock.patch.dict(os.environ, {'CREDENTIALS_DIRECTORY':'/hostile', 'LD_PRELOAD':'/hostile.so'}):
            self.assertEqual(self.module.native_env(), {'PATH':'/usr/bin:/bin', 'LANG':'C', 'LC_ALL':'C'})

    def test_actual_255_three_day_cleanup_with_hostile_extra_rule(self):
        import subprocess
        binary = Path('/tmp/dm-systemd255/root/usr/bin/systemd-tmpfiles')
        libraries = '/tmp/dm-systemd255/root/usr/lib/x86_64-linux-gnu/systemd'
        if not binary.exists(): self.skipTest('isolated extracted systemd255 fixture unavailable')
        import fcntl
        job = self.make_job()
        self.module.producer(self.root, ['/bin/sh','-c','printf active > item'])
        held = next(item for item in (self.root / 'data').iterdir() if item != job)
        held_fd = os.open(held, os.O_RDONLY | os.O_DIRECTORY)
        root_fd = os.open(self.root / 'data', os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, held_fd); self.addCleanup(os.close, root_fd)
        fcntl.flock(held_fd, fcntl.LOCK_SH); fcntl.flock(root_fd, fcntl.LOCK_EX)
        # Shift only native process wall clock by four days, keeping the actual
        # 3d configuration and all real ctime/atime/mtime checks intact.
        source = self.root.parent / 'clock.c'; library = self.root.parent / 'clock.so'
        source.write_text('''#define _GNU_SOURCE
#include <time.h>
#include <dlfcn.h>
int clock_gettime(clockid_t c, struct timespec *t) {
 int (*real)(clockid_t,struct timespec*)=dlsym(RTLD_NEXT,"clock_gettime");
 int r=real(c,t); if(!r && c==CLOCK_REALTIME)t->tv_sec+=345600; return r;
}
''')
        subprocess.run(['cc','-shared','-fPIC',str(source),'-ldl','-o',str(library)],check=True)
        sentinel = self.root.parent / 'outside'; sentinel.write_text('preserve')
        credentials = self.root.parent / 'credentials'; credentials.mkdir()
        (credentials / 'tmpfiles.extra').write_text('r '+str(sentinel)+' - - - - -\n')
        env = self.module.native_env() | {'LD_LIBRARY_PATH': libraries, 'LD_PRELOAD':str(library)}
        with mock.patch.dict(os.environ, {'CREDENTIALS_DIRECTORY':str(credentials)}), mock.patch.object(self.module, 'native_env', return_value=env):
            result = self.module.clean(self.root, binary, execute=True)
        self.assertEqual(result['native_returncode'],0)
        self.assertIn(job.name+'/item',result['removed'])
        self.assertEqual(sentinel.read_text(),'preserve')
        self.assertEqual((held / 'item').read_text(),'active')
        # Configured-root flock did not stop cleanup; child-dir flock did.
        self.assertNotIn(held.name+'/item',result['removed'])
        self.assertEqual(result['status'],'observed')

    def test_corrupt_audit_stops_before_native(self):
        self.make_job()
        with (self.root / 'control/audit.jsonl').open('a') as stream: stream.write('{partial')
        fake = mock.Mock(returncode=0, stdout='systemd 255\n')
        original = self.module.subprocess.run
        calls = []
        def execute(command, **kwargs):
            if command[0] == 'bash': return original(command, **kwargs)
            calls.append(command); return fake
        with mock.patch.object(self.module.subprocess,'run',side_effect=execute) as run:
            with self.assertRaisesRegex(ValueError,'audit history'):
                self.module.clean(self.root,Path('/usr/bin/systemd-tmpfiles'),execute=True)
        self.assertEqual(len(calls),1)  # version probe only, never --clean
        self.assertEqual(self.module.read_json(self.root / 'control/pending.json')['phase'],'pending')

    def test_cli_dispatch_honors_sandbox_and_does_not_create_namespace(self):
        import subprocess
        result = subprocess.run(['bash',str(ROOT/'disk_magician.sh'),'disposable','init','--root','/not-created-disposable'],text=True,capture_output=True)
        self.assertEqual(result.returncode,75,result.stderr)
        self.assertIn('sandbox',result.stderr)
        self.assertFalse(Path('/not-created-disposable').exists())

    def test_detached_cooperative_descendant_inherits_both_locks(self):
        import sys
        import time
        self.module.initialize(self.root)
        code = '''import os, subprocess, sys
fds=(int(os.environ['DISKM_DISPOSABLE_GATE_FD']),int(os.environ['DISKM_DISPOSABLE_LOCK_FD']))
subprocess.Popen([sys.executable,'-c','import time; time.sleep(0.6)'],pass_fds=fds,start_new_session=True)
'''
        self.assertEqual(self.module.producer(self.root,[sys.executable,'-c',code]),0)
        with self.assertRaises(BlockingIOError):
            self.module.clean(self.root,Path('/usr/bin/systemd-tmpfiles'))
        deadline = time.monotonic()+3
        while True:
            try:
                self.module.clean(self.root,Path('/usr/bin/systemd-tmpfiles')); break
            except BlockingIOError:
                if time.monotonic()>deadline: raise
                time.sleep(.05)

    def test_actual_255_parent_death_keeps_native_admission_lock(self):
        import json
        import signal
        import subprocess
        import sys
        import time
        binary = Path('/tmp/dm-systemd255/root/usr/bin/systemd-tmpfiles')
        if not binary.exists(): self.skipTest('isolated extracted systemd255 fixture unavailable')
        self.make_job()
        ready = self.root.parent/'native-ready'; release = self.root.parent/'release'
        source = self.root.parent/'pause.c'; library = self.root.parent/'pause.so'
        source.write_text('''#define _GNU_SOURCE
#include <time.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
int clock_gettime(clockid_t c, struct timespec *t) {
 int (*real)(clockid_t,struct timespec*)=dlsym(RTLD_NEXT,"clock_gettime");
 int r=real(c,t); if(!r && c==CLOCK_REALTIME)t->tv_sec+=345600; return r;
}
int unlinkat(int fd, const char *p, int flags) {
 int (*real)(int,const char*,int)=dlsym(RTLD_NEXT,"unlinkat");
 if(!strcmp(p,"item")) {
  FILE *f=fopen(READY,"w"); if(f){fprintf(f,"%d",getpid());fclose(f);}
  for(int i=0;i<1000 && access(RELEASE,F_OK);i++) usleep(10000);
 }
 return real(fd,p,flags);
}
'''.replace('READY',json.dumps(str(ready))).replace('RELEASE',json.dumps(str(release))))
        subprocess.run(['cc','-shared','-fPIC',str(source),'-ldl','-o',str(library)],check=True)
        env = self.module.native_env() | {'LD_LIBRARY_PATH':'/tmp/dm-systemd255/root/usr/lib/x86_64-linux-gnu/systemd','LD_PRELOAD':str(library)}
        code = '''import sys
from pathlib import Path
from unittest import mock
sys.path.insert(0,sys.argv[1])
import native_disposable as n
exists=Path.exists
with mock.patch.object(Path,'exists',lambda p:False if str(p)=='/tmp/.git' else exists(p)):
 n.native_env=lambda:__import__('json').loads(sys.argv[4])
 n.clean(Path(sys.argv[2]),Path(sys.argv[3]),True)
'''
        worker = subprocess.Popen([sys.executable,'-c',code,str(ROOT/'scripts'),str(self.root),str(binary),json.dumps(env)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            deadline=time.monotonic()+5
            while not ready.exists() and worker.poll() is None and time.monotonic()<deadline: time.sleep(.02)
            self.assertTrue(ready.exists(),worker.communicate(timeout=1) if worker.poll() is not None else 'native did not reach unlink')
            worker.kill(); worker.wait(timeout=2)
            with self.assertRaises(BlockingIOError): self.module.reconcile(self.root)
            self.assertEqual(self.module.read_json(self.root/'control/pending.json')['phase'],'pending')
            release.touch()
            deadline=time.monotonic()+5
            while True:
                try: result=self.module.reconcile(self.root); break
                except BlockingIOError:
                    if time.monotonic()>deadline: raise
                    time.sleep(.02)
            self.assertEqual(result['status'],'unknown-attribution')
            self.assertTrue(result['missing_since_intent'])
        finally:
            release.touch()
            if worker.poll() is None: worker.kill(); worker.wait(timeout=2)
            worker.communicate(timeout=2)

    def test_bare_repository_payload_refused(self):
        job=self.make_job()
        (job/'HEAD').write_text('ref: refs/heads/main\n')
        (job/'objects').mkdir(); (job/'refs').mkdir()
        with self.assertRaisesRegex(ValueError,'repository'):
            self.module.clean(self.root,Path('/usr/bin/systemd-tmpfiles'),execute=True)
        self.assertTrue((job/'HEAD').exists())

    def test_same_device_bind_mount_is_refused(self):
        job=self.make_job()
        with mock.patch.object(self.module,'mount_targets',return_value=[job]):
            with self.assertRaisesRegex(ValueError,'mount'):
                self.module.clean(self.root,Path('/usr/bin/systemd-tmpfiles'),execute=True)
        self.assertTrue((job/'item').exists())

    def test_manifest_does_not_refresh_directory_access_age(self):
        job=self.make_job()
        os.utime(job,ns=(1000000000,1000000000))
        before=job.stat().st_atime_ns
        self.module.snapshot(self.root)
        self.assertEqual(job.stat().st_atime_ns,before)

    def test_safety_rules_apply_before_init_and_after_registration(self):
        import json
        safety=self.root.parent/'safety.json'
        safety.write_text(json.dumps({'never_delete':[str(self.root)]}))
        with mock.patch.dict(os.environ,{'DISK_MAGICIAN_SAFETY_FILE':str(safety)}):
            with self.assertRaisesRegex(ValueError,'protected'):
                self.module.initialize(self.root)
        self.make_job()
        with mock.patch.dict(os.environ,{'DISK_MAGICIAN_SAFETY_FILE':str(safety)}):
            for action in (lambda:self.module.producer(self.root,['true']),lambda:self.module.clean(self.root,Path('/usr/bin/systemd-tmpfiles')),lambda:self.module.reconcile(self.root)):
                with self.assertRaisesRegex(ValueError,'protected'): action()

    def test_missing_and_corrupt_explicit_safety_fail_closed(self):
        safety=self.root.parent/'missing-safety.json'
        with mock.patch.dict(os.environ,{'DISK_MAGICIAN_SAFETY_FILE':str(safety)}):
            with self.assertRaises((OSError,ValueError)):self.module.initialize(self.root)
        safety.write_text('{broken')
        with mock.patch.dict(os.environ,{'DISK_MAGICIAN_SAFETY_FILE':str(safety)}):
            with self.assertRaises((OSError,ValueError)):self.module.initialize(self.root)

    def test_shared_sandbox_guard_is_required(self):
        with mock.patch.dict(os.environ,{'DISK_MAGICIAN_TEST_CONTEXT':'1','DISK_MAGICIAN_TEST_SANDBOX':''}):
            with self.assertRaisesRegex(ValueError,'sandbox'):self.module.initialize(self.root)
        with mock.patch.dict(os.environ,{'DISK_MAGICIAN_TEST_CONTEXT':'1','DISK_MAGICIAN_TEST_SANDBOX':str(self.root.parent/'other')}):
            with self.assertRaisesRegex(ValueError,'sandbox'):self.module.initialize(self.root)

    def test_shared_protected_tmp_root_is_not_admitted(self):
        env={'DISK_MAGICIAN_TMP_ROOT_OVERRIDE':str(self.root.parent),'DISK_MAGICIAN_PROTECTED_TMP_ROOTS':self.root.name}
        with mock.patch.dict(os.environ,env):
            with self.assertRaisesRegex(ValueError,'protected'):self.module.initialize(self.root)

    def test_payload_glob_protection_applies_after_registration(self):
        import json
        job=self.make_job(); safety=self.root.parent/'rules.json'
        safety.write_text(json.dumps({'needs_decision':['*/item']}))
        with mock.patch.dict(os.environ,{'DISK_MAGICIAN_SAFETY_FILE':str(safety)}):
            with self.assertRaisesRegex(ValueError,'protected'):
                self.module.clean(self.root,Path('/usr/bin/systemd-tmpfiles'),True)
        self.assertTrue((job/'item').exists())

    def test_unreadable_safety_file_is_not_ignored(self):
        safety=self.root.parent/'unreadable.json'; safety.write_text('{}'); safety.chmod(0)
        self.addCleanup(safety.chmod,0o600)
        with mock.patch.dict(os.environ,{'DISK_MAGICIAN_SAFETY_FILE':str(safety)}):
            with self.assertRaises(OSError):self.module.initialize(self.root)

    def test_configured_scratch_alias_is_excluded(self):
        import json
        config=self.root.parent/'config.json'
        config.write_text(json.dumps({'volumes':{'classes':{'scratch':{'mountpoint':str(self.root.parent/'unused/../namespace')}}}}))
        with mock.patch.dict(os.environ,{'DISK_MAGICIAN_CONFIG':str(config)}):
            with self.assertRaisesRegex(ValueError,'Scratch'):self.module.initialize(self.root)

    def test_actual_255_credential_age_zero_injection_red_green(self):
        binary=Path('/tmp/dm-systemd255/root/usr/bin/systemd-tmpfiles')
        if not binary.exists():self.skipTest('isolated extracted systemd255 fixture unavailable')
        self.module.initialize(self.root)
        credentials=self.root.parent/'credentials';credentials.mkdir()
        for injected in (True,False):
            self.module.producer(self.root,['/bin/sh','-c','printf fresh > item'])
            job=next(item for item in (self.root/'data').iterdir() if (item/'item').exists())
            (credentials/'tmpfiles.extra').write_text('e /'+job.name+' - - - 0 -\n')
            env=self.module.native_env()|{'LD_LIBRARY_PATH':'/tmp/dm-systemd255/root/usr/lib/x86_64-linux-gnu/systemd'}
            if injected:env['CREDENTIALS_DIRECTORY']=str(credentials)
            with mock.patch.dict(os.environ,{'CREDENTIALS_DIRECTORY':str(credentials)}),mock.patch.object(self.module,'native_env',return_value=env):
                self.module.clean(self.root,binary,True)
            self.assertEqual((job/'item').exists(),not injected)

    def test_post_manifest_replacement_is_incomplete_and_keeps_intent(self):
        job=self.make_job();original=self.module.subprocess.run
        def run(command,**kwargs):
            if command[0]=='bash':return original(command,**kwargs)
            if '--version' in command:return mock.Mock(returncode=0,stdout='systemd 255\n')
            (job/'item').rename(job/'old-item')
            (job/'item').write_text('replacement')
            return mock.Mock(returncode=0,stderr='')
        with mock.patch.object(self.module.subprocess,'run',side_effect=run):
            result=self.module.clean(self.root,Path('/usr/bin/systemd-tmpfiles'),True)
        self.assertEqual(result['status'],'incomplete')
        self.assertIn(job.name+'/item',result['anomalies'])
        self.assertEqual(self.module.read_json(self.root/'control/pending.json')['phase'],'pending')

    def test_global_root_hold_blocks_all_three_safety_categories(self):
        import json
        for category in ('never_delete','protected_live_paths','needs_decision'):
            safety=self.root.parent/(category+'.json')
            safety.write_text(json.dumps({category:['/']}))
            with self.subTest(category=category),mock.patch.dict(os.environ,{'DISK_MAGICIAN_SAFETY_FILE':str(safety)}):
                with self.assertRaisesRegex(ValueError,'protected'):
                    self.module.initialize(self.root)
