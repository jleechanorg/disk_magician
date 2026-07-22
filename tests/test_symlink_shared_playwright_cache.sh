#!/usr/bin/env bash
# test_symlink_shared_playwright_cache.sh — Behavioral tests for
# symlink-shared-playwright-cache.sh
#
# Regression fixture for a live bug found 2026-07-22 (lane2-reclaim,
# mission jleechan-4dtg): the canonical-cache candidate search used
# `find ... -type d | sort -V | tail -1` with no filter, so when the host's
# ms-playwright-go dir contained a stray "<version>.bak.<timestamp>" backup
# directory (left by a prior real --clean run) alongside a dangling
# "<version>" symlink, sort -V picked the .bak. dir as canonical. Every
# session's dry-run then hunted for a live cache literally named
# "<version>.bak.<timestamp>" and matched other stray backup-of-a-backup
# dirs inside already-archived (.bak.-suffixed) AO session directories,
# reporting them as if they were live per-session caches.
#
# Run: bash tests/test_symlink_shared_playwright_cache.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/symlink-shared-playwright-cache.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 2
fi

TMP_DIR=$(mktemp -d -t playwright_dedup_test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR"
CANONICAL_BASE="$TMP_DIR/Library/Caches/ms-playwright-go"
SESSIONS_DIR="$TMP_DIR/.ao-sessions"

PASS=0
FAIL=0
expect() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (did not find: $needle)"
    FAIL=$((FAIL + 1))
  fi
}
refute() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS  $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $desc (unexpectedly found: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== symlink-shared-playwright-cache.sh test ==="

echo "Test 1: a stray .bak. dir at the host canonical location is never chosen as canonical"
mkdir -p "$CANONICAL_BASE/1.57.0.bak.20260719-041505"
# real "1.57.0" is a dangling symlink, same shape as the live bug.
ln -s "../../../../../Library/Caches/ms-playwright-go/1.57.0" "$CANONICAL_BASE/1.57.0"
mkdir -p "$SESSIONS_DIR/ao-1111/Library/Caches/ms-playwright-go/1.57.0"
echo fake-browser-binary > "$SESSIONS_DIR/ao-1111/Library/Caches/ms-playwright-go/1.57.0/marker"
OUT=$("$SCRIPT" 2>&1)
refute "does not select the .bak. dir as canonical" "Canonical cache version in use: 1.57.0.bak" "$OUT"
expect "falls back to the real live session cache" "Canonical cache version in use: 1.57.0" "$OUT"
expect "targets the real per-session cache" "would rename $SESSIONS_DIR/ao-1111/Library/Caches/ms-playwright-go/1.57.0 " "$OUT"
rm -rf "$CANONICAL_BASE" "$SESSIONS_DIR"

echo "Test 2: already-archived (.bak.-suffixed) session dirs are skipped entirely"
mkdir -p "$CANONICAL_BASE/1.57.0"
mkdir -p "$SESSIONS_DIR/ao-2222.bak.20260722-042305/Library/Caches/ms-playwright-go/1.57.0.bak.20260719-041505"
OUT=$("$SCRIPT" 2>&1)
refute "does not touch the archived session's stray backup cache" "1.57.0.bak.20260719-041505" "$OUT"
expect "reports the skip count" "Backup session dirs skipped: 1" "$OUT"
rm -rf "$CANONICAL_BASE" "$SESSIONS_DIR"

echo "Test 3: a clean, real per-session cache still gets symlinked normally"
mkdir -p "$CANONICAL_BASE/1.57.0"
mkdir -p "$SESSIONS_DIR/ao-3333/Library/Caches/ms-playwright-go/1.57.0"
echo fake-browser-binary > "$SESSIONS_DIR/ao-3333/Library/Caches/ms-playwright-go/1.57.0/marker"
OUT=$("$SCRIPT" --clean 2>&1)
expect "linked the real session cache" "linked:" "$OUT"
[[ -L "$SESSIONS_DIR/ao-3333/Library/Caches/ms-playwright-go/1.57.0" ]] && \
  echo "  PASS  symlink actually created" && PASS=$((PASS + 1)) || \
  { echo "  FAIL  symlink not created"; FAIL=$((FAIL + 1)); }
rm -rf "$CANONICAL_BASE" "$SESSIONS_DIR"

echo
echo "=== Result: $PASS pass, $FAIL fail ==="
[[ $FAIL -eq 0 ]]
