#!/usr/bin/env python3
"""Resolve scratch-new's durable shell producer PIDs (bounded to 2 ancestors)."""
import subprocess
import sys


def process(pid):
    result = subprocess.run(
        ["ps", "-ww", "-p", str(pid), "-o", "ppid=,args="],
        check=True, capture_output=True, text=True, timeout=2,
    )
    fields = result.stdout.strip().split(None, 1)
    if len(fields) != 2:
        raise ValueError("incomplete process identity")
    return int(fields[0]), fields[1]


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit() or int(sys.argv[1]) <= 1:
        return 1
    parent = int(sys.argv[1])
    try:
        grandparent, parent_args = process(parent)
        if grandparent <= 1:
            print(parent)
            return 0
        _, grandparent_args = process(grandparent)
        # Bash command substitutions can create a short-lived child with the
        # same full command line as the shell that consumes the returned path.
        # Keep both; lease-side incarnation checks bind each PID atomically.
        pids = [parent, grandparent] if parent_args == grandparent_args else [parent]
        print(",".join(map(str, pids)))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
