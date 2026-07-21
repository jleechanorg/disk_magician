#!/usr/bin/env bash
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
#!/usr/bin/env bash
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
    bash "$SC" "${@:2}"
}

echo "Test 1: fresh run auto-inits state repo, writes snapshot, commits"
H1="$TMP_ROOT/h1"; mkdir -p "$H1"
OUT1=$(run_sc "$H1" 2>&1); RC1=$?
SD1="$H1/.local/state/disk-magician"
[[ $RC1 -eq 0 ]] && ok "exits 0" || bad "rc" "$RC1: $OUT1"
[[ -f "$SD1/snapshots/disk_snapshot.json" ]] && ok "snapshot written under snapshots/" || bad "snapshot path" "missing"
[[ -f "$SD1/config/config.json" ]] && ok "resolved config written" || bad "config path" "missing"
# Capture the log into a variable before matching rather than piping a live
# `git log` process straight into `grep` — a bare pipe here raced against
# git's just-finished commit and intermittently reported no match even
# though the commit was present a heartbeat later (grep-shim pipeline
# corruption class: memory feedback_2026-07-20_grep_shim_truncates_pipelines).
LOG1="$(git -C "$SD1" log --oneline 2>&1)"
[[ "$LOG1" == *[Ss]napshot* ]] && ok "commit made" || bad "commit" "$LOG1"
LASTC=$(git -C "$SD1" rev-list --count HEAD)

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

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
