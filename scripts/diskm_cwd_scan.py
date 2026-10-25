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


MAX_SCAN_PASSES = 200


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
    # Completeness means: every pid ALIVE when we finish has been scanned in some
    # pass. The previous rule demanded a single pass during which no new pid
    # appeared at all (`if pids() <= names`), retried 5 times. On a host that forks
    # continuously (CI runners, agent fleets) that is unsatisfiable, so this exited
    # rc 1 with "process table kept changing" on EVERY attempt. The caller then had
    # no privileged map, fell back to `kept:cwd-unknown`, and every cwd-gated Linux
    # cleanup refused. Measured on jeff-ubuntu 2026-10-23: 3/3 attempts failed and
    # /tmp (174 GiB) could not be reclaimed at all, which in turn kept free space
    # under ezgha's min_free_disk_gb=30 so the runner fleet could not start.
    # Scan only the pids not yet covered and accept once the live set is a subset
    # of what we covered. Convergence is monotonic: each pass only has to read pids
    # forked since the previous pass.
    # Completeness means: every pid that is ALIVE when we finish has been scanned
    # in some pass. The original rule demanded a single pass during which no new
    # pid appeared (`if pids() <= names`), retried 5 times -- unsatisfiable on a
    # host that forks continuously, so it exited rc 1 with "process table kept
    # changing" every time and the caller fell back to kept:cwd-unknown.
    #
    # This version keeps the SAME fail-closed guarantee but makes convergence
    # reachable: each pass scans only the pids not yet covered, so the work per
    # pass shrinks to just what was forked since the previous pass. It succeeds
    # only when the live pid set is fully covered; if it cannot reach that within
    # MAX_SCAN_PASSES it exits non-zero, exactly like before.
    #
    # Do NOT relax this to a time/attempt "best effort" success: a child that
    # chdir()s immediately after being skipped would not be covered, and nothing
    # about fork's cwd inheritance proves otherwise. A non-zero exit is the
    # correct answer when coverage cannot be established.
    seen = set()
    records = []
    for _ in range(MAX_SCAN_PASSES):
        todo = pids() - seen
        if not todo:
            break
        records.extend(scan(todo))
        seen |= todo
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
