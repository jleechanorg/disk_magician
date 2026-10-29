#!/usr/bin/env python3
"""Focused contract tests for `diskm lease-recover-lock --registry`."""

from __future__ import annotations

import json
import os
import fcntl
import stat
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import importlib.util


SCRATCH = os.environ.get("CLAUDE_CODE_TMPDIR") or os.environ.get("DISKM_SCRATCH") or os.environ.get("RUNNER_TEMP")
assert SCRATCH and Path(SCRATCH).is_dir(), "configured Scratch or RUNNER_TEMP directory required"
ROOT = Path(__file__).resolve().parent.parent
CLI = ["bash", str(ROOT / "disk_magician.sh"), "lease-recover-lock"]
SPEC = importlib.util.spec_from_file_location("lease_recover_lock", ROOT / "scripts/lease_recover_lock.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def run(state: Path, expected: int, *args: str, cli: list[str] = CLI) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state)}
    result = subprocess.run([*cli, *args], text=True, capture_output=True, env=env, check=False)
    assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
    return result


def run_bounded(state: Path, expected: int, *args: str) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "DISK_MAGICIAN_STATE_DIR": str(state)}
    try:
        result = subprocess.run(
            [*CLI, *args], text=True, capture_output=True, env=env, check=False, timeout=2
        )
    except subprocess.TimeoutExpired as exc:
        raise AssertionError(f"lease recovery hung on malformed metadata: {exc}") from exc
    assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
    return result


def make_lock(state: Path) -> Path:
    leases = state / "worktree_leases"
    leases.mkdir(parents=True, exist_ok=True)
    os.chmod(leases, 0o755)
    lock = leases / ".owner-mutation.reuse-lock"
    lock.mkdir(mode=0o755)
    os.chmod(lock, 0o755)
    return lock


def make_partial_lock(state: Path, pid: int) -> Path:
    lock = make_lock(state)
    (lock / "pid").write_bytes(f"{pid}\n".encode())
    (lock / "acquired_at").write_bytes(b"")
    os.chmod(lock / "pid", 0o644)
    os.chmod(lock / "acquired_at", 0o644)
    return lock


def partial_lock_bytes(lock: Path) -> dict[str, bytes]:
    return {name: (lock / name).read_bytes() for name in ("pid", "acquired_at")}


with tempfile.TemporaryDirectory(prefix="lease-recover-lock-", dir=SCRATCH) as temp:
    state = Path(temp) / "state"
    state.mkdir()
    os.chmod(state, 0o755)
    packaged_root = Path(temp) / "packaged"
    subprocess.run(
        ["bash", str(ROOT / "scripts/sync_package_tree.sh"), "--stage", str(packaged_root)],
        check=True,
        text=True,
    )
    PACKAGED_CLI = ["bash", str(packaged_root / "disk_magician.sh"), "lease-recover-lock"]
    assert (packaged_root / "disk_magician.sh").is_file()

    assert run(state, 2, "--bad").stderr.startswith("lease-recover-lock: usage:")
    print("PASS: invalid command shape is rejected")

    lock = make_lock(state)
    old = time.time() - 7200
    os.utime(lock, (old, old))
    result = run(state, 0, "--registry")
    receipt = json.loads(result.stdout)
    quarantined = Path(receipt["quarantined"])
    assert not lock.exists() and quarantined.is_dir()
    stored = quarantined.with_name(quarantined.name + ".receipt.json")
    assert json.loads(stored.read_text())["lock_identity"]["inode"] == receipt["lock_identity"]["inode"]
    print("PASS: exact old empty registry lock is atomically quarantined with receipt")

    shared_parent_state = Path(temp) / "shared-quarantine-parent-state"
    shared_parent_state.mkdir()
    os.chmod(shared_parent_state, 0o755)
    lock = make_lock(shared_parent_state)
    os.utime(lock, (old, old))
    shared_parent = shared_parent_state / "quarantine"
    shared_parent.mkdir(mode=0o755)
    os.chmod(shared_parent, 0o755)
    result = run(shared_parent_state, 0, "--registry")
    receipt = json.loads(result.stdout)
    assert Path(receipt["quarantined"]).is_dir()
    assert stat.S_IMODE(shared_parent.stat().st_mode) == 0o755
    print("PASS: existing owned 0755 quarantine parent is preserved and accepted")

    for unsafe_mode in (0o775, 0o777):
        unsafe_quarantine_state = Path(temp) / f"quarantine-{unsafe_mode:o}"
        unsafe_quarantine_state.mkdir()
        os.chmod(unsafe_quarantine_state, 0o755)
        lock = make_lock(unsafe_quarantine_state)
        os.utime(lock, (old, old))
        unsafe_parent = unsafe_quarantine_state / "quarantine"
        unsafe_parent.mkdir(mode=unsafe_mode)
        os.chmod(unsafe_parent, unsafe_mode)
        result = run(unsafe_quarantine_state, 1, "--registry")
        assert "quarantine directory is group- or world-writable" in result.stderr
        assert lock.is_dir()
    print("PASS: group- or world-writable quarantine parents (0775, 0777) remain fail-closed")

    unsafe_leaf_state = Path(temp) / "quarantine-leaf-mode-state"
    unsafe_leaf_state.mkdir()
    os.chmod(unsafe_leaf_state, 0o755)
    lock = make_lock(unsafe_leaf_state)
    os.utime(lock, (old, old))
    unsafe_leaf = unsafe_leaf_state / "quarantine" / "lease-locks"
    unsafe_leaf.mkdir(parents=True, mode=0o700)
    os.chmod(unsafe_leaf.parent, 0o755)
    os.chmod(unsafe_leaf, 0o755)
    result = run(unsafe_leaf_state, 1, "--registry")
    assert "lease-lock quarantine has unexpected mode 0755" in result.stderr
    assert lock.is_dir()
    print("PASS: existing lease-lock quarantine leaf must remain exactly 0700")

    partial_state = Path(temp) / "partial-state"
    partial_state.mkdir()
    os.chmod(partial_state, 0o755)
    lock = make_partial_lock(partial_state, 2147483647)
    os.utime(lock, (old, old))
    expected_bytes = partial_lock_bytes(lock)
    result = run(partial_state, 0, "--registry")
    receipt = json.loads(result.stdout)
    quarantined = Path(receipt["quarantined"])
    assert receipt["shape"] == "partial_pid_empty_acquired_at"
    assert {name: (quarantined / name).read_bytes() for name in expected_bytes} == expected_bytes
    stored = quarantined.with_name(quarantined.name + ".receipt.json")
    stored_record = json.loads(stored.read_text())
    assert stored_record["outcome"] == "quarantined"
    assert stored_record["metadata"]["acquired_at"]["size"] == 0
    print("PASS: exact old dead-pid/empty-timestamp lock is quarantined byte-for-byte")

    packaged_state = Path(temp) / "packaged-state"
    packaged_state.mkdir()
    os.chmod(packaged_state, 0o755)
    lock = make_partial_lock(packaged_state, 2147483647)
    os.utime(lock, (old, old))
    result = run(packaged_state, 0, "--registry", cli=PACKAGED_CLI)
    receipt = json.loads(result.stdout)
    quarantined = Path(receipt["quarantined"])
    assert partial_lock_bytes(quarantined) == {"pid": b"2147483647\n", "acquired_at": b""}
    print("PASS: packaged diskm dispatcher recovers the same exact partial-lock form")

    lock = make_partial_lock(state, os.getpid())
    os.utime(lock, (old, old))
    expected_bytes = partial_lock_bytes(lock)
    result = run(state, 1, "--registry")
    assert "pid is live" in result.stderr and partial_lock_bytes(lock) == expected_bytes
    shutil.rmtree(lock)
    print("PASS: old partial lock with a live pid remains fail-closed")

    lock = make_partial_lock(state, 2147483647)
    expected_bytes = partial_lock_bytes(lock)
    result = run(state, 1, "--registry")
    assert "too recent" in result.stderr and partial_lock_bytes(lock) == expected_bytes
    shutil.rmtree(lock)
    print("PASS: fresh partial lock remains fail-closed even with a dead pid")

    lock = make_partial_lock(state, 2147483647)
    (lock / "unexpected").write_text("unknown metadata\n")
    assert "unexpected metadata entries" in run(state, 1, "--registry").stderr
    shutil.rmtree(lock)
    print("PASS: partial lock with an extra entry remains fail-closed")

    lock = make_partial_lock(state, 2147483647)
    os.chmod(lock / "acquired_at", 0)
    run(state, 1, "--registry")
    assert lock.is_dir() and stat.S_IMODE((lock / "acquired_at").stat().st_mode) == 0
    shutil.rmtree(lock)
    print("PASS: unreadable-mode partial metadata remains fail-closed")

    for fifo_name in ("pid", "acquired_at"):
        fifo_state = Path(temp) / f"fifo-{fifo_name}"
        fifo_state.mkdir()
        os.chmod(fifo_state, 0o755)
        fifo_lock = make_partial_lock(fifo_state, 2147483647)
        fifo_path = fifo_lock / fifo_name
        fifo_path.unlink()
        os.mkfifo(fifo_path, 0o644)
        run_bounded(fifo_state, 1, "--registry")
        assert fifo_lock.is_dir() and stat.S_ISFIFO(fifo_path.stat().st_mode)
        run_bounded(fifo_state, 1, "--registry")
        shutil.rmtree(fifo_lock)
    print("PASS: FIFO metadata in both names is rejected without blocking or holding the guard")

    lock = make_partial_lock(state, 2147483647)
    (lock / "acquired_at").unlink()
    (lock / "acquired_at").symlink_to(lock / "pid")
    run(state, 1, "--registry")
    assert lock.is_dir() and (lock / "acquired_at").is_symlink()
    shutil.rmtree(lock)
    print("PASS: symlink partial metadata remains fail-closed")

    lock = make_partial_lock(state, 2147483647)
    (lock / "pid").write_bytes(b"0\n")
    assert "valid positive PID" in run(state, 1, "--registry").stderr and lock.is_dir()
    shutil.rmtree(lock)
    print("PASS: malformed partial pid remains fail-closed")

    lock = make_partial_lock(state, 2147483647)
    (lock / "acquired_at").write_bytes(b"1\n")
    os.utime(lock, (old, old))
    assert "acquired_at metadata is not empty" in run(state, 1, "--registry").stderr
    shutil.rmtree(lock)
    print("PASS: nonempty acquired_at remains fail-closed")

    lock = make_lock(state)
    old = time.time() - 7200
    os.utime(lock, (old, old))
    guard_path = state / MODULE.RECOVERY_LOCK_NAME
    guard_fd = os.open(guard_path, os.O_RDWR | os.O_CREAT, MODULE.RECOVERY_LOCK_MODE)
    os.chmod(guard_path, MODULE.RECOVERY_LOCK_MODE)
    fcntl.flock(guard_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        assert "guard is busy" in run(state, 1, "--registry").stderr and lock.is_dir()
    finally:
        fcntl.flock(guard_fd, fcntl.LOCK_UN)
        os.close(guard_fd)
    shutil.rmtree(lock)
    print("PASS: concurrent recovery invocation is blocked before source inspection")

    unsafe_state = Path(temp) / "unsafe-state"
    unsafe_state.mkdir()
    os.chmod(unsafe_state, 0o775)
    assert "unsafe recovery guard directory" in run(unsafe_state, 1, "--registry").stderr
    print("PASS: writable recovery guard parent remains fail-closed")

    for unsafe_mode in (0o775, 0o777):
        writable_leases_state = Path(temp) / f"leases-{unsafe_mode:o}"
        writable_leases_state.mkdir()
        os.chmod(writable_leases_state, 0o755)
        writable_leases = writable_leases_state / "worktree_leases"
        writable_leases.mkdir(mode=unsafe_mode)
        os.chmod(writable_leases, unsafe_mode)
        candidate = writable_leases / MODULE.LOCK_NAME
        candidate.mkdir(mode=0o755)
        old = time.time() - 7200
        os.utime(candidate, (old, old))
        result = run(writable_leases_state, 1, "--registry")
        assert "lease directory is group- or world-writable" in result.stderr
        assert candidate.is_dir()
    print("PASS: group- or world-writable lease parents (0775, 0777) remain fail-closed")

    lock = make_lock(state)
    (lock / "pid").write_text("123\n")
    old = time.time() - 7200
    os.utime(lock, (old, old))
    assert "unexpected metadata entries" in run(state, 1, "--registry").stderr and lock.is_dir()
    shutil.rmtree(lock)
    print("PASS: nonempty lock remains fail-closed")

    lock = make_lock(state)
    assert "too recent" in run(state, 1, "--registry").stderr and lock.is_dir()
    shutil.rmtree(lock)
    print("PASS: young empty lock remains fail-closed")

    lock = make_lock(state)
    old = time.time() - 7200
    os.utime(lock, (old, old))
    os.chmod(lock, 0o700)
    assert "unexpected mode" in run(state, 1, "--registry").stderr and lock.is_dir()
    shutil.rmtree(lock)
    print("PASS: unexpected-mode lock remains fail-closed")

    race_state = Path(temp) / "race-state"
    race_state.mkdir()
    os.chmod(race_state, 0o755)
    lock = make_lock(race_state)
    old = time.time() - 7200
    os.utime(lock, (old, old))
    def replace_lock() -> None:
        shutil.rmtree(lock)
        lock.mkdir(mode=0o755)
        os.chmod(lock, 0o755)
    original_hook = MODULE.before_revalidate
    original_state = os.environ.get("DISK_MAGICIAN_STATE_DIR")
    MODULE.before_revalidate = replace_lock
    os.environ["DISK_MAGICIAN_STATE_DIR"] = str(race_state)
    try:
        assert MODULE.main(["--registry"]) == 1
    finally:
        MODULE.before_revalidate = original_hook
        if original_state is None:
            os.environ.pop("DISK_MAGICIAN_STATE_DIR", None)
        else:
            os.environ["DISK_MAGICIAN_STATE_DIR"] = original_state
    assert lock.is_dir()
    receipts = list((race_state / "quarantine" / "lease-locks").glob("*.receipt.json"))
    assert len(receipts) == 1 and json.loads(receipts[0].read_text())["outcome"] == "deferred_identity_changed"
    print("PASS: replacement before rename is deferred and recorded")

    partial_race_state = Path(temp) / "partial-race-state"
    partial_race_state.mkdir()
    os.chmod(partial_race_state, 0o755)
    lock = make_partial_lock(partial_race_state, 2147483647)
    os.utime(lock, (old, old))
    original_bytes = partial_lock_bytes(lock)

    def alter_partial_metadata() -> None:
        (lock / "pid").write_bytes(b"2147483646\n")

    original_hook = MODULE.before_revalidate
    original_state = os.environ.get("DISK_MAGICIAN_STATE_DIR")
    MODULE.before_revalidate = alter_partial_metadata
    os.environ["DISK_MAGICIAN_STATE_DIR"] = str(partial_race_state)
    try:
        assert MODULE.main(["--registry"]) == 1
    finally:
        MODULE.before_revalidate = original_hook
        if original_state is None:
            os.environ.pop("DISK_MAGICIAN_STATE_DIR", None)
        else:
            os.environ["DISK_MAGICIAN_STATE_DIR"] = original_state
    assert lock.is_dir() and partial_lock_bytes(lock) != original_bytes
    receipts = list((partial_race_state / "quarantine" / "lease-locks").glob("*.receipt.json"))
    assert len(receipts) == 1
    assert json.loads(receipts[0].read_text())["outcome"] == "deferred_identity_changed"
    print("PASS: changed partial metadata bytes are preserved and recovery is deferred")

    pid_race_state = Path(temp) / "pid-race-state"
    pid_race_state.mkdir()
    os.chmod(pid_race_state, 0o755)
    lock = make_partial_lock(pid_race_state, 2147483647)
    os.utime(lock, (old, old))
    original_bytes = partial_lock_bytes(lock)
    pid_checks = [0]

    def pid_reused_after_first_check(_pid: int) -> bool:
        pid_checks[0] += 1
        return pid_checks[0] == 1

    original_hook = MODULE.before_revalidate
    original_pid_probe = MODULE.pid_is_dead
    original_state = os.environ.get("DISK_MAGICIAN_STATE_DIR")
    MODULE.before_revalidate = lambda: None
    MODULE.pid_is_dead = pid_reused_after_first_check
    os.environ["DISK_MAGICIAN_STATE_DIR"] = str(pid_race_state)
    try:
        assert MODULE.main(["--registry"]) == 1
    finally:
        MODULE.before_revalidate = original_hook
        MODULE.pid_is_dead = original_pid_probe
        if original_state is None:
            os.environ.pop("DISK_MAGICIAN_STATE_DIR", None)
        else:
            os.environ["DISK_MAGICIAN_STATE_DIR"] = original_state
    assert pid_checks[0] == 2 and lock.is_dir() and partial_lock_bytes(lock) == original_bytes
    receipts = list((pid_race_state / "quarantine" / "lease-locks").glob("*.receipt.json"))
    assert len(receipts) == 1
    assert json.loads(receipts[0].read_text())["outcome"] == "deferred_identity_changed"
    print("PASS: pid reused between liveness probes is preserved and recovery is deferred")

    def change_timestamp(fd: int) -> None:
        metadata_fd = os.open("acquired_at", os.O_WRONLY | os.O_TRUNC, dir_fd=fd)
        try:
            os.write(metadata_fd, b"1\n")
        finally:
            os.close(metadata_fd)

    for label, mutate in (
        ("changed-content", change_timestamp),
        ("unsafe-mode", lambda fd: os.chmod("acquired_at", 0, dir_fd=fd, follow_symlinks=False)),
    ):
        post_move_state = Path(temp) / f"post-move-{label}"
        post_move_state.mkdir()
        os.chmod(post_move_state, 0o755)
        post_move_lock = make_partial_lock(post_move_state, 2147483647)
        os.utime(post_move_lock, (old, old))
        original_after_rename = MODULE.after_quarantine_rename

        def mutate_after_rename(quarantine_fd: int, name: str, mutate=mutate) -> None:
            moved_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY, dir_fd=quarantine_fd)
            try:
                mutate(moved_fd)
            finally:
                os.close(moved_fd)

        MODULE.after_quarantine_rename = mutate_after_rename
        original_state = os.environ.get("DISK_MAGICIAN_STATE_DIR")
        os.environ["DISK_MAGICIAN_STATE_DIR"] = str(post_move_state)
        try:
            assert MODULE.main(["--registry"]) == 1
        finally:
            MODULE.after_quarantine_rename = original_after_rename
            if original_state is None:
                os.environ.pop("DISK_MAGICIAN_STATE_DIR", None)
            else:
                os.environ["DISK_MAGICIAN_STATE_DIR"] = original_state
        assert not post_move_lock.exists()
        receipts = list((post_move_state / "quarantine" / "lease-locks").glob("*.receipt.json"))
        assert len(receipts) == 1
        anomaly = json.loads(receipts[0].read_text())
        assert anomaly["outcome"] == "quarantine_identity_anomaly"
        assert anomaly["metadata"]["acquired_at"]["sha256"] == MODULE.hashlib.sha256(b"").hexdigest()
    print("PASS: post-rename content and unsafe-mode mutations retain anomaly receipts without rollback")

    lock = state / "worktree_leases" / ".owner-mutation.reuse-lock"
    target = state / "other"
    target.mkdir()
    lock.symlink_to(target, target_is_directory=True)
    run(state, 1, "--registry")
    assert lock.is_symlink()
    print("PASS: symlink lock remains fail-closed")

    # The canonical writer publishes two fields after mkdir. A signal or failed
    # metadata write in that window must remove only its newly acquired lock;
    # caller signal handlers must still receive the signal.
    writer_state = Path(temp) / "writer-setup-state"
    writer_lease_dir = writer_state / "worktree_leases"
    writer_lease_dir.mkdir(parents=True)
    writer_lease = writer_lease_dir / "fixture.json"
    writer_mark = Path(temp) / "caller-term-trap.txt"
    writer_case = Path(temp) / "lease-writer-setup-case.sh"
    writer_case.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
source "$LEASE_LIBRARY"
mode="$1"
lease="$2"
case "$mode" in
  normal)
    trap ':' TERM
    before="$(trap -p TERM)"
    lease_reuse_lock_acquire "$lease"
    after="$(trap -p TERM)"
    [[ "$before" == "$after" ]]
    lease_reuse_lock_release "$lease"
    [[ ! -e "$lease.reuse-lock" ]]
    ;;
  write-fail)
    printf() {
      if [[ "${LEASE_TEST_FAIL_ACQUIRED_WRITE:-0}" == "1" && "$BASH_COMMAND" == *"acquired_at"* ]]; then
        LEASE_TEST_FAIL_ACQUIRED_WRITE=0
        return 1
      fi
      builtin printf "$@"
    }
    if lease_reuse_lock_acquire "$lease"; then exit 99; fi
    [[ ! -e "$lease.reuse-lock" ]]
    ;;
  term)
    trap 'builtin printf "TERM delivered\n" > "$LEASE_TEST_TRAP_MARK"; exit 42' TERM
    LEASE_TEST_TARGET_PID="$$"
    date() {
      if [[ "${1:-}" == "+%s" ]]; then
        builtin printf '1793220000\n'
        kill -TERM "$LEASE_TEST_TARGET_PID"
        return 0
      fi
      command date "$@"
    }
    lease_reuse_lock_acquire "$lease"
    exit 99
    ;;
  term-return-retry)
    trap 'builtin printf "TERM handled\n" >> "$LEASE_TEST_TRAP_MARK"' TERM
    LEASE_TEST_TARGET_PID="$$"
    date() {
      if [[ "${1:-}" == "+%s" && ! -e "$LEASE_TEST_DATE_SENT" ]]; then
        : > "$LEASE_TEST_DATE_SENT"
        builtin printf '1793220000\n'
        kill -TERM "$LEASE_TEST_TARGET_PID"
        return 0
      fi
      command date "$@"
    }
    if lease_reuse_lock_acquire "$lease"; then first_rc=0; else first_rc=$?; fi
    if lease_reuse_lock_acquire "$lease"; then second_rc=0; else second_rc=$?; fi
    builtin printf 'first=%s second=%s\n' "$first_rc" "$second_rc"
    lease_reuse_lock_release "$lease"
    [[ "$first_rc" == 1 && "$second_rc" == 0 ]]
    ;;
  *) exit 2 ;;
esac
''')
    writer_env = {
        **os.environ,
        "DISK_MAGICIAN_STATE_DIR": str(writer_state),
        "LEASE_LIBRARY": str(ROOT / "scripts/lib/worktree_lease.sh"),
        "BASH_ENV": "",
    }
    normal_writer = subprocess.run(
        ["bash", str(writer_case), "normal", str(writer_lease)],
        env=writer_env, text=True, capture_output=True, check=False,
    )
    assert normal_writer.returncode == 0, (normal_writer.stdout, normal_writer.stderr)
    assert not Path(str(writer_lease) + ".reuse-lock").exists()
    print("PASS: normal setup/release leaves no lock and preserves the caller TERM trap")

    write_error_env = {**writer_env, "LEASE_TEST_FAIL_ACQUIRED_WRITE": "1"}
    write_error = subprocess.run(
        ["bash", str(writer_case), "write-fail", str(writer_lease)],
        env=write_error_env, text=True, capture_output=True, check=False,
    )
    assert write_error.returncode == 0, (write_error.stdout, write_error.stderr)
    assert not Path(str(writer_lease) + ".reuse-lock").exists()
    print("PASS: acquired_at write failure removes only the newly acquired lock")

    interrupted_env = {**writer_env, "LEASE_TEST_TRAP_MARK": str(writer_mark)}
    interrupted = subprocess.run(
        ["bash", str(writer_case), "term", str(writer_lease)],
        env=interrupted_env, text=True, capture_output=True, check=False,
    )
    assert interrupted.returncode == 42, (interrupted.returncode, interrupted.stdout, interrupted.stderr)
    assert writer_mark.read_text() == "TERM delivered\n"
    assert not Path(str(writer_lease) + ".reuse-lock").exists()
    print("PASS: TERM between pid and acquired_at cleans the lock then runs the caller trap")
    retry_lease = writer_lease_dir / "retry.json"
    retry_mark = Path(temp) / "caller-term-retry.txt"
    retry_date_sent = Path(temp) / "retry-date-sent.txt"
    retry_env = {
        **writer_env,
        "LEASE_TEST_TRAP_MARK": str(retry_mark),
        "LEASE_TEST_DATE_SENT": str(retry_date_sent),
    }
    retry = subprocess.run(
        ["bash", str(writer_case), "term-return-retry", str(retry_lease)],
        env=retry_env, text=True, capture_output=True, check=False,
    )
    assert retry.returncode == 0, (retry.returncode, retry.stdout, retry.stderr)
    assert retry.stdout.strip() == "first=1 second=0", (retry.stdout, retry.stderr)
    assert retry_mark.read_text() == "TERM handled\n"
    assert not Path(str(retry_lease) + ".reuse-lock").exists()
    print("PASS: a returning caller TERM trap does not poison the next acquisition")


# Full-lifetime regressions use only isolated HOME/state and controllable children.
def test_writer_critical_sections():
    import signal
    import sys

    artifact_root = os.environ.get('DISKM_TEST_ARTIFACT_DIR') or os.environ.get('CLAUDE_CODE_TMPDIR') or os.environ.get('DISKM_SCRATCH') or os.environ.get('RUNNER_TEMP')
    temp = Path(tempfile.mkdtemp(prefix='lock-scope-', dir=artifact_root))
    library = ROOT / 'scripts/lib/worktree_lease.sh'
    quarantine = ROOT / 'scripts/lib/quarantine.sh'
    records = []

    def fixture(name, body, *, ttl='24', trap=''):
        home = temp / name
        home.mkdir()
        (home / 'candidate').mkdir()
        (home / 'bin').mkdir()
        real_python = str(Path(sys.executable).resolve())
        shim = home / 'bin/python3'
        shim.write_text('#!' + real_python + '\n' + r'''
import os, pathlib, sys, time
home = pathlib.Path(os.environ['HOME'])
writer = sys.argv[1:2] == ['-'] and len(sys.argv) > 2 and sys.argv[2] == os.environ.get('LEASE_TEST_LEASE')
rename = len(sys.argv) > 2 and sys.argv[1].endswith('/quarantine_rename.py') and sys.argv[2] == 'remove'
if (writer and os.environ.get('BLOCK_WRITER')) or (rename and os.environ.get('BLOCK_RENAME')):
    stage = 'writer' if writer else 'rename'
    (home / (stage + '-ready')).touch()
    while not (home / (stage + '-go')).exists(): time.sleep(.01)
os.execv(os.environ['REAL_PYTHON'], [os.environ['REAL_PYTHON'], *sys.argv[1:]])
''')
        shim.chmod(0o755)
        script = home / 'case.sh'
        script.write_text('set -euo pipefail\nsource "' + str(quarantine) + '"\n' + trap + '\n' + body + '\n')
        env = {**os.environ, 'HOME': str(home), 'PATH': str(home / 'bin') + ':/usr/bin:/bin:/usr/sbin',
               'DISK_MAGICIAN_STATE_DIR': str(home / 'state'), 'DISK_MAGICIAN_LEASE_TTL_HOURS': ttl,
               'DISK_MAGICIAN_CONFIG': str(home / 'config.json'), 'BASH_ENV': '', 'REAL_PYTHON': real_python}
        result = subprocess.run(['bash', '-c', 'source "$1"; lease_path_for "$HOME/candidate"', 'bash', str(library)],
                                env=env, text=True, capture_output=True, check=True)
        env['LEASE_TEST_LEASE'] = result.stdout.strip()
        return home, env, script

    def start(env, script):
        return subprocess.Popen(['bash', str(script)], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def wait_ready(home, stage):
        limit = time.monotonic() + 8
        while not (home / (stage + '-ready')).exists():
            assert time.monotonic() < limit, (home, stage)
            time.sleep(.01)

    def locks(home):
        return sorted((home / 'state/worktree_leases').glob('*.reuse-lock'))

    def finish(name, home, p, expected):
        out, err = p.communicate(timeout=12)
        record = {'case': name, 'returncode': p.returncode, 'stdout': out, 'stderr': err,
                  'locks': {str(lock): {f.name: f.read_text() for f in lock.iterdir()} for lock in locks(home)}}
        records.append(record)
        (temp / 'results.json').write_text(json.dumps(records, indent=2))
        assert p.returncode == expected, record
        return record

    def contender(home, env):
        p = subprocess.run(['bash', '-c', 'source "$1"; lease_write "$HOME/other" --kind scratch',
                            'bash', str(library)], env=env, text=True, capture_output=True, timeout=4)
        assert p.returncode == 1, (p.returncode, p.stdout, p.stderr)
        assert (home / 'state/worktree_leases/.owner-mutation.reuse-lock').is_dir()

    for name, body, expected in (
        ('bare-error', 'lease_write "$HOME/candidate" --kind scratch', 1),
        ('guarded-error', 'if ! lease_write "$HOME/candidate" --kind scratch; then exit 2; fi', 2),
        ('pending-error', 'lease_write_pending "$HOME/missing" "-\t-\t-"', 1),
    ):
        home, env, script = fixture(name, body, ttl='invalid')
        finish(name, home, start(env, script), expected)
        assert not locks(home), name
        print('PASS: ' + name + ' releases all acquired locks under set -e')

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        name = 'writer-' + signal.Signals(signum).name
        trap = '''trap 'rc=$?; [[ ! -d "$DISK_MAGICIAN_STATE_DIR/worktree_leases/.owner-mutation.reuse-lock" ]]; printf "exit:%s\\n" "$rc" >> "$HOME/traps"' EXIT
trap '[[ ! -d "$DISK_MAGICIAN_STATE_DIR/worktree_leases/.owner-mutation.reuse-lock" ]]; printf "signal\\n" >> "$HOME/traps"; exit 42' ''' + signal.Signals(signum).name
        home, env, script = fixture(name, 'lease_write "$HOME/candidate" --kind scratch', trap=trap)
        env['BLOCK_WRITER'] = '1'
        p = start(env, script)
        wait_ready(home, 'writer')
        assert len(locks(home)) == 2
        p.send_signal(signum)
        time.sleep(.1)
        assert p.poll() is None and len(locks(home)) == 2
        contender(home, env)
        (home / 'writer-go').touch()
        finish(name, home, p, 42)
        assert not locks(home) and Path(env['LEASE_TEST_LEASE']).is_file()
        assert (home / 'traps').read_text() == 'signal\nexit:42\n'
        print('PASS: ' + name + ' waits for writing child, releases, then delivers caller signal and EXIT')

    dispositions = []
    for sig in ('HUP', 'INT', 'TERM'):
        dispositions.extend((
            ('ignored-' + sig, "trap '' " + sig, 0),
            ('returning-' + sig, "trap 'rc=$?; printf handled >> \"$HOME/traps\"' " + sig, 0),
        ))
    for name, trap, expected in dispositions:
        body = '''before="$(trap -p TERM)"
if lease_write "$HOME/candidate" --kind scratch; then rc=0; else rc=$?; fi
[[ "$before" == "$(trap -p TERM)" ]]
'''
        body += '[[ "$rc" == 0 ]]' if name.startswith('ignored-') else '''[[ "$rc" == 1 ]]
lease_write "$HOME/candidate" --kind scratch'''
        home, env, script = fixture(name, body, trap=trap)
        env['BLOCK_WRITER'] = '1'
        p = start(env, script)
        wait_ready(home, 'writer'); p.send_signal(getattr(signal, 'SIG' + name.split('-')[1])); time.sleep(.1)
        assert p.poll() is None and len(locks(home)) == 2
        (home / 'writer-go').touch()
        finish(name, home, p, expected)
        assert not locks(home)
        if name.startswith('returning-'): assert (home / 'traps').read_text() == 'handled'
        print('PASS: ' + name + ' retains disposition and permits a fresh acquisition')

    verdict = r'''artifact_removal_verdict() {
python3 -c 'import json,os,pathlib,sys,time
p,out=sys.argv[1:]; s=os.lstat(p)
json.dump([{"path":".","dev":s.st_dev,"ino":s.st_ino,"type":"dir"}],open(out,"w"))
h=pathlib.Path(os.environ["HOME"]); (h/"verdict-ready").touch()
while not (h/"verdict-go").exists(): time.sleep(.01)
print("remove")' "$1" "$3"
}
quarantine_remove "$HOME/candidate"'''
    home, env, script = fixture('c14-term', verdict)
    env['BLOCK_RENAME'] = '1'
    p = start(env, script)
    wait_ready(home, 'verdict'); p.terminate(); time.sleep(.1)
    assert p.poll() is None and len(locks(home)) == 1
    contender(home, env)
    (home / 'verdict-go').touch()
    wait_ready(home, 'rename')
    assert p.poll() is None and len(locks(home)) == 1 and (home / 'candidate').is_dir()
    contender(home, env)
    (home / 'rename-go').touch()
    finish('c14-term', home, p, -signal.SIGTERM)
    assert not locks(home) and not (home / 'candidate').exists()
    print('PASS: TERM during C14 verdict retains registry serialization through rename, then cleans')

    body = r'''(lease_write "$HOME/candidate" --kind scratch)
[[ ! -e "$HOME/exits" ]]
( trap 'printf child >> "$HOME/exits"' EXIT; lease_write "$HOME/candidate" --kind scratch )
[[ "$(cat "$HOME/exits")" == child ]]'''
    home, env, script = fixture('caller-subshell-traps', body,
                                trap="trap 'printf parent >> \"$HOME/exits\"' EXIT")
    finish('caller-subshell-traps', home, start(env, script), 0)
    assert not locks(home) and (home / 'exits').read_text() == 'childparent'
    print('PASS: inactive inherited EXIT remains inactive; locally installed child and parent EXIT each run once')

    body = r'''outer() {
  lease_mutation_lock_enter "$LEASE_TEST_LEASE" || return 1
  nested() { lease_write "$HOME/candidate" --kind scratch --lock-held; }
  value="$(nested)" || return 1
  if value="$(lease_reuse_lock_release "$LEASE_TEST_LEASE")"; then return 1; fi
  ( _lease_lock_scope release nested ) || return 1
  doomed() { exit 7; }
  if value="$(_lease_lock_scope release doomed)"; then return 1; else [[ $? == 7 ]] || return 1; fi
  [[ -d "$LEASE_TEST_LEASE.reuse-lock" && -d "$(lease_dir)/.owner-mutation.reuse-lock" ]]
}
_lease_lock_scope release outer'''
    home, env, script = fixture('nested', body)
    finish('nested', home, start(env, script), 0)
    assert not locks(home)
    print('PASS: nested substitutions, subshells and --lock-held writes never release outer locks')

    for status in (0, 7):
        body = 'probe() { lease_registry_mutation_lock_enter || return 1; exit ' + str(status) + '; }; _lease_lock_scope release probe'
        trap = '''trap 'rc=$?; [[ ! -d "$DISK_MAGICIAN_STATE_DIR/worktree_leases/.owner-mutation.reuse-lock" ]]; printf "%s\\n" "$rc" >> "$HOME/exit-status"' EXIT'''
        name = 'explicit-exit-' + str(status)
        home, env, script = fixture(name, body, trap=trap)
        finish(name, home, start(env, script), status)
        assert not locks(home) and (home / 'exit-status').read_text() == str(status) + '\n'
        print('PASS: ' + name + ' cleans before caller EXIT and preserves $?')

    body = r'''outer() {
lease_mutation_lock_enter "$LEASE_TEST_LEASE" || return 1
nested() {
  printf '%s\n' "${BASHPID:-$(exec sh -c 'echo "$PPID"')}" > "$HOME/child-pid"
  lease_write "$HOME/candidate" --kind scratch --lock-held
}
if value="$(nested)"; then return 1; else [[ $? == 143 ]] || return 1; fi
[[ -d "$LEASE_TEST_LEASE.reuse-lock" && -d "$(lease_dir)/.owner-mutation.reuse-lock" ]]
}
_lease_lock_scope release outer'''
    home, env, script = fixture('nested-term', body)
    env['BLOCK_WRITER'] = '1'
    p = start(env, script); wait_ready(home, 'writer')
    os.kill(int((home / 'child-pid').read_text()), signal.SIGTERM)
    time.sleep(.1)
    assert p.poll() is None and len(locks(home)) == 2
    (home / 'writer-go').touch()
    finish('nested-term', home, p, 0)
    assert not locks(home)
    print('PASS: nested TERM re-delivers to the child, never cleans or signals the parent')

    body = r'''probe() {
lease_registry_mutation_lock_enter || return 1
lock="$(lease_dir)/.owner-mutation.reuse-lock"
mv "$lock" "$HOME/owned-lock"
mkdir "$lock"
printf '%s\n' "$$" > "$lock/pid"
printf '%s\n' 1793220000 > "$lock/acquired_at"
}
_lease_lock_scope release probe'''
    home, env, script = fixture('replacement', body)
    finish('replacement', home, start(env, script), 0)
    assert len(locks(home)) == 1 and (home / 'owned-lock/pid').is_file()
    print('PASS: scope cleanup preserves replacement lock identity and original moved lock')

    body = r'''probe() {
lease_registry_mutation_lock_enter || return 1
: > "$(lease_dir)/.owner-mutation.reuse-lock/acquired_at"
}
_lease_lock_scope release probe'''
    home, env, script = fixture('changed-metadata', body)
    finish('changed-metadata', home, start(env, script), 0)
    assert len(locks(home)) == 1 and (locks(home)[0] / 'acquired_at').read_text() == ''
    print('PASS: full acquired lock with changed metadata is preserved, even on the same directory inode')

    home, env, script = fixture('sigkill', 'lease_write "$HOME/candidate" --kind scratch')
    env['BLOCK_WRITER'] = '1'
    p = start(env, script); wait_ready(home, 'writer')
    p.kill(); p.wait(timeout=5)
    for lock in locks(home):
        assert (lock / 'pid').read_text().strip() == str(p.pid)
        assert (lock / 'acquired_at').read_text().strip().isdigit()
    assert len(locks(home)) == 2
    (home / 'writer-go').touch()
    finish('sigkill', home, p, -signal.SIGKILL)
    assert Path(env['LEASE_TEST_LEASE']).is_file()
    contender(home, env)
    for lock in locks(home):
        lease = str(lock)[:-len('.reuse-lock')]
        for age, expected in ((3590, 1), (3610, 0)):
            (lock / 'acquired_at').write_text(str(int(time.time()) - age) + '\n')
            result = subprocess.run(['bash', '-c', 'source "$1"; [[ "$LEASE_REUSE_LOCK_TTL_SEC" == 3600 ]]; lease_reuse_lock_recover "$2"',
                                     'bash', str(library), lease], env=env, text=True, capture_output=True, timeout=5)
            assert result.returncode == expected, (age, result.stdout, result.stderr)
    assert not locks(home)
    print('PASS: SIGKILL retains full lock shape and existing dead-PID 3600-second recovery')
    print('Critical-section artifacts: ' + str(temp))


test_writer_critical_sections()
