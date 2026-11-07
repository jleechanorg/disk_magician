#!/usr/bin/env python3
"""mirror_archive_manifest.py — independent manifests that prove a tar archive
round-trips a clone before the clone is removed.

Two subcommands produce the SAME manifest text for the same tree:

  source  <dir> <out>   walk <dir> with lstat and describe it (no tar involved)
  archive <out> < tar    read a tar stream and describe its members, streaming
                        every regular member's bytes back once

The two manifests are compared byte-for-byte. Because the source side never
consults tar, an archive that loses a member, truncates a file, downgrades an
exec bit, or drops a symlink cannot produce a matching manifest. Every regular
member is read to the end on the archive side, so a truncated or corrupt zstd
stream fails here rather than later.

Line format (sorted by path, tabs, trailing components "-" when not applicable):
  <path> TAB <kind> TAB <mode> TAB <size> TAB <sha256> TAB <linkname>
kind is f (regular), d (directory), l (symlink), o (other).
mode is compared for f and d only: symlink modes are not portable.
sha256 is the hex digest for f, or "-" for d, l, and o.
Final line: "total<TAB><count><TAB><total-bytes>".
"""
import hashlib
import os
import sys
import tarfile

CHUNK = 1 << 20


def _mode(st_mode):
    return format(st_mode & 0o7777, "04o")


def _emit(rows, total_bytes, out_path):
    rows.sort(key=lambda r: r[0])
    lines = ["\t".join([p, k, m, str(s), sha, l]) for (p, k, m, s, sha, l) in rows]
    lines.append("total\t%d\t%d" % (len(rows), total_bytes))
    text = "\n".join(lines) + "\n"
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print("count=%d bytes=%d" % (len(rows), total_bytes))


def source_manifest(root, out_path):
    root = os.path.abspath(root)
    dev = os.lstat(root).st_dev
    rows = []
    total = 0
    rows.append((".", "d", _mode(os.lstat(root).st_mode), 0, "-", "-"))
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        filenames.sort()
        rel_dir = os.path.relpath(dirpath, root)
        descends = []
        for name in dirnames:
            full = os.path.join(dirpath, name)
            rel = name if rel_dir == "." else os.path.join(rel_dir, name)
            st = os.lstat(full)
            if os.path.islink(full):
                rows.append((rel, "l", "----", 0, "-", os.readlink(full)))
                continue
            rows.append((rel, "d", _mode(st.st_mode), 0, "-", "-"))
            # Mirrors tar --one-file-system: record the mountpoint, never descend.
            if st.st_dev == dev:
                descends.append(name)
        dirnames[:] = descends
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = name if rel_dir == "." else os.path.join(rel_dir, name)
            st = os.lstat(full)
            if os.path.islink(full):
                rows.append((rel, "l", "----", 0, "-", os.readlink(full)))
            elif os.path.isdir(full):
                rows.append((rel, "d", _mode(st.st_mode), 0, "-", "-"))
            elif os.path.isfile(full):
                h = hashlib.sha256()
                try:
                    with open(full, "rb") as fh:
                        while True:
                            block = fh.read(CHUNK)
                            if not block:
                                break
                            h.update(block)
                except OSError as e:
                    raise SystemExit("unreadable source file %r: %s" % (full, e))
                rows.append((rel, "f", _mode(st.st_mode), st.st_size, h.hexdigest(), "-"))
                total += st.st_size
            else:
                rows.append((rel, "o", _mode(st.st_mode), 0, "-", "-"))
    _emit(rows, total, out_path)


def archive_manifest(out_path):
    rows = []
    total = 0
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|") as tf:
        for member in tf:
            name = member.name
            while name.startswith("./"):
                name = name[2:]
            name = name.rstrip("/") or "."
            parts = name.split("/")
            if name.startswith("/") or ".." in parts:
                raise SystemExit("unsafe archive member: %r" % name)
            if member.isdir():
                kind = "d"
            elif member.issym():
                kind = "l"
            elif member.isreg():
                kind = "f"
            else:
                kind = "o"
            size = 0
            sha = "-"
            if kind == "f":
                fh = tf.extractfile(member)
                if fh is None:
                    raise SystemExit("unreadable member: %r" % name)
                h = hashlib.sha256()
                read = 0
                while True:
                    block = fh.read(CHUNK)
                    if not block:
                        break
                    read += len(block)
                    h.update(block)
                if read != member.size:
                    raise SystemExit(
                        "short read on %r: %d of %d bytes" % (name, read, member.size)
                    )
                size = read
                sha = h.hexdigest()
                total += read
            mode = _mode(member.mode) if kind in ("f", "d") else "----"
            link = member.linkname if kind == "l" else "-"
            rows.append((name, kind, mode, size, sha, link))
    _emit(rows, total, out_path)


def main(argv):
    if len(argv) != 4:
        sys.stderr.write("usage: %s {source|archive} <dir|ignored> <out>\n" % argv[0])
        return 2
    action, arg, out_path = argv[1], argv[2], argv[3]
    if action == "source":
        source_manifest(arg, out_path)
    elif action == "archive":
        archive_manifest(out_path)
    else:
        sys.stderr.write("unknown action: %s\n" % action)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
