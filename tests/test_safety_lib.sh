#!/usr/bin/env bash
# test_safety_lib.sh — Coverage for the machine-local safety guidelines layer.
#
# Run: bash tests/test_safety_lib.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_ROOT=$(mktemp -d -t safety_lib.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

record_pass() {
  echo "  PASS  $1"
  PASS=$(( PASS + 1 ))
}

record_fail() {
  echo "  FAIL  $1"
  echo "        $2"
  FAIL=$(( FAIL + 1 ))
}

assert_rc() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected rc=$expected got rc=$actual"
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    record_pass "$name"
  else
    record_fail "$name" "expected output containing '$needle', got: $haystack"
  fi
}

# Sandbox: copy the lib next to a scratch repo root so safety_file_in_use
# resolves the sandbox safety.local.json, never the developer's real one.
SANDBOX="$TMP_ROOT/repo"
mkdir -p "$SANDBOX/scripts"
cp "$REPO_ROOT/scripts/safety_lib.sh" "$SANDBOX/scripts/"
cp "$REPO_ROOT/scripts/safety_check.sh" "$SANDBOX/scripts/"

cat > "$SANDBOX/safety.local.json" <<JSON
{
  "never_delete": ["$TMP_ROOT/never/sessions*"],
  "protected_live_paths": [
    {"path": "$TMP_ROOT/live/daemon-wd", "reason": "test daemon"}
  ],
  "needs_decision": [
    {"path": "$TMP_ROOT/decide/clone-a", "reason": "unpushed commits"}
  ],
  "min_stale_days": 21
}
JSON

# shellcheck source=../scripts/safety_lib.sh
source "$SANDBOX/scripts/safety_lib.sh"

echo "safety_file_in_use:"
resolved="$(safety_file_in_use)"
assert_contains "resolves sandbox safety.local.json" "$SANDBOX/safety.local.json" "$resolved"

echo "safety_is_protected:"
rc=0; out="$(safety_is_protected "$TMP_ROOT/never/sessions-abc")" || rc=$?
assert_rc "never_delete glob match" 0 "$rc"
assert_contains "never_delete reason names section" "never_delete" "$out"

rc=0; out="$(safety_is_protected "$TMP_ROOT/live/daemon-wd/logs/today.log")" || rc=$?
assert_rc "descendant of protected path is blocked" 0 "$rc"
assert_contains "descendant reason carries note" "test daemon" "$out"

rc=0; out="$(safety_is_protected "$TMP_ROOT/live")" || rc=$?
assert_rc "ancestor of protected path is blocked" 0 "$rc"
assert_contains "ancestor verdict marked descendant" "descendant" "$out"

rc=0; out="$(safety_is_protected "$TMP_ROOT/decide/clone-a")" || rc=$?
assert_rc "needs_decision path is blocked" 0 "$rc"

rc=0; safety_is_protected "$TMP_ROOT/decide/clone-a-sibling" >/dev/null || rc=$?
assert_rc "sibling with shared name prefix is NOT blocked" 1 "$rc"

rc=0; safety_is_protected "$TMP_ROOT/unrelated/dir" >/dev/null || rc=$?
assert_rc "unrelated path is not protected" 1 "$rc"

echo "firmlink alias:"
# Only meaningful for paths under /Users; simulate via the canonical form.
cat > "$SANDBOX/safety.local.json" <<'JSON'
{"never_delete": ["/Users/nobody/protected-tree"]}
JSON
rc=0; safety_is_protected "/System/Volumes/Data/Users/nobody/protected-tree/sub" >/dev/null || rc=$?
assert_rc "Data-volume alias of protected path is blocked" 0 "$rc"

echo "safety_min_stale_days:"
cat > "$SANDBOX/safety.local.json" <<'JSON'
{"min_stale_days": 21}
JSON
days="$(safety_min_stale_days)"
assert_rc "min_stale_days honors config" 21 "$days"

cat > "$SANDBOX/safety.local.json" <<'JSON'
{}
JSON
days="$(safety_min_stale_days)"
assert_rc "min_stale_days defaults to 14" 14 "$days"

echo "fail-closed on unreadable file:"
echo '{not json' > "$SANDBOX/safety.local.json"
rc=0; safety_is_protected "$TMP_ROOT/unrelated/dir" >/dev/null 2>&1 || rc=$?
assert_rc "malformed JSON returns rc 2 (not silently safe)" 2 "$rc"
rc=0; out="$(safety_gate "$TMP_ROOT/unrelated/dir" 2>/dev/null)" || rc=$?
assert_rc "safety_gate fails closed on malformed JSON" 1 "$rc"
assert_contains "safety_gate explains fail-closed" "failing closed" "$out"

echo "safety_gate happy paths:"
cat > "$SANDBOX/safety.local.json" <<JSON
{"never_delete": ["$TMP_ROOT/never/sessions*"]}
JSON
rc=0; safety_gate "$TMP_ROOT/unrelated/dir" >/dev/null || rc=$?
assert_rc "safety_gate allows unprotected path" 0 "$rc"
rc=0; out="$(safety_gate "$TMP_ROOT/never/sessions-abc")" || rc=$?
assert_rc "safety_gate blocks protected path" 1 "$rc"

echo "safety_check.sh CLI:"
rc=0; out="$(bash "$SANDBOX/scripts/safety_check.sh" "$TMP_ROOT/never/sessions-abc" "$TMP_ROOT/unrelated" 2>&1)" || rc=$?
assert_rc "CLI exits 1 when any path protected" 1 "$rc"
assert_contains "CLI prints PROTECTED verdict" "PROTECTED" "$out"
assert_contains "CLI prints OK verdict" "OK " "$out"
rc=0; bash "$SANDBOX/scripts/safety_check.sh" "$TMP_ROOT/unrelated" >/dev/null 2>&1 || rc=$?
assert_rc "CLI exits 0 when all paths OK" 0 "$rc"
rc=0; bash "$SANDBOX/scripts/safety_check.sh" >/dev/null 2>&1 || rc=$?
assert_rc "CLI exits 2 on missing args" 2 "$rc"

echo "findings_wiki discovery:"
mkdir -p "$SANDBOX/findings_wiki"
cp "$REPO_ROOT/scripts/findings_lint.sh" "$SANDBOX/scripts/" 2>/dev/null || true
cat > "$SANDBOX/findings_wiki/README.md" <<'MD'
# readme
MD
cat > "$SANDBOX/findings_wiki/TEMPLATE.md" <<'MD'
template
MD
rc=0; findings_wiki_docs >/dev/null || rc=$?
assert_rc "no finding docs -> rc 1" 1 "$rc"
rc=0; out="$(bash "$SANDBOX/scripts/findings_lint.sh" --upstream 2>&1)" || rc=$?
assert_rc "upstream purity passes with only README+TEMPLATE" 0 "$rc"

cat > "$SANDBOX/findings_wiki/dev-cache-bazel.md" <<'MD'
---
title: bazel cache hotspot
hostname: testhost
date: 2026-07-15
status: active
paths:
  - ~/Snapchat/Dev/.cache/bazel
safety_rule: none
---
## What
test finding
MD
rc=0; out="$(findings_wiki_docs)" || rc=$?
assert_rc "finding doc listed" 0 "$rc"
assert_contains "doc path in listing" "dev-cache-bazel.md" "$out"
if [[ "$out" == *"README.md"* || "$out" == *"TEMPLATE.md"* ]]; then
  record_fail "README/TEMPLATE excluded from listing" "listing contained scaffold files: $out"
else
  record_pass "README/TEMPLATE excluded from listing"
fi
rc=0; out="$(bash "$SANDBOX/scripts/findings_lint.sh" 2>&1)" || rc=$?
assert_rc "lint validates well-formed doc" 0 "$rc"
rc=0; bash "$SANDBOX/scripts/findings_lint.sh" --upstream >/dev/null 2>&1 || rc=$?
assert_rc "upstream purity fails when finding docs exist" 1 "$rc"
cat > "$SANDBOX/findings_wiki/bad-doc.md" <<'MD'
---
title: missing fields
status: wat
---
MD
rc=0; bash "$SANDBOX/scripts/findings_lint.sh" >/dev/null 2>&1 || rc=$?
assert_rc "lint rejects malformed frontmatter" 1 "$rc"

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
