#!/usr/bin/env bash
# test_install_launchd_sweepers_lock.sh — Regression test: concurrent
# invocations of install_launchd_sweepers.sh must not race bootout/bootstrap
# calls against each other.
#
# Root cause (2026-09-06/07): disk_magician's launchd fleet was observed
# flapping — jobs dropping out of `launchctl list` within minutes of a fresh
# repair, corroborated by a SEPARATE Gemini CLI session on the same machine
# independently running this exact installer. Two uncoordinated invocations
# interleaving install_plist()'s per-label `launchctl bootout` then
# `launchctl bootstrap` calls is the leading hypothesis. This test proves a
# second invocation, while a lock is held, exits cleanly WITHOUT touching
# launchctl or any plist file — never queues, never blocks, mirrors
# cleanup_worktree_venvs.sh's stated concurrent-run policy.
#
# Run: bash tests/test_install_launchd_sweepers_lock.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/install_launchd_sweepers.sh"

if [[ ! -x "$TARGET_SCRIPT" ]]; then
  echo "FAIL T1" >&2
  echo "$TARGET_SCRIPT not executable" >&2
  exit 2
fi

TMP_ROOT=$(mktemp -d -t install_launchd_sweepers_lock_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
STATE_DIR="$TMP_ROOT/state"
LAUNCHAGENTS_DIR="$TMP_ROOT/LaunchAgents"
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$STATE_DIR" "$LAUNCHAGENTS_DIR" "$FAKE_BIN"

INVOCATION_LOG="$TMP_ROOT/launchctl_invocations.log"
cat > "$FAKE_BIN/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$INVOCATION_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/launchctl"

LOCK_DIR="$STATE_DIR/install_launchd_sweepers.lock"
mkdir -p "$LOCK_DIR"
echo 999999 > "$LOCK_DIR/pid"

OUT="$TMP_ROOT/out.txt"
PATH="$FAKE_BIN:$PATH" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" DISK_MAGICIAN_LAUNCHAGENTS_DIR="$LAUNCHAGENTS_DIR" bash "$TARGET_SCRIPT" >"$OUT" 2>&1
RC=$?
OUT_CONTENT=$(cat "$OUT")

fail=0
[[ "$RC" -ne 0 ]] && fail=1
grep -qE "lock held|already running" <<<"$OUT_CONTENT" || fail=1
grep -q "installed " <<<"$OUT_CONTENT" && fail=1
[[ -f "$INVOCATION_LOG" ]] && fail=1

if [[ "$fail" -eq 0 ]]; then
  echo "PASS T1"
  exit 0
else
  echo "--- captured output ---" >&2
  echo "$OUT_CONTENT" >&2
  echo "FAIL T1"
  exit 1
fi
