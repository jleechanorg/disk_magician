#!/usr/bin/env bash
# test_slim_worktree_checkouts.sh — fixture tests for scripts/slim_worktree_checkouts.sh
#
# Uses a real git repo with a real linked worktree, because the behavior under
# test IS git sparse-checkout (a synthetic .git pointer cannot exercise it).
#
# Run: bash tests/test_slim_worktree_checkouts.sh
set -uo pipefail
export TMPDIR=/tmp
PYTHON_BIN="$(dirname "$(command -v python3 2>/dev/null || echo "/usr/bin/python3")")"
GIT_BIN="$(dirname "$(command -v git 2>/dev/null || echo "/usr/bin/git")")"
TEST_PATH="$PYTHON_BIN:$GIT_BIN:/usr/bin:/bin:/usr/sbin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/slim_worktree_checkouts.sh"

TMP_ROOT=$(cd "$(mktemp -d -t slim_wt.XXXXXX)" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
record_pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
record_fail() { echo "  FAIL  $1"; echo "        $2"; FAIL=$((FAIL + 1)); }
assert_contains() { grep -qF "$2" <<<"$3" && record_pass "$1" || record_fail "$1" "expected: $2"; }
assert_absent() { [[ ! -e "$2" ]] && record_pass "$1" || record_fail "$1" "should not exist: $2"; }
assert_present() { [[ -e "$2" ]] && record_pass "$1" || record_fail "$1" "missing: $2"; }

# --- fixture: repo with docs/ payload + linked worktrees --------------------
REPO="$TMP_ROOT/repo"
ROOTS="$TMP_ROOT/roots"
mkdir -p "$REPO/docs/user-stories-ui/shots" "$REPO/src" "$ROOTS"
printf 'x' > "$REPO/src/keep.py"
head -c 200000 /dev/zero > "$REPO/docs/user-stories-ui/shots/big.png"
printf '# doc\n' > "$REPO/docs/user-stories-ui/readme.md"
mkdir -p "$REPO/evidence"; head -c 150000 /dev/zero > "$REPO/evidence/run.bin"
( cd "$REPO" && git init -q . && git config user.email t@t && git config user.name t \
  && git config extensions.worktreeConfig true \
  && git add -A && git commit -qm init )

mk_wt() { # mk_wt <name> -> prints path
  local name="$1" wt="$ROOTS/$1"
  git -C "$REPO" worktree add -q --detach "$wt" >/dev/null 2>&1
  echo "$wt"
}
age_wt() { # age_wt <path>  — backdate every file so recency reports it dormant
  local ts
  ts=$(date -v-6d +%Y%m%d%H%M 2>/dev/null || date -d "-6 days" +%Y%m%d%H%M)
  find "$1" -path "$1/.git" -prune -o -exec touch -t "$ts" {} + 2>/dev/null
}

OLD=$(mk_wt old-clean);             age_wt "$OLD"
YOUNG=$(mk_wt young-active)
DIRTY=$(mk_wt old-dirty)
printf 'local edit\n' >> "$DIRTY/docs/user-stories-ui/readme.md"   # edit first, then age:
age_wt "$DIRTY"                                                        # aging after the edit keeps it dormant

run() { env -i PATH="$TEST_PATH" HOME="$TMP_ROOT/home" WORKTREE_APPROVED="${APPROVED:-0}" \
          bash "$TARGET_SCRIPT" --roots "$ROOTS" "$@" 2>&1; }

echo "== case 1: dry-run reports, changes nothing =="
OUT=$(run)
assert_contains "dry-run finds the dormant worktree" "WOULD-SLIM" "$OUT"
assert_present  "dry-run keeps docs on disk" "$OLD/docs/user-stories-ui"
assert_contains "dry-run counts only dormant worktree" "Worktrees slimmed:      1" "$OUT"

echo "== case 2: --clean without approval refuses =="
OUT=$(APPROVED=0 run --clean)
RC=$?
assert_contains "refuses without WORKTREE_APPROVED" "set WORKTREE_APPROVED=1" "$OUT"
[[ "$RC" -ne 0 ]] && record_pass "non-zero exit on refusal" || record_fail "non-zero exit on refusal" "rc=$RC"
assert_present "refusal leaves docs intact" "$OLD/docs/user-stories-ui"

echo "== case 3: --clean with approval slims, history intact =="
OUT=$(APPROVED=1 run --clean)
assert_contains "applies the exclusion" "SLIMMED" "$OUT"
assert_absent   "docs removed from checkout" "$OLD/docs/user-stories-ui"
assert_present  "non-excluded file survives" "$OLD/src/keep.py"
assert_present  "sparse-checkout file written per worktree" \
  "$(git -C "$OLD" rev-parse --git-dir)/info/sparse-checkout"
HIST=$(git -C "$REPO" ls-tree -r --name-only HEAD | grep -c 'docs/user-stories-ui')
[[ "$HIST" -ge 2 ]] && record_pass "docs still in git history ($HIST paths)" \
                    || record_fail "docs still in git history" "found $HIST"

echo "== case 4: young + dirty + already-sparse are skipped =="
assert_present "young worktree untouched" "$YOUNG/docs/user-stories-ui"
assert_contains "dirty worktree reported and skipped" "local changes under docs" "$OUT"
assert_present "dirty worktree keeps its docs" "$DIRTY/docs/user-stories-ui"
OUT2=$(APPROVED=1 run --clean)
assert_contains "second run skips already-sparse worktree" "already sparse): 1" "$OUT2"

echo "== case 5: unmeasurable age fails closed =="
BROKEN="$ROOTS/old-clean"   # already sparse -> deterministic skip path
OUT3=$(APPROVED=1 run --min-age notanumber --clean)
assert_contains "rejects a non-numeric floor" "min-age must be an integer" "$OUT3"

echo "== case 6: AO-owned worktrees are never slimmed =="
AO_PARENT="$TMP_ROOT/container/.ao/data/worktrees/wa"
mkdir -p "$AO_PARENT"
AO_WT="$AO_PARENT/agent-1"
git -C "$REPO" worktree add -q --detach "$AO_WT" >/dev/null 2>&1
age_wt "$AO_WT"
OUT4=$(APPROVED=1 env -i PATH="$TEST_PATH" HOME="$TMP_ROOT/home" WORKTREE_APPROVED=1 \
        bash "$TARGET_SCRIPT" --roots "$ROOTS,$AO_PARENT" --clean 2>&1)
assert_contains "AO-owned counted as skipped" "Skipped (ao-owned):     1" "$OUT4"
assert_present  "AO worktree keeps its docs" "$AO_WT/docs/user-stories-ui"

echo "== case 7: an already-sparse worktree gains a newly requested exclusion =="
assert_present "evidence still checked out before" "$OLD/evidence/run.bin"
OUT5=$(APPROVED=1 run --exclude docs,evidence --clean)
assert_contains "already-sparse worktree is re-slimmed" "SLIMMED" "$OUT5"
assert_absent   "new exclusion applied" "$OLD/evidence/run.bin"
assert_absent   "existing exclusion kept" "$OLD/docs/user-stories-ui"
assert_present  "non-excluded file survives" "$OLD/src/keep.py"
SPARSE="$(git -C "$OLD" rev-parse --git-dir)/info/sparse-checkout"
assert_contains "sparse file keeps docs" "!/docs/" "$(cat "$SPARSE")"
assert_contains "sparse file adds evidence" "!/evidence/" "$(cat "$SPARSE")"
[[ "$(grep -c '^!/docs/$' "$SPARSE")" -eq 1 ]] && record_pass "no duplicate docs pattern" || record_fail "no duplicate docs pattern" "$(cat "$SPARSE")"
OUT6=$(APPROVED=1 run --exclude docs,evidence --clean)
assert_contains "fully-excluded worktree is skipped next run" "already sparse): 1" "$OUT6"
assert_present  "dirty worktree still untouched" "$DIRTY/docs/user-stories-ui/readme.md"

echo "== case 8: --min-age-hours enforces >=2h, requires WORKTREE_APPROVED=1, logs override =="
OUT_LT2=$(APPROVED=1 run --min-age-hours 1 --clean); RC_LT2=$?
[[ "$RC_LT2" -eq 2 ]] && record_pass "rejects min-age-hours < 2 (rc=2)" || record_fail "rejects min-age-hours < 2" "rc=$RC_LT2"
assert_contains "rejects min-age-hours < 2 message" "minimum is 2 hours" "$OUT_LT2"

OUT_UNAPPROVED=$(APPROVED=0 run --min-age-hours 2); RC_UNAPPROVED=$?
[[ "$RC_UNAPPROVED" -eq 1 ]] && record_pass "rejects --min-age-hours without WORKTREE_APPROVED=1" || record_fail "rejects --min-age-hours without WORKTREE_APPROVED=1" "rc=$RC_UNAPPROVED"
assert_contains "rejects unapproved --min-age-hours message" "WORKTREE_APPROVED=1" "$OUT_UNAPPROVED"

H3_WT=$(mk_wt three-hour-clean)
H1_WT=$(mk_wt one-hour-clean)
ts_3h=$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d "-3 hours" +%Y%m%d%H%M)
ts_1h=$(date -v-1H +%Y%m%d%H%M 2>/dev/null || date -d "-1 hours" +%Y%m%d%H%M)
find "$H3_WT" -path "$H3_WT/.git" -prune -o -exec touch -t "$ts_3h" {} + 2>/dev/null
find "$H1_WT" -path "$H1_WT/.git" -prune -o -exec touch -t "$ts_1h" {} + 2>/dev/null
STATE_TMP="$TMP_ROOT/state"
OUT_H2=$(DISK_MAGICIAN_STATE_DIR="$STATE_TMP" WORKTREE_APPROVED=1 env -i PATH="$TEST_PATH" HOME="$TMP_ROOT/home" \
  DISK_MAGICIAN_STATE_DIR="$STATE_TMP" WORKTREE_APPROVED=1 bash "$TARGET_SCRIPT" --roots "$ROOTS" --min-age-hours 2 --clean 2>&1)
assert_contains "3h worktree slimmed with --min-age-hours 2" "SLIMMED" "$OUT_H2"
assert_absent "3h worktree docs removed" "$H3_WT/docs/user-stories-ui"
assert_present "1h worktree docs preserved" "$H1_WT/docs/user-stories-ui"
assert_contains "guard log records hours:2 override" "slim-worktrees: recency override active: hours:2" "$(cat "$STATE_TMP/worktree_guard.log" 2>/dev/null || true)"

echo "== case 9: incomplete lsof evidence fails closed (nothing slimmed) =="
FAIL_BIN="$TMP_ROOT/failbin"; mkdir -p "$FAIL_BIN"
printf '#!/bin/sh\necho "lsof: WARNING: partial" >&2\nprintf "p1\\n"\nexit 1\n' > "$FAIL_BIN/lsof"; chmod +x "$FAIL_BIN/lsof"
LSOF_WT=$(mk_wt lsof-fail-clean)
find "$LSOF_WT" -path "$LSOF_WT/.git" -prune -o -exec touch -t "$(date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d '-10 days' +%Y%m%d%H%M)" {} + 2>/dev/null
OUT_LSOF=$(WORKTREE_APPROVED=1 env -i PATH="$FAIL_BIN:$TEST_PATH" HOME="$TMP_ROOT/home" WORKTREE_APPROVED=1 \
  DISK_MAGICIAN_STATE_DIR="$TMP_ROOT/state-lsof" bash "$TARGET_SCRIPT" --roots "$ROOTS" --clean 2>&1)
assert_contains "slim refuses on incomplete lsof" "lsof output incomplete" "$OUT_LSOF"
assert_present "worktree docs untouched when lsof incomplete" "$LSOF_WT/docs/user-stories-ui"

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
