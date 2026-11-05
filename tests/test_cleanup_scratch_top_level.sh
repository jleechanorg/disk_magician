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
REAL_PYTHON3="$(command -v python3)"
T="$(mktemp -d "${TMPDIR:-/tmp}/dm-scratch-prune.XXXXXX")"
trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+ ($2)}"; }
check() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "missing: $2 | got: $(printf '%s' "$3" | tr '\n' ' ' | cut -c1-400)"; }
assert_eq() { [[ "$1" == "$2" ]] && ok "$3 (= $2)" || bad "$3" "expected '$2', got '$1'"; }

SANDBOX="$T/sandbox"
SCRATCH_ROOT="$SANDBOX/scratch"
STATE="$T/state"
LOG="$T/deletions.log"
VOLUME_CONFIG="$T/config.json"
mkdir -p "$SCRATCH_ROOT" "$STATE" "$SANDBOX"
export DISK_MAGICIAN_TEST_CONTEXT=1
export DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX"
export DISK_MAGICIAN_DELETION_LOG="$LOG"
export DISK_MAGICIAN_STATE_DIR="$STATE"
export DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_ROOT"

make_unknown_file() { # <name> <age_hours> — a direct-child file E8 never classifies
  printf 'x%.0s' {1..2048} > "$SCRATCH_ROOT/$1"
  old_stamp "$SCRATCH_ROOT/$1" "${2:-25}"
}

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

make_managed_tree() { # <name> <age_hours> [content-file]
  local dir="$SCRATCH_ROOT/worldai_frontend/build/$1"
  mkdir -p "$dir"
  printf 'x%.0s' {1..2048} > "$dir/payload.bin"
  [[ -n "${3:-}" ]] && printf 'placeholder\n' > "$dir/$3"
  old_stamp "$dir" "${2:-72}"
  echo "$dir"
}

run() { # run with a clean env so ambient settings cannot leak in
  env -i HOME="$T/home" PATH="${RUN_PATH:-/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin}" \
    TMPDIR="$T" \
    DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX" \
    DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_ROOT" \
    DISK_MAGICIAN_STATE_DIR="$DISK_MAGICIAN_STATE_DIR" DISK_MAGICIAN_DELETION_LOG="$LOG" \
    DISK_MAGICIAN_CONFIG="${DISK_MAGICIAN_CONFIG:-}" \
    DISK_MAGICIAN_DISKUTIL_BIN="${DISK_MAGICIAN_DISKUTIL_BIN:-}" \
    FAKE_DISKUTIL_STATE="${FAKE_DISKUTIL_STATE:-}" FAKE_DISKUTIL_CALLS="${FAKE_DISKUTIL_CALLS:-}" \
    FAKE_DISKUTIL_MOUNTPOINT="${FAKE_DISKUTIL_MOUNTPOINT:-}" \
    "${@}"
}
mkdir -p "$T/home"
chmod 700 "$T/home"

# Each test gets its own Scratch root: the cleaner rescans every candidate on
# each run, so sharing one root makes the suite quadratic and risks the runner's
# per-suite time cap under concurrency.
ROOT_SEQ=0
use_root() {
  ROOT_SEQ=$(( ROOT_SEQ + 1 ))
  SANDBOX="$T/sandbox/r${ROOT_SEQ}"
  SCRATCH_ROOT="$SANDBOX/scratch"
  mkdir -p "$SCRATCH_ROOT"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  SCRATCH_ROOT="$(cd "$SCRATCH_ROOT" && pwd -P)"
  python3 - "$VOLUME_CONFIG" "$SCRATCH_ROOT" <<'PY'
import json,sys
json.dump({"volumes":{"swap_headroom_gb":40,"alarm_floor_gb":20,"encryption":"none","encryption_acknowledged_at":"2026-10-25T00:00:00Z","classes":{"scratch":{"name":"diskm-scratch","quota_gb":30,"mountpoint":sys.argv[2]}}}}, open(sys.argv[1],"w"))
PY
}
register_test_volume() {
  DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG"
  DISK_MAGICIAN_STATE_DIR="$T/state/registered-$ROOT_SEQ"
  DISK_MAGICIAN_DISKUTIL_BIN="$ROOT/tests/lib/fake_diskutil.py"
  FAKE_DISKUTIL_STATE="$T/diskutil-$ROOT_SEQ.json"
  FAKE_DISKUTIL_CALLS="$T/diskutil-$ROOT_SEQ.calls"
  FAKE_DISKUTIL_MOUNTPOINT="$SCRATCH_ROOT"
  export DISK_MAGICIAN_STATE_DIR DISK_MAGICIAN_CONFIG DISK_MAGICIAN_DISKUTIL_BIN
  export FAKE_DISKUTIL_STATE FAKE_DISKUTIL_CALLS FAKE_DISKUTIL_MOUNTPOINT
  mkdir -p "$DISK_MAGICIAN_STATE_DIR"
  python3 - "$FAKE_DISKUTIL_STATE" <<'PY'
import json,sys
state={"container":{"ref":"disk3","uuid":"CONTAINER-UUID","ceiling":1000*2**30,"free":100*2**30},"volumes":[{"uuid":"DATA-UUID","name":"Data","ref":"disk3s1","device":"disk3s1","used":100*2**30,"quota":0,"roles":["Data"],"mountpoint":"/System/Volumes/Data"},{"uuid":"SYSTEM-UUID","name":"System","ref":"disk3s5","device":"disk3s5","used":10*2**30,"quota":0,"roles":["System"],"mountpoint":"/"},{"uuid":"VM-UUID","name":"VM","ref":"disk3s6","device":"disk3s6","used":10*2**30,"quota":0,"roles":["VM"],"mountpoint":"/System/Volumes/VM"}]}
json.dump(state,open(sys.argv[1],"w"))
PY
  # `volume.create_cmd` refuses to register an already-existing mountpoint;
  # the fake diskutil creates this exact empty fixture root during registration.
  rmdir "$SCRATCH_ROOT"
  python3 -c 'import sys; from unittest.mock import patch; sys.path.insert(0, sys.argv[1]); import volume; patch.object(sys, "platform", "linux").start(); raise SystemExit(volume.create_cmd("scratch", True))' "$ROOT/scripts"
}
use_root

if [[ -z "${SCRATCH_PRUNE_TEST_FILTER:-}" || "${SCRATCH_PRUNE_TEST_FILTER:-}" == lru-probe-contract ]]; then
  echo "Test: manual LRU skips sub-threshold probes but keeps fresh usage identity"
  LRU_DISKM="$T/lru-diskm"
  cat >"$LRU_DISKM" <<'FAKE_LRU_DISKM'
#!/usr/bin/env bash
[[ "$1 $2" == "volume status" ]] || exit 2
calls_file="${FAKE_STATUS_CALLS:?}"
count=0
[[ -f "$calls_file" ]] && count="$(wc -l <"$calls_file")"
count=$((count + 1))
printf '%s\n' "$count" >>"$calls_file"
[[ "${FAKE_STATUS_MODE:-}" == usage-unknown && "$count" -ge 2 ]] && exit 3
used_kb="$(du -sk "$FAKE_SCRATCH_ROOT" | awk '{print $1}')"
quota_kb=10240
if [[ "${FAKE_STATUS_MODE:-}" == quota-change && "$count" -ge 2 ]]; then
  quota_kb=10241
fi
printf '{"volumes":[{"class":"scratch","allocated_bytes":%s,"quota_bytes":%s}]}\n' \
  "$((used_kb * 1024))" "$((quota_kb * 1024))"
FAKE_LRU_DISKM
  chmod +x "$LRU_DISKM"
  lru_run() {
    env -i HOME="$T/home" PATH="${RUN_PATH:-/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin}" \
      TMPDIR="$T" \
      DISK_MAGICIAN_TEST_CONTEXT=1 DISK_MAGICIAN_TEST_SANDBOX="$SANDBOX" \
      DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_ROOT" \
      DISK_MAGICIAN_STATE_DIR="$STATE" DISK_MAGICIAN_DELETION_LOG="$LOG" \
      DISK_MAGICIAN_DISKM_BIN="$LRU_DISKM" FAKE_SCRATCH_ROOT="$SCRATCH_ROOT" \
      SCRATCH_TOP_LEVEL_APPROVED=1 \
      FAKE_STATUS_CALLS="$T/lru-status.calls" FAKE_STATUS_MODE="${FAKE_STATUS_MODE:-}" DISK_MAGICIAN_SCRATCH_MIN_KB=512 "$@"
  }
  use_root
  make_tree lru-small 14 >/dev/null
  mkdir -p "$SCRATCH_ROOT/lru-large"
  head -c 1048576 /dev/zero >"$SCRATCH_ROOT/lru-large/payload.bin"
  old_stamp "$SCRATCH_ROOT/lru-large" 13
  make_tree lru-small-after 12 >/dev/null
  : >"$T/lru-status.calls"
  out="$(lru_run bash "$SCRIPT" --clean --budget-pct 5 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "LRU threshold regression exits 0" || bad "LRU threshold regression exits 0" "rc=$rc"
  [[ -d "$SCRATCH_ROOT/lru-small" && -d "$SCRATCH_ROOT/lru-small-after" ]] && ok "sub-threshold candidate is preserved" || bad "sub-threshold candidate is preserved"
  [[ ! -e "$SCRATCH_ROOT/lru-large" ]] && ok "eligible candidate is evicted" || bad "eligible candidate is evicted"
  check "LRU target stop is retained" "lru: stop=target-reached evicted=1" "$out"
  status_calls="$(wc -l <"$T/lru-status.calls")"
  [[ "$status_calls" -eq 3 ]] && ok "only initial, eligible, and final usage probes run" || \
    bad "only initial, eligible, and final usage probes run" "status_calls=$status_calls"

  for mode in quota-change usage-unknown; do
    use_root
    mkdir -p "$SCRATCH_ROOT/lru-identity"
    head -c 1048576 /dev/zero >"$SCRATCH_ROOT/lru-identity/payload.bin"
    old_stamp "$SCRATCH_ROOT/lru-identity" 13
    : >"$T/lru-status.calls"
    out="$(FAKE_STATUS_MODE="$mode" lru_run bash "$SCRIPT" --clean --budget-pct 5 2>&1)"; rc=$?
    [[ "$rc" == 75 ]] && ok "usage identity failure ($mode) fails closed" || bad "usage identity failure ($mode) fails closed" "rc=$rc"
    [[ -e "$SCRATCH_ROOT/lru-identity" ]] && ok "candidate survives usage identity failure ($mode)" || bad "candidate survives usage identity failure ($mode)"
    check "usage identity failure ($mode) is reported" "skipped:measurement-unavailable" "$out"
  done
  if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" == lru-probe-contract ]]; then
    echo "test_cleanup_scratch_top_level (lru-probe-contract): $PASS passed, $FAIL failed"
    [[ "$FAIL" == 0 ]]
    exit $?
  fi
fi

if [[ -z "${SCRATCH_PRUNE_TEST_FILTER:-}" || "${SCRATCH_PRUNE_TEST_FILTER:-}" == numeric-secret-contract ]]; then
  echo "Test: numeric manual floor never bypasses secret-like repository provenance"
  for pushed in no yes; do
    use_root
    candidate="$SCRATCH_ROOT/secret-repo-$pushed"
    mkdir -p "$candidate/repo"
    printf 'fixture-only secret marker\n' >"$candidate/.env"
    git init -q --bare "$T/remote-$ROOT_SEQ.git"
    git -C "$candidate/repo" init -q
    printf 'base\n' >"$candidate/repo/payload"
    git -C "$candidate/repo" add payload
    git -C "$candidate/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm base
    git -C "$candidate/repo" remote add origin "$T/remote-$ROOT_SEQ.git"
    git -C "$candidate/repo" push -q origin HEAD
    printf 'must preserve unpushed data\n' >>"$candidate/repo/payload"
    git -C "$candidate/repo" add payload
    git -C "$candidate/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm candidate
    [[ "$pushed" == no ]] || git -C "$candidate/repo" push -q origin HEAD
    # Use the same released producer metadata fixture as test_artifact_verdict.sh.
    run bash -c 'source "$1/scripts/lib/worktree_lease.sh"
f="$(lease_path_for "$2")"; gd="$(git -C "$2" rev-parse --absolute-git-dir)"
mkdir -p "${f%/*}"
printf "{\"path\":\"%s\",\"owner\":{\"pid\":1},\"released_at\":1,\"git_meta\":%s}\n" "$2" "$(python3 "$1/scripts/c14_probe.py" gitmeta "$gd")" >"$f"' _ "$ROOT" "$candidate/repo"
    old_stamp "$candidate" 13
    initial="$(run bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; artifact_removal_verdict "$2"' _ "$ROOT" "$candidate")"
    assert_eq "$initial" kept:secret-like "fixture reaches the real secret-like C14 gate ($pushed)"
    provenance="$(run bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; c14_repos_ok "$2"' _ "$ROOT" "$candidate")"
    if [[ "$pushed" == no ]]; then expected=kept:not-pushed; else expected=ok; fi
    assert_eq "$provenance" "$expected" "fixture has expected repository provenance ($pushed)"
    old_stamp "$candidate" 13  # Git provenance probes refresh metadata mtimes.
    preview="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 DISK_MAGICIAN_SCRATCH_FLOOR_HOURS=12 bash "$SCRIPT" --dry-run 2>&1)"
    old_stamp "$candidate" 13
    out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 DISK_MAGICIAN_SCRATCH_FLOOR_HOURS=12 bash "$SCRIPT" --clean 2>&1)"
    if [[ "$pushed" == no ]]; then
      check "numeric-floor preview preserves unpushed secret-like repository" "kept:not-pushed $candidate" "$preview"
      check "numeric-floor clean refuses unpushed secret-like repository" "kept:not-pushed $candidate" "$out"
      [[ -f "$candidate/repo/payload" ]] && grep -qF 'must preserve unpushed data' "$candidate/repo/payload" && ok "unpushed payload survives" || bad "unpushed payload survives"
      if grep -Fq "$candidate" "$LOG" 2>/dev/null; then bad "no deletion record for retained repository"; else ok "no deletion record for retained repository"; fi
    else
      check "pushed control is eligible in preview" "would-remove:kept:secret-like $candidate" "$preview"
      [[ ! -e "$candidate" ]] && ok "pushed control remains removable with explicit approval" || bad "pushed control remains removable with explicit approval" "$out"
    fi
  done
  if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" == numeric-secret-contract ]]; then
    echo "test_cleanup_scratch_top_level (numeric-secret-contract): $PASS passed, $FAIL failed"
    [[ "$FAIL" == 0 ]]
    exit $?
  fi
fi

if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" != 24h-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != cursor-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != unknown-deadline-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != discovery-cursor-contract ]]; then
# Earlier numeric-secret contract cases include a pushed control that is
# correctly removed and logged; start this independent suite with a fresh log.
: > "$LOG"
echo "Test 1: dry-run lists candidates and deletes nothing"
use_root
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
fi

if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" != cursor-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != unknown-deadline-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != discovery-cursor-contract ]]; then
echo "Test 4: automatic mode uses a 24 h default and does not bypass C14 safety"
use_root
register_test_volume
make_tree unknown-25h 25 >/dev/null
make_managed_tree recent-23h 23 >/dev/null
make_managed_tree eligible-25h 25 >/dev/null
make_managed_tree secret-25h 25 'placeholder.pem' >/dev/null
mkdir -p "$SCRATCH_ROOT/worldai_frontend/build/dirty-25h"
git -C "$SCRATCH_ROOT/worldai_frontend/build/dirty-25h" init -q 2>/dev/null
printf 'change\n' > "$SCRATCH_ROOT/worldai_frontend/build/dirty-25h/tracked.txt"
git -C "$SCRATCH_ROOT/worldai_frontend/build/dirty-25h" add tracked.txt 2>/dev/null
old_stamp "$SCRATCH_ROOT/worldai_frontend/build/dirty-25h" 25
assert_eq "$(run env DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; artifact_removal_verdict "$2" --kind ephemeral' _ "$ROOT" "$SCRATCH_ROOT/worldai_frontend/build/eligible-25h")" remove "C14 accepts a known Scratch build artifact after 24h"
assert_eq "$(run env DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; artifact_removal_verdict "$2" --kind ephemeral' _ "$ROOT" "$SCRATCH_ROOT/worldai_frontend/build/recent-23h")" kept:recent-activity "C14 preserves a known Scratch build artifact before 24h"
preview="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 DISK_MAGICIAN_SCRATCH_MIN_KB=1048576 bash "$SCRIPT" --dry-run 2>&1)"
check "automatic preview marks the 25h managed artifact removable" "would-remove:remove $SCRATCH_ROOT/worldai_frontend/build/eligible-25h" "$preview"
check "automatic preview keeps the 23h managed artifact" "kept:recent-activity $SCRATCH_ROOT/worldai_frontend/build/recent-23h" "$preview"
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 DISK_MAGICIAN_SCRATCH_MIN_KB=1048576 bash "$SCRIPT" --clean 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "automatic cleanup completes without override approval" || bad "automatic cleanup completes without override approval" "rc=$rc"
[[ -d "$SCRATCH_ROOT/worldai_frontend/build/recent-23h" ]] && ok "23h candidate preserved by the 24h default" || bad "23h candidate preserved by the 24h default"
[[ ! -e "$SCRATCH_ROOT/worldai_frontend/build/eligible-25h" ]] && ok "25h registered ephemeral candidate removed through C14" || bad "25h registered ephemeral candidate removed through C14" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
[[ -e "$SCRATCH_ROOT/worldai_frontend/build/secret-25h/placeholder.pem" ]] && ok "secret-like content remains protected in automatic mode" || bad "secret-like content remains protected in automatic mode"
[[ -e "$SCRATCH_ROOT/worldai_frontend/build/dirty-25h/.git" ]] && ok "dirty repository remains protected in automatic mode" || bad "dirty repository remains protected in automatic mode"
# E8 (artifact_verdict.sh:189-197) declares a direct child of the registered
# scratch volume ephemeral at 1440 min whatever its name, so an aged unknown
# top-level tree is now removable in automatic mode. Every other gate still ran.
[[ ! -e "$SCRATCH_ROOT/unknown-25h" ]] && ok "E8 removes an aged unknown direct volume child" || bad "E8 removes an aged unknown direct volume child" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"

echo "Test 4c: E8 declares an arbitrary direct child of the registered volume ephemeral at 24h"
use_root
register_test_volume
E8_ROOT="$SCRATCH_ROOT"
make_tree e8-unleased-26h 26 >/dev/null
mkdir -p "$E8_ROOT/e8-unleased-26h/nested"; old_stamp "$E8_ROOT/e8-unleased-26h" 26
make_tree e8-recent-23h 23 >/dev/null
make_tree e8-secret-26h 26 'placeholder.pem' >/dev/null
make_tree e8-live-cwd-26h 26 >/dev/null
make_tree e8-leased-26h 26 >/dev/null
mkdir -p "$E8_ROOT/.dot-26h"; old_stamp "$E8_ROOT/.dot-26h" 26
mkdir -p "$E8_ROOT/worldai_frontend/build/e2-probe"; old_stamp "$E8_ROOT/worldai_frontend/build/e2-probe" 26
# A real repository holding a commit no remote advertises: unpushed work.
mkdir -p "$E8_ROOT/e8-unpushed-26h"
git -C "$E8_ROOT/e8-unpushed-26h" init -q 2>/dev/null
printf 'work\n' > "$E8_ROOT/e8-unpushed-26h/tracked.txt"
git -C "$E8_ROOT/e8-unpushed-26h" add tracked.txt 2>/dev/null
git -C "$E8_ROOT/e8-unpushed-26h" -c user.email=t@t -c user.name=t commit -qm work 2>/dev/null
old_stamp "$E8_ROOT/e8-unpushed-26h" 26
# The symlink target is a plain tree: a target holding .git would match the
# pre-existing <name>-holds-.git volume row and prove nothing about E8.
make_tree e8-symlink-target-26h 26 >/dev/null
ln -s "$E8_ROOT/e8-symlink-target-26h" "$E8_ROOT/e8-link-26h"
sleep 300 & e8_lease_pid=$!
(cd "$E8_ROOT/e8-live-cwd-26h" && exec sleep 300) & e8_cwd_pid=$!
env DISK_MAGICIAN_STATE_DIR="$DISK_MAGICIAN_STATE_DIR" bash -c '
source "$1/scripts/lib/worktree_lease.sh"
lease_write "$2" "$2" "" scratch-prune-test --owner-pid "$3" >/dev/null' _ "$ROOT" "$E8_ROOT/e8-leased-26h" "$e8_lease_pid"
eph_retention() { run env DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; c14_ephemeral_retention "$2" 2>/dev/null' _ "$ROOT" "$1"; }
assert_eq "$(eph_retention "$E8_ROOT/e8-unleased-26h")" 1440 "E8 proves an arbitrary volume-child name"
assert_eq "$(eph_retention "$E8_ROOT/e8-unleased-26h/nested")" "" "E8 stays top-level only"
assert_eq "$(eph_retention "$E8_ROOT/.dot-26h")" "" "E8 never covers a dot entry"
assert_eq "$(eph_retention "$E8_ROOT/e8-link-26h")" "" "E8 never answers for a symlink"
assert_eq "$(eph_retention "$E8_ROOT/worldai_frontend/build/e2-probe")" 1440 "the <name>/build/<name> row still answers 1440"
preview="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 bash "$SCRIPT" --dry-run 2>&1)"
check "automatic preview marks the unleased E8 candidate removable" "would-remove:remove $E8_ROOT/e8-unleased-26h" "$preview"
check "automatic preview keeps the under-24h E8 candidate" "kept:recent-activity $E8_ROOT/e8-recent-23h" "$preview"
check "automatic preview keeps the secret-like E8 candidate" "kept:secret-like $E8_ROOT/e8-secret-26h" "$preview"
check "automatic preview keeps the live-cwd E8 candidate" "kept:live-cwd $E8_ROOT/e8-live-cwd-26h" "$preview"
check "automatic preview keeps the leased E8 candidate" "kept:live-owner $E8_ROOT/e8-leased-26h" "$preview"
check "automatic preview keeps the symlinked entry as unproven" "kept:unproven-content $E8_ROOT/e8-link-26h" "$preview"
if printf '%s\n' "$preview" | grep -qE "^would-remove:[^ ]* $E8_ROOT/e8-unpushed-26h$"; then
  bad "the unpushed repository is never advertised for removal" "$(printf '%s' "$preview" | grep -F "e8-unpushed-26h" | tr '\n' ' ' | cut -c1-200)"
else
  ok "the unpushed repository is never advertised for removal"
fi
check "the unpushed repository keeps through the repository gate, not the class row" "kept:not-pushed $E8_ROOT/e8-unpushed-26h" "$preview"
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 bash "$SCRIPT" --clean 2>&1)"; rc=$?
kill "$e8_lease_pid" "$e8_cwd_pid" 2>/dev/null || true; wait "$e8_lease_pid" "$e8_cwd_pid" 2>/dev/null || true
[[ "$rc" == 0 ]] && ok "automatic E8 cleanup exits 0" || bad "automatic E8 cleanup exits 0" "rc=$rc"
[[ ! -e "$E8_ROOT/e8-unleased-26h" ]] && ok "an unleased dormant volume child is reclaimed" || bad "an unleased dormant volume child is reclaimed" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
[[ -e "$E8_ROOT/e8-recent-23h" ]] && ok "the 24h floor is still honoured by default" || bad "the 24h floor is still honoured by default"
[[ -e "$E8_ROOT/e8-leased-26h" ]] && ok "a leased volume child is preserved" || bad "a leased volume child is preserved"
[[ -e "$E8_ROOT/e8-live-cwd-26h" ]] && ok "a live-cwd volume child is preserved" || bad "a live-cwd volume child is preserved"
[[ -e "$E8_ROOT/e8-unpushed-26h/tracked.txt" ]] && ok "a volume child holding unpushed commits is preserved" || bad "a volume child holding unpushed commits is preserved"
[[ -e "$E8_ROOT/e8-secret-26h/placeholder.pem" ]] && ok "a secret-like volume child is preserved" || bad "a secret-like volume child is preserved"
[[ -L "$E8_ROOT/e8-link-26h" ]] && ok "a symlinked top-level entry is never followed or reclaimed" || bad "a symlinked top-level entry is never followed or reclaimed"
fi

if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" != unknown-deadline-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != discovery-cursor-contract ]]; then
echo "Test 4b: a deadline deferral preserves the exact candidate cursor for the next scheduled pass"
use_root
register_test_volume
make_managed_tree resume-25h 25 >/dev/null
CURSOR="$T/scratch-prune.cursor"
EXPIRED_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()-1)')"
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$EXPIRED_DEADLINE" --cursor "$CURSOR" 2>&1)"
[[ -d "$SCRATCH_ROOT/worldai_frontend/build/resume-25h" ]] && ok "expired deadline does not delete the pending candidate" || bad "expired deadline does not delete the pending candidate"
if [[ -f "$CURSOR" ]] && python3 - "$CURSOR" "$SCRATCH_ROOT/worldai_frontend" <<'PY'
import json,sys
cursor=json.load(open(sys.argv[1])); assert cursor["schema"] == 1
assert 0 <= cursor["next_index"] < len(cursor["items"])
assert cursor["items"][cursor["next_index"]] == sys.argv[2]
PY
then ok "deadline deferral persists the exact resume item"; else bad "deadline deferral persists the exact resume item"; fi
FUTURE_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()+60)')"
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$FUTURE_DEADLINE" --cursor "$CURSOR" 2>&1)"
[[ ! -e "$SCRATCH_ROOT/worldai_frontend/build/resume-25h" ]] && ok "the next scheduled pass resumes and removes the eligible item" || bad "the next scheduled pass resumes and removes the eligible item" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
fi
if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" == 24h-contract || "${SCRATCH_PRUNE_TEST_FILTER:-}" == cursor-contract ]]; then
  echo "test_cleanup_scratch_top_level (${SCRATCH_PRUNE_TEST_FILTER}): $PASS passed, $FAIL failed"
  [[ "$FAIL" == 0 ]]
  exit $?
fi

if [[ -z "${SCRATCH_PRUNE_TEST_FILTER:-}" || "${SCRATCH_PRUNE_TEST_FILTER:-}" == discovery-cursor-contract ]]; then
  echo "Test: discovery failure on the resume item completes its keep and reaches the next eligible child"
  use_root
  register_test_volume
  make_tree discovery-failed 2880 >/dev/null
  make_tree isolated-discovery-eligible 25 >/dev/null
  make_managed_tree isolated-discovery-recent 1 >/dev/null
  discovery_eligible="$SCRATCH_ROOT/isolated-discovery-eligible"
  discovery_recent="$SCRATCH_ROOT/worldai_frontend/build/isolated-discovery-recent"
  [[ -d "$discovery_eligible" ]] && ok "discovery eligible fixture exists before injection" || bad "discovery eligible fixture exists before injection"
  [[ -d "$discovery_recent" ]] && ok "fresh sibling fixture exists before injection" || bad "fresh sibling fixture exists before injection"
  discovery_verdict="$(run env DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; artifact_removal_verdict "$2" --kind ephemeral' _ "$ROOT" "$discovery_eligible")"
  assert_eq "$discovery_verdict" remove "discovery eligible fixture is independently C14-removable"
  SHIM="$T/discovery-shim"; mkdir -p "$SHIM"
  REAL_PYTHON="$(command -v python3)"
  cat >"$SHIM/python3" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == - && "\${2:-}" == *"$SCRATCH_ROOT/discovery-failed"* ]]; then exit 1; fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod 700 "$SHIM/python3"
  CURSOR="$T/discovery-cursor.json"
  python3 - "$CURSOR" "$SCRATCH_ROOT" <<'PY'
import json,sys
root=sys.argv[2]
json.dump({"schema":1,"source":f"scratch_prune:v1:{root}","items":[f"{root}/discovery-failed",f"{root}/isolated-discovery-eligible"],"next_index":0}, open(sys.argv[1],"w"))
PY
  out="$(RUN_PATH="$SHIM:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 bash "$SCRIPT" --clean --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "discovery-error pass exits cleanly" || bad "discovery-error pass exits cleanly" "rc=$rc"
  [[ -e "$SCRATCH_ROOT/discovery-failed/payload.bin" ]] && ok "discovery-failed candidate is preserved" || bad "discovery-failed candidate is preserved"
  [[ ! -e "$discovery_eligible" ]] && ok "later eligible child is removed" || bad "later eligible child is removed" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-400)"
  [[ -e "$discovery_recent" && -d "$SCRATCH_ROOT/worldai_frontend" ]] && ok "fresh sibling and parent are preserved" || bad "fresh sibling and parent are preserved"
  check "old artifact removal is reported" "removed:" "$out"
  check "discovery failure is explicitly reported" "kept:artifact-discovery-unmeasurable $SCRATCH_ROOT/discovery-failed" "$out"
  if python3 - "$CURSOR" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d["next_index"] >= len(d["items"])
PY
  then ok "cursor advances past the failed discovery visit"; else bad "cursor advances past the failed discovery visit" "$(cat "$CURSOR")"; fi
  echo "Test: discovery failure as the final cursor item persists completion without a sibling"
  use_root
  register_test_volume
  make_tree discovery-final 2880 >/dev/null
  SHIM="$T/discovery-final-shim"; mkdir -p "$SHIM"
  REAL_PYTHON="$(command -v python3)"
  cat >"$SHIM/python3" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == - && "\${2:-}" == *"$SCRATCH_ROOT/discovery-final"* ]]; then exit 1; fi
exec "$REAL_PYTHON" "\$@"
EOF
  chmod 700 "$SHIM/python3"
  CURSOR="$T/discovery-final-cursor.json"
  python3 - "$CURSOR" "$SCRATCH_ROOT" <<'PY'
import json,sys
root=sys.argv[2]
json.dump({"schema":1,"source":f"scratch_prune:v1:{root}","items":[f"{root}/discovery-final"],"next_index":0}, open(sys.argv[1],"w"))
PY
  out="$(RUN_PATH="$SHIM:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 bash "$SCRIPT" --clean --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "final discovery-error pass exits cleanly" || bad "final discovery-error pass exits cleanly" "rc=$rc"
  [[ -e "$SCRATCH_ROOT/discovery-final/payload.bin" ]] && ok "final discovery-failed candidate is preserved" || bad "final discovery-failed candidate is preserved"
  check "final discovery failure is explicitly reported" "kept:artifact-discovery-unmeasurable $SCRATCH_ROOT/discovery-final" "$out"
  if python3 - "$CURSOR" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d["next_index"] == len(d["items"]) == 1
PY
  then ok "final failed discovery persists cursor completion"; else bad "final failed discovery persists cursor completion" "$(cat "$CURSOR")"; fi
  if [[ -n "${SCRATCH_PRUNE_TEST_FILTER:-}" ]]; then
    echo "test_cleanup_scratch_top_level (discovery-cursor-contract): $PASS passed, $FAIL failed"
    [[ "$FAIL" == 0 ]]; exit $?
  fi
fi

if [[ -z "${SCRATCH_PRUNE_TEST_FILTER:-}" || "${SCRATCH_PRUNE_TEST_FILTER:-}" == unknown-deadline-contract ]]; then
  echo "Test: an expired deadline stops before classifying unknown content and resumes safely"
  use_root
  register_test_volume
  # Untyped content that E8 cannot classify: a direct-child *file*, not a
  # directory. These fixtures exist to prove the deadline is honoured before
  # unproven content is even classified, so they must stay unproven.
  make_unknown_file a-unknown-25h 25
  make_unknown_file b-unknown-25h 25
  make_managed_tree resume-after-unknown-25h 25 >/dev/null
  CURSOR="$T/unknown-deadline.cursor"
  EXPIRED_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()-1)')"
  out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$EXPIRED_DEADLINE" --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "expired automatic pass exits cleanly" || bad "expired automatic pass exits cleanly" "rc=$rc"
  if [[ "$out" != *"kept:unproven-content $SCRATCH_ROOT/a-unknown-25h"* ]]; then
    ok "expired deadline is checked before unknown-content classification"
  else
    bad "expired deadline is checked before unknown-content classification" "unknown candidate was classified before deadline: $(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
  [[ -e "$SCRATCH_ROOT/a-unknown-25h" && -e "$SCRATCH_ROOT/b-unknown-25h" && -e "$SCRATCH_ROOT/worldai_frontend/build/resume-after-unknown-25h" ]] && ok "expired pass preserves both unknowns and the recognized candidate" || bad "expired pass preserves both unknowns and the recognized candidate"
  if [[ -f "$CURSOR" ]] && python3 - "$CURSOR" "$SCRATCH_ROOT/a-unknown-25h" <<'PY'
import json,sys
cursor=json.load(open(sys.argv[1])); assert cursor["schema"] == 1
assert cursor["next_index"] < len(cursor["items"])
assert cursor["items"][cursor["next_index"]] == sys.argv[2]
PY
  then ok "expired pass stores the exact first pending candidate"; else bad "expired pass stores the exact first pending candidate"; fi
  FUTURE_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()+60)')"
  out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$FUTURE_DEADLINE" --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "resumed automatic pass exits cleanly" || bad "resumed automatic pass exits cleanly" "rc=$rc"
  [[ -e "$SCRATCH_ROOT/a-unknown-25h" ]] && ok "resumed pass preserves the unknown candidate" || bad "resumed pass preserves the unknown candidate"
  [[ -e "$SCRATCH_ROOT/b-unknown-25h" ]] && ok "resumed pass progresses past the second unknown candidate without deleting it" || bad "resumed pass progresses past the second unknown candidate without deleting it"
  [[ ! -e "$SCRATCH_ROOT/worldai_frontend/build/resume-after-unknown-25h" ]] && ok "resumed pass reaches and removes the recognized artifact" || bad "resumed pass reaches and removes the recognized artifact" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"

  echo "Test: a seeded resume cursor skips prior unknown work and continues after the pending unknown"
  use_root
  register_test_volume
  # Untyped content that E8 cannot classify: a direct-child *file*, not a
  # directory. These fixtures exist to prove the deadline is honoured before
  # unproven content is even classified, so they must stay unproven.
  make_unknown_file a-unknown-25h 25
  make_unknown_file b-unknown-25h 25
  make_managed_tree resume-after-seeded-unknown-25h 25 >/dev/null
  CURSOR="$T/seeded-unknown-deadline.cursor"
  CURSOR_SOURCE="scratch_prune:v1:$SCRATCH_ROOT"
  python3 - "$CURSOR" "$CURSOR_SOURCE" "$SCRATCH_ROOT/a-unknown-25h" "$SCRATCH_ROOT/b-unknown-25h" <<'PY'
import json,sys
with open(sys.argv[1], "w") as f:
    json.dump({"schema": 1, "source": sys.argv[2], "items": sys.argv[3:], "next_index": 1}, f)
PY
  EXPIRED_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()-1)')"
  out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$EXPIRED_DEADLINE" --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "seeded expired pass exits cleanly" || bad "seeded expired pass exits cleanly" "rc=$rc"
  if [[ "$out" != *"kept:unproven-content $SCRATCH_ROOT/a-unknown-25h"* ]]; then
    ok "seeded cursor does not reclassify the completed unknown candidate"
  else
    bad "seeded cursor does not reclassify the completed unknown candidate" "completed unknown was reclassified: $(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
  if [[ -f "$CURSOR" ]] && python3 - "$CURSOR" "$SCRATCH_ROOT/b-unknown-25h" <<'PY'
import json,sys
cursor=json.load(open(sys.argv[1])); assert cursor["next_index"] < len(cursor["items"])
assert cursor["items"][cursor["next_index"]] == sys.argv[2]
PY
  then ok "seeded expired pass leaves the pending unknown at the cursor"; else bad "seeded expired pass leaves the pending unknown at the cursor"; fi
  FUTURE_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()+60)')"
  out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$FUTURE_DEADLINE" --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "seeded resumed pass exits cleanly" || bad "seeded resumed pass exits cleanly" "rc=$rc"
  [[ -e "$SCRATCH_ROOT/a-unknown-25h" && -e "$SCRATCH_ROOT/b-unknown-25h" ]] && ok "seeded resumed pass preserves both unknown candidates" || bad "seeded resumed pass preserves both unknown candidates"
  [[ ! -e "$SCRATCH_ROOT/worldai_frontend/build/resume-after-seeded-unknown-25h" ]] && ok "seeded resumed pass reaches the registered artifact" || bad "seeded resumed pass reaches the registered artifact" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
  if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" == unknown-deadline-contract ]]; then
    echo "test_cleanup_scratch_top_level (unknown-deadline-contract): $PASS passed, $FAIL failed"
    [[ "$FAIL" == 0 ]]
    exit $?
  fi
fi

echo "Test 5: a live owner lease keeps the dir even with approval"
use_root
make_tree live-lease 72 >/dev/null
sleep 300 & lease_pid=$!
lease_file="$(env DISK_MAGICIAN_STATE_DIR="$DISK_MAGICIAN_STATE_DIR" bash -c '
source "$1/scripts/lib/worktree_lease.sh"
lease_write "$2" "$2" "" scratch-prune-test --owner-pid "$3" >/dev/null || exit
lease_path_for "$2"' _ "$ROOT" "$SCRATCH_ROOT/live-lease" "$lease_pid")"
[[ -s "$lease_file" ]] && ok "live-owner lease fixture was written to cleaner state" || bad "live-owner lease fixture was written to cleaner state" "$lease_file"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
kill "$lease_pid" 2>/dev/null || true; wait "$lease_pid" 2>/dev/null || true
check "live lease keeps the candidate" "kept:live-owner" "$out"
[[ -d "$SCRATCH_ROOT/live-lease" ]] && ok "live-lease dir preserved" || bad "live-lease dir preserved"

echo "Test 6: an open file keeps the dir even with approval"
use_root
make_tree open-file 72 >/dev/null
( exec 3<"$SCRATCH_ROOT/open-file/payload.bin"; sleep 60 ) & holder=$!
sleep 1
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
check "open file keeps the candidate" "kept:open-file" "$out"
[[ -d "$SCRATCH_ROOT/open-file" ]] && ok "open-file dir preserved" || bad "open-file dir preserved"

echo "Test 7: both override classes need the approval flag and are logged"
use_root
make_tree content-keep 72 '.env.example' >/dev/null
make_tree secret-keep 73 '.env' >/dev/null
out="$(run bash "$SCRIPT" --dry-run 2>&1)"
check "unproven-content is reported for this candidate" "kept:unproven-content $SCRATCH_ROOT/content-keep" "$out"
check "secret-like is reported for this candidate" "kept:secret-like $SCRATCH_ROOT/secret-keep" "$out"
[[ -d "$SCRATCH_ROOT/content-keep" && -d "$SCRATCH_ROOT/secret-keep" ]] && ok "both unapproved content keeps preserved" || bad "both unapproved content keeps preserved"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
[[ ! -e "$SCRATCH_ROOT/content-keep" ]] && ok "approved override removes the unproven-content tree" || bad "approved override removes the unproven-content tree" "$(printf %s "$out" | tr "\n" " " | cut -c1-300)"
[[ ! -e "$SCRATCH_ROOT/secret-keep" ]] && ok "approved override removes the secret-like tree" || bad "approved override removes the secret-like tree" "$(printf %s "$out" | tr "\n" " " | cut -c1-300)"
check "the unproven-content override is logged" "scratch-prune:kept:unproven-content" "$(cat "$LOG" 2>/dev/null)"
check "the secret-like override is logged" "scratch-prune:kept:secret-like" "$(cat "$LOG" 2>/dev/null)"

echo "Test 8: other content keeps are never overridden"
use_root
make_tree dirty-repo 72 >/dev/null
git -C "$SCRATCH_ROOT/dirty-repo" init -q 2>/dev/null
printf 'change\n' > "$SCRATCH_ROOT/dirty-repo/tracked.txt"
git -C "$SCRATCH_ROOT/dirty-repo" add tracked.txt 2>/dev/null
old_stamp "$SCRATCH_ROOT/dirty-repo" 72
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
[[ -d "$SCRATCH_ROOT/dirty-repo" ]] && ok "a non-listed keep survives the approval flag" || bad "a non-listed keep survives the approval flag"
check "the dirty-repo candidate keeps with its own reason" "kept:dirty $SCRATCH_ROOT/dirty-repo" "$out"
if grep -qF "$SCRATCH_ROOT/dirty-repo" "$LOG" 2>/dev/null; then
  bad "no deletion-log row for the dirty repo"
else
  ok "no deletion-log row for the dirty repo"
fi

echo "Test 8b: a secret-like tree that is also a dirty repository is never overridden"
use_root
mkdir -p "$SCRATCH_ROOT/secret-dirty-repo"
git -C "$SCRATCH_ROOT/secret-dirty-repo" init -q 2>/dev/null
printf 'placeholder\n' > "$SCRATCH_ROOT/secret-dirty-repo/.env"
printf 'change\n' > "$SCRATCH_ROOT/secret-dirty-repo/tracked.txt"
git -C "$SCRATCH_ROOT/secret-dirty-repo" add tracked.txt 2>/dev/null
old_stamp "$SCRATCH_ROOT/secret-dirty-repo" 72
out="$(run bash "$SCRIPT" --dry-run 2>&1)"
check "the secret-like verdict is what C14 reports first" "kept:secret-like $SCRATCH_ROOT/secret-dirty-repo" "$out"
# A preview must not advertise a removal that --clean would refuse: the override
# path runs the repository provenance re-check in preview mode too.
out_prev="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --dry-run 2>&1)"
if printf '%s' "$out_prev" | grep -qF "would-remove:kept:secret-like $SCRATCH_ROOT/secret-dirty-repo"; then
  bad "preview never advertises the dirty-repo removal" "$(printf '%s' "$out_prev" | tr '\n' ' ' | cut -c1-200)"
else
  ok "preview never advertises the dirty-repo removal"
fi
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
[[ -d "$SCRATCH_ROOT/secret-dirty-repo" ]] && ok "unpushed work survives the secret-like override" || bad "unpushed work survives the secret-like override" "$(printf %s "$out" | tr "\n" " " | cut -c1-300)"

echo "Test 9: the per-run cap is honoured"
use_root
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
use_root
out="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" TMPDIR="$T" \
  DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE="$SCRATCH_ROOT" bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ok "root override outside the sandbox is refused" || bad "root override outside the sandbox is refused" "rc=$rc"
check "refusal explains the sandbox requirement" "test sandbox" "$out"

echo "Test 11: root '/' is refused"
use_root
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE=/ bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
[[ "$rc" == 2 ]] && ok "root '/' refused" || bad "root '/' refused" "rc=$rc"

echo "Test 12: a symlinked candidate is never followed"
use_root
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
