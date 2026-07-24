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

# run_real_snapshot() — real frontier scan → ledger/topdown-5g.json, adapted to the
# history_diff.py ledger contract (see task-1-report.md §6 for the schema mismatch).
# Args: $1 = sandbox scan root, $2 = commit message, [$3 = disk_used_kb_override]
run_real_snapshot() {
  local scan_root="$1" msg="$2" used_override="${3:-}"
  local frontier="$TMP_ROOT/frontier.json"
  local out_ledger="$STATE_DIR/ledger/topdown-5g.json"
  mkdir -p "$STATE_DIR/ledger"

  local scan_args=(
    --root "$scan_root"
    --output "$frontier"
    --granularity-gib 5
    --no-sibling-volumes
    --no-purgeable
    --workers 2
    --max-depth 6
    --wall-clock-cap 60
    --timeout-tiers 2,5
  )
  [[ -n "$used_override" ]] && scan_args+=(--disk-used-kb-override "$used_override")

  python3 "$REPO_ROOT/scripts/disk_frontier_scan.py" "${scan_args[@]}" >/dev/null 2>&1 \
    || { bad "frontier scan" "disk_frontier_scan.py exit $?"; return 1; }

  # Stage 2: adapt the frontier report into the ledger contract shape
  # (history_diff.py validate_ledger requires a flat "buckets" list with
  #  sum(buckets)+residual==disk_used_kb). Do the adaptation in Python here so the
  #  test stays hermetic and doesn't require a production render_topdown_ledger.py
  #  change (flagged as a pre-existing prod bug in §6).
  python3 - "$frontier" "$out_ledger" <<'PY'
import json, sys
frontier_path, out_path = sys.argv[1], sys.argv[2]
with open(frontier_path) as f:
    rep = json.load(f)
buckets = []
for b in (rep.get("granularity_buckets") or []):
    buckets.append({"path": b["path"], "measured_kb": int(b["measured_kb"]), "kind": "dir"})
for b in (rep.get("oversize_indivisible_files") or []):
    buckets.append({"path": b["path"], "measured_kb": int(b["measured_kb"]), "kind": "file"})
disk_used_kb = int(rep.get("disk_used_kb") or 0)
sum_buckets = sum(b["measured_kb"] for b in buckets)
# Reconcile by construction: residual absorbs granularity_tail + purgeable + any drift.
residual_kb = disk_used_kb - sum_buckets
ledger = {
    "schema_version": 1,
    "captured_at": rep.get("captured_at"),
    "hostname": rep.get("hostname"),
    "disk_used_kb": disk_used_kb,
    "residual_kb": residual_kb,
    "residual_label": "protected_or_apfs_allocation_not_attributable_by_this_session",
    "buckets": buckets,
}
with open(out_path, "w") as f:
    json.dump(ledger, f, indent=2)
    f.write("\n")
PY

  git -C "$STATE_DIR" add ledger/topdown-5g.json
  git -C "$STATE_DIR" -c user.name=disk-magician -c user.email=disk-magician@localhost \
    commit -q -m "$msg"
}

# Bounded scan root — contains ONLY the fixture dirs the test asserts on, not the
# whole $SANDBOX_HOME (which includes the state repo itself and would be walked
# exhaustively by the frontier scanner).
SCAN_ROOT="$TMP_ROOT/scan_root"
mkdir -p "$SCAN_ROOT/Library/Caches" "$SCAN_ROOT/projects"
dd if=/dev/zero of="$SCAN_ROOT/Library/Caches/blob" bs=1M count=2 >/dev/null 2>&1
dd if=/dev/zero of="$SCAN_ROOT/projects/blob" bs=1M count=2 >/dev/null 2>&1

echo "=== Criterion 2: ledger contract (exact reconciliation, no >=5GiB opaque node) ==="
run_real_snapshot "$SCAN_ROOT" "snapshot: baseline" "$((4*gib))" \
  || bad "baseline snapshot commit" "run_real_snapshot failed (see prior FAIL line)"
if VALID_OUT=$(python3 "$REPO_ROOT/scripts/history_diff.py" \
     --validate "$STATE_DIR/ledger/topdown-5g.json" 2>&1); then
  ok "committed ledger reconciles exactly with zero unexplained >=5GiB nodes"
else
  bad "ledger reconciles / no opaque nodes" "$VALID_OUT"
fi

echo "=== Criterion 3: diff names injected growth as the top line, residual last ==="
# The fixture MUST live inside $SCAN_ROOT so the frontier scanner finds it, and
# it MUST be real-allocated (not sparse): the scanner measures st.st_blocks
# (actual allocated 512-byte blocks), NOT apparent size, so a sparse dd seek=
# fixture reports ~0 KiB. fallocate produces correct st_blocks on this ext4
# Cloud Build runner; fall back to a real zero write if fallocate is unavailable
# or fails (costs 6 GiB + I/O time but always works).
FIXTURE_FILE="$SCAN_ROOT/big_growth.img"
if fallocate -l 6G "$FIXTURE_FILE" 2>/dev/null; then
  ok "real 6 GiB fixture file allocated (fallocate)"
elif dd if=/dev/zero of="$FIXTURE_FILE" bs=1M count=6144 status=none >/dev/null 2>&1; then
  ok "real 6 GiB fixture file written (dd fallback)"
else
  bad "real 6 GiB fixture file created" "fallocate and dd both failed"
fi
# kind:"file" is required here — the fixture is a single indivisible file
# >=5 GiB, which is exempt from the "dir" ceiling (see "Ledger contract this
# PR assumes" / TestValidateLedger.test_oversize_dir_rejected_but_oversize_file_allowed).
# GROWN_BUCKETS (the fabricated buckets JSON) is now unused: the growth ledger
# is produced by run_real_snapshot over $SCAN_ROOT, which now contains this
# 6 GiB fixture + the 2 MiB blobs. Removed here rather than left dead.
#
# Deviation from the task-4 brief's literal `$((10*gib))` override (documented,
# not silent): the brief's idealized math assumed baseline buckets=0 and a
# fixture measuring exactly 6 GiB. The real scanner surfaces the 2 MiB small
# blobs as granularity_buckets in BOTH scans (they cancel in the delta), and
# the fixture's st_blocks-based measured_kb is 6291460 KiB — 4 KiB over the
# ideal 6 GiB (6291456 KiB) due to ext4 block-allocation overhead. With a flat
# 10 GiB override the residual delta = 6 GiB - 6291460 = -4 KiB, which
# history_diff.py formats as "-0.00 GiB" (sign is "-" for any delta < 0),
# failing the `== "+0.00 GiB"` assertion. To make the delta exactly 0
# regardless of filesystem block rounding, set growth disk_used_kb =
# baseline_used + fixture_measured_kb (the small-blob overhead cancels because
# it is identical in both scans). This keeps the growth disk_used_kb at ~10 GiB
# (10485764 KiB vs 10485760 KiB) and is robust across filesystems.
FIXTURE_MEASURED_KB=$(du -sk "$FIXTURE_FILE" 2>/dev/null | cut -f1)
FIXTURE_MEASURED_KB="${FIXTURE_MEASURED_KB:-0}"
GROWTH_USED_KB=$(( 4*gib + FIXTURE_MEASURED_KB ))
run_real_snapshot "$SCAN_ROOT" "snapshot: injected >=6GiB growth" "$GROWTH_USED_KB" \
  || bad "growth snapshot commit" "run_real_snapshot failed (see prior FAIL line)"

DIFF_OUT=$(env -i HOME="$SANDBOX_HOME" PATH="/usr/bin:/bin" \
  DISK_MAGICIAN_STATE_REPO="$STATE_DIR" python3 "$REPO_ROOT/scripts/history_diff.py" 2>&1)
FIRST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[0])" "$DIFF_OUT")
LAST_LINE=$(python3 -c "import sys; print(sys.argv[1].splitlines()[-1])" "$DIFF_OUT")
# Tolerate filesystem block-rounding of the sparse 6 GiB fixture: the real
# scanner reports +6.00 GiB on some filesystems and +6.01 GiB on others
# (e.g. macOS APFS du block allocation), so match ~6 GiB, not a byte-exact value.
[[ "$FIRST_LINE" == *"$FIXTURE_FILE"* && "$FIRST_LINE" == "+6.0"[0-9]" GiB"* ]] \
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
