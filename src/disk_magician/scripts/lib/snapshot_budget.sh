# shellcheck shell=bash
# snapshot_budget.sh — per-path measurement budget helpers for disk_snapshot.sh.
# Sourceable on its own (disk_snapshot.sh is not).

# load_factor: clamp(load1/cores, 1, 3), printed with 2 decimals.
# DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE pins the raw ratio (tests, benchmarks).
load_factor() {
  local raw="${DISK_MAGICIAN_LOAD_FACTOR_OVERRIDE:-}"
  if [[ -z "$raw" ]]; then
    local load1 cores sysctl_bin=sysctl
    [[ -x /usr/sbin/sysctl ]] && sysctl_bin=/usr/sbin/sysctl
    load1=$("$sysctl_bin" -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
    [[ -n "$load1" ]] || load1=$(uptime 2>/dev/null | sed -E 's/.*load averages?: *//' | awk -F'[ ,]+' '{print $1}')
    cores=$("$sysctl_bin" -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)
    raw=$(awk -v l="${load1:-0}" -v c="${cores:-1}" 'BEGIN{ if (c < 1) c = 1; printf "%.4f", l / c }')
  fi
  awk -v r="$raw" 'BEGIN{ if (r < 1) r = 1; if (r > 3) r = 3; printf "%.2f", r }'
}

# scaled_path_budget TIMEOUT FACTOR: min(240, TIMEOUT * FACTOR), whole seconds.
scaled_path_budget() {
  awk -v t="$1" -v f="$2" 'BEGIN{ b = t * f; if (b > 240) b = 240; printf "%d", b }'
}

# User-owned config holding the optional "snapshot_measure" object (kill switch
# that needs no redeploy). The packaged config.json is a template replaced on
# every reinstall, so it is never consulted here.
snapshot_user_config_path() {
  if [[ -n "${DISK_MAGICIAN_USER_CONFIG:-}" ]]; then
    printf '%s' "$DISK_MAGICIAN_USER_CONFIG"
  else
    printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/disk-magician/config.json"
  fi
}

# snapshot_measure_setting KEY: prints the non-negative integer value, or nothing.
snapshot_measure_setting() {
  python3 - "$(snapshot_user_config_path)" "$1" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("snapshot_measure", {}).get(sys.argv[2])
    if isinstance(v, int) and not isinstance(v, bool) and v >= 0:
        print(v)
except Exception:
    pass
PY
}
