#!/usr/bin/env bash
# check_system_residual.sh — Diagnose system-level residual space gaps
#
# Inspects system staging directories (/private/var/dirs_cleaner, etc.)
# and unified logs for deleted_helper ENAMETOOLONG errors when residual disk space is high.
set -euo pipefail

TARGET_DIR="${TARGET_DIR:-/private/var/dirs_cleaner}"
JSON_OUTPUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUTPUT=true; shift ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--json]"
      echo "Diagnoses /private/var/dirs_cleaner accumulation and deleted_helper log errors."
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

dirs_cleaner_mb=0
if [[ -d "$TARGET_DIR" ]]; then
  dirs_cleaner_mb="$(sudo -n du -sm "$TARGET_DIR" 2>/dev/null | awk '{print $1}' || echo "0")"
fi

enametoolong_count=0
if [[ "${DISK_MAGICIAN_SKIP_LOG_CHECK:-0}" != "1" ]] && command -v log &>/dev/null; then
  enametoolong_count="$(log show --predicate 'process == "deleted_helper" AND eventMessage CONTAINS "removefile error"' --last 7d 2>/dev/null | grep -c "removefile error" || echo "0")"
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
  cat <<EOF
{
  "dirs_cleaner_mb": $dirs_cleaner_mb,
  "enametoolong_log_count": $enametoolong_count,
  "dirs_cleaner_path": "$TARGET_DIR"
}
EOF
else
  echo "=== System Residual Diagnostic ==="
  echo "/private/var/dirs_cleaner size: ${dirs_cleaner_mb} MB"
  echo "deleted_helper ENAMETOOLONG log errors (last 7d): ${enametoolong_count}"
  if [[ "$dirs_cleaner_mb" -gt 1024 ]]; then
    echo "WARNING: /private/var/dirs_cleaner has accumulated >1 GiB (${dirs_cleaner_mb} MB)."
    echo "Remediation command: ./scripts/cleanup_dirs_cleaner.sh --clean"
  fi
fi
