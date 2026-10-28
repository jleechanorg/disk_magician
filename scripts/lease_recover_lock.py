#!/usr/bin/env python3
"""Quarantine the one malformed stale lease-registry lock without deleting it."""

from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import stat
import sys
import time
import uuid


LOCK_NAME = ".owner-mutation.reuse-lock"
LOCK_TTL_SECONDS = 3600
LOCK_MODE = 0o755


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


def lock_is_same_empty(lock: Path, expected: os.stat_result) -> bool:
    try:
        current = lstat_directory(lock, "registry lock", LOCK_MODE)
        if (current.st_dev, current.st_ino, current.st_uid, stat.S_IMODE(current.st_mode), current.st_mtime_ns) != (
            expected.st_dev, expected.st_ino, expected.st_uid, stat.S_IMODE(expected.st_mode), expected.st_mtime_ns
        ):
            return False
        return not os.listdir(lock)
    except (OSError, ValueError):
        return False


def before_revalidate() -> None:
    """Test seam; production intentionally has no intervening mutation."""


def write_record(path: Path, record: dict) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    with open(temporary, "x", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def main(argv: list[str]) -> int:
    if argv != ["--registry"]:
        return fail("usage: diskm lease-recover-lock --registry", 2)

    state = Path(os.environ.get("DISK_MAGICIAN_STATE_DIR", str(Path.home() / ".disk_magician_state"))).expanduser()
    leases = state / "worktree_leases"
    lock = leases / LOCK_NAME
    try:
        lstat_directory(state, "state directory")
        lstat_directory(leases, "lease directory")
        info = lstat_directory(lock, "registry lock", LOCK_MODE)
    except (OSError, ValueError) as exc:
        return fail(str(exc))

    try:
        if os.listdir(lock):
            return fail("registry lock is not empty")
    except OSError as exc:
        return fail(f"cannot inspect registry lock: {exc}")

    age_seconds = time.time() - info.st_mtime
    if age_seconds <= LOCK_TTL_SECONDS:
        return fail(f"registry lock is too recent ({age_seconds:.0f}s <= {LOCK_TTL_SECONDS}s)")

    quarantine_parent = state / "quarantine"
    quarantine = quarantine_parent / "lease-locks"
    try:
        if not quarantine_parent.exists():
            os.mkdir(quarantine_parent, 0o700)
        lstat_directory(quarantine_parent, "quarantine directory", 0o700)
        if not quarantine.exists():
            os.mkdir(quarantine, 0o700)
        lstat_directory(quarantine, "lease-lock quarantine", 0o700)
    except (OSError, ValueError) as exc:
        return fail(str(exc))

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    quarantined = quarantine / f"{stamp}-{info.st_dev}-{info.st_ino}-{LOCK_NAME}"
    receipt = quarantined.with_name(quarantined.name + ".receipt.json")
    pending = quarantine / f".pending-{uuid.uuid4().hex}.json"
    record = {
        "schema_version": 1,
        "action": "quarantine_malformed_empty_registry_lock",
        "source": str(lock),
        "quarantined": str(quarantined),
        "recovered_at": datetime.now(timezone.utc).isoformat(),
        "lock_identity": {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid, "mode": f"{stat.S_IMODE(info.st_mode):04o}"},
        "age_seconds": round(age_seconds, 3),
        "ttl_seconds": LOCK_TTL_SECONDS,
    }
    try:
        write_record(pending, record)
        before_revalidate()
        if not lock_is_same_empty(lock, info):
            record["outcome"] = "deferred_identity_changed"
            write_record(pending, record)
            os.replace(pending, receipt)
            return fail("registry lock changed before quarantine; deferred with receipt")
        if os.path.lexists(quarantined) or os.path.lexists(receipt):
            record["outcome"] = "deferred_destination_exists"
            write_record(pending, record)
            os.replace(pending, receipt)
            return fail("quarantine destination already exists; deferred with receipt")
        os.rename(lock, quarantined)
        moved = lstat_directory(quarantined, "quarantined registry lock", LOCK_MODE)
        if (moved.st_dev, moved.st_ino, moved.st_uid, stat.S_IMODE(moved.st_mode), moved.st_mtime_ns) != (
            info.st_dev, info.st_ino, info.st_uid, stat.S_IMODE(info.st_mode), info.st_mtime_ns
        ) or os.listdir(quarantined):
            record["outcome"] = "quarantine_identity_anomaly"
            write_record(pending, record)
            os.replace(pending, receipt)
            return fail("quarantined lock identity changed; retained anomaly receipt")
        record["outcome"] = "quarantined"
        write_record(pending, record)
        os.replace(pending, receipt)
    except OSError as exc:
        return fail(f"quarantine rename or receipt write failed: {exc}")

    print(json.dumps(record, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
