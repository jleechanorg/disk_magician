#!/usr/bin/env bash
# tests/test_disk_report_html.sh — Test suite for `diskm report --html`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DISKM_SH="$REPO_ROOT/disk_magician.sh"

TMP_BASE="${TMPDIR:-/tmp}"
TMP_TEST_DIR="$(mktemp -d "${TMP_BASE%/}/test_disk_report_html.XXXXXX")"
cleanup() {
  if [[ -n "${TMP_TEST_DIR:-}" && "$TMP_TEST_DIR" != "/" && -d "$TMP_TEST_DIR" ]]; then
    rm -rf "${TMP_TEST_DIR:?}"
  fi
}
trap cleanup EXIT

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $msg"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $msg (expected '$expected', got '$actual')" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "PASS: $msg"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $msg (missing '$needle')" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: $msg (unexpectedly found '$needle')" >&2
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $msg"
    PASS=$((PASS + 1))
  fi
}

# Create synthetic snapshot & frontier fixtures
SNAP_FILE="$TMP_TEST_DIR/disk_snapshot.json"
FRONTIER_FILE="$TMP_TEST_DIR/frontier_last.json"
OUT_HTML="$TMP_TEST_DIR/report_out.html"

cat <<'JSON' > "$SNAP_FILE"
{
  "schema_version": 2,
  "timestamp": "2026-10-19T19:30:39Z",
  "hostname": "test-macbook-pro",
  "disk_total_gb": 926,
  "disk_used_gb": 832,
  "disk_free_gb": 50,
  "disk_pct": 89,
  "swap_total_gb": 16.0,
  "swap_used_gb": 14.5,
  "vm_volume_used_gb": 16.0,
  "snapshot_coverage_pct": 74.2,
  "coverage_effective_pct": 81.5,
  "residual_kb": 125829120,
  "residual_gb": 120.0,
  "residual_delta_gb": 12.4,
  "local_snapshots_count": 6,
  "local_snapshot_names": [
    "com.apple.TimeMachine.2026-10-19-110042.local",
    "com.apple.os.update-MSUPrepareUpdate"
  ],
  "directory_deltas_gb": {
    "colima": 4.2,
    "worktrees_dot": 11.5,
    "library_caches": -1.8
  },
  "directories": {
    "claude_root": 17405864,
    "claude_projects": 15699204,
    "codex_root": 76560184,
    "codex_sessions": 50901148,
    "gemini_root": 4309672,
    "colima": 21073284,
    "library_caches": 5253508,
    "library_developer": 4893948,
    "cache_dir": 2244844,
    "local_dir": 9762988,
    "projects": 63656784,
    "projects_other": 13268492,
    "projects_reference": 13575016,
    "repos": 4565924,
    "worktrees_dot": null,
    "tmp_private": null,
    "private_var": null,
    "documents": 15778504,
    "documents_codex": 14453516,
    "aside": 1247848,
    "library_logs": 884840,
    "library_pnpm": 1133876,
    "llm_inspector": 91348,
    "wf_checkouts": 24728012
  },
  "carried_keys": [
    {"key": "worktrees_dot", "kb": 94399344, "age_hours": 0.7},
    {"key": "tmp_private", "kb": 78745204, "age_hours": 0.7},
    {"key": "private_var", "kb": 57827880, "age_hours": 2.0}
  ]
}
JSON

cat <<'JSON' > "$FRONTIER_FILE"
{
  "schema_version": 2,
  "mode": "partial",
  "captured_at": "2026-10-19T10:53:29Z",
  "measured": {
    "/System/Volumes/Data/Users/jleechan/.aside": 1246388,
    "/System/Volumes/Data/Users/jleechan/.colima": 26558884
  }
}
JSON

# 1. Test --help
HELP_OUT="$("$DISKM_SH" report --help)"
assert_contains "$HELP_OUT" "diskm report" "help output mentions diskm report"
assert_contains "$HELP_OUT" "--snapshot" "help output mentions --snapshot"

# 2. Test CLI dispatch & HTML generation
STDOUT_TEXT="$("$DISKM_SH" report --html --snapshot "$SNAP_FILE" --frontier "$FRONTIER_FILE" --output "$OUT_HTML")"
assert_contains "$STDOUT_TEXT" "$OUT_HTML" "stdout prints full absolute path to generated HTML"
assert_contains "$STDOUT_TEXT" "Free right now: 50.0 GiB / 926 GiB" "stdout prints free right now summary"
[[ -s "$OUT_HTML" ]] || { echo "FAIL: HTML output file was not created at $OUT_HTML" >&2; exit 1; }
echo "PASS: HTML file created and non-empty"
PASS=$((PASS + 1))

# 3. Test --json mode
JSON_OUT="$("$DISKM_SH" report --json --snapshot "$SNAP_FILE" --frontier "$FRONTIER_FILE" --output "$OUT_HTML")"
JSON_STATUS="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["status"])' <<<"$JSON_OUT")"
assert_eq "ok" "$JSON_STATUS" "JSON output status is ok"
JSON_FREE="$(python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(int(d["disk_free_gb"]))' <<<"$JSON_OUT")"
assert_eq "50" "$JSON_FREE" "JSON output disk_free_gb is 50"

# 4. Test HTML content for 4 summary cards, Treemap, Canonical diskm commands, Never-Delete locks, and NO raw rm/npkill
HTML_BODY="$(cat "$OUT_HTML")"
assert_contains "$HTML_BODY" "1. Free right now" "HTML has Card 1: Free right now"
assert_contains "$HTML_BODY" "2. In safe-tier paths (upper bound)" "HTML has Card 2: safe-tier upper bound"
assert_contains "$HTML_BODY" "3. Needs review &amp; Protected" "HTML has Card 3: Needs review & Protected"
assert_contains "$HTML_BODY" "4. System &amp; Residual" "HTML has Card 4: System & Residual"

# Rows with no diskm command acting on their path must not reach the generated script
assert_contains "$HTML_BODY" "manual review (no diskm command reclaims this path)" "non-acting rows are labelled manual review"
# Generated-script comments strip control characters from snapshot-supplied names/paths
assert_contains "$HTML_BODY" 'replace(/[\u0000-\u001f\u007f]/g, " ")' "script comments sanitize control characters"
# Canonical diskm commands
for canonical_cmd in \
  "diskm cleanup-dev-caches --clean" \
  "diskm cleanup-tmp --clean" \
  "diskm cleanup-task-scratch --clean" \
  "diskm cleanup-pr-scratch --clean" \
  "diskm cleanup-colima --clean" \
  "diskm prune-aside-sessions --clean" \
  "diskm cleanup-antigravity-brain --clean" \
  "WORKTREE_APPROVED=1 diskm cleanup-worktrees --clean" \
  "WORKTREE_APPROVED=1 diskm cleanup-worktree-deps --clean" \
  "WORKTREE_APPROVED=1 diskm cleanup-worktree-venvs --clean" \
  "diskm cleanup-codex-documents --clean" \
  "diskm cleanup-apfs-snapshots --clean" \
  "diskm cleanup-dirs-cleaner --clean" \
  "diskm cleanup-code-sign-clones --clean" \
  "diskm cleanup-codex-db --clean"; do
  assert_contains "$HTML_BODY" "$canonical_cmd" "HTML includes canonical command: $canonical_cmd"
done

# Protected Never-Delete paths
assert_contains "$HTML_BODY" "~/.codex/sessions*" "HTML flags ~/.codex/sessions* as protected"
assert_contains "$HTML_BODY" "~/.codex/state*.sqlite" "HTML flags ~/.codex/state*.sqlite as protected"
assert_contains "$HTML_BODY" "~/.claude/projects" "HTML flags ~/.claude/projects as protected"
assert_contains "$HTML_BODY" "~/projects_reference" "HTML flags ~/projects_reference as protected"
assert_contains "$HTML_BODY" "PROTECTED — Never-Delete List" "HTML includes Never-Delete List lock explanation"

# UI controls
assert_contains "$HTML_BODY" "Select safe" "HTML includes Select safe button"
assert_contains "$HTML_BODY" "Toggle dry-run / --clean" "HTML includes Toggle dry-run / --clean button"
assert_contains "$HTML_BODY" "Copy diskm script" "HTML includes Copy diskm script button"

# Absence of forbidden raw destructive commands
assert_not_contains "$HTML_BODY" "npx npkill" "HTML does not recommend npx npkill"
assert_not_contains "$HTML_BODY" "rm -rf ~/.codex" "HTML does not contain rm -rf ~/.codex"
assert_not_contains "$HTML_BODY" "mv ~/.codex" "HTML does not contain mv ~/.codex"

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
