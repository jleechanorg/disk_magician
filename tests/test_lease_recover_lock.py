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


with tempfile.TemporaryDirectory(prefix="lease-recover-lock-", dir="/tmp") as temp:
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
