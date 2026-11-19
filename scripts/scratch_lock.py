#!/usr/bin/env python3
# Compatibility dispatcher for former serialized Scratch cleanup entrypoints.
# Cleanup commands run directly and retain their per-entry/registry safety.

from __future__ import annotations

import argparse
import os
import re
import sys


def disable_implicit_git_fsmonitor() -> None:
    # Keep cleanup-triggered Git probes from starting persistent fsmonitor daemons.
    raw = os.environ.get("GIT_CONFIG_COUNT", "")
    if raw and not re.fullmatch(r"[ \t\n\r\v\f]*[+-]?[0-9]+", raw):
        return
    normalized = raw.lstrip(" \t\n\r\v\f")
    digits = normalized.lstrip("+-").lstrip("0") or "0"
    if len(digits) > 10:
        return
    count = int(digits) * (-1 if normalized.startswith("-") else 1)
    if not 0 <= count < 2147483647:
        return
    os.environ[f"GIT_CONFIG_KEY_{count}"] = "core.fsmonitor"
    os.environ[f"GIT_CONFIG_VALUE_{count}"] = "false"
    os.environ["GIT_CONFIG_COUNT"] = str(count + 1)


def run(caller: str, script: str, args: list[str]) -> int:
    disable_implicit_git_fsmonitor()
    try:
        os.execvpe(script, [script, *args], os.environ)
    except OSError as exc:
        print(f"[{caller}] could not execute {script}: {exc}", file=sys.stderr)
        return 127
    return 127


def main() -> int:
    argv = sys.argv[1:]
    if argv[:1] == ["run"]:
        try:
            caller = argv[argv.index("--caller") + 1]
            script = argv[argv.index("--script") + 1]
            marker = argv.index("--args")
            args = argv[marker + 1:]
            if args[:1] == ["--"]:
                args = args[1:]
        except (ValueError, IndexError):
            print("scratch_lock.py: invalid run arguments", file=sys.stderr)
            return 2
        return run(caller, script, args)

    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--fd", type=int, required=True)
    parser.parse_args(argv)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
