"""Available-space policy; caller must verify the registered mount first."""
import os
import sys

FLOOR_BYTES = 50 * 2**30


def available_bytes(root):
    stats = os.statvfs(root)
    value = stats.f_bavail * stats.f_frsize
    if stats.f_frsize <= 0 or value < 0:
        raise ValueError('invalid filesystem availability')
    return value


def needs_reclaim(value):
    if type(value) is not int or value < 0:
        raise ValueError('invalid available bytes')
    return value < FLOOR_BYTES


if __name__ == '__main__':
    try:
        print(available_bytes(sys.argv[1]))
    except (OSError, ValueError, IndexError):
        raise SystemExit(75)
