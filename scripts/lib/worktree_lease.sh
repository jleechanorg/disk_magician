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
    birth="$(stat -f %B "$gitdir" 2>/dev/null || stat -c %W "$gitdir" 2>/dev/null || echo 0)"
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
import hashlib, json, os, sys, tempfile
path, expected, branch, tip, owner_tsv, repo, worktree, admin_id, admin_birth, checkout_dev, checkout_ino = sys.argv[1:]
lock = path + ".reuse-lock"
try:
    os.mkdir(lock)
except OSError:
    sys.exit(1)
try:
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
    try: os.rmdir(lock)
    except OSError: pass
PY
}

# The reaper holds this same lock from its final check through removal.
lease_reuse_lock_acquire() { mkdir "$1.reuse-lock" 2>/dev/null; }
lease_reuse_lock_release() { rmdir "$1.reuse-lock" 2>/dev/null; }
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
    "owner": owner,
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
    local lease="$1" now="${2:-}" inspect
    inspect="$(python3 - "$lease" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    print("unreadable"); sys.exit(0)
o = d.get("owner")
if o is None:
    print("none"); sys.exit(0)
if not isinstance(o, dict) or not isinstance(o.get("pid"), int) or isinstance(o.get("pid"), bool):
    print("unreadable"); sys.exit(0)
if d.get("released_at"):
    print("released"); sys.exit(0)
print("check\t%d\t%s\t%s\t%s\t%s" % (o["pid"], o.get("start_epoch", ""),
      o.get("comm", ""), d.get("created_epoch", ""),
      d.get("ttl_hours", 24)))
PY
)"
    case "$inspect" in
        unreadable|none|released)
            printf '%s\n' "$inspect"; return 0 ;;
    esac
    local _tag pid start comm created ttl
    IFS=$'\t' read -r _tag pid start comm created ttl <<<"$inspect"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { printf 'unreadable\n'; return 0; }
    [[ "$now" =~ ^[1-9][0-9]*$ ]] || now="$(date +%s)"
    local out err rc err_file cur_ep cur_comm stored_base cur_base diff
    err_file="$(mktemp)"
    out="$(LC_ALL=C TZ=UTC _lease_ps -p "$pid" -o lstart= 2>"$err_file")"; rc=$?
    err="$(<"$err_file")"; rm -f "$err_file"
    if (( rc == 1 )) && [[ -z "$out" && -z "$err" ]]; then
        printf 'dead\n'; return 0
    fi
    if (( rc != 0 )); then
        printf 'unknown\n'; return 0
    fi
    [[ -n "${out//[[:space:]]/}" ]] || { printf 'unknown\n'; return 0; }
    cur_ep="$(_lease_lstart_to_epoch "$out")" || { printf 'unknown\n'; return 0; }
    [[ "$cur_ep" =~ ^-?[0-9]+$ && "$start" =~ ^-?[0-9]+$ ]] || { printf 'unknown\n'; return 0; }
    if (( cur_ep > start )); then diff=$(( cur_ep - start )); else diff=$(( start - cur_ep )); fi
    (( diff > 2 )) && { printf 'dead\n'; return 0; }
    cur_comm="$(_lease_full_comm "$pid")"
    stored_base="${comm##*/}"
    cur_base="${cur_comm##*/}"
    if [[ -n "$cur_base" && "$cur_base" != "$stored_base" ]] &&
       [[ "$stored_base" != "$cur_base"* && "$cur_base" != "$stored_base"* ]]; then
        printf 'unknown\n'; return 0
    fi
    if [[ "$created" =~ ^[0-9]+$ && "$ttl" =~ ^[0-9]+$ ]] && (( now >= created + ttl * 3600 )); then
        printf 'alive-expired\n'; return 0
    fi
    printf 'alive\n'
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
import json, os, sys
from datetime import datetime, timezone
lease, pid, ep = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    with open(lease) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
o = d.get("owner")
if not isinstance(o, dict) or not isinstance(o.get("pid"), int) or o["pid"] != pid:
    sys.exit(1)
try:
    if str(int(o.get("start_epoch"))) != ep:
        sys.exit(1)
except (TypeError, ValueError):
    sys.exit(1)
d["released_at"] = datetime.now(timezone.utc).isoformat()
tmp = lease + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
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
# "self|other<TAB>pid<TAB>epoch<TAB>path"; commit marks released (flock, fsync, rename)
# only if the re-read lease still has that owner, else rc 1.
_lease_session_release() {
    local mode="$1" p="$2"
    if [[ "$mode" == commit ]]; then lease_mutation_lock_enter "$p" || return 1; fi
    python3 - "$@" <<'PY'
import fcntl, json, os, sys, tempfile
from datetime import datetime, timezone
mode, p, sid, pid, ep = sys.argv[1:]
try:
    lk = open(p[:-5] + ".lock", "a") if mode == "commit" else None
    lk and fcntl.flock(lk, fcntl.LOCK_EX)
    d = json.load(open(p)); o = d.get("owner")
    o = (str(o.get("pid")), str(o.get("start_epoch"))) if isinstance(o, dict) and o.get("session") == sid and not d.get("released_at") else None
    if mode == "scan":
        o and print("%s\t%s\t%s\t%s" % ("self" if o == (pid, ep) else "other", o[0], o[1], d.get("path", "")))
    elif o == (pid, ep):
        d["released_at"] = datetime.now(timezone.utc).isoformat()
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".release-")
        with os.fdopen(fd, "w") as f:
            json.dump(d, f, indent=2); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, p)
    else:
        sys.exit(1)
except Exception:
    sys.exit(1)
PY
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
# admin_birth_epoch still match the live admin dir for its path. Any
# unresolvable side is a mismatch (the reaper then re-adopts with owner:
# null, which can never be owner-reaped — the safe direction).
lease_matches_incarnation() {
    local lease="$1" path aid birth live_aid live_birth dev ino live_dev live_ino
    path="$(_lease_get "$lease" path)"
    aid="$(_lease_get "$lease" admin_id)"
    birth="$(_lease_get "$lease" admin_birth_epoch)"
    dev="$(_lease_get "$lease" checkout_dev)"
    ino="$(_lease_get "$lease" checkout_ino)"
    [[ -n "$path" && -n "$aid" && -n "$dev" && -n "$ino" ]] || return 1
    IFS=$'\t' read -r live_dev live_ino < <(python3 - "$path" <<'PY'
import os,sys
try:
    st=os.stat(sys.argv[1]); print(f"{st.st_dev}\t{st.st_ino}")
except OSError: print("-\t-")
PY
)
    [[ "$live_dev" == "$dev" && "$live_ino" == "$ino" ]] || return 1
    IFS=$'\t' read -r live_aid live_birth < <(_lease_admin_info "$path")
    [[ "$live_aid" == "$aid" ]] || return 1
    [[ "$live_birth" == "$birth" ]] || return 1
    return 0
}
