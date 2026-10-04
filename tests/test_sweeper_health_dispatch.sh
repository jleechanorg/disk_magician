#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
for tree in (root, root / "src/disk_magician"):
    with tempfile.TemporaryDirectory(prefix="sweeper-health-dispatch-") as tmp:
        fixture = pathlib.Path(tmp)
        shutil.copy2(tree / "disk_magician.sh", fixture / "disk_magician.sh")
        (fixture / "scripts").mkdir()
        helper = fixture / "scripts/sweeper_health_check.sh"
        helper.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nexit 23\n')
        helper.chmod(0o755)
        args = ["--threshold-days", "7", "--auto-repair"]
        result = subprocess.run(
            ["/bin/bash", str(fixture / "disk_magician.sh"), "sweeper-health", *args],
            env={**os.environ, "HOME": tmp}, capture_output=True, text=True,
        )
        assert result.returncode == 23, result.stderr + result.stdout
        assert result.stdout.splitlines() == args, result.stdout
        print(f"PASS: {tree.name} health dispatch forwards arguments and exit status")

    raw = (tree / "launchd/com.disk-magician.sweeper-health.plist").read_bytes()
    plist = plistlib.loads(re.sub(rb"<!--.*?-->", b"", raw, flags=re.DOTALL))
    assert plist["ProgramArguments"] == [
        "@HOME@/.local/bin/diskm", "sweeper-health", "--threshold-days", "7", "--auto-repair",
    ]
    assert plist["StartCalendarInterval"] == {"Hour": 9, "Minute": 0}
    assert plist["Label"] == "com.disk-magician.sweeper-health"
    for key in ("StandardOutPath", "StandardErrorPath"):
        assert plist[key] == "@HOME@/Library/Logs/disk-magician-sweeper-health.log"
    print(f"PASS: {tree.name} scheduled health uses installed CLI and durable logs")
PY
