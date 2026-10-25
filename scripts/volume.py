#!/usr/bin/env python3
"""Opt-in, fail-closed APFS quota-volume helpers used by diskm."""
import fcntl
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
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
    return Container(ref, uuid, ceiling, free, tuple(volumes))


def config() -> dict[str, Any]:
    import resolve_config

    document = json.loads(Path(resolve_config.resolve()).read_text())
    volumes = document.get("volumes")
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


def fit_result(container: Container | None = None) -> dict[str, Any]:
    container = container or load_container()
    settings = config()
    data_used = require_nonnegative(
        container.volume_by_role("Data").used, "Data volume usage"
    )
    system_used = require_nonnegative(
        container.volume_by_role("System").used, "System volume usage"
    )
    vm_used = require_nonnegative(container.volume_by_role("VM").used, "VM usage")
    ceiling = require_positive(container.ceiling, "container ceiling")
    swap_headroom = settings["swap_headroom_gb"] * GIB
    alarm_floor = settings["alarm_floor_gb"] * GIB
    quota_bytes = settings["classes"]["scratch"]["quota_gb"] * GIB

    vm_reserve = max(vm_used, swap_headroom)
    required = data_used + system_used + vm_reserve + quota_bytes + alarm_floor
    max_quota = max(0, (ceiling - data_used - system_used - vm_reserve - alarm_floor) // GIB)
    return {
        "ok": required <= ceiling,
        "fits": required <= ceiling,
        "required_bytes": required,
        "ceiling_bytes": ceiling,
        "data_used_bytes": data_used,
        "system_used_bytes": system_used,
        "vm_reserve_bytes": vm_reserve,
        "quota_bytes": quota_bytes,
        "alarm_floor_bytes": alarm_floor,
        "max_quota_gb_that_fits": max_quota,
    }


def registry_paths() -> tuple[Path, Path]:
    root = Path(os.environ.get(
        "DISK_MAGICIAN_STATE_DIR", Path.home() / ".disk_magician_state"
    ))
    directory = root / "volumes"
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
        details = path.stat()
    except OSError:
        return False
    return (
        path.is_file()
        and not path.is_symlink()
        and details.st_size == BALLAST_BYTES
        and details.st_blocks * 512 >= BALLAST_BYTES
    )


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


def exact_entry(name: str, allowed_states: set[str]) -> tuple[Container, dict[str, Any], dict[str, Any], Volume]:
    settings, scratch = cls(name)
    entries = registry()["volumes"]
    entry = entries.get(name)
    if not isinstance(entry, dict) or entry.get("state") not in allowed_states:
        raise ValueError("volume is not registered in an eligible state")
    container = load_container()
    volume = validate_entry(container, settings, entry)
    return container, settings, entry, volume


def path_cmd(name: str, for_reclaim: bool = False) -> int:
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
        if "not registered" in str(error):
            return 3
        return 75
    except Exception:
        return 75
    print(settings["classes"]["scratch"]["mountpoint"])
    return 0


def log_ballast_release(path: Path, volume_uuid: str) -> None:
    log_script = Path(__file__).resolve().parent / "safety_lib.sh"
    subprocess.run(
        [
            "bash", "-c",
            'source "$1"; deletion_log volume release_ballast 0 "$2" "$3"',
            "volume", str(log_script), str(path), "uuid=" + volume_uuid,
        ],
        check=False,
    )


def ballast_cmd(action: str, name: str) -> int:
    try:
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
            if not ballast_ok(mountpoint):
                return 75
            path.unlink()
            log_ballast_release(path, volume.uuid)
            return 0
        raise ValueError("unknown ballast action")
    except Exception:
        return 75


def encryption_is_acknowledged(settings: dict[str, Any]) -> bool:
    acknowledgement = settings.get("encryption_acknowledged_at")
    return settings.get("encryption") == "none" and isinstance(acknowledgement, str) and bool(acknowledgement.strip())


def create_cmd(name: str, execute: bool = False) -> int:
    try:
        settings, scratch = cls(name)
    except Exception:
        return 2
    if not encryption_is_acknowledged(settings):
        return 2

    mountpoint = scratch["mountpoint"]
    if sys.platform == "darwin" and mountpoint != f"/Volumes/{scratch['name']}":
        return 2
    if os.path.lexists(mountpoint):
        return 75

    try:
        container = load_container()
        registry_file, lock_handle = locked_registry()
        try:
            current_registry = registry()
            if name in current_registry["volumes"]:
                return 2
            if any(volume.name == scratch["name"] for volume in container.volumes):
                return 2
            fit = fit_result(container)
            if not fit["fits"]:
                return 2
            if not execute:
                print(json.dumps({
                    "class": name,
                    "fits": True,
                    "quota_gb": scratch["quota_gb"],
                    "mountpoint": mountpoint,
                }))
                return 0

            free = require_nonnegative(container.free, "container free capacity")
            if free < settings["alarm_floor_gb"] * GIB:
                return 75

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
            }
            validate_entry(updated, settings, provisional)
            write_ballast(mountpoint)

            current_registry["volumes"][name] = {
                **provisional,
                "state": "active",
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            save_registry(registry_file, lock_handle, current_registry)
            return 0
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
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    alarms: list[str] = []
    rows: list[dict[str, Any]] = []
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
        try:
            if not isinstance(entry, dict) or entry.get("state") not in {"active", "retired"}:
                raise ValueError("volume is not registered")
            volume = validate_entry(container, settings, entry)
            used = require_nonnegative(volume.used, "volume usage")
            quota = require_positive(volume.quota, "volume quota")
            row.update({
                "filesystem_id": volume.uuid,
                "allocated_bytes": used,
                "quota_bytes": quota,
                "measured_at": timestamp,
                "available": ballast_ok(settings["classes"]["scratch"]["mountpoint"]),
            })
            if used >= quota:
                alarms.append("volume_full")
            elif used / quota >= 0.9:
                alarms.append("volume_high")
        except Exception:
            if isinstance(entry, dict) and entry.get("state") == "active":
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
            "volumes": rows,
            "alarms": alarms,
        }
    except Exception:
        output = {
            "measured_at": None,
            "container": {
                "filesystem_id": None,
                "source": "apfs_container",
                "ceiling_bytes": None,
                "free_bytes": None,
            },
            "volumes": [],
            "alarms": ["volume_measurement_unavailable"],
        }
    if not snapshot:
        output["tmp_audit"] = audit_tmp()
    print(json.dumps(output, sort_keys=True))
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
    entries = document.get("directories") or document.get("top_directories") or []
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
