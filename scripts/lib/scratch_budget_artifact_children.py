#!/usr/bin/env python3
"""Bounded artifact-child discovery with all-or-nothing NUL-framed output."""
import fnmatch
import os
import sys
import time

MARKER = b"diskm-artifact-children-v1"
ARTIFACT_NAMES = {
    "build", "dist", "out", "target", "coverage", "artifacts", "gradle",
    ".gradle", "android-sdk", "avd", ".next", ".cache", ".turbo",
    ".parcel-cache", "__pycache__", "DerivedData", "Pods",
}

def expired(deadline):
    return deadline is not None and time.monotonic() >= deadline

def has_git_marker(path: str) -> bool:
    try:
        os.lstat(os.path.join(path, ".git"))
    except FileNotFoundError:
        return False
    return True

def is_artifact_name(name: str) -> bool:
    return name in ARTIFACT_NAMES or fnmatch.fnmatchcase(name, "isolated-*")

def discover(root, max_depth, deadline):
    if not os.path.isdir(root) or os.path.islink(root):
        raise OSError("candidate is not a real directory")
    if has_git_marker(root) or max_depth <= 0:
        return []
    result = []
    def walk(path: str, depth: int) -> None:
        if expired(deadline):
            raise TimeoutError
        with os.scandir(path) as entries:
            for entry in entries:
                if expired(deadline):
                    raise TimeoutError
                if not entry.is_dir(follow_symlinks=False):
                    continue
                child = entry.path
                if has_git_marker(child):
                    continue
                if not entry.name.startswith(".") and is_artifact_name(entry.name):
                    result.append(os.fsencode(child))
                if depth < max_depth:
                    walk(child, depth + 1)
    walk(root, 1)
    return result

def parse_deadline(value):
    if not value:
        return None
    result = float(value)
    if not (result >= 0.0 and result < float("inf")):
        raise ValueError("invalid deadline")
    return result

def main():
    if len(sys.argv) < 3:
        return 2
    mode = sys.argv[1]
    deadline = parse_deadline(sys.argv[-1])
    if mode == "single":
        if len(sys.argv) != 5:
            return 2
        root = sys.argv[2]
        max_depth = int(sys.argv[3])
        try:
            children = discover(root, max_depth, deadline)
        except TimeoutError:
            return 124
        except (OSError, ValueError):
            return 1
        sys.stdout.buffer.write(b"".join(child + b"\0" for child in children))
        return 0
    if mode == "batch":
        if len(sys.argv) != 4:
            return 2
        max_depth = int(sys.argv[2])
        raw = sys.stdin.buffer.read()
        if raw and not raw.endswith(b"\0"):
            return 1
        roots = raw[:-1].split(b"\0") if raw else []
        records = []
        try:
            for root_bytes in roots:
                if not root_bytes:
                    return 1
                root = os.fsdecode(root_bytes)
                for child in discover(root, max_depth, deadline):
                    records.append((root_bytes, child))
        except TimeoutError:
            return 124
        except (OSError, ValueError):
            return 1
        output = bytearray()
        output.extend(MARKER + b"\0")
        output.extend(str(len(records)).encode("ascii") + b"\0")
        for candidate, child in records:
            output.extend(candidate + b"\0" + child + b"\0")
        sys.stdout.buffer.write(output)
        return 0
    return 2

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OverflowError):
        raise SystemExit(1)
