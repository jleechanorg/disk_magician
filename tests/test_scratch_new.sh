#!/usr/bin/env bash
# test_scratch_new.sh — `diskm scratch-new` (plan Task 6, spec C3).
# Everything lives in a private temp dir: HOME, the worktree root, the
# evidence root and the state dir. Admission is stubbed via
# DISK_MAGICIAN_ADMIT_BIN except for one case that runs the real `diskm admit`
# against a fake df.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISKM="$REPO_ROOT/src/disk_magician/disk_magician.sh"
PASS=0 FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }
assert_contains() { if [[ "$1" == *"$2"* ]]; then ok "$3"; else bad "$3 — missing '$2' in: $1"; fi; }

T="$(mktemp -d)"
T="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$T")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/bin" "$T/tmp" "$T/state" "$T/elsewhere"
export HOME="$T/home" STANDARD_WORKTREE_ROOT="$T/home/.worktrees" EVIDENCE_TMP_ROOT="$T/tmp"
export DISK_MAGICIAN_STATE_DIR="$T/state"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q "$T/myrepo" && git -C "$T/myrepo" commit -q --allow-empty -m init
git -C "$T/myrepo" remote add origin https://example.invalid/o/myrepo.git
SHA="$(git -C "$T/myrepo" rev-parse HEAD)"

# Fake admit: logs argv, exits with the next rc from $T/admit_rcs (one per line).
cat > "$T/bin/admit" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/admit.log"
rc="\$(head -n 1 "$T/admit_rcs")"; tail -n +2 "$T/admit_rcs" > "$T/admit_rcs.n"; mv "$T/admit_rcs.n" "$T/admit_rcs"
echo admit_id=fake
exit "\${rc:-0}"
EOF
chmod +x "$T/bin/admit"
export DISK_MAGICIAN_ADMIT_BIN="$T/bin/admit"

# run <admit rcs> <args...> — sets OUT (stdout), ERR, RC.
run() {
    printf '%s\n' $1 > "$T/admit_rcs"; : > "$T/admit.log"; shift
    OUT="$(bash "$DISKM" scratch-new "$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"
}
admits() { wc -l < "$T/admit.log" | tr -d ' '; }
lease_field() {  # lease_field <path> <key>
    (source "$REPO_ROOT/scripts/lib/worktree_lease.sh"; _lease_get "$(lease_path_for "$1")" "$2")
}
wt_count() { find "$STANDARD_WORKTREE_ROOT/myrepo" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

echo "== admit contract: 0 / 10 / unexpected rc run the command; 75 refuses; 76 retries once =="
for rc in 0 10 3; do
    run "$rc" "$T/myrepo" "c$rc" --detach HEAD
    assert_eq "$RC" 0 "admit rc $rc: exit 0"
    [[ -d "$OUT" && -f "$OUT/.git" ]] && ok "admit rc $rc: detached worktree created" || bad "admit rc $rc: no worktree at '$OUT'"
done
assert_contains "$ERR" "admission_degraded:caller" "unexpected admit rc counted as degraded"
before="$(wt_count)"
run 75 "$T/myrepo" refused --detach HEAD
assert_eq "$RC" 75 "admit 75: exit 75"
assert_contains "$ERR" "disk-admission: refused" "admit 75: refusal line"
assert_eq "$(wt_count)" "$before" "admit 75: nothing created"
run "76 0" "$T/myrepo" retry --detach HEAD
assert_eq "$RC" 0 "admit 76 then 0: exit 0"
assert_eq "$(admits)" 2 "admit 76: retried exactly once"
run "76 76 0" "$T/myrepo" retry2 --detach HEAD
assert_eq "$RC" 75 "admit 76 twice: exit 75"
assert_eq "$(admits)" 2 "admit 76 twice: no third call"
assert_eq "$(wt_count)" "$((before + 1))" "admit 76 twice: nothing created"
run 0 "$T/myrepo" badsha --detach deadbeefdeadbeef
if [[ "$RC" != 0 && "$RC" != 75 ]]; then ok "command failure keeps its own rc ($RC)"; else bad "command failure rc $RC"; fi

echo "== detached scratch worktree: path, .git file, lease kind + source =="
run 0 "$T/myrepo" gate-prep --detach HEAD --est-gb 3
assert_eq "$RC" 0 "exit 0"
assert_contains "$OUT" "$STANDARD_WORKTREE_ROOT/myrepo/scratch-gate-prep-" "path under ~/.worktrees/<repo>/scratch-<purpose>-<ts>"
assert_eq "$(git -C "$OUT" rev-parse HEAD)" "$SHA" "checked out at the sha"
assert_eq "$(git -C "$OUT" symbolic-ref -q HEAD || echo detached)" detached "HEAD is detached"
assert_eq "$(lease_field "$OUT" kind)" scratch "lease kind"
assert_eq "$(lease_field "$OUT" source)" "git:https://example.invalid/o/myrepo.git@$SHA" "lease source = repo URL + sha"
assert_contains "$(cat "$T/admit.log")" "--class worktrees --est-gb 3" "admit class worktrees with --est-gb"
assert_eq "$(lease_field "$OUT" producer)" scratch-new "default producer"

echo "== bad purpose / escaping root -> rc 2, nothing admitted =="
for p in ../x Bad_Purpose "" "$(printf 'a%.0s' {1..41})"; do
    run 0 "$T/myrepo" "$p" --detach HEAD
    assert_eq "$RC" 2 "purpose '$p' rejected"
done
assert_eq "$(admits)" 0 "rejected purpose never admitted"
mkdir -p "$STANDARD_WORKTREE_ROOT" && ln -s "$T/elsewhere" "$STANDARD_WORKTREE_ROOT/linked"
git clone -q "$T/myrepo" "$T/linked"
run 0 "$T/linked" esc --detach HEAD
assert_eq "$RC" 2 "repo dir symlinked outside the root -> rc 2"
assert_eq "$(find "$T/elsewhere" -mindepth 1 | wc -l | tr -d ' ')" 0 "nothing created outside the root"

echo "== --kind evidence: dir under the evidence root, evidence lease, tmp_containers class =="
run 0 "$T/myrepo" ui-proof --kind evidence
assert_eq "$RC" 0 "exit 0"
EV="$OUT"
assert_contains "$EV" "$T/tmp/myrepo/evidence/ui-proof-" "evidence path"
[[ -d "$EV" ]] && ok "evidence dir exists" || bad "evidence dir missing"
assert_eq "$(lease_field "$EV" kind)" evidence "evidence lease kind"
assert_contains "$(cat "$T/admit.log")" "--class tmp_containers" "admit class tmp_containers"

echo "== real diskm admit (observe, fake df) admits and logs one event =="
cat > "$T/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/x 1000000000 1 900000000 1% /"
EOF
chmod +x "$T/bin/df"
OUT="$(env -u DISK_MAGICIAN_ADMIT_BIN DISK_MAGICIAN_DF_BIN="$T/bin/df" bash "$DISKM" scratch-new "$T/myrepo" real --detach HEAD 2>"$T/err")"; RC=$?
assert_eq "$RC" 0 "real admit: exit 0"
[[ -d "$OUT" && "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" == 0 ]] && ok "real admit: stdout is exactly the path" || bad "real admit: stdout '$OUT'"
assert_eq "$(grep -c '"producer": "scratch-new:myrepo"' "$T/state/admission/events.jsonl")" 1 "one admit event"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
