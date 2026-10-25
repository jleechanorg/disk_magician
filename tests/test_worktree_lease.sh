#!/usr/bin/env bash
# test_worktree_lease.sh — the worktree lease library (plan Task 2).
#
# Covers: lease write/read, owner resolution (runtime ancestors, hermes
# detection, pid cycles), liveness by pid + lstart epoch (pid reuse, comm
# mismatch, 16-char comm truncation, TZ/LANG pinning), release by owner,
# pending leases, incarnation match, and the unreadable/unknown fail-closed
# states.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/worktree_lease.sh
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local actual="$1" expected="$2" what="$3"
    if [[ "$actual" == "$expected" ]]; then ok "$what (= $expected)"; else bad "$what — expected '$expected', got '$actual'"; fi
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"

# ---------------------------------------------------------------- fake ps ---
FAKE_PS_DIR="$TMPROOT/psdata"
FAKE_PS="$TMPROOT/fake_ps"
mkdir -p "$FAKE_PS_DIR"
export FAKE_PS_DIR
cat > "$FAKE_PS" <<'EOS'
#!/usr/bin/env bash
# fake ps — table-driven stand-in. Honors -A (always fails, like an empty
# process listing) and per-pid tables under $FAKE_PS_DIR:
#   comm/<pid>    "<ppid>\t<comm>"
#   lstart/<pid>  "<lstart string>"
#   args/<pid>    "<full command line>"
#   fail/<pid>    "<rc> [stderr message]"
pid="" spec="" saw_a=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) pid="$2"; shift 2 ;;
        -o) spec="$2"; shift 2 ;;
        -A) saw_a=1; shift ;;
        *) shift ;;
    esac
done
base="${FAKE_PS_DIR:?}"
if [[ "$saw_a" == 1 ]]; then exit 2; fi
if [[ -n "$pid" && -f "$base/fail/$pid" ]]; then
    read -r rcode rest < "$base/fail/$pid" || true
    [[ -n "${rest:-}" ]] && printf '%s\n' "$rest" >&2
    exit "$rcode"
fi
case "$spec" in
    ppid=,comm=)
        [[ -f "$base/comm/$pid" ]] && cat "$base/comm/$pid" || exit 1 ;;
    comm=)
        [[ -f "$base/comm/$pid" ]] && awk '{print $2}' "$base/comm/$pid" || exit 1 ;;
    lstart=)
        [[ -f "$base/lstart/$pid" ]] && cat "$base/lstart/$pid" || exit 1 ;;
    args=)
        [[ -f "$base/args/$pid" ]] && cat "$base/args/$pid" || exit 1 ;;
    *) exit 2 ;;
esac
EOS
chmod +x "$FAKE_PS"

seed_comm()    { mkdir -p "$FAKE_PS_DIR/comm";    printf '%s\t%s\n' "$2" "$3" > "$FAKE_PS_DIR/comm/$1"; }
seed_lstart()  { mkdir -p "$FAKE_PS_DIR/lstart";  printf '%s\n' "$2" > "$FAKE_PS_DIR/lstart/$1"; }
seed_args()    { mkdir -p "$FAKE_PS_DIR/args";    printf '%s\n' "$2" > "$FAKE_PS_DIR/args/$1"; }
seed_fail()    { mkdir -p "$FAKE_PS_DIR/fail";    printf '%s\n' "$2" > "$FAKE_PS_DIR/fail/$1"; }
clear_pid()    { rm -f "$FAKE_PS_DIR/comm/$1" "$FAKE_PS_DIR/lstart/$1" "$FAKE_PS_DIR/args/$1" "$FAKE_PS_DIR/fail/$1"; }

# A fixed owner epoch and its ps lstart rendering (day >= 10, no padding
# ambiguity). Both the fake and the real parser must agree on it.
OWNER_EPOCH=1760000000
OWNER_LSTART="$(python3 -c '
from datetime import datetime, timezone
print(datetime.fromtimestamp(1760000000, tz=timezone.utc).strftime("%a %b %d %H:%M:%S %Y"))')"

TESTPID="$$"   # the running test shell's pid

# ------------------------------------------------------------- fixtures ---
mk_wt() { # mk_wt <name> — linked-worktree shape with a real admin dir
    local wt="$TMPROOT/wt/$1"
    mkdir -p "$wt/src" "$TMPROOT/.gitadmin/$1"
    echo "gitdir: $TMPROOT/.gitadmin/$1" > "$wt/.git"
    : > "$TMPROOT/.gitadmin/$1/HEAD"
    echo "$wt"
}

craft_lease() { # craft_lease <wt-path> <owner-pid> <start-epoch> <comm> [created-epoch]
    local l
    l="$(lease_path_for "$1")"
    python3 - "$l" "$1" "${2:-}" "${3:-}" "${4:-}" "${5:-$(date +%s)}" <<'PY'
import json, sys, os
lease, path, pid, ep, comm, created = sys.argv[1:7]
try:
    owner = {"pid": int(pid), "start_epoch": int(ep), "comm": comm} if pid.isdigit() and ep.lstrip("-").isdigit() else {"pid": pid, "start_epoch": ep, "comm": comm}
except ValueError:
    owner = {"pid": pid, "start_epoch": ep, "comm": comm}
if not pid:
    owner = None
d = {"schema_version": 1, "path": path, "repo": "r", "branch": "b", "creator": "test",
     "pending": False, "created_at": "2026-10-09T12:00:00+00:00",
     "created_epoch": int(created), "ttl_hours": 24, "owner": owner,
     "admin_id": None, "admin_birth_epoch": None, "released_at": None,
     "last_verdict": None, "last_checked_at": None}
os.makedirs(os.path.dirname(lease), exist_ok=True)
tmp = lease + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, lease)
PY
}

lease_field() { # lease_field <lease-file> <pyexpr over d>
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(eval(sys.argv[2], {"d": d}))
except Exception:
    print("ERR")
PY
}

echo "== lease_write produces a valid lease =="
seed_comm "$TESTPID" 400 bash
seed_comm 400 1 claude
seed_lstart 400 "$OWNER_LSTART"
export DISK_MAGICIAN_PS_BIN="$FAKE_PS"
WT1="$(mk_wt wt_one)"
if lease_write "$WT1" "myrepo" "fix/x" "worktree-new"; then ok "lease_write rc 0"; else bad "lease_write failed"; fi
L1="$(lease_path_for "$WT1")"
assert_eq "$(lease_field "$L1" 'd["schema_version"]')" "1" "schema_version"
assert_eq "$(lease_field "$L1" 'd["path"]')" "$WT1" "recorded path"
assert_eq "$(lease_field "$L1" 'd["branch"]')" "fix/x" "recorded branch"
assert_eq "$(lease_field "$L1" 'd["creator"]')" "worktree-new" "recorded creator"
assert_eq "$(lease_field "$L1" 'd["owner"]["pid"]')" "400" "owner pid resolved from ancestry"
assert_eq "$(lease_field "$L1" 'd["owner"]["start_epoch"]')" "$OWNER_EPOCH" "owner start_epoch"
assert_eq "$(lease_field "$L1" 'type(d["created_epoch"]) is int')" "True" "integer created_epoch"

echo "== lease_resolve_owner walks to the nearest runtime ancestor =="
seed_comm 500 400 sh
R="$(lease_resolve_owner 500 | cut -f1,3)"
assert_eq "$R" "$(printf '400\tclaude')" "resolve 500 -> 400/claude"
seed_comm 700 1 bash
assert_eq "$(lease_resolve_owner 700 | cut -f1,2,3)" "$(printf -- '-\t-\t-')" "no runtime in chain -> none"
seed_comm 5 6 x
seed_comm 6 5 y
assert_eq "$(lease_resolve_owner 5 | cut -f1,2,3)" "$(printf -- '-\t-\t-')" "pid cycle terminates -> none"
seed_comm 600 1 python3.13
seed_lstart 600 "$OWNER_LSTART"
seed_args 600 "/usr/bin/python3.13 /opt/hermes/hermes_gateway.py --serve"
assert_eq "$(lease_resolve_owner 600 | cut -f1,3)" "$(printf '600\thermes')" "hermes python script detected as owner"

echo "== no runtime ancestor stores owner null =="
seed_comm "$TESTPID" 1 bash
WT2="$(mk_wt wt_nullowner)"
lease_write "$WT2" "myrepo" "fix/y" "worktree-new"
L2="$(lease_path_for "$WT2")"
assert_eq "$(lease_field "$L2" 'd["owner"]')" "None" "owner null when no runtime ancestor"
assert_eq "$(lease_owner_state "$L2")" "none" "owner_state none for null owner"

echo "== owner liveness =="
# restore a claude ancestor for the test shell
seed_comm "$TESTPID" 400 bash
assert_eq "$(lease_owner_state "$L1")" "alive" "same lstart -> alive"
seed_fail 400 "1"
assert_eq "$(lease_owner_state "$L1")" "dead" "ps rc 1 empty stderr -> dead"
rm -f "$FAKE_PS_DIR/fail/400"
seed_lstart 400 "$(python3 -c '
from datetime import datetime, timezone
print(datetime.fromtimestamp(1760000000 + 10, tz=timezone.utc).strftime("%a %b %d %H:%M:%S %Y"))')"
assert_eq "$(lease_owner_state "$L1")" "dead" "start epoch 10s off -> dead (pid reuse)"
seed_lstart 400 "$OWNER_LSTART"
seed_args 400 "/bin/someotherthing -x"
assert_eq "$(lease_owner_state "$L1")" "unknown" "epoch matches but comm differs -> unknown"
rm -f "$FAKE_PS_DIR/args/400"

echo "== TTL expiry while owner alive =="
E25H=$(( $(date +%s) - 25*3600 ))
WT3="$(mk_wt wt_expired)"
craft_lease "$WT3" 400 "$OWNER_EPOCH" claude "$E25H"
L3="$(lease_path_for "$WT3")"
assert_eq "$(lease_owner_state "$L3")" "alive-expired" "alive owner past 24h TTL -> alive-expired"

echo "== release by owner =="
if lease_release "$WT1"; then ok "lease_release by owner rc 0"; else bad "lease_release by owner failed"; fi
assert_eq "$(lease_owner_state "$L1")" "released" "released state overrides live owner"
assert_eq "$(lease_field "$L1" 'd["released_at"] is not None')" "True" "released_at recorded"

echo "== release by non-owner fails =="
WT4="$(mk_wt wt_other)"
craft_lease "$WT4" 401 "$OWNER_EPOCH" claude
L4="$(lease_path_for "$WT4")"
SUM_BEFORE="$(shasum -a 256 "$L4" | cut -d' ' -f1)"
if lease_release "$WT4" 2> "$TMPROOT/rel_err"; then bad "non-owner release succeeded"; else ok "non-owner release rc 1"; fi
grep -q "not lease owner" "$TMPROOT/rel_err" && ok "stderr says not lease owner" || bad "stderr missing 'not lease owner'"
assert_eq "$(shasum -a 256 "$L4" | cut -d' ' -f1)" "$SUM_BEFORE" "lease byte-identical after refused release"
WT5="$(mk_wt wt_nullease)"
craft_lease "$WT5" "" "" ""
if lease_release "$WT5" 2>/dev/null; then bad "null-owner lease released"; else ok "null-owner lease -> rc 1"; fi
seed_comm "$TESTPID" 1 bash
if lease_release "$WT1" 2>/dev/null; then bad "caller with no resolvable owner released"; else ok "unresolvable caller -> rc 1"; fi
seed_comm "$TESTPID" 400 bash
if lease_release "$TMPROOT/never_leased_wt" 2> "$TMPROOT/nl_err"; then bad "unleased release succeeded"; else ok "unleased path -> rc 1"; fi
grep -q "no lease" "$TMPROOT/nl_err" && ok "stderr says no lease" || bad "stderr missing 'no lease'"

echo "== unreadable and oversized pids =="
WT6="$(mk_wt wt_badpids)"
craft_lease "$WT6" 99999999999 "$OWNER_EPOCH" claude
seed_fail 99999999999 "1 ps: process id too large"
assert_eq "$(lease_owner_state "$(lease_path_for "$WT6")")" "unknown" "ps 'id too large' rc1-with-stderr -> unknown, not dead"
WT7="$(mk_wt wt_pidabc)"
craft_lease "$WT7" abc "$OWNER_EPOCH" claude
assert_eq "$(lease_owner_state "$(lease_path_for "$WT7")")" "unreadable" "non-integer pid -> unreadable"

echo "== -A listing empty but -p hops resolve =="
# (fake ps exits 2 on -A; resolution must go through -p per hop)
assert_eq "$(lease_resolve_owner 500 | cut -f1,3)" "$(printf '400\tclaude')" "resolve works when ps -A is useless"

echo "== real ps: TZ/LANG pinning and >16-char comm =="
unset DISK_MAGICIAN_PS_BIN
LONGNAME="$TMPROOT/a-very-long-executable-name-xyz"
# /bin/* are dyld shared-cache stubs on modern macOS; a copy cannot exec
# (SIGKILL). Build a real binary instead so comm really is over 16 chars.
if printf '#include <unistd.h>\nint main(void){for(;;)pause();}' | clang -x c - -o "$LONGNAME" 2>/dev/null; then
    "$LONGNAME" &
    SLEEP_PID=$!
    REAL_EPOCH="$(python3 - "$SLEEP_PID" <<'PY'
import subprocess, sys
from datetime import datetime, timezone
out = subprocess.run(["ps", "-p", sys.argv[1], "-o", "lstart="],
                     capture_output=True, text=True,
                     env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "TZ": "UTC"}).stdout.strip()
print(int(datetime.strptime(out, "%a %b %d %H:%M:%S %Y").replace(tzinfo=timezone.utc).timestamp()))
PY
)"
    WT8="$(mk_wt wt_realps)"
    craft_lease "$WT8" "$SLEEP_PID" "$REAL_EPOCH" "a-very-long-executable-name-xyz"
    L8="$(lease_path_for "$WT8")"
    A="$(TZ=America/Los_Angeles LANG=fr_FR.UTF-8 lease_owner_state "$L8")"
    B="$(TZ=UTC LANG=C lease_owner_state "$L8")"
    assert_eq "$A" "alive" "owner alive under TZ=America/Los_Angeles LANG=fr_FR.UTF-8"
    assert_eq "$B" "alive" "owner alive under TZ=UTC LANG=C"
    kill "$SLEEP_PID" 2>/dev/null
else
    echo "  SKIP: clang unavailable; >16-char comm case not exercisable"
fi
export DISK_MAGICIAN_PS_BIN="$FAKE_PS"

echo "== lease_write records admin incarnation =="
WT9="$(mk_wt wt_admin)"
seed_comm "$TESTPID" 400 bash
lease_write "$WT9" "myrepo" "fix/z" "worktree-new"
L9="$(lease_path_for "$WT9")"
if [[ $(uname -s) == Darwin ]]; then ADMIN_BIRTH="$(stat -f %B "$TMPROOT/.gitadmin/wt_admin")"; else ADMIN_BIRTH="$(stat -c %W "$TMPROOT/.gitadmin/wt_admin")"; fi
assert_eq "$(lease_field "$L9" 'd["admin_id"]')" "wt_admin" "admin_id from admin dir name"
assert_eq "$(lease_field "$L9" 'd["admin_birth_epoch"]')" "$ADMIN_BIRTH" "admin_birth_epoch from platform stat birth time"
if lease_matches_incarnation "$L9"; then ok "incarnation matches -> rc 0"; else bad "incarnation should match"; fi
# recreate the admin dir -> new birth time -> stale lease
rm -rf "$TMPROOT/.gitadmin/wt_admin"
mkdir -p "$TMPROOT/.gitadmin/wt_admin"
: > "$TMPROOT/.gitadmin/wt_admin/HEAD"
sleep 1
rm -rf "$TMPROOT/.gitadmin/wt_admin"      # ensure creation time moves
mkdir -p "$TMPROOT/.gitadmin/wt_admin"
: > "$TMPROOT/.gitadmin/wt_admin/HEAD"
if [[ $(uname -s) == Darwin ]]; then NEW_BIRTH="$(stat -f %B "$TMPROOT/.gitadmin/wt_admin")"; else NEW_BIRTH="$(stat -c %W "$TMPROOT/.gitadmin/wt_admin")"; fi
if lease_matches_incarnation "$L9"; then bad "recreated admin dir still matches (stale lease undetected)"; else ok "recreated admin dir -> no match (rc 1)"; fi

echo "== lease_matches_incarnation: legacy fallback and strict checkout identity =="
WTL="$(mk_wt wt_legacy)"
seed_comm "$TESTPID" 400 bash
lease_write "$WTL" "myrepo" "fix/legacy" "worktree-new"
LL="$(lease_path_for "$WTL")"
if lease_matches_incarnation "$LL"; then ok "lease with checkout identity matches"; else bad "lease with checkout identity should match"; fi
lease_field_drop() { python3 - "$1" "$2" <<'PY'
import json,sys
p,keys=sys.argv[1],sys.argv[2].split(',')
d=json.load(open(p))
for k in keys: d.pop(k,None)
json.dump(d,open(p,'w'))
PY
}
lease_field_drop "$LL" 'checkout_dev,checkout_ino'
if lease_matches_incarnation "$LL"; then ok "legacy lease without dev/ino matches via admin/birth"; else bad "legacy lease should match via admin/birth"; fi
# stale recorded identity must fail even when admin/birth still match
python3 - "$LL" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["checkout_dev"]=1; d["checkout_ino"]=1
json.dump(d,open(p,'w'))
PY
if lease_matches_incarnation "$LL"; then bad "stale checkout identity must not match"; else ok "stale checkout identity -> no match (rc 1)"; fi
# a replacement checkout gets a new admin dir/birth -> no match even for legacy
lease_field_drop "$LL" 'checkout_dev,checkout_ino'
sleep 1
rm -rf "$TMPROOT/.gitadmin/wt_legacy"; mkdir -p "$TMPROOT/.gitadmin/wt_legacy"; : > "$TMPROOT/.gitadmin/wt_legacy/HEAD"
if lease_matches_incarnation "$LL"; then bad "replacement admin dir must not match a legacy lease"; else ok "replacement admin dir -> no match (rc 1)"; fi

echo "== lease_write_pending =="
PENDING_TARGET="$TMPROOT/wt/future_wt"
PTSV="$(printf '400\t%s\tclaude' "$OWNER_EPOCH")"
if lease_write_pending "$PENDING_TARGET" "$PTSV"; then ok "pending lease written"; else bad "pending lease write failed"; fi
LP="$(lease_path_for "$PENDING_TARGET")"
assert_eq "$(lease_field "$LP" 'd["creator"]')" "guard" "pending lease creator guard"
assert_eq "$(lease_field "$LP" 'd["pending"]')" "True" "pending flag set"
if lease_write_pending "$PENDING_TARGET" "$PTSV"; then
    ok "replacement of pending lease whose path still absent is allowed"
else
    bad "second pending write on a still-absent path must be allowed (replacement)"
fi
mkdir -p "$PENDING_TARGET"
if lease_write_pending "$PENDING_TARGET" "$PTSV" 2>/dev/null; then bad "existing target path must refuse"; else ok "existing path -> rc 1"; fi
# a lease for an EXISTING worktree must never be overwritten by pending
if lease_write_pending "$WT9" "$PTSV" 2>/dev/null; then bad "pending write over live lease+worktree succeeded"; else ok "existing lease for existing worktree -> rc 1"; fi
assert_eq "$(lease_field "$L9" 'd["creator"]')" "worktree-new" "live lease untouched by refused pending write"

echo "== lease_set_verdict =="
lease_set_verdict "$L9" "kept:dirty"
assert_eq "$(lease_field "$L9" 'd["last_verdict"]')" "kept:dirty" "last_verdict updated"
assert_eq "$(lease_field "$L9" 'd["last_checked_at"] is not None')" "True" "last_checked_at set"

echo "== lease kind and provenance fields (governor C3, part 1) =="
PROV="$TMPROOT/prov"; mkdir -p "$PROV"
printf '[{"path": "a.txt", "sha256": "%s"}]\n' "$(printf a | shasum -a 256 | cut -c1-64)" > "$PROV/inv.json"
cat > "$PROV/upload.json" <<'EOJ'
[{"path": "a.txt", "sha256": "ca978112", "md5": "0cc175b9", "crc32c": "6sRbVQ==", "size": 1,
  "object": "gs://b/a.txt", "generation": "1760000000000001"}]
EOJ
cat > "$PROV/upload_bad.json" <<'EOJ'
[{"path": "a.txt", "sha256": "ca978112", "crc32c": "6sRbVQ==", "size": 1, "object": "gs://b/a.txt", "generation": "1"}]
EOJ
printf '{"head": "abc123", "refs": {"refs/heads/x": "abc123"}}\n' > "$PROV/gitmeta.json"
WTS="$(mk_wt wt_scratch)"
if lease_write "$WTS" --kind scratch --producer gate-prep --source 'git:https://example.com/r.git@abc123' --manifest "$PROV/inv.json"; then
    ok "provenance lease_write rc 0"
else
    bad "provenance lease_write failed"
fi
LS="$(lease_path_for "$WTS")"
assert_eq "$(lease_field "$LS" 'd["kind"]')" "scratch" "kind round-trips"
assert_eq "$(lease_field "$LS" 'd["producer"]')" "gate-prep" "producer round-trips"
assert_eq "$(lease_field "$LS" 'd["source"]')" "git:https://example.com/r.git@abc123" "source round-trips"
assert_eq "$(lease_field "$LS" 'd["manifest"][0]["path"]')" "a.txt" "manifest stored as inventory"
assert_eq "$(lease_field "$LS" 'd["published"]')" "False" "manifest alone never sets published"
assert_eq "$(lease_field "$LS" 'd["verified_at"] is None and d["published_url"] is None')" "True" "manifest alone sets no publication fields"
assert_eq "$(lease_kind "$LS")" "scratch" "lease_kind reads kind"

assert_eq "$(lease_field "$L1" 'd.get("kind")')" "worktree" "no --kind -> worktree"
assert_eq "$(lease_field "$L1" 'd.get("producer") is None and d.get("source") is None')" "True" "no --kind -> no provenance"
LOLD="$TMPROOT/old_lease.json"
printf '{"schema_version": 1, "path": "/x", "owner": null}\n' > "$LOLD"
assert_eq "$(lease_kind "$LOLD")" "worktree" "pre-existing lease without kind reads worktree"
printf 'not json' > "$TMPROOT/garbage_lease.json"
assert_eq "$(lease_kind "$TMPROOT/garbage_lease.json")" "unreadable" "unreadable lease kind"

WTB="$(mk_wt wt_bad)"
LB="$(lease_path_for "$WTB")"
lease_write "$WTB" --kind bogus >/dev/null 2>&1; assert_eq "$?" "2" "--kind bogus -> rc 2"
[[ -e "$LB" ]] && bad "--kind bogus wrote a lease" || ok "--kind bogus wrote nothing"
lease_write "$WTB" --frobnicate x >/dev/null 2>&1; assert_eq "$?" "2" "unknown option -> rc 2"
lease_write "$WTB" --published https://x/y >/dev/null 2>&1; assert_eq "$?" "2" "--published without manifest or verified-at -> rc 2"
lease_write "$WTB" --published https://x/y --upload-manifest "$PROV/upload.json" >/dev/null 2>&1
assert_eq "$?" "2" "--published without --verified-at -> rc 2"
lease_write "$WTB" --published https://x/y --verified-at 2026-10-12T00:00:00Z >/dev/null 2>&1
assert_eq "$?" "2" "--published without --upload-manifest -> rc 2"
lease_write "$WTB" --published https://x/y --upload-manifest "$PROV/upload_bad.json" --verified-at 2026-10-12T00:00:00Z >/dev/null 2>&1
assert_eq "$?" "2" "upload manifest entry missing md5 -> rc 2"
lease_write "$WTB" --upload-manifest "$PROV/upload.json" --verified-at 2026-10-12T00:00:00Z >/dev/null 2>&1
assert_eq "$?" "2" "upload manifest without --published -> rc 2"
lease_write "$WTB" --manifest "$PROV/missing.json" >/dev/null 2>&1; assert_eq "$?" "2" "unreadable manifest -> rc 2"
[[ -e "$LB" ]] && bad "a refused write left a lease" || ok "refused writes leave no lease"

WTE="$(mk_wt wt_evidence)"
if lease_write "$WTE" myrepo "" evidence-push --kind evidence --published gs://b/run1 \
    --upload-manifest "$PROV/upload.json" --verified-at 2026-10-12T00:00:00Z --git-meta "$PROV/gitmeta.json"; then
    ok "published lease_write rc 0"
else
    bad "published lease_write failed"
fi
LE="$(lease_path_for "$WTE")"
assert_eq "$(lease_field "$LE" 'd["repo"]')" "myrepo" "positional args still honoured with options"
assert_eq "$(lease_field "$LE" 'd["kind"]')" "evidence" "evidence kind"
assert_eq "$(lease_field "$LE" 'd["published"]')" "True" "published set"
assert_eq "$(lease_field "$LE" 'd["published_url"]')" "gs://b/run1" "published_url"
assert_eq "$(lease_field "$LE" 'd["verified_at"]')" "2026-10-12T00:00:00Z" "verified_at"
assert_eq "$(lease_field "$LE" 'd["published_at"] is not None')" "True" "published_at set"
assert_eq "$(lease_field "$LE" 'sorted(d["upload_manifest"][0])')" "['crc32c', 'generation', 'md5', 'object', 'path', 'sha256', 'size']" "upload manifest fields per file"
assert_eq "$(lease_field "$LE" 'd["git_meta"]["head"]')" "abc123" "git metadata baseline stored"
lease_set_verdict "$LE" "kept:test"
assert_eq "$(lease_field "$LE" 'd["kind"] + str(d["published"])')" "evidenceTrue" "provenance survives verdict update"

echo "== atomic reuse lease claim and recovery =="
REUSE_WT="$(mk_wt wt_reuse)"
lease_write "$REUSE_WT" myrepo old-branch test
REUSE_LEASE="$(lease_path_for "$REUSE_WT")"
REUSE_HASH="$(python3 - "$REUSE_LEASE" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)"
REUSE_OWNER="$(printf '500\t%s\tcodex' "$OWNER_EPOCH")"
if lease_claim_reuse "$REUSE_LEASE" "$REUSE_HASH" old-branch abc123 "$REUSE_OWNER"; then ok "exact lease claimed"; else bad "exact lease claim failed"; fi
assert_eq "$(lease_field "$REUSE_LEASE" 'd["reuse"]["old_branch"]')" "old-branch" "old branch preserved in claim"
assert_eq "$(lease_field "$REUSE_LEASE" 'd["reuse"]["old_tip"]')" "abc123" "old tip preserved in claim"
if lease_claim_reuse "$REUSE_LEASE" "$REUSE_HASH" old-branch abc123 "$REUSE_OWNER"; then bad "stale lease claim succeeded"; else ok "stale/concurrent lease claim refused"; fi
if lease_restore_reuse_claim "$REUSE_LEASE"; then ok "claim rollback restored"; else bad "claim rollback failed"; fi
assert_eq "$(python3 - "$REUSE_LEASE" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)" "$REUSE_HASH" "rollback restores exact original lease"
if lease_claim_reuse "$REUSE_LEASE" "$REUSE_HASH" old-branch abc123 "$REUSE_OWNER" && lease_mark_reuse_incomplete "$REUSE_LEASE"; then ok "incomplete reuse marked"; else bad "incomplete reuse marker failed"; fi
assert_eq "$(lease_field "$REUSE_LEASE" 'd["reuse"]["state"]')" "reuse_incomplete" "incomplete state retained"

echo "== lease_prune_birth_audit_scratch =="
PRUNE_STATE="$TMPROOT/prune_state"
export DISK_MAGICIAN_STATE_DIR="$PRUNE_STATE"
mkdir -p "$(lease_dir)" "$TMPROOT/prune_paths"
NOW_PRUNE="$(date +%s)"

write_raw_lease() { # write_raw_lease <target_path> <json_override_py>
    local p="$1" py="$2" lf
    lf="$(lease_path_for "$p")"
    python3 - "$lf" "$p" "$NOW_PRUNE" "$py" <<'PY'
import json, os, sys
lf, p, now_s, py = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
d = {
    "schema_version": 1,
    "path": p,
    "repo": None,
    "branch": None,
    "creator": "birth-audit",
    "pending": False,
    "created_at": "2026-10-17T00:00:00+00:00",
    "created_epoch": now_s,
    "ttl_hours": 24,
    "owner": None,
    "kind": "scratch",
    "producer": "birth-audit",
}
exec(py, {"d": d, "now": now_s})
with open(lf, "w") as f:
    json.dump(d, f)
print(lf)
PY
}

# 1. Missing path birth-audit scratch lease -> pruned
P_GONE="$TMPROOT/prune_paths/gone_scratch"
mkdir -p "$P_GONE"
L_GONE="$(write_raw_lease "$P_GONE" "")"
rm -rf "$P_GONE"

# 2. Existing path birth-audit scratch lease with expires_at in the past -> pruned
P_EXP_AT="$TMPROOT/prune_paths/exp_at_scratch"
mkdir -p "$P_EXP_AT"
L_EXP_AT="$(write_raw_lease "$P_EXP_AT" 'd["expires_at"] = now - 60')"

# 3. Existing path birth-audit scratch lease with created_epoch+ttl_hours in the past -> pruned
P_EXP_CE="$TMPROOT/prune_paths/exp_ce_scratch"
mkdir -p "$P_EXP_CE"
L_EXP_CE="$(write_raw_lease "$P_EXP_CE" 'd["created_epoch"] = now - 25 * 3600')"

# 4. Live unexpired birth-audit scratch lease -> preserved
P_LIVE="$TMPROOT/prune_paths/live_scratch"
mkdir -p "$P_LIVE"
L_LIVE="$(write_raw_lease "$P_LIVE" 'd["expires_at"] = now + 3600')"

# 5. kind=worktree lease (even if missing and expired) -> preserved
P_WT="$TMPROOT/prune_paths/gone_wt"
mkdir -p "$P_WT"
L_WT="$(write_raw_lease "$P_WT" 'd["kind"] = "worktree"; d["expires_at"] = now - 60')"
rm -rf "$P_WT"

# 6. pending=true lease (even if missing and expired) -> preserved
P_PEND="$TMPROOT/prune_paths/gone_pending"
mkdir -p "$P_PEND"
L_PEND="$(write_raw_lease "$P_PEND" 'd["pending"] = True; d["expires_at"] = now - 60')"
rm -rf "$P_PEND"

# 7. owned lease (owner != null, even if missing and expired) -> preserved
P_OWNED="$TMPROOT/prune_paths/gone_owned"
mkdir -p "$P_OWNED"
L_OWNED="$(write_raw_lease "$P_OWNED" 'd["owner"] = {"pid": 400, "start_epoch": 1760000000, "comm": "claude"}; d["expires_at"] = now - 60')"
rm -rf "$P_OWNED"

# 8. hash-mismatched filename -> preserved
L_BADHASH="$(lease_dir)/0000000000000000.json"
cp "$L_GONE" "$L_BADHASH"

# 9. malformed path (embedded NUL byte) -> preserved and does not abort loop
L_NULPATH="$(lease_dir)/0000000000000001.json"
printf '{"schema_version":1,"path":"/tmp/bad\\u0000path","owner":null,"pending":false,"creator":"birth-audit","kind":"scratch","expires_at":1}\n' > "$L_NULPATH"

if lease_prune_birth_audit_scratch; then ok "lease_prune_birth_audit_scratch rc 0"; else bad "lease_prune_birth_audit_scratch failed"; fi
[[ ! -e "$L_GONE" ]] && ok "missing-path birth-audit scratch lease pruned" || bad "missing-path birth-audit scratch lease still exists"
[[ ! -e "$L_EXP_AT" ]] && ok "expired (expires_at) birth-audit scratch lease pruned" || bad "expired (expires_at) birth-audit scratch lease still exists"
[[ ! -e "$L_EXP_CE" ]] && ok "expired (created_epoch+ttl) birth-audit scratch lease pruned" || bad "expired (created_epoch+ttl) birth-audit scratch lease still exists"
[[ -f "$L_LIVE" ]] && ok "live unexpired birth-audit scratch lease preserved" || bad "live unexpired birth-audit scratch lease was pruned"
[[ -f "$L_WT" ]] && ok "worktree kind lease preserved even when missing/expired" || bad "worktree kind lease was pruned"
[[ -f "$L_PEND" ]] && ok "pending:true lease preserved even when missing/expired" || bad "pending:true lease was pruned"
[[ -f "$L_OWNED" ]] && ok "owned lease preserved even when missing/expired" || bad "owned lease was pruned"
[[ -f "$L_BADHASH" ]] && ok "hash-mismatched lease filename preserved" || bad "hash-mismatched lease filename was pruned"
[[ -f "$L_NULPATH" ]] && ok "embedded-NUL path lease preserved without aborting scan" || bad "embedded-NUL path lease was pruned"

echo "== multi-owner lease lifecycle =="
WT10="$(mk_wt wt_multi)"
lease_write "$WT10" myrepo fix/multi test
L10="$(lease_path_for "$WT10")"
seed_comm 700 1 codex
seed_lstart 700 "$OWNER_LSTART"
seed_args 700 "/usr/bin/codex"
if lease_owner_add "$WT10" 700 "$OWNER_EPOCH" codex; then ok "child owner appended"; else bad "child owner append failed"; fi
assert_eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["owners"]))' "$L10")" "2" "both parent and child owners retained"
assert_eq "$(lease_owner_state "$L10")" "alive" "live child keeps lease alive"
if lease_release "$WT10"; then ok "parent owner release succeeds"; else bad "parent owner release failed"; fi
assert_eq "$(lease_owner_state "$L10")" "alive" "child remains protective after parent release"
lease_resolve_owner() { printf "700\t%s\tcodex\n" "$OWNER_EPOCH"; }
if lease_release "$WT10"; then ok "child owner release succeeds"; else bad "child owner release failed"; fi
unset -f lease_resolve_owner
assert_eq "$(lease_owner_state "$L10")" "released" "lease released only after all owners release"

echo "== session release is owner-scoped =="
WT11="$(mk_wt wt_session_multi)"
lease_resolve_owner() { printf "400\t%s\tbash\n" "$OWNER_EPOCH"; }
lease_write "$WT11" myrepo fix/session test
L11="$(lease_path_for "$WT11")"
python3 - "$L11" "$OWNER_EPOCH" <<'PYSESSIONSEED'
import json,sys
p,ep=sys.argv[1:]
d=json.load(open(p)); parent=d["owner"]
parent["session"]="session-parent"
child={"pid":700,"start_epoch":int(ep),"comm":"codex","session":"session-child"}
d["owners"]=[parent,child]
json.dump(d,open(p,"w"))
PYSESSIONSEED
lease_release_owner_session session-parent 400 "$OWNER_EPOCH" >/dev/null
assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(bool(d["owners"][0].get("released_at")), bool(d["owners"][1].get("released_at")), bool(d.get("released_at")))' "$L11")" "True False False" "session release releases only matching owner"
lease_release_owner_session session-child 700 "$OWNER_EPOCH" >/dev/null
assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(bool(d.get("released_at")))' "$L11")" "True" "global release set only after all session owners release"

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
