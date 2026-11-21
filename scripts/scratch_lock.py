#!/usr/bin/env python3
"""Kernel coordination for writers of the same cleanup checkpoint."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import re
import stat
import sys

ENV_FD = "DISKM_CLEANUP_CURSOR_FD"
ENV_PID = "DISKM_CLEANUP_CURSOR_PID"
ENV_KEY = "DISKM_CLEANUP_CURSOR_KEY"


def canonical_cursor_path(raw: str | os.PathLike[str]) -> str:
    value = Path(raw)
    if not value.is_absolute():
        value = Path.cwd() / value
    if value.is_symlink():
        raise ValueError("cursor lock key cannot be a symlink")
    parent = value.parent.resolve(strict=False)
    canonical = parent / value.name
    if canonical.exists() and not canonical.is_file():
        raise ValueError("cursor lock key must name a regular file")
    return os.fspath(canonical)


def lock_path(key: str) -> Path:
    home = os.environ.get("HOME", "")
    if not home or not Path(home).is_absolute():
        raise PermissionError("unsafe HOME for cursor lock")
    home_stat = os.lstat(home)
    if not stat.S_ISDIR(home_stat.st_mode) or home_stat.st_uid != os.geteuid() or home_stat.st_mode & 0o022:
        raise PermissionError("unsafe HOME for cursor lock")
    canonical = canonical_cursor_path(key)
    digest = hashlib.sha256(os.fsencode(canonical)).hexdigest()
    return Path(home) / ".disk_magician_locks" / f"checkpoint-{digest}.lock"


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


def verify_fd(fd: int, key: str) -> bool:
    try:
        canonical_fd = open_lock(lock_path(key), create=False)
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


def disable_implicit_git_fsmonitor() -> None:
    """Keep incidental Git probes from spawning long-lived flock owners.

    The lock must remain inheritable for real cleanup descendants. Git's
    process-scoped config disables its implicit fsmonitor hook/daemon instead,
    without changing repository or user config or dropping caller entries.
    Leave malformed counts untouched so Git retains its own error behavior.
    """
    raw = os.environ.get("GIT_CONFIG_COUNT", "")
    # Git accepts an empty count as zero, otherwise strtol-style decimal input
    # (leading ASCII whitespace/sign but no trailing characters).
    if raw and not re.fullmatch(r"[ \t\n\r\v\f]*[+-]?[0-9]+", raw):
        return
    normalized = raw.lstrip(" \t\n\r\v\f")
    digits = normalized.lstrip("+-").lstrip("0") or "0"
    # Avoid Python's integer-string limit for valid, zero-padded Git counts.
    if len(digits) > 10:
        return
    count = int(digits) * (-1 if normalized.startswith("-") else 1)
    if not 0 <= count < 2147483647:
        return
    os.environ[f"GIT_CONFIG_KEY_{count}"] = "core.fsmonitor"
    os.environ[f"GIT_CONFIG_VALUE_{count}"] = "false"
    os.environ["GIT_CONFIG_COUNT"] = str(count + 1)


def run(caller: str, script: str, args: list[str], key: str) -> int:
    try:
        canonical = canonical_cursor_path(key)
        fd = open_lock(lock_path(canonical), create=True)
    except (OSError, ValueError) as error:
        print(f"[{caller}] cannot open cursor lock: {error}", file=sys.stderr)
        return 1
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        print(f"[{caller}] skipped, cursor lock held", file=sys.stderr)
        return 75
    except OSError as error:
        os.close(fd)
        print(f"[{caller}] cannot acquire cursor lock: {error}", file=sys.stderr)
        return 1

    os.set_inheritable(fd, True)
    os.environ[ENV_FD] = str(fd)
    os.environ[ENV_PID] = str(os.getpid())
    os.environ[ENV_KEY] = canonical
    disable_implicit_git_fsmonitor()
    os.execvpe(script, [script, *args], os.environ)
    return 127


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="mode", required=True)
    canonical = commands.add_parser("key")
    canonical.add_argument("cursor")
    verify = commands.add_parser("verify")
    verify.add_argument("--fd", type=int, required=True)
    verify.add_argument("--key", required=True)
    invoke = commands.add_parser("run")
    invoke.add_argument("--caller", required=True)
    invoke.add_argument("--script", required=True)
    invoke.add_argument("--key", required=True)
    args = sys.argv[1:]
    child_args = []
    if args[:1] == ["run"] and "--args" in args:
        separator = args.index("--args")
        child_args = args[separator + 1:]
        if child_args[:1] == ["--"]:
            child_args = child_args[1:]
        args = args[:separator]
    options = parser.parse_args(args)
    if options.mode == "key":
        try:
            print(canonical_cursor_path(options.cursor))
            return 0
        except (OSError, ValueError) as error:
            print(f"invalid cursor path: {error}", file=sys.stderr)
            return 2
    if options.mode == "verify":
        return 0 if verify_fd(options.fd, options.key) else 1
    return run(options.caller, options.script, child_args, options.key)


if __name__ == "__main__":
    raise SystemExit(main())
