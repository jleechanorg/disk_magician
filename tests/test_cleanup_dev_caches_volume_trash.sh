#!/usr/bin/env bash
# Standalone CLI regression: no BASH_ENV or exported functions provide helpers.
# All candidates are disposable fixtures; C14 must keep the unknown Trash item.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d -t test_dev_caches_volume_trash.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
HOME_FIXTURE="$WORK/home"
mkdir -p "$HOME_FIXTURE" "$WORK/tmp" "$WORK/state"
python3 - "$WORK" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
home = root / 'home'
volume = home / 'Scratch'
trash = volume / ('.Trash-' + str(os.getuid()))
for parent in (trash, home / 'unconfigured' / trash.name):
    (parent / 'files').mkdir(parents=True)
    (parent / 'info').mkdir()
    (parent / 'files' / 'unknown-artifact').write_bytes(b'x' * (2 * 1024 * 1024))
    (parent / 'info' / 'unknown-artifact.trashinfo').write_text('[Trash Info]\nPath=/fixture/original\n')
(root / 'config.json').write_text(json.dumps({'volumes': {
    'swap_headroom_gb': 1, 'alarm_floor_gb': 1, 'encryption': 'none',
    'classes': {'scratch': {'name': 'diskm-scratch', 'quota_gb': 30,
                            'mountpoint': str(volume)}}}}))
# Deny hardcoded non-HOME roots independently of the sandbox backstop.
(root / 'safety.json').write_text(json.dumps({'never_delete': [
    '/private/tmp/jest_dx', '/private/tmp/worldai-ios-compilation-cache']}))
PY
TRASH="$HOME_FIXTURE/Scratch/.Trash-$(id -u)"
run_cli() {
  # env -i strips BASH_ENV, ENV and all BASH_FUNC_* entries, not just known names.
  env -i PATH="$PATH" TZ=UTC HOME="$HOME_FIXTURE" TMPDIR="$WORK/tmp" \
    DISK_MAGICIAN_CONFIG="$WORK/config.json" \
    DISK_MAGICIAN_SAFETY_FILE="$WORK/safety.json" \
    DISK_MAGICIAN_STATE_DIR="$WORK/state" \
    DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$WORK" \
    DISK_MAGICIAN_DELETION_LOG="$WORK/deletions.log" \
    bash "$REPO_ROOT/disk_magician.sh" cleanup-dev-caches "$@"
}
run_cli --dry-run >"$WORK/dry.log" 2>&1
cat "$WORK/dry.log"
grep -Fq "would delete contents of $TRASH" "$WORK/dry.log"
[[ -f "$TRASH/files/unknown-artifact" ]]
run_cli --clean >"$WORK/clean.log" 2>&1
cat "$WORK/clean.log"
grep -Fq "C14 kept: $TRASH/files/unknown-artifact (kept:recent-activity)" "$WORK/clean.log"
[[ -f "$TRASH/files/unknown-artifact" ]]
[[ -f "$TRASH/info/unknown-artifact.trashinfo" ]]
if grep -Fq "$HOME_FIXTURE/unconfigured" "$WORK/clean.log"; then
  echo "FAIL: scanned unconfigured volume" >&2
  exit 1
fi
[[ ! -s "$WORK/deletions.log" ]]
echo 'PASS: standalone CLI discovers configured volume Trash, invokes real C14, preserves refused item and metadata, and does not scan unconfigured volume'
