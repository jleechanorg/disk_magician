#!/usr/bin/env bash
# test_worktree_reuse_real.sh — real (unstubbed) Task 15 reuse proof.
#
# The existing tests/test_worktree_new.sh exercises the reuse decision with a
# stubbed `artifact_removal_verdict` and a stubbed `lease_owner_state`. This
# file proves the whole canonical `worktree_new.sh` entry end to end with:
#
#   * a real local bare origin and a real linked worktree,
#   * the real C14 `artifact_removal_verdict` (no stub),
#   * the real lease owner probe (`_lease_ps`), no DISK_MAGICIAN_PS_BIN stub,
#   * a real owner PID/start recorded by the create run and observed dead after
#     that run exits, then a real *live* competing owner that must keep.
#
# Paths are canonicalized (/tmp is a symlink to /private/tmp on macOS): C14's
# own-reuse-claim canonicalization and lease_path_for must compare equal bytes.
# Fixtures live only under a validated /tmp allocation with a fixture HOME and
# state dir; the trap removes only that allocation. No production path is
# touched or deleted.
set -uo pipefail

REPO_ROOT="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/worktree_new.sh"
BASH_BIN="$(command -v bash)"

ROOT_RAW="$(mktemp -d /tmp/dm-worktree-reuse-real.XXXXXX)" || { echo "FATAL: fixture allocation failed" >&2; exit 1; }
if [[ -z "$ROOT_RAW" || "$ROOT_RAW" != /tmp/dm-worktree-reuse-real.* || ! -d "$ROOT_RAW" || -L "$ROOT_RAW" ]]; then
    echo "FATAL: refusing non-/tmp fixture root '$ROOT_RAW'" >&2
    exit 1
fi
ROOT="$(CDPATH= cd -- "$ROOT_RAW" && pwd -P)"
trap 'rm -rf -- "$ROOT_RAW"' EXIT

export HOME="$ROOT/home"
mkdir -p "$HOME"
export DISK_MAGICIAN_STATE_DIR="$ROOT/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_COMMON_DIR GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR GIT_EXEC_PATH GIT_CEILING_DIRECTORIES \
    DISK_MAGICIAN_PS_BIN DISK_MAGICIAN_STAT_BIN DISK_MAGICIAN_LSOF_BIN DISK_MAGICIAN_GIT_BIN \
    DISK_MAGICIAN_C14_LEDGER C14_INVENTORY_OUT C14_INVENTORY_FILE 2>/dev/null || true
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cd "$ROOT" || exit 1

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }

# The canonical entry must run under a real runtime ancestor so the product's
# own lease owner probe (`_lease_runtime_comms`) resolves a live owner. A
# symlink named for a runtime comm is a genuine process with a real PID/start;
# the production owner probe is not stubbed.
CLAUDE_BIN="$ROOT/bin/claude"
mkdir -p "$ROOT/bin"
ln -sf "$BASH_BIN" "$CLAUDE_BIN"
run_entry() { "$CLAUDE_BIN" -c 'bash "$1" "${@:2}" & wait $!; exit $?' _ "$SCRIPT" "$@"; }

# shellcheck source=scripts/lib/worktree_lease.sh
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"

REAL_GIT="$(command -v git)"
git init -q --bare -b main "$ROOT/origin.git"
git clone -q "$ROOT/origin.git" "$ROOT/seed" 2>/dev/null
printf 'base\n' > "$ROOT/seed/f.txt"
git -C "$ROOT/seed" add -A
git -C "$ROOT/seed" commit -qm base
git -C "$ROOT/seed" push -q origin main
git clone -q "$ROOT/origin.git" "$ROOT/repo"
REPO="$ROOT/repo"
WTROOT="$HOME/.worktrees/repo"
ORIGIN_SHA="$(git -C "$REPO" rev-parse origin/main)"

echo "== real case R1: released/dead owner, clean pushed worktree -> C14 recycle =="
CAND="$(run_entry "$REPO" reuse/old --base origin/main --name reuse-old 2>"$ROOT/r1-create.err")"; rc=$?
assert_eq "$rc" "0" "candidate create exit"
assert_eq "$CAND" "$WTROOT/reuse-old" "candidate path"
LEASE="$(lease_path_for "$CAND")"
[[ -f "$LEASE" ]] && ok "real lease written by the create run" || bad "lease missing: $LEASE"
# The create run has exited: its recorded owner is a real dead PID/start.
assert_eq "$(lease_owner_state "$LEASE")" "dead" "recorded owner is dead after the create run exits"
find "$CAND" -exec touch -h -t 202001010000 {} + 2>/dev/null
[[ "$(git -C "$CAND" rev-parse --abbrev-ref HEAD)" == "reuse/old" ]] || bad "candidate not on old branch"

# Capture the lease at the branch-delete boundary: reaching the hook proves the
# first C14, the pending claim and the second (own-claim) C14 all passed.
MARK="$ROOT/pending-claim.json"
cat > "$ROOT/before-ref.sh" <<'HOOK'
#!/usr/bin/env bash
exec python3 - "$CAND" "$MARK" <<'PY'
import glob, json, os, sys
cand, mark = sys.argv[1], sys.argv[2]
st = os.environ["DISK_MAGICIAN_STATE_DIR"]
for p in glob.glob(os.path.join(st, "worktree_leases", "*.json")):
    try:
        d = json.load(open(p))
    except OSError:
        continue
    if d.get("path") == cand:
        reuse = d.get("reuse") or {}
        json.dump({"pending": d.get("pending"), "state": reuse.get("state"),
                   "old_branch": reuse.get("old_branch"), "old_tip": reuse.get("old_tip"),
                   "has_previous": isinstance(reuse.get("previous_lease"), dict)}, open(mark, "w"))
        sys.exit(0)
sys.exit(0)
PY
HOOK
chmod +x "$ROOT/before-ref.sh"
export CAND MARK
out="$(DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF="$ROOT/before-ref.sh" run_entry "$REPO" feat/recycled --base origin/main --name recycled 2>"$ROOT/r1-reuse.err")"; rc=$?
unset DISK_MAGICIAN_TEST_BEFORE_UPDATE_REF
assert_eq "$rc" "0" "recycle exit"
assert_eq "$out" "$CAND" "recycle keeps the existing worktree path"
assert_eq "$(git -C "$CAND" rev-parse --abbrev-ref HEAD 2>/dev/null)" "feat/recycled" "recycled checkout moved to the new branch"
if git -C "$REPO" show-ref -q --verify refs/heads/reuse/old; then bad "old branch survived the conditional delete"; else ok "old branch deleted after the conditional ref delete"; fi
[[ ! -e "$WTROOT/recycled" ]] && ok "no fresh worktree was created" || bad "fresh worktree created despite reuse"
if [[ -f "$MARK" ]]; then
    assert_eq "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pending"])' "$MARK")" "True" "pending claim was held at the ref-delete boundary"
    assert_eq "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$MARK")" "pending" "reuse state pending before delete"
    assert_eq "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["old_branch"])' "$MARK")" "reuse/old" "pending claim names the old branch"
    assert_eq "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["old_tip"])' "$MARK")" "$ORIGIN_SHA" "pending claim records old tip T"
    assert_eq "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["has_previous"])' "$MARK")" "True" "pending claim keeps previous_lease for rollback"
else
    bad "branch-delete boundary hook never fired"
fi

echo "== real case R2: competing live owner keeps the candidate and falls back fresh =="
# Make the R1 candidate recently active so it is not itself re-selected; this
# isolates the live-owner candidate created next.
touch "$CAND/f.txt"
CAND2="$(run_entry "$REPO" reuse/live --base origin/main --name reuse-live 2>"$ROOT/r2-create.err")"; rc=$?
assert_eq "$rc" "0" "second candidate create exit"
assert_eq "$CAND2" "$WTROOT/reuse-live" "second candidate path"
LEASE2="$(lease_path_for "$CAND2")"
# Start a real live runtime process and record it as the candidate owner.
# Keep the runtime process alive as the parent (do not let bash exec the sleep).
"$CLAUDE_BIN" -c 'sleep 120 & wait $!' & HOLDER=$!
sleep 0.5
HOLDER_EP="$(_lease_ps_lstart_epoch "$HOLDER")"
[[ -n "$HOLDER_EP" ]] || bad "could not read the live owner start epoch"
python3 - "$LEASE2" "$HOLDER" "$HOLDER_EP" <<'PY'
import json, sys
p, pid, ep = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = json.load(open(p))
d["owner"] = {"pid": pid, "start_epoch": ep, "comm": "claude"}
json.dump(d, open(p, "w"), indent=2)
PY
assert_eq "$(lease_owner_state "$LEASE2")" "alive" "recorded owner is a live process"
find "$CAND2" -exec touch -h -t 202001010000 {} + 2>/dev/null
out="$(run_entry "$REPO" feat/live2 --base origin/main --name live2 2>"$ROOT/r2-reuse.err")"; rc=$?
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true
assert_eq "$rc" "0" "live-owner fallback exit"
assert_eq "$out" "$WTROOT/live2" "live owner forces a fresh worktree"
assert_eq "$(git -C "$CAND2" rev-parse --abbrev-ref HEAD 2>/dev/null)" "reuse/live" "live-owner candidate preserved"
if git -C "$REPO" show-ref -q --verify refs/heads/reuse/live; then ok "live-owner old branch preserved"; else bad "live-owner old branch deleted"; fi
[[ -d "$WTROOT/live2" ]] && ok "fresh fallback worktree created" || bad "fresh fallback worktree missing"

echo "== real case R3: stale .reuse-lock from a killed owner is reclaimed (dead) =="
touch "$CAND2/f.txt"
CAND3="$(run_entry "$REPO" reuse/stale --base origin/main --name reuse-stale 2>"$ROOT/r3-create.err")"; rc=$?
assert_eq "$rc" "0" "third candidate create exit"
assert_eq "$CAND3" "$WTROOT/reuse-stale" "third candidate path"
LEASE3="$(lease_path_for "$CAND3")"
assert_eq "$(lease_owner_state "$LEASE3")" "dead" "third candidate owner is dead"
find "$CAND3" -exec touch -h -t 202001010000 {} + 2>/dev/null
# Leak a lock exactly as a holder killed between mkdir and rmdir would.
"$BASH_BIN" -c 'sleep 60' & DEAD_HOLDER=$!
sleep 0.3
kill "$DEAD_HOLDER" 2>/dev/null || true
wait "$DEAD_HOLDER" 2>/dev/null || true
mkdir -p "$LEASE3.reuse-lock"
printf '%s\n' "$DEAD_HOLDER" > "$LEASE3.reuse-lock/pid"
printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$LEASE3.reuse-lock/acquired_at"
out="$(run_entry "$REPO" feat/stale --base origin/main --name stale 2>"$ROOT/r3-reuse.err")"; rc=$?
assert_eq "$rc" "0" "stale-lock recycle exit"
assert_eq "$out" "$CAND3" "dead stale lock reclaimed and candidate recycled"
assert_eq "$(git -C "$CAND3" rev-parse --abbrev-ref HEAD 2>/dev/null)" "feat/stale" "stale-lock candidate moved to new branch"
[[ ! -e "$LEASE3.reuse-lock" ]] && ok "stale lock removed after reclaim" || bad "stale lock left behind"

# A stale-looking lock held by a LIVE pid must be preserved (no broad cleanup).
echo "== real case R4: stale-looking .reuse-lock with a live owner is preserved =="
touch "$CAND3/f.txt"
CAND4="$(run_entry "$REPO" reuse/livelock --base origin/main --name reuse-livelock 2>"$ROOT/r4-create.err")"; rc=$?
assert_eq "$rc" "0" "fourth candidate create exit"
LEASE4="$(lease_path_for "$CAND4")"
find "$CAND4" -exec touch -h -t 202001010000 {} + 2>/dev/null
"$CLAUDE_BIN" -c 'sleep 120 & wait $!' & LIVE_HOLDER=$!
sleep 0.5
mkdir -p "$LEASE4.reuse-lock"
printf '%s\n' "$LIVE_HOLDER" > "$LEASE4.reuse-lock/pid"
printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$LEASE4.reuse-lock/acquired_at"
out="$(run_entry "$REPO" feat/livelock --base origin/main --name livelock 2>"$ROOT/r4-reuse.err")"; rc=$?
assert_eq "$rc" "0" "live stale-lock fallback exit"
assert_eq "$out" "$WTROOT/livelock" "live stale lock forces a fresh worktree"
[[ -d "$LEASE4.reuse-lock" ]] && ok "live stale lock preserved" || bad "live stale lock wrongly removed"
assert_eq "$(git -C "$CAND4" rev-parse --abbrev-ref HEAD 2>/dev/null)" "reuse/livelock" "live stale-lock candidate preserved"
kill "$LIVE_HOLDER" 2>/dev/null || true
wait "$LIVE_HOLDER" 2>/dev/null || true

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
