#!/usr/bin/env bash
# The CLI exposes C14's read-only verdict without exposing removal options.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRATCH_TMP="$(bash "$REPO_ROOT/disk_magician.sh" scratch-dir tmp)"
TMP_ROOT="$(mktemp -d "$SCRATCH_TMP/quarantine-verdict.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
export TMPDIR="$SCRATCH_TMP"
export DISK_MAGICIAN_STATE_DIR="$TMP_ROOT/state"

ORIGIN="$TMP_ROOT/origin.git"
BASE="$TMP_ROOT/base"
WT="$TMP_ROOT/home/.worktrees/repo/candidate"
mkdir -p "${WT%/*}"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$BASE"
printf 'tracked\n' > "$BASE/README.md"
printf '.venv/\n' > "$BASE/.gitignore"
git -C "$BASE" -c user.name=test -c user.email=test@invalid add -A
git -C "$BASE" -c user.name=test -c user.email=test@invalid commit -qm init
git -C "$BASE" remote add origin "$ORIGIN"
git -C "$BASE" push -q -u origin main
git -C "$BASE" -c user.name=test -c user.email=test@invalid worktree add -q -b candidate "$WT"
git -C "$WT" -c user.name=test -c user.email=test@invalid push -q -u origin candidate
mkdir -p "$WT/.venv/lib"
printf 'preserve this rebuildable file\n' > "$WT/.venv/lib/site.py"
OLD="$(date -d '-10 days' +%Y%m%d%H%M 2>/dev/null || date -v-10d +%Y%m%d%H%M)"
for stale in "$WT/README.md" "$WT/.gitignore" "$WT/.venv" "$WT/.venv/lib/site.py"; do touch -t "$OLD" "$stale"; done

CANDIDATE="$TMP_ROOT/opaque-preview"
mkdir -p "$CANDIDATE"
printf 'preserve me\n' > "$CANDIDATE/payload.txt"

OUT="$(bash "$REPO_ROOT/disk_magician.sh" quarantine verdict "$WT/.venv" --kind rebuildable 2>&1)"
[[ "$OUT" == remove ]] || { echo "FAIL: expected exact C14 remove verdict, got: $OUT"; exit 1; }
[[ "$(cat "$WT/.venv/lib/site.py")" == 'preserve this rebuildable file' ]] || {
  echo "FAIL: remove verdict deleted the venv"
  exit 1
}

set +e
OUT="$(bash "$REPO_ROOT/disk_magician.sh" quarantine verdict "$CANDIDATE" --kind rebuildable 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 0 && "$OUT" == kept:* ]] || {
  echo "FAIL: expected a kept C14 verdict (dispatch rc=$RC), got: $OUT"
  exit 1
}
[[ "$(cat "$CANDIDATE/payload.txt")" == 'preserve me' ]] || {
  echo "FAIL: read-only verdict changed the candidate"
  exit 1
}
OUT="$(bash "$REPO_ROOT/disk_magician.sh" quarantine verdict "$CANDIDATE" 2>&1)"
[[ "$OUT" == kept:* ]] || { echo "FAIL: verdict without optional arguments failed: $OUT"; exit 1; }

LEDGER="$TMP_ROOT/c14-ledger.jsonl"
OUT="$(DISK_MAGICIAN_C14_LEDGER="$LEDGER" bash "$REPO_ROOT/disk_magician.sh" \
  quarantine verdict "$CANDIDATE" --kind rebuildable 2>&1)"
[[ "$OUT" == kept:* && ! -e "$LEDGER" ]] || {
  echo "FAIL: read-only verdict wrote a C14 ledger or lost its keep verdict"
  exit 1
}

for forbidden in --self-test --inventory-out --own-reuse-claim --t3-owner-null \
  --frozen-identity --frozen-parent-identity --frozen-root-identity; do
  set +e
  OUT="$(bash "$REPO_ROOT/disk_magician.sh" quarantine verdict "$CANDIDATE" "$forbidden" rejected 2>&1)"
  RC=$?
  set -e
  [[ "$RC" -eq 2 ]] || { echo "FAIL: $forbidden was not rejected (rc=$RC)"; exit 1; }
done

set +e
OUT="$(bash "$REPO_ROOT/disk_magician.sh" quarantine verdict --self-test 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 2 ]] || { echo "FAIL: --self-test path was not rejected (rc=$RC)"; exit 1; }

# A read-only query must never publish a rescue snapshot for dirty source.
printf 'local changes\n' > "$WT/dirty.txt"
touch -t "$OLD" "$WT/dirty.txt"
OUT="$(bash "$REPO_ROOT/disk_magician.sh" quarantine verdict "$WT" 2>&1)"
[[ "$OUT" == kept:rescue-required ]] || {
  echo "FAIL: dirty-source preview did not require an actual rescue: $OUT"
  exit 1
}
[[ -z "$(git -C "$ORIGIN" for-each-ref refs/diskm-rescue)" ]] || {
  echo "FAIL: read-only query published a rescue ref"
  exit 1
}
[[ "$(cat "$WT/dirty.txt")" == 'local changes' ]] || {
  echo "FAIL: read-only query changed dirty source"
  exit 1
}
echo "PASS: quarantine verdict routes read-only C14 and rejects unsafe options"
