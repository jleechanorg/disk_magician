#!/usr/bin/env python3
"""Bounded artifact-child discovery with all-or-nothing NUL-framed output."""
import fnmatch
import os
import stat
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
        pass
    else:
        return True
    # Bare repositories have no .git marker. Treat even symlinked metadata as
    # a boundary; discovery never resolves it or nominates its internals.
    for name in ("HEAD", "objects", "refs"):
        try:
            os.lstat(os.path.join(path, name))
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

def generic_scope(root, path):
    """Validate lexical ancestors, without following links or entering Git."""
    rel = os.path.relpath(path, root)
    parts = rel.split(os.sep)
    if any(part in ("", ".", "..") or part.startswith(".") for part in parts):
        return False
    if parts[0].startswith(("_disk_magician_archive", "system-", "com.apple.", "PowerlogHelperd")):
        return False
    current = root
    device = os.lstat(root).st_dev
    for part in parts:
        if has_git_marker(current):
            return False
        current = os.path.join(current, part)
        info = os.lstat(current)
        if not stat.S_ISDIR(info.st_mode) or info.st_dev != device:
            return False
    return True


def discover_generic(root, deadline):
    """Iterative traversal: no depth/name cutoff and no partial result on error."""
    info = os.lstat(root)
    if not stat.S_ISDIR(info.st_mode):
        raise OSError("candidate is not a real directory")
    result = []
    pending = [root]
    while pending:
        if expired(deadline):
            raise TimeoutError
        path = pending.pop()
        if has_git_marker(path):
            continue
        children = []
        with os.scandir(path) as entries:
            for entry in entries:
                if expired(deadline):
                    raise TimeoutError
                if entry.name.startswith("."):
                    continue
                info_child = entry.stat(follow_symlinks=False)
                if not stat.S_ISDIR(info_child.st_mode) or info_child.st_dev != info.st_dev:
                    continue
                # Whole repository units may still receive C14 checks, but
                # never descend into their source, metadata, or generated files.
                result.append(os.fsencode(entry.path))
                if not has_git_marker(entry.path):
                    children.append(entry.path)
        pending.extend(reversed(sorted(children)))
    return result

def stream_generic_leaves(root, deadline):
    """Stream disjoint lifecycle units; caller must retain nonzero completion."""
    root_info = os.lstat(root)
    if not stat.S_ISDIR(root_info.st_mode):
        raise OSError("candidate is not a real directory")
    pending = [root]
    while pending:
        if expired(deadline):
            raise TimeoutError
        path = pending.pop()
        children = []
        if not has_git_marker(path):
            with os.scandir(path) as entries:
                for entry in entries:
                    if expired(deadline):
                        raise TimeoutError
                    info = entry.stat(follow_symlinks=False)
                    if (not entry.name.startswith(".") and stat.S_ISDIR(info.st_mode)
                            and info.st_dev == root_info.st_dev):
                        children.append(entry.path)
        if children:
            pending.extend(reversed(sorted(children)))
        elif path != root:
            sys.stdout.buffer.write(os.fsencode(path) + b"\0")
            sys.stdout.buffer.flush()


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
    if mode == "scope":
        if len(sys.argv) != 4:
            return 2
        try:
            return 0 if generic_scope(sys.argv[2], sys.argv[3]) else 3
        except OSError:
            return 1
    deadline = parse_deadline(sys.argv[-1])
    if mode == "stream-generic-leaves":
        if len(sys.argv) != 4:
            return 2
        try:
            stream_generic_leaves(sys.argv[2], deadline)
        except TimeoutError:
            return 124
        except OSError:
            return 1
        return 0
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
    if mode in ("batch", "batch-generic"):
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
                for child in (discover_generic(root, deadline) if mode == "batch-generic" else discover(root, max_depth, deadline)):
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
