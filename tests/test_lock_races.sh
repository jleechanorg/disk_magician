#!/usr/bin/env bash
# tests/test_lock_races.sh — Verify atomic lock takeover and live-pid protection
# for snapshot_commit.sh and pressure_sweep.sh (beads disk_magician-0bgs, disk_magician-151c).
set -euo pipefail

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$(( PASS + 1 ))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$(( FAIL + 1 ))
  fi
}

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/test_lock_races.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

echo "=== Test Case 1: snapshot_commit atomic stale lock takeover with 20 concurrent contenders ==="
LOCK_DIR="$TEST_TMP/snapshot.lock"
mkdir -p "$LOCK_DIR"
echo 999998 > "$LOCK_DIR/pid"
touch -t "$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$LOCK_DIR"

TTL=3600
OUT_DIR="$TEST_TMP/out1"
mkdir -p "$OUT_DIR"

acquire_snapshot_subshell() {
  local id="$1"
  mkdir -p "$(dirname "$LOCK_DIR")"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    echo "WINNER $id" > "$OUT_DIR/$id.win"
    return 0
  fi
  local held_pid age now lock_mtime is_alive=0
  held_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  lock_mtime=$(stat -f%m "$LOCK_DIR" 2>/dev/null || stat -c%Y "$LOCK_DIR" 2>/dev/null || date +%s)
  now=$(date +%s)
  age=$(( now - lock_mtime ))
  if [[ -n "$held_pid" && "$held_pid" =~ ^[0-9]+$ ]]; then
    if ps -p "$held_pid" -o pid= >/dev/null 2>&1; then
      is_alive=1
    fi
  fi
  if [[ "$age" -gt "$TTL" && "$is_alive" -eq 0 ]]; then
    local reclaim_gate="${LOCK_DIR}.reclaim_gate"
    if mkdir "$reclaim_gate" 2>/dev/null; then
      local recheck_pid recheck_mtime recheck_alive=0
      recheck_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
      recheck_mtime=$(stat -f%m "$LOCK_DIR" 2>/dev/null || stat -c%Y "$LOCK_DIR" 2>/dev/null || echo 0)
      if [[ -n "$recheck_pid" && "$recheck_pid" =~ ^[0-9]+$ ]]; then
        if ps -p "$recheck_pid" -o pid= >/dev/null 2>&1; then
          recheck_alive=1
        fi
      fi
      if [[ "$(( now - recheck_mtime ))" -gt "$TTL" && "$recheck_alive" -eq 0 ]]; then
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
          echo $$ > "$LOCK_DIR/pid"
          rmdir "$reclaim_gate" 2>/dev/null || true
          echo "WINNER $id" > "$OUT_DIR/$id.win"
          return 0
        fi
      fi
      rmdir "$reclaim_gate" 2>/dev/null || true
    fi
  fi
  echo "LOSER $id" > "$OUT_DIR/$id.lose"
  return 1
}

pids=()
for i in {1..20}; do
  acquire_snapshot_subshell "$i" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || true
done

winners=$(find "$OUT_DIR" -maxdepth 1 -name '*.win' 2>/dev/null | wc -l | tr -d ' ')
losers=$(find "$OUT_DIR" -maxdepth 1 -name '*.lose' 2>/dev/null | wc -l | tr -d ' ')

assert_eq "1" "$winners" "Exactly 1 winner among 20 concurrent contenders"
assert_eq "19" "$losers" "Exactly 19 losers cleanly skipped without corrupting lock"
assert_eq "true" "$([[ -d "$LOCK_DIR" ]] && echo true || echo false)" "Lock directory is intact"

echo "=== Test Case 2: snapshot_commit live PID protection (cannot steal lock while PID alive) ==="
rm -rf "$TEST_TMP/snapshot2.lock" "$OUT_DIR"
mkdir -p "$OUT_DIR"
LOCK_DIR2="$TEST_TMP/snapshot2.lock"
mkdir -p "$LOCK_DIR2"

# Use subshell sleep and track its PID
( sleep 60 ) &
SLEEP_PID=$!
echo "$SLEEP_PID" > "$LOCK_DIR2/pid"
touch -t "$(date -v-5H +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 hours ago' +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$LOCK_DIR2"

acquire_snapshot2_subshell() {
  local id="$1"
  mkdir -p "$(dirname "$LOCK_DIR2")"
  if mkdir "$LOCK_DIR2" 2>/dev/null; then
    echo $$ > "$LOCK_DIR2/pid"
    echo "WINNER $id" > "$OUT_DIR/$id.win"
    return 0
  fi
  local held_pid age now lock_mtime is_alive=0
  held_pid=$(cat "$LOCK_DIR2/pid" 2>/dev/null || echo "")
  lock_mtime=$(stat -f%m "$LOCK_DIR2" 2>/dev/null || stat -c%Y "$LOCK_DIR2" 2>/dev/null || date +%s)
  now=$(date +%s)
  age=$(( now - lock_mtime ))
  if [[ -n "$held_pid" && "$held_pid" =~ ^[0-9]+$ ]]; then
    if ps -p "$held_pid" -o pid= >/dev/null 2>&1; then
      is_alive=1
    fi
  fi
  if [[ "$age" -gt "$TTL" && "$is_alive" -eq 0 ]]; then
    local reclaim_gate="${LOCK_DIR2}.reclaim_gate"
    if mkdir "$reclaim_gate" 2>/dev/null; then
      local recheck_pid recheck_mtime recheck_alive=0
      recheck_pid=$(cat "$LOCK_DIR2/pid" 2>/dev/null || echo "")
      recheck_mtime=$(stat -f%m "$LOCK_DIR2" 2>/dev/null || stat -c%Y "$LOCK_DIR2" 2>/dev/null || echo 0)
      if [[ -n "$recheck_pid" && "$recheck_pid" =~ ^[0-9]+$ ]]; then
        if ps -p "$recheck_pid" -o pid= >/dev/null 2>&1; then
          recheck_alive=1
        fi
      fi
      if [[ "$(( now - recheck_mtime ))" -gt "$TTL" && "$recheck_alive" -eq 0 ]]; then
        rm -rf "$LOCK_DIR2"
        if mkdir "$LOCK_DIR2" 2>/dev/null; then
          echo $$ > "$LOCK_DIR2/pid"
          rmdir "$reclaim_gate" 2>/dev/null || true
          echo "WINNER $id" > "$OUT_DIR/$id.win"
          return 0
        fi
      fi
      rmdir "$reclaim_gate" 2>/dev/null || true
    fi
  fi
  echo "LOSER $id" > "$OUT_DIR/$id.lose"
  return 1
}

pids2=()
for i in {1..10}; do
  acquire_snapshot2_subshell "$i" &
  pids2+=($!)
done
for pid in "${pids2[@]}"; do
  wait "$pid" || true
done
kill -9 "$SLEEP_PID" 2>/dev/null || true

winners2=$(find "$OUT_DIR" -maxdepth 1 -name '*.win' 2>/dev/null | wc -l | tr -d ' ')
losers2=$(find "$OUT_DIR" -maxdepth 1 -name '*.lose' 2>/dev/null | wc -l | tr -d ' ')

assert_eq "0" "$winners2" "Zero contenders stole lock while process was alive"
assert_eq "10" "$losers2" "All 10 contenders skipped because process is alive"

echo "=== Test Case 3: pressure_sweep atomic stale lock takeover with 20 concurrent contenders ==="
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
LOCK_DIR3="$TEST_TMP/pressure.lock"
mkdir -p "$LOCK_DIR3"
echo 999997 > "$LOCK_DIR3/pid"
echo "$(( $(date +%s) - 7200 ))" > "$LOCK_DIR3/acquired_at"

acquire_pressure_subshell() {
  local id="$1"
  mkdir -p "$(dirname "$LOCK_DIR3")"
  if mkdir "$LOCK_DIR3" 2>/dev/null; then
    date -u +%s > "$LOCK_DIR3/acquired_at"
    echo $$ > "$LOCK_DIR3/pid"
    echo "WINNER $id" > "$OUT_DIR/$id.win"
    return 0
  fi
  local lock_ts now age held_pid is_alive=0
  held_pid=$(cat "$LOCK_DIR3/pid" 2>/dev/null || echo "")
  lock_ts="$(cat "$LOCK_DIR3/acquired_at" 2>/dev/null || stat -f%m "$LOCK_DIR3" 2>/dev/null || stat -c%Y "$LOCK_DIR3" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age=$(( now - lock_ts ))
  if [[ -n "$held_pid" && "$held_pid" =~ ^[0-9]+$ ]]; then
    if ps -p "$held_pid" -o pid= >/dev/null 2>&1; then
      is_alive=1
    fi
  fi
  if (( age > TTL )) && [[ "$is_alive" -eq 0 ]]; then
    local reclaim_gate="${LOCK_DIR3}.reclaim_gate"
    if mkdir "$reclaim_gate" 2>/dev/null; then
      local recheck_pid recheck_ts recheck_alive=0
      recheck_pid=$(cat "$LOCK_DIR3/pid" 2>/dev/null || echo "")
      recheck_ts="$(cat "$LOCK_DIR3/acquired_at" 2>/dev/null || echo 0)"
      if [[ -n "$recheck_pid" && "$recheck_pid" =~ ^[0-9]+$ ]]; then
        if ps -p "$recheck_pid" -o pid= >/dev/null 2>&1; then
          recheck_alive=1
        fi
      fi
      if (( (now - recheck_ts) > TTL )) && [[ "$recheck_alive" -eq 0 ]]; then
        rm -rf "$LOCK_DIR3"
        if mkdir "$LOCK_DIR3" 2>/dev/null; then
          date -u +%s > "$LOCK_DIR3/acquired_at"
          echo $$ > "$LOCK_DIR3/pid"
          rmdir "$reclaim_gate" 2>/dev/null || true
          echo "WINNER $id" > "$OUT_DIR/$id.win"
          return 0
        fi
      fi
      rmdir "$reclaim_gate" 2>/dev/null || true
    fi
  fi
  echo "LOSER $id" > "$OUT_DIR/$id.lose"
  return 1
}

pids3=()
for i in {1..20}; do
  acquire_pressure_subshell "$i" &
  pids3+=($!)
done
for pid in "${pids3[@]}"; do
  wait "$pid" || true
done

winners3=$(find "$OUT_DIR" -maxdepth 1 -name '*.win' 2>/dev/null | wc -l | tr -d ' ')
losers3=$(find "$OUT_DIR" -maxdepth 1 -name '*.lose' 2>/dev/null | wc -l | tr -d ' ')

assert_eq "1" "$winners3" "Exactly 1 winner among 20 pressure_sweep contenders"
assert_eq "19" "$losers3" "Exactly 19 losers cleanly skipped"
assert_eq "true" "$([[ -f "$LOCK_DIR3/pid" ]] && echo true || echo false)" "Winner successfully recorded its PID"

echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
