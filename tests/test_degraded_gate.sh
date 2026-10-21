#!/usr/bin/env bash
# test_degraded_gate.sh — bead disk_magician-kub3: a run whose safety gates
# refused every eligible candidate for an unmeasurable reason (cwd-unknown) is
# DEGRADED (receipt outcome `degraded`, exit 4), not a success with 0 bytes
# freed. Disposable fixtures only; nothing is removed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 - expected '$2', got '$1'"; fi; }

TMPROOT="$(mktemp -d /tmp/dm-degraded-test.XXXXXX)" || exit 1
[[ "$TMPROOT" == /tmp/dm-degraded-test.* && -d "$TMPROOT" ]] || exit 1
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
trap 'chmod -R u+rwx "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home" DISK_MAGICIAN_STATE_DIR="$TMPROOT/state"
mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

RECEIPT="$REPO_ROOT/scripts/job_receipt.py"

echo "== tally classification (job_receipt.py tally) =="
tally() { printf '%s' "$1" >"$TMPROOT/tally"; python3 "$RECEIPT" tally --file "$TMPROOT/tally"; }
out="$(tally $'kept:cwd-unknown\nkept:cwd-unknown\nkept:cwd-unknown\n')"; rc=$?
assert_eq "$rc" 4 "all eligible refused cwd-unknown -> exit 4"
[[ "$out" == *'"degraded": true'* ]] && ok "summary marks degraded" || bad "summary not degraded: $out"
out="$(tally '')"; rc=$?
assert_eq "$rc" 0 "nothing eligible -> exit 0"
[[ "$out" == *'"eligible_count": 0'* && "$out" == *'"degraded": false'* ]] && ok "nothing eligible is not degraded" || bad "empty tally: $out"
out="$(tally $'remove\nkept:cwd-unknown\nkept:cwd-unknown\n')"; rc=$?
assert_eq "$rc" 0 "some reclaimable -> exit 0"
[[ "$out" == *'"refused_unmeasurable_count": 2'* && "$out" == *'"removed_count": 1'* ]] && ok "mixed run reports refused count" || bad "mixed tally: $out"
out="$(tally $'kept:live-cwd\nkept:live-cwd\n')"; rc=$?
assert_eq "$rc" 0 "genuine live-cwd keeps are not degraded"
out="$(tally $'kept:cwd-unknown\nkept:live-cwd\n')"; rc=$?
assert_eq "$rc" 0 "unmeasurable plus a measured keep is not 'every' refusal unmeasurable"

echo "== producer: artifact_removal_verdict under unreadable cwds =="
PT="$TMPROOT/ptmp"; mkdir -p "$PT" "$TMPROOT/utmp" "$TMPROOT/bin"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PT" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$PT"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMPROOT/utmp"
# Unprivileged lsof on a shared host: a foreign process hides its cwd.
cat >"$TMPROOT/bin/lsof" <<'SH'
#!/bin/sh
printf 'p1\nfcwd\nn/proc/1/cwd (readlink: Permission denied)\np%s\nfcwd\nn/\n' "$PPID"
SH
chmod +x "$TMPROOT/bin/lsof"
# age <path> <minutes>: every entry under <path> last modified <minutes> ago (BSD and GNU).
age() {
    python3 -c 'import os,sys,time
t = time.time() - int(sys.argv[2]) * 60
for d, ds, fs in os.walk(sys.argv[1]):
    for n in ds + fs + ["."]:
        os.utime(os.path.join(d, n), (t, t), follow_symlinks=False)' "$1" "$2"
}
for n in a b c; do mkdir -p "$PT/pr-$n" && printf x >"$PT/pr-$n/f" && age "$PT/pr-$n" 43200; done

# shellcheck source=scripts/lib/artifact_verdict.sh
source "$REPO_ROOT/scripts/lib/artifact_verdict.sh"
PATH="$TMPROOT/bin:$PATH"
export DISK_MAGICIAN_VERDICT_TALLY="$TMPROOT/prod-tally"; : >"$DISK_MAGICIAN_VERDICT_TALLY"
v="$(artifact_removal_verdict "$PT/pr-a" --kind ephemeral)"
assert_eq "$v" kept:cwd-unknown "fixture: permission-denied cwd record keeps the candidate"
assert_eq "$(cat "$DISK_MAGICIAN_VERDICT_TALLY")" kept:cwd-unknown "verdict producer records the token in the tally"
unset DISK_MAGICIAN_VERDICT_TALLY
v="$(artifact_removal_verdict "$PT/pr-b" --kind ephemeral)"
assert_eq "$v" kept:cwd-unknown "no tally open: verdict unchanged"

echo "== run level: disk_audit.sh clean through run_category =="
FIX="$TMPROOT/fixture"; mkdir -p "$FIX/scripts/lib" "$FIX/bin" "$FIX/home"
cp "$REPO_ROOT/scripts/disk_audit.sh" "$FIX/scripts/"
cp "$REPO_ROOT/scripts/job_receipt.py" "$FIX/scripts/"
cp -r "$REPO_ROOT/scripts/lib/." "$FIX/scripts/lib/"
cp "$REPO_ROOT/config.json.template" "$FIX/"
printf '#!/bin/bash\necho "mock launchd fleet ok"\n' >"$FIX/scripts/check_launchd_fleet.sh"
chmod +x "$FIX/scripts/disk_audit.sh" "$FIX/scripts/check_launchd_fleet.sh"

# stub_category <scriptname> <body>: other categories are no-ops.
reset_stubs() {
    for s in cleanup_dev_caches cleanup_tmp cleanup_pr_scratch cleanup_xcode cleanup_colima prune_aside_sessions \
             cleanup_antigravity_brain cleanup_codex_db cleanup_supervisor_logs cleanup_uv_cache post_job_docker_prune \
             cleanup_llm_inspector; do
        printf '#!/bin/bash\nexit 0\n' >"$FIX/scripts/$s.sh"; chmod +x "$FIX/scripts/$s.sh"
    done
}
write_dev_caches() {
    cat >"$FIX/scripts/cleanup_dev_caches.sh" <<SH
#!/bin/bash
source "$REPO_ROOT/scripts/lib/artifact_verdict.sh"
$1
SH
    chmod +x "$FIX/scripts/cleanup_dev_caches.sh"
}
run_audit() {
    rm -rf "${DISK_MAGICIAN_STATE_DIR:?}/receipts"
    PATH="$TMPROOT/bin:$FIX/bin:/usr/bin:/bin" HOME="$FIX/home" /bin/bash "$FIX/scripts/disk_audit.sh" clean --live --no-history >"$TMPROOT/audit.log" 2>&1
    RC=$?
    [[ -z "${DEGRADED_TEST_DEBUG:-}" ]] || { echo "--- audit.log (rc=$RC) ---"; tail -25 "$TMPROOT/audit.log"; }
}
routine_outcome() { python3 "$RECEIPT" read --job routine_clean --last 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["outcome"])' 2>/dev/null; }

reset_stubs
# 1. every eligible candidate refused on an unreadable cwd -> DEGRADED
write_dev_caches 'artifact_removal_verdict "'"$PT"'/pr-a" --kind ephemeral >/dev/null
artifact_removal_verdict "'"$PT"'/pr-b" --kind ephemeral >/dev/null
artifact_removal_verdict "'"$PT"'/pr-c" --kind ephemeral >/dev/null'
run_audit
assert_eq "$RC" 4 "degraded run exits with the documented code 4"
grep -q "CATEGORY DEGRADED: Dev caches" "$TMPROOT/audit.log" && ok "category reported DEGRADED" || bad "no CATEGORY DEGRADED line"
grep -q "DEGRADED: 1 of" "$TMPROOT/audit.log" && ok "summary says DEGRADED" || bad "summary lacks DEGRADED"
grep -q "All attempted categories completed without error" "$TMPROOT/audit.log" && bad "summary still claims clean completion" || ok "summary no longer claims clean completion"
assert_eq "$(routine_outcome)" degraded "routine_clean receipt outcome"

# 2. nothing eligible -> success
reset_stubs; write_dev_caches 'exit 0'
run_audit
assert_eq "$RC" 0 "nothing eligible exits 0"
assert_eq "$(routine_outcome)" success "nothing eligible receipt outcome stays success"
grep -q "DEGRADED" "$TMPROOT/audit.log" && bad "false DEGRADED on a run with nothing eligible" || ok "no DEGRADED text when nothing is eligible"

# 3. mixed: one candidate reclaimable, others refused -> success, refused count reported
reset_stubs
write_dev_caches 'source "'"$REPO_ROOT"'/scripts/lib/verdict_tally.sh"
artifact_removal_verdict "'"$PT"'/pr-a" --kind ephemeral >/dev/null
artifact_removal_verdict "'"$PT"'/pr-b" --kind ephemeral >/dev/null
vt_record remove'
run_audit
assert_eq "$RC" 0 "mixed run exits 0"
assert_eq "$(routine_outcome)" success "mixed run receipt outcome stays success"
grep -q "Dev caches: 2 of 3 eligible refused (cwd-unknown=2)" "$TMPROOT/audit.log" && ok "mixed run reports the refused count" || bad "mixed run did not report refused count: $(grep -n 'Dev caches' "$TMPROOT/audit.log" | head -3)"
python3 "$RECEIPT" read --job routine_clean --last | grep -q '"refused_unmeasurable_count": 2' && ok "receipt carries refused_unmeasurable_count" || bad "receipt lacks refused count"

# 4. a failed category still wins exit 1 over degraded
reset_stubs; printf '#!/bin/bash\nexit 7\n' >"$FIX/scripts/cleanup_tmp.sh"
write_dev_caches 'artifact_removal_verdict "'"$PT"'/pr-a" --kind ephemeral >/dev/null'
run_audit
assert_eq "$RC" 1 "a failed category exits 1 even when another is degraded"
assert_eq "$(routine_outcome)" error "failed+degraded receipt outcome is error"

echo "== whole-category refusal: worktree deps with an unusable lsof =="
printf '#!/bin/sh\necho "lsof: boom" >&2\nexit 2\n' >"$TMPROOT/bin/lsof"
export DISK_MAGICIAN_VERDICT_TALLY="$TMPROOT/deps-tally"; : >"$DISK_MAGICIAN_VERDICT_TALLY"
PATH="$TMPROOT/bin:$PATH" bash "$REPO_ROOT/scripts/cleanup_worktree_deps.sh" --dry-run >"$TMPROOT/deps.log" 2>&1
assert_eq "$(cat "$DISK_MAGICIAN_VERDICT_TALLY")" kept:cwd-unknown "deps lane records its wholesale cwd refusal"
unset DISK_MAGICIAN_VERDICT_TALLY

echo "== status / sweeper-health surface DEGRADED =="
python3 "$RECEIPT" begin --job routine_clean --trigger test >"$TMPROOT/rid" && \
    python3 "$RECEIPT" finish --job routine_clean --run-id "$(cat "$TMPROOT/rid")" --outcome degraded --reason "1 of 12 categories degraded: Dev caches" >/dev/null
timeout 120 python3 "$REPO_ROOT/scripts/disk_status.py" --json --state-dir "$DISK_MAGICIAN_STATE_DIR" >"$TMPROOT/status.json" 2>/dev/null
detail="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["dimensions"]["action_outcome"]; print(d["details"]["routine_clean"]["status"], "|", d["reason"])' "$TMPROOT/status.json" 2>/dev/null)"
[[ "$detail" == "degraded | "*"routine_clean: DEGRADED 1 of 12 categories degraded"* ]] && ok "diskm status marks the routine_clean job degraded" || bad "status did not surface DEGRADED: $detail"
cat >"$TMPROOT/health_receipts.py" <<'PY'
import re, sys
src = open(sys.argv[1] + "/sweeper_health_check.sh").read()
m = re.search(r"python3 - \"\$SCRIPT_DIR\" <<'PY_RECEIPTS'\n(.*?)\nPY_RECEIPTS", src, re.S)
exec(m.group(1))
PY
health="$(python3 "$TMPROOT/health_receipts.py" "$REPO_ROOT/scripts" 2>&1)"
[[ "$health" == *"[RECEIPT] routine_clean: DEGRADED - 1 of 12 categories degraded"* ]] && ok "sweeper-health prints DEGRADED for routine_clean" || bad "sweeper-health did not surface DEGRADED: $health"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
