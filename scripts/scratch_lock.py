#!/usr/bin/env python3
"""Kernel-backed serialization for destructive scratch cleanup entrypoints."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import math
import os
from pathlib import Path
import re
import stat
import sys
import time


ENV_FD = "DISK_MAGICIAN_SCRATCH_LOCK_FD"
ENV_PID = "DISK_MAGICIAN_SCRATCH_LOCK_PID"
ENV_SCOPE = "DISK_MAGICIAN_SCRATCH_LOCK_SCOPE"
ENV_KEY = "DISK_MAGICIAN_SCRATCH_LOCK_KEY"
# Contention is a skip, not a failure: EX_TEMPFAIL lets callers tell it apart from rc=1.
EXIT_LOCK_HELD = 75


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


def lock_path(scope: str = "scratch", key: str | None = None) -> Path:
    home = os.environ.get("HOME", "")
    if not home or not Path(home).is_absolute():
        raise PermissionError("unsafe HOME for scratch lock")
    home_stat = os.lstat(home)
    if not stat.S_ISDIR(home_stat.st_mode) or home_stat.st_uid != os.geteuid() or home_stat.st_mode & 0o022:
        raise PermissionError("unsafe HOME for scratch lock")
    base = Path(home) / ".disk_magician_locks"
    if scope == "scratch" and key is None:
        return base / "scratch_cleanup.lock"
    if scope != "cursor" or key is None:
        raise ValueError("invalid scratch lock scope")
    canonical = canonical_cursor_path(key)
    digest = hashlib.sha256(os.fsencode(canonical)).hexdigest()
    return base / f"cursor-{digest}.lock"


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


def verify_fd(fd: int, scope: str = "scratch", key: str | None = None) -> bool:
    try:
        canonical_fd = open_lock(lock_path(scope, key), create=False)
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


def parse_wait(raw: str | None) -> float:
    """Seconds to wait for the lock; non-numeric or non-finite input falls back to 20."""
    try:
        value = float(raw) if raw is not None else 20.0
    except ValueError:
        return 20.0
    return max(0.0, value) if math.isfinite(value) else 20.0


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


def holder_path(path: Path | None = None) -> Path:
    """Sidecar record naming the live lock holder, for staleness diagnosis."""
    return (path or lock_path()).with_suffix(".holder")


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True          # exists, owned by someone else
    return True


def write_holder(fd: int, path: Path) -> None:
    """Best-effort holder record. Never fail the run because of it."""
    try:
        record = holder_path(path)
        tmp = record.with_suffix(f".holder.{os.getpid()}")
        tmp.write_text(f"pid={os.getpid()}\nsince={int(time.time())}\nfd_locked=1\n")
        os.replace(tmp, record)
    except OSError:
        pass


def clear_holder() -> None:
    try:
        holder_path().unlink()
    except OSError:
        pass


def stale_holder_report(path: Path | None = None) -> str:
    """Human-readable diagnosis when the lock is held.

    Reports whether the recorded holder is still alive. This is diagnostic only:
    it never breaks a live lock, because a kernel flock is authoritative and a
    dead holder releases it automatically. What it removes is the silent case
    where a WEDGED-but-alive holder (a stalled child, not a dead process) holds
    the lock for hours with nothing explaining why -- measured 2026-11-19: a
    frozen cleanup held this lock 8h+ with orphaned children and every later
    cleanup reported only "scratch lock held".
    """
    try:
        raw = holder_path(path).read_text()
    except OSError:
        return "holder=unknown (no holder record)"
    info = {}
    for line in raw.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            info[k.strip()] = v.strip()
    pid_raw = info.get("pid", "")
    if not pid_raw.isdigit():
        return "holder=unknown (malformed holder record)"
    pid = int(pid_raw)
    since = info.get("since", "")
    age = ""
    if since.isdigit():
        age = f" held_s={int(time.time()) - int(since)}"
    if _pid_alive(pid):
        return f"holder=pid {pid} alive{age}"
    return f"holder=pid {pid} DEAD (stale record; flock must have been released){age}"


def run(caller: str, script: str, args: list[str], scope: str = "scratch",
        key: str | None = None) -> int:
    try:
        path = lock_path(scope, key)
    except (OSError, ValueError) as exc:
        print(f"[{caller}] invalid scratch lock scope: {exc}", file=sys.stderr)
        return 2
    try:
        fd = open_lock(path, create=True)
    except OSError as exc:
        print(f"[{caller}] failed to open scratch lock {path}: {exc}", file=sys.stderr)
        return 1

    wait = parse_wait(os.environ.get("DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS"))
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except (BlockingIOError, OSError) as exc:
            if isinstance(exc, BlockingIOError) and time.monotonic() < deadline:
                time.sleep(0.25)
                continue
            os.close(fd)
            if isinstance(exc, BlockingIOError):
                note = f"after waiting {wait:g}s" if wait > 0 else "— not queuing"
                label = "cursor" if scope == "cursor" else "scratch"
                print(
                    f"[{caller}] skipped, {label} lock held {note}; {stale_holder_report(path)}",
                    file=sys.stderr,
                )
                return EXIT_LOCK_HELD
            print(f"[{caller}] failed to acquire scratch lock {path}: {exc}", file=sys.stderr)
            return 1

    write_holder(fd, path)
    os.set_inheritable(fd, True)
    os.environ[ENV_FD] = str(fd)
    os.environ[ENV_PID] = str(os.getpid())
    if scope == "cursor":
        os.environ[ENV_SCOPE] = scope
        os.environ[ENV_KEY] = canonical_cursor_path(key or "")
    else:
        os.environ.pop(ENV_SCOPE, None)
        os.environ.pop(ENV_KEY, None)
    disable_implicit_git_fsmonitor()
    os.execvpe(script, [script, *args], os.environ)
    return 127


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "key":
        try:
            print(canonical_cursor_path(sys.argv[2]))
            return 0
        except (OSError, ValueError) as exc:
            print(f"scratch_lock.py: invalid cursor path: {exc}", file=sys.stderr)
            return 2
    if len(sys.argv) >= 2 and sys.argv[1] == "run":
        try:
            end = sys.argv.index("--args")
            options = sys.argv[2:end]
            caller = options[options.index("--caller") + 1]
            script = options[options.index("--script") + 1]
            scope = "scratch"
            key = None
            if "--scope" in options:
                scope = options[options.index("--scope") + 1]
            if "--key" in options:
                key = options[options.index("--key") + 1]
            args = sys.argv[end + 1 :]
            if args[:1] == ["--"]:
                args = args[1:]
        except (ValueError, IndexError):
            print("scratch_lock.py: invalid run arguments", file=sys.stderr)
            return 2
        return run(caller, script, args, scope, key)

    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("--fd", type=int, required=True)
    verify_parser.add_argument("--scope", choices=("scratch", "cursor"), default="scratch")
    verify_parser.add_argument("--key")
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--caller", required=True)
    run_parser.add_argument("--script", required=True)
    run_parser.add_argument("--args", nargs=argparse.REMAINDER, default=[])
    ns = parser.parse_args()

    if ns.mode == "verify":
        return 0 if verify_fd(ns.fd, ns.scope, ns.key) else 1
    args = ns.args[1:] if ns.args[:1] == ["--"] else ns.args
    return run(ns.caller, ns.script, args)


if __name__ == "__main__":
    raise SystemExit(main())
