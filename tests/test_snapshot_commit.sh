#!/bin/bash
# test_snapshot_commit.sh — orchestrator write-path (sandboxed, stubbed snapshot writer).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SC="$REPO_ROOT/scripts/snapshot_commit.sh"
TMP_ROOT=$(mktemp -d -t snapshot_commit_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Stub snapshot writer: honors --output, writes a minimal valid snapshot JSON.
STUB_BIN="$TMP_ROOT/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/snap.sh" <<'EOF'
#!/bin/bash
out=""
while [[ $# -gt 0 ]]; do case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac; done
[[ -n "$out" ]] || exit 1
mkdir -p "$(dirname "$out")"
printf '{"disk_free_gb": 100, "schema_version": 2}\n' > "$out"
EOF
chmod +x "$STUB_BIN/snap.sh"

run_sc() { # run_sc <home> <args...>
  env -i HOME="$1" PATH="/usr/bin:/bin" \
    DISK_MAGICIAN_SNAPSHOT_BIN="$STUB_BIN/snap.sh" \
    DISK_MAGICIAN_FRONTIER_JSON="${DM_TEST_FRONTIER:-$1/.disk_magician_state/frontier_last.json}" \
    DISK_MAGICIAN_STATE_DIR="${DM_TEST_STATE_DIR:-$1/.disk_magician_state}" \
    /bin/bash "$SC" "${@:2}"
}

echo "Test 1: fresh run auto-inits state repo, writes snapshot, commits"
H1="$TMP_ROOT/h1"; mkdir -p "$H1"
OUT1=$(run_sc "$H1" 2>&1); RC1=$?
SD1="$H1/.local/state/disk-magician"
[[ $RC1 -eq 0 ]] && ok "exits 0" || bad "rc" "$RC1: $OUT1"
[[ -f "$SD1/snapshots/disk_snapshot.json" ]] && ok "snapshot written under snapshots/" || bad "snapshot path" "missing"
[[ -f "$SD1/config/config.json" ]] && ok "resolved config written" || bad "config path" "missing"
LOG1="$(git -C "$SD1" log --oneline 2>&1)"
[[ "$LOG1" == *[Ss]napshot* ]] && ok "commit made" || bad "commit" "$LOG1"
LASTC=$(git -C "$SD1" rev-list --count HEAD)
RF1="$H1/.disk_magician_state/receipts/snapshot_commit.json"
[[ -f "$RF1" ]] && ok "receipt file written" || bad "receipt file" "missing"
grep -q '"outcome": "success"' "$RF1" && ok "receipt reports success" || bad "receipt outcome" "not success"
grep -q '"committed": true' "$RF1" && ok "receipt reports committed true" || bad "receipt committed" "not true"

echo "Test 2: second run commits a NEW snapshot (history accrues)"
OUT2=$(run_sc "$H1" 2>&1)
NEWC=$(git -C "$SD1" rev-list --count HEAD)
[[ "$NEWC" -gt "$LASTC" ]] && ok "history accrued a commit" || bad "history" "count $LASTC -> $NEWC"

echo "Test 3: push failure is non-fatal (commit still local, exit 0)"
H3="$TMP_ROOT/h3"; mkdir -p "$H3"
SD3="$H3/.local/state/disk-magician"
# Point origin at an unwritable/bogus path so push fails.
run_sc "$H3" >/dev/null 2>&1
git -C "$SD3" remote add origin /nonexistent/bare.git 2>/dev/null || true
OUT3=$(run_sc "$H3" 2>&1); RC3=$?
[[ $RC3 -eq 0 ]] && ok "push failure is non-fatal (exit 0)" || bad "non-fatal push" "rc=$RC3"
[[ "$OUT3" == *[Pp]ush* ]] && ok "push outcome logged" || bad "push log" "$OUT3"
LOG3="$(git -C "$SD3" log --oneline 2>&1)"
[[ "$LOG3" == *[Ss]napshot* ]] && ok "commit preserved despite push failure" || bad "commit preserved" "$LOG3"
RF3="$H3/.disk_magician_state/receipts/snapshot_commit.json"
grep -q '"outcome": "success"' "$RF3" && ok "push failure still reports success outcome" || bad "push outcome" "not success"
grep -q '"pushed": false' "$RF3" && ok "push failure records pushed false" || bad "push pushed" "not false"

echo "Test 4: state_repo_path config grandfathers an existing repo in place"
H4="$TMP_ROOT/h4"; mkdir -p "$H4/.config/disk-magician"
LEGACY="$TMP_ROOT/legacy-backup"; mkdir -p "$LEGACY/backup/somehost"
printf '{"pre":"existing"}\n' > "$LEGACY/backup/somehost/disk_snapshot.json"
( cd "$LEGACY" && git init -q -b main && git -c user.email=x@x -c user.name=x add -A && git -c user.email=x@x -c user.name=x commit -qm seed )
printf '{"state_repo_path": "%s"}\n' "$LEGACY" > "$H4/.config/disk-magician/config.json"
OUT4=$(run_sc "$H4" 2>&1); RC4=$?
[[ $RC4 -eq 0 ]] && ok "grandfathered run exits 0" || bad "grandfather rc" "$RC4: $OUT4"
[[ -f "$LEGACY/snapshots/disk_snapshot.json" ]] && ok "new-layout snapshots/ created in legacy repo" || bad "new layout" "missing"
[[ -f "$LEGACY/backup/somehost/disk_snapshot.json" ]] && ok "existing backup/<host>/ left untouched" || bad "legacy preserved" "gone"
[[ "$(cat "$LEGACY/backup/somehost/disk_snapshot.json")" == '{"pre":"existing"}' ]] && ok "legacy content byte-identical" || bad "legacy content" "changed"

echo "Test 5: tracked 5G ledger is unmasked before snapshot staging"
H5="$TMP_ROOT/h5"; mkdir -p "$H5/.disk_magician_state"
DM_TEST_FRONTIER="$H5/.disk_magician_state/frontier_last.json"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FIXTURE_USER_HOME="$(python3 -c 'import os; print(os.path.realpath(os.path.expanduser("~")))')"
cat > "$DM_TEST_FRONTIER" <<EOF
{"schema_version":2,"captured_at":"$NOW","hostname":"test","mode":"complete","coverage_envelope":{"complete":true,"fda_preflight_status":"granted","fda_user_preflight_status":"granted","reachable_top_level_roots":1,"measured_top_level_roots":1,"unfinished_top_level_roots":0},"fda_probe_paths":{"mobile_sync":"$FIXTURE_USER_HOME/Library/Application Support/MobileSync/Backup","mail":"$FIXTURE_USER_HOME/Library/Mail","messages":"$FIXTURE_USER_HOME/Library/Messages"},"fda_preflight":{"status":"granted","probes":{"mobile_sync":{"path":"$FIXTURE_USER_HOME/Library/Application Support/MobileSync/Backup","status":"readable"},"mail":{"path":"$FIXTURE_USER_HOME/Library/Mail","status":"readable"},"messages":{"path":"$FIXTURE_USER_HOME/Library/Messages","status":"readable"}}},"frontier_unfinished":[],"opaque_intrinsic_gates":[],"disk_used_kb":1048576,"residual_kb":0,"purgeable_kb":0,"granularity_buckets":[{"path":"/small","measured_kb":1048576}],"oversize_indivisible_files":[],"accounting_equation":{"displayed_balanced":true,"display_ledger_valid":true,"data_used_kb":1048576,"displayed_buckets_kb":1048576,"oversize_indivisible_files_kb":0,"sub_granularity_tail_kb":0,"purgeable_kb":0,"residual_kb":0,"clone_shared_adjustment_kb":0}}
EOF
run_sc "$H5" >/dev/null 2>&1
SD5="$H5/.local/state/disk-magician"
git -C "$SD5" update-index --assume-unchanged ledger/topdown-5g.json ledger/topdown-5g.md
run_sc "$H5" >/dev/null 2>&1
FLAGS5="$(git -C "$SD5" ls-files -v ledger/topdown-5g.json ledger/topdown-5g.md)"
[[ "$FLAGS5" != h* ]] && ok "ledger index flags are not assume-unchanged" || bad "ledger flags" "$FLAGS5"
git -C "$SD5" show HEAD:ledger/topdown-5g.json | grep -q 'granularity_buckets' \
  && ok "validated 5G ledger committed" || bad "ledger commit" "missing ledger payload"

echo "Test 6: partial frontier preserves the last published mega-table"
H6="$TMP_ROOT/h6"; mkdir -p "$H6/.disk_magician_state"
DM_TEST_FRONTIER="$H6/.disk_magician_state/frontier_last.json"
NOW6="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$DM_TEST_FRONTIER" <<EOF
{"schema_version":2,"captured_at":"$NOW6","hostname":"test","mode":"complete","coverage_envelope":{"complete":true,"fda_preflight_status":"granted","fda_user_preflight_status":"granted","reachable_top_level_roots":1,"measured_top_level_roots":1,"unfinished_top_level_roots":0},"fda_probe_paths":{"mobile_sync":"$FIXTURE_USER_HOME/Library/Application Support/MobileSync/Backup","mail":"$FIXTURE_USER_HOME/Library/Mail","messages":"$FIXTURE_USER_HOME/Library/Messages"},"fda_preflight":{"status":"granted","probes":{"mobile_sync":{"path":"$FIXTURE_USER_HOME/Library/Application Support/MobileSync/Backup","status":"readable"},"mail":{"path":"$FIXTURE_USER_HOME/Library/Mail","status":"readable"},"messages":{"path":"$FIXTURE_USER_HOME/Library/Messages","status":"readable"}}},"frontier_unfinished":[],"opaque_intrinsic_gates":[],"disk_used_kb":1048576,"residual_kb":0,"purgeable_kb":0,"granularity_buckets":[{"path":"/published","measured_kb":1048576}],"oversize_indivisible_files":[],"accounting_equation":{"displayed_balanced":true,"display_ledger_valid":true,"data_used_kb":1048576,"displayed_buckets_kb":1048576,"oversize_indivisible_files_kb":0,"sub_granularity_tail_kb":0,"purgeable_kb":0,"residual_kb":0,"clone_shared_adjustment_kb":0}}
EOF
run_sc "$H6" >/dev/null 2>&1
SD6="$H6/.local/state/disk-magician"
cp "$SD6/ledger/topdown-5g.json" "$TMP_ROOT/published.json"
cp "$SD6/ledger/topdown-5g.md" "$TMP_ROOT/published.md"
cat > "$DM_TEST_FRONTIER" <<EOF
{"captured_at":"$NOW6","hostname":"test","mode":"partial","coverage_envelope":{"complete":false,"status":"partial"},"disk_used_kb":2097152,"residual_kb":1048576,"purgeable_kb":0,"granularity_buckets":[{"path":"/new-partial","measured_kb":1048576}],"oversize_indivisible_files":[],"accounting_equation":{"displayed_balanced":true}}
EOF
OUT6=$(run_sc "$H6" 2>&1); RC6=$?
[[ $RC6 -eq 0 ]] && ok "partial run exits 0" || bad "partial rc" "$RC6: $OUT6"
cmp -s "$TMP_ROOT/published.json" "$SD6/ledger/topdown-5g.json" \
  && ok "partial run preserved JSON mega-table" || bad "partial JSON preservation" "changed"
cmp -s "$TMP_ROOT/published.md" "$SD6/ledger/topdown-5g.md" \
  && ok "partial run preserved Markdown mega-table" || bad "partial Markdown preservation" "changed"
grep -q '"status": "partial"' "$SD6/ledger/topdown-5g.status.json" \
  && ok "partial status recorded" || bad "partial status" "missing or incorrect"
git -C "$SD6" show HEAD:ledger/topdown-5g.status.json | grep -q '"status": "partial"' \
  && ok "partial status committed" || bad "partial status commit" "missing"

echo "Test 7: lock contention skips run (exit 0) and records skipped_lock receipt"
H7="$TMP_ROOT/h7"; mkdir -p "$H7/.disk_magician_state/snapshot.lock"
echo "$$" > "$H7/.disk_magician_state/snapshot.lock/pid"
OUT7=$(run_sc "$H7" 2>&1); RC7=$?
[[ $RC7 -eq 0 ]] && ok "lock skip exits 0" || bad "lock skip rc" "$RC7: $OUT7"
RF7="$H7/.disk_magician_state/receipts/snapshot_commit.json"
[[ -f "$RF7" ]] && ok "receipt written on lock skip" || bad "receipt on lock skip" "missing"
grep -q '"outcome": "skipped_lock"' "$RF7" && ok "receipt outcome is skipped_lock" || bad "receipt outcome" "not skipped_lock"

echo "Test 8: git commit failure cannot report success (exits nonzero, outcome error)"
H8="$TMP_ROOT/h8"; mkdir -p "$H8"
run_sc "$H8" >/dev/null 2>&1
SD8="$H8/.local/state/disk-magician"
mkdir -p "$SD8/.git/hooks"
cat > "$SD8/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
exit 1
HOOK
chmod +x "$SD8/.git/hooks/pre-commit"
OUT8=$(run_sc "$H8" 2>&1); RC8=$?
[[ $RC8 -ne 0 ]] && ok "commit failure exits nonzero" || bad "commit failure rc" "unexpected exit 0"
RF8="$H8/.disk_magician_state/receipts/snapshot_commit.json"
[[ -f "$RF8" ]] && ok "receipt file written on commit failure" || bad "commit failure receipt" "missing"
grep -q '"outcome": "error"' "$RF8" && ok "receipt outcome is error" || bad "commit failure outcome" "not error"
grep -q '"committed": false' "$RF8" && ok "receipt publication.committed is false" || bad "receipt committed" "not false"

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
