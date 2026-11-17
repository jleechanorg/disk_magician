#!/usr/bin/env bash
# Regression test for Defect 2: cleanup_worktrees.sh terminates promptly on TERM/INT,
# closes its job receipt, and releases held leases instead of surviving timeout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_BASE="${CLAUDE_CODE_TMPDIR:-${DISKM_SCRATCH:-${TMPDIR:-/tmp}}}"
TMP="$(mktemp -d "${TMP_BASE%/}/test-cw-term-trap.XXXXXX")"
HOLDER_PID=""
cleanup_tmp() {
    if [[ -n "$HOLDER_PID" ]]; then
        kill "$HOLDER_PID" 2>/dev/null || true
        wait "$HOLDER_PID" 2>/dev/null || true
    fi
    python3 -c 'import os,shutil,sys; p=sys.argv[1]; p and os.path.isabs(p) and p != "/" and shutil.rmtree(p, ignore_errors=True)' "$TMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$TIMEOUT_BIN" ]]; then
    echo "FATAL: timeout or gtimeout required" >&2
    exit 1
fi

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

HOME_DIR="$TMP/home"
STATE_DIR="$TMP/state"
ORIGIN="$TMP/origin.git"
REPO="$TMP/repo"
WT_ROOT="$HOME_DIR/.worktrees/fixture"
BIN_DIR="$TMP/bin"
mkdir -p "$HOME_DIR" "$STATE_DIR/worktree_leases" "$WT_ROOT" "$BIN_DIR"

# Deterministic fast lsof shim so tests do not scan host processes.
cat > "$BIN_DIR/lsof" <<'SH'
#!/usr/bin/env bash
printf 'p1\nfcwd\nn/\n'
SH
chmod +x "$BIN_DIR/lsof"

git init --bare -b main "$ORIGIN" >/dev/null
git init -b main "$REPO" >/dev/null
git -C "$REPO" config user.email "fixture@users.noreply.github.com"
git -C "$REPO" config user.name "fixture"
git -C "$REPO" remote add origin "$ORIGIN"
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md
HERMES_SKIP_EXAMPLE_COM_GUARD=1 git -C "$REPO" commit -m "base" >/dev/null
git -C "$REPO" push -u origin main >/dev/null 2>&1

for name in wt-one wt-two wt-three; do
    git -C "$REPO" worktree add -b "feat/$name" "$WT_ROOT/$name" HEAD >/dev/null 2>&1
    python3 -c '
import os, sys, time
old = time.time() - (72 * 3600)
for root, dirs, files in os.walk(sys.argv[1]):
    for f in files:
        p = os.path.join(root, f)
        if not os.path.islink(p):
            os.utime(p, (old, old))
    os.utime(root, (old, old))
' "$WT_ROOT/$name"
done
python3 -c '
import os, sys, time
old = time.time() - (72 * 3600)
for root, dirs, files in os.walk(sys.argv[1]):
    for f in files:
        p = os.path.join(root, f)
        if not os.path.islink(p):
            os.utime(p, (old, old))
    os.utime(root, (old, old))
' "$REPO/.git/worktrees"

echo "== 1. timeout (SIGTERM) terminates cleanup_worktrees.sh within timeout and closes receipt =="
HOOK1="$TMP/hook-term.sh"
cat > "$HOOK1" <<'SH'
#!/usr/bin/env bash
sleep 3
SH
chmod +x "$HOOK1"

CURSOR1="$STATE_DIR/cursor1.json"
if python3 - "$TIMEOUT_BIN" "$REPO_ROOT/scripts/cleanup_worktrees.sh" "$REPO" "$CURSOR1" "$HOME_DIR" "$STATE_DIR" "$BIN_DIR" "$HOOK1" <<'PY'
import os, subprocess, sys, time

timeout_bin, script, repo, cursor, home_dir, state_dir, bin_dir, hook = sys.argv[1:]
env = {
    **os.environ,
    "HOME": home_dir,
    "DISK_MAGICIAN_STATE_DIR": state_dir,
    "DISK_MAGICIAN_TEST_CLEANUP_CANDIDATE_HOOK": hook,
    "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
}
start = time.monotonic()
try:
    proc = subprocess.run(
        [timeout_bin, "3", "bash", script, "--repos", repo, "--cursor", cursor],
        env=env,
        capture_output=True,
        text=True,
        timeout=5.5,
    )
except subprocess.TimeoutExpired as exc:
    print("cleanup_worktrees survived timeout 3s past 5.5s watchdog", file=sys.stderr)
    sys.exit(1)

elapsed = time.monotonic() - start
if proc.returncode == 0:
    print("expected non-zero exit on timeout, got 0", file=sys.stderr)
    sys.exit(1)
if elapsed >= 5.0:
    print(f"took too long after SIGTERM: {elapsed:.2f}s", file=sys.stderr)
    sys.exit(1)
PY
then
    ok "timeout 3s terminated cleanup_worktrees.sh within watchdog window"
else
    bad "cleanup_worktrees.sh survived its 3s timeout"
fi

# Verify governed receipt was closed (not left active) and no lease locks remained.
if python3 - "$STATE_DIR" <<'PY'
import json, pathlib, sys
state = pathlib.Path(sys.argv[1])
receipt_file = state / "receipts" / "cleanup_worktrees.json"
data = json.loads(receipt_file.read_text())
assert data["active"] == [], f"expected no active receipts after SIGTERM, got {data['active']}"
assert data["last_terminal"] is not None, "expected terminal receipt on SIGTERM"
assert data["last_terminal"]["outcome"] in ("timeout", "error", "partial"), data["last_terminal"]
locks = list((state / "worktree_leases").glob("*.reuse-lock")) + list((state / "worktree_leases").glob(".*.reuse-lock"))
assert locks == [], f"lease locks leaked on SIGTERM: {locks}"
PY
then
    ok "governed job_receipt closed cleanly and zero lease locks remained on SIGTERM"
else
    bad "governed job_receipt remained active or lease lock leaked after SIGTERM"
fi

echo "== 2. Direct SIGINT terminates cleanup_worktrees.sh non-zero, closes receipt, and leaves no held lease locks =="
READY="$TMP/hook-ready"
HOOK="$TMP/hook.sh"
cat > "$HOOK" <<'SH'
#!/usr/bin/env bash
: > "$HOOK_READY"
sleep 10
SH
chmod +x "$HOOK"

CURSOR2="$STATE_DIR/cursor2.json"
if python3 - "$REPO_ROOT/scripts/cleanup_worktrees.sh" "$REPO" "$CURSOR2" "$HOME_DIR" "$STATE_DIR" "$BIN_DIR" "$HOOK" "$READY" <<'PY'
import json, os, pathlib, signal, subprocess, sys, time

script, repo, cursor, home_dir, state_dir, bin_dir, hook, ready = sys.argv[1:]
env = {
    **os.environ,
    "HOME": home_dir,
    "DISK_MAGICIAN_STATE_DIR": state_dir,
    "DISK_MAGICIAN_TEST_CLEANUP_CANDIDATE_HOOK": hook,
    "HOOK_READY": ready,
    "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
}
proc = subprocess.Popen(
    ["bash", script, "--repos", repo, "--cursor", cursor],
    env=env,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    start_new_session=True,
)
try:
    deadline = time.monotonic() + 5.0
    while not pathlib.Path(ready).exists() and proc.poll() is None:
        if time.monotonic() > deadline:
            raise AssertionError("cleanup_worktrees never reached candidate hook")
        time.sleep(0.02)
    os.killpg(proc.pid, signal.SIGINT)
    out, err = proc.communicate(timeout=3.0)
    assert proc.returncode != 0, f"expected non-zero rc on SIGINT, got {proc.returncode}"
    receipt_file = pathlib.Path(state_dir) / "receipts" / "cleanup_worktrees.json"
    data = json.loads(receipt_file.read_text())
    assert data["active"] == [], f"active receipt leaked on SIGINT: {data['active']}"
    locks = list((pathlib.Path(state_dir) / "worktree_leases").glob("*.reuse-lock")) + list((pathlib.Path(state_dir) / "worktree_leases").glob(".*.reuse-lock"))
    assert locks == [], f"lease locks leaked on SIGINT: {locks}"
finally:
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate(timeout=2)
PY
then
    ok "SIGINT exited non-zero, closed receipt, and left zero lease locks"
else
    bad "SIGINT failed receipt or lock cleanup"
fi

for name in wt-one wt-two wt-three; do
    if [[ -d "$WT_ROOT/$name" ]]; then
        ok "worktree $name preserved across interrupted runs"
    else
        bad "worktree $name unexpectedly deleted during interrupted run"
    fi
done

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
