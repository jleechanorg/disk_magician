# shellcheck shell=bash
# worktree_lease.sh — owner leases for standard-root worktrees.
#
# Part of the worktree lease teardown design
# (docs/superpowers/specs/2026-10-10-worktree-lease-teardown-design.md).
# Writes JSON lease files under $(lease_dir), one per worktree, keyed by
# sha256(realpath)[:16]. The reaper (worktree_reap.sh) is the only consumer
# allowed to remove anything; this library only records and reports.
#
# SAFETY POSTURE
# ---------------
# Every unknown fails toward "owner alive / keep". A lease with no resolvable
# runtime owner (owner: null) is never owner-reaped. pid liveness is checked
# by pid PLUS lstart epoch so a reused pid reads dead, not alive. A comm
# mismatch with matching epochs reads unknown (keep), never dead.
#
# Test hook: DISK_MAGICIAN_PS_BIN overrides the ps binary; fake ps
# implementations honour -p <pid> -o ppid=,comm= / lstart= / args=.
# State dir override: DISK_MAGICIAN_STATE_DIR (as everywhere in disk_magician).

# Owner runtimes, matched by comm basename (exact).
_LEASE_RUNTIME_COMMS="claude codex agy cursor-agent hermes"

_lease_ps() { "${DISK_MAGICIAN_PS_BIN:-ps}" "$@"; }

lease_dir() {
    printf '%s/worktree_leases\n' "${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
}

# lease_path_for <path> — canonical lease file for a worktree path. The path
# may not exist yet (pending guard leases); realpath is computed logically.
lease_path_for() {
    local path="${1:-}" real hash
    real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null)" || real="$path"
    if command -v shasum >/dev/null 2>&1; then
        hash="$(printf '%s' "$real" | shasum -a 256 | cut -c1-16)"
    else
        hash="$(printf '%s' "$real" | sha256sum | cut -c1-16)"
    fi
    printf '%s/%s.json\n' "$(lease_dir)" "$hash"
}

# _lease_lstart_to_epoch <lstart string> — parse "Thu Oct  9 12:00:00 2026"
# (LC_ALL=C TZ=UTC rendering) to a UTC epoch. bash 3.2-safe: python3 stdlib.
_lease_lstart_to_epoch() {
    python3 - "$1" <<'PY'
import sys
from datetime import datetime, timezone
try:
    dt = datetime.strptime(sys.argv[1].strip(), "%a %b %d %H:%M:%S %Y")
    print(int(dt.replace(tzinfo=timezone.utc).timestamp()))
except Exception:
    sys.exit(1)
PY
}

# _lease_ps_lstart_epoch <pid> — UTC epoch of the process start time, or rc 1.
_lease_ps_lstart_epoch() {
    local pid="$1" out
    out="$(LC_ALL=C TZ=UTC _lease_ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
    [[ -n "${out//[[:space:]]/}" ]] || return 1
    _lease_lstart_to_epoch "$out"
}

# _lease_full_comm <pid> — full executable basename, preferring the first
# token of args= (macOS comm= is truncated near 16 chars; args is not).
# Prints empty on failure.
_lease_full_comm() {
    local pid="$1" args first comm
    args="$(_lease_ps -p "$pid" -o args= 2>/dev/null)" || args=""
    if [[ -z "${args//[[:space:]]/}" ]]; then
        args="$(_lease_ps -p "$pid" -o comm= 2>/dev/null)" || args=""
    fi
    [[ -z "${args//[[:space:]]/}" ]] && return 0
    read -r first _ <<<"$args"
    [[ -n "$first" ]] || return 0
    comm="${first##*/}"
    printf '%s\n' "$comm"
}

_lease_comm_is_runtime() {
    local c="${1##*/}" r
    for r in $_LEASE_RUNTIME_COMMS; do
        [[ "$c" == "$r" ]] && return 0
    done
    return 1
}

# Hermes detection: a python* process whose script argument's basename starts
# with "hermes" (the gateway only shows up as python in comm).
_lease_args_mention_hermes() {
    local args="$1" tok base
    for tok in $args; do
        base="${tok##*/}"
        case "$base" in hermes*) return 0 ;; esac
    done
    return 1
}

# lease_resolve_owner [start_pid] — walk parent links from start_pid (default
# $$) up to 32 hops, guarding against pid cycles. Prints
# "pid<TAB>start_epoch<TAB>comm" of the nearest runtime ancestor, or
# "-<TAB>-<TAB>-" when there is none (lease then written with owner: null).
lease_resolve_owner() {
    local pid="${1:-$$}" hops=0 rest ppid hop_comm i
    local visited="" ep comm
    while (( hops < 32 )); do
        hops=$((hops + 1))
        case ",$visited," in *",$pid,"*)
            printf -- '-\t-\t-\n'; return 0 ;;
        esac
        visited="$visited,$pid"
        rest="$(_lease_ps -p "$pid" -o ppid=,comm= 2>/dev/null)" || { printf -- '-\t-\t-\n'; return 0; }
        [[ -n "${rest//[[:space:]]/}" ]] || { printf -- '-\t-\t-\n'; return 0; }
        read -r ppid hop_comm <<<"$rest"
        if _lease_comm_is_runtime "$hop_comm"; then
            ep="$(_lease_ps_lstart_epoch "$pid")" || ep="-"
            comm="$(_lease_full_comm "$pid")"
            [[ -n "$comm" ]] || comm="${hop_comm##*/}"
            printf '%s\t%s\t%s\n' "$pid" "$ep" "$comm"
            return 0
        fi
        if [[ "${hop_comm##*/}" == python* ]]; then
            rest="$(_lease_ps -p "$pid" -o args= 2>/dev/null)" || rest=""
            if _lease_args_mention_hermes "$rest"; then
                ep="$(_lease_ps_lstart_epoch "$pid")" || ep="-"
                printf '%s\t%s\thermes\n' "$pid" "$ep"
                return 0
            fi
        fi
        [[ "$ppid" =~ ^[1-9][0-9]*$ ]] || { printf -- '-\t-\t-\n'; return 0; }
        pid="$ppid"
    done
    printf -- '-\t-\t-\n'
}

# _lease_admin_info <worktree_path> — "admin_id<TAB>birth_epoch" from the
# .git pointer's admin dir, or "-<TAB>-" when unresolvable.
_lease_admin_info() {
    local path="$1" line gitdir birth
    [[ -n "$path" && -f "$path/.git" ]] || { printf -- '-\t-\n'; return 0; }
    line="$(head -n 1 "$path/.git" 2>/dev/null)" || { printf -- '-\t-\n'; return 0; }
    [[ "$line" == gitdir:* ]] || { printf -- '-\t-\n'; return 0; }
    gitdir="${line#gitdir:}"
    gitdir="${gitdir# }"
    [[ -n "$gitdir" && -d "$gitdir" ]] || { printf -- '-\t-\n'; return 0; }
    if [[ "$(uname -s 2>/dev/null)" == Darwin ]]; then
        birth="$(stat -f %B "$gitdir" 2>/dev/null || echo 0)"
    else
        birth="$(stat -c %W "$gitdir" 2>/dev/null || echo 0)"
    fi
    printf '%s\t%s\n' "${gitdir##*/}" "$birth"
}

# _lease_get <lease_file> <key> — one JSON field, empty on any failure.
_lease_get() {
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}

# _lease_write_json <lease_file> <pydict-args...> is not used; writes go
# through inline python below for atomicity (mktemp sibling + os.replace).

# lease_write <worktree_path> [<repo> <branch> <creator>] [--kind K]
#   [--producer P] [--source S] [--manifest F] [--git-meta F]
#   [--published URL --upload-manifest F --verified-at TS]
# Atomic lease write with the owner resolved from $$. Kinds: worktree (default),
# clone, scratch, evidence. --manifest is an inventory only; publication needs
# all three --published flags. rc 2 on invalid options (nothing written).
lease_write() {
    local wt="$1"; shift
    local -a pos=() prov=("" "" "" "" "" "" "" "")
    while [[ $# -gt 0 && "$1" != --* ]]; do pos+=("$1"); shift; done
    local repo="${pos[0]:-}" branch="${pos[1]:-}" creator="${pos[2]:-}"
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || return 2
        case "$1" in
            --kind) prov[0]="$2" ;; --producer) prov[1]="$2" ;;
            --source) prov[2]="$2" ;; --manifest) prov[3]="$2" ;;
            --git-meta) prov[4]="$2" ;; --published) prov[5]="$2" ;;
            --upload-manifest) prov[6]="$2" ;; --verified-at) prov[7]="$2" ;;
            *) return 2 ;;
        esac
        shift 2
    done
    local tsv pid ep comm admin_id admin_birth lease ttl
    tsv="$(lease_resolve_owner)"
    pid="$(cut -f1 <<<"$tsv")"; ep="$(cut -f2 <<<"$tsv")"; comm="$(cut -f3 <<<"$tsv")"
    IFS=$'\t' read -r admin_id admin_birth < <(_lease_admin_info "$wt")
    lease="$(lease_path_for "$wt")"
    mkdir -p "$(lease_dir)" 2>/dev/null || return 1
    ttl="${DISK_MAGICIAN_LEASE_TTL_HOURS:-24}"
    _lease_emit_json "$lease" "$wt" "$repo" "$branch" "$creator" "False" \
        "$pid" "$ep" "$comm" "$admin_id" "$admin_birth" "$ttl" "${prov[@]}"
}

# lease_owner_add <worktree_path> <pid> <start_epoch> <comm> adds a concrete
# process incarnation without replacing existing owners.
lease_owner_add() {
    local wt="$1" pid="$2" start="$3" comm="$4" lease
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$start" =~ ^-?[0-9]+$ && -n "$comm" ]] || return 2
    lease="$(lease_path_for "$wt")"
    [[ -f "$lease" ]] || return 1
    lease_mutation_lock_enter "$lease" || return 1
    python3 - "$lease" "$pid" "$start" "$comm" <<'PYOWNERADD'
import json, os, sys, tempfile
from datetime import datetime, timezone
path, pid, start, comm = sys.argv[1:]
try:
    d=json.load(open(path))
    owners=d.get("owners")
    if not isinstance(owners,list):
        old=d.get("owner")
        owners=[old] if isinstance(old,dict) else []
    if any(str(o.get("pid"))==pid and str(o.get("start_epoch"))==start and not o.get("released_at")
           for o in owners if isinstance(o,dict)):
        raise SystemExit(0)
    owners.append({"pid":int(pid),"start_epoch":int(start),"comm":comm,
                   "session":None,"added_at":datetime.now(timezone.utc).isoformat()})
    d["owners"]=owners
    if d.get("owner") is None and owners: d["owner"]=owners[0]
    fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path),prefix=".owner-add-")
    with os.fdopen(fd,"w") as f: json.dump(d,f,indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
    os.replace(tmp,path)
except Exception:
    sys.exit(1)
PYOWNERADD
    local rc=$?
    lease_mutation_lock_exit "$lease"
    return "$rc"
}

# lease_kind <lease_file> — kind, "worktree" for leases written before kinds
# existed, "unreadable" when the file cannot be parsed.
lease_kind() {
    python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get("kind") or "worktree")
except Exception:
    print("unreadable")
PY
}

# lease_write_pending <target_path> <owner_tsv> — pre-creation lease written
# by the guard. rc 1 (nothing written) if the target path already exists, or
# if a lease already exists for a worktree that still exists on disk.
# Replaces a lease whose recorded path no longer exists.
lease_write_pending() {
    local target="$1" tsv="$2"
    local pid ep comm lease existing_path
    lease="$(lease_path_for "$target")"
    mkdir -p "$(lease_dir)" 2>/dev/null || return 1
    lease_mutation_lock_enter "$lease" || return 1
    if [[ -e "$target" ]]; then lease_mutation_lock_exit "$lease"; return 1; fi
    if [[ -f "$lease" ]]; then
        existing_path="$(_lease_get "$lease" path)"
        if [[ -n "$existing_path" && -e "$existing_path" ]]; then
            lease_mutation_lock_exit "$lease"
            return 1
        fi
    fi
    pid="$(cut -f1 <<<"$tsv")"; ep="$(cut -f2 <<<"$tsv")"; comm="$(cut -f3 <<<"$tsv")"
    _lease_emit_json "$lease" "$target" "" "" "guard" "True" \
        "$pid" "$ep" "$comm" "-" "-" "${DISK_MAGICIAN_LEASE_TTL_HOURS:-24}" \
        "" "" "" "" "" "" "" "" --lock-held
    local rc=$?
    lease_mutation_lock_exit "$lease"
    return "$rc"
}

# lease_claim_reuse <lease_file> <expected_sha256> <old_branch> <old_tip> <owner_tsv>
#   <repo> <path> <admin_id> <admin_birth> <checkout_dev> <checkout_ino>
# Atomically converts the exact observed lease to a pending reuse claim. The
# previous lease is retained for rollback; an abandoned claim is never reaped.
lease_claim_reuse() {
    python3 - "$1" "$2" "$3" "$4" "$5" "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}" "${11:-}" <<'PY'
import hashlib, json, os, sys, tempfile, time
path, expected, branch, tip, owner_tsv, repo, worktree, admin_id, admin_birth, checkout_dev, checkout_ino = sys.argv[1:]
lock = path + ".reuse-lock"
try:
    os.mkdir(lock)
except OSError:
    sys.exit(1)
try:
    with open(os.path.join(lock, "pid"), "w") as f: f.write(str(os.getpid()))
    with open(os.path.join(lock, "acquired_at"), "w") as f: f.write(str(int(time.time())))
    with open(path, "rb") as f: raw = f.read()
    if hashlib.sha256(raw).hexdigest() != expected: sys.exit(1)
    old = json.loads(raw)
    if not isinstance(old, dict) or old.get("reuse") or old.get("pending") is True: sys.exit(1)
    if repo and (old.get("repo") != repo or old.get("path") != worktree or
                 old.get("branch") != branch or old.get("admin_id") != admin_id or
                 str(old.get("admin_birth_epoch")) != admin_birth or
                 str(old.get("checkout_dev")) != checkout_dev or
                 str(old.get("checkout_ino")) != checkout_ino): sys.exit(1)
    if worktree:
        try:
            st = os.stat(worktree)
        except OSError:
            sys.exit(1)
        if str(st.st_dev) != checkout_dev or str(st.st_ino) != checkout_ino: sys.exit(1)
    owner = None
    fields = owner_tsv.split("\t")
    if len(fields) >= 3 and fields[0].isdigit() and fields[1].isdigit():
        owner = {"pid": int(fields[0]), "start_epoch": int(fields[1]), "comm": fields[2]}
    d = dict(old)
    d.pop("released_at", None)  # a fresh live claim is not released; old state stays in previous_lease
    d["pending"] = True
    d["owner"] = owner
    d["reuse"] = {"state": "pending", "old_branch": branch, "old_tip": tip,
                  "previous_lease": old}
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".reuse-lease-")
    try:
        with os.fdopen(fd, "w") as f: json.dump(d, f, indent=2); f.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
finally:
    for name in ("pid", "acquired_at"):
        try: os.unlink(os.path.join(lock, name))
        except FileNotFoundError: pass
    try: os.rmdir(lock)
    except OSError: pass
PY
}

# lease_owner_state_for <lease> <own_owner_tsv> [expected_candidate] —
# lease_owner_state, but a live owner that exactly matches own_owner_tsv on a
# *pending reuse claim* reports "own-live" so the claimer's own post-claim C14
# passes. The exemption is bound to the exact pending claim/candidate: the
# lease must record `path` == expected_candidate (when supplied) and retain a
# dict `reuse.previous_lease` for rollback. Exact pid+start_epoch; any other
# live owner, any other candidate (e.g. an ancestor) and any missing/invalid
# claim proof retains its live state (kept). Expired TTLs never revoke a
# verified live owner, including this exact claimant. Never a universal bypass.
lease_owner_state_for() {
    local lease="$1" own="${2:-}" candidate="${3:-}" base
    base="$(lease_owner_state "$lease")"
    [[ "$base" == alive || "$base" == alive-expired ]] || { printf '%s\n' "$base"; return 0; }
    python3 - "$lease" "$own" "$candidate" "$base" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(sys.argv[4]); sys.exit(0)
own = sys.argv[2].split("\t")
candidate = sys.argv[3]
reuse = d.get("reuse")
if d.get("released_at") or not isinstance(reuse, dict) or reuse.get("state") != "pending":
    print(sys.argv[4]); sys.exit(0)
if not isinstance(reuse.get("previous_lease"), dict):
    print(sys.argv[4]); sys.exit(0)
if candidate and d.get("path") != candidate:
    print(sys.argv[4]); sys.exit(0)
o = d.get("owner")
if not (isinstance(o, dict) and len(own) >= 2 and own[0].isdigit()):
    print(sys.argv[4]); sys.exit(0)
if str(o.get("pid")) == own[0] and str(o.get("start_epoch", "")) == own[1]:
    print("own-live"); sys.exit(0)
print(sys.argv[4])
PY
}

# The reaper holds this same lock from its final check through removal.
#
# Stale-lock recovery (reproduced: a holder killed between mkdir and rmdir
# leaves an empty .reuse-lock dir forever). This library writes `pid` and
# `acquired_at` inside the dir and, on mkdir failure, reclaims ONLY its own
# two known files when the pid is provably dead AND the lock is past the TTL.
# Unknown shape, a live pid, or an unreadable probe keeps the lock (fail
# closed). A nested reclaim gate makes the reclaim single-writer.
LEASE_REUSE_LOCK_TTL_SEC="${LEASE_REUSE_LOCK_TTL_SEC:-3600}"

_reuse_lock_dead_pid() {
    local pid="$1" out rc err
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    err="$(mktemp)" || return 1
    out="$(LC_ALL=C TZ=UTC _lease_ps -p "$pid" -o pid= 2>"$err")"; rc=$?
    [[ "$rc" == 1 && ! -s "$err" && -z "$out" ]]; rc=$?
    rm -f "$err"
    return "$rc"
}

lease_reuse_lock_recover() {
    local lease="$1" lock="$1.reuse-lock" gate="$1.reuse-lock.reclaim_gate" pid stamp
    [[ -d "$lock" && ! -L "$lock" ]] || return 1
    pid="$(cat "$lock/pid" 2>/dev/null)"; stamp="$(cat "$lock/acquired_at" 2>/dev/null)"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$stamp" =~ ^[0-9]+$ ]] || return 1
    (( $(date +%s) - stamp > LEASE_REUSE_LOCK_TTL_SEC )) || return 1
    _reuse_lock_dead_pid "$pid" || return 1
    mkdir "$gate" 2>/dev/null || return 1
    pid="$(cat "$lock/pid" 2>/dev/null)"; stamp="$(cat "$lock/acquired_at" 2>/dev/null)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ && "$stamp" =~ ^[0-9]+$ ]] &&
        (( $(date +%s) - stamp > LEASE_REUSE_LOCK_TTL_SEC )) && _reuse_lock_dead_pid "$pid"; then
        rm -f "$lock/pid" "$lock/acquired_at"
        rmdir "$lock" 2>/dev/null || { rmdir "$gate" 2>/dev/null; return 1; }
        rmdir "$gate" 2>/dev/null
        return 0
    fi
    rmdir "$gate" 2>/dev/null
    return 1
}

lease_reuse_lock_acquire() {
    local lease="$1" lock="$1.reuse-lock"
    if ! mkdir "$lock" 2>/dev/null; then
        lease_reuse_lock_recover "$lease" || return 1
        mkdir "$lock" 2>/dev/null || return 1
    fi
    echo "$$" > "$lock/pid" 2>/dev/null || true
    date +%s > "$lock/acquired_at" 2>/dev/null || true
}
lease_reuse_lock_release() {
    rm -f "$1.reuse-lock/pid" "$1.reuse-lock/acquired_at" 2>/dev/null
    rmdir "$1.reuse-lock" 2>/dev/null
}
lease_mutation_lock_enter() {
    local lease="$1" mode="${2:-}"
    if [[ "$mode" == --lock-held ]]; then
        [[ -d "$lease.reuse-lock" ]]
    else
        lease_reuse_lock_acquire "$lease"
    fi
}
lease_mutation_lock_exit() {
    [[ "${2:-}" == --lock-held ]] || lease_reuse_lock_release "$1"
}

# lease_restore_reuse_claim <lease_file> — restore the exact saved lease only
# while this file still carries our pending claim.
lease_restore_reuse_claim() {
    local lease="$1"
    lease_mutation_lock_enter "$lease" || return 1
    python3 - "$lease" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
try:
    with open(path) as f: d = json.load(f)
    prev = d.get("reuse", {}).get("previous_lease")
    if d.get("reuse", {}).get("state") != "pending" or not isinstance(prev, dict): sys.exit(1)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".restore-lease-")
    with os.fdopen(fd, "w") as f: json.dump(prev, f, indent=2); f.write("\n")
    os.replace(tmp, path)
except Exception: sys.exit(1)
PY
    local rc=$?
    lease_mutation_lock_exit "$lease"
    return "$rc"
}

# lease_mark_reuse_incomplete <lease_file> — preserve old branch/tip and block
# future claims when recovery could not restore the candidate safely.
lease_mark_reuse_incomplete() {
    local lease="$1"
    lease_mutation_lock_enter "$lease" || return 1
    python3 - "$lease" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
try:
    with open(path) as f: d = json.load(f)
    if not isinstance(d.get("reuse"), dict): sys.exit(1)
    d["reuse"]["state"] = "reuse_incomplete"
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".incomplete-lease-")
    with os.fdopen(fd, "w") as f: json.dump(d, f, indent=2); f.write("\n")
    os.replace(tmp, path)
except Exception: sys.exit(1)
PY
    local rc=$?
    lease_mutation_lock_exit "$lease"
    return "$rc"
}

# _lease_emit_json <lease_file> ... — shared writer. owner fields "-" produce
# owner: null. Atomic: temp file in the same dir, then os.replace.
_lease_emit_json() {
    local lease="$1" wt="$2" repo="$3" branch="$4" creator="$5" pending="$6"
    local pid="$7" ep="$8" comm="$9" admin_id="${10}" admin_birth="${11}" ttl="${12}"
    local lock_mode="${21:-}"
    lease_mutation_lock_enter "$lease" "$lock_mode" || return 1
    python3 - "$lease" "$wt" "$repo" "$branch" "$creator" "$pending" \
        "$pid" "$ep" "$comm" "$admin_id" "$admin_birth" "$ttl" "${@:13}" <<'PY'
import json, os, sys, tempfile
from datetime import datetime, timezone
(lease, wt, repo, branch, creator, pending, pid, ep, comm,
 admin_id, admin_birth, ttl) = sys.argv[1:13]
(kind, producer, source, manifest, git_meta, pub_url, upload, verified_at) = (
    sys.argv[13:21] + [""] * 8)[:8]
UPLOAD_KEYS = {"path", "sha256", "md5", "crc32c", "size", "object", "generation"}
def load(p):
    if not p:
        return None
    try:
        with open(p) as f:
            return json.load(f)
    except Exception:
        sys.exit(2)
if (kind or "worktree") not in ("worktree", "clone", "scratch", "evidence"):
    sys.exit(2)
if bool(pub_url) != bool(upload) or bool(pub_url) != bool(verified_at):
    sys.exit(2)
upload_manifest = load(upload)
if upload and not (isinstance(upload_manifest, list) and upload_manifest and all(
        isinstance(e, dict) and UPLOAD_KEYS <= set(e) for e in upload_manifest)):
    sys.exit(2)
owner = None
try:
    st = os.stat(wt)
    checkout_dev, checkout_ino = st.st_dev, st.st_ino
except OSError:
    checkout_dev = checkout_ino = None
if pid not in ("-", ""):
    try:
        owner = {"pid": int(pid), "start_epoch": int(ep), "comm": comm}
    except ValueError:
        owner = None
if owner and os.environ.get("DISK_MAGICIAN_OWNER_SESSION"):
    owner["session"] = os.environ["DISK_MAGICIAN_OWNER_SESSION"]
now = datetime.now(timezone.utc)
d = {
    "schema_version": 1,
    "path": wt,
    "repo": repo or None,
    "branch": branch or None,
    "creator": creator,
    "pending": pending == "True",
    "created_at": now.isoformat(),
    "created_epoch": int(now.timestamp()),
    "ttl_hours": int(ttl),
    "expires_at": int(now.timestamp()) + int(ttl) * 3600,
    "owner": owner,
    "owners": ([owner] if owner else []),
    "admin_id": None if admin_id in ("", "-") else admin_id,
    "admin_birth_epoch": None if admin_birth in ("", "-") else int(admin_birth),
    "checkout_dev": checkout_dev,
    "checkout_ino": checkout_ino,
    "released_at": None,
    "last_verdict": None,
    "last_checked_at": None,
    "kind": kind or "worktree",
    "producer": producer or None,
    "source": source or None,
    "manifest": load(manifest),
    "git_meta": load(git_meta),
    "published": bool(pub_url),
    "published_at": now.isoformat() if pub_url else None,
    "published_url": pub_url or None,
    "verified_at": verified_at or None,
    "upload_manifest": upload_manifest,
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(lease), prefix=".lease-", suffix=".json")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    os.replace(tmp, lease)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(1)
PY
    local rc=$?
    lease_mutation_lock_exit "$lease" "$lock_mode"
    return "$rc"
}

# lease_owner_state <lease_file> [now_epoch] — prints exactly one of:
#   none | released | dead | alive | alive-expired | unknown | unreadable
# Precedence: none (owner null) > released > ps check. Fail-closed: every
# unmeasurable case keeps the worktree (alive/unknown/unreadable/none).
# The liveness probe is LC_ALL=C TZ=UTC pinned so ambient LANG/TZ cannot
# localize the lstart rendering (fr_FR renders "Sam 10 oct ..." and breaks
# the parse, which would silently turn alive owners into unknown).
lease_owner_state() {
    local lease="$1" now="${2:-}"
    python3 - "$lease" "$now" <<'PYLEASESTATE'
import json, os, subprocess, sys, time
from datetime import datetime, timezone
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    print("unreadable"); raise SystemExit
if d.get("released_at"): print("released"); raise SystemExit
owners=d.get("owners")
if not isinstance(owners,list): owners=[] if d.get("owner") is None else [d.get("owner")]
if not owners: print("none"); raise SystemExit
now=int(sys.argv[2]) if sys.argv[2].isdigit() else int(time.time())
states=[]
for owner in owners:
    if not isinstance(owner,dict) or not isinstance(owner.get("pid"),int) or isinstance(owner.get("pid"),bool):
        states.append("unreadable"); continue
    if owner.get("released_at"):
        states.append("released"); continue
    pid=owner["pid"]
    try:
        ps=os.environ.get("DISK_MAGICIAN_PS_BIN", "ps")
        p=subprocess.run([ps,"-p",str(pid),"-o","lstart="],capture_output=True,text=True,env={**os.environ,"LC_ALL":"C","TZ":"UTC"})
    except Exception:
        states.append("unknown"); continue
    if p.returncode==1 and not p.stdout.strip() and not p.stderr.strip():
        states.append("dead"); continue
    if p.returncode!=0 or not p.stdout.strip(): states.append("unknown"); continue
    try:
        epoch=int(datetime.strptime(p.stdout.strip(),"%a %b %d %H:%M:%S %Y").replace(tzinfo=timezone.utc).timestamp())
        stored=int(owner.get("start_epoch"))
    except Exception:
        states.append("unknown"); continue
    if abs(epoch-stored)>2: states.append("dead"); continue
    args=subprocess.run([ps,"-p",str(pid),"-o","args="],capture_output=True,text=True).stdout.strip()
    comm=os.path.basename(args.split()[0]) if args else ""
    expected=os.path.basename(str(owner.get("comm", "")))
    if comm and comm!=expected and not comm.startswith(expected) and not expected.startswith(comm):
        states.append("unknown"); continue
    created=d.get("created_epoch"); ttl=d.get("ttl_hours",24)
    states.append("alive-expired" if isinstance(created,int) and isinstance(ttl,int) and now>=created+ttl*3600 else "alive")
if "alive" in states: print("alive")
elif "alive-expired" in states: print("alive-expired")
elif "unreadable" in states: print("unreadable")
elif "unknown" in states: print("unknown")
elif "dead" in states: print("dead")
else: print("released")
PYLEASESTATE
}

# lease_release <worktree_path> — mark the caller's own lease released.
# rc 1 "no lease" when unleased; rc 1 "not lease owner" when the caller's
# resolved owner does not match the lease owner (pid plus start epoch), when
# the lease has no owner, or when the caller has no resolvable owner.
lease_release() {
    local wt="$1" lease tsv pid ep
    lease="$(lease_path_for "$wt")"
    [[ -f "$lease" ]] || { echo "no lease" >&2; return 1; }
    tsv="$(lease_resolve_owner)"
    pid="$(cut -f1 <<<"$tsv")"; ep="$(cut -f2 <<<"$tsv")"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "not lease owner" >&2; return 1; }
    [[ "$ep" =~ ^-?[0-9]+$ ]] || { echo "not lease owner" >&2; return 1; }
    lease_mutation_lock_enter "$lease" || { echo "lease busy" >&2; return 1; }
    if python3 - "$lease" "$pid" "$ep" <<'PY'
import json, os, sys, tempfile
from datetime import datetime, timezone
lease, pid, ep = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    with open(lease) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
owners = d.get("owners")
if not isinstance(owners, list):
    owners = [d.get("owner")] if isinstance(d.get("owner"), dict) else []
matches = [o for o in owners if isinstance(o, dict) and str(o.get("pid")) == str(pid)
           and str(o.get("start_epoch")) == ep and not o.get("released_at")]
if not matches:
    o = d.get("owner")
    if isinstance(o, dict) and str(o.get("pid")) == str(pid) and str(o.get("start_epoch")) == ep:
        owners = [o]
        d["owners"] = owners
        matches = [o]
if not matches:
    sys.exit(1)
stamp = datetime.now(timezone.utc).isoformat()
for o in matches: o["released_at"] = stamp
d["owners"] = owners
if owners and all(not isinstance(o, dict) or o.get("released_at") for o in owners):
    d["released_at"] = stamp
else:
    d.pop("released_at", None)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(lease), prefix=".release-")
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
os.replace(tmp, lease)
PY
    then
        lease_mutation_lock_exit "$lease"
        return 0
    fi
    lease_mutation_lock_exit "$lease"
    echo "not lease owner" >&2
    return 1
}

# lease_release_owner_session <session> <runtime_pid> <runtime_start_epoch> —
# session-exit release (spec C8). Releases each lease whose owner.session is
# <session> and whose owner is the ending runtime (same pid and start epoch)
# or dead; any other owner is reported as release_skipped_live_owner. Deletes
# nothing; an unknown session changes nothing. rc 2 only without a session.
lease_release_owner_session() {
    local sid="${1:-}" rpid="${2:-}" rep="${3:-}" file match opid oep path
    [[ -n "$sid" ]] || return 2
    for file in "$(lease_dir)"/*.json; do
        IFS=$'\t' read -r match opid oep path < <(_lease_session_release scan "$file" "$sid" "$rpid" "$rep") || continue
        if [[ "$match" == other && "$(lease_owner_state "$file")" != dead ]]; then
            printf 'release_skipped_live_owner %s\n' "$path"; continue
        fi # commit re-checks the owner judged above under the lock (TOCTOU)
        _lease_session_release commit "$file" "$sid" "$opid" "$oep" && printf 'released %s\n' "$path"
    done
    return 0
}

# _lease_session_release scan|commit <lease> <session> <pid> <epoch> — scan prints
# one matching owner; commit releases only that owner under the mutation lock.
_lease_session_release() {
    local mode="$1" p="$2"
    if [[ "$mode" == commit ]]; then lease_mutation_lock_enter "$p" || return 1; fi
    python3 - "$@" <<'PYLEASESESSION'
import json, os, sys, tempfile
from datetime import datetime, timezone
mode, p, sid, pid, ep = sys.argv[1:]
try:
    lk = open(p[:-5] + ".lock", "a") if mode == "commit" else None
    if lk:
        import fcntl
        fcntl.flock(lk, fcntl.LOCK_EX)
    d = json.load(open(p))
    owners = d.get("owners")
    if not isinstance(owners, list):
        owners = [d.get("owner")] if isinstance(d.get("owner"), dict) else []
    matches = [o for o in owners if isinstance(o, dict) and o.get("session") == sid
               and str(o.get("pid")) == pid and str(o.get("start_epoch")) == ep
               and not o.get("released_at") and not d.get("released_at")]
    if mode == "scan":
        if matches:
            o = matches[0]
            print("self\t%s\t%s\t%s" % (o.get("pid"), o.get("start_epoch"), d.get("path", "")))
        elif any(isinstance(o, dict) and o.get("session") == sid and not o.get("released_at") for o in owners):
            o = next(o for o in owners if isinstance(o, dict) and o.get("session") == sid and not o.get("released_at"))
            print("other\t%s\t%s\t%s" % (o.get("pid"), o.get("start_epoch"), d.get("path", "")))
    elif len(matches) == 1:
        stamp = datetime.now(timezone.utc).isoformat()
        matches[0]["released_at"] = stamp
        d["owners"] = owners
        if owners and all(not isinstance(o, dict) or o.get("released_at") for o in owners):
            d["released_at"] = stamp
        else:
            d.pop("released_at", None)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".release-")
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, indent=2); f.write("\n"); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, p)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
PYLEASESESSION
    local rc=$?
    if [[ "$mode" == commit ]]; then lease_mutation_lock_exit "$p"; fi
    return "$rc"
}

# lease_set_verdict <lease_file> <verdict> — record the reaper's last verdict.
lease_set_verdict() {
    local lease="$1" verdict="$2" lock_mode="${3:-}" rc
    lease_mutation_lock_enter "$lease" "$lock_mode" || return 1
    python3 - "$lease" "$verdict" <<'PY'
import json, os, sys
from datetime import datetime, timezone
lease, verdict = sys.argv[1], sys.argv[2]
try:
    with open(lease) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
d["last_verdict"] = verdict
d["last_checked_at"] = datetime.now(timezone.utc).isoformat()
tmp = lease + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, lease)
PY
    rc=$?
    lease_mutation_lock_exit "$lease" "$lock_mode"
    return "$rc"
}

# lease_matches_incarnation <lease_file> — rc 0 when the lease's admin_id and
# admin_birth_epoch still match the live admin dir for its path, and (when the
# lease records them) its checkout device/inode still match that path. Legacy
# leases written before checkout identity existed carry no dev/ino; they fall
# back to the admin/birth proof so a reaper pass preserves their owner instead
# of re-adopting with owner: null. A replacement checkout always gets a fresh
# admin dir/birth, so it still fails this check; the reuse claim separately
# requires the recorded dev/ino, so a legacy lease can never authorize a
# recycle. Any unresolvable side is a mismatch (the reaper then re-adopts with
# owner: null, which can never be owner-reaped — the safe direction).
lease_matches_incarnation() {
    local lease="$1" path aid birth dev ino live_aid live_birth live_dev live_ino
    path="$(_lease_get "$lease" path)"
    aid="$(_lease_get "$lease" admin_id)"
    birth="$(_lease_get "$lease" admin_birth_epoch)"
    dev="$(_lease_get "$lease" checkout_dev)"
    ino="$(_lease_get "$lease" checkout_ino)"
    [[ -n "$path" && -n "$aid" ]] || return 1
    IFS=$'\t' read -r live_aid live_birth < <(_lease_admin_info "$path")
    [[ "$live_aid" == "$aid" ]] || return 1
    [[ "$live_birth" == "$birth" ]] || return 1
    # Legacy lease (pre-checkout-identity): admin/birth proof is authoritative.
    [[ -z "$dev" && -z "$ino" ]] && return 0
    # A lease must record both fields or neither; a partial record is corrupt.
    [[ -n "$dev" && -n "$ino" ]] || return 1
    IFS=$'\t' read -r live_dev live_ino < <(python3 - "$path" <<'PY'
import os,sys
try:
    st=os.stat(sys.argv[1]); print(f"{st.st_dev}\t{st.st_ino}")
except OSError: print("-\t-")
PY
)
    [[ "$live_dev" == "$dev" && "$live_ino" == "$ino" ]]
}

# lease_prune_birth_audit_scratch [now_epoch] — unlink expired or missing-path
# ownerless scratch adoption leases written by birth-audit. Never touches
# worktree/clone/evidence leases, pending leases, owned leases, non-birth-audit
# leases, symlinks, or hash-mismatched files (fail closed on any ambiguity).
lease_prune_birth_audit_scratch() {
    local ld
    ld="$(lease_dir)"
    [[ -d "$ld" && ! -L "$ld" ]] || return 0
    python3 - "$ld" "${1:-}" <<'PY'
import hashlib, json, os, stat, sys, time

ld = sys.argv[1]
try:
    now = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else time.time()
except (TypeError, ValueError):
    now = time.time()

try:
    entries = list(os.scandir(ld))
except OSError:
    sys.exit(0)

for entry in entries:
    n = entry.name
    if not n.endswith(".json") or n.startswith("."):
        continue
    fp = entry.path
    try:
        st = os.lstat(fp)
    except OSError:
        continue
    if not stat.S_ISREG(st.st_mode):
        continue
    if os.path.lexists(fp + ".reuse-lock"):
        continue
    try:
        with open(fp, "rb") as f:
            d = json.load(f)
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    p = d.get("path")
    if not (isinstance(p, str) and bool(p)):
        continue
    if not ("owner" in d and d["owner"] is None):
        continue
    if d.get("pending") is not False:
        continue
    if d.get("creator") != "birth-audit":
        continue
    if d.get("kind") != "scratch":
        continue
    try:
        real = os.path.realpath(p)
        encoded = os.fsencode(real)
        path_gone = not os.path.lexists(p) and not os.path.exists(real)
    except (ValueError, UnicodeError, OSError):
        continue
    if n != hashlib.sha256(encoded).hexdigest()[:16] + ".json":
        continue
    exp = d.get("expires_at")
    ce = d.get("created_epoch")
    ttl = d.get("ttl_hours")
    exp_ok = isinstance(exp, (int, float)) and not isinstance(exp, bool) and exp > 0
    ce_ok = (
        isinstance(ce, (int, float))
        and not isinstance(ce, bool)
        and ce > 0
        and isinstance(ttl, (int, float))
        and not isinstance(ttl, bool)
        and ttl > 0
    )
    if "expires_at" in d and not exp_ok:
        ttl_expired = False
    else:
        ttl_expired = (exp_ok and now >= exp) or (ce_ok and now >= ce + ttl * 3600)
    if path_gone or ttl_expired:
        try:
            os.unlink(fp)
        except OSError:
            pass
PY
}
