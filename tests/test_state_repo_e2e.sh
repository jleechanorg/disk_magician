#!/usr/bin/env bash
# test_state_repo_e2e.sh — sandbox E2E proof of design-doc Exit Criteria 1-3
# (roadmap/2026-07-21-generic-split-state-repo-design.md).
#
# Default (CI): DM_E2E_SKIP_INSTALL=1-equivalent behavior — no network, no
# uv, no gh. Set DM_E2E_BRANCH=<pushed-branch> and unset DM_E2E_SKIP_INSTALL
# to exercise the real `uv tool install git+...@branch` path (criterion 1).
# Set DM_E2E_REAL_GH=1 (in addition) to let a real `gh repo create` run
# against github.com; default is a stubbed gh so CI stays hermetic.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT=$(mktemp -d -t state_repo_e2e.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
gib=$((1024*1024))

DM_E2E_SKIP_INSTALL="${DM_E2E_SKIP_INSTALL:-1}"
DM_E2E_REAL_GH="${DM_E2E_REAL_GH:-0}"
DM_E2E_BRANCH="${DM_E2E_BRANCH:-}"

SANDBOX_HOME="$TMP_ROOT/home"
mkdir -p "$SANDBOX_HOME"
FAKE_HOST="sandbox-$(date +%s)-$$"

# ---- Criterion 1: fresh-user E2E -------------------------------------
echo "=== Criterion 1: fresh-user E2E ==="
if [[ "$DM_E2E_SKIP_INSTALL" == "1" ]]; then
  echo "  SKIP (loud): DM_E2E_SKIP_INSTALL=1 — set DM_E2E_BRANCH=<branch> and"
  echo "  DM_E2E_SKIP_INSTALL=0 to run the real 'uv tool install git+...' leg."
  DM_BIN="$REPO_ROOT/disk_magician.sh"
else
  [[ -n "$DM_E2E_BRANCH" ]] || { bad "DM_E2E_BRANCH set" "required when DM_E2E_SKIP_INSTALL=0"; echo "=== Result: $PASS pass, $FAIL fail ==="; exit 1; }
  command -v uv >/dev/null 2>&1 || { bad "uv on PATH" "uv not found — cannot run real install leg"; echo "=== Result: $PASS pass, $FAIL fail ==="; exit 1; }
  REMOTE_URL="$(git -C "$REPO_ROOT" remote get-url origin)"
  UV_TOOL_DIR="$TMP_ROOT/uv-tools"
  if UV_TOOL_DIR="$UV_TOOL_DIR" uv tool install --force \
       "git+${REMOTE_URL}@${DM_E2E_BRANCH}" >"$TMP_ROOT/uv-install.log" 2>&1; then
    ok "uv tool install git+<repo>@<branch> succeeds"
  else
    bad "uv tool install git+<repo>@<branch> succeeds" "$(cat "$TMP_ROOT/uv-install.log")"
  fi
  DM_BIN=$(UV_TOOL_DIR="$UV_TOOL_DIR" command -v disk-magician || true)
  [[ -n "$DM_BIN" ]] && ok "installed disk-magician entrypoint found" \
    || { bad "installed entrypoint found" "not on PATH after install"; DM_BIN="$REPO_ROOT/disk_magician.sh"; }
fi

FAKE_BIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
GH_LOG="$TMP_ROOT/gh.log"
# REAL_GH_ENV: extra env -i args, empty by default. DM_E2E_REAL_GH=1 needs
# real `gh` reachable (its dir added to PATH — the stock-tools PATH below
# won't have it, e.g. Homebrew's /opt/homebrew/bin) and its real credential
# store located (GH_CONFIG_DIR) — both are stripped by the env -i sandbox
# that intentionally isolates the rest of this run from the real $HOME.
# Deviation from the plan's literal script (documented, not silently
# patched): without this, DM_E2E_REAL_GH=1 always falls into
# state_repo.sh's "no gh auth" branch and never actually creates a repo
# (confirmed via manual run + `gh api repos/.../disk-magician-state-...`
# returning 404 before this fix).
REAL_GH_PATH_PREFIX=""
REAL_GH_ENV=()
if [[ "$DM_E2E_REAL_GH" == "1" ]]; then
  REAL_GH_BIN="$(command -v gh || true)"
  [[ -n "$REAL_GH_BIN" ]] || { bad "real gh on PATH" "gh not found — required when DM_E2E_REAL_GH=1"; echo "=== Result: $PASS pass, $FAIL fail ==="; exit 1; }
  REAL_GH_PATH_PREFIX="$(dirname "$REAL_GH_BIN"):"
  REAL_GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh}"
  REAL_GH_ENV=(GH_CONFIG_DIR="$REAL_GH_CONFIG_DIR")
else
  cat > "$FAKE_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GH_LOG"
case "\$1" in
  auth) exit 0 ;;
  repo) exit 0 ;;
  api) echo '{"login":"sandbox-user"}'; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$FAKE_BIN/gh"
fi

STATE_DIR="$SANDBOX_HOME/.local/state/disk-magician"
INIT_OUT=$(env -i HOME="$SANDBOX_HOME" PATH="${REAL_GH_PATH_PREFIX}${FAKE_BIN}:/usr/bin:/bin" \
  "${REAL_GH_ENV[@]+"${REAL_GH_ENV[@]}"}" \
  DISK_MAGICIAN_ASSUME_YES=1 "$REPO_ROOT/scripts/state_repo.sh" init 2>&1)
[[ -d "$STATE_DIR/.git" ]] && ok "state init creates a git state repo" \
  || bad "state init creates a git state repo" "$INIT_OUT"
if [[ "$DM_E2E_REAL_GH" != "1" ]]; then
  grep -q "repo create" "$GH_LOG" 2>/dev/null && ok "gh repo-create offer invoked (stub)" \
    || bad "gh repo-create offer invoked" "$(cat "$GH_LOG" 2>/dev/null || echo missing)"
else
  # state_repo.sh derives the repo name from the REAL machine hostname (via
  # its own `hostname -s` call, unaffected by our HOME sandboxing) — NOT
  # from $FAKE_HOST (that var only feeds the ledger fixture's "hostname"
  # JSON field below). Compute the same name here so verification/teardown
  # target the repo that was actually created, not a name that was never
  # used (confirmed bug in an earlier draft of this harness: the printed
  # verify/delete commands referenced $FAKE_HOST and always 404'd).
  REAL_HOST="$(hostname -s 2>/dev/null || echo unknown)"
  REAL_STATE_REPO="disk-magician-state-${REAL_HOST}"
  REAL_GH_LOGIN=$(env -i HOME="$SANDBOX_HOME" "${REAL_GH_ENV[@]+"${REAL_GH_ENV[@]}"}" \
    PATH="${REAL_GH_PATH_PREFIX}/usr/bin:/bin" gh api user --jq .login 2>/dev/null || true)
  if [[ -n "$REAL_GH_LOGIN" ]] && env -i HOME="$SANDBOX_HOME" "${REAL_GH_ENV[@]+"${REAL_GH_ENV[@]}"}" \
       PATH="${REAL_GH_PATH_PREFIX}/usr/bin:/bin" \
       gh api "repos/${REAL_GH_LOGIN}/${REAL_STATE_REPO}" --jq .full_name >/dev/null 2>&1; then
    ok "real throwaway repo exists (verified via gh api, not tool output)"
  else
    bad "real throwaway repo exists (verified via gh api)" \
      "repos/${REAL_GH_LOGIN:-<unknown-login>}/${REAL_STATE_REPO} not found — gh repo create likely failed; see INIT_OUT: $INIT_OUT"
  fi
fi

# ---- Criterion 2 + 3: ledger contract + diff naming growth ------------
# PR-2 (snapshot -> ledger write) is not merged yet; write_fixture_ledger()
# is the documented seam — see roadmap/plans/2026-07-21-state-repo-pr3-plan.md
# "Ledger contract this PR assumes" for the swap-to-real-snapshot plan.
write_fixture_ledger() {
  local disk_used_kb="$1" residual_kb="$2" buckets_json="$3"
  mkdir -p "$STATE_DIR/ledger"
  printf '{"schema_version":1,"captured_at":"2026-07-21T00:00:00Z",' > "$STATE_DIR/ledger/topdown-5g.json"
  printf '"hostname":"%s","disk_used_kb":%s,"residual_kb":%s,' "$FAKE_HOST" "$disk_used_kb" "$residual_kb" >> "$STATE_DIR/ledger/topdown-5g.json"
  printf '"residual_label":"protected_or_apfs_allocation_not_attributable_by_this_session",' >> "$STATE_DIR/ledger/topdown-5g.json"
  printf '"buckets":%s}' "$buckets_json" >> "$STATE_DIR/ledger/topdown-5g.json"
  git -C "$STATE_DIR" add ledger/topdown-5g.json
  git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost \
    commit -q -m "$4"
}

echo "=== Criterion 2: ledger contract (exact reconciliation, no >=5GiB opaque node) ==="
BASE_BUCKETS='[{"path":"/Users/sandbox/Library/Caches","measured_kb":'$((2*gib))'},{"path":"/Users/sandbox/projects","measured_kb":'$((2*gib))'}]'
write_fixture_ledger "$((4*gib))" 0 "$BASE_BUCKETS" "snapshot: baseline"
if VALID_OUT=$(python3 "$REPO_ROOT/scripts/history_diff.py" \
     --validate "$STATE_DIR/ledger/topdown-5g.json" 2>&1); then
  ok "committed ledger reconciles exactly with zero unexplained >=5GiB nodes"
else
  bad "ledger reconciles / no opaque nodes" "$VALID_OUT"
fi

echo "=== Criterion 3: diff names injected growth as the top line, residual last ==="
FIXTURE_DIR="$SANDBOX_HOME/fixture_growth"
mkdir -p "$(dirname "$FIXTURE_DIR")"
FIXTURE_FILE="$FIXTURE_DIR.img"
# Sparse file: seek to (6 GiB - 1 byte) and write one byte, so the fixture
# names a real >=6 GiB path without actually consuming 6 GiB of disk.
dd if=/dev/zero of="$FIXTURE_FILE" bs=1 count=1 seek=$((6*1024*1024*1024 - 1)) >/dev/null 2>&1
if [[ -f "$FIXTURE_FILE" ]]; then
  ok "sparse fixture file created"
else
  bad "sparse fixture file created" "dd failed"
fi
# kind:"file" is required here — the fixture is a single indivisible file
# >=5 GiB, which is exempt from the "dir" ceiling (see "Ledger contract this
# PR assumes" / TestValidateLedger.test_oversize_dir_rejected_but_oversize_file_allowed).
GROWN_BUCKETS='[{"path":"/Users/sandbox/Library/Caches","measured_kb":'$((2*gib))'},{"path":"/Users/sandbox/projects","measured_kb":'$((2*gib))'},{"path":"'"$FIXTURE_FILE"'","measured_kb":'$((6*gib))',"kind":"file"}]'
write_fixture_ledger "$((10*gib))" 0 "$GROWN_BUCKETS" "snapshot: injected >=6GiB growth"

DIFF_OUT=$(env -i HOME="$SANDBOX_HOME" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_REPO="$STATE_DIR" python3 "$REPO_ROOT/scripts/history_diff.py" 2>&1)
FIRST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[0])" "$DIFF_OUT")
LAST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[-1])" "$DIFF_OUT")
[[ "$FIRST_LINE" == *"$FIXTURE_FILE"* && "$FIRST_LINE" == "+6.00 GiB"* ]] \
  && ok "history diff names the injected bucket with its delta as the top line" \
  || bad "top line names injected growth" "$FIRST_LINE"
[[ "$LAST_LINE" == "residual delta: +0.00 GiB" ]] \
  && ok "residual delta is printed last" \
  || bad "residual delta last" "$LAST_LINE"

# ---- Teardown -----------------------------------------------------------
rm -f "$FIXTURE_FILE"
if [[ "$DM_E2E_REAL_GH" == "1" ]]; then
  # Attempt real teardown, then FAIL LOUDLY if the repo still exists (e.g. the
  # token lacks the delete_repo scope) so a real-gh run never silently litters
  # the account. cursor-agent adversarial finding 2026-07-21: the old teardown
  # only printed a manual command and could not surface a scope failure.
  target="${REAL_GH_LOGIN:-}/${REAL_STATE_REPO:-}"
  if [[ "$target" != "/" ]]; then
    gh repo delete "$target" --yes >/dev/null 2>&1 || true
    if gh repo view "$target" >/dev/null 2>&1; then
      echo "  !! WARNING: throwaway repo NOT deleted (missing delete_repo scope?):" >&2
      echo "     https://github.com/$target" >&2
      echo "     Delete manually: gh auth refresh -h github.com -s delete_repo && gh repo delete $target --yes" >&2
    else
      echo "  teardown: deleted throwaway repo $target"
    fi
  fi
fi

echo; echo "=== Result: $PASS pass, $FAIL fail ==="
[[ "$FAIL" -eq 0 ]]
