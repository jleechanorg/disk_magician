#!/usr/bin/env bash
# Lease-driven worktree reaper. Nomination is the default; removal is opt-in.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/actuator_deadline.sh"
act_parse_deadline_args "$@" || exit $?
set -- "${ACT_ARGS[@]}"
source "$SCRIPT_DIR/worktree_remove_hook.sh"
source "$SCRIPT_DIR/lib/worktree_merged_pr.sh"
STATE="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
LOCK="$STATE/worktree_reap.lock"
MODE="${DISK_MAGICIAN_REAP_MODE:-nominate}"
DEADLINE=1500
QUIET="${REAP_QUIET_MINUTES:-30}"
RELEASE_QUIET="${REAP_RELEASED_QUIET_MINUTES:-30}"
ACT_UNIT_BUDGET_S="${DISK_MAGICIAN_UNIT_BUDGET_S:-60}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:-}"; [[ $# -ge 2 ]] || exit 2; shift 2 ;;
        --deadline-seconds) DEADLINE="${2:-}"; [[ $# -ge 2 ]] || exit 2; shift 2 ;;
        *) echo "Usage: worktree_reap.sh [--mode nominate|remove] [--deadline-seconds N] [--deadline-at T --cursor F]" >&2; exit 2 ;;
    esac
done
[[ "$MODE" == nominate || "$MODE" == remove ]] || exit 2
[[ "$DEADLINE" =~ ^[0-9]+$ && "$QUIET" =~ ^[0-9]+$ && "$RELEASE_QUIET" =~ ^[0-9]+$ ]] || exit 2
[[ -z "$ACT_DEADLINE_AT" || -n "$ACT_CURSOR" ]] || { echo "--deadline-at requires --cursor" >&2; exit 2; }
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
if [[ "$MODE" == remove ]] && ! { [[ -f "$STATE/worktree_reap.remove_approved" ]] && (source "$SCRIPT_DIR/lib/removal_activation.sh" && removal_activation_ok worktree_reap_remove >&2); }; then
    log 'remove mode not approved'
    MODE=nominate
fi
expired() {
    if (( STOP || $(date +%s)-START >= DEADLINE )); then OUTCOME=partial; return 0; fi
    if [[ -n "$ACT_DEADLINE_AT" ]] && ! act_unit_fits 0; then
        OUTCOME=partial
        return 0
    fi
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
process_lease() {
    local file="$1" real owner repo branch since quiet verdict
    [[ -e "$file" ]] || return 0
    expired && return 1
    real="$(_lease_get "$file" path)"
    if [[ -z "$real" ]]; then log "kept:lease-unreadable $file"; echo kept:lease-unreadable >> "$EVENTS"; return 0; fi
    [[ -e "$real" ]] || return 0
    # Even malicious or misplaced leases cannot nominate outside the root.
    real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$real")"
    case "$real" in "$ROOT_REAL"/*) ;; *) return 0;; esac
    owner="$(lease_owner_state "$file")"
    if [[ "$owner" != unreadable ]] && ! lease_matches_incarnation "$file"; then
        repo="$(wtn_main_repo "$real")" || return 0
        registered "$real" "$repo" || return 0
        branch="$(git -C "$real" symbolic-ref -q --short HEAD 2>/dev/null)"
        adopt "$real" "$repo" "$branch"
        return 0
    fi
    case "$owner" in
        none|alive|unknown) return 0 ;;
        unreadable) record "$file" "$real" kept:lease-unreadable; return 0 ;;
        # TTL only reports: an expired lease with a live owner is parked, never T1.
        alive-expired) record "$file" "$real" kept:expired_owner_alive; return 0 ;;
        dead) update "$file" dead || return 0; quiet="$QUIET"; since=owner_dead_seen_at ;;
        released) quiet="$RELEASE_QUIET"; since=released_at ;;
        *) return 0 ;;
    esac
    if [[ -n "${DISK_MAGICIAN_REAP_CANDIDATE_HOOK:-}" ]]; then "$DISK_MAGICIAN_REAP_CANDIDATE_HOOK" "$real"; fi
    (( STOP )) && return 1
    if ! quiet_since "$file" "$since" "$quiet" || worktree_is_recently_active_minutes "$real" "$quiet"; then
        record "$file" "$real" kept:recent-activity; return 0
    fi
    repo="$(wtn_main_repo "$real")" || { record "$file" "$real" kept:not-registered; return 0; }
    if ! fetch_repo "$repo"; then record "$file" "$real" kept:remote-unverified; return 0; fi
    verdict="$(verdict_for "$real" "$repo" "$quiet")"
    if [[ "$verdict" == remove && "$MODE" == remove ]]; then
        if [[ -n "${DISK_MAGICIAN_REAP_BEFORE_REMOVE_HOOK:-}" ]]; then "$DISK_MAGICIAN_REAP_BEFORE_REMOVE_HOOK" "$real"; fi
        (( STOP )) && return 1
        verdict="$(verdict_for "$real" "$repo" "$quiet")"
        if [[ "$verdict" == remove ]]; then
            if wrh_remove_now "$real" "$real"; then echo remove >> "$EVENTS"; return 0; fi
            verdict=kept:remove-failed
        fi
    fi
    record "$file" "$real" "$verdict"
    return 0
}

CURSOR_SOURCE="worktree_reap|mode=$MODE|quiet=$QUIET|released_quiet=$RELEASE_QUIET|root=$ROOT_REAL"
if [[ -n "$ACT_CURSOR" ]]; then
    CURSOR_STATE="$(act_cursor_load "$ACT_CURSOR" "$CURSOR_SOURCE")" || { log cursor-invalid; OUTCOME=error; exit 3; }
    CURSOR_ITEMS="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["items"],separators=(",",":")))' "$CURSOR_STATE")"
    CURSOR_INDEX="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["next_index"])' "$CURSOR_STATE")"
    CURSOR_LEN="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$CURSOR_ITEMS")"
    if [[ "$CURSOR_ITEMS" == '[]' ]] || (( CURSOR_INDEX >= CURSOR_LEN )); then
        CURSOR_ITEMS="$(python3 - "$(lease_dir)" <<'PY'
import glob,json,sys
print(json.dumps(sorted(glob.glob(sys.argv[1]+"/*.json")),separators=(",",":")))
PY
)"
        act_cursor_save "$ACT_CURSOR" "$CURSOR_SOURCE" "$CURSOR_ITEMS" 0 || { log cursor-save-failed; OUTCOME=error; exit 3; }
        CURSOR_INDEX=0
    fi
    CURSOR_LEN="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$CURSOR_ITEMS")"
    while (( CURSOR_INDEX < CURSOR_LEN )); do
        if ! act_unit_fits "$ACT_UNIT_BUDGET_S"; then
            OUTCOME=partial; log deferred:deadline-before-unit; echo deadline_before_unit >> "$EVENTS"; break
        fi
        file="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])])' "$CURSOR_ITEMS" "$CURSOR_INDEX")"
        process_lease "$file" || { OUTCOME=partial; break; }
        CURSOR_INDEX=$((CURSOR_INDEX + 1))
        act_cursor_save "$ACT_CURSOR" "$CURSOR_SOURCE" "$CURSOR_ITEMS" "$CURSOR_INDEX" || { log cursor-save-failed; OUTCOME=error; break; }
        expired && break
    done
else
    for file in "$(lease_dir)"/*.json; do
        [[ -e "$file" ]] || continue
        process_lease "$file" || { OUTCOME=partial; break; }
        expired && break
    done
fi
# Prune nonexistent leases, retaining fresh pending guards for one hour.
for file in "$(lease_dir)"/*.json; do
    [[ -f "$file" ]] || continue
    python3 - "$file" <<'PY'
import json,os,sys,time
try:
    p=sys.argv[1]; d=json.load(open(p)); target=d.get('path')
    if not isinstance(target,str) or not target or os.path.lexists(target): sys.exit(0)
    if d.get('pending') and time.time()-d.get('created_epoch',time.time())<3600: sys.exit(0)
    os.unlink(p)
except (OSError,ValueError,TypeError,AttributeError): pass
PY
done
AFTER="$(free_bytes)"
COUNTS="$(python3 - "$EVENTS" <<'PY'
import collections,json,sys
c=collections.Counter({'fetch_ok':0,'fetch_failed':0,'gh_ok':0,'gh_failed':0})
events=[]
with open(sys.argv[1]) as f:
    events=[line.strip() for line in f if line.strip()]
c.update(events)
c['removed_count']=events.count('remove')
c['deferred_count']=sum(x.startswith('deferred:') for x in events)
c['interrupted_count']=events.count('deadline_before_unit')
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
