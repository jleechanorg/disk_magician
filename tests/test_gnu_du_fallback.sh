#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO_ROOT="$ROOT"
export DISK_MAGICIAN_GDU_CMD=""
ok() { echo PASS; }
bad() { echo FAIL; exit 1; }
GNU_DU_DISCOVERY_OUT=$(cd "$REPO_ROOT" && python3 - <<'PY'
import subprocess
import sys
from unittest import mock

sys.path.insert(0, "scripts")
import disk_frontier_scan as m

gnu_version = subprocess.CompletedProcess(
    ["/usr/bin/du", "--version"], 0,
    stdout="du (GNU coreutils) 9.4\n", stderr=""
)
with mock.patch.object(m, "_GDU_OVERRIDE", None), \
     mock.patch.object(m.shutil, "which", side_effect=lambda name: {
         "gdu": None, "du": "/usr/bin/du"
     }.get(name)), \
     mock.patch.object(m.subprocess, "run", return_value=gnu_version):
    linux_du = m._discover_gnu_du_cmd()

bsd_version = subprocess.CompletedProcess(
    ["/usr/bin/du", "--version"], 1,
    stdout="", stderr="du: illegal option -- -\n"
)
with mock.patch.object(m, "_GDU_OVERRIDE", None), \
     mock.patch.object(m.shutil, "which", side_effect=lambda name: {
         "gdu": None, "du": "/usr/bin/du"
     }.get(name)), \
     mock.patch.object(m.subprocess, "run", return_value=bsd_version):
    bsd_du = m._discover_gnu_du_cmd()

with mock.patch.object(m, "_GDU_OVERRIDE", "/custom/gdu"), \
     mock.patch.object(m.subprocess, "run") as run:
    explicit_du = m._discover_gnu_du_cmd()
    explicit_untouched = not run.called

with mock.patch.object(m, "_GDU_OVERRIDE", ""):
    disabled = m._discover_gnu_du_cmd()

print(linux_du == "/usr/bin/du", bsd_du is None,
      explicit_du == "/custom/gdu" and explicit_untouched, disabled is None)
PY
)
[[ "$GNU_DU_DISCOVERY_OUT" == "True True True True" ]] && ok "auto-discover GNU du, reject BSD du, and preserve explicit overrides" \
  || bad "GNU du discovery contract failed: $GNU_DU_DISCOVERY_OUT"

[[ "$GNU_DU_DISCOVERY_OUT" == "True True True True" ]] && echo "PASS GNU du detection, BSD rejection, gdu priority and overrides" || { echo "FAIL GNU du detection: $GNU_DU_DISCOVERY_OUT" >&2; exit 1; }
