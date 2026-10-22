#!/usr/bin/env bash
# test_reclaim_ledger.sh — scripts/reclaim_ledger.py against a fixture deletion
# log and state repo (sandboxed HOME; never touches the real log or state repo).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RL="$REPO_ROOT/scripts/reclaim_ledger.py"
TMP_ROOT=$(mktemp -d -t reclaim_ledger_test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
has() { grep -q -F -- "$2" <<<"$1"; }
PYDIR="$(dirname "$(command -v python3)")"
NOW="2026-10-22T00:00:00Z"
GIB=1048576
TMPROOT=/tmp; [[ "$(uname)" == Darwin ]] && TMPROOT=/private/tmp
FRESH_OK="OK	published_age_hours=2	status=fresh	reason=ok"
FRESH_STALE="OK	published_age_hours=36	status=stale	reason=frontier_report_stale"

# run_rl <home> <log> <args...>
run_rl() {
  local home="$1" log="$2"; shift 2
  env -i HOME="$home" PATH="$PYDIR:/usr/bin:/bin" DISK_MAGICIAN_DELETION_LOG="$log" \
    python3 "$RL" --frontier "$home/none.json" --now "$NOW" "$@"
}

# row <ts> <script> <action> <kb> <path>
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }

H="$TMP_ROOT/mac"; mkdir -p "$H"
LOG="$H/deletions.log"
{
  row 2026-10-21T01:00:00Z cleanup_xcode.sh remove "$GIB" /private/tmp/ddroot/a
  row 2026-10-21T01:30:00Z cleanup_xcode.sh remove "$GIB" /private/tmp/ddroot/b
  row 2026-10-20T05:00:00Z cleanup_tmp.sh remove "$GIB" /private/tmp/ddroot/c
  row 2026-10-19T06:00:00Z cleanup_tmp.sh remove "$GIB" /private/tmp/ddroot/d
  row 2026-10-21T02:00:00Z cleanup_tmp.sh remove "$GIB" /private/tmp/oneoff/x
  row 2026-10-21T03:00:00Z cleanup_tmp.sh remove "$GIB" /private/tmp/_disk_magician_archive/x
  row 2026-10-20T03:00:00Z cleanup_tmp.sh remove "$GIB" /private/tmp/_disk_magician_archive/y
  row 2026-10-19T03:00:00Z cleanup_tmp.sh remove "$GIB" /private/tmp/_disk_magician_archive/z
  row 2026-10-21T04:00:00Z cleanup_tmp.sh dry-run-remove "$GIB" /private/tmp/dryroot/x
  row 2026-10-01T04:00:00Z cleanup_tmp.sh remove "$GIB" /private/tmp/oldroot/x
  row 2026-10-21T05:00:00Z cleanup_tmp.sh remove -1 /private/tmp/nosize/x
} >"$LOG"

echo "Test 1: section C sums the window, skips dry-run and out-of-window rows"
OUT=$(run_rl "$H" "$LOG" --stdout --freshness-line "$FRESH_OK"); RC=$?
[[ $RC -eq 0 ]] && ok "exits 0" || bad "exit" "rc=$RC: $OUT"
has "$OUT" '| `/private/tmp/ddroot` | 4.00 | 4 |' && ok "ddroot 4.00 GiB x4" || bad "ddroot row" "$OUT"
has "$OUT" '`cleanup_xcode.sh` (2)' && ok "owner script counts" || bad "owner counts" "$OUT"
has "$OUT" 'oldroot' && bad "out-of-window row excluded" "oldroot present" || ok "out-of-window row excluded"
has "$OUT" 'dryroot' && bad "dry-run row excluded" "dryroot present" || ok "dry-run row excluded"
has "$OUT" '1 rows had no size' && ok "unknown-size rows reported" || bad "unknown size note" "$OUT"

echo "Test 2: section D lists multi-day roots, not one-offs or tool staging"
D=$(awk '/^### D\./{f=1;next} /^### /{f=0} f' <<<"$OUT")
has "$D" '`/private/tmp/ddroot`' && ok "ddroot is a fast regrower (3 days)" || bad "ddroot in D" "$D"
has "$D" 'oneoff' && bad "one-off excluded" "$D" || ok "one-off excluded"
has "$D" '_disk_magician_archive' && bad "tool staging excluded" "$D" || ok "tool staging excluded"

echo "Test 3: stale banner appears only when the ledger is stale"
has "$OUT" 'STALE FULL-DISK LEDGER' && bad "no banner when fresh" "banner shown" || ok "no banner when fresh"
STALE=$(run_rl "$H" "$LOG" --stdout --freshness-line "$FRESH_STALE")
has "$STALE" 'STALE FULL-DISK LEDGER' && ok "banner when stale" || bad "banner when stale" "$STALE"
UNK=$(run_rl "$H" "$LOG" --stdout --freshness-line "UNKNOWN	no output")
has "$UNK" 'STALE FULL-DISK LEDGER' && ok "banner when unknown" || bad "banner when unknown" "$UNK"

echo "Test 4: B and A degrade to explicit 'Unavailable', never silent"
has "$OUT" '### B2. Top-down ledger growth' && has "$OUT" '### A. Uncovered' && ok "B and A headings present" || bad "headings" "$OUT"
has "$OUT" 'Unavailable' && ok "unavailable data is stated" || bad "unavailable" "$OUT"

echo "Test 5: --stdout writes and commits nothing"
SD="$H/.local/state/disk-magician"
[[ -e "$SD/reclaim" ]] && bad "--stdout writes nothing" "reclaim dir exists" || ok "--stdout writes nothing"

echo "Test 6: Linux layout: XDG state repo, /tmp roots, host from MACHINE, commit"
L="$TMP_ROOT/linux"; mkdir -p "$L/.local/state/disk-magician"
LSD="$L/.local/state/disk-magician"
git -C "$LSD" init -q 2>/dev/null
printf 'hostname: jeff-ubuntu\ncreated: 2026-07-21T11:50:18Z\n' >"$LSD/MACHINE"
git -C "$LSD" add MACHINE && git -C "$LSD" -c user.name=t -c user.email=t@t commit -q -m init
LLOG="$L/deletions.log"
{
  row 2026-10-21T01:00:00Z cleanup_tmp.sh remove "$GIB" /tmp/pr9-scratch/a
  row 2026-10-20T01:00:00Z cleanup_tmp.sh remove "$GIB" /tmp/pr9-scratch/b
  row 2026-10-19T01:00:00Z cleanup_tmp.sh remove "$GIB" /tmp/pr9-scratch/c
  row 2026-10-21T02:00:00Z cleanup_dev_caches.sh remove "$GIB" "$L/.cache/uv/wheels"
} >"$LLOG"
OUT6=$(run_rl "$L" "$LLOG" --freshness-line "$FRESH_OK"); RC6=$?
F="$LSD/reclaim/known-reclaim-dirs.md"
[[ $RC6 -eq 0 && -f "$F" ]] && ok "written to the XDG state repo" || bad "written" "rc=$RC6 $OUT6"
has "$OUT6" '(committed)' && ok "reports committed" || bad "committed" "$OUT6"
CONTENT=$(cat "$F" 2>/dev/null)
has "$CONTENT" '# Known reclaim directories: jeff-ubuntu' && ok "host name from MACHINE" || bad "host" "$CONTENT"
has "$CONTENT" "\`$TMPROOT/pr9-scratch\`" && ok "/tmp root grouped" || bad "/tmp root" "$CONTENT"
has "$CONTENT" '`~/.cache/uv`' && ok "home root folded to ~" || bad "home root" "$CONTENT"
SUBJ=$(git -C "$LSD" log -1 --format=%s)
[[ "$SUBJ" == "reclaim-ledger 2026-10-22T00:00:00Z" ]] && ok "commit message" || bad "commit message" "$SUBJ"
[[ -z "$(git -C "$LSD" status --porcelain)" ]] && ok "state repo clean after commit" || bad "clean" "$(git -C "$LSD" status --porcelain)"

echo "Test 7: an unchanged regeneration makes no new commit"
N1=$(git -C "$LSD" rev-list --count HEAD)
OUT7=$(run_rl "$L" "$LLOG" --freshness-line "$FRESH_OK")
N2=$(git -C "$LSD" rev-list --count HEAD)
[[ "$N1" == "$N2" ]] && has "$OUT7" '(unchanged)' && ok "idempotent" || bad "idempotent" "$N1 -> $N2 $OUT7"

echo "Test 8: --no-commit leaves the file uncommitted; unrelated staged files are untouched"
echo extra >"$LSD/extra.txt"; git -C "$LSD" add extra.txt
OUT8=$(run_rl "$L" "$LLOG" --freshness-line "$FRESH_OK" --days 3 --no-commit)
has "$OUT8" '(written)' && ok "--no-commit reports written" || bad "--no-commit" "$OUT8"
OUT8B=$(run_rl "$L" "$LLOG" --freshness-line "$FRESH_OK" --days 3)
git -C "$LSD" diff --cached --name-only | grep -q '^extra.txt$' && ok "unrelated staged file left staged" || bad "pathspec commit" "extra.txt not staged"

echo "Test 9: dispatched through diskm (disk_magician.sh)"
OUT9=$(env -i HOME="$H" PATH="$PYDIR:/usr/bin:/bin" DISK_MAGICIAN_DELETION_LOG="$LOG" \
  bash "$REPO_ROOT/disk_magician.sh" reclaim-ledger --stdout --freshness-line "$FRESH_OK" --now "$NOW" --frontier "$H/none.json" 2>&1)
has "$OUT9" '### C. Cleaned roots, last 7 days' && ok "dispatch works" || bad "dispatch" "$OUT9"
has "$(bash "$REPO_ROOT/disk_magician.sh" --help 2>&1)" 'reclaim-ledger' && ok "listed in usage" || bad "usage" "missing"

echo "Test 10: the snapshot job regenerates the ledger before its commit"
SC="$REPO_ROOT/scripts/snapshot_commit.sh"
L1=$(grep -n -F 'reclaim_ledger.py' "$SC" | head -1 | cut -d: -f1)
L2=$(grep -n -F 'git_id add -A' "$SC" | head -1 | cut -d: -f1)
[[ -n "$L1" && -n "$L2" && "$L1" -lt "$L2" ]] && ok "reclaim_ledger.py runs before git add -A" || bad "snapshot wiring" "L1=$L1 L2=$L2"

echo "Test 11: monitored_dirs growth from snapshot history; unmonitored roots flagged"
M="$TMP_ROOT/mon"; mkdir -p "$M/.local/state/disk-magician/config" "$M/.local/state/disk-magician/snapshots"
MSD="$M/.local/state/disk-magician"
git -C "$MSD" init -q 2>/dev/null
printf '{"monitored_dirs":[{"key":"adir","path":"~/a","timeout":60}],"monitored_globs":[{"key":"g","pattern":"~/glob*"}]}' >"$MSD/config/config.json"
snap() { printf '{"snapshot_coverage_pct":90,"directories":{"adir":%s,"g":%s},"carried_keys":[]}' "$1" "$1" >"$MSD/snapshots/disk_snapshot.json"
  git -C "$MSD" add -A && GIT_COMMITTER_DATE="$2" git -C "$MSD" -c user.name=t -c user.email=t@t commit -q -m s --date "$2"; }
snap $((1*GIB)) "2026-10-20T00:00:00Z"
snap $((5*GIB)) "2026-10-21T12:00:00Z"
MLOG="$M/deletions.log"
{
  row 2026-10-21T01:00:00Z cleanup_tmp.sh remove "$GIB" "$M/a/inside"
  row 2026-10-21T01:00:00Z cleanup_tmp.sh remove "$GIB" "$M/glob1/x"
  row 2026-10-21T01:00:00Z cleanup_tmp.sh remove "$GIB" "$M/elsewhere/x"
} >"$MLOG"
OUT11=$(run_rl "$M" "$MLOG" --stdout --freshness-line "$FRESH_OK")
has "$OUT11" '| `adir` | `~/a` | 5.00 | 1.00 | 4.00 |' && ok "B1 shows monitored dir growth 4.00 GiB" || bad "B1 row" "$OUT11"
has "$OUT11" '| `g` | `~/glob*` | 5.00 | 1.00 | 4.00 |' && ok "B1 shows a glob key with its pattern" || bad "B1 glob row" "$OUT11"
C11=$(awk '/^### C\./{f=1;next} /^### /{f=0} f' <<<"$OUT11")
has "$(grep -F '~/a' <<<"$C11")" '| yes |' && ok "dir under monitored_dirs is yes" || bad "monitored yes" "$C11"
has "$(grep -F '~/glob1' <<<"$C11")" '| yes |' && ok "dir matching monitored_globs is yes" || bad "glob yes" "$C11"
has "$(grep -F '~/elsewhere' <<<"$C11")" '**NO**' && ok "unmonitored root flagged NO" || bad "NO flag" "$C11"
has "$OUT11" 'not a second list' && ok "report-over-monitored_dirs statement present" || bad "statement" "missing"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
