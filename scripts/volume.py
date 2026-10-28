#!/usr/bin/env python3
"""Opt-in, fail-closed Scratch-volume helpers used by diskm."""
from __future__ import annotations
import fcntl
import hashlib
import json
import os
import plistlib
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

GIB = 1024**3
MIB = 1024**2
BALLAST_BYTES = 64 * MIB
BALLAST_RECREATE_FREE_BYTES = 1088 * MIB
DATA_MOUNTPOINT = "/System/Volumes/Data"
REGISTRY_SCHEMA_VERSION = 1
SUPPORTED_CLASSES = {"scratch"}
DOCKER_SOCKET = Path("/var/run/docker.sock")
DOCKER_TRANSPORT_FLAGS = (
    "--pid", "host", "--security-opt", "apparmor=unconfined",
    "--cap-drop", "ALL", "--cap-add", "SYS_CHROOT", "--cap-add", "DAC_OVERRIDE",
    "--cap-add", "SYS_PTRACE",
)


@dataclass(frozen=True)
class Volume:
    name: str
    uuid: str
    ref: str
    used: int | None
    quota: int | None
    roles: tuple[str, ...]
    encrypted: bool | None = None
    locked: bool | None = None
    mountpoint: str | None = field(default=None, compare=False)


@dataclass(frozen=True)
class Container:
    ref: str
    uuid: str
    ceiling: int | None
    free: int | None
    volumes: tuple[Volume, ...]
    all_volume_names: tuple[str, ...] = ()

    def volume_by_role(self, role: str) -> Volume:
        matches = [volume for volume in self.volumes if role in volume.roles]
        if len(matches) != 1:
            raise ValueError("APFS role is not uniquely available: " + role)
        return matches[0]


def is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def require_nonnegative(value: Any, label: str) -> int:
    if not is_int(value) or value < 0:
        raise ValueError(label + " is unavailable or invalid")
    return value


def require_positive(value: Any, label: str) -> int:
    if not is_int(value) or value <= 0:
        raise ValueError(label + " must be a positive integer")
    return value


def diskutil_bin() -> str:
    return os.environ.get("DISK_MAGICIAN_DISKUTIL_BIN", "/usr/sbin/diskutil")


def run_diskutil(arguments: list[str]) -> bytes:
    result = subprocess.run(
        [diskutil_bin(), *arguments], capture_output=True, timeout=15, check=False
    )
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip()
        raise RuntimeError("diskutil operation failed" + (": " + detail if detail else ""))
    return result.stdout


def has_interactive_diskutil_tty() -> bool:
    try:
        if not all(stream is not None and stream.isatty()
                   for stream in (sys.stdin, sys.stdout, sys.stderr)):
            return False
        descriptor = os.open("/dev/tty", os.O_RDWR | getattr(os, "O_CLOEXEC", 0))
        try:
            return stat.S_ISCHR(os.fstat(descriptor).st_mode) and os.isatty(descriptor)
        finally:
            os.close(descriptor)
    except (AttributeError, OSError):
        return False


def run_diskutil_interactive(arguments: list[str]) -> None:
    if not has_interactive_diskutil_tty():
        raise RuntimeError("diskutil passphrase prompt requires an interactive terminal")
    result = subprocess.run([diskutil_bin(), *arguments], timeout=300, check=False)
    if result.returncode:
        raise RuntimeError("diskutil interactive operation failed")


def plist(arguments: list[str]) -> dict[str, Any]:
    result = plistlib.loads(run_diskutil(arguments))
    if not isinstance(result, dict):
        raise ValueError("diskutil returned an invalid plist")
    return result


def load_container() -> Container:
    listing = plist(["apfs", "list", "-plist"])
    containers = listing.get("Containers")
    if not isinstance(containers, list) or not containers:
        raise ValueError("APFS containers are unavailable")

    all_volume_names = []
    for candidate in containers:
        if not isinstance(candidate, dict):
            raise ValueError("invalid APFS container row")
        rows = candidate.get("Volumes")
        if not isinstance(rows, list):
            raise ValueError("APFS volume inventory is unavailable")
        for row in rows:
            if (
                not isinstance(row, dict)
                or not isinstance(row.get("Name"), str)
                or not row["Name"]
            ):
                raise ValueError("APFS volume name is unavailable")
            all_volume_names.append(row["Name"])

    data_info = plist(["info", "-plist", DATA_MOUNTPOINT])
    data_container_ref = data_info.get("APFSContainerReference")
    if not isinstance(data_container_ref, str) or not data_container_ref:
        raise ValueError("Data volume container identity is unavailable")

    matches = [
        item for item in containers
        if isinstance(item, dict)
        and item.get("ContainerReference") == data_container_ref
    ]
    if len(matches) != 1:
        raise ValueError("Data volume container is not uniquely available")

    raw = matches[0]
    ref = raw.get("ContainerReference")
    uuid = raw.get("APFSContainerUUID")
    if not all(isinstance(value, str) and value for value in (ref, uuid)):
        raise ValueError("container identity is incomplete")

    raw_volumes = raw.get("Volumes")
    if not isinstance(raw_volumes, list):
        raise ValueError("container volume listing is unavailable")

    volumes = []
    for item in raw_volumes:
        if not isinstance(item, dict):
            raise ValueError("invalid volume row")
        name = item.get("Name")
        volume_uuid = item.get("APFSVolumeUUID")
        device = item.get("DeviceIdentifier")
        roles = item.get("Roles") or []
        encrypted = item.get("Encryption")
        locked = item.get("Locked")
        if not all(isinstance(value, str) and value for value in (name, volume_uuid, device)):
            raise ValueError("volume identity is incomplete")
        if not isinstance(roles, list) or not all(isinstance(role, str) for role in roles):
            raise ValueError("volume roles are invalid")
        if encrypted is not None and not isinstance(encrypted, bool):
            raise ValueError("volume encryption state is invalid")
        if locked is not None and not isinstance(locked, bool):
            raise ValueError("volume lock state is invalid")
        used = item.get("CapacityInUse")
        quota = item.get("CapacityQuota")
        if used is not None:
            require_nonnegative(used, "volume used capacity")
        if quota is not None:
            require_nonnegative(quota, "volume quota")
        volumes.append(Volume(name, volume_uuid, device, used, quota, tuple(roles), encrypted, locked))

    ceiling = raw.get("CapacityCeiling")
    free = raw.get("CapacityFree")
    if ceiling is not None:
        require_nonnegative(ceiling, "container ceiling")
    if free is not None:
        require_nonnegative(free, "container free capacity")
    return Container(ref, uuid, ceiling, free, tuple(volumes), tuple(all_volume_names))


def config(config_path: str | Path | None = None) -> dict[str, Any]:
    import resolve_config

    source = resolve_config.resolve() if config_path is None else config_path
    document = json.loads(Path(source).read_text())
    if not isinstance(document, dict):
        raise ValueError("invalid quota configuration")
    if "volumes" not in document:
        raise ValueError("quota configuration has no volume block")
    volumes = document["volumes"]
    if not isinstance(volumes, dict):
        raise ValueError("quota configuration is unavailable")
    classes = volumes.get("classes")
    if not isinstance(classes, dict) or set(classes) != SUPPORTED_CLASSES:
        raise ValueError("unsupported v1 volume classes")
    require_positive(volumes.get("swap_headroom_gb"), "swap headroom")
    require_positive(volumes.get("alarm_floor_gb"), "container alarm floor")
    encryption = volumes.get("encryption")
    if encryption != "none" and not (encryption == "apfs-passphrase" and sys.platform == "darwin"):
        raise ValueError("unsupported v1 encryption mode")

    scratch = classes["scratch"]
    if not isinstance(scratch, dict):
        raise ValueError("invalid scratch configuration")
    if scratch.get("name") != "diskm-scratch":
        raise ValueError("invalid scratch volume name")
    mountpoint = scratch.get("mountpoint")
    if not isinstance(mountpoint, str) or not Path(mountpoint).is_absolute():
        raise ValueError("scratch mountpoint must be absolute")
    require_positive(scratch.get("quota_gb"), "scratch quota")
    if scratch.get("backend", "fuse") not in {"fuse", "native"}:
        raise ValueError("unsupported Linux Scratch backend")
    return volumes


def cls(name: str, config_path: str | Path | None = None) -> tuple[dict[str, Any], dict[str, Any]]:
    volumes = config(config_path)
    if name not in SUPPORTED_CLASSES:
        raise ValueError("unsupported v1 volume class")
    return volumes, volumes["classes"][name]


def fit_result(
    container: Container | None = None,
    settings: dict[str, Any] | None = None,
) -> dict[str, Any]:
    container = container or load_container()
    settings = config() if settings is None else settings
    data_used = require_nonnegative(
        container.volume_by_role("Data").used, "Data volume usage"
    )
    system_used = require_nonnegative(
        container.volume_by_role("System").used, "System volume usage"
    )
    vm_volume = container.volume_by_role("VM")
    vm_used = require_nonnegative(vm_volume.used, "VM usage")
    ceiling = require_positive(container.ceiling, "container ceiling")
    swap_headroom = settings["swap_headroom_gb"] * GIB
    alarm_floor = settings["alarm_floor_gb"] * GIB
    quota_bytes = settings["classes"]["scratch"]["quota_gb"] * GIB

    scratch_volumes = [v for v in container.volumes if v.name == settings["classes"]["scratch"]["name"]]
    if len(scratch_volumes) > 1:
        raise ValueError("Scratch volume identity is not unique")
    scratch_volume = scratch_volumes[0] if scratch_volumes else None
    if scratch_volume is not None:
        scratch_used = require_nonnegative(scratch_volume.used, "Scratch usage")
    else:
        scratch_used = 0
    vm_reserve = max(vm_used, swap_headroom)
    # Sum every measured allocation from the Data APFS container. Replace the
    # VM usage with the larger swap reserve and Scratch usage with its full
    # configured quota, so neither resource is counted twice.
    all_allocations = 0
    other_allocations = 0
    for volume in container.volumes:
        used = require_nonnegative(volume.used, "APFS volume usage: " + volume.name)
        all_allocations += used
        if volume is not vm_volume and volume is not scratch_volume:
            other_allocations += used
    scratch_reservation = max(scratch_used, quota_bytes)
    required = other_allocations + vm_reserve + scratch_reservation + alarm_floor
    max_quota = max(0, (ceiling - other_allocations - vm_reserve - alarm_floor) // GIB)
    return {
        "ok": required <= ceiling,
        "fits": required <= ceiling,
        "required_bytes": required,
        "ceiling_bytes": ceiling,
        "data_used_bytes": data_used,
        "system_used_bytes": system_used,
        "vm_reserve_bytes": vm_reserve,
        "container_volume_allocations_bytes": all_allocations,
        "other_volume_allocations_bytes": other_allocations,
        "scratch_reservation_bytes": scratch_reservation,
        "quota_bytes": quota_bytes,
        "alarm_floor_bytes": alarm_floor,
        "max_quota_gb_that_fits": max_quota,
    }


def state_root(state_dir: str | Path | None = None) -> Path:
    if state_dir is not None:
        return Path(state_dir)
    return Path(os.environ.get(
        "DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"
    ))


def registry_paths(state_dir: str | Path | None = None) -> tuple[Path, Path]:
    directory = state_root(state_dir) / "volumes"
    directory.mkdir(parents=True, exist_ok=True)
    return directory / "registry.json", directory / "registry.lock"


def registry(state_dir: str | Path | None = None) -> dict[str, Any]:
    path, _ = registry_paths(state_dir)
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError:
        return {"schema_version": REGISTRY_SCHEMA_VERSION, "volumes": {}}
    if (
        not isinstance(value, dict)
        or value.get("schema_version") != REGISTRY_SCHEMA_VERSION
        or not isinstance(value.get("volumes"), dict)
    ):
        raise ValueError("invalid volume registry")
    return value


def locked_registry() -> tuple[Path, Any]:
    registry_file, lock_file = registry_paths()
    handle = lock_file.open("a+")
    fcntl.flock(handle, fcntl.LOCK_EX)
    return registry_file, handle


def save_registry(path: Path, lock_handle: Any, value: dict[str, Any]) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".registry-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        lock_handle.close()


def validate_entry(
    container: Container, settings: dict[str, Any], entry: Any,
    *, allow_locked: bool = False, allow_unexpected_mount: bool = False,
) -> Volume:
    if not isinstance(entry, dict):
        raise ValueError("volume registry entry is missing")
    scratch = settings["classes"]["scratch"]
    required = {
        "class": "scratch",
        "name": scratch["name"],
        "mountpoint": scratch["mountpoint"],
        "container_uuid": container.uuid,
    }
    if any(entry.get(key) != value for key, value in required.items()):
        raise ValueError("volume registry identity mismatch")

    volume_uuid = entry.get("uuid")
    if not isinstance(volume_uuid, str) or not volume_uuid:
        raise ValueError("registered volume UUID is missing")
    expected_quota = scratch["quota_gb"] * GIB
    if entry.get("quota_bytes") != expected_quota:
        raise ValueError("registered quota does not match configured quota")

    matches = [volume for volume in container.volumes if volume.name == scratch["name"]]
    if len(matches) != 1:
        raise ValueError("registered volume is not uniquely mounted")
    volume = matches[0]
    if volume.uuid != volume_uuid or volume.roles:
        raise ValueError("volume identity or role mismatch")
    if volume.quota != expected_quota:
        raise ValueError("measured quota does not match configured quota")

    encrypted_mode = settings["encryption"] == "apfs-passphrase"
    measured = plist(["info", "-plist", volume.ref])
    if (
        measured.get("VolumeUUID") != volume.uuid
        or measured.get("APFSContainerReference") != container.ref
        or measured.get("DeviceIdentifier") != volume.ref
    ):
        raise ValueError("volume identity mismatch")
    if encrypted_mode:
        measured_locked = measured.get("Locked")
        if volume.encrypted is not True or measured.get("Encryption") is not True:
            raise ValueError("encrypted volume verification failed")
        if not isinstance(volume.locked, bool) or measured_locked is not volume.locked:
            raise ValueError("volume lock state is unavailable or inconsistent")
        if volume.locked:
            if not allow_locked:
                raise ValueError("encrypted volume is locked")
            return replace(volume, mountpoint=None)
    mountpoint = measured.get("MountPoint")
    if not isinstance(mountpoint, str):
        raise ValueError("mounted volume path is unavailable")
    if mountpoint != scratch["mountpoint"] and not allow_unexpected_mount:
        raise ValueError("mounted volume path mismatch")
    return replace(volume, mountpoint=mountpoint)


def ballast_path(mountpoint: str) -> Path:
    return Path(mountpoint) / ".diskm-ballast"


def ballast_ok(mountpoint: str) -> bool:
    path = ballast_path(mountpoint)
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return False
    try:
        details = os.fstat(descriptor)
        return (stat.S_ISREG(details.st_mode)
                and details.st_size == BALLAST_BYTES
                and details.st_blocks * 512 >= BALLAST_BYTES)
    finally:
        os.close(descriptor)


def unlink_ballast_verified(mountpoint: str) -> bool:
    path = ballast_path(mountpoint)
    try:
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        return False
    try:
        try:
            file_fd = os.open(path.name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                              dir_fd=directory_fd)
        except OSError:
            return False
        try:
            opened = os.fstat(file_fd)
            if (not stat.S_ISREG(opened.st_mode)
                    or opened.st_size != BALLAST_BYTES
                    or opened.st_blocks * 512 < BALLAST_BYTES):
                return False
            current = os.stat(path.name, dir_fd=directory_fd, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino):
                return False
            os.unlink(path.name, dir_fd=directory_fd)
            return True
        finally:
            os.close(file_fd)
    finally:
        os.close(directory_fd)


def write_ballast(mountpoint: str) -> None:
    path = ballast_path(mountpoint)
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        stream = os.fdopen(descriptor, "wb")
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        raise
    with stream:
        remaining = BALLAST_BYTES
        block = b"\0" * MIB
        while remaining:
            stream.write(block)
            remaining -= len(block)
        stream.flush()
        os.fsync(stream.fileno())
    if not ballast_ok(mountpoint):
        raise RuntimeError("ballast allocation verification failed")


def recover_creation(name: str, settings: dict[str, Any], scratch: dict[str, Any],
                     registry_file: Path, lock_handle: Any,
                     current_registry: dict[str, Any], entry: dict[str, Any],
                     container: Container) -> int:
    """Finish only a volume whose exact UUID was recorded after addVolume."""
    if entry.get("state") == "creating":
        raise ValueError("creation intent has no verified UUID; manual reconciliation required")
    if entry.get("state") != "needs_recovery":
        raise ValueError("volume is already registered")
    volume = validate_entry(container, settings, entry)
    fit = fit_result(container, settings)
    if not fit["fits"]:
        raise ValueError("container no longer satisfies scratch capacity fit")
    free = require_nonnegative(container.free, "container free capacity")
    if free < settings["alarm_floor_gb"] * GIB:
        raise ValueError("container free capacity is below the alarm floor")
    mountpoint = scratch["mountpoint"]
    if not ballast_ok(mountpoint):
        if os.path.lexists(ballast_path(mountpoint)):
            raise ValueError("ballast path exists but is not valid")
        used = require_nonnegative(volume.used, "volume usage")
        quota = require_positive(volume.quota, "volume quota")
        if quota - used < BALLAST_RECREATE_FREE_BYTES:
            raise ValueError("insufficient free quota to restore ballast")
        write_ballast(mountpoint)
    entry["state"] = "active"
    entry["created_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    save_registry(registry_file, lock_handle, current_registry)
    return 0


def exact_entry(name: str, allowed_states: set[str]) -> tuple[Container, dict[str, Any], dict[str, Any], Volume]:
    settings, scratch = cls(name)
    entries = registry()["volumes"]
    if name not in entries:
        diskutil = Path(diskutil_bin())
        can_inspect = sys.platform == "darwin" or (
            diskutil.is_file() and os.access(diskutil, os.X_OK)
        )
        if can_inspect:
            container = load_container()
            if any(volume.name == scratch["name"] for volume in container.volumes):
                raise ValueError("live scratch volume is missing its registry entry")
        raise ValueError("volume is not registered in an eligible state")
    entry = entries.get(name)
    if not isinstance(entry, dict):
        raise ValueError("invalid volume registry entry")
    container = load_container()
    volume = validate_entry(container, settings, entry)
    state = entry.get("state")
    if state == "retired" and "retired" not in allowed_states:
        raise ValueError("volume is retired")
    if state not in allowed_states:
        raise ValueError("invalid volume registry state")
    return container, settings, entry, volume


def path_cmd(name: str, for_reclaim: bool = False) -> int:
    if linux_backend_enabled(name):
        try:
            settings, scratch = cls(name)
            entries = registry()["volumes"]
            if name not in entries:
                return 3
            entry = entries[name]
            if not isinstance(entry, dict):
                return 75
            linux_validate_mount(settings, scratch, entry)
            print(scratch["mountpoint"])
            return 0
        except Exception:
            return 75
    allowed_states = {"active", "retired"} if for_reclaim else {"active"}
    try:
        container, settings, entry, volume = exact_entry(name, allowed_states)
        mountpoint = settings["classes"]["scratch"]["mountpoint"]
        ballast_exists = os.path.lexists(ballast_path(mountpoint))
        if for_reclaim:
            if ballast_exists and not ballast_ok(mountpoint):
                return 75
        elif not ballast_ok(mountpoint):
            return 75
    except ValueError as error:
        message = str(error)
        if message == "quota configuration has no volume block":
            if sys.platform != "darwin":
                return 3
            try:
                container = load_container()
                if any(volume.name == "diskm-scratch" for volume in container.volumes):
                    return 75
            except Exception:
                return 75
            return 3
        if message in {
            "volume is not registered in an eligible state",
            "volume is retired",
        }:
            return 3
        return 75
    except Exception:
        return 75
    print(settings["classes"]["scratch"]["mountpoint"])
    return 0


def log_ballast_release(path: Path, volume_uuid: str, action: str) -> bool:
    log_script = Path(__file__).resolve().parent / "safety_lib.sh"
    log_path = Path(os.environ.get(
        "DISK_MAGICIAN_DELETION_LOG",
        Path.home() / "Library" / "Logs" / "disk-magician-deletions.log",
    ))
    marker = uuid.uuid4().hex
    completed = subprocess.run(
        [
            "bash", "-c",
            'source "$1"; deletion_log volume "$4" 0 "$2" "$3"',
            "volume", str(log_script), str(path),
            "uuid=" + volume_uuid + ";record=" + marker,
            action,
        ],
        check=False,
    )
    if completed.returncode != 0:
        return False
    try:
        descriptor = os.open(log_path, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        try:
            details = os.fstat(descriptor)
            if not stat.S_ISREG(details.st_mode):
                return False
            start = max(0, details.st_size - 8192)
            tail = os.pread(descriptor, details.st_size - start, start)
            if marker.encode() not in tail:
                return False
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        directory_fd = os.open(
            log_path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        )
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        return True
    except OSError:
        return False


def ballast_cmd(action: str, name: str) -> int:
    registry_file = None
    lock_handle = None
    try:
        registry_file, lock_handle = locked_registry()
        if linux_backend_enabled(name):
            settings, scratch = cls(name)
            entry = registry()["volumes"].get(name)
            filesystem_uuid = linux_validate_mount(settings, scratch, entry)
            usage = shutil.disk_usage(scratch["mountpoint"])
            volume = Volume(scratch["name"], filesystem_uuid, scratch["image_path"],
                            usage.total - usage.free, usage.total, ())
        else:
            container, settings, entry, volume = exact_entry(name, {"active", "retired"})
        mountpoint = settings["classes"]["scratch"]["mountpoint"]
        path = ballast_path(mountpoint)
        if action == "ensure":
            if ballast_ok(mountpoint):
                return 0
            if os.path.lexists(path):
                return 75
            used = require_nonnegative(volume.used, "volume usage")
            quota = require_positive(volume.quota, "volume quota")
            if quota - used < BALLAST_RECREATE_FREE_BYTES:
                return 75
            write_ballast(mountpoint)
            return 0 if ballast_ok(mountpoint) else 75
        if action == "release":
            if not log_ballast_release(path, volume.uuid, "release_ballast_intent"):
                return 75
            if not unlink_ballast_verified(mountpoint):
                return 75
            path = ballast_path(mountpoint)
            return 0 if log_ballast_release(path, volume.uuid, "release_ballast") else 75
        raise ValueError("unknown ballast action")
    except Exception:
        return 75
    finally:
        if lock_handle is not None:
            lock_handle.close()


def encryption_is_acknowledged(settings: dict[str, Any]) -> bool:
    acknowledgement = settings.get("encryption_acknowledged_at")
    return settings.get("encryption") in {"none", "apfs-passphrase"} and isinstance(acknowledgement, str) and bool(acknowledgement.strip())



def linux_backend_enabled(name: str = "scratch") -> bool:
    if not sys.platform.startswith("linux"):
        return False
    try:
        _, scratch = cls(name)
    except Exception:
        return False
    return isinstance(scratch.get("image_path"), str)


def linux_paths(scratch: dict[str, Any]) -> tuple[Path, Path]:
    image = Path(scratch["image_path"])
    mountpoint = Path(scratch["mountpoint"])
    for path in (image, mountpoint):
        if path.resolve(strict=False) != path:
            raise ValueError("Linux Scratch paths may not traverse symlinks")
    if image == mountpoint or os.path.commonpath((str(image), str(mountpoint))) in {str(image), str(mountpoint)}:
        raise ValueError("Linux Scratch image and mountpoint must be separate")
    return image, mountpoint


def linux_command_env(args: list[str]) -> tuple[list[str], dict[str, str]]:
    command = list(args)
    env = os.environ.copy()
    if command[0] == "fuse2fs":
        settings = config()
        binary = settings.get("fuse2fs_bin")
        if isinstance(binary, str) and Path(binary).is_absolute():
            command[0] = binary
        else:
            command[0] = shutil.which("fuse2fs") or "fuse2fs"
        library_path = settings.get("fuse2fs_library_path")
        if isinstance(library_path, str) and library_path:
            if any(not Path(item).is_absolute() for item in library_path.split(":")):
                raise ValueError("fuse2fs library paths must be absolute")
            env["LD_LIBRARY_PATH"] = library_path
    return command, env


def linux_command(args: list[str], timeout: int | None = 30) -> str:
    args, env = linux_command_env(args)
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False, env=env)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "command failed: " + args[0])
    return result.stdout.strip()


def linux_fs_uuid(image: Path) -> str:
    value = linux_command(["blkid", "-p", "-s", "UUID", "-o", "value", str(image)])
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", value):
        raise ValueError("Scratch filesystem UUID is invalid")
    return value.lower()


def linux_loop_devices(image: Path) -> list[Path]:
    devices = []
    for backing in Path("/sys/block").glob("loop*/loop/backing_file"):
        value = backing.read_text().rstrip("\n").replace("\\040", " ")
        if value and Path(value).resolve() == image.resolve():
            devices.append(Path("/dev") / backing.parents[1].name)
    return devices


def linux_fuser_pid_set(image: Path, writers_only: bool = False) -> set[int] | None:
    """Return a positively identified fuser PID set, or None when unknown."""
    try:
        argv = ["fuser"]
        if writers_only:
            argv.append("-w")
        argv.append(str(image))
        result = subprocess.run(argv, capture_output=True, timeout=10, check=False)
        stdout = result.stdout.decode(errors="replace") if isinstance(result.stdout, bytes) else (result.stdout or "")
        stderr = result.stderr.decode(errors="replace") if isinstance(result.stderr, bytes) else (result.stderr or "")
        # fuser's normal PID mode writes the path/diagnostics to stderr and
        # the numeric PID list to stdout.  Never mine arbitrary diagnostics
        # for digits: a warning or errno must make the observation unknown.
        stderr = stderr.strip()
        if stderr not in {"", f"{image}:"}:
            return None
        fields = stdout.split()
        if any(not field.isdigit() for field in fields):
            return None
        pids = {int(field) for field in fields}
        if result.returncode == 1:
            return set() if not pids else None
        if result.returncode != 0 or not pids:
            return None
        return pids
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def linux_host_fstab_probe(image: Path, mountpoint: Path,
                           runtime_sha256: str | None = None) -> dict[str, Any]:
    """Capture the host observations the privileged fstab helper must agree with."""
    writers = linux_fuser_pid_set(image, writers_only=True)
    readers = linux_fuser_pid_set(image, writers_only=False)
    if writers is None or readers is None:
        raise RuntimeError("Scratch image reader/writer probe is unknown")
    view = {
        "mount": linux_mount_record(mountpoint),
        "loop_devices": sorted(str(path) for path in linux_loop_devices(image)),
        "writer_pids": sorted(writers),
        "reader_pids": sorted(readers),
        "image": str(image),
        "mountpoint": str(mountpoint),
    }
    if runtime_sha256 is not None:
        view["runtime_sha256"] = runtime_sha256
    return view


def linux_validate_installed_runtime(runtime: Path, state: Path) -> str:
    """Require the helper to be the immutable package named by deployed.json."""
    manifest_path = state / "deployed.json"
    document = json.loads(manifest_path.read_text())
    package_root_raw = document.get("package_root") if isinstance(document, dict) else None
    hashes = document.get("package_hashes") if isinstance(document, dict) else None
    if not isinstance(package_root_raw, str) or not isinstance(hashes, dict) or not hashes:
        raise ValueError("deployed package manifest is unavailable")
    package_root_arg = Path(package_root_raw)
    runtime_arg = Path(runtime)
    if package_root_arg.is_symlink() or runtime_arg.is_symlink():
        raise ValueError("deployed package root may not be a symlink")
    package_root = package_root_arg.resolve(strict=True)
    runtime = runtime_arg.resolve(strict=True)
    if runtime != package_root or (runtime / ".git").exists():
        raise ValueError("runtime is not the deployed package root")
    for relative, expected in hashes.items():
        relative_path = Path(relative)
        if (not isinstance(relative, str) or relative_path.is_absolute()
                or ".." in relative_path.parts or not isinstance(expected, str)
                or not re.fullmatch(r"[0-9a-f]{64}", expected)):
            raise ValueError("deployed package manifest contains an unsafe entry")
        candidate = package_root / relative_path
        if candidate.is_symlink() or not candidate.is_file():
            raise ValueError("deployed package contains an unsafe or missing file")
        digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
        if digest != expected:
            raise ValueError("deployed package hash mismatch")
    helper = package_root / "scripts" / "volume.py"
    helper_hash = hashes.get("scripts/volume.py")
    if not helper.is_file() or not isinstance(helper_hash, str):
        raise ValueError("deployed volume helper is not pinned")
    return helper_hash


def linux_validate_native_mount(settings: dict[str, Any], scratch: dict[str, Any], entry: Any) -> str:
    image, mountpoint = linux_paths(scratch)
    if not isinstance(entry, dict) or entry.get("state") != "active":
        raise ValueError("Scratch volume is not registered active")
    if (entry.get("image_path") != str(image) or entry.get("mountpoint") != str(mountpoint) or
            entry.get("quota_bytes") != scratch["quota_gb"] * GIB or
            image.stat().st_size != scratch["quota_gb"] * GIB):
        raise ValueError("Scratch volume registry identity mismatch")
    devices = linux_loop_devices(image)
    record = linux_mount_record(mountpoint)
    if len(devices) != 1 or record != ("ext4", str(devices[0])):
        raise ValueError("native Scratch mount identity mismatch")
    mounted_uuid = linux_command(["blkid", "-p", "-s", "UUID", "-o", "value", str(devices[0])]).lower()
    image_uuid = linux_fs_uuid(image)
    if (not re.fullmatch(r"[0-9a-f-]{36}", mounted_uuid) or mounted_uuid != image_uuid or
            entry.get("filesystem_uuid") != image_uuid):
        raise ValueError("native Scratch filesystem UUID mismatch")
    return image_uuid


def linux_native_mount_cmd(scratch: dict[str, Any], entry: Any) -> int:
    image, mountpoint = linux_paths(scratch)
    if linux_mount_record(mountpoint) is not None:
        linux_validate_native_mount(config(), scratch, entry)
        return 0
    try:
        if linux_image_has_loop_mapping(image) or linux_image_has_open_writers(image):
            return 75
        image_details = image.stat()
        if not stat.S_ISREG(image_details.st_mode) or image_details.st_nlink != 1:
            return 75
    except OSError:
        return 75
    linux_command(["mount", str(mountpoint)])
    try:
        linux_validate_native_mount(config(), scratch, entry)
        return 0
    except Exception:
        devices = linux_loop_devices(image)
        if len(devices) == 1 and linux_mount_record(mountpoint) == ("ext4", str(devices[0])):
            linux_command(["umount", str(mountpoint)])
            if linux_mount_record(mountpoint) is not None or linux_image_has_loop_mapping(image):
                raise RuntimeError("failed native mount identity remains active after rollback")
        raise


def linux_native_unmount_cmd(scratch: dict[str, Any], entry: Any) -> int:
    image, mountpoint = linux_paths(scratch)
    linux_validate_native_mount(config(), scratch, entry)
    linux_command(["umount", str(mountpoint)])
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if linux_mount_record(mountpoint) is None and not linux_image_has_loop_mapping(image):
            return 0
        time.sleep(0.1)
    return 75


def linux_mountpoint_safe(mountpoint: Path) -> bool:
    try:
        details = mountpoint.lstat()
        return (stat.S_ISDIR(details.st_mode) and details.st_uid == os.geteuid()
                and not (details.st_mode & 0o222) and not any(mountpoint.iterdir()))
    except OSError:
        return False


def linux_recover_underlay(mountpoint: Path, image: Path, entry: dict[str, Any]) -> bool:
    """Close only the exact empty writable underlay left by an interrupted mount."""
    if (entry.get("state") != "active" or entry.get("mountpoint") != str(mountpoint)
            or entry.get("image_path") != str(image) or linux_mount_record(mountpoint)):
        return False
    try:
        fd = os.open(mountpoint, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            details = os.fstat(fd)
            if (details.st_uid != os.geteuid() or not stat.S_ISDIR(details.st_mode)
                    or stat.S_IMODE(details.st_mode) != 0o700 or os.listdir(fd)):
                return False
            os.fchmod(fd, 0o500)
            details = os.fstat(fd)
            return stat.S_IMODE(details.st_mode) == 0o500 and not os.listdir(fd)
        finally:
            os.close(fd)
    except OSError:
        return False


def linux_mount_record(mountpoint: Path) -> tuple[str, str] | None:
    escaped = str(mountpoint).replace("\\", "\\134").replace("\t", "\\011").replace(" ", "\\040").replace("\n", "\\012")
    records = []
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        fields = line.split()
        if len(fields) <= 4 or fields[4] != escaped:
            continue
        if "-" not in fields:
            raise ValueError("invalid mountinfo row for target mountpoint")
        separator = fields.index("-")
        if len(fields) <= separator + 2:
            raise ValueError("invalid mountinfo row for target mountpoint")
        records.append((fields[separator + 1], fields[separator + 2]))
    if len(records) > 1:
        raise ValueError("ambiguous mountpoint has stacked mounts")
    return records[0] if records else None

def linux_validate_mount(settings: dict[str, Any], scratch: dict[str, Any], entry: Any) -> str:
    if scratch.get("backend", "fuse") == "native":
        return linux_validate_native_mount(settings, scratch, entry)
    image, mountpoint = linux_paths(scratch)
    if not isinstance(entry, dict) or entry.get("state") != "active":
        raise ValueError("Scratch volume is not registered active")
    if entry.get("image_path") != str(image) or entry.get("mountpoint") != str(mountpoint):
        raise ValueError("Scratch volume registry identity mismatch")
    quota = scratch["quota_gb"] * GIB
    if entry.get("quota_bytes") != quota or entry.get("filesystem_uuid") != linux_fs_uuid(image):
        raise ValueError("Scratch volume identity or capacity mismatch")
    if image.stat().st_size != quota:
        raise ValueError("Scratch image size differs from configured capacity")
    if linux_mount_record(mountpoint) != ("fuse.ext4", str(image)):
        raise ValueError("Scratch mount identity mismatch")
    return entry["filesystem_uuid"]


def linux_create_cmd(name: str, execute: bool = False) -> int:
    lock = None
    try:
        settings, scratch = cls(name)
        if name != "scratch" or not encryption_is_acknowledged(settings):
            return 2
        image, mountpoint = linux_paths(scratch)
        quota = scratch["quota_gb"] * GIB
        if quota > 200 * GIB:
            return 2
        reserve = (settings["swap_headroom_gb"] + settings["alarm_floor_gb"] + scratch["quota_gb"]) * GIB
        if not execute:
            if image.exists() or image.is_symlink():
                return 75
            if mountpoint.exists() and (mountpoint.is_symlink() or not mountpoint.is_dir()
                                        or mountpoint.stat().st_uid != os.geteuid()
                                        or any(mountpoint.iterdir())):
                return 75
            parent = image.parent
            while not parent.exists() and parent != parent.parent:
                parent = parent.parent
            if parent.is_symlink() or not parent.is_dir() or parent.stat().st_uid not in {0, os.geteuid()}:
                return 75
            if shutil.disk_usage(parent).free < reserve:
                return 2
            print(json.dumps({"class": name, "fits": True, "quota_bytes": quota,
                              "image_path": str(image), "mountpoint": str(mountpoint), "sparse": True}))
            return 0
        registry_file, lock = locked_registry()
        data = registry()
        if name in data["volumes"]:
            return 75
        # Recheck mutable filesystem and mountpoint preconditions while holding
        # the registry lock used by every diskm creator.
        if image.exists() or image.is_symlink():
            return 75
        if mountpoint.exists() and (mountpoint.is_symlink() or not mountpoint.is_dir()
                                    or mountpoint.stat().st_uid != os.geteuid()
                                    or any(mountpoint.iterdir())):
            return 75
        parent = image.parent
        while not parent.exists() and parent != parent.parent:
            parent = parent.parent
        if parent.is_symlink() or not parent.is_dir() or parent.stat().st_uid != os.geteuid():
            return 75
        if shutil.disk_usage(parent).free < reserve:
            return 2
        image.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if image.parent.is_symlink() or image.parent.stat().st_uid != os.geteuid():
            return 75
        fd = os.open(image, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
        try:
            os.ftruncate(fd, quota)
            os.fsync(fd)
        finally:
            os.close(fd)
        linux_command(["mke2fs", "-F", "-t", "ext4", "-m", "0", "-E",
                       f"root_owner={os.geteuid()}:{os.getegid()}", "-U", str(uuid.uuid4()),
                       "-L", "diskm-scratch", str(image), str(scratch["quota_gb"]) + "G"], 180)
        mountpoint.mkdir(mode=0o500, parents=True, exist_ok=True)
        mountpoint.chmod(0o500)
        fs_uuid = linux_fs_uuid(image)
        data["volumes"][name] = {"class": name, "name": scratch["name"], "filesystem_uuid": fs_uuid,
            "image_path": str(image), "mountpoint": str(mountpoint), "quota_bytes": quota,
            "state": "active", "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        save_registry(registry_file, lock, data)
        return 0
    except Exception:
        return 75
    finally:
        if lock is not None and not lock.closed:
            lock.close()


def linux_mount_cmd(name: str, foreground: bool = False) -> int:
    mount_fd = None
    process = None
    image = mountpoint = None
    started = False
    restored = False
    try:
        settings, scratch = cls(name)
        image, mountpoint = linux_paths(scratch)
        entry = registry()["volumes"].get(name)
        if not isinstance(entry, dict) or entry.get("state") != "active":
            return 75
        if scratch.get("backend", "fuse") == "native":
            return linux_native_mount_cmd(scratch, entry)
        mounted = linux_mount_record(mountpoint)
        if mounted:
            linux_validate_mount(settings, scratch, entry)
            # A systemd foreground invocation must own the FUSE process. An
            # already-mounted filesystem has no process for this invocation
            # to supervise, so fail instead of reporting a successful start.
            if foreground:
                return 75
            return 0
        if image.is_symlink() or not image.is_file() or image.stat().st_uid != os.geteuid():
            return 75
        if entry.get("filesystem_uuid") != linux_fs_uuid(image) or image.stat().st_size != entry.get("quota_bytes"):
            return 75
        if not linux_mountpoint_safe(mountpoint):
            if not linux_recover_underlay(mountpoint, image, entry):
                return 75
            if not linux_mountpoint_safe(mountpoint):
                return 75
        # Keep an FD to the verified underlay so its permissions can be restored
        # even after the mount obscures the path. fusermount requires a writable
        # mountpoint during startup, so widen only for the bounded handshake.
        mount_fd = os.open(mountpoint, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        underlay = os.fstat(mount_fd)
        if underlay.st_uid != os.geteuid() or not stat.S_ISDIR(underlay.st_mode):
            return 75
        os.fchmod(mount_fd, 0o700)
        args = ["fuse2fs", str(image), str(mountpoint), "-o", "noatime"]
        if foreground:
            args.append("-f")
        command, env = linux_command_env(args)
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, env=env, close_fds=True)
        started = True
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            mounted = linux_mount_record(mountpoint)
            if mounted:
                linux_validate_mount(settings, scratch, entry)
                os.fchmod(mount_fd, 0o500)
                restored = True
                if foreground:
                    return 0 if process.wait() == 0 else 75
                return 0
            if process.poll() is not None:
                return 75
            time.sleep(0.1)
        return 75
    except Exception as error:
        print("volume mount: " + str(error), file=sys.stderr)
        return 75
    finally:
        if process is not None and process.poll() is None and not restored:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if started and not restored and image is not None and mountpoint is not None:
            try:
                mounted = linux_mount_record(mountpoint)
                if mounted and mounted[1] == str(image):
                    linux_command(["fusermount3", "-u", str(mountpoint)])
            except Exception:
                pass
        if mount_fd is not None:
            try:
                if not restored:
                    os.fchmod(mount_fd, 0o500)
            finally:
                os.close(mount_fd)


def linux_status() -> int:
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    alarms: list[str] = []
    rows: list[dict[str, Any]] = []
    fatal = False
    try:
        settings, scratch = cls("scratch")
        image, mountpoint = linux_paths(scratch)
        entry = registry()["volumes"].get("scratch")
        mounted = linux_mount_record(mountpoint)
        identity_ok = False
        if isinstance(entry, dict) and entry.get("state") == "active" and mounted:
            linux_validate_mount(settings, scratch, entry)
            identity_ok = True
        backing_free = shutil.disk_usage(image.parent).free if image.parent.exists() else None
        volume_used = volume_free = None
        if identity_ok:
            usage = shutil.disk_usage(mountpoint)
            volume_used, volume_free = usage.total - usage.free, usage.free
        row = {
            "host_id": os.uname().nodename,
            "filesystem_id": entry.get("filesystem_uuid") if isinstance(entry, dict) else None,
            "kind": "filesystem",
            "source": "ext4_image",
            "path": str(mountpoint),
            "class": "scratch",
            "allocated_bytes": volume_used,
            "quota_bytes": scratch["quota_gb"] * GIB,
            "measured_at": timestamp if identity_ok else None,
            "status": "active" if identity_ok else "unavailable",
            "available": identity_ok,
            "attribution": "exclusive_exact",
        }
        rows.append(row)
        if not identity_ok:
            alarms.append("volume_measurement_unavailable:scratch")
        elif volume_used >= row["quota_bytes"]:
            alarms.append("volume_full")
        elif volume_used / row["quota_bytes"] >= 0.9:
            alarms.append("volume_high")
        output = {
            "measured_at": timestamp,
            "container": {"filesystem_id": None, "source": "linux_host_filesystem",
                          "ceiling_bytes": None, "free_bytes": backing_free},
            "capacity_fit": None,
            "volumes": rows,
            "alarms": alarms,
        }
    except Exception:
        fatal = True
        output = {"measured_at": timestamp, "container": {"filesystem_id": None,
            "source": "linux_host_filesystem", "ceiling_bytes": None, "free_bytes": None},
            "capacity_fit": None, "volumes": rows, "alarms": ["volume_measurement_unavailable"]}
    print(json.dumps(output, sort_keys=True))
    return 2 if fatal else (1 if alarms else 0)


def systemd_quote(value: str) -> str:
    if any(char in value for char in "\0\n\r"):
        raise ValueError("service argument contains a control character")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def linux_service_render(runtime: Path, config_path: str, state_path: Path,
                         backend: str) -> str:
    template = runtime / "systemd/diskm-scratch.service.in"
    rendered = template.read_text().replace("@ORCHESTRATOR@", systemd_quote(str(runtime / "disk_magician.sh")))
    rendered = rendered.replace("@CONFIG_PATH@", systemd_quote(config_path))
    rendered = rendered.replace("@STATE_PATH@", systemd_quote(str(state_path)))
    if backend == "native":
        if "Type=simple" not in rendered:
            raise ValueError("service template lacks FUSE service type")
        rendered = rendered.replace("Type=simple", "Type=oneshot\nRemainAfterExit=yes", 1)
    if "@" in rendered:
        raise ValueError("service template contains unresolved placeholders")
    return rendered


def linux_service_matches_fuse_unit(unit_bytes: bytes, runtime: Path,
                                      config_path: str, state_path: Path) -> bool:
    try:
        if unit_bytes == linux_service_render(runtime, config_path, state_path, "fuse").encode():
            return True
    except (OSError, ValueError):
        return False

    candidates = Path.home() / ".local/share/disk-magician/candidates"
    try:
        if candidates.is_symlink() or not candidates.is_dir():
            return False
        if candidates.resolve(strict=True) != candidates.absolute():
            return False
        if candidates.stat().st_uid != os.geteuid():
            return False
        for previous in candidates.iterdir():
            if not re.fullmatch(r"[0-9a-f]{40}", previous.name):
                continue
            if previous.is_symlink() or not previous.is_dir() or previous.stat().st_uid != os.geteuid():
                continue
            if previous.resolve(strict=True) != previous.absolute():
                continue
            template = previous / "systemd/diskm-scratch.service.in"
            orchestrator = previous / "disk_magician.sh"
            systemd = previous / "systemd"
            if (systemd.is_symlink() or template.is_symlink() or orchestrator.is_symlink() or
                    not systemd.is_dir() or not template.is_file() or not orchestrator.is_file()):
                continue
            if unit_bytes == linux_service_render(previous, config_path, state_path, "fuse").encode():
                return True
    except (OSError, ValueError):
        return False
    return False


def linux_atomic_bytes(path: Path, data: bytes, details: os.stat_result,
                      preserve_times: bool = False) -> None:
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".diskm-", dir=path.parent)
    os.fchmod(fd, stat.S_IMODE(details.st_mode))
    os.fchown(fd, details.st_uid, details.st_gid)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    if preserve_times:
        os.utime(path, ns=(details.st_atime_ns, details.st_mtime_ns), follow_symlinks=False)
        restored_fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            os.fsync(restored_fd)
        finally:
            os.close(restored_fd)
    linux_fsync_directory(path.parent)

def linux_fstab_change_result(output: bytes | str | None) -> bool | None:
    try:
        if output is None:
            return None
        result = json.loads(output)
        changed = result.get("changed") if isinstance(result, dict) else None
        return changed if isinstance(changed, bool) else None
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
        return None


def linux_docker_transport_info(image_id: str) -> tuple[str, dict[str, Any]]:
    """Validate the fixed rootful Docker transport without pulling or mutating."""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise ValueError("admin image id must be a full sha256 digest")
    details = DOCKER_SOCKET.lstat()
    if not stat.S_ISSOCK(details.st_mode) or details.st_uid != 0:
        raise ValueError("rootful Docker socket identity is unsafe")
    docker = shutil.which("docker")
    if not docker:
        raise ValueError("docker executable is unavailable")
    host = "unix:///var/run/docker.sock"
    result = subprocess.run(
        [docker, "--host", host, "info", "--format", "{{json .}}"],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "rootful Docker info failed")
    try:
        info = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("Docker info returned invalid JSON") from error
    if not isinstance(info, dict) or info.get("Rootless") is True:
        raise ValueError("Docker daemon is rootless")
    if info.get("DockerRootDir") != "/var/lib/docker":
        raise ValueError("Docker daemon root directory is not the fixed host root")
    security = info.get("SecurityOptions") or []
    if any("rootless" in str(item).lower() for item in security):
        raise ValueError("Docker daemon advertises rootless security")
    inspect = subprocess.run(
        [docker, "--host", host, "image", "inspect", "--format", "{{.Id}}", image_id],
        capture_output=True, text=True, timeout=30, check=False,
    )
    if inspect.returncode or inspect.stdout.strip() != image_id:
        raise ValueError("pinned admin image is not locally available")
    return docker, info


def linux_docker_helper_argv(
    docker: str, image_id: str, runtime: Path, action: str,
    config_path: Path, state: Path, user_uid: str, runtime_sha256: str | None = None,
) -> list[str]:
    if action not in {"probe", "install", "remove"}:
        raise ValueError("unsupported Docker fstab helper action")
    if runtime.is_symlink() or not runtime.is_dir() or not (runtime / "disk_magician.sh").is_file():
        raise ValueError("installed canonical runtime is unavailable")
    helper = str(runtime / "disk_magician.sh")
    args = ["volume", "fstab", action, "scratch", "--config", str(config_path),
            "--state-dir", str(state), "--user-uid", str(user_uid)]
    if runtime_sha256 is not None:
        if not re.fullmatch(r"[0-9a-f]{64}", runtime_sha256):
            raise ValueError("runtime hash is invalid")
        args.extend(("--runtime-sha256", runtime_sha256))
    if action in {"install", "remove"}:
        args.append("--execute")
    quoted = " ".join(shlex.quote(item) for item in args)
    command = (
        "exec chroot /host /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "
        f"/usr/bin/bash {shlex.quote(helper)} {quoted}"
    )
    mounts = [
        "--mount", "type=bind,src=/,dst=/host,readonly",
        "--mount", "type=bind,src=/proc,dst=/host/proc,readonly",
        "--mount", "type=bind,src=/sys,dst=/host/sys,readonly",
    ]
    if action in {"install", "remove"}:
        mounts[2:2] = ["--mount", "type=bind,src=/etc,dst=/host/etc"]
    return [
        docker, "--host", "unix:///var/run/docker.sock", "run", "--rm", "--pull", "never",
        "--network", "none", *DOCKER_TRANSPORT_FLAGS, "--read-only",
        *mounts,
        "--entrypoint", "/bin/sh", image_id, "-c", command,
    ]


def linux_docker_fstab_command(
    docker: str, image_id: str, runtime: Path, action: str,
    config_path: Path, state: Path, user_uid: str, runtime_sha256: str | None = None,
) -> subprocess.CompletedProcess[str]:
    argv = linux_docker_helper_argv(docker, image_id, runtime, action, config_path, state, user_uid,
                                    runtime_sha256)
    return subprocess.run(argv, capture_output=True, text=True, timeout=60, check=False)


def linux_docker_probe(
    docker: str, image_id: str, runtime: Path, config_path: Path, state: Path, user_uid: str,
    runtime_sha256: str | None = None,
) -> dict[str, Any]:
    result = linux_docker_fstab_command(docker, image_id, runtime, "probe", config_path, state,
                                        user_uid, runtime_sha256)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Docker fstab probe failed")
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("Docker fstab probe returned invalid JSON") from error
    if not isinstance(value, dict) or value.get("probe") != "fstab":
        raise ValueError("Docker fstab probe returned an invalid view")
    return value


def linux_assert_admin_view(host: dict[str, Any], privileged: dict[str, Any]) -> None:
    keys = ("mount", "loop_devices", "writer_pids", "reader_pids", "image", "mountpoint")
    if "runtime_sha256" in host or "runtime_sha256" in privileged:
        keys += ("runtime_sha256",)
    for view in (host, privileged):
        if not isinstance(view, dict) or any(key not in view or view[key] is None for key in keys):
            raise RuntimeError("admin transport view is incomplete")
        for key in ("loop_devices", "writer_pids", "reader_pids"):
            if (not isinstance(view[key], list) or
                    not all(isinstance(item, (str, int)) and not isinstance(item, bool)
                            for item in view[key])):
                raise RuntimeError("admin transport PID/mount view has an invalid list")
        if not isinstance(view["image"], str) or not isinstance(view["mountpoint"], str):
            raise RuntimeError("admin transport path view is invalid")
    for key in keys:
        if host.get(key) != privileged.get(key):
            raise RuntimeError("admin transport view differs from host for " + key)
    writers = host.get("writer_pids")
    if not isinstance(writers, list) or not writers:
        raise RuntimeError("Scratch FUSE writer set is empty or unknown before stop")


def linux_service_migrate_cmd(arguments: list[str]) -> int:
    config_path = unit = None
    state = image = mountpoint = None
    config_bytes = unit_bytes = b""
    config_stat = unit_stat = None
    fstab_install_attempted = False
    fstab_install_changed: bool | None = None
    admin_transport = "sudo"
    admin_image_id: str | None = None
    docker = None
    transaction_started = False
    try:
        if not arguments or arguments[0] != "scratch":
            return 2
        values: dict[str, str] = {}
        execute = False
        index = 1
        while index < len(arguments):
            key = arguments[index]
            if key == "--execute":
                execute = True
                index += 1
            elif key in {"--backend", "--config", "--state-dir", "--user-uid",
                         "--admin-transport", "--admin-image-id"} and index + 1 < len(arguments):
                values[key] = arguments[index + 1]
                index += 2
            else:
                return 2
        required = {"--backend", "--config", "--state-dir", "--user-uid"}
        if not required.issubset(values) or not execute or values["--backend"] != "native":
            return 2
        extra = set(values) - required
        if extra - {"--admin-transport", "--admin-image-id"}:
            return 2
        admin_transport = values.get("--admin-transport", "sudo")
        admin_image_id = values.get("--admin-image-id")
        if admin_transport not in {"sudo", "docker"}:
            return 2
        if admin_transport == "docker" and admin_image_id is None:
            return 2
        if admin_transport == "sudo" and admin_image_id is not None:
            return 2
        allowed = linux_fstab_allowed_paths(values["--config"], values["--state-dir"], values["--user-uid"], None)
        if allowed is None or int(values["--user-uid"]) != os.geteuid():
            return 75
        config_path, state, image, mountpoint = allowed
        settings, scratch = cls("scratch", config_path)
        entry = registry(state)["volumes"].get("scratch")
        if (not isinstance(entry, dict) or entry.get("state") != "active" or
                scratch.get("backend", "fuse") != "fuse"):
            return 75
        linux_validate_mount(settings, scratch, entry)
        unit = Path.home() / ".config/systemd/user/diskm-scratch.service"
        if unit.is_symlink() or not unit.is_file() or unit.stat().st_uid != os.geteuid():
            return 75
        try:
            for protected_path in (config_path, unit):
                if os.listxattr(protected_path, follow_symlinks=False):
                    raise ValueError("migration refuses files with extended attributes or ACLs")
        except (AttributeError, OSError) as error:
            raise ValueError("migration cannot verify file extended attributes or ACLs") from error
        config_bytes, config_stat = config_path.read_bytes(), config_path.stat()
        unit_bytes, unit_stat = unit.read_bytes(), unit.stat()
        runtime = Path(__file__).resolve().parent.parent
        if (runtime / ".git").exists() or not (runtime / "disk_magician.sh").is_file():
            return 75
        runtime_sha256 = None
        if not linux_service_matches_fuse_unit(unit_bytes, runtime, str(config_path), state):
            return 75
        if admin_transport == "docker":
            runtime_sha256 = linux_validate_installed_runtime(runtime, state)
            docker, _ = linux_docker_transport_info(admin_image_id or "")
            host_view = linux_host_fstab_probe(image, mountpoint, runtime_sha256)
            privileged_view = linux_docker_probe(
                docker, admin_image_id or "", runtime, config_path, state, values["--user-uid"],
                runtime_sha256,
            )
            linux_assert_admin_view(host_view, privileged_view)
        systemctl = ["systemctl", "--user"]
        transaction_started = True
        linux_command(systemctl + ["stop", "diskm-scratch.service"], 60)
        if (linux_mount_record(mountpoint) is not None or linux_image_has_loop_mapping(image) or
                linux_image_has_open_writers(image)):
            raise RuntimeError("FUSE image remains mounted or open after stop")
        fstab_install_attempted = True
        try:
            if admin_transport == "docker":
                result = linux_docker_fstab_command(
                    docker, admin_image_id or "", runtime, "install", config_path, state,
                    values["--user-uid"], runtime_sha256,
                )
            else:
                root_cmd = ["bash", str(runtime / "disk_magician.sh"), "volume", "fstab", "install", "scratch",
                            "--config", str(config_path), "--state-dir", str(state),
                            "--user-uid", values["--user-uid"], "--execute"]
                result = subprocess.run(["sudo", "-n", *root_cmd], capture_output=True, timeout=45, check=False)
        except subprocess.TimeoutExpired as error:
            fstab_install_changed = linux_fstab_change_result(error.stdout or error.output)
            raise
        fstab_install_changed = linux_fstab_change_result(result.stdout)
        if result.returncode or fstab_install_changed is None:
            raise RuntimeError("administrator fstab installation failed or returned no change receipt")
        document = json.loads(config_bytes)
        document["volumes"]["classes"]["scratch"]["backend"] = "native"
        linux_atomic_bytes(config_path, (json.dumps(document, indent=2) + "\n").encode(), config_stat)
        native_unit = linux_service_render(runtime, str(config_path), state, "native")
        linux_atomic_bytes(unit, native_unit.encode(), unit_stat)
        linux_command(systemctl + ["daemon-reload"])
        linux_command(systemctl + ["start", "diskm-scratch.service"], 60)
        settings, scratch = cls("scratch", config_path)
        linux_validate_native_mount(settings, scratch, registry(state)["volumes"].get("scratch"))
        linux_command(systemctl + ["is-active", "--quiet", "diskm-scratch.service"])
        return 0
    except Exception as error:
        print("volume service migrate: " + str(error), file=sys.stderr)
        if config_path is None or unit is None or config_stat is None or unit_stat is None:
            return 75
        if not transaction_started:
            return 75
        stopped = True
        try:
            linux_command(["systemctl", "--user", "stop", "diskm-scratch.service"], 60)
        except Exception:
            stopped = False
        try:
            resources_busy = (
                linux_mount_record(mountpoint) is not None or
                linux_image_has_loop_mapping(image) or
                linux_image_has_open_writers(image)
            )
        except Exception:
            resources_busy = True
        try:
            linux_atomic_bytes(config_path, config_bytes, config_stat, preserve_times=True)
            linux_atomic_bytes(unit, unit_bytes, unit_stat, preserve_times=True)
            linux_command(["systemctl", "--user", "daemon-reload"])
            if fstab_install_attempted and fstab_install_changed is None:
                return 75
            if fstab_install_attempted and fstab_install_changed and not resources_busy:
                if admin_transport == "docker":
                    rollback = linux_docker_fstab_command(
                        docker, admin_image_id or "", Path(__file__).resolve().parent.parent,
                        "remove", config_path, state, str(os.geteuid()), runtime_sha256,
                    )
                else:
                    root_cmd = ["bash", str(Path(__file__).resolve().parent.parent / "disk_magician.sh"),
                                "volume", "fstab", "remove", "scratch", "--config", str(config_path),
                                "--state-dir", str(state), "--user-uid", str(os.geteuid()), "--allow-absent", "--execute"]
                    rollback = subprocess.run(["sudo", "-n", *root_cmd], capture_output=True,
                                               timeout=45, check=False)
                if rollback.returncode:
                    return 75
            if not stopped or resources_busy:
                return 75
            if (linux_mount_record(mountpoint) is not None or linux_image_has_loop_mapping(image) or
                    linux_image_has_open_writers(image)):
                return 75
            linux_command(["systemctl", "--user", "start", "diskm-scratch.service"], 60)
        except Exception:
            return 75
        return 75

def linux_service_install_cmd(name: str) -> int:
    try:
        if name != "scratch":
            return 2
        _, scratch = cls(name)
        entry = registry()["volumes"].get(name)
        image, mountpoint = linux_paths(scratch)
        if not isinstance(entry, dict) or entry.get("state") != "active":
            return 75
        if entry.get("image_path") != str(image) or entry.get("mountpoint") != str(mountpoint):
            return 75
        if linux_mount_record(mountpoint):
            # Do not let systemd claim an unmanaged mount. Only an already
            # active instance of this exact unit can legitimately own it.
            linux_validate_mount(cls(name)[0], scratch, entry)
            linux_command(["systemctl", "--user", "is-active", "--quiet", "diskm-scratch.service"], 15)
        unit_template = Path(__file__).resolve().parent.parent / "systemd" / "diskm-scratch.service.in"
        if not unit_template.is_file():
            return 75
        import resolve_config
        config_path = resolve_config.resolve()
        if not config_path:
            return 75
        runtime_root = Path(__file__).resolve().parent.parent
        # A service must be bound to the installed candidate package, never a
        # mutable source checkout that can change beneath systemd.
        if (runtime_root / ".git").exists():
            return 75
        orchestrator = runtime_root / "disk_magician.sh"
        if not orchestrator.is_file():
            return 75
        rendered = linux_service_render(runtime_root, config_path, state_root(),
                                        scratch.get("backend", "fuse"))
        unit_dir = Path.home() / ".config/systemd/user"
        unit_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        unit = unit_dir / "diskm-scratch.service"
        if unit.is_symlink() or (unit.exists() and (not unit.is_file() or unit.stat().st_uid != os.geteuid())):
            return 75
        if unit.exists():
            if unit.read_text() != rendered:
                return 75
        else:
            descriptor = os.open(unit, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                stream.write(rendered)
                stream.flush()
                os.fsync(stream.fileno())
        linux_command(["systemctl", "--user", "daemon-reload"])
        linux_command(["systemctl", "--user", "enable", "--now", "diskm-scratch.service"], 60)
        linux_command(["systemctl", "--user", "is-active", "--quiet", "diskm-scratch.service"], 15)
        settings, scratch = cls(name)
        _, mountpoint = linux_paths(scratch)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            active = subprocess.run(["systemctl", "--user", "is-active", "--quiet",
                                     "diskm-scratch.service"], capture_output=True, check=False)
            mounted = linux_mount_record(mountpoint)
            if active.returncode == 0 and mounted:
                linux_validate_mount(settings, scratch, registry()["volumes"].get(name))
                return 0
            time.sleep(0.1)
        return 75
    except Exception:
        return 75


def linux_unmount_cmd(name: str) -> int:
    try:
        settings, scratch = cls(name)
        _, mountpoint = linux_paths(scratch)
        entry = registry()["volumes"].get(name)
        linux_validate_mount(settings, scratch, entry)
        if scratch.get("backend", "fuse") == "native":
            return linux_native_unmount_cmd(scratch, entry)
        linux_command(["fusermount3", "-u", str(mountpoint)])
        return 0 if linux_mount_record(mountpoint) is None else 75
    except Exception:
        return 75


def linux_scheduler_install_cmd(name: str, interval: int | None = None) -> int:
    try:
        if name != "scratch" or not linux_backend_enabled(name):
            return 2
        if interval is not None:
            require_positive(interval, "scheduler interval")
        import resolve_config
        resolved = resolve_config.resolve()
        if not resolved:
            return 75
        config_path = Path(resolved).resolve(strict=True)
        settings, scratch = cls(name)
        linux_validate_mount(settings, scratch, registry()["volumes"].get(name))
        production = config_path == Path.home() / ".config/disk-magician/linux-scratch.json"
        protected = (scratch["mountpoint"] == str(Path.home() / "Scratch") or
                     scratch["image_path"] == str(Path.home() / ".local/share/disk-magician/volumes/scratch.ext4"))
        if (interval is not None and (production or protected)) or (protected and not production):
            return 75
        unit_name = "diskm-scratch-reclaim"
        if not production:
            unit_name += "-" + hashlib.sha256(os.fsencode(config_path)).hexdigest()[:12]
        runtime = Path(__file__).resolve().parent.parent
        if (runtime / ".git").exists() or not (runtime / "disk_magician.sh").is_file():
            return 75
        if production and any(runtime.is_relative_to(path.resolve()) for path in (Path("/tmp"), Path("/var/tmp"))):
            return 75
        values = {"@ORCHESTRATOR@": str(runtime / "disk_magician.sh"),
                  "@CONFIG_PATH@": str(config_path), "@STATE_PATH@": str(state_root().resolve()),
                  "@DELETION_LOG@": str(state_root().resolve() / "deletions.log")}
        if any(any(c in value for c in "%$") for value in values.values()):
            return 75
        cadence = "OnCalendar=hourly\nPersistent=true"
        if interval is not None:
            cadence = f"OnBootSec=5s\nOnUnitActiveSec={interval}s\nAccuracySec=1s"
        units = []
        unit_dir = Path.home() / ".config/systemd/user"
        for suffix in ("service", "timer"):
            content = (runtime / "systemd" / f"diskm-scratch-reclaim.{suffix}.in").read_text()
            for key, value in values.items():
                content = content.replace(key, systemd_quote(value))
            content = content.replace("@UNIT_NAME@", unit_name).replace("@CADENCE@", cadence)
            if "@" in content:
                return 75
            target = unit_dir / f"{unit_name}.{suffix}"
            if target.is_symlink() or (target.exists() and
                    (not target.is_file() or target.stat().st_uid != os.geteuid() or target.read_text() != content)):
                return 75
            units.append((target, content))
        unit_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        for target, content in units:
            if not target.exists():
                with os.fdopen(os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
                    stream.write(content)
                    stream.flush()
                    os.fsync(stream.fileno())
        linux_command(["systemctl", "--user", "daemon-reload"])
        linux_validate_mount(settings, scratch, registry()["volumes"].get(name))
        if production:
            usage = shutil.disk_usage(scratch["mountpoint"])
            if (usage.total - usage.free) * 100 >= scratch["quota_gb"] * GIB * 90 or not ballast_ok(scratch["mountpoint"]):
                return 75
        linux_command(["systemctl", "--user", "enable", "--now", unit_name + ".timer"])
        linux_command(["systemctl", "--user", "is-active", "--quiet", unit_name + ".timer"])
        print(json.dumps({"unit": unit_name, "runtime": str(runtime), "config": str(config_path),
            "config_sha256": hashlib.sha256(config_path.read_bytes()).hexdigest(),
            "units": [{"path": str(p), "mtime_ns": p.stat().st_mtime_ns,
                       "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p, _ in units]}, sort_keys=True))
        print(unit_name)
        return 0
    except Exception as error:
        print("volume scheduler: " + str(error), file=sys.stderr)
        return 75


def linux_path_components_owned(path: Path, uid: int) -> bool:
    if not path.is_absolute():
        return False
    current = Path("/")
    try:
        for index, component in enumerate(path.parts[1:], 1):
            current = current / component
            details = current.lstat()
            if stat.S_ISLNK(details.st_mode) or details.st_uid not in {0, uid}:
                return False
            if index < len(path.parts) - 1 and not stat.S_ISDIR(details.st_mode):
                return False
        return True
    except OSError:
        return False


def linux_fixture_paths(config_path: str, state_path: str, user_uid: str,
                        fixture_root: str) -> tuple[Path, Path, Path, Path] | None:
    """Validate the exact private fixture tuple before any privileged operation."""
    try:
        uid = int(user_uid)
        if uid < 0:
            return None
        root_arg = Path(fixture_root)
        config_arg = Path(config_path)
        state_arg = Path(state_path)
        if not all(linux_path_components_owned(path, uid)
                   for path in (root_arg, config_arg, state_arg)):
            return None
        root = root_arg.resolve(strict=True)
        config = config_arg.resolve(strict=True)
        state = state_arg.resolve(strict=True)
        rs = root.lstat()
        if (not stat.S_ISDIR(rs.st_mode) or rs.st_uid != uid or
                stat.S_IMODE(rs.st_mode) != 0o700 or root != root_arg):
            return None
        if (config != config_arg or state != state_arg or
                not config.is_relative_to(root) or not state.is_relative_to(root)):
            return None
        for path in (config, state):
            ps = path.lstat()
            if ps.st_uid != uid or stat.S_ISLNK(ps.st_mode):
                return None
        if not stat.S_ISDIR(state.lstat().st_mode):
            return None
        document = json.loads(config.read_text())
        scratch = document["volumes"]["classes"]["scratch"]
        image_arg = Path(scratch["image_path"])
        mount_arg = Path(scratch["mountpoint"])
        if not image_arg.is_absolute() or not mount_arg.is_absolute():
            return None
        if not all(linux_path_components_owned(path, uid) for path in (image_arg, mount_arg)):
            return None
        image = image_arg.resolve(strict=True)
        mountpoint = mount_arg.resolve(strict=True)
        if image != image_arg or mountpoint != mount_arg:
            return None
        if not image.is_relative_to(root) or not mountpoint.is_relative_to(root):
            return None
        if (image.is_relative_to(mountpoint) or mountpoint.is_relative_to(image) or
                config.is_relative_to(mountpoint) or state.is_relative_to(mountpoint) or
                mountpoint.is_relative_to(config) or mountpoint.is_relative_to(state)):
            return None
        for path, expected_type in ((image, stat.S_ISREG), (mountpoint, stat.S_ISDIR)):
            ps = path.lstat()
            if ps.st_uid != uid or not expected_type(ps.st_mode) or stat.S_ISLNK(ps.st_mode):
                return None
        return config, state, image, mountpoint
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError, OverflowError):
        return None


def linux_fstab_allowed_paths(config_path: str, state_path: str, user_uid: str,
                             fixture_root: str | None) -> tuple[Path, Path, Path, Path] | None:
    if fixture_root is not None:
        return linux_fixture_paths(config_path, state_path, user_uid, fixture_root)
    try:
        uid = int(user_uid)
        home = Path(pwd.getpwuid(uid).pw_dir)
        config = Path(config_path)
        state = Path(state_path)
        if (uid < 0 or home.lstat().st_uid != uid or
                config != home / ".config/disk-magician/linux-scratch.json" or
                state != home / ".disk_magician_state" or
                not all(linux_path_components_owned(path, uid)
                        for path in (home, config, state))):
            return None
        if (config.resolve(strict=True) != config or state.resolve(strict=True) != state or
                config.stat().st_uid != uid or state.stat().st_uid != uid or
                not state.is_dir()):
            return None
        document = json.loads(config.read_text())
        scratch = document["volumes"]["classes"]["scratch"]
        image = Path(scratch["image_path"])
        mountpoint = Path(scratch["mountpoint"])
        if (image != home / ".local/share/disk-magician/volumes/scratch.ext4" or
                mountpoint != home / "Scratch" or
                not all(linux_path_components_owned(path, uid) for path in (image, mountpoint)) or
                image.resolve(strict=True) != image or
                mountpoint.resolve(strict=True) != mountpoint or image.stat().st_uid != uid or
                mountpoint.stat().st_uid != uid or not image.is_file() or not mountpoint.is_dir()):
            return None
        return config, state, image, mountpoint
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError, KeyError):
        return None


def linux_fstab_path() -> Path:
    return Path("/etc/fstab")


def linux_fstab_lock_path() -> Path:
    return Path("/etc/.diskm-fstab.lock")


def linux_fstab_lock() -> int:
    path = linux_fstab_lock_path()
    parent = path.parent.lstat()
    if not stat.S_ISDIR(parent.st_mode) or stat.S_ISLNK(parent.st_mode) or parent.st_mode & 0o022:
        raise PermissionError("fstab lock parent is not private to its owner")
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    details = os.fstat(descriptor)
    if not stat.S_ISREG(details.st_mode) or details.st_uid != parent.st_uid or stat.S_IMODE(details.st_mode) != 0o600:
        os.close(descriptor)
        raise PermissionError("fstab lock identity is unsafe")
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    return descriptor


def linux_fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def linux_fstab_validate(data: bytes) -> None:
    for number, line in enumerate(data.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith(b"#"):
            continue
        fields = stripped.split()
        if (len(fields) != 6 or not fields[4].isdigit() or not fields[5].isdigit() or
                any(any(byte < 32 for byte in field) for field in fields)):
            raise ValueError("invalid fstab record at line " + str(number))


def linux_fstab_marker_id(uid: str, config: Path, state: Path, image: Path,
                          mountpoint: Path) -> str:
    raw = "\0".join((uid, str(config), str(state), str(image), str(mountpoint)))
    return hashlib.sha256(os.fsencode(raw)).hexdigest()


def linux_fstab_block(uid: str, config: Path, state: Path, image: Path,
                      mountpoint: Path) -> bytes:
    if any(any(c.isspace() or c == "\\" or ord(c) < 32 for c in str(path)) for path in (image, mountpoint)):
        raise ValueError("fstab paths may not contain whitespace or control characters")
    marker = linux_fstab_marker_id(uid, config, state, image, mountpoint)
    return (f"# diskm-scratch:{marker}:begin\n{image} {mountpoint} ext4 "
            "loop,user,noauto,nosuid,nodev,noatime,exec 0 0\n"
            f"# diskm-scratch:{marker}:end\n").encode()


def linux_fstab_decode_field(field: bytes) -> bytes:
    return re.sub(rb"\\([0-7]{3})", lambda match: bytes((int(match.group(1), 8),)), field)


def linux_fstab_markers(lines: list[bytes]) -> dict[bytes, tuple[int, int]]:
    begins: dict[bytes, int] = {}
    ends: dict[bytes, int] = {}
    active: bytes | None = None
    prefix = b"# diskm-scratch:"
    for index, line in enumerate(lines):
        candidate = line.rstrip(b"\r\n")
        if not candidate.lstrip().startswith(prefix):
            continue
        match = re.fullmatch(rb"# diskm-scratch:([0-9a-f]{64}):(begin|end)", candidate)
        if match is None:
            raise ValueError("malformed managed fstab marker")
        marker, boundary = match.groups()
        if boundary == b"begin":
            if active is not None or marker in begins:
                raise ValueError("duplicate or malformed managed fstab markers")
            begins[marker] = index
            active = marker
            continue
        if active != marker or marker not in begins or marker in ends:
            raise ValueError("orphan or mismatched managed fstab marker")
        begin = begins[marker]
        record = lines[begin + 1].strip() if index == begin + 2 else b""
        if not record or record.startswith(b"#"):
            raise ValueError("malformed managed fstab block")
        ends[marker] = index
        active = None
    if active is not None or begins.keys() != ends.keys():
        raise ValueError("orphan managed fstab marker")
    return {marker: (begin, ends[marker]) for marker, begin in begins.items()}


def linux_fstab_transform(data: bytes, block: bytes, image: Path, mountpoint: Path,
                          action: str) -> bytes:
    linux_fstab_validate(data)
    lines = data.splitlines(keepends=True)
    block_lines = block.splitlines(keepends=True)
    pairs = linux_fstab_markers(lines)
    begin_match = re.fullmatch(rb"# diskm-scratch:([0-9a-f]{64}):begin\r?\n", block_lines[0])
    end_match = re.fullmatch(rb"# diskm-scratch:([0-9a-f]{64}):end\r?\n", block_lines[-1])
    if begin_match is None or end_match is None or begin_match.group(1) != end_match.group(1):
        raise ValueError("invalid requested managed fstab block")
    own_marker = begin_match.group(1)
    existing = b""
    if own_marker in pairs:
        start, finish = pairs[own_marker]
        if (finish != start + 2 or lines[start].rstrip(b"\\r\\n") != block_lines[0].rstrip(b"\\r\\n") or
                lines[start + 1] != block_lines[1] or
                lines[finish].rstrip(b"\\r\\n") != block_lines[-1].rstrip(b"\\r\\n")):
            raise ValueError("managed fstab block does not match requested identity")
        existing = b"".join(lines[start:finish + 1])
        del lines[start:finish + 1]
    for line in lines:
        if line.lstrip().startswith(b"#"):
            continue
        fields = line.split()
        if len(fields) >= 2 and (
                linux_fstab_decode_field(fields[0]) == os.fsencode(image) or
                linux_fstab_decode_field(fields[1]) == os.fsencode(mountpoint)):
            raise ValueError("conflicting unmanaged fstab entry")
    if action in {"remove", "remove-if-present"}:
        if not existing and action == "remove":
            raise ValueError("exact managed fstab entry is absent")
        output = b"".join(lines)
        linux_fstab_validate(output)
        return output
    if action == "install":
        if existing:
            return data
        output = b"".join(lines)
        # A table without a final newline keeps its original bytes after the
        # managed block; prefixing the block avoids inventing an EOF newline.
        output = (block + output) if output and not output.endswith(b"\n") else (output + block)
        linux_fstab_validate(output)
        return output
    raise ValueError("unknown fstab action")
def linux_fstab_write(path: Path, old: bytes, new: bytes) -> None:
    if os.geteuid() != 0:
        raise PermissionError("fstab changes require administrator authentication")
    try:
        attributes = os.listxattr(path, follow_symlinks=False)
        if not isinstance(attributes, list) or attributes:
            raise OSError("fstab mutation refuses extended attributes or ACLs")
    except (AttributeError, OSError, TypeError) as error:
        raise OSError("fstab mutation cannot verify extended attributes or ACLs") from error
    details = path.stat()
    backup = path.with_name(path.name + ".diskm-backup-" + hashlib.sha256(old).hexdigest()[:16])
    try:
        backup_fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                            stat.S_IMODE(details.st_mode))
    except FileExistsError:
        existing = backup.stat()
        if (backup.is_symlink() or backup.read_bytes() != old or existing.st_uid != details.st_uid or
                existing.st_gid != details.st_gid or
                stat.S_IMODE(existing.st_mode) != stat.S_IMODE(details.st_mode)):
            raise OSError("fstab backup identity mismatch")
    else:
        try:
            os.fchown(backup_fd, details.st_uid, details.st_gid)
            os.fchmod(backup_fd, stat.S_IMODE(details.st_mode))
            with os.fdopen(backup_fd, "wb") as stream:
                stream.write(old)
                stream.flush()
                os.fsync(stream.fileno())
            backup_dir_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(backup_dir_fd)
            finally:
                os.close(backup_dir_fd)
        except Exception:
            raise
    fd, temporary = tempfile.mkstemp(prefix=".fstab-diskm-", dir=path.parent)
    try:
        os.fchmod(fd, stat.S_IMODE(details.st_mode))
        os.fchown(fd, details.st_uid, details.st_gid)
        with os.fdopen(fd, "wb") as stream:
            stream.write(new)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        linux_fsync_directory(path.parent)
        if path.read_bytes() != new:
            raise OSError("fstab read-back mismatch")
        linux_fstab_validate(path.read_bytes())
    except Exception:
        try:
            restore_needed = path.read_bytes() != old
        except OSError:
            restore_needed = True
        if restore_needed:
            linux_atomic_bytes(path, old, details, preserve_times=True)
        raise


def linux_image_has_loop_mapping(image: Path) -> bool:
    """Fail closed if any kernel loop device still references this image."""
    root = Path("/sys/block")
    if not root.is_dir():
        return True
    for backing in root.glob("loop*/loop/backing_file"):
        try:
            value = backing.read_text().rstrip("\n").replace("\\040", " ")
        except OSError:
            return True
        if value and Path(value).resolve() == image.resolve():
            return True
    return False


def linux_image_has_open_writers(image: Path) -> bool:
    pids = linux_fuser_pid_set(image, writers_only=True)
    return pids is None or bool(pids)


def linux_fstab_cmd(action: str, arguments: list[str]) -> int:
    lock_fd = None
    try:
        if not arguments or arguments[0] != "scratch":
            return 2
        values: dict[str, str] = {}
        execute = False
        allow_absent = False
        i = 1
        while i < len(arguments):
            key = arguments[i]
            if key == "--execute":
                execute = True
                i += 1
            elif key == "--allow-absent":
                allow_absent = True
                i += 1
            elif key in {"--config", "--state-dir", "--user-uid", "--fixture-root",
                         "--runtime-sha256"} and i + 1 < len(arguments):
                values[key] = arguments[i + 1]
                i += 2
            else:
                return 2
        required = {"--config", "--user-uid"}
        if (not required.issubset(values)
                or set(values) - required - {"--state-dir", "--fixture-root", "--runtime-sha256"}):
            return 2
        if "--state-dir" not in values:
            if "--fixture-root" in values:
                return 2
            values["--state-dir"] = str(Path(pwd.getpwuid(int(values["--user-uid"])).pw_dir) / ".disk_magician_state")
        if ((action in {"preview", "probe"} and execute) or
                (action in {"install", "remove"} and not execute) or
                (action not in {"preview", "probe", "install", "remove"}) or
                (allow_absent and action != "remove")):
            return 2
        safe = linux_fstab_allowed_paths(values["--config"], values["--state-dir"], values["--user-uid"], values.get("--fixture-root"))
        if safe is None:
            return 75
        if "--runtime-sha256" in values:
            runtime_file = Path(__file__).resolve()
            if (not re.fullmatch(r"[0-9a-f]{64}", values["--runtime-sha256"])
                    or hashlib.sha256(runtime_file.read_bytes()).hexdigest() != values["--runtime-sha256"]):
                return 75
        if action == "probe":
            config, state, image, mountpoint = safe
            view = linux_host_fstab_probe(image, mountpoint, values.get("--runtime-sha256"))
            print(json.dumps({"probe": "fstab", **view}, sort_keys=True), flush=True)
            return 0
        if action != "preview":
            if os.geteuid() != 0:
                runtime = Path(__file__).resolve().parent.parent
                if (runtime / ".git").exists() or not (runtime / "disk_magician.sh").is_file():
                    return 75
                root_args = [str(runtime / "disk_magician.sh"), "volume", "fstab", action,
                             "scratch", "--config", str(safe[0]), "--state-dir", str(safe[1]),
                             "--user-uid", values["--user-uid"]]
                if "--fixture-root" in values:
                    root_args.extend(("--fixture-root", values["--fixture-root"]))
                if allow_absent:
                    root_args.append("--allow-absent")
                root_args.append("--execute")
                result = subprocess.run(["sudo", "-n", "bash", *root_args],
                                        capture_output=True, text=True, timeout=45, check=False)
                if result.stdout:
                    print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
                if result.stderr:
                    print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", file=sys.stderr)
                return 0 if result.returncode == 0 else 75
            lock_fd = linux_fstab_lock()
        config, state, image, mountpoint = safe
        block = linux_fstab_block(values["--user-uid"], config, state, image, mountpoint)
        path = linux_fstab_path()
        old = path.read_bytes()
        if action == "remove" and (linux_mount_record(mountpoint) is not None or
                                    linux_image_has_loop_mapping(image) or
                                    linux_image_has_open_writers(image)):
            return 75
        transform_action = "install"
        if action == "remove":
            transform_action = "remove-if-present" if allow_absent else "remove"
        new = linux_fstab_transform(old, block, image, mountpoint, transform_action)
        print(json.dumps({"path": str(path), "changed": old != new,
                          "before_sha256": hashlib.sha256(old).hexdigest(),
                          "after_sha256": hashlib.sha256(new).hexdigest()}, sort_keys=True), flush=True)
        if action != "preview" and old != new:
            linux_fstab_write(path, old, new)
        return 0
    except Exception as error:
        print("volume fstab: " + str(error), file=sys.stderr)
        return 75
    finally:
        if lock_fd is not None:
            os.close(lock_fd)


def linux_service_control_cmd(arguments: list[str]) -> int:
    """Explicitly stop/start only the verified Scratch user service unit."""
    try:
        if len(arguments) < 2 or arguments[0] not in {"stop", "start"} or arguments[1] != "scratch":
            return 2
        action = arguments[0]
        values: dict[str, str] = {}
        execute = False
        index = 2
        while index < len(arguments):
            key = arguments[index]
            if key == "--execute":
                execute = True
                index += 1
            elif key in {"--config", "--state-dir", "--user-uid"} and index + 1 < len(arguments):
                values[key] = arguments[index + 1]
                index += 2
            else:
                return 2
        if not execute or set(values) != {"--config", "--state-dir", "--user-uid"}:
            return 2
        user_uid = int(values["--user-uid"])
        if os.geteuid() != user_uid:
            return 75
        safe = linux_fstab_allowed_paths(values["--config"], values["--state-dir"],
                                          values["--user-uid"], None)
        if safe is None:
            return 75
        config_path, state, image, mountpoint = safe
        settings, scratch = cls("scratch", config_path)
        entry = registry(state)["volumes"].get("scratch")
        if (not isinstance(entry, dict) or entry.get("state") != "active"
                or entry.get("image_path") != str(image)
                or entry.get("mountpoint") != str(mountpoint)):
            return 75
        linux_validate_mount(settings, scratch, entry)
        unit = Path.home() / ".config/systemd/user/diskm-scratch.service"
        runtime = Path(__file__).resolve().parent.parent
        if (unit.is_symlink() or not unit.is_file() or unit.stat().st_uid != user_uid
                or not linux_service_matches_fuse_unit(unit.read_bytes(), runtime,
                                                        str(config_path), state)):
            return 75
        active = subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", "diskm-scratch.service"],
            capture_output=True, timeout=15, check=False,
        )
        if active.returncode not in {0, 3}:
            return 75
        if action == "stop":
            if active.returncode != 0:
                return 75
            linux_command(["systemctl", "--user", "stop", "diskm-scratch.service"], 60)
            return 0
        if active.returncode == 0:
            return 0
        linux_command(["systemctl", "--user", "start", "diskm-scratch.service"], 60)
        linux_command(["systemctl", "--user", "is-active", "--quiet", "diskm-scratch.service"], 15)
        linux_validate_mount(settings, scratch, registry(state)["volumes"].get("scratch"))
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.TimeoutExpired):
        return 75


def linux_fsck_cmd(arguments: list[str]) -> int:
    """Run a separately gated read-only or explicitly requested preen check."""
    try:
        if not arguments or arguments[0] != "scratch":
            return 2
        values: dict[str, str] = {}
        repair = execute = False
        index = 1
        while index < len(arguments):
            key = arguments[index]
            if key == "--repair":
                repair = True
                index += 1
            elif key == "--execute":
                execute = True
                index += 1
            elif key in {"--config", "--state-dir", "--user-uid"} and index + 1 < len(arguments):
                values[key] = arguments[index + 1]
                index += 2
            else:
                return 2
        if set(values) != {"--config", "--state-dir", "--user-uid"}:
            return 2
        if execute != repair:
            return 2
        user_uid = int(values["--user-uid"])
        if os.geteuid() != user_uid:
            return 75
        safe = linux_fstab_allowed_paths(values["--config"], values["--state-dir"], values["--user-uid"], None)
        if safe is None:
            return 75
        config_path, state, image, mountpoint = safe
        settings, scratch = cls("scratch", config_path)
        entry = registry(state)["volumes"].get("scratch")
        if not isinstance(entry, dict) or entry.get("state") != "active":
            return 75
        if entry.get("image_path") != str(image) or entry.get("mountpoint") != str(mountpoint):
            return 75
        if image.stat().st_size != scratch["quota_gb"] * GIB or image.stat().st_uid != user_uid:
            return 75
        if entry.get("filesystem_uuid") != linux_fs_uuid(image):
            return 75
        active = subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", "diskm-scratch.service"],
            capture_output=True, timeout=15, check=False,
        )
        if active.returncode != 3:
            return 75
        if linux_mount_record(mountpoint) is not None or linux_loop_devices(image):
            return 75
        readers = linux_fuser_pid_set(image, writers_only=False)
        if readers is None or readers:
            return 75
        e2fsck = shutil.which("e2fsck")
        if not e2fsck:
            return 75
        undo_path = receipt_path = None
        if repair:
            parent = image.parent
            parent_details = parent.stat()
            if (parent_details.st_uid != user_uid or stat.S_IMODE(parent_details.st_mode) & 0o022 or
                    parent.is_symlink()):
                return 75
            undo_path = image.with_name(image.name + ".e2fsck-undo")
            receipt_path = image.with_name(image.name + ".e2fsck-undo.receipt.json")
            if undo_path.exists() or undo_path.is_symlink() or receipt_path.exists() or receipt_path.is_symlink():
                return 75
            command = [e2fsck, "-fp", "-z", str(undo_path), str(image)]
        else:
            command = [e2fsck, "-fn", str(image)]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=300, check=False)
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout.decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or "")
            stderr = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else (error.stderr or "")
            if repair and receipt_path is not None:
                timeout_receipt = {
                    "command": command,
                    "raw_exit": None,
                    "timed_out": True,
                    "stdout": stdout,
                    "stderr": stderr,
                    "undo_path": str(undo_path) if undo_path else None,
                    "undo_present": bool(undo_path and undo_path.is_file()),
                    "image": str(image),
                    "filesystem_uuid": entry["filesystem_uuid"],
                }
                try:
                    descriptor = os.open(receipt_path, os.O_CREAT | os.O_EXCL |
                                         os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                    with os.fdopen(descriptor, "w") as stream:
                        json.dump(timeout_receipt, stream, sort_keys=True)
                        stream.write("\n")
                        stream.flush()
                        os.fsync(stream.fileno())
                except OSError:
                    return 75
            print(json.dumps({"action": "repair" if repair else "diagnostic", "command": command,
                              "raw_exit": None, "timed_out": True, "stdout": stdout, "stderr": stderr,
                              "undo_path": str(undo_path) if undo_path else None}, sort_keys=True), flush=True)
            return 75
        if repair:
            if not undo_path or not undo_path.is_file() or undo_path.stat().st_uid != user_uid:
                return 75
            receipt = {
                "command": command,
                "raw_exit": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "undo_path": str(undo_path),
                "image": str(image),
                "filesystem_uuid": entry["filesystem_uuid"],
            }
            try:
                descriptor = os.open(receipt_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                with os.fdopen(descriptor, "w") as stream:
                    json.dump(receipt, stream, sort_keys=True)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
            except OSError:
                return 75
        print(json.dumps({
            "action": "repair" if repair else "diagnostic",
            "command": command,
            "raw_exit": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "undo_path": str(undo_path) if undo_path else None,
        }, sort_keys=True), flush=True)
        return result.returncode
    except (OSError, ValueError, RuntimeError, KeyError, TypeError):
        return 75

def darwin_mount_cmd(name: str) -> int:
    if sys.platform != "darwin":
        return 2
    try:
        settings, scratch = cls(name)
        if settings["encryption"] != "apfs-passphrase":
            return 2
        entry = registry()["volumes"].get(name)
        if not isinstance(entry, dict) or entry.get("state") not in {"active", "needs_recovery"}:
            return 75
        entry_state = entry["state"]
        container = load_container()
        volume = validate_entry(
            container, settings, entry,
            allow_locked=True, allow_unexpected_mount=True,
        )
        if volume.locked:
            if not has_interactive_diskutil_tty():
                return 75
            run_diskutil_interactive(["apfs", "unlockVolume", volume.ref])
            container = load_container()
            volume = validate_entry(
                container, settings, entry,
                allow_locked=True, allow_unexpected_mount=True,
            )
        if volume.locked:
            return 75
        if volume.mountpoint != scratch["mountpoint"]:
            print("mounted-unexpected", file=sys.stderr)
            return 75
        if entry_state == "needs_recovery":
            registry_file, lock_handle = locked_registry()
            try:
                current_registry = registry()
                current_entry = current_registry["volumes"].get(name)
                if current_entry != entry or not isinstance(current_entry, dict):
                    return 75
                container = load_container()
                volume = validate_entry(container, settings, current_entry)
                if volume.locked or volume.mountpoint != scratch["mountpoint"]:
                    return 75
                return recover_creation(
                    name, settings, scratch, registry_file, lock_handle,
                    current_registry, current_entry, container,
                )
            finally:
                if not lock_handle.closed:
                    lock_handle.close()
        return 0
    except Exception as error:
        print("volume mount: " + str(error), file=sys.stderr)
        return 75


def create_cmd(name: str, execute: bool = False) -> int:
    if linux_backend_enabled(name):
        return linux_create_cmd(name, execute)
    try:
        settings, scratch = cls(name)
    except Exception:
        return 2
    if not encryption_is_acknowledged(settings):
        return 2
    encrypted = sys.platform == "darwin" and settings["encryption"] == "apfs-passphrase"
    if execute and encrypted and not has_interactive_diskutil_tty():
        return 75

    mountpoint = scratch["mountpoint"]
    if sys.platform == "darwin" and mountpoint != f"/Volumes/{scratch['name']}":
        return 2

    def fresh_create_container(previous: Container) -> tuple[Container | None, int]:
        try:
            current_settings, current_scratch = cls(name)
            if current_settings != settings or current_scratch != scratch:
                return None, 75
            current = load_container()
            if current.ref != previous.ref or current.uuid != previous.uuid:
                return None, 75
            if os.path.lexists(mountpoint):
                return None, 75
            if scratch["name"] in current.all_volume_names:
                return None, 2
            if not fit_result(current, settings)["fits"]:
                return None, 2
            free = require_nonnegative(current.free, "container free capacity")
            if free < settings["alarm_floor_gb"] * GIB:
                return None, 75
            return current, 0
        except Exception:
            return None, 75

    try:
        container = load_container()
        registry_file, lock_handle = locked_registry()
        try:
            current_registry = registry()
            existing = current_registry["volumes"].get(name)
            if name in current_registry["volumes"]:
                if not isinstance(existing, dict):
                    return 75
                if not execute:
                    return 2
                return recover_creation(name, settings, scratch, registry_file,
                                        lock_handle, current_registry, existing, container)

            container, result = fresh_create_container(container)
            if result:
                return result
            if not execute:
                print(json.dumps({
                    "class": name,
                    "fits": True,
                    "quota_gb": scratch["quota_gb"],
                    "mountpoint": mountpoint,
                }))
                return 0

            creation_intent = {
                "class": name,
                "name": scratch["name"],
                "container_uuid": container.uuid,
                "mountpoint": mountpoint,
                "quota_bytes": scratch["quota_gb"] * GIB,
                "state": "creating",
                "intent_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            current_registry["volumes"][name] = creation_intent
            save_registry(registry_file, lock_handle, current_registry)
            registry_file, lock_handle = locked_registry()
            current_registry = registry()
            if current_registry["volumes"].get(name) != creation_intent:
                return 75

            container, result = fresh_create_container(container)
            if result:
                current_registry["volumes"].pop(name)
                save_registry(registry_file, lock_handle, current_registry)
                return result

            add_volume_arguments = [
                "apfs", "addVolume", container.ref, "APFS", scratch["name"],
                "-quota", str(scratch["quota_gb"] * GIB),
            ]
            if encrypted:
                run_diskutil_interactive([*add_volume_arguments, "-passprompt"])
            else:
                run_diskutil(add_volume_arguments)
            updated = load_container()
            matches = [volume for volume in updated.volumes if volume.name == scratch["name"]]
            if len(matches) != 1:
                return 75
            volume = matches[0]
            provisional = {
                "class": name,
                "name": scratch["name"],
                "uuid": volume.uuid,
                "container_uuid": updated.uuid,
                "mountpoint": mountpoint,
                "quota_bytes": scratch["quota_gb"] * GIB,
                "state": "needs_recovery",
                "intent_at": current_registry["volumes"][name]["intent_at"],
            }
            validate_entry(updated, settings, provisional)
            current_registry["volumes"][name] = provisional
            save_registry(registry_file, lock_handle, current_registry)
            registry_file, lock_handle = locked_registry()
            current_registry = registry()
            return recover_creation(name, settings, scratch, registry_file,
                                    lock_handle, current_registry,
                                    current_registry["volumes"][name], updated)
        finally:
            if not lock_handle.closed:
                lock_handle.close()
    except Exception:
        return 75


def retire_cmd(name: str) -> int:
    try:
        _, _, _, _ = exact_entry(name, {"active", "retired"})
        registry_file, lock_handle = locked_registry()
        try:
            current_registry = registry()
            entry = current_registry["volumes"].get(name)
            if not isinstance(entry, dict) or entry.get("state") not in {"active", "retired"}:
                return 3
            entry["state"] = "retired"
            entry["retired_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            save_registry(registry_file, lock_handle, current_registry)
            return 0
        finally:
            if not lock_handle.closed:
                lock_handle.close()
    except Exception:
        return 75


def status(snapshot: bool = False) -> int:
    if linux_backend_enabled():
        return linux_status()
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    alarms: list[str] = []
    rows: list[dict[str, Any]] = []
    fatal = False
    capacity_fit: dict[str, Any] | None = None
    try:
        container = load_container()
        settings = config()
        entries = registry()["volumes"]
        free = require_nonnegative(container.free, "container free capacity")
        ceiling = require_positive(container.ceiling, "container ceiling")
        if free < 10 * GIB:
            alarms.append("container_critical")
        elif free < 20 * GIB:
            alarms.append("container_low")

        entry = entries.get("scratch")
        live_scratch = any(
            volume.name == settings["classes"]["scratch"]["name"]
            for volume in container.volumes
        )
        entry_state = entry.get("state") if isinstance(entry, dict) else None
        if "scratch" in entries and not isinstance(entry, dict):
            fatal = True
            alarms.append("volume_registry_invalid:scratch")
        elif "scratch" not in entries and live_scratch:
            fatal = True
            alarms.append("volume_registry_missing:scratch")
        elif entry_state in {"creating", "needs_recovery"}:
            fatal = True
            alarms.append("volume_registry_incomplete:scratch")
        elif isinstance(entry, dict) and entry_state not in {"active", "retired"}:
            fatal = True
            alarms.append("volume_registry_invalid:scratch")
        try:
            capacity_fit = fit_result(container)
        except Exception:
            fatal = True
            alarms.append("scratch_capacity_measurement_unavailable")
        if capacity_fit is not None and not capacity_fit["fits"]:
            alarms.append("scratch_capacity_unavailable")
        row: dict[str, Any] = {
            "host_id": os.uname().nodename,
            "filesystem_id": entry.get("uuid") if isinstance(entry, dict) else None,
            "kind": "filesystem",
            "source": "apfs_volume",
            "path": settings["classes"]["scratch"]["mountpoint"],
            "class": "scratch",
            "allocated_bytes": None,
            "quota_bytes": None,
            "measured_at": None,
            "status": entry.get("state", "unavailable") if isinstance(entry, dict) else "unavailable",
            "available": False,
            "attribution": "exclusive_exact",
        }
        if isinstance(entry, dict) and entry.get("state") in {"active", "retired"}:
            encrypted_mode = settings["encryption"] == "apfs-passphrase"
            try:
                volume = validate_entry(
                    container, settings, entry,
                    allow_locked=encrypted_mode, allow_unexpected_mount=encrypted_mode,
                )
            except Exception:
                fatal = True
                if entry.get("state") == "active":
                    alarms.append("volume_measurement_unavailable:scratch")
            else:
                if encrypted_mode and volume.locked:
                    row.update({"status": "locked", "encrypted": True, "locked": True,
                                "quota_bytes": volume.quota, "available": False})
                elif encrypted_mode and volume.mountpoint != settings["classes"]["scratch"]["mountpoint"]:
                    row.update({"status": "mounted-unexpected", "mounted_path": volume.mountpoint,
                                "encrypted": True, "locked": False,
                                "quota_bytes": volume.quota, "available": False})
                    alarms.append("scratch_mounted_unexpected")
                else:
                    try:
                        used = require_nonnegative(volume.used, "volume usage")
                        quota = require_positive(volume.quota, "volume quota")
                        reserve_ok = ballast_ok(settings["classes"]["scratch"]["mountpoint"])
                        row.update({
                            "filesystem_id": volume.uuid,
                            "allocated_bytes": used,
                            "quota_bytes": quota,
                            "measured_at": timestamp,
                            "available": reserve_ok,
                            **({"encrypted": True, "locked": False} if encrypted_mode else {}),
                        })
                        if entry.get("state") == "active" and not reserve_ok:
                            alarms.append("scratch_ballast_missing")
                        if used >= quota:
                            alarms.append("volume_full")
                        elif used / quota >= 0.9:
                            alarms.append("volume_high")
                    except Exception:
                        if entry.get("state") == "active":
                            alarms.append("volume_measurement_unavailable:scratch")
        rows.append(row)

        output: dict[str, Any] = {
            "measured_at": timestamp,
            "container": {
                "filesystem_id": container.uuid,
                "source": "apfs_container",
                "ceiling_bytes": ceiling,
                "free_bytes": free,
            },
            "capacity_fit": capacity_fit,
            "volumes": rows,
            "alarms": alarms,
        }
    except Exception:
        fatal = True
        output = {
            "measured_at": None,
            "container": {
                "filesystem_id": None,
                "source": "apfs_container",
                "ceiling_bytes": None,
                "free_bytes": None,
            },
            "capacity_fit": None,
            "volumes": [],
            "alarms": ["volume_measurement_unavailable"],
        }
    if not snapshot:
        output["tmp_audit"] = audit_tmp()
    print(json.dumps(output, sort_keys=True))
    if fatal:
        return 2
    return 1 if alarms else 0

def audit_tmp(path: str | Path | None = None) -> dict[str, Any]:
    if path is None:
        resolver = Path(__file__).resolve().parent / "lib" / "resolve_snapshot_json.sh"
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; resolve_snapshot_json', "resolve_snapshot", str(resolver)],
            capture_output=True, text=True, timeout=5, check=False,
        )
        if result.returncode:
            return {"status": "unknown", "reason": "snapshot_unavailable", "candidates": []}
        path = result.stdout.strip()
    try:
        document = json.loads(Path(path).read_text())
    except Exception:
        return {"status": "unknown", "reason": "snapshot_unavailable", "candidates": []}

    measured_at = document.get("snapshot_ts") or document.get("timestamp")
    # disk_snapshot.sh emits `directories` as path -> size_kb. Keep that
    # producer contract separate from record-shaped compatibility inputs.
    if "directories" in document:
        entries = document["directories"] or {}
        if isinstance(entries, dict):
            normalized = []
            for entry_path, value in entries.items():
                if is_int(value):
                    normalized.append({"path": entry_path, "size_bytes": value * 1024})
                elif isinstance(value, dict):
                    if is_int(value.get("size_bytes")):
                        normalized.append({"path": entry_path, "size_bytes": value["size_bytes"]})
                    elif is_int(value.get("size_kb")):
                        normalized.append({"path": entry_path, "size_bytes": value["size_kb"] * 1024})
            entries = normalized
    else:
        entries = document.get("top_directories") or []
        if isinstance(entries, dict):
            entries = [
                dict(path=entry_path, **(value if isinstance(value, dict) else {"size_bytes": value}))
                for entry_path, value in entries.items()
            ]
    candidates = []
    for item in entries:
        path_value = item.get("path") or item.get("name")
        size = item.get("size_bytes")
        if (
            isinstance(path_value, str)
            and path_value.startswith("/private/tmp/")
            and is_int(size)
            and size >= GIB
        ):
            candidates.append({
                "path": path_value,
                "size_bytes": size,
                "measured_at": measured_at,
            })
    return {
        "status": "measured" if measured_at is not None else "unknown",
        "measured_at": measured_at,
        "candidates": candidates,
    }


def reclaim_cmd(clean: bool = False) -> int:
    script = Path(__file__).resolve().parent / "volume_reclaim.sh"
    arguments = ["bash", str(script)]
    if clean:
        arguments.append("--clean")
    result = subprocess.run(arguments, check=False)
    return result.returncode


def verify_mount(root: str) -> int:
    if linux_backend_enabled():
        try:
            settings, scratch = cls("scratch")
            if root != scratch["mountpoint"]:
                return 75
            linux_validate_mount(settings, scratch, registry()["volumes"].get("scratch"))
            return 0
        except Exception:
            return 75
    try:
        settings, _ = cls("scratch")
        if os.path.realpath(root) != os.path.realpath(settings["classes"]["scratch"]["mountpoint"]):
            return 75
        exact_entry("scratch", {"active", "retired"})
        return 0
    except Exception:
        return 75


def main(argv: list[str] | None = None) -> int:
    arguments = list(argv if argv is not None else sys.argv[1:])
    try:
        if len(arguments) >= 2 and arguments[0] == "fstab" and arguments[1] in {"preview", "probe", "install", "remove"} and sys.platform.startswith("linux"):
            return linux_fstab_cmd(arguments[1], arguments[2:])
        if arguments[:1] == ["fsck"] and sys.platform.startswith("linux"):
            return linux_fsck_cmd(arguments[1:])
        if (arguments[:2] == ["service", "stop"] or arguments[:2] == ["service", "start"]):
            return (linux_service_control_cmd([arguments[1], *arguments[2:]])
                    if sys.platform.startswith("linux") else 2)
        if arguments[:1] == ["scheduler"]:
            if arguments[1:] == ["--help"]:
                print("volume scheduler install scratch [--interval-seconds POSITIVE_INTEGER (nonproduction only)]")
                return 0
            if arguments[1:3] != ["install", "scratch"] or not sys.platform.startswith("linux"):
                return 2
            interval = None
            if len(arguments) != 3:
                if len(arguments) != 5 or arguments[3] != "--interval-seconds" or not re.fullmatch(r"[1-9][0-9]*", arguments[4]):
                    return 2
                interval = int(arguments[4])
            return linux_scheduler_install_cmd("scratch", interval)
        if arguments[:1] == ["path"] and len(arguments) > 1:
            return path_cmd(arguments[1], "--for-reclaim" in arguments[2:])
        if arguments[:1] == ["verify-mount"] and len(arguments) > 1:
            return verify_mount(arguments[1])
        if arguments[:1] == ["reclaim"]:
            return reclaim_cmd("--clean" in arguments[1:])
        if arguments[:1] in (["fit"], ["plan-fit"]):
            print(json.dumps(fit_result(), sort_keys=True))
            return 0
        if arguments[:1] == ["create"] and len(arguments) > 1:
            return create_cmd(arguments[1], "--execute" in arguments[2:])
        if arguments[:1] == ["mount"] and len(arguments) > 1:
            if sys.platform.startswith("linux"):
                return linux_mount_cmd(arguments[1], "--foreground" in arguments[2:])
            if sys.platform == "darwin":
                return darwin_mount_cmd(arguments[1])
            return 2
        if arguments[:1] == ["unmount"] and len(arguments) > 1:
            return linux_unmount_cmd(arguments[1]) if sys.platform.startswith("linux") else 2
        if arguments[:2] == ["service", "migrate"] and sys.platform.startswith("linux"):
            return linux_service_migrate_cmd(arguments[2:])
        if arguments[:2] == ["service", "install"] and len(arguments) > 2:
            return linux_service_install_cmd(arguments[2]) if sys.platform.startswith("linux") else 2
        if arguments[:1] == ["retire"] and len(arguments) > 1:
            return retire_cmd(arguments[1])
        if arguments[:1] == ["ballast"] and len(arguments) > 2:
            return ballast_cmd(arguments[1], arguments[2])
        if arguments[:1] == ["status"]:
            return status("--snapshot" in arguments[1:])
        if arguments[:1] == ["audit-tmp"]:
            print(json.dumps(
                audit_tmp(arguments[1] if len(arguments) > 1 else None),
                sort_keys=True,
            ))
            return 0
        return 2
    except Exception as error:
        print("volume: " + str(error), file=sys.stderr)
        return 75


if __name__ == "__main__":
    raise SystemExit(main())
