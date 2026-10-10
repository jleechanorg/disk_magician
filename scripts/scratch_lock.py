#!/usr/bin/env python3
"""Kernel-backed serialization for destructive scratch cleanup entrypoints."""

from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import stat
import sys


ENV_FD = "DISK_MAGICIAN_SCRATCH_LOCK_FD"
ENV_PID = "DISK_MAGICIAN_SCRATCH_LOCK_PID"


def lock_path() -> Path:
    state_dir = os.environ.get("DISK_MAGICIAN_STATE_DIR", "").strip()
    if not state_dir:
        home = os.environ.get("HOME", "")
        if not home or not Path(home).is_absolute():
            raise PermissionError("unsafe HOME for scratch lock")
        home_stat = os.lstat(home)
        if not stat.S_ISDIR(home_stat.st_mode) or home_stat.st_uid != os.geteuid() or home_stat.st_mode & 0o022:
            raise PermissionError("unsafe HOME for scratch lock")
        state_dir = str(Path(home) / ".disk_magician_locks")
    return Path(state_dir).expanduser() / "scratch_cleanup.lock"


def open_lock(path: Path, create: bool) -> int:
    if create:
        old_umask = os.umask(0)
        try:
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        finally:
            os.umask(old_umask)
    dir_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parent = os.fstat(dir_fd)
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or parent.st_mode & 0o077:
            raise PermissionError("unsafe scratch lock directory")
        flags = os.O_RDWR | os.O_NOFOLLOW
        if create:
            flags |= os.O_CREAT
        fd = os.open(path.name, flags, 0o600, dir_fd=dir_fd)
        try:
            opened = os.fstat(fd)
            if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid() or opened.st_mode & 0o077:
                raise PermissionError("unsafe scratch lock file")
            return fd
        except BaseException:
            os.close(fd)
            raise
    finally:
        os.close(dir_fd)


def verify_fd(fd: int) -> bool:
    try:
        canonical_fd = open_lock(lock_path(), create=False)
        try:
            opened = os.fstat(fd)
            canonical = os.fstat(canonical_fd)
        finally:
            os.close(canonical_fd)
        if (opened.st_dev, opened.st_ino) != (canonical.st_dev, canonical.st_ino):
            return False
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except (OSError, ValueError):
        return False


def run(caller: str, script: str, args: list[str]) -> int:
    path = lock_path()
    try:
        fd = open_lock(path, create=True)
    except OSError as exc:
        print(f"[{caller}] failed to open scratch lock {path}: {exc}", file=sys.stderr)
        return 1

    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, OSError) as exc:
        os.close(fd)
        if isinstance(exc, BlockingIOError):
            print(f"[{caller}] skipped, scratch lock held — not queuing", file=sys.stderr)
        else:
            print(f"[{caller}] failed to acquire scratch lock {path}: {exc}", file=sys.stderr)
        return 1

    os.set_inheritable(fd, True)
    os.environ[ENV_FD] = str(fd)
    os.environ[ENV_PID] = str(os.getpid())
    os.execvpe(script, [script, *args], os.environ)
    return 127


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "run":
        try:
            caller = sys.argv[sys.argv.index("--caller") + 1]
            script = sys.argv[sys.argv.index("--script") + 1]
            marker = sys.argv.index("--args")
            args = sys.argv[marker + 1 :]
            if args[:1] == ["--"]:
                args = args[1:]
        except (ValueError, IndexError):
            print("scratch_lock.py: invalid run arguments", file=sys.stderr)
            return 2
        return run(caller, script, args)

    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("--fd", type=int, required=True)
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--caller", required=True)
    run_parser.add_argument("--script", required=True)
    run_parser.add_argument("--args", nargs=argparse.REMAINDER, default=[])
    ns = parser.parse_args()

    if ns.mode == "verify":
        return 0 if verify_fd(ns.fd) else 1
    args = ns.args[1:] if ns.args[:1] == ["--"] else ns.args
    return run(ns.caller, ns.script, args)


if __name__ == "__main__":
    raise SystemExit(main())
