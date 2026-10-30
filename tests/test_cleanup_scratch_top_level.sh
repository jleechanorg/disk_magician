#!/usr/bin/env bash
# Tests for scripts/cleanup_scratch_top_level.sh (diskm scratch-prune).
#
# Covers every gate in the cleaner's contract: scope/shape, the 48 h recency
# floor, safety_gate, the C14 lease/live-cwd/open-file ordering that makes the
# content override safe, the operator approval flag and its exact scope, the
# per-run cap, and the deletion-log row.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$ROOT/scripts/cleanup_scratch_top_level.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/dm-scratch-prune.XXXXXX")"
trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+ ($2)}"; }
check() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "missing: $2 | got: $(printf '%s' "$3" | tr '\n' ' ' | cut -c1-400)"; }

SANDBOX="$T/sandbox"
SCRATCH_ROOT="$SANDBOX/scratch"
STATE="$T/state"
LOG="$T/deletions.log"
mkdir -p "$SCRATCH_ROOT" "$STATE" "$SANDBOX"
export DISK_MAGICIAN_TEST_CONTEXT=1
export DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX"
export DISK_MAGICIAN_DELETION_LOG="$LOG"
export DISK_MAGICIAN_STATE_DIR="$STATE"
export DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_ROOT"

old_stamp() { python3 -c 'import os,sys,time
root=sys.argv[1]; t=time.time()-int(sys.argv[2])*3600
for dirpath,dirnames,filenames in os.walk(root):
    for name in dirnames+filenames:
        p=os.path.join(dirpath,name)
        try: os.utime(p,(t,t),follow_symlinks=False)
        except OSError: pass
os.utime(root,(t,t))' "$1" "${2:-72}"; }

make_tree() { # <name> <age_hours> [content-file]
  local dir="$SCRATCH_ROOT/$1"
  mkdir -p "$dir"
  printf 'x%.0s' {1..2048} > "$dir/payload.bin"
  [[ -n "${3:-}" ]] && printf 'placeholder\n' > "$dir/$3"
  old_stamp "$dir" "${2:-72}"
  echo "$dir"
}

run() { # run with a clean env so ambient settings cannot leak in
  env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" \
    TMPDIR="$T" \
    DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX" \
    DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_ROOT" \
    DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_DELETION_LOG="$LOG" \
    "${@}"
}
mkdir -p "$T/home"

echo "Test 1: dry-run lists candidates and deletes nothing"
make_tree plain-old >/dev/null
out="$(run bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "dry-run exits 0" || bad "dry-run exits 0" "rc=$rc"
# A synthetic tree has no provenance, so C14 reports a content keep; the dry run
# must surface that verdict (or a would-remove) for every candidate it scans.
if printf '%s' "$out" | grep -qE "^(would-remove|kept:)"; then
  ok "dry-run reports a verdict for the candidate"
else
  bad "dry-run reports a verdict for the candidate" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
fi
check "dry-run names the candidate" "plain-old" "$out"
[[ -d "$SCRATCH_ROOT/plain-old" ]] && ok "dry-run deleted nothing" || bad "dry-run deleted nothing"
[[ ! -s "$LOG" ]] && ok "dry-run wrote no deletion-log row" || bad "dry-run wrote no deletion-log row"

echo "Test 2: --clean without SCRATCH_TOP_LEVEL_APPROVED=1 refuses"
out="$(run bash "$SCRIPT" --clean 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ok "--clean refuses with rc=2" || bad "--clean refuses with rc=2" "rc=$rc"
check "refusal names the approval variable" "SCRATCH_TOP_LEVEL_APPROVED=1" "$out"
[[ -d "$SCRATCH_ROOT/plain-old" ]] && ok "unapproved clean deleted nothing" || bad "unapproved clean deleted nothing"

echo "Test 3: approved clean removes an eligible dir and logs the row"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "approved clean exits 0" || bad "approved clean exits 0" "rc=$rc"
[[ ! -e "$SCRATCH_ROOT/plain-old" ]] && ok "eligible dir removed" || bad "eligible dir removed"
check "removal is reported" "removed:" "$out"
check "deletion log records the removal" "plain-old" "$(cat "$LOG" 2>/dev/null)"
check "deletion log names the cleaner" "scratch-prune" "$(cat "$LOG" 2>/dev/null)"

echo "Test 4: the 48 h floor is enforced and cannot be lowered"
make_tree young-dir 4 >/dev/null
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
check "young dir kept" "kept:recent-activity" "$out"
[[ -d "$SCRATCH_ROOT/young-dir" ]] && ok "young dir preserved" || bad "young dir preserved"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --min-hours 2 2>&1)"
[[ -d "$SCRATCH_ROOT/young-dir" ]] && ok "--min-hours 2 is clamped up to 48 h" || bad "--min-hours 2 is clamped up to 48 h"

echo "Test 5: a live owner lease keeps the dir even with approval"
make_tree live-lease 72 >/dev/null
sleep 300 & lease_pid=$!
env DISK_MAGICIAN_STATE_DIR="$STATE" bash -c '
source "$1/scripts/lib/worktree_lease.sh"
lease_write "$2" "$2" "" scratch-prune-test --owner-pid "$3" >/dev/null' _ "$ROOT" "$SCRATCH_ROOT/live-lease" "$lease_pid"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
kill "$lease_pid" 2>/dev/null || true; wait "$lease_pid" 2>/dev/null || true
check "live lease keeps the candidate" "kept:live-owner" "$out"
[[ -d "$SCRATCH_ROOT/live-lease" ]] && ok "live-lease dir preserved" || bad "live-lease dir preserved"

echo "Test 6: an open file keeps the dir even with approval"
make_tree open-file 72 >/dev/null
( exec 3<"$SCRATCH_ROOT/open-file/payload.bin"; sleep 60 ) & holder=$!
sleep 1
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
check "open file keeps the candidate" "kept:open-file" "$out"
[[ -d "$SCRATCH_ROOT/open-file" ]] && ok "open-file dir preserved" || bad "open-file dir preserved"

echo "Test 7: a content keep needs the approval flag, and only the two named classes are overridden"
make_tree content-keep 72 '.env.example' >/dev/null
out="$(run bash "$SCRIPT" --dry-run 2>&1)"
check "content keep is reported as kept without approval" "kept:unproven-content" "$out"
[[ -d "$SCRATCH_ROOT/content-keep" ]] && ok "unapproved content-keep dir preserved" || bad "unapproved content-keep dir preserved"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
[[ ! -e "$SCRATCH_ROOT/content-keep" ]] && ok "approved override removes the unproven-content tree" || bad "approved override removes the unproven-content tree" "$(printf %s "$out" | tr "\n" " " | cut -c1-300)"
check "the override is recorded in the deletion log" "scratch-prune:kept:unproven-content" "$(cat "$LOG" 2>/dev/null)"

echo "Test 8: other content keeps are never overridden"
make_tree dirty-repo 72 >/dev/null
git -C "$SCRATCH_ROOT/dirty-repo" init -q 2>/dev/null
printf 'change\n' > "$SCRATCH_ROOT/dirty-repo/tracked.txt"
git -C "$SCRATCH_ROOT/dirty-repo" add tracked.txt 2>/dev/null
old_stamp "$SCRATCH_ROOT/dirty-repo" 72
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
[[ -d "$SCRATCH_ROOT/dirty-repo" ]] && ok "a non-listed keep survives the approval flag" || bad "a non-listed keep survives the approval flag"
check "the kept reason is reported" "kept:" "$out"

echo "Test 9: the per-run cap is honoured"
mkdir -p "$T/fakebin"
cat > "$T/fakebin/du" <<'EOF'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="$arg"; done
case "$last" in
  */cap-a|*/cap-b) printf '2097152\t%s\n' "$last"; exit 0 ;;
esac
exec /usr/bin/du "$@"
EOF
chmod +x "$T/fakebin/du"
mkdir -p "$SCRATCH_ROOT/cap-a" "$SCRATCH_ROOT/cap-b"
for d in cap-a cap-b; do printf 'x' > "$SCRATCH_ROOT/$d/blob"; old_stamp "$SCRATCH_ROOT/$d" 72; done
out="$(run env PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --max-gib 3 2>&1)"
check "the cap is reported" "capped: at least one candidate skipped" "$out"
removed_cap=0; kept_cap=0
[[ ! -e "$SCRATCH_ROOT/cap-a" ]] && removed_cap=$((removed_cap+1))
[[ ! -e "$SCRATCH_ROOT/cap-b" ]] && removed_cap=$((removed_cap+1))
[[ -e "$SCRATCH_ROOT/cap-a" ]] && kept_cap=$((kept_cap+1))
[[ -e "$SCRATCH_ROOT/cap-b" ]] && kept_cap=$((kept_cap+1))
(( removed_cap == 1 && kept_cap == 1 )) && ok "exactly one 2 GiB candidate fits a 3 GiB cap" || \
  bad "exactly one 2 GiB candidate fits a 3 GiB cap" "removed=$removed_cap kept=$kept_cap"

echo "Test 10: a synthetic root outside the test sandbox is refused"
out="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" TMPDIR="$T" \
  DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_ROOT" bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ok "root override outside the sandbox is refused" || bad "root override outside the sandbox is refused" "rc=$rc"
check "refusal explains the sandbox requirement" "test sandbox" "$out"

echo "Test 11: root '/' is refused"
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE=/ bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ok "root '/' refused" || bad "root '/' refused" "rc=$rc"

echo "Test 12: a symlinked candidate is never followed"
make_tree link-target 72 >/dev/null
ln -s "$SCRATCH_ROOT/link-target" "$SCRATCH_ROOT/link-candidate"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
check "symlink candidate reported" "kept:symlink" "$out"
[[ -L "$SCRATCH_ROOT/link-candidate" ]] && ok "symlink candidate itself was not followed or unlinked" || \
  bad "symlink candidate itself was not followed or unlinked"
# The target is an independent, eligible candidate: its own evaluation removes
# it. What matters here is that the symlink never made it removable.
[[ -L "$SCRATCH_ROOT/link-candidate" && ! -e "$SCRATCH_ROOT/link-target" ]] && ok "target was only taken as its own candidate" || \
  bad "target was only taken as its own candidate"

echo
echo "test_cleanup_scratch_top_level: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
