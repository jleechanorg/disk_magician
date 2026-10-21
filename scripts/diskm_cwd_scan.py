#!/usr/bin/python3 -I
"""diskm-cwd-scan: read-only root helper for the Linux live-cwd gate.

Prints one NUL-terminated record per process, `<pid>\t<uid>\t<cwd>\0`, from
/proc/<pid>/cwd. Takes no arguments and reads nothing else, so what it can do
as root is exactly: readlink /proc/<pid>/cwd and stat /proc/<pid>. A process
that exits mid-scan is skipped, and the scan repeats if new pids appear
mid-read; any other error exits non-zero with no output.
"""
import os
import sys


def pids():
    return {n for n in os.listdir(b"/proc") if n.isdigit()}


def thread_cwds(proc):
    """cwds of a process whose leader's own cwd link is gone (leader called
    pthread_exit while other threads run): read each thread's link instead."""
    cwds = set()
    try:
        tids = os.listdir(proc + b"/task")
    except FileNotFoundError:
        return cwds
    for tid in tids:
        try:
            cwds.add(os.readlink(proc + b"/task/" + tid + b"/cwd"))
        except FileNotFoundError:
            continue
    return cwds


def scan(names):
    records = []
    for name in sorted(names, key=int):
        proc = b"/proc/" + name
        try:
            uid = os.stat(proc).st_uid
        except FileNotFoundError:
            continue  # exited
        try:
            cwds = {os.readlink(proc + b"/cwd")}
        except FileNotFoundError:
            cwds = thread_cwds(proc)  # empty for a zombie
        for cwd in sorted(cwds):
            records.append(name + b"\t" + str(uid).encode() + b"\t" + cwd + b"\0")
    return records


def main():
    if len(sys.argv) != 1:
        sys.exit("diskm-cwd-scan: takes no arguments")
    for _ in range(5):
        names = pids()
        records = scan(names)
        # A process forked after the listing would be missing from the map:
        # rescan until no new pid appeared while we were reading.
        if pids() <= names:
            break
    else:
        sys.exit("diskm-cwd-scan: process table kept changing")
    if not records:
        sys.exit("diskm-cwd-scan: no processes found")
    sys.stdout.buffer.write(b"".join(records))
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    try:
        main()
    except OSError as exc:
        sys.exit("diskm-cwd-scan: %s" % exc)
