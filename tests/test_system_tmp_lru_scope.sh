#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/system-tmp-lru-test.XXXXXX")"
PRIVATE_TMP="$WORK_ROOT/private-tmp"
OTHER_TMP="$WORK_ROOT/other-tmp"
ARCHIVE="$WORK_ROOT/archive"
TEST_HOME="$WORK_ROOT/home"
mkdir -p "$PRIVATE_TMP" "$OTHER_TMP" "$ARCHIVE" "$TEST_HOME/.disk_magician_locks" "$WORK_ROOT/bin"
chmod 700 "$WORK_ROOT" "$TEST_HOME" "$TEST_HOME/.disk_magician_locks"
cat > "$WORK_ROOT/bin/lsof" <<'LSOF_EOF'
#!/bin/bash
for arg in "$@"; do
  [[ "$arg" == +D ]] && exit 1
done
printf 'p1\nf3\ntREG\nn/usr/bin/other\n'
LSOF_EOF
chmod +x "$WORK_ROOT/bin/lsof"
cat > "$WORK_ROOT/bin/du" <<'DU_EOF'
#!/bin/bash
for arg in "$@"; do candidate="$arg"; done
if [[ "${PARTIAL_SIZE_FIXTURE:-}" == 1 && "$candidate" == */pr1_partial ]]; then
  printf '1\t%s\n' "$candidate"
  exit 1
fi
exec /usr/bin/du "$@"
DU_EOF
chmod +x "$WORK_ROOT/bin/du"
mk_candidate() {
  local name="$1" hours="$2" dir
  dir="$PRIVATE_TMP/$name"
  mkdir -p "$dir"
  printf 'ephemeral fixture\n' > "$dir/payload.txt"
  python3 -c 'import os,sys; stamp=float(sys.argv[1]); [os.utime(p,(stamp,stamp)) for p in sys.argv[2:]]'     "$(( $(date +%s) - hours * 3600 ))" "$dir" "$dir/payload.txt"
}
mk_candidate pr1_big_1 12
mk_candidate pr1_big_2 10
mk_candidate pr1_big_3 8
mk_candidate pr1_recent 3
mkdir -p "$OTHER_TMP/pr1_unrelated"
printf 'unrelated root\n' > "$OTHER_TMP/pr1_unrelated/payload.txt"
python3 -c 'import os,sys; stamp=float(sys.argv[1]); [os.utime(p,(stamp,stamp)) for p in sys.argv[2:]]'   "$(( $(date +%s) - 24 * 3600 ))" "$OTHER_TMP/pr1_unrelated" "$OTHER_TMP/pr1_unrelated/payload.txt"
ENV_ARGS=(
  "DISK_MAGICIAN_SIZE_METHOD=du"
  "DISK_MAGICIAN_LSOF_BIN=$WORK_ROOT/bin/lsof"
  "DISK_MAGICIAN_TEST_CONTEXT=1"
  "DISK_MAGICIAN_TEST_SANDBOX=$WORK_ROOT"
  "DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE=$PRIVATE_TMP"
  "DISK_MAGICIAN_TMP_ROOT_OVERRIDE=$OTHER_TMP"
  "DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE=$OTHER_TMP"
  "DISK_MAGICIAN_ARCHIVE_ROOT=$ARCHIVE"
  "DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS=0"
  "HOME=$TEST_HOME"
  "PATH=$WORK_ROOT/bin:/usr/bin:/bin"
)
OUT="$WORK_ROOT/preview.log"
set +e
env "${ENV_ARGS[@]}" bash "$REPO_ROOT/disk_magician.sh" cleanup-tmp \
  --system-tmp-budget-pct 50 --budget-floor-minutes 360 --dry-run >"$OUT" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then cat "$OUT"; echo "system tmp preview failed rc=$rc" >&2; exit 1; fi
candidates=()
while IFS= read -r candidate; do candidates+=("$candidate"); done < <(
  sed -n 's/.*DRY RUN: would evict (budget): \([^ ]*\).*/\1/p' "$OUT"
)
[[ "${#candidates[@]}" -eq 2 ]] || { cat "$OUT"; echo "expected exactly two oldest candidates" >&2; exit 1; }
[[ "${candidates[0]}" == "$PRIVATE_TMP/pr1_big_1" ]]
[[ "${candidates[1]}" == "$PRIVATE_TMP/pr1_big_2" ]]
if grep -F -e "$OTHER_TMP" "$OUT"; then
  cat "$OUT"
  echo "FAIL: cleanup selected a path outside oldest eligible files" >&2
  exit 1
fi
[[ -z "$(find "$ARCHIVE" -mindepth 1 -print -quit)" ]]
for path in "$PRIVATE_TMP"/pr1_* "$OTHER_TMP/pr1_unrelated"; do [[ -f "$path/payload.txt" ]]; done
if ! env "${ENV_ARGS[@]}" bash "$REPO_ROOT/disk_magician.sh" cleanup-tmp \
  --system-tmp-budget-pct 50 --budget-floor-minutes 360 --clean >"$OUT" 2>&1; then
  cat "$OUT"
  echo "scoped test cleanup failed" >&2
  exit 1
fi
[[ ! -e "$PRIVATE_TMP/pr1_big_1" && ! -e "$PRIVATE_TMP/pr1_big_2" ]]
[[ -f "$PRIVATE_TMP/pr1_big_3/payload.txt" && -f "$PRIVATE_TMP/pr1_recent/payload.txt" ]]
[[ -f "$OTHER_TMP/pr1_unrelated/payload.txt" ]]
[[ -z "$(find "$ARCHIVE" -mindepth 1 -print -quit)" ]]
mk_candidate pr1_partial 24
printf 'old prompt fixture\n' > "$PRIVATE_TMP/agent_prompt_old.txt"
python3 -c 'import os,sys,time; stamp=int(time.time())-25*3600; os.utime(sys.argv[1],(stamp,stamp))' "$PRIVATE_TMP/agent_prompt_old.txt"
env "${ENV_ARGS[@]}" PARTIAL_SIZE_FIXTURE=1 bash "$REPO_ROOT/disk_magician.sh" cleanup-tmp \
  --system-tmp-budget-pct 50 --budget-floor-minutes 360 --dry-run >"$OUT" 2>&1
if ! grep -F "size unknown for $PRIVATE_TMP/pr1_partial" "$OUT" >/dev/null; then
  cat "$OUT"
  exit 1
fi
if ! grep -F "$PRIVATE_TMP/agent_prompt_old.txt" "$OUT" >/dev/null; then
  cat "$OUT"
  echo "regular file did not reach scoped qualification" >&2
  exit 1
fi
if grep -F "would evict (budget): $PRIVATE_TMP/pr1_partial" "$OUT"; then
  echo "partial size was accepted" >&2
  exit 1
fi
for conflict in "--large" "--aged" "--opencode-dylibs" "--budget-gb 1"; do
  set +e
  env "${ENV_ARGS[@]}" bash "$REPO_ROOT/disk_magician.sh" cleanup-tmp \
    --system-tmp-budget-pct 50 --budget-floor-minutes 360 --dry-run $conflict >"$OUT" 2>&1
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { echo "conflicting mode was accepted: $conflict" >&2; exit 1; }
done
for invalid_pct in 0 100 9999999999999999999999999 ""; do
  if env "${ENV_ARGS[@]}" bash "$REPO_ROOT/disk_magician.sh" cleanup-tmp \
    --system-tmp-budget-pct="$invalid_pct" --dry-run >"$OUT" 2>&1; then
    echo "out-of-range system tmp budget was accepted: $invalid_pct" >&2
    exit 1
  fi
done
echo "PASS: tmp scope isolation, oldest-first six-hour preview and sandbox apply, conflicting-mode rejection"
