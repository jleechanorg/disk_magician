#!/usr/bin/env bash
# T11-14 caller wiring guard: cleanup_tmp and shared scratch-budget eviction
# must nominate content through C14 quarantine, while script-owned probe files
# may still be unlinked directly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
check() {
  local name="$1" condition="$2"
  if eval "$condition"; then
    echo "PASS $name"
    PASS=$(( PASS + 1 ))
  else
    echo "FAIL $name"
    FAIL=$(( FAIL + 1 ))
  fi
}

python3 - "$ROOT/scripts/cleanup_tmp.sh" "$ROOT/scripts/lib/scratch_budget.sh" <<'PY'
import re, sys

tmp = open(sys.argv[1], encoding="utf-8").read()
budget = open(sys.argv[2], encoding="utf-8").read()

def function(source, name):
    match = re.search(r"(?ms)^" + re.escape(name) + r"\(\) \{\n(.*?)^\}", source)
    if not match:
        raise SystemExit(f"missing function {name}")
    return match.group(1)

remove_path = function(tmp, "remove_path")
purge = function(tmp, "purge_aged_archives")
evict = function(budget, "scratch_budget_evict_root")
helper = function(budget, "scratch_budget_quarantine_remove")

assert "quarantine_remove" in helper and "--kind ephemeral" in helper
assert "scratch_budget_quarantine_remove \"$path\"" in remove_path
assert "scratch_budget_quarantine_remove \"$d\"" in purge
assert "scratch_budget_quarantine_remove \"$item_i\"" in evict
assert 'scratch_budget_quarantine_remove "$f"' in tmp
assert not re.search(r'\brm\s+-f\s+"\$f"', tmp)
assert not re.search(r"\brm\s+-rf?\s+\"\$(?:path|d|item_i)\"", remove_path + purge + evict)
assert "archive_overcap_kept" in purge
assert "ACT_DEADLINE_AT" in helper
print("T11-14 candidate-removal callsites route through C14; over-cap keeps are logged")
PY

check "cleanup_tmp package mirror matches" "cmp -s '$ROOT/scripts/cleanup_tmp.sh' '$ROOT/src/disk_magician/scripts/cleanup_tmp.sh'"
check "scratch_budget package mirror matches" "cmp -s '$ROOT/scripts/lib/scratch_budget.sh' '$ROOT/src/disk_magician/scripts/lib/scratch_budget.sh'"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
