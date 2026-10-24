#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${TMPDIR:?set TMPDIR to an approved writable scratch directory}"
TMP_ROOT="$(mktemp -d "$TMPDIR/disk-magician-aged-tmp.XXXXXX")"
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
if [[ "$*" == "+w -n -P -F fnt" ]]; then printf "p123\nfcwd\nn/\n"; exit 0; fi
exit 99
MOCK
chmod +x "$TMP_ROOT/bin/lsof"
OUT="$TMP_ROOT/out.txt"
if env -i HOME="$HOME_FIX" TMPDIR="$TMP_ROOT" PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
  DISK_MAGICIAN_LSOF_BIN="$TMP_ROOT/bin/lsof" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PRIVATE" \
  DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$ORDINARY" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE" LARGE_TMP_APPROVED=1 AGED_TMP_ACTIVE_HOURS=1 PROTECTED_ROOT_CHILD_MIN_AGE_HOURS=96 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run --aged >"$OUT" 2>&1; then
  :
else
  rc=$?; cat "$OUT" >&2; echo "aged cleanup dry-run failed rc=$rc" >&2; exit "$rc"
fi
cat "$OUT"
grep -Fq "Scanning $PRIVATE for C14-proven dirs of any size with no activity for 72h" "$OUT"
grep -Fq "Skipping recently active dir (mtime/ctime within 72h): $PRIVATE/pr123-fresh" "$OUT"
grep -Fq "Skipping recently active dir (mtime/ctime within 72h): $PRIVATE/pr789-nested-active" "$OUT"
grep -Fq "DRY RUN: would archive: $PRIVATE/pr456-aged" "$OUT"
grep -Fq "Scanning $PRIVATE for C14-proven dirs of any size with no activity for 72h" "$OUT"
grep -Fq "Skipping recently active protected-root child (mtime/ctime within 96h): $PRIVATE/worldarchitect.ai/old-protected-child" "$OUT"
grep -Fq "DRY RUN: would remove C14 agent prompt (>72h): $PRIVATE/agent_prompt_old.txt" "$OUT"
! grep -Fq "agent_prompt_fresh.txt" "$OUT"
if grep -Fq "Scanning $ORDINARY for stale" "$OUT"; then
  echo "aged-only mode unexpectedly ran the ordinary tmp scan" >&2; cat "$OUT" >&2; exit 1
fi
[[ -d "$PRIVATE/pr123-fresh" && -d "$PRIVATE/pr456-aged" && -d "$PRIVATE/pr789-nested-active" ]]

# Exercise the real sandboxed clean path: eligible old candidates are archived
# with their C14 origin receipt, the old C14 prompt is removed, and fresh data
# remains in place.
CLEAN_OUT="$TMP_ROOT/clean.out"
if env -i HOME="$HOME_FIX" TMPDIR="$TMP_ROOT" PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
  DISK_MAGICIAN_LSOF_BIN="$TMP_ROOT/bin/lsof" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PRIVATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$ORDINARY" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE" LARGE_TMP_APPROVED=1 AGED_TMP_ACTIVE_HOURS=1 \
  PROTECTED_ROOT_CHILD_MIN_AGE_HOURS=96 bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --aged >"$CLEAN_OUT" 2>&1; then
  :
else
  rc=$?; cat "$CLEAN_OUT" >&2; echo "aged cleanup clean-mode failed rc=$rc" >&2; exit "$rc"
fi
cat "$CLEAN_OUT"
[[ ! -e "$PRIVATE/pr456-aged" ]]
[[ -d "$PRIVATE/pr123-fresh" && -d "$PRIVATE/pr789-nested-active" ]]
[[ ! -e "$PRIVATE/agent_prompt_old.txt" ]]
[[ -f "$PRIVATE/agent_prompt_fresh.txt" ]]
archived_candidate="$(/usr/bin/find "$ARCHIVE" -mindepth 2 -maxdepth 2 -type d -name pr456-aged -print -quit)"
[[ -n "$archived_candidate" && -f "$archived_candidate/payload.txt" ]]
[[ -f "$archived_candidate.c14-origin.json" ]]
python3 - "$archived_candidate.c14-origin.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    row = json.load(f)
assert row.get("recovery_hours") == 72, row
PY
grep -Fq "agent_prompt_fresh.txt" "$CLEAN_OUT" && { echo "fresh prompt unexpectedly entered clean candidate output" >&2; exit 1; }

# Ordinary --large runs must honor the aged mode's persisted recovery floor,
# even when the archived source's own mtime is already far older than 24h.
ORDINARY_OUT="$TMP_ROOT/ordinary-purge.out"
if env -i HOME="$HOME_FIX" TMPDIR="$TMP_ROOT" PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
  DISK_MAGICIAN_LSOF_BIN="$TMP_ROOT/bin/lsof" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PRIVATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$ORDINARY" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE" LARGE_TMP_APPROVED=1 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run --large >"$ORDINARY_OUT" 2>&1; then
  :
else
  rc=$?; cat "$ORDINARY_OUT" >&2; echo "ordinary purge dry-run failed rc=$rc" >&2; exit "$rc"
fi
cat "$ORDINARY_OUT"
grep -Fq "Skipping archive inside its persisted 72h recovery window: $archived_candidate" "$ORDINARY_OUT"

# Once the receipt's archive age clears 72h, the ordinary purge path can
# continue to the normal C14 and activity gates.
python3 - "$archived_candidate.c14-origin.json" <<'PY'
import json, sys, time
path=sys.argv[1]
with open(path, encoding="utf-8") as f: row=json.load(f)
row["archived_at"] = int(time.time()) - 73*3600
with open(path, "w", encoding="utf-8") as f: json.dump(row, f)
PY
python3 - "$archived_candidate/payload.txt" <<'PY'
import os, sys, time
recent = time.time() - 3600
os.utime(sys.argv[1], (recent, recent))
PY
RECENT_OUT="$TMP_ROOT/recent-archive-purge.out"
if env -i HOME="$HOME_FIX" TMPDIR="$TMP_ROOT" PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
  DISK_MAGICIAN_LSOF_BIN="$TMP_ROOT/bin/lsof" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PRIVATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$ORDINARY" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE" LARGE_TMP_APPROVED=1 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run --large >"$RECENT_OUT" 2>&1; then
  :
else
  rc=$?; cat "$RECENT_OUT" >&2; echo "recent archive activity check failed rc=$rc" >&2; exit "$rc"
fi
cat "$RECENT_OUT"
grep -Fq "Skipping recently-active aged archive: $archived_candidate" "$RECENT_OUT"
python3 - "$archived_candidate/payload.txt" <<'PY'
import os, sys, time
old = time.time() - 73*3600
os.utime(sys.argv[1], (old, old))
PY
LATER_OUT="$TMP_ROOT/later-purge.out"
if env -i HOME="$HOME_FIX" TMPDIR="$TMP_ROOT" PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
  DISK_MAGICIAN_LSOF_BIN="$TMP_ROOT/bin/lsof" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PRIVATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$ORDINARY" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE" LARGE_TMP_APPROVED=1 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --dry-run --large >"$LATER_OUT" 2>&1; then
  :
else
  rc=$?; cat "$LATER_OUT" >&2; echo "ordinary post-recovery dry-run failed rc=$rc" >&2; exit "$rc"
fi
cat "$LATER_OUT"
grep -Fq "would purge aged archive (>24h): $archived_candidate" "$LATER_OUT"

# The same ordinary cleanup is authorized to purge once recovery elapsed; run
# the real quarantine path and assert the archive payload is gone.
PURGE_OUT="$TMP_ROOT/purge.out"
if env -i HOME="$HOME_FIX" TMPDIR="$TMP_ROOT" PATH="$TMP_ROOT/bin:/usr/bin:/bin" \
  DISK_MAGICIAN_LSOF_BIN="$TMP_ROOT/bin/lsof" DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$TMP_ROOT" \
  DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PRIVATE" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$ORDINARY" \
  DISK_MAGICIAN_ARCHIVE_ROOT="$ARCHIVE" LARGE_TMP_APPROVED=1 \
  bash "$REPO_ROOT/scripts/cleanup_tmp.sh" --clean --large >"$PURGE_OUT" 2>&1; then
  :
else
  rc=$?; cat "$PURGE_OUT" >&2; echo "ordinary post-recovery purge failed rc=$rc" >&2; exit "$rc"
fi
cat "$PURGE_OUT"
[[ ! -e "$archived_candidate" ]]
echo "PASS 72h age gate, nested activity, C14 clean archive+receipt, persistent recovery floor across ordinary purge, post-window real purge, prompt removal, fresh prompt preservation, and aged-only scan"
