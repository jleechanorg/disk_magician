#!/usr/bin/env python3
"""Quarantine a stale empty or exactly partial lease-registry lock without deleting it.

The canonical writer (`lease_reuse_lock_acquire` in lib/worktree_lease.sh)
creates the lock directory with mkdir and writes pid/acquired_at only after
mkdir succeeds. A pre-existing partial directory therefore is not a normal
writer interruption; only its separately guarded stale-lock recovery can
remove/recreate one. This recovery relies on that writer contract plus a
private-enough lease parent, while still revalidating the observed inode and
metadata immediately before rename. It does not provide an atomic compare-and-
rename against arbitrary same-UID mutation. A post-rename identity anomaly
receipt records the pre-rename snapshot and anomaly outcome; it does not prove
the moved entry remained unchanged during the rename window.
"""

from __future__ import annotations

from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import uuid


LOCK_NAME = ".owner-mutation.reuse-lock"
LOCK_TTL_SECONDS = 3600
LOCK_MODE = 0o755
METADATA_MODE = 0o644
RECOVERY_LOCK_NAME = "lease-recover-lock.lock"
RECOVERY_LOCK_MODE = 0o600


def fail(message: str, code: int = 1) -> int:
    print(f"lease-recover-lock: {message}", file=sys.stderr)
    return code


def lstat_directory(path: Path, label: str, mode: int | None = None) -> os.stat_result:
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"{label} is not a real directory")
    if info.st_uid != os.geteuid():
        raise ValueError(f"{label} is not owned by the current user")
    if mode is not None and stat.S_IMODE(info.st_mode) != mode:
        raise ValueError(f"{label} has unexpected mode {stat.S_IMODE(info.st_mode):04o}")
    return info


def acquire_recovery_lock(state: Path) -> tuple[int | None, int]:
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    dir_fd = os.open(state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parent = os.fstat(dir_fd)
        if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or
                parent.st_mode & 0o022):
            raise PermissionError("unsafe recovery guard directory")
        fd = os.open(RECOVERY_LOCK_NAME, flags, RECOVERY_LOCK_MODE, dir_fd=dir_fd)
    except Exception:
        os.close(dir_fd)
        raise
    try:
        current = os.fstat(fd)
        if (not stat.S_ISREG(current.st_mode) or current.st_uid != os.geteuid() or
                stat.S_IMODE(current.st_mode) != RECOVERY_LOCK_MODE or
                current.st_nlink != 1):
            raise ValueError("recovery guard is not an owned private regular file")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return None, dir_fd
        return fd, dir_fd
    except Exception:
        os.close(fd)
        os.close(dir_fd)
        raise


def stat_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev, info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode),
        info.st_size, info.st_nlink, info.st_mtime_ns, info.st_ctime_ns,
    )


def rename_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev, info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode),
        info.st_size, info.st_nlink, info.st_mtime_ns,
    )


def open_owned_directory(parent_fd: int, name: str, label: str, mode: int | None = None) -> tuple[int, os.stat_result]:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(name, flags, dir_fd=parent_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
            raise ValueError(f"{label} is not an owned real directory")
        if mode is not None and stat.S_IMODE(info.st_mode) != mode:
            raise ValueError(f"{label} has unexpected mode {stat.S_IMODE(info.st_mode):04o}")
        return fd, info
    except Exception:
        os.close(fd)
        raise


def read_metadata(lock_fd: int, name: str) -> tuple[os.stat_result, bytes]:
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    initial = os.stat(name, dir_fd=lock_fd, follow_symlinks=False)
    if (not stat.S_ISREG(initial.st_mode) or initial.st_uid != os.geteuid() or
            stat.S_IMODE(initial.st_mode) != METADATA_MODE or initial.st_nlink != 1 or
            initial.st_size > 64):
        raise ValueError(f"registry lock metadata {name} has unsafe type, owner, mode, links, or size")
    fd = os.open(name, flags, dir_fd=lock_fd)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or
                stat.S_IMODE(info.st_mode) != METADATA_MODE or info.st_nlink != 1 or info.st_size > 64):
            raise ValueError(f"registry lock metadata {name} has unsafe type, owner, mode, links, or size")
        content = bytearray()
        while len(content) <= 64:
            chunk = os.read(fd, 65 - len(content))
            if not chunk:
                break
            content.extend(chunk)
        after = os.fstat(fd)
        if len(content) > 64 or len(content) != info.st_size or stat_identity(after) != stat_identity(info):
            raise ValueError(f"registry lock metadata {name} changed while reading")
        return after, bytes(content)
    finally:
        os.close(fd)


def lock_snapshot(lock_fd: int) -> dict:
    names = sorted(os.listdir(lock_fd))
    if not names:
        return {"shape": "empty", "members": {}}
    if names == ["pid"]:
        # The canonical writer creates pid and writes it before creating
        # acquired_at, so a lone EMPTY pid is the same interruption class as an
        # empty lock: nothing identifies a holder and no timestamp exists yet.
        # A non-empty lone pid is not a writer shape and stays refused.
        info, content = read_metadata(lock_fd, "pid")
        if content:
            raise ValueError("registry lock pid-only metadata is not empty")
        return {"shape": "partial_pid_only_empty",
                "members": {"pid": {"identity": stat_identity(info), "bytes": content}}}
    if names != ["acquired_at", "pid"]:
        raise ValueError("registry lock has unexpected metadata entries")
    members = {}
    for name in names:
        info, content = read_metadata(lock_fd, name)
        if name == "acquired_at" and content:
            raise ValueError("registry lock acquired_at metadata is not empty")
        members[name] = {"identity": stat_identity(info), "bytes": content}
    raw_pid = members["pid"]["bytes"]
    if not re.fullmatch(rb"([1-9][0-9]{0,9})\n?", raw_pid):
        raise ValueError("registry lock pid metadata is not a valid positive PID")
    pid = int(raw_pid.rstrip(b"\n"))
    if pid > 2**31 - 1:
        raise ValueError("registry lock pid metadata exceeds the supported PID range")
    members["pid"]["value"] = pid
    return {"shape": "partial_pid_empty_acquired_at", "members": members}


def pid_is_dead(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except OSError:
        return False
    return False


def lock_is_same(lock_fd: int, expected: os.stat_result, expected_snapshot: dict) -> bool:
    try:
        current = os.fstat(lock_fd)
        if stat_identity(current) != stat_identity(expected) or lock_snapshot(lock_fd) != expected_snapshot:
            return False
        return True
    except (OSError, ValueError):
        return False


def lock_entry_is_same(leases_fd: int, name: str, expected: os.stat_result) -> bool:
    try:
        current = os.stat(name, dir_fd=leases_fd, follow_symlinks=False)
        return stat_identity(current) == stat_identity(expected)
    except OSError:
        return False


def path_entry_absent(dir_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return True
    return False


def before_revalidate() -> None:
    """Test seam; production intentionally has no intervening mutation."""


def after_quarantine_rename(quarantine_fd: int, name: str) -> None:
    """Test seam; production intentionally has no intervening mutation."""


def write_record_at(dir_fd: int, name: str, record: dict) -> None:
    temporary = f".{name}.{uuid.uuid4().hex}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(temporary, flags, 0o600, dir_fd=dir_fd)
    try:
        os.fchmod(fd, 0o600)
        payload = (json.dumps(record, indent=2) + "\n").encode("utf-8")
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            if not written:
                raise OSError("short write while creating quarantine receipt")
            view = view[written:]
        os.fsync(fd)
    except Exception:
        os.close(fd)
        try:
            os.unlink(temporary, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
        raise
    else:
        os.close(fd)
    try:
        os.link(temporary, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
    finally:
        try:
            os.unlink(temporary, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
    os.fsync(dir_fd)


def ensure_private_directory(parent_fd: int, name: str, label: str, mode: int | None = 0o700) -> tuple[int, os.stat_result]:
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    return open_owned_directory(parent_fd, name, label, mode)


def create_pending_receipt(dir_fd: int, pending: str, receipt: str, record: dict) -> None:
    write_record_at(dir_fd, pending, record)
    os.link(pending, receipt, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
    os.unlink(pending, dir_fd=dir_fd)
    os.fsync(dir_fd)


def main(argv: list[str]) -> int:
    if argv != ["--registry"]:
        return fail("usage: diskm lease-recover-lock --registry", 2)

    state = Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", str(Path.home() / ".disk_magician_state"))).expanduser()
    guard = state_fd = leases_fd = lock_fd = quarantine_parent_fd = quarantine_fd = None
    try:
        lstat_directory(state, "state directory")
        guard, state_fd = acquire_recovery_lock(state)
    except (OSError, ValueError) as exc:
        return fail(str(exc))
    try:
        if guard is None:
            return fail("recovery guard is busy")
        leases_fd, leases_info = open_owned_directory(state_fd, "worktree_leases", "lease directory")
        if leases_info.st_mode & 0o022:
            raise ValueError("lease directory is group- or world-writable")
        lock_fd, info = open_owned_directory(leases_fd, LOCK_NAME, "registry lock", LOCK_MODE)
        snapshot = lock_snapshot(lock_fd)
        pid = snapshot["members"]["pid"]["value"] if snapshot["shape"] == "partial_pid_empty_acquired_at" else None
        age_seconds = time.time() - info.st_mtime
        if age_seconds <= LOCK_TTL_SECONDS:
            return fail(f"registry lock is too recent ({age_seconds:.0f}s <= {LOCK_TTL_SECONDS}s)")
        if pid is not None and not pid_is_dead(pid):
            return fail("registry lock pid is live or cannot be validated dead")

        quarantine_parent_fd, quarantine_parent_info = ensure_private_directory(
            state_fd, "quarantine", "quarantine directory", mode=None)
        if quarantine_parent_info.st_mode & 0o022:
            raise ValueError("quarantine directory is group- or world-writable")
        quarantine_fd, _ = ensure_private_directory(quarantine_parent_fd, "lease-locks", "lease-lock quarantine")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        quarantined_name = f"{stamp}-{info.st_dev}-{info.st_ino}-{uuid.uuid4().hex}-{LOCK_NAME}"
        receipt_name = f"{quarantined_name}.receipt.json"
        pending_name = f".pending-{uuid.uuid4().hex}.json"
        lock_path = state / "worktree_leases" / LOCK_NAME
        quarantine_path = state / "quarantine" / "lease-locks" / quarantined_name
        metadata = {
            name: {"sha256": hashlib.sha256(member["bytes"]).hexdigest(),
                   "size": len(member["bytes"]),
                   "mode": f"{member['identity'][3]:04o}"}
            for name, member in snapshot["members"].items()
        }
        record = {
            "schema_version": 2,
            "action": "quarantine_stale_registry_lock",
            "shape": snapshot["shape"],
            "source": str(lock_path),
            "quarantined": str(quarantine_path),
            "recovered_at": datetime.now(timezone.utc).isoformat(),
            "lock_identity": {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid,
                              "mode": f"{stat.S_IMODE(info.st_mode):04o}"},
            "metadata": metadata,
            "age_seconds": round(age_seconds, 3),
            "ttl_seconds": LOCK_TTL_SECONDS,
        }
        before_revalidate()
        if (not lock_entry_is_same(leases_fd, LOCK_NAME, info) or
                not lock_is_same(lock_fd, info, snapshot) or
                (pid is not None and not pid_is_dead(pid))):
            record["outcome"] = "deferred_identity_changed"
            create_pending_receipt(quarantine_fd, pending_name, receipt_name, record)
            return fail("registry lock changed before quarantine; deferred with receipt")
        if not path_entry_absent(quarantine_fd, quarantined_name) or not path_entry_absent(quarantine_fd, receipt_name):
            record["outcome"] = "deferred_destination_exists"
            create_pending_receipt(quarantine_fd, pending_name, receipt_name, record)
            return fail("quarantine destination already exists; deferred with receipt")
        os.rename(LOCK_NAME, quarantined_name, src_dir_fd=leases_fd, dst_dir_fd=quarantine_fd)
        after_quarantine_rename(quarantine_fd, quarantined_name)
        moved_fd = None
        try:
            moved_fd, moved = open_owned_directory(quarantine_fd, quarantined_name, "quarantined registry lock", LOCK_MODE)
            preserved = rename_identity(moved) == rename_identity(info) and lock_snapshot(moved_fd) == snapshot
        except (OSError, ValueError) as exc:
            record["outcome"] = "quarantine_identity_anomaly"
            record["error"] = str(exc)
            create_pending_receipt(quarantine_fd, pending_name, receipt_name, record)
            return fail(f"quarantined lock validation failed; retained anomaly receipt: {exc}")
        finally:
            if moved_fd is not None:
                os.close(moved_fd)
        if not preserved:
            record["outcome"] = "quarantine_identity_anomaly"
            create_pending_receipt(quarantine_fd, pending_name, receipt_name, record)
            return fail("quarantined lock identity changed; retained anomaly receipt")
        record["outcome"] = "quarantined"
        create_pending_receipt(quarantine_fd, pending_name, receipt_name, record)
        print(json.dumps(record, sort_keys=True))
        return 0
    except (OSError, ValueError) as exc:
        return fail(f"quarantine operation failed: {exc}")
    finally:
        for fd in (lock_fd, leases_fd, quarantine_fd, quarantine_parent_fd, guard, state_fd):
            if fd is not None:
                os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
