#!/usr/bin/env python3
"""Render a native launchd or systemd template.

Every @<NAME>_SECONDS@ placeholder is filled from `diskm time-windows`, the
single source of default time windows (rust/src/time_windows.rs). @HOME@ is
the invoking user's home. Any placeholder left unfilled is an error.

Usage: render_template.py TEMPLATE OUTPUT [--diskm PATH] [--set NAME=VALUE ...]

--set fills non-window placeholders such as @STATE_PATH@; it cannot
override a time window.
"""
import json
import os
import re
import subprocess
import sys


def main(argv):
    args = argv[1:]
    if len(args) < 2:
        sys.exit(__doc__)
    template, output, rest = args[0], args[1], args[2:]
    diskm, extra = "diskm", {}
    while rest:
        flag, value, rest = rest[0], rest[1] if len(rest) > 1 else None, rest[2:]
        if value is None or flag not in ("--diskm", "--set"):
            sys.exit(__doc__)
        if flag == "--diskm":
            diskm = value
        else:
            name, _, setting = value.partition("=")
            if not re.fullmatch(r"[A-Z_]+", name) or not setting or name.endswith("_SECONDS"):
                sys.exit(f"invalid --set {value!r}")
            extra[name] = setting
    windows = json.loads(subprocess.run([diskm, "time-windows"], check=True, capture_output=True, text=True).stdout)
    values = {**extra, **{name: str(seconds) for name, seconds in windows.items()}}
    values["HOME"] = os.path.expanduser("~")
    text = open(template, encoding="utf-8").read()
    rendered = re.sub(r"@([A-Z_]+)@", lambda match: values.get(match.group(1), match.group(0)), text)
    left = sorted(set(re.findall(r"@[A-Z_]+@", rendered)))
    if left:
        sys.exit(f"unfilled placeholders in {template}: {', '.join(left)}")
    temporary = f"{output}.tmp.{os.getpid()}"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(rendered)
    os.replace(temporary, output)


if __name__ == "__main__":
    main(sys.argv)
