#!/usr/bin/env bash
# Real disposable native-ext4 fixtures. Evidence and images survive canonical unmount.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVIDENCE="$(mktemp -d /tmp/dm-linux-autotrim.XXXXXX)"
exec > >(tee "$EVIDENCE/full.log") 2>&1
echo "Evidence: $EVIDENCE"
cat > "$EVIDENCE/physical.py" <<'PY'
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import struct
import subprocess
import sys
import tarfile
import threading
import time

root, evidence = map(Path, sys.argv[1:3])
preflight = sys.argv[3:] == ["--preflight"]
assert sys.platform.startswith("linux")
env = {k: v for k, v in os.environ.items() if not k.startswith("DISK_MAGICIAN_")}
env["XDG_RUNTIME_DIR"] = f"/run/user/{os.getuid()}"
env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path={env['XDG_RUNTIME_DIR']}/bus"
GIB, MIB = 1024**3, 1024**2

def run(args, *, allowed=(0,), timeout=60, current=None):
    print("RUN", json.dumps(list(map(str, args))), flush=True)
    output = evidence / f"command-{time.time_ns()}.log"
    with output.open("w") as stream:
        result = subprocess.run(list(map(str, args)), env=current or env, text=True,
                                stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    content = output.read_text()
    print(content, end="", flush=True)
    print("EXIT", result.returncode, flush=True)
    assert result.returncode in allowed, (args, result.returncode)
    return content.strip()

def systemctl(*args, **kwargs):
    return run(["systemctl", "--user", *args], **kwargs)

assert shutil.disk_usage(evidence).free >= 10 * GIB, "host headroom below 10 GiB"
for binary in ("mke2fs", "blkid", "mount", "umount", "fuser", "systemctl", "sudo"):
    assert shutil.which(binary), binary
bus = subprocess.run(["systemctl", "--user", "show", "--property=Version", "--value"], env=env,
                     capture_output=True, text=True, timeout=10)
print("systemd user manager version present:", bool(bus.stdout.strip()), flush=True)
assert bus.returncode == 0 and bus.stdout.strip(), bus.stderr
production_config = Path.home() / ".config/disk-magician/linux-scratch.json"
production = json.loads(production_config.read_text())["volumes"]
unit_directory = Path.home() / ".config/systemd/user"
protected = [production_config, unit_directory / "diskm-scratch.service",
             unit_directory / "diskm-scratch-reclaim.service",
             unit_directory / "diskm-scratch-reclaim.timer"]
for pattern in ("diskm-scratch-reclaim*.service", "diskm-scratch-reclaim*.timer"):
    protected.extend(path for path in sorted(unit_directory.glob(pattern)) if path not in protected)
protected_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None
                    for p in protected}
run(["bash", root / "disk_magician.sh", "volume", "scheduler", "--help"])
print("PASS preflight: user bus, canonical scheduler help, native ext4 tools, >=10 GiB headroom", flush=True)
if preflight:
    raise SystemExit(0)

candidate = evidence / "candidate"
sha = run(["git", "-C", root, "rev-parse", "HEAD"])
assert not run(["git", "-C", root, "status", "--porcelain"]), "commit candidate before physical run"
archive = evidence / f"candidate-{sha}.tar"
run(["git", "-C", root, "archive", "--format=tar", f"--output={archive}", sha])
candidate.mkdir()
with tarfile.open(archive) as source:
    source.extractall(candidate, filter="data")
assert (candidate / "tests/test_linux_scratch_autotrim.sh").read_bytes() == (root / "tests/test_linux_scratch_autotrim.sh").read_bytes()
file_hashes = {str(p.relative_to(candidate)): hashlib.sha256(p.read_bytes()).hexdigest()
               for p in sorted(candidate.rglob("*")) if p.is_file() and not p.is_symlink()}
(evidence / "candidate.json").write_text(json.dumps({"commit": sha,
    "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(), "files": file_hashes}))
for p in candidate.rglob("*"):
    if not p.is_symlink():
        p.chmod(p.stat().st_mode & ~0o222)
candidate.chmod(0o500)
diskm = ["bash", str(candidate / "disk_magician.sh")]
(evidence / "source-head").write_text(sha + "\n")

def digest(p):
    with p.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def age(p, hours):
    stamp = time.time() - hours * 3600
    for child in [*p.rglob("*"), p]:
        os.utime(child, (stamp, stamp))

def allocated(p):
    try:
        return p.stat().st_blocks * 512
    except FileNotFoundError:
        return 0

def reserve_details(p):
    try:
        st = p.stat()
        return {"exists": True, "logical_bytes": st.st_size, "blocks": st.st_blocks,
                "block_unit_bytes": 512, "allocated_bytes": st.st_blocks * 512, "io_block_bytes": st.st_blksize}
    except FileNotFoundError:
        return {"exists": False, "allocated_bytes": 0}

def host_headroom():
    sample = {"at_ns": time.time_ns(), "free_bytes": shutil.disk_usage(evidence).free}
    with (evidence / "host-headroom.jsonl").open("a") as f:
        f.write(json.dumps(sample) + "\n")
    assert sample["free_bytes"] >= 10 * GIB, "host headroom below 10 GiB while writing"
    return sample

def write(p, blocks):
    with p.open("xb", buffering=0) as f:
        for index in range(blocks):
            if index % 32 == 0:
                host_headroom()
            f.write(b"x" * MIB)
        os.fsync(f.fileno())

def full(p):
    failure = None
    host_samples = []
    with p.open("xb", buffering=0) as f:
        try:
            for index in range(2049):
                if index % 32 == 0:
                    host_samples.append(host_headroom())
                block = b"f" * MIB
                while block:
                    count = f.write(block)
                    assert count > 0
                    block = block[count:]
            raise AssertionError("2 GiB fixture did not fill")
        except OSError as exc:
            assert exc.errno == errno.ENOSPC, exc
            failure = {"operation": "write", "errno": exc.errno, "errno_name": "ENOSPC",
                       "path": str(p), "size": p.stat().st_size}
    assert failure and failure["size"] > 0
    failure["host_free_samples"] = host_samples
    failure["host_free_at_enospc"] = shutil.disk_usage(evidence).free
    assert failure["host_free_at_enospc"] >= 10 * GIB
    print(json.dumps(failure), flush=True)
    return failure

class Diagnostics:
    """Hold real diagnostic inodes open so canonical unlink cannot lose evidence."""
    def __init__(self, state, reserve, output):
        self.state, self.reserve, self.output = state, reserve, output
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        assert self.fd >= 0
        assert self.libc.inotify_add_watch(self.fd, os.fsencode(state), 0x100 | 0x200) >= 0
        self.handles, self.records, self.samples = {}, [], []
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.watch)
        self.thread.start()

    def watch(self):
        while not self.stop.is_set():
            self.samples.append({"at_ns": time.time_ns(), **reserve_details(self.reserve)})
            if not select.select([self.fd], [], [], .002)[0]:
                continue
            data = os.read(self.fd, 65536)
            while data:
                wd, mask, cookie, length = struct.unpack("iIII", data[:16])
                name = data[16:16+length].split(b"\0")[0].decode()
                data = data[16+length:]
                if not name.startswith("dm-c14-diagnostic."):
                    continue
                if mask & 0x100:
                    try:
                        self.handles[name] = os.open(self.state / name, os.O_RDONLY)
                    except FileNotFoundError:
                        pass
                if mask & 0x200 and name in self.handles:
                    fd = self.handles.pop(name)
                    content = os.pread(fd, 65536, 0)
                    os.close(fd)
                    if content:
                        record = json.loads(content)
                        self.records.append(record)
                        (self.output / name).write_bytes(content)

    def finish(self):
        self.stop.set()
        self.thread.join()
        for fd in self.handles.values():
            os.close(fd)
        os.close(self.fd)
        (self.output / "ballast-samples.json").write_text(json.dumps(self.samples))
        (self.output / "intent-diagnostics.json").write_text(json.dumps(self.records))

for case in ("recovery", "protected"):
    assert shutil.disk_usage(evidence).free >= 10 * GIB, "host headroom below 10 GiB"
    fixture = evidence / case
    fixture.mkdir(mode=0o700)
    assert fixture.stat().st_mode & 0o777 == 0o700
    state = fixture / "state"
    state.mkdir(mode=0o700)
    config_path, mount, image = fixture / "config.json", fixture / "mount", fixture / "scratch.ext4"
    cfg = json.loads((root / "config.json.template").read_text())
    cfg["volumes"] = dict(production, swap_headroom_gb=1, alarm_floor_gb=1,
                          classes={"scratch": {"name": "diskm-scratch", "quota_gb": 2,
                                   "backend": "native",
                                   "mountpoint": str(mount), "image_path": str(image)}})
    config_path.write_text(json.dumps(cfg))
    local = dict(env, DISK_MAGICIAN_CONFIG=str(config_path), DISK_MAGICIAN_STATE_DIR=str(state),
                 DISK_MAGICIAN_DELETION_LOG=str(state / "deletions.log"),
                 DISK_MAGICIAN_SCRATCH_PRODUCER_PIDS=f"{os.getpid()},{os.getppid()}",
                 DISK_MAGICIAN_DISKM_BIN=str(candidate / "disk_magician.sh"))
    unit = "diskm-scratch-reclaim-" + hashlib.sha256(os.fsencode(config_path.resolve())).hexdigest()[:12]
    unit_dir = Path.home() / ".config/systemd/user"
    assert not any((unit_dir / (unit + s)).exists() for s in (".timer", ".service")), "test unit collision"
    expected_units = {}
    for suffix in ("service", "timer"):
        text = (candidate / "systemd" / f"diskm-scratch-reclaim.{suffix}.in").read_text()
        for key, value in {"@ORCHESTRATOR@": candidate / "disk_magician.sh", "@CONFIG_PATH@": config_path,
                           "@STATE_PATH@": state, "@DELETION_LOG@": state / "deletions.log"}.items():
            text = text.replace(key, '"' + str(value) + '"')
        expected_units[suffix] = text.replace("@UNIT_NAME@", unit).replace("@CADENCE@", "OnBootSec=5s\nOnUnitActiveSec=20s\nAccuracySec=1s")
    def dm(*args, **kwargs):
        return run([*diskm, *args], current=local, **kwargs)
    sleeper = subprocess.Popen(["sleep", "600"], cwd=fixture)
    mounted, installed, fstab_installed, observer = False, False, False, None
    try:
        dm("volume", "create", "scratch")
        dm("volume", "create", "scratch", "--execute", timeout=180)
        assert image.stat().st_size == 2 * GIB
        run([*diskm, "volume", "fstab", "preview", "scratch", "--config", config_path,
             "--state-dir", state, "--user-uid", os.getuid(), "--fixture-root", fixture], timeout=60)
        fstab_args = ["volume", "fstab", "install", "scratch", "--config", config_path,
                      "--state-dir", state, "--user-uid", os.getuid(), "--fixture-root", fixture, "--execute"]
        run(["sudo", "-n", *diskm, *fstab_args], timeout=60)
        fstab_installed = True
        dm("volume", "mount", "scratch")
        mounted = True
        dm("volume", "ballast", "ensure", "scratch")
        reserve = mount / ".diskm-ballast"
        before_blocks = allocated(reserve)
        before_reserve = reserve_details(reserve)
        assert before_blocks >= 64 * MIB
        paths = {}
        for name in ("oldest", "newer", "recent", "live"):
            args = ["scratch-new", str(root), name, "--kind", "evidence", "--est-gb", "0.01"]
            if name == "live":
                args += ["--owner-pid", str(sleeper.pid)]
            paths[name] = Path(dm(*args).splitlines()[-1])
            assert paths[name].is_relative_to(mount)
        # Every producer/parent owner is still live at canonical release time.
        for lease in sorted((state / "worktree_leases").glob("*.json")):
            record = json.loads(lease.read_text())
            if record["path"] not in list(map(str, paths.values())):
                continue
            for owner in record["owners"]:
                if record["path"] == str(paths["live"]) and owner["pid"] == sleeper.pid:
                    continue
                os.kill(owner["pid"], 0)
                dm("lease-release-owner", record["path"], "--owner-pid", str(owner["pid"]))
        write(paths["oldest"] / "payload", 1280 if case == "recovery" else 8)
        write(paths["recent"] / "payload", 8)
        write(paths["live"] / "payload", 8)
        if case == "protected":
            write(paths["newer"] / "payload", 8)
        failure = full(paths["newer" if case == "recovery" else "live"] / "fill")
        if case == "recovery":
            age(paths["oldest"], 96)
            age(paths["newer"], 72)
        age(paths["live"], 120)
        payloads = [p for artifact in paths.values() for p in artifact.iterdir() if p.is_file()]
        hashes = {str(p): digest(p) for p in payloads}
        (fixture / "before.json").write_text(json.dumps({"hashes": hashes, "reserve": before_reserve, "enospc": failure}))
        if case == "recovery":
            original_config = config_path.read_bytes()
            registry = state / "volumes/registry.json"
            original_registry = registry.read_bytes()
            alias = fixture / "mount-alias"
            alias.symlink_to(mount, target_is_directory=True)
            substitute = fixture / "substitute"
            substitute.mkdir()
            write(substitute / "sentinel", 1)
            substitute_hash = digest(substitute / "sentinel")
            for negative in ("wrong-uuid", "unknown-config", "symlink-mount", "substituted-config"):
                try:
                    if negative == "wrong-uuid":
                        data = json.loads(original_registry)
                        data["volumes"]["scratch"]["filesystem_uuid"] = "00000000-0000-0000-0000-000000000000"
                        registry.write_text(json.dumps(data))
                    elif negative == "unknown-config":
                        config_path.write_text("{")
                    else:
                        data = json.loads(original_config)
                        data["volumes"]["classes"]["scratch"]["mountpoint"] = str(alias if negative == "symlink-mount" else substitute)
                        config_path.write_text(json.dumps(data))
                    dm("volume", "reclaim", "--clean")
                    dm("volume", "ballast", "release", "scratch", allowed=(75,))
                    assert all(digest(Path(p)) == h for p, h in hashes.items())
                    assert allocated(reserve) == before_blocks
                    assert digest(substitute / "sentinel") == substitute_hash
                    print("PASS B1", negative, "hashes and allocated ballast preserved", flush=True)
                finally:
                    registry.write_bytes(original_registry)
                    config_path.write_bytes(original_config)
            # A real second native ext4 filesystem at the registered mount must not be
            # accepted merely because the original image and registry still match.
            assert shutil.disk_usage(evidence).free >= 10 * GIB
            dm("volume", "unmount", "scratch")
            mounted = False
            run(["sudo", "-n", *diskm, "volume", "fstab", "remove", "scratch", "--config", config_path,
                 "--state-dir", state, "--user-uid", os.getuid(), "--fixture-root", fixture, "--execute"], timeout=60)
            fstab_installed = False
            substitute_config = fixture / "substitute-config.json"
            substitute_state = fixture / "substitute-state"
            substitute_state.mkdir(mode=0o700)
            substitute_cfg = json.loads(original_config)
            substitute_cfg["volumes"]["classes"]["scratch"]["image_path"] = str(fixture / "substitute.ext4")
            substitute_config.write_text(json.dumps(substitute_cfg))
            substitute_env = dict(local, DISK_MAGICIAN_CONFIG=str(substitute_config),
                                  DISK_MAGICIAN_STATE_DIR=str(substitute_state))
            def substitute_dm(*args):
                return run([*diskm, *args], current=substitute_env, timeout=180)
            substitute_mounted, substitute_fstab_installed = False, False
            try:
                substitute_dm("volume", "create", "scratch")
                substitute_dm("volume", "create", "scratch", "--execute")
                run([*diskm, "volume", "fstab", "preview", "scratch", "--config", substitute_config,
                     "--state-dir", substitute_state, "--user-uid", os.getuid(), "--fixture-root", fixture], timeout=60)
                substitute_fstab = ["sudo", "-n", *diskm, "volume", "fstab", "install", "scratch",
                    "--config", substitute_config, "--state-dir", substitute_state,
                    "--user-uid", os.getuid(), "--fixture-root", fixture, "--execute"]
                run(substitute_fstab, timeout=60)
                substitute_fstab_installed = True
                substitute_dm("volume", "mount", "scratch")
                substitute_mounted = True
                substitute_dm("volume", "ballast", "ensure", "scratch")
                write(mount / "substitute-sentinel", 1)
                sentinel_hash = digest(mount / "substitute-sentinel")
                substitute_reserve = allocated(reserve)
                dm("volume", "reclaim", "--clean")
                dm("volume", "ballast", "release", "scratch", allowed=(75,))
                assert digest(mount / "substitute-sentinel") == sentinel_hash
                assert allocated(reserve) == substitute_reserve
            finally:
                if substitute_mounted:
                    substitute_dm("volume", "unmount", "scratch")
                if substitute_fstab_installed:
                    run(["sudo", "-n", *diskm, "volume", "fstab", "remove", "scratch",
                         "--config", substitute_config, "--state-dir", substitute_state,
                         "--user-uid", os.getuid(), "--fixture-root", fixture, "--execute"], timeout=60)
                run([*diskm, "volume", "fstab", "preview", "scratch", "--config", config_path,
                     "--state-dir", state, "--user-uid", os.getuid(), "--fixture-root", fixture], timeout=60)
                run(["sudo", "-n", *diskm, "volume", "fstab", "install", "scratch", "--config", config_path,
                     "--state-dir", state, "--user-uid", os.getuid(), "--fixture-root", fixture, "--execute"], timeout=60)
                fstab_installed = True
                dm("volume", "mount", "scratch")
                mounted = True
            assert all(digest(Path(p)) == h for p, h in hashes.items())
            assert allocated(reserve) == before_blocks
            print("PASS B1 real substituted mount: both filesystems and ballast preserved", flush=True)
        observer = Diagnostics(state, reserve, fixture)
        assert sleeper.poll() is None
        live_lease = next(json.loads(p.read_text()) for p in (state / "worktree_leases").glob("*.json")
                          if json.loads(p.read_text())["path"] == str(paths["live"]))
        assert any(o["pid"] == sleeper.pid and not o.get("released_at") for o in live_lease["owners"])
        started = time.monotonic()
        installed = True
        assert dm("volume", "scheduler", "install", "scratch", "--interval-seconds", "20").splitlines()[-1] == unit
        history = state / "volumes/reclaim_runs.json"
        while time.monotonic() - started < 60:
            if history.exists():
                break
            time.sleep(.25)
        assert history.exists(), "timer did not complete within 60 seconds"
        trigger_us = int(systemctl("show", unit + ".timer", "-p", "LastTriggerUSecMonotonic", "--value"))
        start_us = int(systemctl("show", unit + ".service", "-p", "ExecMainStartTimestampMonotonic", "--value"))
        assert trigger_us > 0 and 0 <= start_us - trigger_us < 5_000_000
        (fixture / "timer-correlation.json").write_text(json.dumps({"last_trigger_us": trigger_us, "service_start_us": start_us}))
        systemctl("disable", "--now", unit + ".timer")
        while time.monotonic() - started < 60:
            active = systemctl("show", unit + ".service", "-p", "ActiveState", "--value")
            if active not in ("activating", "active", "deactivating"):
                break
            time.sleep(.25)
        assert active == "inactive", "reclaim service did not finish"
        observer.finish()
        result = json.loads(history.read_text())["runs"][-1]
        receipt = json.loads((state / "receipts/volume_reclaim.json").read_text())["last_terminal"]
        assert receipt["trigger"] == "timer"
        properties = systemctl("show", unit + ".timer", unit + ".service", "-p", "LastTriggerUSec",
                               "-p", "InvocationID", "-p", "ExecMainStartTimestamp", "-p", "Result")
        (fixture / "systemd-properties.txt").write_text(properties)
        journal = run(["journalctl", "--user", "-u", unit + ".service", "--no-pager", "-o", "short-precise"])
        (fixture / "journal.txt").write_text(journal)
        json_journal = run(["journalctl", "--user", "-u", unit + ".service", "--no-pager", "-o", "json"])
        (fixture / "journal.jsonl").write_text(json_journal + "\n")
        journal_rows = [json.loads(line) for line in json_journal.splitlines() if line.startswith("{")]
        assert any(row.get("_SYSTEMD_INVOCATION_ID") for row in journal_rows), "no service invocation evidence"
        assert "ExecMainStartTimestamp=Mon" in properties or any(
            line.startswith("ExecMainStartTimestamp=") and len(line.split("=", 1)[1]) > 5 for line in properties.splitlines())
        rendered_hashes = {}
        for suffix in ("service", "timer"):
            assert (unit_dir / f"{unit}.{suffix}").read_text() == expected_units[suffix]
            shutil.copyfile(unit_dir / f"{unit}.{suffix}", fixture / f"installed.{suffix}")
            rendered_hashes[suffix] = digest(fixture / f"installed.{suffix}")
        (fixture / "unit-proof.json").write_text(json.dumps({"commit": sha, "unit": unit,
            "config_sha256": digest(config_path), "rendered_sha256": rendered_hashes}))
        (fixture / "after.json").write_text(json.dumps({"result": result, "reserve": reserve_details(reserve)}))
        if case == "recovery":
            assert receipt["outcome"] == "success", receipt
            assert observer.records and {"operation": "intent_write", "errno": 28, "errno_name": "ENOSPC"} in observer.records
            assert any(not s["exists"] for s in observer.samples), "reserve was never physically released"
            release_lines = (state / "deletions.log").read_text().splitlines()
            entry = json.loads((state / "volumes/registry.json").read_text())["volumes"]["scratch"]
            actions = [line.split("\t")[2] for line in release_lines
                       if "\t" + str(reserve) + "\t" in line and "uuid=" + entry["filesystem_uuid"] in line]
            assert actions == ["release_ballast_intent", "release_ballast"], actions
            removed = [line.split("\t")[4] for line in release_lines if line.split("\t")[2] == "remove"]
            assert removed == [str(paths["oldest"])], removed
            assert not paths["oldest"].exists()
            assert paths["newer"].is_dir()
            assert result["removed"] == 1 and result["target_reached"]
            assert all(digest(Path(p)) == h for p, h in hashes.items() if not Path(p).is_relative_to(paths["oldest"]))
            if allocated(reserve) < before_blocks:
                print("PARTIAL: reserve restoration failed; see after.json and receipts", flush=True)
                raise AssertionError("reserve not restored")
            assert shutil.disk_usage(mount).used * 100 <= 2 * GIB * 80
            write(mount / "recovered-write-fsync", 1)
            print("PASS B2: typed intent ENOSPC, release, oldest whole artifact, restored ballast, fsync", flush=True)
        else:
            assert receipt["outcome"] == "partial", receipt
            assert all(digest(Path(p)) == h for p, h in hashes.items())
            assert result["removed"] == 0 and not result["target_reached"]
            assert "trim_target_not_reached" in journal
            print("PASS all-protected: unchanged hashes and unmet target", flush=True)
    finally:
        if observer and observer.thread.is_alive():
            observer.finish()
        if installed:
            owned = all((unit_dir / f"{unit}.{suffix}").is_file() and
                        (unit_dir / f"{unit}.{suffix}").read_text() == content for suffix, content in expected_units.items())
            if owned:
                systemctl("disable", "--now", unit + ".timer", allowed=(0, 1))
                deadline = time.monotonic() + 60
                while systemctl("show", unit + ".service", "-p", "ActiveState", "--value") in ("active", "activating", "deactivating"):
                    assert time.monotonic() < deadline, "service still running; preserve mounted fixture"
                    time.sleep(.5)
            else:
                assert not any((unit_dir / f"{unit}.{suffix}").exists() for suffix in expected_units), "unit identity changed; leave untouched"
        if mounted:
            dm("volume", "unmount", "scratch")
        if fstab_installed:
            run(["sudo", "-n", *diskm, "volume", "fstab", "remove", "scratch", "--config", config_path,
                 "--state-dir", state, "--user-uid", os.getuid(), "--fixture-root", fixture, "--execute"], timeout=60)
        sleeper.terminate()
        sleeper.wait(timeout=5)
        assert all((digest(Path(p)) if Path(p).is_file() else None) == h
                   for p, h in protected_hashes.items()), "production config/service changed"
print("PASS Linux Scratch automatic trimming; fixtures canonically unmounted, evidence retained", flush=True)
PY
python3 "$EVIDENCE/physical.py" "$ROOT" "$EVIDENCE" "$@"
