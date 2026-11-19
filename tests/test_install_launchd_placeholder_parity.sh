#!/usr/bin/env bash
# Placeholder parity between the LaunchAgent and LaunchDaemon install paths.
#
# Both paths render the same templates with their own `sed -e s|@X@|...|g` list.
# When the lists drift, a placeholder reaches the installed plist as its literal
# "@NAME@" form and fails silently at runtime -- plists stay syntactically valid,
# so plutil -lint cannot catch it (Spotted 2026-11-19: the daemon path lacked
# @SCRATCH_BUDGET_FLOOR_HOURS@ while the agent path had it).
#
# This asserts every placeholder appearing in any launchd template is substituted
# by BOTH render functions.
set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/install_launchd_sweepers.sh"
TPL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/launchd"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n    %s\n' "$1" "${2:-}"; }

# Every @PLACEHOLDER@ used by any template THIS installer renders. Templates
# owned by a different installer (e.g. the frontier-root daemon, rendered by
# install_root_frontier_runner.sh with its own @USER_HOME@ substitution) are out
# of scope here; asserting them would be a false failure.
mapfile -t used < <(
  for t in "$TPL_DIR"/*.template; do
    grep -q 'frontier-root' <<<"$t" && continue
    grep -oh '@[A-Z_][A-Z0-9_]*@' "$t" 2>/dev/null
  done | sort -u
)
[[ ${#used[@]} -gt 0 ]] || { echo "no placeholders found; nothing to check"; exit 0; }

# The two render functions' bodies.
agent_body="$(sed -n '/^install_plist()/,/^}/p' "$SCRIPT")"
daemon_body="$(sed -n '/^install_launchdaemon()/,/^}/p' "$SCRIPT")"

for ph in "${used[@]}"; do
  if grep -qF "$ph" <<<"$agent_body"; then
    ok "agent path substitutes $ph"
  else
    bad "agent path substitutes $ph" "missing in install_plist"
  fi
  if grep -qF "$ph" <<<"$daemon_body"; then
    ok "daemon path substitutes $ph"
  elif [[ "$ph" == "@REPO_ROOT@" || "$ph" == "@HOME@" || "$ph" == "@BASH@" || "$ph" == "@SCRATCH_BUDGET_FLOOR_HOURS@" ]]; then
    bad "daemon path substitutes $ph" "missing in install_launchdaemon"
  else
    bad "daemon path substitutes $ph" "missing in install_launchdaemon"
  fi
done

echo "test_install_launchd_placeholder_parity: ${PASS} passed, ${FAIL} failed"
(( FAIL == 0 )) || exit 1
exit 0
