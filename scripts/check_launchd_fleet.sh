#!/usr/bin/env bash
# check_launchd_fleet.sh — Verify disk_magician's own launchd automation is alive.
#
# Root cause 2026-09-06: every disk-investigation session (this one included,
# repeatedly) started with floor/bucket accounting and never asked "is my own
# collector even running?" On 2026-09-06 it was found that up to 16 of
# disk_magician's launchd jobs — including the daily sweeper-health watchdog
# whose entire job is to detect exactly this — had gone silently unloaded for
# ~6 days (all plists stamped the same second, one mass event; some were
# malformed <array>-without-<dict>, launchd's failure mode for which is total
# silence: no crash log, no `launchctl list` entry at all). Prior incidents
# of the same externally-observable symptom (disk fills, nothing self-heals):
# 2026-07-22 "never-firing launchd sweepers", 2026-07-29 "interval-elapsed"
# false-negative. Every fix so far patched the specific mechanism, not the
# symptom class — this script is the mechanism-agnostic guardrail: it runs
# BEFORE any accounting (wired into disk_audit.sh's very first section) and
# does not itself depend on launchd being healthy to report launchd's health.
#
# Exit code: 0 if every known label is loaded and its plist lints clean,
# 1 if any are missing/unloaded/invalid. Read-only; never modifies anything.
set -euo pipefail

PLIST_DIR="${DISK_MAGICIAN_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"

# Canonical fleet — keep in sync with scripts/install_launchd_sweepers.sh's
# two template families (com.jleechanorg.disk-magician-*, com.disk-magician.*)
# plus the primary snapshot job and the root frontier LaunchDaemon.
KNOWN_LABELS=(
  com.jleechanorg.disk-magician
  com.jleechanorg.disk-magician-downloads-evidence
  com.jleechanorg.disk-magician-drilldown
  com.jleechanorg.disk-magician-frontier-nightly
  com.jleechanorg.disk-magician-frontier-root
  com.jleechanorg.disk-magician-observer
  com.jleechanorg.disk-magician-pressure-sweep
  com.jleechanorg.disk-magician-tmp-scratch
  com.jleechanorg.disk-magician-worktree-hygiene
  com.disk-magician.colima-prune
  com.disk-magician.cursor-logs-watchdog
  com.disk-magician.fsevents-projects
  com.disk-magician.hermes-vacuum
  com.disk-magician.playwright-dedup
  com.disk-magician.sweeper-health
  com.disk-magician.worktree-venvs
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [-h|--help]

Checks every known disk-magician launchd label for two independent failure
modes: (1) not currently loaded (\`launchctl list\`), (2) installed plist is
structurally invalid (\`plutil -lint\`). Read-only. Exit 0 = all healthy.
EOF
}
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

if [[ "$OSTYPE" != darwin* ]]; then
  echo "check_launchd_fleet: not macOS — launchd fleet check skipped (n/a on this OS)."
  exit 0
fi

missing=0
not_loaded=0
invalid=0
ok=0

for label in "${KNOWN_LABELS[@]}"; do
  plist="$PLIST_DIR/${label}.plist"
  if [[ ! -f "$plist" ]]; then
    echo "  MISSING PLIST   $label  (expected $plist)"
    missing=$(( missing + 1 ))
    continue
  fi
  if ! plutil -lint "$plist" >/dev/null 2>&1; then
    echo "  INVALID PLIST   $label  ($plist fails plutil -lint — launchd will silently refuse to load it)"
    invalid=$(( invalid + 1 ))
    continue
  fi
  # plutil -lint only validates plist XML syntax — a top-level <array> with no
  # <dict> wrapper (the actual 2026-09-06 failure mode) is syntactically legal
  # plist and passes -lint, but is not a valid launchd job description and
  # launchd refuses it with zero visible error. A missing Label key is the
  # cheapest reliable signal that this happened.
  if ! plutil -extract Label raw -o - "$plist" >/dev/null 2>&1; then
    echo "  INVALID PLIST   $label  ($plist has no top-level Label key — likely missing its <dict> wrapper; passes plutil -lint but launchd will silently refuse to load it)"
    invalid=$(( invalid + 1 ))
    continue
  fi
  if ! launchctl list 2>/dev/null | grep -qF "$label"; then
    echo "  NOT LOADED      $label  (plist valid but launchctl has no record — try: launchctl load \"$plist\")"
    not_loaded=$(( not_loaded + 1 ))
    continue
  fi
  ok=$(( ok + 1 ))
done

total=${#KNOWN_LABELS[@]}
echo "  Fleet: $ok/$total loaded and valid."

if [[ $((missing + not_loaded + invalid)) -gt 0 ]]; then
  echo "  ⚠️  $((missing + not_loaded + invalid)) job(s) unhealthy — floor/history data below may be stale or absent."
  echo "  Repair: bash scripts/install_launchd_sweepers.sh   (rewrites every plist from its template and reloads it)"
  exit 1
fi
exit 0
