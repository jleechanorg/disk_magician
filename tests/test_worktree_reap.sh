#!/usr/bin/env bash
# Isolated Task 5 integration tests; every removal targets a temporary fixture.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/worktree_reap.sh"
TMP="$(cd "$(mktemp -d /tmp/worktree-reap-test.XXXXXX)" && pwd -P)"
trap '[[ "$TMP" == /tmp/worktree-reap-test.* || "$TMP" == /private/tmp/worktree-reap-test.* ]] && rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() { local label="$1"; shift; if "$@"; then echo "PASS: $label"; PASS=$((PASS+1)); else echo "FAIL: $label"; FAIL=$((FAIL+1)); fi; }
export HOME="$TMP/home" STANDARD_WORKTREE_ROOT="$TMP/worktrees" DISK_MAGICIAN_STATE_DIR="$TMP/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
export FAKE_PS_DIR="$TMP/ps" DISK_MAGICIAN_PS_BIN="$TMP/bin/ps"
export FAKE_FETCH_LOG="$TMP/fetch.log" FAKE_LSOF_FIXTURE="$TMP/lsof" REAL_GIT="$(command -v git)"
export FAKE_DF_STATE="$TMP/df-count"
mkdir -p "$HOME" "$TMP/bin" "$FAKE_PS_DIR/comm" "$FAKE_PS_DIR/lstart" "$FAKE_PS_DIR/args" "$FAKE_PS_DIR/fail"
cat > "$TMP/bin/ps" <<'MOCK'
#!/bin/bash
pid= spec=
while [[ $# -gt 0 ]]; do case "$1" in -p) pid="$2"; shift 2;; -o) spec="$2"; shift 2;; *) shift;; esac; done
if [[ -f "$FAKE_PS_DIR/fail/$pid" ]]; then read -r rc msg < "$FAKE_PS_DIR/fail/$pid"; [[ -z "${msg:-}" ]] || echo "$msg" >&2; exit "$rc"; fi
case "$spec" in lstart=) cat "$FAKE_PS_DIR/lstart/$pid" 2>/dev/null;; args=) cat "$FAKE_PS_DIR/args/$pid" 2>/dev/null;; ppid=,comm=) cat "$FAKE_PS_DIR/comm/$pid" 2>/dev/null;; pid=) /bin/kill -0 "$pid" 2>/dev/null;; *) exit 1;; esac
MOCK
cat > "$TMP/bin/lsof" <<'MOCK'
#!/bin/bash
cat "$FAKE_LSOF_FIXTURE"
MOCK
cat > "$TMP/bin/git" <<'MOCK'
#!/bin/bash
for arg in "$@"; do
 if [[ "$arg" == fetch ]]; then
  printf '%s|%s\n' "${GIT_TERMINAL_PROMPT:-}" "$*" >> "$FAKE_FETCH_LOG"
  [[ "${FAIL_FETCH:-0}" == 1 ]] && exit 1
 fi
done
if [[ "$*" == *'remote get-url origin'* && "${GH_HEAD:-}" != '' ]]; then echo https://github.com/example/repo.git; exit; fi
exec "$REAL_GIT" "$@"
MOCK
cat > "$TMP/bin/gh" <<'MOCK'
#!/bin/bash
[[ "$1" == api ]] && exit 1
[[ -n "${GH_HEAD:-}" ]] && echo "$GH_HEAD"
exit 0
MOCK
cat > "$TMP/bin/timeout" <<'MOCK'
#!/bin/bash
shift
exec "$@"
MOCK
cat > "$TMP/bin/df" <<'MOCK'
#!/bin/bash
n=0
[[ ! -s "$FAKE_DF_STATE" ]] || read -r n < "$FAKE_DF_STATE"
echo $((n+1)) > "$FAKE_DF_STATE"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
printf '/dev/test 2000000 1000000 %s 50%% /\n' "$((1000000+n*${FAKE_DF_DELTA_KB:-0}))"
MOCK
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
printf 'p999999\nfcwd\nn/\n' > "$FAKE_LSOF_FIXTURE"
python3 -c 'from datetime import datetime,timezone; print(datetime.fromtimestamp(1760000000,timezone.utc).strftime("%a %b %d %H:%M:%S %Y"))' > "$FAKE_PS_DIR/lstart/400"
printf '/usr/bin/claude\n' > "$FAKE_PS_DIR/args/400"
printf '1 claude\n' > "$FAKE_PS_DIR/comm/400"
printf '1\n' > "$FAKE_PS_DIR/fail/401"
printf '2\n' > "$FAKE_PS_DIR/fail/402"
source "$ROOT/scripts/lib/worktree_lease.sh"
git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null
printf 'base\n' > "$TMP/repo/file"
printf '.env\ndata/\n' > "$TMP/repo/.gitignore"
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -qm base
git -C "$TMP/repo" push -q origin HEAD:main
N=0
age() { python3 - "$WT" "${1:-2400}" <<'PY'
import os,sys,time
old=time.time()-int(sys.argv[2])
for base,dirs,files in os.walk(sys.argv[1]):
 for name in files: os.utime(os.path.join(base,name),(old,old))
PY
}
new() {
 N=$((N+1)); WT="$STANDARD_WORKTREE_ROOT/repo/c$N"; git -C "$TMP/repo" worktree add -qb "worktree-c$N" "$WT" origin/main
 lease_write "$WT" "$TMP/repo" "worktree-c$N" test
 LF="$(lease_path_for "$WT")"
 edit 'd["owner"]={"pid":401,"start_epoch":1760000000,"comm":"claude"}; d["owner_dead_seen_at"]=time.time()-2400'
 age
}
edit() { python3 - "$LF" "$1" <<'PY'
import json,sys,time,datetime
p=sys.argv[1]; d=json.load(open(p)); exec(sys.argv[2]); json.dump(d,open(p,'w'))
PY
}
field() { python3 - "$LF" "$1" <<'PY'
import json,sys
try: print(eval(sys.argv[2],{'d':json.load(open(sys.argv[1]))}))
except Exception: print('ERR')
PY
}
RUNS=0
run() {
 local before=0 after=0
 [[ ! -f "$FAKE_FETCH_LOG" ]] || before="$(wc -l < "$FAKE_FETCH_LOG")"
 : > "$FAKE_DF_STATE"
 bash "$SCRIPT" "$@" > "$TMP/run.log" 2>&1; RC=$?
 [[ ! -f "$FAKE_FETCH_LOG" ]] || after="$(wc -l < "$FAKE_FETCH_LOG")"
 RUN_FETCHES=$((after-before)); RUNS=$((RUNS+1))
 cp "$TMP/run.log" "$TMP/run-$RUNS.log"
 check "run $RUNS exits zero" test "$RC" = 0
 [[ "$RC" == 0 ]] || cat "$TMP/run.log"
}
verdict() { local actual; actual="$(field 'd.get("last_verdict")')"; check "$1 (actual=$actual expected=$2)" test "$actual" = "$2"; }
receipt() { python3 - "$DISK_MAGICIAN_STATE_DIR/receipts/worktree_reap.json" "$1" <<'PY'
import json,sys
try: print(eval(sys.argv[2],{'d':json.load(open(sys.argv[1]))['last_terminal']}))
except Exception: print('ERR')
PY
}
park() {
 [[ ! -f "$LF" ]] || edit 'd["owner"]=None'
 mkdir -p "$TMP/parked"
 # Move completed fixtures, including their dirty contents, out of discovery.
 # Locked fixtures stay put. The reaper prunes the old-path lease next run.
 [[ ! -d "$WT" ]] || git -C "$TMP/repo" worktree move "$WT" "$TMP/parked/c$N" 2>/dev/null || true
}
if [[ ! -f "$SCRIPT" ]]; then bash "$SCRIPT"; echo 'RED: scripts/worktree_reap.sh missing'; exit 1; fi
# removal_activation_ok is covered by test_removal_activation.sh; here it is a switch file.
cp -R "$ROOT/scripts" "$TMP/root-scripts"; SCRIPT="$TMP/root-scripts/worktree_reap.sh"
echo 'removal_activation_ok() { [[ -f "$DISK_MAGICIAN_STATE_DIR/test_gate_open" ]] || { echo activation_blocked:test; return 1; }; }' > "$TMP/root-scripts/lib/removal_activation.sh"
new; rm "$LF"; run; check 'unleased adopts null owner' test "$(field 'd["creator"] == "adopt" and d["owner"] is None')" = True
new; edit 'd["owner"]["pid"]=400; d["last_verdict"]="sentinel"'; run; verdict 'alive unchanged' sentinel; check 'alive present' test -d "$WT"; park
new; run; verdict 'dead nominate' remove; check 'nominate retains' test -d "$WT"; park
new; run --mode remove; verdict 'unapproved records verdict' remove; check 'unapproved message' grep -q 'remove mode not approved' "$TMP/run.log"; check 'unapproved retains' test -d "$WT"; park
mkdir -p "$DISK_MAGICIAN_STATE_DIR"; touch "$DISK_MAGICIAN_STATE_DIR/worktree_reap.remove_approved"
new; run --mode remove; check 'legacy marker, gate closed: nominate only' grep -q 'remove mode not approved' "$TMP/run.log"; check 'legacy marker alone retains' test -d "$WT"; park
touch "$DISK_MAGICIAN_STATE_DIR/test_gate_open"
echo "== reuse lease claim cannot race reaper's dead-owner update =="
new
mkdir -p "$TMP/pythonhook"
cat > "$TMP/pythonhook/sitecustomize.py" <<'PYHOOK'
import os, time
_replace = os.replace
def replace(src, dst, *args, **kwargs):
    if (os.path.basename(src).startswith('.reap-') and
        os.path.realpath(dst) == os.path.realpath(os.environ.get('RACE_LEASE','')) and
        os.path.exists(os.environ.get('RACE_ARM',''))):
        open(os.environ['RACE_READY'],'w').write(str(src))
        deadline=time.time()+20
        while not os.path.exists(os.environ['RACE_RELEASE']):
            if time.time()>deadline: raise TimeoutError('test release timeout')
            time.sleep(.01)
    return _replace(src,dst,*args,**kwargs)
os.replace=replace
PYHOOK
RACE_ARM="$TMP/race-arm"; RACE_READY="$TMP/race-ready"; RACE_RELEASE="$TMP/race-release"
export RACE_ARM RACE_READY RACE_RELEASE RACE_LEASE="$LF"
touch "$RACE_ARM"
PYTHONPATH="$TMP/pythonhook${PYTHONPATH:+:$PYTHONPATH}" bash "$SCRIPT" --mode nominate > "$TMP/race-reaper.log" 2>&1 & reaper_pid=$!
for _ in $(seq 1 1000); do [[ -e "$RACE_READY" ]] && break; sleep .01; done
check 'reaper update pauses at atomic replace' test -e "$RACE_READY"
RACE_HASH="$(python3 - "$LF" <<'PYHASH'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PYHASH
)"
RACE_BRANCH="worktree-c$N"
RACE_TIP="$(git -C "$TMP/repo" rev-parse "refs/heads/$RACE_BRANCH")"
if lease_claim_reuse "$LF" "$RACE_HASH" "$RACE_BRANCH" "$RACE_TIP" $'401\t1760000000\tclaude'; then check 'claim must not enter during reaper mutation' false; else check 'claim waits/fails while reaper owns shared lease lock' true; fi
touch "$RACE_RELEASE"
wait "$reaper_pid"
RACE_HASH="$(python3 - "$LF" <<'PYHASH'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PYHASH
)"
if lease_claim_reuse "$LF" "$RACE_HASH" "$RACE_BRANCH" "$RACE_TIP" $'401\t1760000000\tclaude'; then check 'claim succeeds after serialized reaper update' true; else check 'claim remains blocked after reaper completed' false; fi
check 'pending claim survives the reaper update' test "$(field 'd.get("reuse",{}).get("state")')" = pending
unset PYTHONPATH RACE_ARM RACE_READY RACE_RELEASE RACE_LEASE
cat > "$TMP/reuse-lock-hook" <<'HOOK'
#!/usr/bin/env bash
source "$TEST_LEASE_LIB"
file="$1"
hash="$(shasum -a 256 "$file" | awk '{print $1}')"
if lease_claim_reuse "$file" "$hash" hook/branch deadbeef $'401\t1760000000\tclaude'; then
    echo raced > "$TEST_HOOK_RESULT"
else
    echo blocked > "$TEST_HOOK_RESULT"
fi
HOOK
chmod +x "$TMP/reuse-lock-hook"
export TEST_LEASE_LIB="$ROOT/scripts/lib/worktree_lease.sh" TEST_HOOK_RESULT="$TMP/reuse-lock-result"
export DISK_MAGICIAN_REAP_AFTER_REMOVE_LOCK_HOOK="$TMP/reuse-lock-hook"
new; run --mode remove
unset DISK_MAGICIAN_REAP_AFTER_REMOVE_LOCK_HOOK
check 'reuse claim cannot start inside final removal boundary' grep -qx blocked "$TEST_HOOK_RESULT"
check 'approved removes worktree' test ! -e "$WT"; check 'removal deletes lease' test ! -e "$LF"
new; mkdir "$LF.reuse-lock"; run --mode remove
check 'pre-existing reuse lock preserves candidate' test -d "$WT"
check 'pre-existing reuse lock leaves lease untouched' test "$(field 'd.get("branch")')" = "worktree-c$N"
rmdir "$LF.reuse-lock"
for mode in nominate remove; do new; echo changed >> "$WT/file"; age; run --mode "$mode"; verdict "dirty $mode" kept:dirty; check 'dirty present' test -d "$WT"; park; done
new; age 300; run; verdict 'quiet five minutes' kept:recent-activity; park
for mode in nominate remove; do new; edit 'd["owner"]["pid"]=400; d["created_epoch"]=int(time.time())-30*3600-86400'; age 25200; run --mode "$mode"; verdict "TTL expired 30h, owner alive $mode" kept:expired_owner_alive; check "TTL expired owner alive present $mode" test -d "$WT"; park; done
for quiet in 2400 300; do new; edit "d['owner']['pid']=400; d['released_at']=datetime.datetime.fromtimestamp(time.time()-$quiet,datetime.timezone.utc).isoformat()"; age 7200; run; if [[ "$quiet" == 2400 ]]; then verdict 'released quiet' remove; else verdict 'released recent' kept:recent-activity; fi; park; done
new; edit 'd.pop("owner_dead_seen_at",None)'; age 7200; run; verdict 'first dead waits' kept:recent-activity; check 'first death recorded' test "$(field 'bool(d.get("owner_dead_seen_at"))')" = True; edit 'd["owner_dead_seen_at"]=time.time()-1860'; run; verdict 'next run after quiet' remove; park
new; edit 'd["owner"]=None'; run --mode remove; check 'null owner never removed' test -d "$WT"
new; edit 'd["pending"]=True; d["reuse"]={"state":"pending","old_branch":"old","old_tip":"abc"}'; run --mode remove; check 'pending reuse claim is skipped' grep -q 'kept:pending' "$TMP/run.log"; check 'pending reuse path preserved' test -d "$WT"; check 'pending reuse marker preserved' test "$(field 'd["reuse"]["state"]')" = pending; park
new; edit 'd["reuse"]={"state":"reuse_incomplete","old_branch":"old","old_tip":"abc"}'; run --mode remove; check 'incomplete reuse is skipped' grep -q 'kept:reuse_incomplete' "$TMP/run.log"; check 'incomplete reuse path preserved' test -d "$WT"; park
new; edit 'd["reuse"]={"state":"reuse_incomplete","old_branch":"old","old_tip":"abc"}'; git -C "$TMP/repo" worktree remove "$WT"; run; check 'missing incomplete claim remains available for recovery' test -f "$LF"; check 'missing incomplete claim state retained' test "$(field 'd["reuse"]["state"]')" = reuse_incomplete
new; git -C "$WT" commit -q --allow-empty -m fork; git -C "$WT" update-ref refs/remotes/fork/test HEAD; age; run; verdict 'fork only not pushed' kept:not-pushed; park
new; git -C "$WT" commit -q --allow-empty -m merged; age; export GH_HEAD="$(git -C "$WT" rev-parse HEAD)"; run; verdict 'merged PR deleted branch' remove; unset GH_HEAD; park
for offset in 0 -30 -120 1; do new; edit "d['pending']=True; d['creator']='guard'; d['owner']['pid']=400; d['created_epoch']=d['admin_birth_epoch']+$offset; d['admin_id']=None; d['admin_birth_epoch']=None"; run; if [[ "$offset" == 0 || "$offset" == -30 ]]; then check "pending promotion offset $offset" test "$(field 'd["creator"] == "guard" and d["owner"]["pid"] == 400 and not d["pending"]')" = True; else check "pending stale offset $offset" test "$(field 'd["creator"] == "adopt" and d["owner"] is None')" = True; fi; park; done
new; saved="$TMP/saved-lease"; cp "$LF" "$saved"; git -C "$TMP/repo" worktree remove "$WT"; git -C "$TMP/repo" worktree add -qb reuse "$WT" origin/main; cp "$saved" "$LF"; edit 'd["admin_id"]="old-incarnation"'; run --mode remove; check 'path reuse adopted' test "$(field 'd["owner"] is None and d["creator"] == "adopt"')" = True; check 'reuse preserved' test -d "$WT"
cat > "$TMP/inject" <<'HOOK'
#!/bin/bash
if [[ "$1" == "$INJECT_WT" ]]; then mkdir -p "$1/data"; touch "$1/$INJECT_FILE"; python3 - "$1/$INJECT_FILE" <<'PY'
import os,sys,time
os.utime(sys.argv[1],(time.time()-4000,)*2)
PY
fi
HOOK
chmod +x "$TMP/inject"
for injected in .env data/notes.db; do new; export INJECT_WT="$WT" INJECT_FILE="$injected" DISK_MAGICIAN_REAP_BEFORE_REMOVE_HOOK="$TMP/inject"; run --mode remove; if [[ "$injected" == .env ]]; then verdict 'final secret recheck' kept:hidden-state; else verdict 'final ignored data recheck' kept:ignored-data; fi; check 'injected retained' test -f "$WT/$injected"; unset DISK_MAGICIAN_REAP_BEFORE_REMOVE_HOOK; park; done
mkdir "$TMP/minbin"
for tool in bash python3 git date mkdir cat cp rm rmdir stat awk sed grep head cut shasum dirname find sort mktemp tr wc env lsof; do target="$(command -v "$tool")"; [[ -z "$target" ]] || ln -s "$target" "$TMP/minbin/$tool"; done
new; before="$(wc -l < "$FAKE_FETCH_LOG")"; PATH="$TMP/minbin" run; verdict 'missing timeout blocks fetch' kept:remote-unverified; check 'no unbounded fetch' test "$(wc -l < "$FAKE_FETCH_LOG")" = "$before"; check 'missing gh logged' grep -q 'missing tool: gh' "$TMP/run.log"; check 'missing gh counted' test "$(receipt 'd["candidates"]["gh_failed"] > 0')" = True; park
new; edit 'd["owner"]["pid"]=402'; run --mode remove; check 'unknown owner retained' test -d "$WT"; park
# Owner proof (governor T12): liveness is pid + start epoch only.
sleep 300 & stopped=$!
# Stop only after exec: a pre-exec child is bash and would run the EXIT trap.
for ((i=0;i<100;i++)); do [[ "$(/bin/ps -p "$stopped" -o comm=)" == *sleep ]] && break; sleep .05; done; kill -STOP "$stopped"
LC_ALL=C TZ=UTC /bin/ps -p "$stopped" -o lstart= > "$FAKE_PS_DIR/lstart/$stopped"; printf 'sleep 300\n' > "$FAKE_PS_DIR/args/$stopped"
stopped_ep="$(_lease_lstart_to_epoch "$(cat "$FAKE_PS_DIR/lstart/$stopped")")"
new; edit "d['owner']={'pid':$stopped,'start_epoch':$stopped_ep,'comm':'sleep'}; d['last_verdict']='sentinel'"; age 7200; run --mode remove; verdict 'SIGSTOPped owner kept' sentinel; check 'SIGSTOPped owner present' test -d "$WT"; kill -CONT "$stopped"; kill "$stopped"; wait "$stopped" 2>/dev/null; park
new; edit 'd["owner"]={"pid":400,"start_epoch":1760000000-3600,"comm":"claude"}'; run; verdict 'pid reused (other start epoch) reads dead' remove; park
new; edit 'd["owner"]["pid"]=402; d["last_verdict"]="sentinel"'; run --mode remove; verdict 'ps error is unknown, kept' sentinel; check 'ps error present' test -d "$WT"; park
new; edit 'd["owner"]={"pid":400,"start_epoch":1760000000-3600,"comm":"claude"}'; (cd "$WT" && sleep 30) & child=$!; printf 'p%s\nfcwd\nn%s\n' "$child" "$WT" > "$FAKE_LSOF_FIXTURE"; run --mode remove; verdict 'dead owner, live child cwd kept' kept:live-cwd; check 'child cwd present' test -d "$WT"; kill "$child"; wait "$child" 2>/dev/null; printf 'p999999\nfcwd\nn/\n' > "$FAKE_LSOF_FIXTURE"; park
new; git -C "$TMP/repo" worktree lock "$WT"; run; verdict 'locked' kept:locked; park
new; export FAIL_FETCH=1; run; verdict 'fetch failure' kept:remote-unverified; unset FAIL_FETCH; park
new; export DISK_MAGICIAN_SAFETY_FILE="$TMP/safety.local.json"; printf '{"never_delete":["%s"]}\n' "$WT" > "$DISK_MAGICIAN_SAFETY_FILE"; run; verdict 'safety local' kept:safety-local; unset DISK_MAGICIAN_SAFETY_FILE; park
new; (cd "$WT" && sleep 30) & livepid=$!; printf 'p%s\nfcwd\nn%s\n' "$livepid" "$WT" > "$FAKE_LSOF_FIXTURE"; run; verdict 'live cwd' kept:live-cwd; kill "$livepid"; wait "$livepid" 2>/dev/null || true; printf 'p999999\nfcwd\nn/\n' > "$FAKE_LSOF_FIXTURE"; park
new; echo '{broken' > "$LF"; corrupt="$LF"; new; run; check 'corrupt logged' grep -q 'kept:lease-unreadable' "$TMP/run.log"; verdict 'other lease processed' remove; rm "$corrupt"; park
new; git -C "$TMP/repo" worktree remove "$WT"; run; check 'nonexistent lease pruned' test ! -e "$LF"; check 'prune exit zero' test "$RC" = 0
LF="$(lease_path_for "$STANDARD_WORKTREE_ROOT/missing")"; lease_write_pending "$STANDARD_WORKTREE_ROOT/missing" $'401\t1760000000\tclaude'; edit 'd["created_epoch"]=int(time.time())-7201'; run; check 'old pending pruned' test ! -e "$LF"
mkdir "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock"; echo 401 > "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock/pid"; echo 1 > "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock/acquired_at"; run; check 'stale lock reclaimed' test ! -d "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock"; check 'stale proceeds' test "$(receipt 'd["outcome"]')" = success
mkdir "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock"; echo $$ > "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock/pid"; date +%s > "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock/acquired_at"; run; check 'second lock exit zero' test "$RC" = 0; check 'second lock skip' grep -q skipped_lock "$TMP/run.log"; rm "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock/pid" "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock/acquired_at"; rmdir "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock"
cat > "$TMP/pause" <<'HOOK'
#!/bin/bash
touch "$HOOK_SEEN"
sleep 2
HOOK
chmod +x "$TMP/pause"
new; export DISK_MAGICIAN_REAP_CANDIDATE_HOOK="$TMP/pause" HOOK_SEEN="$TMP/hook-seen"; bash "$SCRIPT" > "$TMP/term.log" 2>&1 & reaper=$!
for ((i=0;i<600;i++)); do [[ -f "$HOOK_SEEN" ]] && break; sleep .1; done
check 'TERM reaches candidate loop' test -f "$HOOK_SEEN"
kill -TERM "$reaper"; wait "$reaper" 2>/dev/null || true; check 'TERM releases lock' test ! -d "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock"; unset DISK_MAGICIAN_REAP_CANDIDATE_HOOK; run; check 'next after TERM proceeds' test "$(receipt 'd["outcome"]')" = success; park
new; new; new
# Freeze the deadline clock through adoption, then advance at the first candidate.
# This proves partial progress rather than timing out before any candidate.
export REAL_DATE="$(command -v date)" REAP_CLOCK="$(date +%s)"
cat > "$TMP/bin/date" <<'MOCK'
#!/bin/bash
if [[ "${REAP_CLOCK:-}" != '' && "$*" == +%s ]]; then
 if [[ -f "$HOOK_SEEN" ]]; then echo $((REAP_CLOCK+2)); else echo "$REAP_CLOCK"; fi
else exec "$REAL_DATE" "$@"; fi
MOCK
chmod +x "$TMP/bin/date"
rm -f "$HOOK_SEEN"
export DISK_MAGICIAN_REAP_CANDIDATE_HOOK="$TMP/pause"
run --deadline-seconds 1
check 'deadline partial' test "$(receipt 'd["outcome"]')" = partial
check 'deadline processed a candidate' test "$(receipt 'd["candidates"].get("remove",0)')" = 1
check 'deadline releases lock' test ! -d "$DISK_MAGICIAN_STATE_DIR/worktree_reap.lock"
unset DISK_MAGICIAN_REAP_CANDIDATE_HOOK REAP_CLOCK
run; check 'receipt success' test "$(receipt 'd["outcome"]')" = success; check 'receipt counters' test "$(receipt 'all(k in d["candidates"] for k in ("fetch_ok","fetch_failed","gh_ok","gh_failed"))')" = True; check 'receipt freed bytes' test "$(receipt 'isinstance(d["postcondition"]["freed_bytes"],int)')" = True
check 'one fetch per repository for three candidates' test "$RUN_FETCHES" = 1
export FAKE_DF_DELTA_KB=128
run
check 'freed bytes measured from df delta' test "$(receipt 'd["postcondition"]["freed_bytes"]')" = 131072
export FAKE_DF_DELTA_KB=-16
run
check 'growth records raw negative df delta' test "$(receipt 'd["postcondition"]["df_delta_bytes"]')" = -16384
check 'growth cannot report reclaimed bytes' test "$(receipt 'd["postcondition"]["freed_bytes"]')" = 0
unset FAKE_DF_DELTA_KB
check 'fetch disables interactive gc maintenance' grep -q '0|.*-c gc.auto=0 -c maintenance.auto=false fetch --quiet --prune origin' "$FAKE_FETCH_LOG"
export DISK_MAGICIAN_REAP_MODE=remove; new; run --mode nominate; check 'CLI overrides environment' test -d "$WT"; unset DISK_MAGICIAN_REAP_MODE; park
printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
