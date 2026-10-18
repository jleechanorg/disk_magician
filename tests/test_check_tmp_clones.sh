#!/usr/bin/env bash
# test_check_tmp_clones.sh — Regression tests for /private/tmp full-clone & advice scratch detector
# (bead disk_magician-tmp-full-clones-still-produced-tjkb).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DISKM="$REPO_ROOT/disk_magician.sh"
CHECK_SCRIPT="$REPO_ROOT/scripts/check_tmp_clones.sh"

WORK="$(mktemp -d -t test_check_tmp_clones.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

FAKE_TMP="$WORK/private_tmp"
mkdir -p "$FAKE_TMP/worldarchitect.ai/evidence" "$FAKE_TMP/worldai_claw" "$FAKE_TMP/benign-small"
echo "small" > "$FAKE_TMP/benign-small/note.txt"
echo "evidence" > "$FAKE_TMP/worldarchitect.ai/evidence/report.txt"

# 1. Top-level full git clone (.git is a directory) with remote and branch
CLONE_DIR="$FAKE_TMP/pr10364-clone-opus"
mkdir -p "$CLONE_DIR"
git -C "$CLONE_DIR" init -q -b feat/opus-review
git -C "$CLONE_DIR" remote add origin "https://github.com/jleechanorg/worldarchitect.ai.git"
echo "payload" > "$CLONE_DIR/file.txt"

# 2. Linked git worktree (.git is a gitdir: file, NOT a directory) — should NOT be flagged as full clone
WT_DIR="$FAKE_TMP/linked-wt-clean"
mkdir -p "$WT_DIR"
echo "gitdir: /some/main/repo/.git/worktrees/linked-wt-clean" > "$WT_DIR/.git"
echo "hi" > "$WT_DIR/file.txt"

# 3. Child under /private/tmp/worldarchitect.ai matching advice*
ADVICE_DIR="$FAKE_TMP/worldarchitect.ai/advice-pr10364-621b945c.y99p"
mkdir -p "$ADVICE_DIR"
echo "review scratch" > "$ADVICE_DIR/diff.patch"

# 4. Child under /private/tmp/worldarchitect.ai matching level_up_suite_*
SUITE_DIR="$FAKE_TMP/worldarchitect.ai/level_up_suite_Ab12Cd"
mkdir -p "$SUITE_DIR"
echo "suite log" > "$SUITE_DIR/run.log"

# 5. Child under /private/tmp/worldai_claw matching *-full*
FULL_NAMING_DIR="$FAKE_TMP/worldai_claw/claw-full-copy"
mkdir -p "$FULL_NAMING_DIR"
echo "copy" > "$FULL_NAMING_DIR/data.txt"

# 6. Child under /private/tmp/worldarchitect.ai exceeding size threshold (oversize)
OVERSIZE_DIR="$FAKE_TMP/worldarchitect.ai/split-gates"
mkdir -p "$OVERSIZE_DIR"
dd if=/dev/zero of="$OVERSIZE_DIR/blob.bin" bs=1024 count=2048 >/dev/null 2>&1

echo "── 1. Script existence and CLI dispatch ──"
if [[ -x "$CHECK_SCRIPT" ]]; then
  ok "scripts/check_tmp_clones.sh exists and is executable"
else
  bad "scripts/check_tmp_clones.sh missing or not executable"
fi

# Use a 1 MiB threshold (0.001 GiB) so the 2 MiB split-gates dir triggers oversize without writing 1 GiB
OUT_TEXT="$WORK/out.txt"
if DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$FAKE_TMP" \
   DISK_MAGICIAN_TMP_CLONE_WARN_GB="0.001" \
   bash "$DISKM" check-tmp-clones >"$OUT_TEXT" 2>&1; then
  ok "disk_magician.sh check-tmp-clones runs and exits 0"
else
  bad "disk_magician.sh check-tmp-clones failed"
fi

echo "── 2. Detection accuracy (text output) ──"
grep -q "pr10364-clone-opus" "$OUT_TEXT" \
  && ok "flags top-level full git clone (pr10364-clone-opus)" \
  || bad "missed top-level full git clone: $(cat "$OUT_TEXT")"

grep -q "feat/opus-review" "$OUT_TEXT" && grep -q "worldarchitect.ai.git" "$OUT_TEXT" \
  && ok "reports git branch and remote for full git clone" \
  || bad "missing git branch or remote in output: $(cat "$OUT_TEXT")"

grep -q "advice-pr10364-621b945c.y99p" "$OUT_TEXT" \
  && ok "flags child advice* dir under /private/tmp/worldarchitect.ai" \
  || bad "missed child advice* dir under worldarchitect.ai"

grep -q "level_up_suite_Ab12Cd" "$OUT_TEXT" \
  && ok "flags child level_up_suite_* dir under /private/tmp/worldarchitect.ai" \
  || bad "missed child level_up_suite_* dir under worldarchitect.ai"

grep -q "claw-full-copy" "$OUT_TEXT" \
  && ok "flags child *-full* dir under /private/tmp/worldai_claw" \
  || bad "missed child *-full* dir under worldai_claw"

grep -q "split-gates" "$OUT_TEXT" \
  && ok "flags oversize child dir (split-gates) exceeding DISK_MAGICIAN_TMP_CLONE_WARN_GB" \
  || bad "missed oversize child dir split-gates"

! grep -q "linked-wt-clean" "$OUT_TEXT" \
  && ok "does not flag linked worktree (.git file) below threshold" \
  || bad "falsely flagged linked worktree (.git file)"

! grep -q "benign-small" "$OUT_TEXT" \
  && ok "does not flag small benign directory" \
  || bad "falsely flagged small benign directory"

! grep -q "/evidence" "$OUT_TEXT" \
  && ok "does not flag canonical protected evidence subdirectory below threshold" \
  || bad "falsely flagged evidence subdirectory"

echo "── 3. JSON output contract ──"
OUT_JSON="$WORK/out.json"
if DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$FAKE_TMP" \
   DISK_MAGICIAN_TMP_CLONE_WARN_GB="0.001" \
   bash "$DISKM" check-tmp-clones --json >"$OUT_JSON" 2>&1 &&
   python3 - "$OUT_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
entries = {e["name"]: e for e in data["entries"]}
assert "pr10364-clone-opus" in entries, entries
assert "full_git_clone" in entries["pr10364-clone-opus"]["reasons"], entries["pr10364-clone-opus"]
assert entries["pr10364-clone-opus"]["git_branch"] == "feat/opus-review"
assert "worldarchitect.ai.git" in entries["pr10364-clone-opus"]["git_remote"]
assert "advice-pr10364-621b945c.y99p" in entries
assert "advice" in entries["advice-pr10364-621b945c.y99p"]["owning_lane"]
assert "level_up_suite_Ab12Cd" in entries
assert "run_level_up_class_repro_suite" in entries["level_up_suite_Ab12Cd"]["owning_lane"]
assert "claw-full-copy" in entries
assert "split-gates" in entries
assert "oversize" in entries["split-gates"]["reasons"]
assert "linked-wt-clean" not in entries
assert "benign-small" not in entries
PY
then
  ok "JSON output contains structured entries, reasons, git info, and owning_lane"
else
  bad "JSON output validation failed: $(cat "$OUT_JSON" 2>/dev/null || true)"
fi

echo "── 4. Integration with scripts/disk_audit.sh ──"
AUDIT_OUT="$WORK/audit.txt"
DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$FAKE_TMP" \
DISK_MAGICIAN_TMP_CLONE_WARN_GB="0.001" \
HOME="$WORK/empty_home" \
  bash "$REPO_ROOT/scripts/disk_audit.sh" --no-history --skip-directory-breakdown >"$AUDIT_OUT" 2>&1 || true

grep -q "pr10364-clone-opus" "$AUDIT_OUT" && grep -q "advice-pr10364-621b945c.y99p" "$AUDIT_OUT" \
  && ok "disk_audit.sh surfaces /private/tmp full-clone and advice anomalies" \
  || bad "disk_audit.sh did not surface /private/tmp anomalies: $(cat "$AUDIT_OUT")"

echo
echo "Summary: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
