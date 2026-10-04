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

# Exercise packaged auto-repair through the real installer, with launchctl stubbed.
with tempfile.TemporaryDirectory(prefix="packaged-health-repair-") as tmp:
    fixture = pathlib.Path(tmp).resolve()
    checkout = fixture / "checkout"
    package = fixture / "site-packages/disk_magician"
    home = fixture / "home"
    dest = home / "Library/LaunchAgents"
    shim = fixture / "bin"
    dest.mkdir(parents=True)
    shim.mkdir()
    trace = fixture / "launchctl.log"
    launchctl = shim / "launchctl"
    launchctl.write_text('#!/bin/sh\nprintf "%s\n" "$*" >> "$LAUNCHCTL_TRACE"\n')
    launchctl.chmod(0o755)
    label = "com.disk-magician.colima-prune"
    for layout in (checkout, package):
        (layout / "scripts").mkdir(parents=True)
        (layout / "launchd").mkdir()
        shutil.copy2(root / "scripts/install_launchd_sweepers.sh", layout / "scripts")
        shutil.copy2(root / ("launchd/" + label + ".plist"), layout / "launchd")
    shutil.copy2(root / "src/disk_magician/scripts/sweeper_health_check.sh", package / "scripts")
    broken = dest / (label + ".plist")
    broken.write_text("corrupt fixture\n")
    template = (root / "launchd/com.disk-magician.sweeper-health.plist").read_text()
    rendered = template.replace("@HOME@", str(home)).replace("@REPO_ROOT@", str(checkout))
    config = plistlib.loads(re.sub(r"<!--.*?-->", "", rendered, flags=re.DOTALL).encode())
    env = {
        "HOME": str(home), "PATH": str(shim) + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "DISK_MAGICIAN_STATE_DIR": str(fixture / "state"), "LAUNCHCTL_TRACE": str(trace),
        **config.get("EnvironmentVariables", {}),
    }
    result = subprocess.run(
        ["/bin/bash", str(package / "scripts/sweeper_health_check.sh"),
         "--auto-repair", "--no-notify"], env=env, capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 1, result.stdout + result.stderr
    repaired = plistlib.loads(re.sub(rb"<!--.*?-->", b"", broken.read_bytes(), flags=re.DOTALL))
    expected = str(checkout / "scripts/cleanup_colima.sh")
    assert expected in repaired["ProgramArguments"], repaired["ProgramArguments"]
    assert str(package) not in broken.read_text(), broken.read_text()
    assert "bootstrap" in trace.read_text()
    assert config["EnvironmentVariables"]["DISK_MAGICIAN_INSTALLER"] == str(
        checkout / "scripts/install_launchd_sweepers.sh"
    )
    print("PASS: packaged watchdog repairs through checkout installer and preserves repo paths")
PY
