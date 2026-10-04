#!/usr/bin/env bash
# Verify the unattended pressure launchd template opts into the reviewed
# scratch budget without changing its cadence or diskm dispatch contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST="$REPO_ROOT/launchd/com.jleechanorg.disk-magician-pressure-sweep.plist.template"

[[ -f "$PLIST" ]] || { echo "FAIL: missing $PLIST" >&2; exit 1; }

python3 - "$PLIST" <<'PY'
import plistlib
import re
import sys

path = sys.argv[1]
with open(path, "rb") as handle:
    # The tracked template's operational comments contain shell `--` tokens,
    # which are legal documentation here but not legal XML comment content.
    # Strip comments in memory only; never rewrite the tracked template.
    raw = re.sub(rb"<!--.*?-->", b"", handle.read(), flags=re.DOTALL)
plist = plistlib.loads(raw)

env = plist.get("EnvironmentVariables")
assert isinstance(env, dict), "EnvironmentVariables must be a dictionary"
assert env.get("DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB") == "15", (
    "DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB must be exactly '15'"
)
assert plist.get("StartInterval") == 1800, "StartInterval must remain 1800 seconds"
assert plist.get("ProgramArguments") == ["@HOME@/.local/bin/diskm", "pressure-sweep"], (
    "ProgramArguments must continue to dispatch diskm pressure-sweep"
)
PY

echo "All pressure_sweep_scratch_budget_enabled tests passed."
