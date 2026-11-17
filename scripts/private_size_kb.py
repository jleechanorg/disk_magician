#!/usr/bin/env python3
"""Print `<kb>\t<path>` like `du -sk -x`, but count APFS private (unshared) bytes.

`du` counts clone-shared blocks in full; deleting a clone frees only its private
bytes. On macOS each file is sized with getattrlist ATTR_CMNEXT_PRIVATESIZE; any
error, or a non-macOS host, falls back to st_blocks*512 (what du reports), so an
unmeasurable file is never undercounted. Symlinks are not followed, hard links
are counted once, and other filesystems are skipped.
"""
import ctypes
import os
import stat
import sys

FSOPT_NOFOLLOW = 0x1
FSOPT_ATTR_CMN_EXTENDED = 0x20
ATTR_CMNEXT_PRIVATESIZE = 0x8


class _AttrList(ctypes.Structure):
    _fields_ = [("bitmapcount", ctypes.c_ushort), ("reserved", ctypes.c_ushort),
                ("commonattr", ctypes.c_uint), ("volattr", ctypes.c_uint),
                ("dirattr", ctypes.c_uint), ("fileattr", ctypes.c_uint),
                ("forkattr", ctypes.c_uint)]


def _libc_getattrlist():
    if sys.platform != "darwin":
        return None
    try:
        return ctypes.CDLL(None, use_errno=True).getattrlist
    except (OSError, AttributeError):
        return None


def private_bytes(path, st, getattrlist):
    if getattrlist is not None:
        al = _AttrList(5, 0, 0, 0, 0, 0, ATTR_CMNEXT_PRIVATESIZE)
        buf = ctypes.create_string_buffer(16)  # u32 length + off_t
        rc = getattrlist(os.fsencode(path), ctypes.byref(al), buf, 16,
                         FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
        if rc == 0:
            return int.from_bytes(buf.raw[4:12], "little")
    return st.st_blocks * 512


def tree_kb(root):
    getattrlist = _libc_getattrlist()
    root_st = os.lstat(root)
    if not stat.S_ISDIR(root_st.st_mode):  # a file or symlink root is sized itself, like du
        return (private_bytes(root, root_st, getattrlist) + 1023) // 1024
    seen, total = set(), 0
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            entries = list(os.scandir(d))
        except OSError:
            continue
        for e in entries:
            try:
                st = e.stat(follow_symlinks=False)
                if st.st_dev != root_st.st_dev:
                    continue
                if e.is_dir(follow_symlinks=False):
                    stack.append(e.path)
                    continue
                if st.st_nlink > 1 and (st.st_dev, st.st_ino) in seen:
                    continue
                seen.add((st.st_dev, st.st_ino))
                total += private_bytes(e.path, st, getattrlist)
            except OSError:
                continue
    return (total + 1023) // 1024


if __name__ == "__main__":
    print(f"{tree_kb(sys.argv[1])}\t{sys.argv[1]}")
