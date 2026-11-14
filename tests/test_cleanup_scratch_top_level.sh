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

if [[ -z "${SCRATCH_PRUNE_TEST_FILTER:-}" || "${SCRATCH_PRUNE_TEST_FILTER:-}" == lru-probe-contract || "${SCRATCH_PRUNE_TEST_FILTER:-}" == budget-preserve-contract ]]; then
  echo "Test: manual LRU skips sub-threshold probes but keeps fresh usage identity"
  LRU_DISKM="$T/lru-diskm"
  cat >"$LRU_DISKM" <<'FAKE_LRU_DISKM'
#!/usr/bin/env bash
if [[ "$1 $2" == "volume verify-mount" ]]; then exit 0; fi
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
      DISK_MAGICIAN_CONFIG="${DISK_MAGICIAN_CONFIG:-}" \
      DISK_MAGICIAN_DISKUTIL_BIN="${DISK_MAGICIAN_DISKUTIL_BIN:-}" \
      FAKE_DISKUTIL_STATE="${FAKE_DISKUTIL_STATE:-}" FAKE_DISKUTIL_CALLS="${FAKE_DISKUTIL_CALLS:-}" \
      FAKE_DISKUTIL_MOUNTPOINT="${FAKE_DISKUTIL_MOUNTPOINT:-}" \
      DISK_MAGICIAN_DISKM_BIN="$LRU_DISKM" FAKE_SCRATCH_ROOT="$SCRATCH_ROOT" \
      SCRATCH_TOP_LEVEL_APPROVED=1 \
      FAKE_STATUS_CALLS="$T/lru-status.calls" FAKE_STATUS_MODE="${FAKE_STATUS_MODE:-}" DISK_MAGICIAN_SCRATCH_MIN_KB=512 "$@" --budget-floor-minutes 120
  }
  if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" != budget-preserve-contract ]]; then
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

  echo "Test: manual LRU filters sub-threshold entries before slow age ordering"
  use_root
  mkdir -p "$SCRATCH_ROOT/aaa-small-slow" "$SCRATCH_ROOT/zzz-large-eligible"
  printf 'tiny\n' >"$SCRATCH_ROOT/aaa-small-slow/payload.bin"
  head -c 1048576 /dev/zero >"$SCRATCH_ROOT/zzz-large-eligible/payload.bin"
  old_stamp "$SCRATCH_ROOT/aaa-small-slow" 13
  old_stamp "$SCRATCH_ROOT/zzz-large-eligible" 13
  SLOW_FIND_BIN="$T/lru-slow-find-bin"
  mkdir -p "$SLOW_FIND_BIN"
  cat >"$SLOW_FIND_BIN/find" <<'FAKE_FIND'
#!/usr/bin/env bash
case "$1" in
  *aaa-small-slow*) sleep 2 ;;
esac
exec /usr/bin/find "$@"
FAKE_FIND
  chmod +x "$SLOW_FIND_BIN/find"
  : >"$T/lru-status.calls"
  deadline="$(python3 -c 'import time; print(time.monotonic()+1)')"
  out="$(RUN_PATH="$SLOW_FIND_BIN:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" lru_run bash "$SCRIPT" --clean --budget-pct 5 --deadline-at "$deadline" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "minimum-size prefilter regression exits 0" || bad "minimum-size prefilter regression exits 0" "rc=$rc"
  [[ -d "$SCRATCH_ROOT/aaa-small-slow" ]] && ok "slow sub-threshold candidate is preserved" || bad "slow sub-threshold candidate is preserved"
  [[ ! -e "$SCRATCH_ROOT/zzz-large-eligible" ]] && ok "eligible candidate is evicted despite slow small sibling" || bad "eligible candidate is evicted despite slow small sibling" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-400)"
  check "minimum-size prefilter still reaches target" "lru: stop=target-reached evicted=1" "$out"

  for mode in quota-change usage-unknown; do
    use_root
    mkdir -p "$SCRATCH_ROOT/lru-identity"
    head -c 1048576 /dev/zero >"$SCRATCH_ROOT/lru-identity/payload.bin"
    old_stamp "$SCRATCH_ROOT/lru-identity" 13
    : >"$T/lru-status.calls"
    out="$(FAKE_STATUS_MODE="$mode" lru_run bash "$SCRIPT" --clean --budget-pct 5 2>&1)"; rc=$?
    [[ "$rc" == 75 ]] && ok "usage identity failure ($mode) fails closed" || bad "usage identity failure ($mode) fails closed" "rc=$rc"
    [[ -e "$SCRATCH_ROOT/lru-identity" ]] && ok "candidate survives usage identity failure ($mode)" || bad "candidate survives usage identity failure ($mode)"
    check "usage identity failure ($mode) reports an unknown post-measurement result" "budget_unmet=unknown" "$out"
    check "usage identity failure ($mode) is deferred explicitly" "deferred:budget-result-unmeasurable" "$out"
  done
  fi
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
    old_stamp "$candidate" 49
    initial="$(run bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; artifact_removal_verdict "$2"' _ "$ROOT" "$candidate")"
    assert_eq "$initial" kept:secret-like "fixture reaches the secret veto (secret-like blocks rescue proof) ($pushed)"
    provenance="$(run bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; c14_repos_ok "$2"' _ "$ROOT" "$candidate")"
    if [[ "$pushed" == no ]]; then expected=kept:not-pushed; else expected=ok; fi
    assert_eq "$provenance" "$expected" "fixture has expected repository provenance ($pushed)"
    old_stamp "$candidate" 49  # Git provenance probes refresh metadata mtimes.
    preview="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 DISK_MAGICIAN_SCRATCH_FLOOR_HOURS=12 bash "$SCRIPT" --dry-run 2>&1)"
    old_stamp "$candidate" 49
    out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 DISK_MAGICIAN_SCRATCH_FLOOR_HOURS=12 bash "$SCRIPT" --clean 2>&1)"
    if [[ "$pushed" == no ]]; then
      check "numeric-floor preview preserves unpushed secret-like repository" "kept:not-pushed $candidate" "$preview"
      check "numeric-floor clean refuses unpushed secret-like repository" "kept:not-pushed $candidate" "$out"
      [[ -f "$candidate/repo/payload" ]] && grep -qF 'must preserve unpushed data' "$candidate/repo/payload" && ok "unpushed payload survives" || bad "unpushed payload survives"
      if grep -Fq "$candidate" "$LOG" 2>/dev/null; then bad "no deletion record for retained repository"; else ok "no deletion record for retained repository"; fi
    else
      check "pushed secret-bearing control remains vetoed in preview" "kept:secret-like $candidate" "$preview"
      [[ ! -e "$candidate" ]] && ok "pushed control remains removable with explicit approval" || bad "pushed control remains removable with explicit approval" "$out"
    fi
  done
  if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" == numeric-secret-contract ]]; then
    echo "test_cleanup_scratch_top_level (numeric-secret-contract): $PASS passed, $FAIL failed"
    [[ "$FAIL" == 0 ]]
    exit $?
  fi
fi

if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" != 48h-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != cursor-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != unknown-deadline-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != discovery-cursor-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != budget-preserve-contract ]]; then
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

if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" != cursor-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != unknown-deadline-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != discovery-cursor-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != budget-preserve-contract ]]; then
echo "Test 4: automatic mode uses a 48 h default and does not bypass C14 safety"
use_root
register_test_volume
make_tree unknown-49h 49 >/dev/null
make_managed_tree recent-47h 47 >/dev/null
make_managed_tree eligible-49h 49 >/dev/null
make_managed_tree secret-49h 49 'placeholder.pem' >/dev/null
make_managed_tree secret-5h 5 'placeholder.pem' >/dev/null
mkdir -p "$SCRATCH_ROOT/worldai_frontend/build/dirty-5h"
git -C "$SCRATCH_ROOT/worldai_frontend/build/dirty-5h" init -q 2>/dev/null
printf 'change\n' > "$SCRATCH_ROOT/worldai_frontend/build/dirty-5h/tracked.txt"
git -C "$SCRATCH_ROOT/worldai_frontend/build/dirty-5h" add tracked.txt 2>/dev/null
old_stamp "$SCRATCH_ROOT/worldai_frontend/build/dirty-5h" 5
mkdir -p "$SCRATCH_ROOT/worldai_frontend/build/dirty-49h"
git -C "$SCRATCH_ROOT/worldai_frontend/build/dirty-49h" init -q 2>/dev/null
printf 'change\n' > "$SCRATCH_ROOT/worldai_frontend/build/dirty-49h/tracked.txt"
git -C "$SCRATCH_ROOT/worldai_frontend/build/dirty-49h" add tracked.txt 2>/dev/null
old_stamp "$SCRATCH_ROOT/worldai_frontend/build/dirty-49h" 49
assert_eq "$(run env DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; artifact_removal_verdict "$2" --kind ephemeral' _ "$ROOT" "$SCRATCH_ROOT/worldai_frontend/build/eligible-49h")" remove "C14 accepts a known Scratch build artifact after 48h"
assert_eq "$(run env DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; artifact_removal_verdict "$2" --kind ephemeral' _ "$ROOT" "$SCRATCH_ROOT/worldai_frontend/build/recent-47h")" kept:recent-activity "C14 preserves a known Scratch build artifact at 47h (48h recency veto)"
preview="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 DISK_MAGICIAN_SCRATCH_MIN_KB=1048576 bash "$SCRIPT" --dry-run 2>&1)"
check "automatic preview marks the 49h managed artifact removable" "would-remove:remove $SCRATCH_ROOT/worldai_frontend/build/eligible-49h" "$preview"
check "automatic preview keeps the 47h managed artifact" "kept:recent-activity $SCRATCH_ROOT/worldai_frontend/build/recent-47h" "$preview"
check "automatic preview refuses secret-bearing content after 48h" "kept:secret-like $SCRATCH_ROOT/worldai_frontend/build/secret-49h" "$preview"
check "automatic preview refuses dirty repository content after 48h" "kept:dirty $SCRATCH_ROOT/worldai_frontend/build/dirty-49h" "$preview"
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 DISK_MAGICIAN_SCRATCH_MIN_KB=1048576 bash "$SCRIPT" --clean 2>&1)"; rc=$?
[[ "$rc" == 0 ]] && ok "automatic cleanup completes without override approval" || bad "automatic cleanup completes without override approval" "rc=$rc"
[[ -d "$SCRATCH_ROOT/worldai_frontend/build/recent-47h" ]] && ok "47h candidate preserved by the 48h default" || bad "47h candidate preserved by the 48h default"
[[ ! -e "$SCRATCH_ROOT/worldai_frontend/build/eligible-49h" ]] && ok "49h registered ephemeral candidate removed through C14" || bad "49h registered ephemeral candidate removed through C14" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
[[ -e "$SCRATCH_ROOT/worldai_frontend/build/secret-49h/placeholder.pem" ]] && ok "secret-like content past the age floor remains protected" || bad "secret-like content past the age floor remains protected"
[[ -e "$SCRATCH_ROOT/worldai_frontend/build/dirty-49h/.git" ]] && ok "dirty repository past the age floor remains protected" || bad "dirty repository past the age floor remains protected"
[[ -e "$SCRATCH_ROOT/worldai_frontend/build/secret-5h/placeholder.pem" ]] && ok "secret-like content younger than the floor remains protected in automatic mode" || bad "secret-like content younger than the floor remains protected in automatic mode"
[[ -e "$SCRATCH_ROOT/worldai_frontend/build/dirty-5h/.git" ]] && ok "dirty repository younger than the floor remains protected in automatic mode" || bad "dirty repository younger than the floor remains protected in automatic mode"
# E8 (artifact_verdict.sh:189-197) declares a direct child of the registered
# scratch volume ephemeral at the shared 2880-minute floor whatever its name, so an aged unknown
# top-level tree is now removable in automatic mode. Every other gate still ran.
[[ ! -e "$SCRATCH_ROOT/unknown-49h" ]] && ok "E8 removes an aged unknown direct volume child" || bad "E8 removes an aged unknown direct volume child" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"

echo "Test 4c: E8 declares an arbitrary direct child of the registered volume ephemeral at 48h"
use_root
register_test_volume
E8_ROOT="$SCRATCH_ROOT"
make_tree e8-unleased-50h 50 >/dev/null
mkdir -p "$E8_ROOT/e8-unleased-50h/nested"; old_stamp "$E8_ROOT/e8-unleased-50h" 50
make_tree e8-recent-47h 47 >/dev/null
make_tree e8-secret-50h 50 'placeholder.pem' >/dev/null
make_tree e8-secret-5h 5 'placeholder.pem' >/dev/null
make_tree e8-live-cwd-50h 50 >/dev/null
make_tree e8-leased-50h 50 >/dev/null
mkdir -p "$E8_ROOT/.dot-50h"; old_stamp "$E8_ROOT/.dot-50h" 50
mkdir -p "$E8_ROOT/worldai_frontend/build/e2-probe"; old_stamp "$E8_ROOT/worldai_frontend/build/e2-probe" 50
# A real repository holding a commit no remote advertises: unpushed work.
mkdir -p "$E8_ROOT/e8-unpushed-50h"
git -C "$E8_ROOT/e8-unpushed-50h" init -q 2>/dev/null
printf 'work\n' > "$E8_ROOT/e8-unpushed-50h/tracked.txt"
git -C "$E8_ROOT/e8-unpushed-50h" add tracked.txt 2>/dev/null
git -C "$E8_ROOT/e8-unpushed-50h" -c user.email=t@t -c user.name=t commit -qm work 2>/dev/null
old_stamp "$E8_ROOT/e8-unpushed-50h" 50
mkdir -p "$E8_ROOT/e8-unpushed-5h"
git -C "$E8_ROOT/e8-unpushed-5h" init -q 2>/dev/null
printf 'work\n' > "$E8_ROOT/e8-unpushed-5h/tracked.txt"
git -C "$E8_ROOT/e8-unpushed-5h" add tracked.txt 2>/dev/null
git -C "$E8_ROOT/e8-unpushed-5h" -c user.email=t@t -c user.name=t commit -qm work 2>/dev/null
old_stamp "$E8_ROOT/e8-unpushed-5h" 5
# The symlink target is a plain tree: a target holding .git would match the
# pre-existing <name>-holds-.git volume row and prove nothing about E8.
make_tree e8-symlink-target-50h 50 >/dev/null
ln -s "$E8_ROOT/e8-symlink-target-50h" "$E8_ROOT/e8-link-50h"
sleep 300 & e8_lease_pid=$!
(cd "$E8_ROOT/e8-live-cwd-50h" && exec sleep 300) & e8_cwd_pid=$!
env DISK_MAGICIAN_STATE_DIR="$DISK_MAGICIAN_STATE_DIR" bash -c '
source "$1/scripts/lib/worktree_lease.sh"
lease_write "$2" "$2" "" scratch-prune-test --owner-pid "$3" >/dev/null' _ "$ROOT" "$E8_ROOT/e8-leased-50h" "$e8_lease_pid"
eph_retention() { run env DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" bash -c 'source "$1/scripts/lib/artifact_verdict.sh"; c14_ephemeral_retention "$2" 2>/dev/null' _ "$ROOT" "$1"; }
assert_eq "$(eph_retention "$E8_ROOT/e8-unleased-50h")" 2880 "E8 proves an arbitrary volume-child name"
assert_eq "$(eph_retention "$E8_ROOT/e8-unleased-50h/nested")" "" "E8 stays top-level only"
assert_eq "$(eph_retention "$E8_ROOT/.dot-50h")" "" "E8 never covers a dot entry"
assert_eq "$(eph_retention "$E8_ROOT/e8-link-50h")" "" "E8 never answers for a symlink"
assert_eq "$(eph_retention "$E8_ROOT/worldai_frontend/build/e2-probe")" 1440 "the <name>/build/<name> row still answers 1440"
preview="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 bash "$SCRIPT" --dry-run 2>&1)"
check "automatic preview marks the unleased E8 candidate removable" "would-remove:remove $E8_ROOT/e8-unleased-50h" "$preview"
check "automatic preview keeps the under-48h E8 candidate" "kept:recent-activity $E8_ROOT/e8-recent-47h" "$preview"
check "automatic preview preserves secret-like E8 content past the floor" "kept:secret-like $E8_ROOT/e8-secret-50h" "$preview"
check "automatic preview keeps the secret-like E8 candidate younger than the floor" "kept:recent-activity $E8_ROOT/e8-secret-5h" "$preview"
check "automatic preview keeps the live-cwd E8 candidate" "kept:live-cwd $E8_ROOT/e8-live-cwd-50h" "$preview"
check "automatic preview keeps the leased E8 candidate" "kept:live-owner $E8_ROOT/e8-leased-50h" "$preview"
check "automatic preview keeps the symlinked entry as unproven" "kept:unproven-content $E8_ROOT/e8-link-50h" "$preview"
check "the unpushed repository without rescue remains protected past the floor" "kept:not-pushed $E8_ROOT/e8-unpushed-50h" "$preview"
if printf '%s\n' "$preview" | grep -qE "^would-remove:[^ ]* $E8_ROOT/e8-unpushed-5h$"; then
  bad "the unpushed repository younger than the floor is never advertised for removal" "$(printf '%s' "$preview" | grep -F "e8-unpushed-5h" | tr '\n' ' ' | cut -c1-200)"
else
  ok "the unpushed repository younger than the floor is never advertised for removal"
fi
check "the unpushed repository younger than the floor keeps as recent-activity" "kept:recent-activity $E8_ROOT/e8-unpushed-5h" "$preview"
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 bash "$SCRIPT" --clean 2>&1)"; rc=$?
kill "$e8_lease_pid" "$e8_cwd_pid" 2>/dev/null || true; wait "$e8_lease_pid" "$e8_cwd_pid" 2>/dev/null || true
[[ "$rc" == 0 ]] && ok "automatic E8 cleanup exits 0" || bad "automatic E8 cleanup exits 0" "rc=$rc"
[[ ! -e "$E8_ROOT/e8-unleased-50h" ]] && ok "an unleased dormant volume child is reclaimed" || bad "an unleased dormant volume child is reclaimed" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
[[ -e "$E8_ROOT/e8-recent-47h" ]] && ok "the 48h floor is still honoured by default" || bad "the 48h floor is still honoured by default"
[[ -e "$E8_ROOT/e8-leased-50h" ]] && ok "a leased volume child is preserved" || bad "a leased volume child is preserved"
[[ -e "$E8_ROOT/e8-live-cwd-50h" ]] && ok "a live-cwd volume child is preserved" || bad "a live-cwd volume child is preserved"
[[ -e "$E8_ROOT/e8-unpushed-50h/.git" ]] && ok "a volume child holding unpushed commits past the floor stays protected" || bad "a volume child holding unpushed commits past the floor stays protected"
[[ -e "$E8_ROOT/e8-secret-50h/placeholder.pem" ]] && ok "a secret-like volume child past the floor stays protected" || bad "a secret-like volume child past the floor stays protected"
[[ -e "$E8_ROOT/e8-unpushed-5h/tracked.txt" ]] && ok "a volume child holding unpushed commits younger than the floor is preserved" || bad "a volume child holding unpushed commits younger than the floor is preserved"
[[ -e "$E8_ROOT/e8-secret-5h/placeholder.pem" ]] && ok "a secret-like volume child younger than the floor is preserved" || bad "a secret-like volume child younger than the floor is preserved"
[[ -L "$E8_ROOT/e8-link-50h" ]] && ok "a symlinked top-level entry is never followed or reclaimed" || bad "a symlinked top-level entry is never followed or reclaimed"
fi

if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" != unknown-deadline-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != discovery-cursor-contract && "${SCRATCH_PRUNE_TEST_FILTER:-}" != budget-preserve-contract ]]; then
echo "Test 4b: an expired batch deadline leaves the existing cursor retryable"
use_root
register_test_volume
make_managed_tree resume-49h 49 >/dev/null
CURSOR="$T/scratch-prune.cursor"
EXPIRED_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()-1)')"
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$EXPIRED_DEADLINE" --cursor "$CURSOR" 2>&1)"
rc=$?
[[ "$rc" == 75 ]] && ok "expired batch deadline returns deferred status 75" || bad "expired batch deadline returns deferred status 75" "rc=$rc"
[[ -d "$SCRATCH_ROOT/worldai_frontend/build/resume-49h" ]] && ok "expired deadline does not delete the pending candidate" || bad "expired deadline does not delete the pending candidate"
check "expired batch deadline is explicit" "deferred:artifact-discovery-deadline" "$out"
if [[ -f "$CURSOR" ]] && python3 - "$CURSOR" "$SCRATCH_ROOT" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d["source"] == f"scratch_prune:v1:{sys.argv[2]}"
assert d["items"] == [] and d["next_index"] == 0
PY
then ok "expired batch leaves a zero-progress cursor that retries discovery"; else bad "expired batch leaves a zero-progress cursor that retries discovery"; fi
FUTURE_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()+60)')"
out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$FUTURE_DEADLINE" --cursor "$CURSOR" 2>&1)"
[[ ! -e "$SCRATCH_ROOT/worldai_frontend/build/resume-49h" ]] && ok "the next scheduled pass resumes and removes the eligible item" || bad "the next scheduled pass resumes and removes the eligible item" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
fi
if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" == 48h-contract ]]; then
  echo "Test 4d: public scratch-prune dry-run does not publish a dirty-source rescue"
  use_root
  register_test_volume
  origin="$T/dry-run-rescue-origin.git"
  candidate="$SCRATCH_ROOT/dirty-public-preview"
  git init -q --bare "$origin"
  mkdir -p "$candidate"
  git -C "$candidate" init -q -b main
  git -C "$candidate" config user.name fixture
  git -C "$candidate" config user.email fixture@example.invalid
  printf 'base\\n' >"$candidate/tracked.txt"
  git -C "$candidate" add tracked.txt
  git -C "$candidate" commit -qm base
  git -C "$candidate" remote add origin "$origin"
  git -C "$candidate" push -q origin main
  printf 'local changes\\n' >"$candidate/local.txt"
  old_stamp "$candidate" 72
  refs_before="$(git --git-dir "$origin" for-each-ref --format='%(refname) %(objectname)')"
  objects_before="$(git --git-dir "$origin" count-objects -v)"
  out="$(run bash "$ROOT/disk_magician.sh" scratch-prune --dry-run 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "public CLI dry-run completes" || bad "public CLI dry-run completes" "rc=$rc"
  check "dirty-source preview requires a real rescue" "kept:rescue-required $candidate" "$out"
  [[ -f "$candidate/local.txt" ]] && ok "dry-run preserves the dirty source" || bad "dry-run preserves the dirty source"
  refs_after="$(git --git-dir "$origin" for-each-ref --format='%(refname) %(objectname)')"
  objects_after="$(git --git-dir "$origin" count-objects -v)"
  [[ "$refs_after" == "$refs_before" ]] && ok "dry-run leaves remote refs unchanged" || bad "dry-run leaves remote refs unchanged"
  [[ "$objects_after" == "$objects_before" ]] && ok "dry-run leaves remote objects unchanged" || bad "dry-run leaves remote objects unchanged"
fi
if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" == 48h-contract || "${SCRATCH_PRUNE_TEST_FILTER:-}" == cursor-contract ]]; then
  echo "test_cleanup_scratch_top_level (${SCRATCH_PRUNE_TEST_FILTER}): $PASS passed, $FAIL failed"
  [[ "$FAIL" == 0 ]]
  exit $?
fi

if [[ -z "${SCRATCH_PRUNE_TEST_FILTER:-}" || "${SCRATCH_PRUNE_TEST_FILTER:-}" == discovery-cursor-contract ]]; then
  echo "Test: any batch discovery failure aborts before deleting candidates and leaves the cursor retryable"
  use_root
  register_test_volume
  make_tree discovery-failed 49 >/dev/null
  make_tree isolated-discovery-eligible 49 >/dev/null
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
if [[ "\${1:-}" == *scratch_budget_artifact_children.py ]]; then exit 1; fi
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
  [[ "$rc" == 75 ]] && ok "batch discovery-error pass returns deferred status 75" || bad "batch discovery-error pass returns deferred status 75" "rc=$rc"
  [[ -e "$SCRATCH_ROOT/discovery-failed/payload.bin" ]] && ok "discovery-failed candidate is preserved" || bad "discovery-failed candidate is preserved"
  [[ -e "$discovery_eligible" ]] && ok "separate eligible candidate is preserved after batch failure" || bad "separate eligible candidate is preserved after batch failure"
  [[ -e "$discovery_recent" && -d "$SCRATCH_ROOT/worldai_frontend" ]] && ok "fresh sibling and parent are preserved" || bad "fresh sibling and parent are preserved"
  check "discovery failure is explicitly reported" "deferred:artifact-discovery-unmeasurable" "$out"
  if python3 - "$CURSOR" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d["next_index"] == 0
PY
  then ok "cursor remains at the failed batch for retry"; else bad "cursor remains at the failed batch for retry" "$(cat "$CURSOR")"; fi
  echo "Test: a failing batch with only one cursor item does not persist false completion"
  use_root
  register_test_volume
  make_tree discovery-final 49 >/dev/null
  SHIM="$T/discovery-final-shim"; mkdir -p "$SHIM"
  REAL_PYTHON="$(command -v python3)"
  cat >"$SHIM/python3" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == *scratch_budget_artifact_children.py ]]; then exit 1; fi
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
  [[ "$rc" == 75 ]] && ok "final batch discovery-error pass returns 75" || bad "final batch discovery-error pass returns 75" "rc=$rc"
  [[ -e "$SCRATCH_ROOT/discovery-final/payload.bin" ]] && ok "final discovery-failed candidate is preserved" || bad "final discovery-failed candidate is preserved"
  check "final discovery failure is explicitly reported" "deferred:artifact-discovery-unmeasurable" "$out"
  if python3 - "$CURSOR" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d["next_index"] == 0 and len(d["items"]) == 1
PY
  then ok "final failed discovery preserves the pending cursor item"; else bad "final failed discovery preserves the pending cursor item" "$(cat "$CURSOR")"; fi
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
  make_unknown_file a-unknown-49h 49
  make_unknown_file b-unknown-49h 49
  make_managed_tree resume-after-unknown-49h 49 >/dev/null
  CURSOR="$T/unknown-deadline.cursor"
  EXPIRED_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()-1)')"
  out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$EXPIRED_DEADLINE" --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 75 ]] && ok "expired automatic batch pass returns deferred status 75" || bad "expired automatic batch pass returns deferred status 75" "rc=$rc"
  check "expired automatic batch pass reports discovery deferral" "deferred:artifact-discovery-deadline" "$out"
  if [[ "$out" != *"kept:unproven-content $SCRATCH_ROOT/a-unknown-49h"* ]]; then
    ok "expired deadline is checked before unknown-content classification"
  else
    bad "expired deadline is checked before unknown-content classification" "unknown candidate was classified before deadline: $(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
  [[ -e "$SCRATCH_ROOT/a-unknown-49h" && -e "$SCRATCH_ROOT/b-unknown-49h" && -e "$SCRATCH_ROOT/worldai_frontend/build/resume-after-unknown-49h" ]] && ok "expired pass preserves both unknowns and the recognized candidate" || bad "expired pass preserves both unknowns and the recognized candidate"
  if [[ -f "$CURSOR" ]] && python3 - "$CURSOR" "$SCRATCH_ROOT" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d["source"] == f"scratch_prune:v1:{sys.argv[2]}"
assert d["items"] == [] and d["next_index"] == 0
PY
  then ok "expired batch leaves zero cursor progress for retry"; else bad "expired batch leaves zero cursor progress for retry"; fi
  FUTURE_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()+60)')"
  out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$FUTURE_DEADLINE" --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "resumed automatic pass exits cleanly" || bad "resumed automatic pass exits cleanly" "rc=$rc"
  [[ -e "$SCRATCH_ROOT/a-unknown-49h" ]] && ok "resumed pass preserves the unknown candidate" || bad "resumed pass preserves the unknown candidate"
  [[ -e "$SCRATCH_ROOT/b-unknown-49h" ]] && ok "resumed pass progresses past the second unknown candidate without deleting it" || bad "resumed pass progresses past the second unknown candidate without deleting it"
  [[ ! -e "$SCRATCH_ROOT/worldai_frontend/build/resume-after-unknown-49h" ]] && ok "resumed pass reaches and removes the recognized artifact" || bad "resumed pass reaches and removes the recognized artifact" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"

  echo "Test: a seeded resume cursor skips prior unknown work and continues after the pending unknown"
  use_root
  register_test_volume
  # Untyped content that E8 cannot classify: a direct-child *file*, not a
  # directory. These fixtures exist to prove the deadline is honoured before
  # unproven content is even classified, so they must stay unproven.
  make_unknown_file a-unknown-49h 49
  make_unknown_file b-unknown-49h 49
  make_managed_tree resume-after-seeded-unknown-49h 49 >/dev/null
  CURSOR="$T/seeded-unknown-deadline.cursor"
  CURSOR_SOURCE="scratch_prune:v1:$SCRATCH_ROOT"
  python3 - "$CURSOR" "$CURSOR_SOURCE" "$SCRATCH_ROOT/a-unknown-49h" "$SCRATCH_ROOT/b-unknown-49h" <<'PY'
import json,sys
with open(sys.argv[1], "w") as f:
    json.dump({"schema": 1, "source": sys.argv[2], "items": sys.argv[3:], "next_index": 1}, f)
PY
  EXPIRED_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()-1)')"
  out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$EXPIRED_DEADLINE" --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 75 ]] && ok "seeded expired batch pass returns deferred status 75" || bad "seeded expired batch pass returns deferred status 75" "rc=$rc"
  if [[ "$out" != *"kept:unproven-content $SCRATCH_ROOT/a-unknown-49h"* ]]; then
    ok "seeded cursor does not reclassify the completed unknown candidate"
  else
    bad "seeded cursor does not reclassify the completed unknown candidate" "completed unknown was reclassified: $(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
  if [[ -f "$CURSOR" ]] && python3 - "$CURSOR" "$SCRATCH_ROOT/b-unknown-49h" <<'PY'
import json,sys
cursor=json.load(open(sys.argv[1])); assert cursor["next_index"] < len(cursor["items"])
assert cursor["items"][cursor["next_index"]] == sys.argv[2]
PY
  then ok "seeded expired pass leaves the pending unknown at the cursor"; else bad "seeded expired pass leaves the pending unknown at the cursor"; fi
  FUTURE_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()+60)')"
  out="$(run env DISK_MAGICIAN_SCRATCH_ROOT_OVERRIDE= DISK_MAGICIAN_CONFIG="$VOLUME_CONFIG" DISK_MAGICIAN_SCRATCH_AUTOMATIC=1 "$REAL_PYTHON3" "$ROOT/src/disk_magician/cli.py" scratch-prune --clean --deadline-at "$FUTURE_DEADLINE" --cursor "$CURSOR" 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "seeded resumed pass exits cleanly" || bad "seeded resumed pass exits cleanly" "rc=$rc"
  [[ -e "$SCRATCH_ROOT/a-unknown-49h" && -e "$SCRATCH_ROOT/b-unknown-49h" ]] && ok "seeded resumed pass preserves both unknown candidates" || bad "seeded resumed pass preserves both unknown candidates"
  [[ ! -e "$SCRATCH_ROOT/worldai_frontend/build/resume-after-seeded-unknown-49h" ]] && ok "seeded resumed pass reaches the registered artifact" || bad "seeded resumed pass reaches the registered artifact" "$(printf %s "$out" | tr '\n' ' ' | cut -c1-300)"
  if [[ "${SCRATCH_PRUNE_TEST_FILTER:-}" == unknown-deadline-contract ]]; then
    echo "test_cleanup_scratch_top_level (unknown-deadline-contract): $PASS passed, $FAIL failed"
    [[ "$FAIL" == 0 ]]
    exit $?
  fi
fi

if [[ -z "${SCRATCH_PRUNE_TEST_FILTER:-}" ]]; then
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
check "no-proof is reported for this candidate" "kept:no-proof $SCRATCH_ROOT/content-keep" "$out"
check "secret-like veto is reported for the secret candidate" "kept:secret-like $SCRATCH_ROOT/secret-keep" "$out"
[[ -d "$SCRATCH_ROOT/content-keep" && -d "$SCRATCH_ROOT/secret-keep" ]] && ok "both unapproved content keeps preserved" || bad "both unapproved content keeps preserved"
out="$(run env SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean 2>&1)"
[[ ! -e "$SCRATCH_ROOT/content-keep" ]] && ok "approved override removes the unproven-content tree" || bad "approved override removes the unproven-content tree" "$(printf %s "$out" | tr "\n" " " | cut -c1-300)"
[[ ! -e "$SCRATCH_ROOT/secret-keep" ]] && ok "approved override removes the secret-like tree" || bad "approved override removes the secret-like tree" "$(printf %s "$out" | tr "\n" " " | cut -c1-300)"
check "the no-proof override is logged for the content candidate" "scratch-prune:kept:no-proof" "$(grep -F "$SCRATCH_ROOT/content-keep" "$LOG" 2>/dev/null)"
check "the secret-like veto is logged for the secret candidate" "scratch-prune:kept:secret-like" "$(grep -F "$SCRATCH_ROOT/secret-keep" "$LOG" 2>/dev/null)"

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
check "the secret-like veto is what C14 reports" "kept:secret-like $SCRATCH_ROOT/secret-dirty-repo" "$out"
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
fi

if [[ -z "${SCRATCH_PRUNE_TEST_FILTER:-}" || "${SCRATCH_PRUNE_TEST_FILTER:-}" == budget-preserve-contract ]]; then
  echo "Test 13: preserving budget mode keeps all C14 content/provenance verdicts"
  echo "Test 13a: a mid-helper discovery deadline returns 75 before any candidate deletion"
  use_root
  make_tree artifact-deferred 72 >/dev/null
  mkdir -p "$T/slow-python"
  cat >"$T/slow-python/python3" <<'PYTHON'
#!/usr/bin/env bash
case "${1:-}" in
  *scratch_budget_artifact_children.py) /bin/sleep 0.05; exit 124 ;;
esac
exec "$REAL_PYTHON3" "$@"
PYTHON
  chmod +x "$T/slow-python/python3"
  FUTURE_DEADLINE="$("$REAL_PYTHON3" -c 'import time; print(time.monotonic()+10)')"
  out="$(RUN_PATH="$T/slow-python:/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" run env REAL_PYTHON3="$REAL_PYTHON3" \
    SCRATCH_TOP_LEVEL_APPROVED=1 bash "$SCRIPT" --clean --deadline-at "$FUTURE_DEADLINE" 2>&1)"; rc=$?
  [[ "$rc" == 75 ]] && ok "mid-helper deferred discovery returns 75" || bad "mid-helper deferred discovery returns 75" "rc=$rc"
  check "mid-helper deadline is reported as discovery deferral" "deferred:artifact-discovery-deadline" "$out"
  check "mid-helper deferral reports a pending candidate" "deferred_candidates=1" "$out"
  [[ -d "$SCRATCH_ROOT/artifact-deferred" ]] && ok "mid-helper deferral deletes no candidates" || bad "mid-helper deferral deletes no candidates"
  temp_count="$(find "$T" -maxdepth 1 -type f -name 'dm-sp-artifacts.*' | wc -l | tr -d ' ')"
  [[ "$temp_count" == 0 ]] && ok "mid-helper deferral removes its batch result temp" || bad "mid-helper deferral removes its batch result temp" "count=$temp_count"

  echo "Test 13b: an unregistered generic directory remains an unproven C14 keep"
  use_root
  make_tree budget-unproven 72 '.env.example' >/dev/null
  head -c 1048576 /dev/zero >"$SCRATCH_ROOT/budget-unproven/payload.bin"
  old_stamp "$SCRATCH_ROOT/budget-unproven" 49
  out="$(lru_run env -u DISK_MAGICIAN_CONFIG DISK_MAGICIAN_SCRATCH_MIN_KB=0 bash "$SCRIPT" --dry-run --budget-pct 5 --budget-preserve-content-keeps 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] && ok "unconfigured user content dry-run completes without deletion" || bad "unconfigured user content dry-run completes without deletion" "rc=$rc"
  check "unclassified user content has no proof" "kept:no-proof $SCRATCH_ROOT/budget-unproven" "$out"
  [[ -d "$SCRATCH_ROOT/budget-unproven" ]] && ok "unclassified user content remains present" || bad "unclassified user content remains present"

  use_root
  register_test_volume
  STATE="$DISK_MAGICIAN_STATE_DIR"
  make_tree budget-secret 72 '.env' >/dev/null
  mkdir -p "$SCRATCH_ROOT/budget-dirty"
  git -C "$SCRATCH_ROOT/budget-dirty" init -q
  git -C "$SCRATCH_ROOT/budget-dirty" config user.name fixture
  git -C "$SCRATCH_ROOT/budget-dirty" config user.email fixture@example.invalid
  printf 'base\n' >"$SCRATCH_ROOT/budget-dirty/tracked.txt"
  git -C "$SCRATCH_ROOT/budget-dirty" add tracked.txt
  git -C "$SCRATCH_ROOT/budget-dirty" commit -qm base
  printf 'dirty\n' >>"$SCRATCH_ROOT/budget-dirty/tracked.txt"
  mkdir -p "$SCRATCH_ROOT/budget-not-pushed"
  git -C "$SCRATCH_ROOT/budget-not-pushed" init -q
  git -C "$SCRATCH_ROOT/budget-not-pushed" config user.name fixture
  git -C "$SCRATCH_ROOT/budget-not-pushed" config user.email fixture@example.invalid
  git init -q --bare "$T/budget-not-pushed-remote.git"
  printf 'local commit\n' >"$SCRATCH_ROOT/budget-not-pushed/tracked.txt"
  git -C "$SCRATCH_ROOT/budget-not-pushed" add tracked.txt
  git -C "$SCRATCH_ROOT/budget-not-pushed" commit -qm base
  git -C "$SCRATCH_ROOT/budget-not-pushed" branch -M main
  git -C "$SCRATCH_ROOT/budget-not-pushed" remote add origin "$T/budget-not-pushed-remote.git"
  git -C "$SCRATCH_ROOT/budget-not-pushed" push -qu -u origin main
  printf 'local-only\n' >>"$SCRATCH_ROOT/budget-not-pushed/tracked.txt"
  git -C "$SCRATCH_ROOT/budget-not-pushed" commit -qam local-only
  mkdir -p "$SCRATCH_ROOT/budget-ignored"
  git -C "$SCRATCH_ROOT/budget-ignored" init -q
  git -C "$SCRATCH_ROOT/budget-ignored" config user.name fixture
  git -C "$SCRATCH_ROOT/budget-ignored" config user.email fixture@example.invalid
  printf 'ignored.bin\n' >"$SCRATCH_ROOT/budget-ignored/.gitignore"
  git -C "$SCRATCH_ROOT/budget-ignored" add .gitignore
  git -C "$SCRATCH_ROOT/budget-ignored" commit -qm ignore-rule
  printf 'ignored bytes\n' >"$SCRATCH_ROOT/budget-ignored/ignored.bin"
  make_managed_tree budget-known-build 13 >/dev/null
  head -c 1048576 /dev/zero >"$SCRATCH_ROOT/budget-secret/payload.bin"
  head -c 1048576 /dev/zero >"$SCRATCH_ROOT/budget-dirty/padding.bin"
  old_stamp "$SCRATCH_ROOT/budget-secret" 49
  old_stamp "$SCRATCH_ROOT/budget-dirty" 49
  old_stamp "$SCRATCH_ROOT/budget-not-pushed" 50
  old_stamp "$SCRATCH_ROOT/budget-ignored" 50
  old_stamp "$SCRATCH_ROOT/worldai_frontend/build/budget-known-build" 50
  out="$(lru_run env DISK_MAGICIAN_SCRATCH_MIN_KB=0 bash "$SCRIPT" --dry-run --budget-pct 5 --budget-preserve-content-keeps 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E 'budget-(not-pushed|ignored|secret|unproven|dirty)|budget-known-build|budget_unmet=' || true
  [[ "$rc" == 0 ]] && ok "preserving budget dry-run completes without deletion" || bad "preserving budget dry-run completes without deletion" "rc=$rc"
  check "secret-like content remains a keep" "kept:secret-like $SCRATCH_ROOT/budget-secret" "$out"
  check "dirty repository remains a keep" "kept:dirty $SCRATCH_ROOT/budget-dirty" "$out"
  check "unpushed repository remains a keep without a dry-run rescue push" "kept:rescue-required $SCRATCH_ROOT/budget-not-pushed" "$out"
  check "ignored data remains a keep" "kept:ignored-data $SCRATCH_ROOT/budget-ignored" "$out"
  check "known disposable build remains eligible" "would-remove:remove $SCRATCH_ROOT/worldai_frontend/build/budget-known-build" "$out"
  check "dry-run reports no actual budget result" "budget_unmet=not-run projected_budget_unmet=unknown" "$out"
  [[ -d "$SCRATCH_ROOT/budget-secret" && -d "$SCRATCH_ROOT/budget-dirty" && -d "$SCRATCH_ROOT/budget-not-pushed" && -d "$SCRATCH_ROOT/budget-ignored" ]] && \
    ok "dry-run leaves every content/provenance fixture present" || bad "dry-run leaves every content/provenance fixture present"
  out="$(lru_run env DISK_MAGICIAN_SCRATCH_MIN_KB=0 bash "$SCRIPT" --clean --budget-pct 5 --budget-preserve-content-keeps 2>&1)"; rc=$?
  [[ "$rc" == 75 ]] && ok "unmet target after safe candidates returns partial status 75" || bad "unmet target after safe candidates returns partial status 75" "rc=$rc"
  [[ -d "$SCRATCH_ROOT/budget-secret" && -d "$SCRATCH_ROOT/budget-dirty" && -d "$SCRATCH_ROOT/budget-not-pushed" && -d "$SCRATCH_ROOT/budget-ignored" ]] && \
    ok "clean preserving mode leaves every content/provenance fixture present" || bad "clean preserving mode leaves every content/provenance fixture present"
  [[ ! -e "$SCRATCH_ROOT/worldai_frontend/build/budget-known-build" ]] && ok "clean preserving mode removes a known disposable build" || bad "clean preserving mode removes a known disposable build"
  check "clean reports measured unmet target and before/after gap" "budget_unmet=1" "$out"
  check "summary reports Data free-space interval separately" "data_free_interval_delta_bytes=" "$out"

  echo "Test 14: legacy budget callers retain their explicit content override"
  use_root
  register_test_volume
  STATE="$DISK_MAGICIAN_STATE_DIR"
  make_tree legacy-secret 72 '.env' >/dev/null
  make_tree legacy-unproven 72 '.env.example' >/dev/null
  head -c 1048576 /dev/zero >"$SCRATCH_ROOT/legacy-secret/payload.bin"
  head -c 1048576 /dev/zero >"$SCRATCH_ROOT/legacy-unproven/payload.bin"
  old_stamp "$SCRATCH_ROOT/legacy-secret" 13
  old_stamp "$SCRATCH_ROOT/legacy-unproven" 13
  out="$(lru_run env DISK_MAGICIAN_SCRATCH_MIN_KB=0 bash "$SCRIPT" --clean --budget-pct 5 2>&1)"; rc=$?
  [[ "$rc" == 75 ]] && ok "legacy budget mode reports safe-candidate shortfall" || bad "legacy budget mode reports safe-candidate shortfall" "rc=$rc"
  [[ ! -e "$SCRATCH_ROOT/legacy-secret" && ! -e "$SCRATCH_ROOT/legacy-unproven" ]] && ok "legacy budget mode still overrides its explicit content keeps" || bad "legacy budget mode still overrides its explicit content keeps"
fi

echo
echo "test_cleanup_scratch_top_level: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
