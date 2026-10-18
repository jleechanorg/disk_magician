#!/usr/bin/env bash
# Lease-driven worktree reaper. Nomination is the default; removal is opt-in.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/worktree_remove_hook.sh"
source "$SCRIPT_DIR/lib/worktree_merged_pr.sh"
STATE="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
LOCK="$STATE/worktree_reap.lock"
MODE="${DISK_MAGICIAN_REAP_MODE:-nominate}"
DEADLINE=1500
QUIET="${REAP_QUIET_MINUTES:-30}"
RELEASE_QUIET="${REAP_RELEASED_QUIET_MINUTES:-30}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:-}"; [[ $# -ge 2 ]] || exit 2; shift 2 ;;
        --deadline-seconds) DEADLINE="${2:-}"; [[ $# -ge 2 ]] || exit 2; shift 2 ;;
        *) echo "Usage: worktree_reap.sh [--mode nominate|remove] [--deadline-seconds N]" >&2; exit 2 ;;
    esac
done
[[ "$MODE" == nominate || "$MODE" == remove ]] || exit 2
[[ "$DEADLINE" =~ ^[0-9]+$ && "$QUIET" =~ ^[0-9]+$ && "$RELEASE_QUIET" =~ ^[0-9]+$ ]] || exit 2
log() { printf 'worktree_reap: %s\n' "$*"; }
# The shared removal helper otherwise logs to HOME rather than the state override.
wrh_log() { log "$*"; }

# The existing receipt helper owns locking, validation and atomic persistence.
# Task 5 adds its deadline outcome without changing the shared helper's API.
receipt() {
    python3 - "$SCRIPT_DIR" "$@" <<'PY'
import sys
sys.path.insert(0,sys.argv.pop(1))
import job_receipt
job_receipt.TERMINAL_OUTCOMES.add('partial')
job_receipt.ALL_ALLOWED_OUTCOMES.add('partial')
sys.exit(job_receipt.main())
PY
}
lock_dead() {
    local pid="$1" rc err out
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    err="$(mktemp)" || return 1
    out="$(_lease_ps -p "$pid" -o pid= 2>"$err")"; rc=$?
    [[ "$rc" == 1 && ! -s "$err" && -z "$out" ]]; rc=$?
    rm -f "$err"
    return "$rc"
}
acquire_lock() {
    local pid stamp now gate="$LOCK.reclaim_gate"
    if ! mkdir "$LOCK" 2>/dev/null; then
        pid="$(cat "$LOCK/pid" 2>/dev/null)"; stamp="$(cat "$LOCK/acquired_at" 2>/dev/null)"; now="$(date +%s)"
        [[ "$stamp" =~ ^[0-9]+$ ]] || return 1
        (( now-stamp > 3600 )) && lock_dead "$pid" || return 1
        mkdir "$gate" 2>/dev/null || return 1
        pid="$(cat "$LOCK/pid" 2>/dev/null)"; stamp="$(cat "$LOCK/acquired_at" 2>/dev/null)"
        if [[ "$stamp" =~ ^[0-9]+$ ]] && (( now-stamp > 3600 )) && lock_dead "$pid"; then
            # Only our two known files can be reclaimed; unexpected contents keep.
            rm -f "$LOCK/pid" "$LOCK/acquired_at"
            rmdir "$LOCK" 2>/dev/null || { rmdir "$gate"; return 1; }
            mkdir "$LOCK" 2>/dev/null || { rmdir "$gate"; return 1; }
            log 'reclaimed stale lock' >&2
        else
            rmdir "$gate"; return 1
        fi
        rmdir "$gate"
    fi
    echo "$$" > "$LOCK/pid"
    date +%s > "$LOCK/acquired_at"
}
mkdir -p "$STATE" "$(lease_dir)"
if ! acquire_lock; then
    log skipped_lock
    receipt finish --job worktree_reap --outcome skipped_lock --reason 'lock held' --lock '{"held":true}'
    exit 0
fi
RUN_TMP=""
cleanup() {
    rm -f "$LOCK/pid" "$LOCK/acquired_at"
    rmdir "$LOCK" 2>/dev/null || true
    [[ -z "$RUN_TMP" ]] || rm -rf "$RUN_TMP"
}
trap cleanup EXIT
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/worktree-reap.XXXXXX")" || exit 1
EVENTS="$RUN_TMP/events"
: > "$EVENTS"
OUTCOME=success
STOP=0
trap 'STOP=1; OUTCOME=partial' TERM INT
START="$(date +%s)"
free_bytes() { df -kP "$STATE" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%.0f\n", $4*1024}'; }
BEFORE="$(free_bytes)"
RUN_ID="$(receipt begin --job worktree_reap --trigger "$MODE")" || exit 1
for tool in git timeout gh; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log "missing tool: $tool"
        [[ "$tool" != gh ]] || echo gh_failed >> "$EVENTS"
    fi
done
if [[ "$MODE" == remove && ! -f "$STATE/worktree_reap.remove_approved" ]]; then
    log 'remove mode not approved'
    MODE=nominate
fi
expired() {
    if (( STOP || $(date +%s)-START >= DEADLINE )); then OUTCOME=partial; return 0; fi
    return 1
}
record() {
    log "$2 $3"
    printf '%s\n' "$3" >> "$EVENTS"
    lease_set_verdict "$1" "$3"
}
# Atomic metadata updates used for promotion, adoption and death observation.
update() {
    python3 - "$@" <<'PY'
import json,os,sys,tempfile,time
path,action,*args=sys.argv[1:]
with open(path) as f: d=json.load(f)
if action=='promote':
    admin,birth,repo,branch=args
    created=d.get('created_epoch')
    if not isinstance(created,int) or not created<=int(birth)<=created+60: sys.exit(1)
    d.update(pending=False,admin_id=admin,admin_birth_epoch=int(birth),repo=repo,branch=branch)
elif action=='dead':
    d.setdefault('owner_dead_seen_at',int(time.time()))
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path),prefix='.reap-')
try:
    with os.fdopen(fd,'w') as f: json.dump(d,f); f.write('\n')
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
}
adopt() {
    local real="$1" repo="$2" branch="$3" admin birth file
    file="$(lease_path_for "$real")"
    # Use the library writer directly so adoption never resolves a live owner.
    IFS=$'\t' read -r admin birth < <(_lease_admin_info "$real")
    _lease_emit_json "$file" "$real" "$repo" "$branch" adopt False - - - "$admin" "$birth" 24
}
registered() {
    git -C "$2" worktree list --porcelain 2>/dev/null |
        awk -v want="worktree $1" 'NR>1 && $0==want {found=1} END {exit !found}'
}
ROOT_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$STANDARD_WORKTREE_ROOT")"
# Discover linked worktrees without traversing their content or following links.
python3 - "$ROOT_REAL" > "$RUN_TMP/paths" <<'PY'
import os,sys
root=sys.argv[1]
for base,dirs,files in os.walk(root):
    if '.git' in files:
        sys.stdout.buffer.write(os.fsencode(base)+b'\0'); dirs[:]=[]
    elif '.git' in dirs: dirs.remove('.git')
PY
while IFS= read -r -d '' real; do
    expired && break
    repo="$(wtn_main_repo "$real")" || continue
    registered "$real" "$repo" || continue
    file="$(lease_path_for "$real")"
    branch="$(git -C "$real" symbolic-ref -q --short HEAD 2>/dev/null)"
    if [[ ! -e "$file" ]]; then adopt "$real" "$repo" "$branch"; continue; fi
    # Invalid JSON is preserved and reported by the owner phase.
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d,dict)' "$file" 2>/dev/null || continue
    if [[ "$(_lease_get "$file" pending)" == True ]]; then
        IFS=$'\t' read -r admin birth < <(_lease_admin_info "$real")
        update "$file" promote "$admin" "$birth" "$repo" "$branch" || adopt "$real" "$repo" "$branch"
    elif ! lease_matches_incarnation "$file"; then
        adopt "$real" "$repo" "$branch"
    fi
done < "$RUN_TMP/paths"

fetch_repo() {
    local repo="$1" key cached
    key="$(printf '%s' "$repo" | shasum -a 256 | cut -c1-16)"
    cached="$RUN_TMP/fetch-$key"
    if [[ ! -f "$cached" ]]; then
        if command -v timeout >/dev/null 2>&1 && GIT_TERMINAL_PROMPT=0 timeout 60s git -C "$repo" -c gc.auto=0 -c maintenance.auto=false fetch --quiet --prune origin; then
            echo ok > "$cached"; echo fetch_ok >> "$EVENTS"
        else
            echo failed > "$cached"; echo fetch_failed >> "$EVENTS"
        fi
    fi
    [[ "$(cat "$cached")" == ok ]]
}
quiet_since() {
    python3 - "$1" "$2" "$3" <<'PY'
import json,sys,time
from datetime import datetime
try:
    d=json.load(open(sys.argv[1])); value=d[sys.argv[2]]
    epoch=float(value) if isinstance(value,(float,int)) else datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()
    sys.exit(0 if time.time()-epoch>=int(sys.argv[3])*60 else 1)
except (OSError,ValueError,KeyError,TypeError): sys.exit(1)
PY
}
verdict_for() {
    local real="$1" repo="$2" quiet="$3" verdict origin
    if git -C "$repo" worktree list --porcelain | awk -v want="worktree $real" '$0==want {found=1;next} /^worktree / {found=0} found && /^locked($| )/ {locked=1} END {exit !locked}'; then
        echo kept:locked; return
    fi
    if ! bash "$SCRIPT_DIR/safety_check.sh" "$real" >/dev/null 2>&1; then echo kept:safety-local; return; fi
    verdict="$(wrh_removal_verdict "$real" "minutes:$quiet" origin-or-merged-pr)"
    # Count merged-PR proof outcomes when origin containment cannot prove HEAD.
    if [[ "$verdict" == remove || "$verdict" == kept:not-pushed ]]; then
        origin="$(git -C "$real" for-each-ref --count=1 --contains HEAD refs/remotes/origin 2>/dev/null)"
        if [[ -z "$origin" ]]; then
            if [[ "$verdict" == remove ]]; then echo gh_ok >> "$EVENTS"; else echo gh_failed >> "$EVENTS"; fi
        fi
    fi
    printf '%s\n' "$verdict"
}
prune_nonexistent_leases() {
    python3 - "$(lease_dir)" <<'PY'
import json,os,sys,time
ldir=sys.argv[1]
now=time.time()
try:
    entries=list(os.scandir(ldir))
except OSError:
    sys.exit(0)
for e in entries:
    if e.name.startswith('.') or not e.name.endswith('.json') or not e.is_file(follow_symlinks=False):
        continue
    p=e.path
    try:
        with open(p) as f: d=json.load(f)
        if not isinstance(d,dict): continue
        target=d.get('path')
        if not isinstance(target,str) or not target or os.path.lexists(target):
            continue
        if d.get('pending') and now-d.get('created_epoch',now)<3600:
            continue
        os.unlink(p)
    except (OSError,ValueError,TypeError,AttributeError):
        pass
PY
}
# Prune nonexistent leases up front so accumulated stale leases do not exhaust the deadline.
prune_nonexistent_leases
# Emit only unreadable leases or existing paths under ROOT_REAL in one Python pass.
python3 - "$(lease_dir)" "$ROOT_REAL" > "$RUN_TMP/leases" <<'PY'
import json,os,sys
ldir,root_real=sys.argv[1],sys.argv[2]
prefix=root_real.rstrip('/')+'/'
try:
    entries=sorted(os.scandir(ldir),key=lambda e:e.name)
except OSError:
    sys.exit(0)
out=sys.stdout.buffer
for e in entries:
    if e.name.startswith('.') or not e.name.endswith('.json') or not e.is_file(follow_symlinks=False):
        continue
    p=e.path
    try:
        with open(p) as f: d=json.load(f)
        target=d.get('path') if isinstance(d,dict) else None
        if not isinstance(target,str) or not target:
            out.write(os.fsencode(p)+b'\0\0')
            continue
    except Exception:
        out.write(os.fsencode(p)+b'\0\0')
        continue
    if not os.path.exists(target):
        continue
    real=os.path.realpath(target)
    if real.startswith(prefix):
        out.write(os.fsencode(p)+b'\0'+os.fsencode(real)+b'\0')
PY
while IFS= read -r -d '' file && IFS= read -r -d '' real; do
    [[ -e "$file" ]] || continue
    expired && break
    if [[ -z "$real" ]]; then log "kept:lease-unreadable $file"; echo kept:lease-unreadable >> "$EVENTS"; continue; fi
    [[ -e "$real" ]] || continue
    owner="$(lease_owner_state "$file")"
    if [[ "$owner" != unreadable ]] && ! lease_matches_incarnation "$file"; then
        repo="$(wtn_main_repo "$real")" || continue
        registered "$real" "$repo" || continue
        branch="$(git -C "$real" symbolic-ref -q --short HEAD 2>/dev/null)"
        adopt "$real" "$repo" "$branch"
        continue
    fi
    case "$owner" in
        none|alive|unknown) continue ;;
        unreadable) record "$file" "$real" kept:lease-unreadable; continue ;;
        alive-expired) record "$file" "$real" kept:owner-alive-expired; continue ;;
        dead) update "$file" dead || continue; quiet="$QUIET"; since=owner_dead_seen_at ;;
        released) quiet="$RELEASE_QUIET"; since=released_at ;;
        *) continue ;;
    esac
    if [[ -n "${DISK_MAGICIAN_REAP_CANDIDATE_HOOK:-}" ]]; then "$DISK_MAGICIAN_REAP_CANDIDATE_HOOK" "$real"; fi
    (( STOP )) && break
    if ! quiet_since "$file" "$since" "$quiet" || worktree_is_recently_active_minutes "$real" "$quiet"; then
        record "$file" "$real" kept:recent-activity; continue
    fi
    repo="$(wtn_main_repo "$real")" || { record "$file" "$real" kept:not-registered; continue; }
    if ! fetch_repo "$repo"; then record "$file" "$real" kept:remote-unverified; continue; fi
    verdict="$(verdict_for "$real" "$repo" "$quiet")"
    if [[ "$verdict" == remove && "$MODE" == remove ]]; then
        if [[ -n "${DISK_MAGICIAN_REAP_BEFORE_REMOVE_HOOK:-}" ]]; then "$DISK_MAGICIAN_REAP_BEFORE_REMOVE_HOOK" "$real"; fi
        (( STOP )) && break
        verdict="$(verdict_for "$real" "$repo" "$quiet")"
        if [[ "$verdict" == remove ]]; then
            if wrh_remove_now "$real" "$real"; then
                echo remove >> "$EVENTS"; continue
            fi
            verdict=kept:remove-failed
        fi
    fi
    record "$file" "$real" "$verdict"
done < "$RUN_TMP/leases"
# Prune nonexistent leases, retaining fresh pending guards for one hour.
prune_nonexistent_leases
AFTER="$(free_bytes)"
COUNTS="$(python3 - "$EVENTS" <<'PY'
import collections,json,sys
c=collections.Counter({'fetch_ok':0,'fetch_failed':0,'gh_ok':0,'gh_failed':0})
with open(sys.argv[1]) as f: c.update(line.strip() for line in f if line.strip())
print(json.dumps(dict(c)))
PY
)"
POST="$(python3 - "$BEFORE" "$AFTER" <<'PY'
import json,sys
before,after=sys.argv[1:]
delta=int(after)-int(before) if before.isdigit() and after.isdigit() else None
print(json.dumps({'freed_bytes':max(0,delta) if delta is not None else None,
                  'df_delta_bytes':delta,
                  'free_bytes_before':int(before) if before.isdigit() else None,
                  'free_bytes_after':int(after) if after.isdigit() else None}))
PY
)"
receipt finish --job worktree_reap --run-id "$RUN_ID" --outcome "$OUTCOME" --candidates "$COUNTS" --postcondition "$POST"
