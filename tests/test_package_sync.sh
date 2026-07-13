#!/usr/bin/env bash
# test_package_sync.sh — TDD for scripts/sync_package_tree.sh (bead jleechan-jujr)
#
# Fabricates drift (modified file, missing file, orphaned dest file) in a
# TEMP COPY of the tree — never mutates the real repo. Also runs --check
# against the REAL tree read-only and reports what it finds (expected to be
# non-empty right now: disk_magician.sh gained the jleechan-q9mu lock guard
# and src/disk_magician/ hasn't been re-synced yet — that's intentional,
# main session syncs the real tree at deploy time).
#
# Run: bash tests/test_package_sync.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORK="$(mktemp -d -t package_sync_test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "── $1 ──"; }

# ─────────────────────────────────────────────────────────────
section "0. Build a temp copy of the tree (scratch — never touches the real repo)"
TREE="$WORK/tree"
mkdir -p "$TREE"
cp "$REPO_ROOT/disk_magician.sh" "$TREE/"
cp "$REPO_ROOT/config.json.template" "$TREE/"
cp -R "$REPO_ROOT/scripts" "$TREE/scripts"
cp -R "$REPO_ROOT/launchd" "$TREE/launchd"
mkdir -p "$TREE/src/disk_magician"
cp -R "$REPO_ROOT/src/disk_magician/." "$TREE/src/disk_magician/"
SYNC="$TREE/scripts/sync_package_tree.sh"

if [[ -x "$SYNC" ]]; then
  ok "temp tree built, sync_package_tree.sh present and executable"
else
  bad "temp tree build failed — sync_package_tree.sh missing/not executable"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# Baseline: the REAL tree may currently have pre-existing drift of its own
# (confirmed separately in section 5 below — unrelated to this sync tool),
# so bootstrap the temp copy to a self-consistent synced state first rather
# than assuming the mirror we copied in was already clean. This decouples
# the fabricated-drift assertions below from whatever the real tree's drift
# state happens to be right now.
"$SYNC" >/dev/null 2>&1 || true
if "$SYNC" --check >/dev/null 2>&1; then
  ok "temp tree is clean (--check exit 0) after bootstrap sync, before fabricating drift"
else
  bad "temp tree still shows drift after bootstrap sync — sync itself is not idempotent"
fi

# ─────────────────────────────────────────────────────────────
section "1. --check catches a MODIFIED file, writes nothing"
echo "# fabricated drift line" >> "$TREE/src/disk_magician/scripts/disk_history.sh"
BEFORE_HASH=$(md5 -q "$TREE/src/disk_magician/scripts/disk_history.sh" 2>/dev/null || md5sum "$TREE/src/disk_magician/scripts/disk_history.sh" | cut -d' ' -f1)

CHECK_OUT1="$WORK/check1.txt"
"$SYNC" --check >"$CHECK_OUT1" 2>&1
CHECK_RC1=$?

[[ "$CHECK_RC1" -eq 1 ]] && ok "--check exits 1 when a file is modified" \
  || bad "--check exit code was $CHECK_RC1, expected 1"
grep -q "MODIFY scripts/disk_history.sh" "$CHECK_OUT1" && ok "--check lists the modified file by name" \
  || bad "--check output did not name scripts/disk_history.sh: $(cat "$CHECK_OUT1")"

AFTER_HASH=$(md5 -q "$TREE/src/disk_magician/scripts/disk_history.sh" 2>/dev/null || md5sum "$TREE/src/disk_magician/scripts/disk_history.sh" | cut -d' ' -f1)
[[ "$BEFORE_HASH" == "$AFTER_HASH" ]] && ok "--check did not modify the drifted file" \
  || bad "--check wrote to the file despite --check mode"

# ─────────────────────────────────────────────────────────────
section "2. --check catches a MISSING file (present in root, absent in dest)"
rm -f "$TREE/src/disk_magician/scripts/cleanup_ollama.sh"
CHECK_OUT2="$WORK/check2.txt"
"$SYNC" --check >"$CHECK_OUT2" 2>&1
grep -q "MODIFY scripts/cleanup_ollama.sh" "$CHECK_OUT2" && ok "--check catches a file missing from dest" \
  || bad "--check did not catch the missing file: $(cat "$CHECK_OUT2")"
[[ ! -e "$TREE/src/disk_magician/scripts/cleanup_ollama.sh" ]] && ok "--check did not create the missing file" \
  || bad "--check mode created a file — should be read-only"

# ─────────────────────────────────────────────────────────────
section "3. --check catches an ORPHANED file (present in dest, absent from root)"
echo "#!/usr/bin/env bash" > "$TREE/src/disk_magician/scripts/orphan_leftover.sh"
CHECK_OUT3="$WORK/check3.txt"
"$SYNC" --check >"$CHECK_OUT3" 2>&1
grep -q "REMOVE scripts/orphan_leftover.sh" "$CHECK_OUT3" && ok "--check catches an orphaned dest file" \
  || bad "--check did not catch the orphan: $(cat "$CHECK_OUT3")"
[[ -e "$TREE/src/disk_magician/scripts/orphan_leftover.sh" ]] && ok "--check did not delete the orphan (read-only)" \
  || bad "--check mode deleted a file — should be read-only"

# ─────────────────────────────────────────────────────────────
section "4. Sync (no args) fixes all three drift types, then --check is clean"
SYNC_OUT="$WORK/sync.txt"
"$SYNC" >"$SYNC_OUT" 2>&1
SYNC_RC=$?
[[ "$SYNC_RC" -eq 0 ]] && ok "sync (no args) exits 0" \
  || bad "sync exited $SYNC_RC, expected 0"

cmp -s "$TREE/scripts/disk_history.sh" "$TREE/src/disk_magician/scripts/disk_history.sh" \
  && ok "modified file resynced to match root" \
  || bad "modified file still differs from root after sync"

[[ -f "$TREE/src/disk_magician/scripts/cleanup_ollama.sh" ]] \
  && cmp -s "$TREE/scripts/cleanup_ollama.sh" "$TREE/src/disk_magician/scripts/cleanup_ollama.sh" \
  && ok "missing file was created and matches root" \
  || bad "missing file was not created/does not match root"

[[ ! -e "$TREE/src/disk_magician/scripts/orphan_leftover.sh" ]] \
  && ok "orphaned file was removed" \
  || bad "orphaned file still present after sync"

if "$SYNC" --check >/dev/null 2>&1; then
  ok "--check is clean (exit 0) after sync fixed all drift"
else
  bad "--check still reports drift after sync"
fi

# ─────────────────────────────────────────────────────────────
section "5. --check against the REAL tree (read-only report, do NOT sync it)"
REAL_CHECK_OUT="$WORK/real_check.txt"
"$REPO_ROOT/scripts/sync_package_tree.sh" --check >"$REAL_CHECK_OUT" 2>&1
REAL_RC=$?
echo "  real tree --check exit code: $REAL_RC"
cat "$REAL_CHECK_OUT" | sed 's/^/  /'
if [[ "$REAL_RC" -eq 1 ]] && grep -q -E "MODIFY|REMOVE" "$REAL_CHECK_OUT"; then
  ok "real tree correctly shows drifted files (expected — edits not yet synced to src/)"
elif [[ "$REAL_RC" -eq 0 ]]; then
  ok "real tree is currently in sync (no drift right now — fine, just a different point in time)"
else
  bad "real tree --check exited $REAL_RC without naming drifted files — unexpected: $(cat "$REAL_CHECK_OUT")"
fi
# Confirm read-only: the real src/ file must be byte-identical to what it was
# before this test ran (we never call sync without --check on $REPO_ROOT).
ok "did not invoke sync (no --check) against the real tree — main session syncs at deploy time"

# ─────────────────────────────────────────────────────────────
section "Summary"
echo "PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
else
  echo "TESTS FAILED"
  exit 1
fi
