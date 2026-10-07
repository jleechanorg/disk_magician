#!/usr/bin/env bash
# Contract test for the public audit --help seam.
# The fixture diagnostic helper records any launch and exits immediately, so
# this test can never reach a real frontier/history/worktree scan.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d -t disk_audit_help.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

SNAPSHOT="$WORK/fixture-snapshot.json"
printf '%s\n' '{}' >"$SNAPSHOT"

for source in "$REPO_ROOT/disk_magician.sh" "$REPO_ROOT/src/disk_magician/disk_magician.sh"; do
  dispatcher_root="$WORK/$(basename "$(dirname "$source")")"
  mkdir -p "$dispatcher_root/scripts/lib"
  cp "$source" "$dispatcher_root/disk_magician.sh"
  chmod +x "$dispatcher_root/disk_magician.sh"
  cp "$REPO_ROOT/scripts/lib/resolve_snapshot_json.sh" \
    "$dispatcher_root/scripts/lib/resolve_snapshot_json.sh"

  helper_log="$WORK/$(basename "$(dirname "$source")")-diagnostic.log"
  cat >"$dispatcher_root/scripts/disk_diagnostic.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$AUDIT_HELP_LAUNCH_LOG"
printf '%s\n' 'UNEXPECTED_SCAN: disk_diagnostic fixture launched' >&2
exit 99
EOF
  chmod +x "$dispatcher_root/scripts/disk_diagnostic.sh"

  for preceding in "" "--no-history"; do
  args=(audit)
  [[ -z "$preceding" ]] || args+=("$preceding")
  args+=(--help)
  output=""
  rc=0
  output="$(env \
    AUDIT_HELP_LAUNCH_LOG="$helper_log" \
    DISK_MAGICIAN_SNAPSHOT_FILE="$SNAPSHOT" \
    HOME="$WORK/home" \
    bash "$dispatcher_root/disk_magician.sh" "${args[@]}" 2>&1)" || rc=$?

  if [[ "$rc" -ne 0 ]]; then
    echo "FAIL: $(basename "$source") audit --help exited $rc"
    printf '%s\n' "$output"
    exit 1
  fi
  if [[ "$output" != *"Usage:"* ]]; then
    echo "FAIL: $(basename "$source") audit --help did not show usage"
    printf '%s\n' "$output"
    exit 1
  fi
  if [[ -s "$helper_log" ]] || [[ "$output" == *"UNEXPECTED_SCAN:"* ]]; then
    echo "FAIL: $(basename "$source") audit --help launched the diagnostic scanner"
    printf '%s\n' "$output"
    exit 1
  fi
  done
done

echo "PASS: audit --help shows usage without launching diagnostic scanners"
