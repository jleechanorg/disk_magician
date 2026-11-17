#!/usr/bin/env bash
# Dry-run eligibility must share the clean path's safety and C14 gates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRATCH_TMP="$(bash "$REPO_ROOT/disk_magician.sh" scratch-dir tmp)"
TMP_ROOT="$(mktemp -d "$SCRATCH_TMP/venv-dryrun-gates.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

HOME_FIX="$TMP_ROOT/home"
ROOTS="$HOME_FIX/.worktrees/repo"
STATE="$TMP_ROOT/state"
BASE="$TMP_ROOT/base"
ORIGIN="$TMP_ROOT/origin.git"
SAFETY_WT="$ROOTS/safety"
C14_WT="$ROOTS/c14-kept"
SAFETY_FILE="$TMP_ROOT/safety.json"
mkdir -p "$ROOTS"

git init -q --bare -b main "$ORIGIN"
git init -q -b main "$BASE"
printf 'base\n' > "$BASE/README.md"
printf '.venv/\nvenv/\n' > "$BASE/.gitignore"
git -C "$BASE" -c user.name=test -c user.email=test@invalid add -A
git -C "$BASE" -c user.name=test -c user.email=test@invalid commit -qm init
git -C "$BASE" remote add origin "$ORIGIN"
git -C "$BASE" push -q -u origin main

age_path_days_ago() {
  local path="$1" days="$2" stamp
  stamp="$(date -d "-$days days" +%Y%m%d%H%M 2>/dev/null || date -v-"${days}"d +%Y%m%d%H%M)"
  touch -t "$stamp" "$path"
}

make_worktree() {
  local branch="$1" path="$2"
  git -C "$BASE" -c user.name=test -c user.email=test@invalid worktree add -q -b "$branch" "$path"
  git -C "$path" -c user.name=test -c user.email=test@invalid push -q -u origin "$branch"
  mkdir -p "$path/.venv/lib" "$path/.venv.bak.20260101/lib"
  printf 'python module\n' > "$path/.venv/lib/site.py"
  printf 'backup module\n' > "$path/.venv.bak.20260101/lib/site.py"
  for file in "$path/README.md" "$path/.gitignore" "$path/.git" \
    "$path/.venv" "$path/.venv/lib/site.py" \
    "$path/.venv.bak.20260101" "$path/.venv.bak.20260101/lib/site.py"; do
    age_path_days_ago "$file" 15
  done
}

make_worktree safety "$SAFETY_WT"
make_worktree c14-kept "$C14_WT"
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"
export DISK_MAGICIAN_STATE_DIR="$STATE"
LEASE_PATH="$(lease_path_for "$C14_WT")"
mkdir -p "${LEASE_PATH%/*}"
LEASE_START="$( _lease_ps_lstart_epoch $$ )"
LEASE_COMM="$( _lease_full_comm $$ )"
printf '{"path":"%s","owner":{"pid":%d,"start_epoch":%s,"comm":"%s"},"created_epoch":%d,"ttl_hours":24,"released_at":null}\n' \
  "$C14_WT" "$$" "$LEASE_START" "$LEASE_COMM" "$(date +%s)" > "$LEASE_PATH"
printf '{"never_delete":[{"path":"%s/.venv","reason":"fixture protection"},{"path":"%s/.venv.bak.20260101","reason":"fixture protection"}]}' \
  "$SAFETY_WT" "$SAFETY_WT" > "$SAFETY_FILE"

set +e
OUT="$(env -i HOME="$HOME_FIX" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  DISK_MAGICIAN_STATE_DIR="$STATE" \
  DISK_MAGICIAN_LOAD5_OVERRIDE="0.1000" \
  DISK_MAGICIAN_SAFETY_FILE="$SAFETY_FILE" \
  bash "$REPO_ROOT/scripts/cleanup_worktree_venvs.sh" --roots "$ROOTS" --min-age 14 --purge-bak-days 14 --dry-run 2>&1)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]]; then
  echo "FAIL: dry-run exited $RC"
  printf '%s\n' "$OUT"
  exit 1
fi

FAIL=0
if grep -qF "would strip $SAFETY_WT/.venv" <<< "$OUT"; then
  echo "FAIL: safety-protected venv was reported as removable"
  FAIL=1
fi
grep -qF "SAFETY-SKIP $SAFETY_WT/.venv (never_delete:" <<< "$OUT" || {
  echo "FAIL: safety-protected venv did not report its safety reason"
  FAIL=1
}
if grep -qF "would purge $SAFETY_WT/.venv.bak.20260101" <<< "$OUT"; then
  echo "FAIL: safety-protected venv backup was reported as removable"
  FAIL=1
fi
if grep -qF "would strip $C14_WT/.venv" <<< "$OUT"; then
  echo "FAIL: C14-kept venv was reported as removable"
  FAIL=1
fi
grep -qF "Preserved (C14 kept:live-owner) $C14_WT/.venv" <<< "$OUT" || {
  echo "FAIL: C14-kept venv did not report its C14 reason"
  FAIL=1
}
if grep -qF "would purge $C14_WT/.venv.bak.20260101" <<< "$OUT"; then
  echo "FAIL: C14-kept venv backup was reported as removable"
  FAIL=1
fi
grep -qF "Preserved (C14 kept:live-owner) $C14_WT/.venv.bak.20260101" <<< "$OUT" || {
  echo "FAIL: C14-kept venv backup did not report its C14 reason"
  FAIL=1
}
[[ -d "$SAFETY_WT/.venv" && -d "$SAFETY_WT/.venv.bak.20260101" &&
   -d "$C14_WT/.venv" && -d "$C14_WT/.venv.bak.20260101" ]] || {
  echo "FAIL: a dry-run removed a fixture venv"
  FAIL=1
}
if [[ "$FAIL" -ne 0 ]]; then
  printf '%s\n' "$OUT"
  exit 1
fi
echo "PASS: dry-run applies safety and C14 gates; protected candidates remain"
