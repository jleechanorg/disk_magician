#!/usr/bin/env bash
# test_govern.sh — `diskm govern --mode observe` tick (plan Task 8, spec C1/C10).
#
# Fake df (DISK_MAGICIAN_DF_BIN), launchctl stub (DISK_MAGICIAN_LAUNCHCTL_BIN) and a
# temp DISK_MAGICIAN_STATE_DIR. The C14 self-test is stubbed by copying scripts/ into
# a temp tree and dropping a fake scripts/lib/artifact_verdict.sh there; the real tree
# has no artifact_verdict.sh until Task 11, so the kickstart must stay blocked.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISKM="$REPO_ROOT/disk_magician.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }

T="$(mktemp -d /tmp/dm-govern-test.XXXXXX)" || exit 1
[[ -d "$T" && "$T" == /tmp/dm-govern-test.* ]] || exit 1
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export DISK_MAGICIAN_DF_BIN="$T/bin/df"
export DISK_MAGICIAN_LAUNCHCTL_BIN="$T/bin/launchctl"
export DISK_MAGICIAN_FLEET_BIN="$T/bin/fleet" DISK_MAGICIAN_COLIMA_BIN=/usr/bin/false
printf '%s\n' '#!/bin/sh' 'echo '\''{"schema_version":1,"status":"healthy","records":[{"status":"healthy"}]}'\''' > "$T/bin/fleet"
chmod +x "$T/bin/fleet"
# Confine the tick's birth audit (Task 9) to empty temp roots.
export HOME="$T/home" TMPDIR="$T/tdir" DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$T/ptmp"
mkdir -p "$HOME" "$TMPDIR" "$T/ptmp"
KICKS="$T/kicks.log"

fake_df() {  # fake_df <free_gib> | fake_df fail
  if [[ "$1" == fail ]]; then printf '#!/bin/sh\nexit 1\n' > "$T/bin/df"
  else
    printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/disk3s5 999999999 1 %s 1%% /"\n' \
      "$(( $1 * 1024 * 1024 ))" > "$T/bin/df"
  fi
  chmod +x "$T/bin/df"
}
# The launchctl stub logs its argv plus the zone already in budget.json (zone-first check).
cat > "$T/bin/launchctl" <<SH
#!/bin/sh
z=\$(python3 -c 'import json,os;print(json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/budget.json"))["zone"])' 2>/dev/null)
echo "\$* zone=\$z" >> "$KICKS"
SH
chmod +x "$T/bin/launchctl"

fresh_state() { export DISK_MAGICIAN_STATE_DIR="$T/state.$1"; mkdir -p "$DISK_MAGICIAN_STATE_DIR"; : > "$KICKS"; }
budget() { python3 -c 'import json,os,sys;print(json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/budget.json")).get(sys.argv[1]))' "$1" 2>/dev/null; }
events() { cat "$DISK_MAGICIAN_STATE_DIR/admission/events.jsonl" 2>/dev/null; }
kicks() { [[ -s "$KICKS" ]] && wc -l < "$KICKS" | tr -d ' ' || echo 0; }

tree_with_verdict() {  # tree_with_verdict <dir> <self-test output>
  mkdir -p "$1"; cp -R "$REPO_ROOT/scripts" "$1/"
  cp "$REPO_ROOT/config.json.template" "$1/"
  printf 'artifact_removal_verdict() { [ "$1" = --self-test ] && echo %s; }\n' "$2" > "$1/scripts/lib/artifact_verdict.sh"
}

echo "== 1. GREEN tick writes zone, zone_at and free_bytes; merges with existing keys"
fresh_state green; fake_df 150
echo '{"classes": {"worktrees": {"used_gb": 1}}}' > "$DISK_MAGICIAN_STATE_DIR/budget.json"
before=$(date +%s)
"$DISKM" govern --mode observe >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "GREEN tick rc"
assert_eq "$(budget zone)" GREEN "zone"
assert_eq "$(budget free_bytes)" "$((150 * 1024 * 1024 * 1024))" "free_bytes"
python3 -c 'import json,os,sys;d=json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/budget.json"));sys.exit(0 if d["zone_at"]>=int(sys.argv[1]) else 1)' "$before" \
  && ok "zone_at fresh" || bad "zone_at not fresh"
# Configured du classes with an existing root are now bootstrapped on the first
# tick (spec 7.1 step 3); the pre-existing worktrees entry must be preserved.
assert_eq "$(python3 -c 'import json,os;c=json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/budget.json")).get("classes",{});print(c.get("worktrees"))')" "{'used_gb': 1}" "existing worktrees class kept"
assert_eq "$(kicks)" 0 "GREEN never kickstarts"

echo "== 1b. tick keeps a per-day minimum of used bytes (C12 trough baseline), 31 days max"
fresh_state daily; fake_df 150   # fake df reports Used=1 KiB
python3 -c 'import json,os,time
d={time.strftime("%Y-%m-%d",time.localtime(time.time()-i*86400)):10**15 for i in range(1,40)}
d[time.strftime("%Y-%m-%d")]=5
json.dump(dict(daily_min_used=d),open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/budget.json","w"))'
"$DISKM" govern --mode observe >/dev/null 2>&1
dm() { python3 -c 'import json,os,sys,time;m=json.load(open(os.environ["DISK_MAGICIAN_STATE_DIR"]+"/budget.json"))["daily_min_used"];print(len(m),m[time.strftime("%Y-%m-%d")])'; }
assert_eq "$(dm)" "31 5" "lower same-day minimum kept, history pruned to 31 days"
python3 -c 'import json,os,time;p=os.environ["DISK_MAGICIAN_STATE_DIR"]+"/budget.json";b=json.load(open(p));b["daily_min_used"][time.strftime("%Y-%m-%d")]=10**15;json.dump(b,open(p,"w"))'
"$DISKM" govern --mode observe >/dev/null 2>&1
assert_eq "$(dm)" "31 1024" "higher same-day value replaced by the df used bytes"

echo "== 2. BLACK with no artifact_verdict.sh in the running tree: kickstart blocked"
fresh_state black_missing; fake_df 25
tree_with_verdict "$T/tree_missing" fail
mv "$T/tree_missing/scripts/lib/artifact_verdict.sh" "$T/tree_missing/disabled-verdict.sh"
out=$(python3 "$T/tree_missing/scripts/disk_budget.py" --govern --mode observe 2>&1); rc=$?
assert_eq "$rc" 0 "BLACK tick rc"
assert_eq "$(budget zone)" BLACK "zone BLACK written"
assert_eq "$(kicks)" 0 "launchctl never called"
[[ "$out" == *kickstart_blocked:c14_missing* ]] && ok "stdout says kickstart_blocked:c14_missing" || bad "missing blocked line: $out"
events | grep -q '"event": "kickstart_blocked:c14_missing"' && ok "blocked event recorded" || bad "no blocked event"

echo "== 3. BLACK with a failing C14 self-test: kickstart blocked"
fresh_state black_fail; fake_df 25; tree_with_verdict "$T/tree_fail" fail
python3 "$T/tree_fail/scripts/disk_budget.py" --govern --mode observe >/dev/null 2>&1
assert_eq "$(kicks)" 0 "launchctl never called on failing self-test"
events | grep -q 'kickstart_blocked:c14_missing' && ok "blocked event recorded" || bad "no blocked event"

echo "== 4. BLACK with C14 self-test ok: kickstart exactly once, zone written first"
fresh_state black_ok; fake_df 25; tree_with_verdict "$T/tree_ok" ok
python3 "$T/tree_ok/scripts/disk_budget.py" --govern --mode observe >/dev/null 2>&1
assert_eq "$(kicks)" 1 "launchctl called exactly once"
assert_eq "$(cat "$KICKS")" "kickstart gui/$(id -u)/com.jleechanorg.disk-magician-pressure-sweep zone=BLACK" "kickstart target, zone already BLACK"
events | grep -q '"event": "govern_emergency"' && ok "govern_emergency recorded" || bad "no govern_emergency event"

echo "== 5. FLOOR (5 GiB free): floor_breach recorded, files valid"
fresh_state floor; fake_df 5
python3 "$T/tree_missing/scripts/disk_budget.py" --govern --mode observe >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "FLOOR tick rc"
assert_eq "$(budget zone)" FLOOR "zone FLOOR"
events | grep -q '"event": "floor_breach"' && ok "floor_breach event" || bad "no floor_breach event"
assert_eq "$(kicks)" 0 "FLOOR without C14 never kickstarts"
events | python3 -c 'import json,sys;[json.loads(l) for l in sys.stdin]' && ok "events.jsonl parses" || bad "events.jsonl corrupt"

echo "== 6. Overlapping tick: skipped_tick_lock, budget.json untouched"
fresh_state overlap; fake_df 150
python3 -c 'import fcntl,sys,time;f=open(sys.argv[1],"a");fcntl.flock(f,fcntl.LOCK_EX);open(sys.argv[2],"w").close();time.sleep(30)' \
  "$DISK_MAGICIAN_STATE_DIR/govern.lock" "$T/held" & holder=$!
for _ in $(seq 50); do [[ -f "$T/held" ]] && break; sleep 0.1; done
out=$("$DISKM" govern --mode observe 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
assert_eq "$rc" 0 "overlapping tick rc"
[[ "$out" == *skipped_tick_lock* ]] && ok "skipped_tick_lock printed" || bad "no skipped_tick_lock: $out"
[[ ! -e "$DISK_MAGICIAN_STATE_DIR/budget.json" ]] && ok "no budget.json written" || bad "budget.json written under held lock"

echo "== 7. Stale lock from a dead pid is taken over"
fresh_state stale; fake_df 150
echo 999999 > "$DISK_MAGICIAN_STATE_DIR/govern.lock"
"$DISKM" govern --mode observe >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 "tick after stale lock rc"
assert_eq "$(budget zone)" GREEN "zone written after takeover"

echo "== 8. Act mode writes its observation then blocks before dispatch until C14 is complete"
fresh_state act; fake_df 25
act_output=$(python3 "$T/tree_fail/scripts/disk_budget.py" --govern --mode act 2>&1); rc=$?
assert_eq "$rc" 0 "--mode act rc"
[[ -e "$DISK_MAGICIAN_STATE_DIR/budget.json" ]] && ok "act records zone" || bad "act failed to record zone"
[[ "$act_output" == *activation_blocked:c14_incomplete* ]] && ok "C14 gate blocks adapters" || bad "act did not report C14 gate: $act_output"
[[ ! -e "$DISK_MAGICIAN_STATE_DIR/govern_sched.json" ]] && ok "blocked act starts no scheduler" || bad "blocked act wrote scheduler state"
python3 - "$DISK_MAGICIAN_STATE_DIR/receipts" <<'PY' && ok "blocked act records skip receipts only" || bad "blocked act receipt state wrong"
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
files=list(p.glob("govern_*.json"))
assert files
for f in files:
 d=json.loads(f.read_text()); assert d["last_terminal"]["outcome"] == "blocked_safety", f
assert not list(p.glob("cleanup_*.json"))
PY

echo "== 9. df failure: exit 3, previous budget.json kept"
fresh_state dffail; fake_df 150
"$DISKM" govern --mode observe >/dev/null 2>&1
fake_df fail
"$DISKM" govern --mode observe >/dev/null 2>&1; rc=$?
assert_eq "$rc" 3 "df failure rc"
assert_eq "$(budget zone)" GREEN "previous zone kept"

echo "== 10. Write error: exit 3, previous budget.json parseable"
fresh_state werr; fake_df 150
"$DISKM" govern --mode observe >/dev/null 2>&1
fake_df 25
chmod 555 "$DISK_MAGICIAN_STATE_DIR"
"$DISKM" govern --mode observe >/dev/null 2>&1; rc=$?
chmod 755 "$DISK_MAGICIAN_STATE_DIR"
assert_eq "$rc" 3 "unwritable state dir rc"
assert_eq "$(budget zone)" GREEN "previous budget.json intact"

echo "== 11. Template: 600 s gated act tick through packaged diskm"
P="$REPO_ROOT/launchd/com.jleechanorg.disk-magician-govern.plist.template"
if [[ -f "$P" ]] && plutil -lint "$P" >/dev/null 2>&1; then ok "template lints"; else bad "template missing or invalid"; fi
python3 - "$P" <<'PY' && ok "template args and interval" || bad "template args/interval wrong"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
assert d["ProgramArguments"] == ["@HOME@/.local/bin/diskm", "govern", "--mode", "act"], d["ProgramArguments"]
assert d["StartInterval"] == 600 and d["Label"] == "com.jleechanorg.disk-magician-govern"
PY

echo "== 12. Template: daily 03:00 measure job through packaged diskm"
M="$REPO_ROOT/launchd/com.jleechanorg.disk-magician-govern-measure.plist.template"
if [[ -f "$M" ]] && plutil -lint "$M" >/dev/null 2>&1; then ok "measure template lints"; else bad "measure template missing or invalid"; fi
python3 - "$M" <<'PY' && ok "measure template args and 03:00 calendar" || bad "measure template args/calendar wrong"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
assert d["Label"] == "com.jleechanorg.disk-magician-govern-measure", d["Label"]
assert d["ProgramArguments"] == ["@HOME@/.local/bin/diskm", "govern", "--daily-measure"], d["ProgramArguments"]
assert d["StartCalendarInterval"] == {"Hour": 3, "Minute": 0}, d["StartCalendarInterval"]
PY
if grep -q 'com.jleechanorg.disk-magician-\*\.plist\.template' "$REPO_ROOT/scripts/install_launchd_sweepers.sh" \
   || grep -q 'com.jleechanorg.disk-magician-\*.plist.template' "$REPO_ROOT/scripts/install_launchd_sweepers.sh"; then
  ok "installer discovers govern-measure template"
else
  bad "installer does not auto-discover the govern-measure template"
fi

echo
echo "test_govern.sh: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
