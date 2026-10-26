#!/usr/bin/env python3
"""Opt-in, fail-closed Scratch-volume helpers used by diskm."""
from __future__ import annotations
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
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


@dataclass(frozen=True)
class Volume:
    name: str
    uuid: str
    ref: str
    used: int | None
    quota: int | None
    roles: tuple[str, ...]


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
        if not all(isinstance(value, str) and value for value in (name, volume_uuid, device)):
            raise ValueError("volume identity is incomplete")
        if not isinstance(roles, list) or not all(isinstance(role, str) for role in roles):
            raise ValueError("volume roles are invalid")
        used = item.get("CapacityInUse")
        quota = item.get("CapacityQuota")
        if used is not None:
            require_nonnegative(used, "volume used capacity")
        if quota is not None:
            require_nonnegative(quota, "volume quota")
        volumes.append(Volume(name, volume_uuid, device, used, quota, tuple(roles)))

    ceiling = raw.get("CapacityCeiling")
    free = raw.get("CapacityFree")
    if ceiling is not None:
        require_nonnegative(ceiling, "container ceiling")
    if free is not None:
        require_nonnegative(free, "container free capacity")
    return Container(ref, uuid, ceiling, free, tuple(volumes), tuple(all_volume_names))


def config() -> dict[str, Any]:
    import resolve_config

    document = json.loads(Path(resolve_config.resolve()).read_text())
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
    if volumes.get("encryption") != "none":
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
    return volumes


def cls(name: str) -> tuple[dict[str, Any], dict[str, Any]]:
    volumes = config()
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


def state_root() -> Path:
    return Path(os.environ.get(
        "DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"
    ))


def registry_paths() -> tuple[Path, Path]:
    directory = state_root() / "volumes"
    directory.mkdir(parents=True, exist_ok=True)
    return directory / "registry.json", directory / "registry.lock"


def registry() -> dict[str, Any]:
    path, _ = registry_paths()
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
    container: Container, settings: dict[str, Any], entry: Any
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

    measured = plist(["info", "-plist", volume.ref])
    if (
        measured.get("VolumeUUID") != volume.uuid
        or measured.get("MountPoint") != scratch["mountpoint"]
        or measured.get("APFSContainerReference") != container.ref
        or measured.get("DeviceIdentifier") != volume.ref
    ):
        raise ValueError("mounted volume identity mismatch")
    return volume


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
        with os.fdopen(descriptor, "wb") as stream:
            remaining = BALLAST_BYTES
            block = b"\0" * MIB
            while remaining:
                stream.write(block)
                remaining -= len(block)
            stream.flush()
            os.fsync(stream.fileno())
        if not ballast_ok(mountpoint):
            raise RuntimeError("ballast allocation verification failed")
    except Exception:
        try:
            path.unlink()
        except OSError:
            pass
        raise


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
            entry = registry()["volumes"].get(name)
            if not isinstance(entry, dict):
                return 3
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
    return settings.get("encryption") == "none" and isinstance(acknowledgement, str) and bool(acknowledgement.strip())



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
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        fields = line.split()
        if len(fields) > 6 and fields[4] == escaped and "-" in fields:
            separator = fields.index("-")
            if len(fields) > separator + 2:
                return fields[separator + 1], fields[separator + 2]
    return None


def linux_validate_mount(settings: dict[str, Any], scratch: dict[str, Any], entry: Any) -> str:
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
        rendered = unit_template.read_text().replace("@ORCHESTRATOR@", systemd_quote(str(orchestrator)))
        rendered = rendered.replace("@CONFIG_PATH@", systemd_quote(config_path))
        rendered = rendered.replace("@STATE_PATH@", systemd_quote(str(state_root())))
        if "@" in rendered:
            return 75
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
        linux_validate_mount(settings, scratch, registry()["volumes"].get(name))
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


def create_cmd(name: str, execute: bool = False) -> int:
    if linux_backend_enabled(name):
        return linux_create_cmd(name, execute)
    try:
        settings, scratch = cls(name)
    except Exception:
        return 2
    if not encryption_is_acknowledged(settings):
        return 2

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

            run_diskutil([
                "apfs", "addVolume", container.ref, "APFS", scratch["name"],
                "-quota", str(scratch["quota_gb"] * GIB),
            ])
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
            try:
                volume = validate_entry(container, settings, entry)
            except Exception:
                fatal = True
                if entry.get("state") == "active":
                    alarms.append("volume_measurement_unavailable:scratch")
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
        if root != settings["classes"]["scratch"]["mountpoint"]:
            return 75
        exact_entry("scratch", {"active", "retired"})
        return 0
    except Exception:
        return 75


def main(argv: list[str] | None = None) -> int:
    arguments = list(argv if argv is not None else sys.argv[1:])
    try:
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
            return linux_mount_cmd(arguments[1], "--foreground" in arguments[2:]) if sys.platform.startswith("linux") else 2
        if arguments[:1] == ["unmount"] and len(arguments) > 1:
            return linux_unmount_cmd(arguments[1]) if sys.platform.startswith("linux") else 2
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
