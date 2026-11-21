#!/usr/bin/env python3
"""Apply exact regular-file selections from a hashed Scratch inventory."""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

import scratch_lock

MAX_BYTES = 256 * 1024 * 1024
FIELDS = ("dev", "ino", "size", "mtime_ns", "ctime_ns")
IDENTITY = re.compile(r"^([0-9]+),([0-9]+),([0-9]+),(-?[0-9]+),(-?[0-9]+)$")


def identity(path):
    st = os.lstat(path)
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns) if stat.S_ISREG(st.st_mode) else None


def check_entry(path, encoded):
    match = IDENTITY.fullmatch(encoded)
    if not match:
        return False
    try:
        return identity(path) == tuple(map(int, match.groups()))
    except OSError:
        return False


def scratch_root():
    dispatcher = shutil.which("disk-magician") or str(Path(__file__).resolve().parent.parent / "disk_magician.sh")
    result = subprocess.run([dispatcher, "volume", "path", "scratch"], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"registered Scratch volume unavailable ({dispatcher} rc={result.returncode}, stderr={result.stderr.strip()[:120]!r}, stdout={result.stdout.strip()[:120]!r})")
    path = result.stdout.rstrip("\r\n")
    root = Path(path)
    if not root.is_absolute() or root == Path("/") or os.path.realpath(path) != path:
        raise ValueError("invalid registered Scratch root")
    if subprocess.run([dispatcher, "volume", "verify-mount", str(root)],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise ValueError("Scratch mount verification failed")
    st = os.lstat(root)
    if not stat.S_ISDIR(st.st_mode):
        raise ValueError("registered Scratch root is not a directory")
    return root, st.st_dev, st.st_ino


def load_manifest(path, expected):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("manifest must be a regular file")
        raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES or hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError("manifest size or digest mismatch")
    value = json.loads(raw)
    if (not isinstance(value, dict) or value.get("version") != 1 or
            type(value.get("before_epoch_seconds")) is not int or
            not isinstance(value.get("root"), dict) or not isinstance(value.get("entries"), list)):
        raise ValueError("invalid manifest")
    root = value["root"]
    if not isinstance(root.get("path"), str) or any(type(root.get(k)) is not int for k in ("dev", "ino")):
        raise ValueError("invalid Scratch identity")
    return value


def path_parts(value):
    if not isinstance(value, str) or not value or value.startswith("/") or "\x00" in value:
        return None
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return None
    parts = value.split("/")
    return parts if all(part not in ("", ".", "..") for part in parts) else None


def verify(root, root_dev, entry, cutoff):
    relative = entry.get("path") if isinstance(entry, dict) else None
    parts = path_parts(relative)
    if parts is None:
        return None, "kept:invalid-path"
    # The canonical deletion receipt is tab-separated, one record per line.
    if any(char in relative for char in "\t\r\n"):
        return None, "kept:unsupported-log-path"
    if entry.get("kind") != "regular_file" or any(type(entry.get(k)) is not int for k in FIELDS):
        return None, "kept:unsupported-manifest-entry"
    target = root
    for index, part in enumerate(parts):
        target = target / part
        try:
            st = os.lstat(target)
        except FileNotFoundError:
            return None, "missing"
        except OSError:
            return None, "deferred:metadata"
        if stat.S_ISLNK(st.st_mode):
            return None, "kept:symlink-ancestor" if index < len(parts) - 1 else "kept:symlink"
        if st.st_dev != root_dev:
            return None, "kept:filesystem-boundary"
        if index < len(parts) - 1 and not stat.S_ISDIR(st.st_mode):
            return None, "kept:non-directory-ancestor"
        if index == len(parts) - 1 and not stat.S_ISREG(st.st_mode):
            return None, "kept:unsupported-path"
    current = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)
    if current != tuple(entry[k] for k in FIELDS):
        return None, "kept:identity-mismatch"
    if st.st_mtime_ns >= cutoff * 1_000_000_000:
        return None, "kept:outside-date-window"
    return target, None


def remove_exact(path, entry, lock_fd):
    repo = Path(__file__).resolve().parent.parent
    encoded = ",".join(str(entry[k]) for k in FIELDS)
    shell = 'source "$1/scripts/lib/quarantine.sh"; shift; quarantine_remove "$@"'
    args = ["bash", "-c", shell, "diskm-scratch-apply", str(repo), str(path),
            "--kind", "ephemeral", "--expected-target-identity", encoded]
    env = dict(os.environ, C14_NO_RESCUE_PUSH="1")
    env.pop("DISK_MAGICIAN_AGE_FLOOR_MINUTES", None)
    env.pop("DISK_MAGICIAN_OPERATOR_TARGETS", None)
    result = subprocess.run(args, capture_output=True, text=True, env=env, pass_fds=(lock_fd,))
    verdict = result.stdout.strip()
    if result.returncode or verdict == "remove" or not verdict.startswith(("removed:", "kept:", "deferred:")):
        return "deferred:quarantine-error"
    return verdict


def apply(manifest_path, digest, paths, all_entries, lock_fd):
    manifest = load_manifest(manifest_path, digest)
    root, dev, ino = scratch_root()
    recorded = manifest["root"]
    if (recorded["path"], recorded["dev"], recorded["ino"]) != (str(root), dev, ino):
        raise ValueError("Scratch root identity changed")
    rows = manifest["entries"]
    entries = {row["path"]: row for row in rows
               if isinstance(row, dict) and isinstance(row.get("path"), str)}
    if len(entries) != len(rows):
        raise ValueError("invalid or duplicate manifest entry")
    paths = list(entries) if all_entries else paths
    if not paths or len(set(paths)) != len(paths) or any(path not in entries for path in paths):
        raise ValueError("select unique paths present in the manifest")
    results = []
    for relative in paths:
        entry = entries[relative]
        target, reason = verify(root, dev, entry, manifest["before_epoch_seconds"])
        result = reason if reason else remove_exact(target, entry, lock_fd)
        results.append({"path": relative, "result": result})
    return {"manifest_sha256": digest, "before_epoch_seconds": manifest["before_epoch_seconds"], "results": results}


def main(args):
    if args[:1] == ["--check-entry"] and len(args) == 3:
        return 0 if check_entry(args[1], args[2]) else 1
    fields = {flag: [] for flag in ("--manifest", "--manifest-sha256", "--path")}
    all_entries = False
    options = iter(args)
    for flag in options:
        if flag in fields:
            value = next(options, None)
            if value is None:
                return 2
            fields[flag].append(value)
        elif flag == "--all" and not all_entries:
            all_entries = True
        else:
            return 2
    manifests, digests, paths = fields.values()
    if len(manifests) != 1 or len(digests) != 1 or not manifests[0] or not digests[0] or (all_entries and paths):
        return 2
    try:
        try:
            fd = int(os.environ.get(scratch_lock.ENV_FD, ""))
        except ValueError:
            fd = -1
        if not 0 <= fd <= 2**31 - 1 or not scratch_lock.verify_fd(fd):
            os.environ["DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS"] = "0"
            return scratch_lock.run("scratch-apply", sys.executable, [__file__, *args])
        scratch_lock.disable_implicit_git_fsmonitor()
        result = apply(manifests[0], digests[0], paths, all_entries, fd)
    except (OSError, ValueError, TypeError) as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 2
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
