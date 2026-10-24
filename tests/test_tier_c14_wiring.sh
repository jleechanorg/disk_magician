#!/usr/bin/env bash
# test_tier_c14_wiring.sh — production-callstack wiring proof for governor
# T11-15 (rebuildable + os_clone) and T11-16 (declared-ephemeral E3-E7).
#
# Each tier is exercised through its real script entry point (not a unit stub):
#   * an eligible, past-retention entry is REMOVED, and
#   * provenance-less / undeclared content is KEPT.
# No candidate is ever removed by a direct `rm`; removal is C14 +
# quarantine_remove. Fixtures live only under /tmp (TMPDIR=/tmp).
set -uo pipefail
export TMPDIR=/tmp
set +e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/dm-tier-wiring.XXXXXX)" || exit 1
[[ "$T" == /tmp/dm-tier-wiring.* && -d "$T" && ! -L "$T" ]] || exit 1
T="$(cd -- "$T" && pwd -P)" || exit 1
trap 'rm -rf "$T"' EXIT

export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0
FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
present() { [[ -e "$1" ]] && ok "$2" || bad "$2 (missing: $1)"; }
absent()  { [[ ! -e "$1" ]] && ok "$2" || bad "$2 (still present: $1)"; }
contains(){ grep -qF "$2" "$1" && ok "$3" || bad "$3 (no '$2' in $1)"; }

# External boundary stubs only: lsof for the code-sign candidate probe + the
# C14 live-cwd probe, and xcrun so the Xcode tier never touches real simulators.
mkdir -p "$T/bin"
cat >"$T/bin/lsof" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" +D "* ]]; then
  [[ -n "${MOCK_LSOF_ACTIVE:-}" ]] && { echo p1; echo capp; echo "n$PWD/x"; exit 0; }
  exit 1
fi
echo "p$$"; echo fcwd; echo "n/"; exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/bin/xcrun"
chmod +x "$T/bin/lsof" "$T/bin/xcrun"

old_stamp() { date -v-40d +%Y%m%d%H%M 2>/dev/null || date -d '-40 days' +%Y%m%d%H%M; }
recent_stamp() { date -v-1d +%Y%m%d%H%M 2>/dev/null || date -d '-1 day' +%Y%m%d%H%M; }

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Tier: cleanup_dev_caches (rebuildable cache root + default kind) ==="
H="$T/devcaches"; mkdir -p "$H"
export HOME="$H"
mkdir -p "$HOME/.cache/uv/archive-v0/entry" "$HOME/.gemini/tmp/provenance-less"
echo data >"$HOME/.cache/uv/archive-v0/entry/payload"
echo keep >"$HOME/.gemini/tmp/provenance-less/payload"
S="$(old_stamp)"; find "$HOME/.cache/uv" "$HOME/.gemini/tmp" -exec touch -t "$S" {} + 2>/dev/null
DISK_MAGICIAN_STATE_DIR="$T/state-dc" bash "$REPO_ROOT/scripts/cleanup_dev_caches.sh" --clean >"$T/dc.out" 2>&1
absent  "$HOME/.cache/uv/archive-v0/entry" "rebuildable ~/.cache/uv entry removed"
present "$HOME/.gemini/tmp/provenance-less" "provenance-less ~/.gemini/tmp content kept"
contains "$T/dc.out" "C14 kept: $HOME/.gemini/tmp/provenance-less" "dev_caches logs the C14 keep reason"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Tier: cleanup_xcode (rebuildable DerivedData) ==="
H="$T/xcode"; mkdir -p "$H"
export HOME="$H"
mkdir -p "$HOME/Library/Developer/Xcode/DerivedData/App-abc" \
         "$HOME/Library/Developer/CoreSimulator/Caches/SimCache"
echo data >"$HOME/Library/Developer/Xcode/DerivedData/App-abc/build.o"
echo data >"$HOME/Library/Developer/CoreSimulator/Caches/SimCache/c.cache"
find "$HOME/Library/Developer" -exec touch -t "$S" {} + 2>/dev/null
DISK_MAGICIAN_STATE_DIR="$T/state-xc" PATH="$T/bin:$PATH" \
  bash "$REPO_ROOT/scripts/cleanup_xcode.sh" --clean >"$T/xc.out" 2>&1
absent "$HOME/Library/Developer/Xcode/DerivedData/App-abc" "rebuildable DerivedData entry removed"
absent "$HOME/Library/Developer/CoreSimulator/Caches/SimCache" "rebuildable CoreSimulator cache removed"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Tier: cleanup_code_sign_clones (os_clone) ==="
H="$T/codesign"; mkdir -p "$H"
export HOME="$H"
XD="$H/X"
mkdir -p "$XD/com.example.app.code_sign_clone/code_sign_clone.1234/Contents/MacOS"
dd if=/dev/zero of="$XD/com.example.app.code_sign_clone/code_sign_clone.1234/Contents/MacOS/bin" bs=1024 count=20 2>/dev/null
mkdir -p "$XD/not-a-clone"
find "$XD" -exec touch -t "$S" {} + 2>/dev/null
PATH="$T/bin:$PATH" CODE_SIGN_CLONES_APPROVED=1 CODE_SIGN_CLONE_MIN_KB=10 CODE_SIGN_CLONE_MIN_AGE_SEC=60 \
  DISK_MAGICIAN_CODE_SIGN_X_DIR="$XD" DISK_MAGICIAN_STATE_DIR="$T/state-cs" \
  bash "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" --clean >"$T/cs.out" 2>&1
absent  "$XD/com.example.app.code_sign_clone/code_sign_clone.1234" "os_clone candidate removed via C14"
present "$XD/not-a-clone" "non-clone path under X kept"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Tier: cleanup_pr_scratch (E3) ==="
H="$T/prscratch"; mkdir -p "$H"
export HOME="$H"
SCRATCH="$H/scratch"; mkdir -p "$SCRATCH/pr-old" "$SCRATCH/pr-secret"
echo data >"$SCRATCH/pr-old/f"; echo s >"$SCRATCH/pr-secret/secrets.txt"
find "$SCRATCH" -exec touch -t "$S" {} + 2>/dev/null
DISK_MAGICIAN_STATE_DIR="$T/state-pr" DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$SCRATCH" \
  DISK_MAGICIAN_TEST_SANDBOX="$SCRATCH" \
  bash "$REPO_ROOT/scripts/cleanup_pr_scratch.sh" --clean --tmp-dir "$SCRATCH" >"$T/pr.out" 2>&1
absent  "$SCRATCH/pr-old" "past-retention E3 scratch entry removed"
present "$SCRATCH/pr-secret" "secret-like scratch entry kept"
contains "$T/pr.out" "SKIP (C14 kept: kept:secret-like): $SCRATCH/pr-secret" "pr_scratch logs the C14 keep reason with its specific verdict"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Tier: prune_aside_sessions (E4) ==="
H="$T/aside"; mkdir -p "$H"
HOME="$H"; export HOME
mkdir -p "$HOME/.aside/u/0/sessions/old-1" "$HOME/.aside/u/0/sessions/secret-1"
echo old >"$HOME/.aside/u/0/sessions/old-1/messages.jsonl"
echo s >"$HOME/.aside/u/0/sessions/secret-1/secrets.txt"
find "$HOME/.aside" -exec touch -t "$S" {} + 2>/dev/null
printf '#!/bin/sh\nexit 1\n' >"$T/bin/lsof-aside"; chmod +x "$T/bin/lsof-aside"
DISK_MAGICIAN_LSOF_BIN="$T/bin/lsof-aside" \
  python3 "$REPO_ROOT/scripts/prune_aside_sessions.py" --clean --days 7 \
  --aside-dir "$HOME/.aside" >"$T/aside.out" 2>&1
absent  "$HOME/.aside/u/0/sessions/old-1" "past-retention E4 session removed"
present "$HOME/.aside/u/0/sessions/secret-1" "secret-like session kept"
contains "$T/aside.out" "Kept stale session (C14" "prune_aside logs the C14 keep reason"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Tier: cleanup_antigravity_brain.sh (E5) ==="
H="$T/brain"; mkdir -p "$H"
export HOME="$H"
B="$HOME/.gemini/antigravity/brain"
mkdir -p "$B/old-uuid" "$B/secret-uuid"
echo old >"$B/old-uuid/report.md"
echo s >"$B/secret-uuid/secrets.txt"
mkdir -p "$HOME/empty-roots"
find "$B" -exec touch -t "$S" {} + 2>/dev/null
DISK_MAGICIAN_STATE_DIR="$T/state-br" WORKTREE_APPROVED=1 DISK_MAGICIAN_WORKTREE_ROOTS="$HOME/empty-roots" \
  bash "$REPO_ROOT/scripts/cleanup_antigravity_brain.sh" --clean >"$T/br.out" 2>&1
absent  "$B/old-uuid" "past-retention E5 brain dir removed"
present "$B/secret-uuid" "secret-like brain dir kept"
contains "$T/br.out" "C14 kept: $B/secret-uuid" "brain cleanup logs the C14 keep reason"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Tier: cleanup_llm_inspector (E6) ==="
H="$T/captures"; mkdir -p "$H"
export HOME="$H"
C="$HOME/.llm-inspector/captures"; mkdir -p "$C"
echo old >"$C/capture-old.json"
echo s >"$C/capture-credentials.json"
echo keep >"$C/notes.json"
find "$C" -exec touch -t "$S" {} + 2>/dev/null
DISK_MAGICIAN_STATE_DIR="$T/state-ll" bash "$REPO_ROOT/scripts/cleanup_llm_inspector.sh" --clean >"$T/ll.out" 2>&1
absent  "$C/capture-old.json" "past-retention E6 capture removed"
present "$C/capture-credentials.json" "secret-like capture kept"
present "$C/notes.json" "non-capture file untouched"
contains "$T/ll.out" "C14 kept: $C/capture-credentials.json" "llm_inspector logs the C14 keep reason"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "=== Tier: cleanup_supervisor_logs (E7) ==="
H="$T/supervisor"; mkdir -p "$H"
export HOME="$H"
D="$HOME/.claude/supervisor"; mkdir -p "$D"
OLD_LOG="$D/cmux-codex-launchd.20200101T000000.log"
RECENT_LOG="$D/cmux-codex-launchd.20260101T000000.log"
echo old >"$OLD_LOG"
echo recent >"$RECENT_LOG"
echo active >"$D/cmux-codex-launchd.log"
touch -t "$S" "$OLD_LOG"
touch -t "$(recent_stamp)" "$RECENT_LOG"
DISK_MAGICIAN_STATE_DIR="$T/state-sv" bash "$REPO_ROOT/scripts/cleanup_supervisor_logs.sh" --clean >"$T/sv.out" 2>&1
absent  "$OLD_LOG" "past-retention E7 rotated log removed"
present "$RECENT_LOG" "recent rotated log kept (below 7d)"
present "$D/cmux-codex-launchd.log" "active log untouched"

echo
echo "=== Tier c14 wiring: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
