#!/usr/bin/env python3
"""Small stateful diskutil fake for isolated quota-volume tests."""
import json
import os
import pathlib
import plistlib
import sys

STATE = pathlib.Path(os.environ["FAKE_DISKUTIL_STATE"])
CALLS = pathlib.Path(os.environ["FAKE_DISKUTIL_CALLS"])
DEFAULT = {
    "container": {"ref": "disk3", "uuid": "CONTAINER-UUID", "ceiling": 994662584320, "free": 100 * 2**30},
    "volumes": [
        {"uuid": "DATA-UUID", "name": "Data", "ref": "disk3s1", "device": "disk3s1", "used": 829 * 2**30, "quota": 0, "roles": ["Data"], "mountpoint": "/System/Volumes/Data"},
        {"uuid": "SYSTEM-UUID", "name": "System", "ref": "disk3s5", "device": "disk3s5", "used": 15 * 2**30, "quota": 0, "roles": ["System"], "mountpoint": "/"},
        {"uuid": "VM-UUID", "name": "VM", "ref": "disk3s6", "device": "disk3s6", "used": 4 * 2**30, "quota": 0, "roles": ["VM"], "mountpoint": "/System/Volumes/VM"},
    ],
}

def read():
    if not STATE.exists():
        STATE.write_text(json.dumps(DEFAULT))
    return json.loads(STATE.read_text())

def save(data):
    STATE.write_text(json.dumps(data))

def record(args):
    with CALLS.open("a") as f:
        f.write(json.dumps(args) + "\n")

def fail(code=1):
    raise SystemExit(code)

def main(args):
    data = read()
    if args[:2] == ["info", "-plist"]:
        target = args[2] if len(args) > 2 else ""
        row = next((v for v in data["volumes"] if target in (v.get("ref"), v.get("name"), v.get("mountpoint"))), None)
        if row is None:
            fail()
        result = {"MountPoint": row.get("mountpoint", ""), "VolumeUUID": row["uuid"], "APFSContainerReference": data["container"]["ref"], "DeviceIdentifier": row.get("device", ""), "CapacityInUse": row.get("used")}
        sys.stdout.buffer.write(plistlib.dumps(result)); return
    if args[:3] == ["apfs", "list", "-plist"]:
        c = data["container"]
        result = {"Containers": [{"APFSContainerUUID": c["uuid"], "CapacityCeiling": c["ceiling"], "CapacityFree": c.get("free"), "ContainerReference": c["ref"], "Volumes": [{"APFSVolumeUUID": v["uuid"], **({"CapacityInUse": v["used"]} if isinstance(v.get("used"), int) else {}), "CapacityQuota": v.get("quota", 0), "DeviceIdentifier": v.get("device", ""), "Name": v["name"], "Roles": v.get("roles", [])} for v in data["volumes"]]}]}
        sys.stdout.buffer.write(plistlib.dumps(result)); return
    if args[:2] == ["apfs", "addVolume"]:
        record(args)
        if os.environ.get("FAKE_DISKUTIL_HOOK"):
            os.system(os.environ["FAKE_DISKUTIL_HOOK"])
        if os.environ.get("FAKE_DISKUTIL_FAIL_ADD") == "1": fail()
        name = args[4]
        quota = next((int(x[:-1]) * 2**30 for x in args if x.endswith("g")), 0)
        mountpoint = os.environ.get("FAKE_DISKUTIL_MOUNTPOINT", "/Volumes/" + name)
        row = {"uuid": "SCRATCH-UUID", "name": name, "ref": "disk3s9", "device": "disk3s9", "used": 0, "quota": quota, "roles": [], "mountpoint": mountpoint}
        data["volumes"].append(row); data["container"]["free"] = max(0, data["container"].get("free", 0) - quota); save(data); return
    if args and args[0] in ("mount", "unmount"):
        record(args)
        if os.environ.get("FAKE_DISKUTIL_HOOK"):
            os.system(os.environ["FAKE_DISKUTIL_HOOK"])
        if args[0] == "mount":
            os.makedirs(os.environ.get("FAKE_DISKUTIL_MOUNTPOINT", "/Volumes/diskm-scratch"), exist_ok=True)
        if args[0] == "unmount" and os.environ.get("FAKE_DISKUTIL_BUSY") == "1": fail()
        return
    if args[:2] == ["apfs", "deleteVolume"]:
        record(args); return
    fail(2)

if __name__ == "__main__":
    main(sys.argv[1:])
