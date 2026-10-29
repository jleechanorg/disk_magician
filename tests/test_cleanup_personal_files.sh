#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRATCH_ROOT="${DISKM_SCRATCH:-${TMPDIR:-/tmp}}"
TEST_ROOT="$(mktemp -d "$SCRATCH_ROOT/personal-files-regression.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
FIXTURE_HOME="$TEST_ROOT/home"
HOME="${REAL_HOME_FOR_TEST:-$HOME}"
DOWNLOADS="$FIXTURE_HOME/Downloads"
SCREENSHOTS="$FIXTURE_HOME/Pictures/Screenshots"
DESKTOP="$FIXTURE_HOME/Desktop"
LOG="$TEST_ROOT/deletions.log"
SAFETY="$TEST_ROOT/safety.local.json"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$DOWNLOADS" "$SCREENSHOTS" "$DESKTOP" "$FAKE_BIN"

cat >"$FAKE_BIN/lsof" <<'EOF'
#!/usr/bin/env bash
case "${FAKE_LSOF_MODE:-none}" in
  active) printf 'p123\nn%s\n' "${FAKE_LSOF_PATH:-}"; exit 0 ;;
  fail) exit 2 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/lsof"
export HOME DISK_MAGICIAN_DOWNLOADS_ROOT="$DOWNLOADS"
export DISK_MAGICIAN_SCREENSHOT_ROOT="$SCREENSHOTS" DISK_MAGICIAN_DESKTOP_ROOT="$DESKTOP"
export DISK_MAGICIAN_DELETION_LOG="$LOG" DISK_MAGICIAN_LSOF_BIN="$FAKE_BIN/lsof"

assert_exists() { [[ -e "$1" || -L "$1" ]] || { echo "missing: $1" >&2; exit 1; }; }
assert_missing() { [[ ! -e "$1" && ! -L "$1" ]] || { echo "present: $1" >&2; exit 1; }; }

HELP="$(bash "$REPO_ROOT/disk_magician.sh" cleanup-personal-files --help)"
grep -q 'Usage:' <<<"$HELP"
if bash "$REPO_ROOT/disk_magician.sh" cleanup-personal-files --clean >/dev/null 2>&1; then
  echo "approval gate failed" >&2; exit 1
fi

python3 -c 'import os,sys; [(open(path, "wb").close(), os.truncate(path, 101 * 1024 * 1024)) for path in sys.argv[1:]]' \
  "$DOWNLOADS/big.iso" "$DOWNLOADS/.env.local" "$DOWNLOADS/Credentials.zip" \
  "$DOWNLOADS/API_TOKEN.tar" "$DOWNLOADS/PRIVATE.key"
printf 'credential' >"$DOWNLOADS/api_credentials.txt"
mkdir "$DOWNLOADS/extracted-dir"
ln -s "$DOWNLOADS/big.iso" "$DOWNLOADS/link.iso"
python3 -c 'import os,sys; open(sys.argv[1], "wb").close(); os.utime(sys.argv[1], (1577836800, 1577836800))' \
  "$SCREENSHOTS/old-screenshot.png"
touch "$SCREENSHOTS/Screenshot-current.png"
DRY="$(FAKE_LSOF_MODE=none bash "$REPO_ROOT/disk_magician.sh" cleanup-personal-files --dry-run)"
grep -q 'would remove large download' <<<"$DRY"
assert_exists "$DOWNLOADS/big.iso"

PERSONAL_FILES_APPROVED=1 FAKE_LSOF_MODE=active FAKE_LSOF_PATH="$DOWNLOADS/big.iso" bash "$REPO_ROOT/disk_magician.sh" cleanup-personal-files --clean >/dev/null
assert_exists "$DOWNLOADS/big.iso"
PERSONAL_FILES_APPROVED=1 FAKE_LSOF_MODE=fail bash "$REPO_ROOT/disk_magician.sh" cleanup-personal-files --clean >/dev/null
assert_exists "$DOWNLOADS/big.iso"

printf '{"never_delete":["%s"]}\n' "$DOWNLOADS/big.iso" >"$SAFETY"
export DISK_MAGICIAN_SAFETY_FILE="$SAFETY"
PERSONAL_FILES_APPROVED=1 FAKE_LSOF_MODE=none bash "$REPO_ROOT/disk_magician.sh" cleanup-personal-files --clean >/dev/null
assert_exists "$DOWNLOADS/big.iso"
unset DISK_MAGICIAN_SAFETY_FILE

PERSONAL_FILES_APPROVED=1 FAKE_LSOF_MODE=none bash "$REPO_ROOT/disk_magician.sh" cleanup-personal-files --clean >/dev/null
assert_missing "$DOWNLOADS/big.iso"
assert_exists "$DOWNLOADS/.env.local"
assert_exists "$DOWNLOADS/api_credentials.txt"
assert_exists "$DOWNLOADS/Credentials.zip"
assert_exists "$DOWNLOADS/API_TOKEN.tar"
assert_exists "$DOWNLOADS/PRIVATE.key"
assert_exists "$DOWNLOADS/link.iso"
assert_exists "$DOWNLOADS/extracted-dir"
assert_missing "$SCREENSHOTS/old-screenshot.png"
assert_exists "$SCREENSHOTS/Screenshot-current.png"
grep -q 'cleanup-personal-files.sh' "$LOG"
echo "cleanup_personal_files: PASS"
