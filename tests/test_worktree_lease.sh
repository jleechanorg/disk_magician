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

echo "== aged live producer lease stays protective; producer exit retires it =="
WT14="$(mk_wt wt_aged_live_evidence)"
if lease_write "$WT14" myrepo "" scratch-new --kind evidence --owner-pid 400; then ok "producer-bound evidence lease written"; else bad "producer-bound evidence lease failed"; fi
L14="$(lease_path_for "$WT14")"
LEASE_NOW="$(date +%s)"
LEASE_CREATED=$((LEASE_NOW - 48*3600 - 10))
python3 -c 'import json,sys; p=sys.argv[1]; created=int(sys.argv[2]); d=json.load(open(p)); d["created_epoch"]=created; d["expires_at"]=created+24*3600; json.dump(d,open(p,"w"))' "$L14" "$LEASE_CREATED"
assert_eq "$(lease_owner_state "$L14" "$LEASE_NOW")" "alive-expired" "48h age does not retire a live evidence producer"
seed_fail 400 "1"
assert_eq "$(lease_owner_state "$L14" "$LEASE_NOW")" "dead" "producer exit makes aged evidence lease reclaim-eligible"
rm -f "$FAKE_PS_DIR/fail/400"

echo "== unknown ownerless evidence never ages into reclaim =="
WT15="$(mk_wt wt_unknown_owner_evidence)"
lease_write "$WT15" myrepo "" scratch-new --kind evidence
L15="$(lease_path_for "$WT15")"
LEASE_CREATED=$((LEASE_NOW - 96*3600))
python3 -c 'import json,sys; p=sys.argv[1]; created=int(sys.argv[2]); d=json.load(open(p)); d.update(owner=None,owners=[],created_epoch=created,expires_at=created+24*3600); json.dump(d,open(p,"w"))' "$L15" "$LEASE_CREATED"
assert_eq "$(lease_owner_state "$L15" "$LEASE_NOW")" "none" "unknown ownerless evidence remains protected after 96h"
WT16="$(mk_wt wt_bad_explicit_owner)"
if lease_write "$WT16" myrepo "" scratch-new --kind evidence --owner-pid 99999999; then
    bad "unknown explicit producer identity accepted"
else
    ok "unknown explicit producer identity rejected"
fi
[[ ! -f "$(lease_path_for "$WT16")" ]] && ok "unknown producer writes no lease" || bad "unknown producer lease exists"

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

PENDING_ACTIVATE="$TMPROOT/pending_activate"
PENDING_OWNER="$(printf '600\t%s\tguard' "$OWNER_EPOCH")"
if lease_write_pending "$PENDING_ACTIVATE" "$PENDING_OWNER"; then ok "pending lease created for activation"; else bad "pending activation lease creation failed"; fi
mkdir -p "$PENDING_ACTIVATE"
lease_write "$PENDING_ACTIVATE" myrepo fresh-branch worktree-new
LPA="$(lease_path_for "$PENDING_ACTIVATE")"
assert_eq "$(lease_field "$LPA" 'len(d["owners"]) == 1 and d["owners"][0]["pid"] == 400')" "True" "activation replaces pending claimant with resolved owner"
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
if lease_write "$WTE" myrepo "" evidence-push --kind evidence; then
    ok "evidence lease created before publication"
else
    bad "evidence lease creation failed"
fi
seed_comm 700 1 codex
seed_lstart 700 "$OWNER_LSTART"
seed_args 700 "/usr/bin/codex"
if "$REPO_ROOT/disk_magician.sh" lease-add-owner "$WTE" --owner-pid 700; then
    ok "child owner added before publication update"
else
    bad "child owner add before publication failed"
fi
python3 - "$(lease_path_for "$WTE")" <<'PYUNKNOWNFIELD'
import json,sys
p=sys.argv[1]
d=json.load(open(p)); d["future_writer_field"]={"kept":True}; json.dump(d,open(p,"w"))
PYUNKNOWNFIELD
if lease_write "$WTE" myrepo "" evidence-push --kind evidence --published gs://b/run1 \
    --upload-manifest "$PROV/upload.json" --verified-at 2026-10-12T00:00:00Z --git-meta "$PROV/gitmeta.json"; then
    ok "published lease_write updates existing lease"
else
    bad "published lease_write failed"
fi
LE="$(lease_path_for "$WTE")"
assert_eq "$(lease_field "$LE" 'len(d["owners"])')" "2" "publication update retains parent and child owners"
assert_eq "$(lease_field "$LE" 'd.get("future_writer_field", {}).get("kept")')" "True" "publication update retains unknown fields"
if lease_release "$WTE"; then ok "parent owner releases after publication update"; else bad "parent owner release failed after publication update"; fi
assert_eq "$(lease_owner_state "$LE")" "alive" "child remains protective after parent releases published lease"
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

echo "== publication update rejects unverifiable existing lease =="
WTPUBBAD="$(mk_wt wt_pub_bad)"
lease_write "$WTPUBBAD" myrepo "" evidence-push --kind evidence
LPB="$(lease_path_for "$WTPUBBAD")"
python3 - "$LPB" <<'PYWRONGPATH'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["path"] += "/wrong"; json.dump(d,open(p,"w"))
PYWRONGPATH
LPB_HASH="$(sha256sum "$LPB" | cut -d' ' -f1)"
if lease_write "$WTPUBBAD" myrepo "" evidence-push --kind evidence --published gs://b/run1 \
    --upload-manifest "$PROV/upload.json" --verified-at 2026-10-12T00:00:00Z 2>/dev/null; then
    bad "publication overwrote wrong-path lease"
else
    ok "publication refuses wrong-path existing lease"
fi
assert_eq "$(sha256sum "$LPB" | cut -d' ' -f1)" "$LPB_HASH" "wrong-path lease remains byte-identical"
printf '[]\n' > "$LPB"
LPB_HASH="$(sha256sum "$LPB" | cut -d' ' -f1)"
if lease_write "$WTPUBBAD" myrepo "" evidence-push --kind evidence --published gs://b/run1 \
    --upload-manifest "$PROV/upload.json" --verified-at 2026-10-12T00:00:00Z 2>/dev/null; then
    bad "publication overwrote malformed lease"
else
    ok "publication refuses malformed existing lease"
fi
assert_eq "$(sha256sum "$LPB" | cut -d' ' -f1)" "$LPB_HASH" "malformed lease remains byte-identical"

echo "== publication update refuses pending and reuse claims =="
WTPUBSTATE="$(mk_wt wt_pub_state)"
lease_write "$WTPUBSTATE" myrepo "" evidence-push --kind evidence
LPSTATE="$(lease_path_for "$WTPUBSTATE")"
python3 - "$LPSTATE" <<'PENDINGCLAIM'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["pending"]=True; json.dump(d,open(p,"w"))
PENDINGCLAIM
LPSTATE_HASH="$(sha256sum "$LPSTATE" | cut -d' ' -f1)"
if lease_write "$WTPUBSTATE" myrepo "" evidence-push --kind evidence --published gs://b/run1 \
    --upload-manifest "$PROV/upload.json" --verified-at 2026-10-12T00:00:00Z 2>/dev/null; then
    bad "publication changed pending lease"
else
    ok "publication refuses pending lease"
fi
assert_eq "$(sha256sum "$LPSTATE" | cut -d' ' -f1)" "$LPSTATE_HASH" "pending lease remains byte-identical"
python3 - "$LPSTATE" <<'REUSECLAIM'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["pending"]=False; d["reuse"]={"state":"pending","previous_lease":{}}; json.dump(d,open(p,"w"))
REUSECLAIM
LPSTATE_HASH="$(sha256sum "$LPSTATE" | cut -d' ' -f1)"
if lease_write "$WTPUBSTATE" myrepo "" evidence-push --kind evidence --published gs://b/run1 \
    --upload-manifest "$PROV/upload.json" --verified-at 2026-10-12T00:00:00Z 2>/dev/null; then
    bad "publication changed reuse claim"
else
    ok "publication refuses reuse claim"
fi
assert_eq "$(sha256sum "$LPSTATE" | cut -d' ' -f1)" "$LPSTATE_HASH" "reuse claim remains byte-identical"

echo "== atomic reuse lease claim and recovery =="
REUSE_WT="$(mk_wt wt_reuse)"
lease_write "$REUSE_WT" myrepo old-branch test
REUSE_LEASE="$(lease_path_for "$REUSE_WT")"
if lease_release "$REUSE_WT"; then ok "old reuse lease released before claimant"; else bad "old reuse lease release failed"; fi
assert_eq "$(lease_owner_state "$REUSE_LEASE")" "released" "released lease is eligible for exact pending claim"
REUSE_HASH="$(python3 - "$REUSE_LEASE" <<'PY'
import hashlib,sys
print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())
PY
)"
REUSE_OWNER="$(printf '500\t%s\tcodex' "$OWNER_EPOCH")"
if lease_claim_reuse "$REUSE_LEASE" "$REUSE_HASH" old-branch abc123 "$REUSE_OWNER"; then ok "exact lease claimed"; else bad "exact lease claim failed"; fi
assert_eq "$(lease_field "$REUSE_LEASE" 'd["reuse"]["old_branch"]')" "old-branch" "old branch preserved in claim"
assert_eq "$(lease_field "$REUSE_LEASE" 'd["reuse"]["old_tip"]')" "abc123" "old tip preserved in claim"
assert_eq "$(lease_field "$REUSE_LEASE" 'd["reuse"]["previous_lease"].get("released_at") is not None')" "True" "released previous lease preserved for rollback"
assert_eq "$(lease_field "$REUSE_LEASE" 'len(d["owners"]) == 1 and d["owners"][0]["pid"] == 500')" "True" "pending claimant is present in preferred owners array"
seed_comm 500 1 codex
seed_lstart 500 "$OWNER_LSTART"
seed_args 500 "/usr/bin/codex"
assert_eq "$(lease_owner_state "$REUSE_LEASE")" "alive" "unrelated C14 keeps pending claimant lease"
assert_eq "$(lease_owner_state_for "$REUSE_LEASE" "$REUSE_OWNER" "$REUSE_WT")" "own-live" "claimant exemption applies to exact candidate"
assert_eq "$(lease_owner_state_for "$REUSE_LEASE" "$REUSE_OWNER" "$REUSE_WT/ancestor")" "alive" "claimant exemption does not apply to another candidate"
python3 - "$REUSE_LEASE" <<'PYOWNERSMISSING'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d.pop("owners"); json.dump(d,open(p,"w"))
PYOWNERSMISSING
assert_eq "$(lease_owner_state_for "$REUSE_LEASE" "$REUSE_OWNER" "$REUSE_WT")" "alive" "missing owners array disables claimant exemption"
python3 - "$REUSE_LEASE" <<'PYOWNERSRESTORE'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["owners"]=[dict(d["owner"])]; json.dump(d,open(p,"w"))
PYOWNERSRESTORE
python3 - "$REUSE_LEASE" <<'PYOWNERSMALFORMED'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["owners"]={"pid":d["owner"]["pid"]}; json.dump(d,open(p,"w"))
PYOWNERSMALFORMED
assert_eq "$(lease_owner_state_for "$REUSE_LEASE" "$REUSE_OWNER" "$REUSE_WT")" "alive" "malformed owners array disables claimant exemption"
python3 - "$REUSE_LEASE" <<'PYOWNERRESTORE'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["owners"]=[dict(d["owner"])]; json.dump(d,open(p,"w"))
PYOWNERRESTORE
python3 - "$REUSE_LEASE" <<'PYOWNERDISAGREE'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["owner"]={"pid":700,"start_epoch":1760000000,"comm":"codex"}; json.dump(d,open(p,"w"))
PYOWNERDISAGREE
assert_eq "$(lease_owner_state_for "$REUSE_LEASE" "$REUSE_OWNER" "$REUSE_WT")" "alive" "compatibility owner disagreement disables claimant exemption"
python3 - "$REUSE_LEASE" <<'PYOWNERAGREERESTORE'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["owner"]={"pid":500,"start_epoch":1760000000,"comm":"codex"}; json.dump(d,open(p,"w"))
PYOWNERAGREERESTORE
python3 - "$REUSE_LEASE" <<'PYEXTRAOWNER'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["owners"].append({"pid":700,"start_epoch":1760000000,"comm":"codex"}); json.dump(d,open(p,"w"))
PYEXTRAOWNER
assert_eq "$(lease_owner_state_for "$REUSE_LEASE" "$REUSE_OWNER" "$REUSE_WT")" "alive" "added owner disables claimant exemption"
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

cat > "$TMPROOT/add-prune-owner-hook" <<'HOOK'
#!/usr/bin/env bash
[[ "$1" == "$TEST_PRUNE_LEASE" ]] || exit 0
source "$TEST_LEASE_LIB"
lease_owner_add "$TEST_PRUNE_PATH" 401 1760000000 claude
HOOK
chmod +x "$TMPROOT/add-prune-owner-hook"
export TEST_LEASE_LIB="$REPO_ROOT/scripts/lib/worktree_lease.sh" TEST_PRUNE_LEASE="$L_EXP_AT" TEST_PRUNE_PATH="$P_EXP_AT"
export DISK_MAGICIAN_TEST_BEFORE_BIRTH_AUDIT_PRUNE_LOCK="$TMPROOT/add-prune-owner-hook"
if lease_prune_birth_audit_scratch; then ok "lease_prune_birth_audit_scratch rc 0"; else bad "lease_prune_birth_audit_scratch failed"; fi
unset DISK_MAGICIAN_TEST_BEFORE_BIRTH_AUDIT_PRUNE_LOCK TEST_LEASE_LIB TEST_PRUNE_LEASE TEST_PRUNE_PATH
[[ ! -e "$L_GONE" ]] && ok "missing-path birth-audit scratch lease pruned" || bad "missing-path birth-audit scratch lease still exists"
[[ -f "$L_EXP_AT" ]] && ok "lease with owner added at prune boundary survives" || bad "lease with owner added at prune boundary was unlinked"
assert_eq "$(lease_field "$L_EXP_AT" 'd.get("owner",{}).get("pid")')" "401" "owner survives prune boundary"
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
if "$REPO_ROOT/disk_magician.sh" lease-add-owner "$WT10" --owner-pid 700; then ok "CLI adds live child owner"; else bad "CLI child owner add failed"; fi
if "$REPO_ROOT/disk_magician.sh" lease-add-owner "$WT10" --owner-pid 700; then ok "CLI child add is idempotent"; else bad "CLI idempotent child add failed"; fi
assert_eq "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["owners"]))' "$L10")" "2" "both parent and child owners retained"
if "$REPO_ROOT/disk_magician.sh" lease-add-owner "$WT10" --owner-pid 799 >/dev/null 2>&1; then bad "CLI rejects unknown PID"; else ok "CLI rejects unknown PID"; fi
assert_eq "$(lease_owner_state "$L10")" "alive" "live child keeps lease alive"
if "$REPO_ROOT/disk_magician.sh" lease-release-owner "$WT10" --owner-pid 700; then ok "CLI releases only the child owner"; else bad "CLI child owner release failed"; fi
assert_eq "$(lease_owner_state "$L10")" "alive" "parent remains protective after child release"
if lease_release "$WT10"; then ok "parent owner release succeeds"; else bad "parent owner release failed"; fi
assert_eq "$(lease_owner_state "$L10")" "released" "lease releases after every owner releases"

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

echo "== repeated parent release preserves live child =="
WT12="$(mk_wt wt_repeat_parent_release)"
lease_resolve_owner() { printf "400\t%s\tbash\n" "$OWNER_EPOCH"; }
lease_write "$WT12" myrepo fix/repeated test
L12="$(lease_path_for "$WT12")"
seed_comm 700 1 codex
seed_lstart 700 "$OWNER_LSTART"
seed_args 700 "/usr/bin/codex"
if "$REPO_ROOT/disk_magician.sh" lease-add-owner "$WT12" --owner-pid 700; then ok "child owner added before parent release"; else bad "child owner add failed"; fi
if lease_release "$WT12"; then ok "first parent release succeeds"; else bad "first parent release failed"; fi
if lease_release "$WT12" 2>/dev/null; then bad "repeated parent release is refused"; else ok "repeated parent release is refused"; fi
assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["owners"]), bool(d.get("released_at")), sum(not bool(o.get("released_at")) for o in d["owners"]))' "$L12")" "2 False 1" "live child remains recorded and globally unreleased"
assert_eq "$(lease_owner_state "$L12")" "alive" "live child remains protective after repeated parent release"

echo "== adding owner reopens globally released lease =="
WT13="$(mk_wt wt_add_owner_after_release)"
lease_write "$WT13" myrepo fix/add-owner test
L13="$(lease_path_for "$WT13")"
if lease_release "$WT13"; then ok "sole owner releases lease"; else bad "sole owner release failed"; fi
assert_eq "$(lease_owner_state "$L13")" "released" "lease is released before new owner add"
if "$REPO_ROOT/disk_magician.sh" lease-add-owner "$WT13" --owner-pid 700; then ok "new live owner added to released lease"; else bad "new owner add failed"; fi
assert_eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("released_at"), len(d["owners"]))' "$L13")" "None 2" "owner add clears global release marker"
assert_eq "$(lease_owner_state "$L13")" "alive" "new live owner makes lease protective"
rm -rf -- "$WT13"
if lease_owner_add "$WT13" 701 1760000000 codex; then bad "owner add after artifact removal succeeded"; else ok "owner add after artifact removal fails closed"; fi

echo
echo "=== $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
