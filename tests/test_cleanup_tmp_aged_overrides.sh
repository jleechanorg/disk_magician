#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${TMPDIR:?set TMPDIR to an approved writable scratch directory}"
TMP_ROOT="$(mktemp -d "$TMPDIR/disk-magician-aged-overrides.XXXXXX")"
case "$TMP_ROOT" in "$TMPDIR"/*) ;; *) echo "unsafe fixture path: $TMP_ROOT" >&2; exit 2 ;; esac
trap 'rm -rf "$TMP_ROOT"' EXIT
PRIVATE="$TMP_ROOT/private"; ORDINARY="$TMP_ROOT/ordinary"; ARCHIVE="$TMP_ROOT/archive"; HOME_FIX="$TMP_ROOT/home"
mkdir -p "$PRIVATE" "$ORDINARY" "$HOME_FIX"
chmod 700 "$HOME_FIX"
CONFLICT_OUT="$TMP_ROOT/conflict.out"
if bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run --aged --large >"$CONFLICT_OUT" 2>&1; then
  echo "--aged --large unexpectedly combined incompatible safety windows" >&2
  cat "$CONFLICT_OUT" >&2
  exit 1
fi
grep -Fq "run one mode at a time" "$CONFLICT_OUT"
make_pr_dir() {
  local path="$1" age_minutes="$2"
  mkdir -p "$path"
  printf 'fixture\n' > "$path/payload.txt"
  python3 -c 'import os,sys,time
cutoff=time.time()-int(sys.argv[2])*60
for root, dirs, files in os.walk(sys.argv[1]):
  for name in [".", *dirs, *files]: os.utime(os.path.join(root,name), (cutoff,cutoff), follow_symlinks=False)' "$path" "$age_minutes"
}
make_pr_dir "$PRIVATE/pr123-fresh" 4260
make_pr_dir "$PRIVATE/pr456-aged" 4380
make_pr_dir "$PRIVATE/pr789-nested-active" 4380
mkdir -p "$PRIVATE/worldarchitect.ai/old-protected-child"
printf "protected fixture\n" > "$PRIVATE/worldarchitect.ai/old-protected-child/payload.txt"
python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2])*3600; [(os.utime(os.path.join(root,name),(t,t),follow_symlinks=False)) for root,dirs,files in os.walk(sys.argv[1]) for name in ["."]+dirs+files]' "$PRIVATE/worldarchitect.ai/old-protected-child" 80
printf "old prompt\n" > "$PRIVATE/agent_prompt_old.txt"
printf "fresh prompt\n" > "$PRIVATE/agent_prompt_fresh.txt"
python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2])*60; os.utime(sys.argv[1],(t,t))' "$PRIVATE/agent_prompt_old.txt" 4380
python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2])*60; os.utime(sys.argv[1],(t,t))' "$PRIVATE/agent_prompt_fresh.txt" 4260
touch "$PRIVATE/pr789-nested-active/recent.txt"
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/stat" <<'MOCK'
#!/usr/bin/env bash
if [[ "$(uname -s)" == Darwin ]]; then exec /usr/bin/stat "$@"; fi
if [[ "${1:-}" == "-f" && "${2:-}" == "%m" ]]; then exec /usr/bin/stat -c %Y "$3"; fi
exec /usr/bin/stat "$@"
MOCK
chmod +x "$TMP_ROOT/bin/stat"
cat > "$TMP_ROOT/bin/lsof" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "-w" ]]; then exit 1; fi
if [[ "${1:-}" == "-nP" ]]; then exit 1; fi
if [[ "$*" == "-n -P -d cwd -Fpn" ]]; then printf "p123\nn/\n"; exit 0; fi
if [[ "$*" == "+w -n -P -F fnt" ]]; then printf "p123\nfcwd\nn/\n"; exit 0; fi
exit 99
MOCK
chmod +x "$TMP_ROOT/bin/lsof"

make_pr_dir "$PRIVATE/pr168-eighty-hours" 4800
make_pr_dir "$PRIVATE/pr240-old-enough" 18000
run_fixture() {
  local out="$1"; shift
  env -i HOME="$HOME_FIX" TMPDIR="$TMP_ROOT" PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
    DISK_MAGICIAN_LSOF_BIN="$TMP_ROOT/bin/lsof" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
    DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMP_ROOT" \
    DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PRIVATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$ORDINARY" \
    DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE" LARGE_TMP_APPROVED=1 \
    "$@" >"$out" 2>&1
  cat "$out"
}
FAIL=0
assert_contains() {
  if grep -Fq "$2" "$1"; then echo "PASS $3"; else echo "FAIL $3"; FAIL=$((FAIL + 1)); fi
}
# Both inherited environment safety overrides must survive the new hourly mode.
OUT="$TMP_ROOT/active.out"
run_fixture "$OUT" LARGE_TMP_ACTIVE_HOURS=168 AGED_TMP_ACTIVE_HOURS=72 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run --aged
assert_contains "$OUT" "Skipping recently active dir (mtime/ctime within 168h): $PRIVATE/pr168-eighty-hours" "168h legacy activity protects 80h candidate"
assert_contains "$OUT" "DRY RUN: would archive: $PRIVATE/pr240-old-enough" "older eligible candidate remains eligible"
# A higher new setting must not be lowered by an older override.
OUT="$TMP_ROOT/higher-aged.out"
run_fixture "$OUT" LARGE_TMP_ACTIVE_HOURS=168 AGED_TMP_ACTIVE_HOURS=192 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run --aged
assert_contains "$OUT" "with no activity for 192h" "higher aged setting retained"
# Exercise the real clean path only in the owned synthetic sandbox.
OUT="$TMP_ROOT/clean.out"
run_fixture "$OUT" LARGE_TMP_ACTIVE_HOURS=168 LARGE_TMP_ARCHIVE_RETENTION_HOURS=240 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --aged
if [[ -d "$PRIVATE/pr168-eighty-hours" ]]; then echo "PASS 80h candidate remains at original path"; else echo "FAIL 80h candidate archived early"; FAIL=$((FAIL + 1)); fi
archived="$(/usr/bin/find "$ARCHIVE" -mindepth 2 -maxdepth 2 -type d -name pr240-old-enough -print -quit)"
[[ -n "$archived" && -f "$archived.c14-origin.json" ]]
if python3 - "$archived.c14-origin.json" <<'CHECK'
import json,sys
row=json.load(open(sys.argv[1]))
assert row['recovery_hours'] == 240, row
CHECK
then echo "PASS receipt preserves 240h recovery override"; else echo "FAIL recovery override discarded"; FAIL=$((FAIL + 1)); fi
python3 - "$archived.c14-origin.json" <<'AGE'
import json,sys,time
p=sys.argv[1]; row=json.load(open(p)); row['archived_at']=int(time.time())-80*3600
with open(p,'w') as f: json.dump(row,f)
AGE
for mode in aged large; do
  OUT="$TMP_ROOT/purge-$mode.out"
  run_fixture "$OUT" bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run "--$mode"
  assert_contains "$OUT" "Skipping archive inside its persisted 240h recovery window: $archived" "$mode preserves recovery override after env is removed"
done
# Exercise existing configuration resolution, not only environment overrides.
COPY="$TMP_ROOT/config-repo"
mkdir -p "$COPY/scripts"
for item in "$REPO_ROOT/scripts/"*; do ln -s "$item" "$COPY/scripts/$(basename "$item")"; done
# Copy the entrypoint so its REPO_ROOT resolves the isolated configuration.
rm "$COPY/scripts/cleanup_tmp.sh"
cp "$REPO_ROOT/scripts/cleanup_tmp.sh" "$COPY/scripts/cleanup_tmp.sh"
printf '%s\n' '{"cleanup_thresholds":{"large_tmp_active_hours":168,"large_tmp_archive_retention_hours":240}}' > "$COPY/config.json"
OUT="$TMP_ROOT/config.out"
run_fixture "$OUT" bash "$COPY/scripts/cleanup_tmp.sh" --dry-run --aged
assert_contains "$OUT" "with no activity for 168h" "config activity override retained"
assert_contains "$OUT" "Skipping archive inside its persisted 240h recovery window: $archived" "config recovery override honored"
make_pr_dir "$PRIVATE/pr241-config-old-enough" 18000
OUT="$TMP_ROOT/config-clean.out"
run_fixture "$OUT" bash "$COPY/scripts/cleanup_tmp.sh" --clean --aged
config_archived="$(/usr/bin/find "$ARCHIVE" -mindepth 2 -maxdepth 2 -type d -name pr241-config-old-enough -print -quit)"
[[ -n "$config_archived" && -f "$config_archived.c14-origin.json" ]]
if python3 - "$config_archived.c14-origin.json" <<'CONFIG_CHECK'
import json,sys
row=json.load(open(sys.argv[1]))
assert row['recovery_hours'] == 240, row
CONFIG_CHECK
then echo "PASS config recovery override persisted"; else echo "FAIL config recovery override discarded"; FAIL=$((FAIL + 1)); fi
echo "FAIL=$FAIL"
(( FAIL == 0 ))
