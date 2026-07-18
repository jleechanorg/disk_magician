#!/usr/bin/env bash
# Default read-only disk diagnosis: run independent evidence lanes in parallel.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t disk_diagnostic.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

TOPDOWN_JSON="$WORK/topdown.json"
TOPDOWN_LOG="$WORK/topdown.log"
HISTORY_LOG="$WORK/history.log"
QUICK_LOG="$WORK/quick.log"
QUICK_AUDIT_LOG="$WORK/quick-audit.log"
WORKTREE_LOG="$WORK/worktree-hygiene.log"

budget="${DISK_MAGICIAN_TOPDOWN_BUDGET_SECONDS:-480}"
workers="${DISK_MAGICIAN_TOPDOWN_WORKERS:-8}"
max_nodes="${DISK_MAGICIAN_TOPDOWN_MAX_NODES:-}"
granularity="${DISK_MAGICIAN_GRANULARITY_GIB:-5}"
quick_budget="${DISK_MAGICIAN_QUICK_BUDGET_SECONDS:-120}"

frontier_args=(
  --granularity-gib "$granularity"
  --wall-clock-cap "$budget"
  --workers "$workers"
  --output "$TOPDOWN_JSON"
)
if [[ -n "$max_nodes" ]]; then
  frontier_args+=(--max-nodes "$max_nodes")
fi

python3 "$SCRIPT_DIR/disk_frontier_scan.py" \
  "${frontier_args[@]}" >"$TOPDOWN_LOG" 2>&1 &
topdown_pid=$!

"$SCRIPT_DIR/disk_history.sh" --days 7 --regressions >"$HISTORY_LOG" 2>&1 &
history_pid=$!

(
  "$SCRIPT_DIR/disk_audit.sh" --no-history --skip-directory-breakdown "$@" >"$QUICK_AUDIT_LOG" 2>&1 &
  audit_pid=$!
  hygiene_pid=""
  if [[ -x "$SCRIPT_DIR/worktree_hygiene.sh" ]]; then
    timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
    if [[ -n "$timeout_bin" ]]; then
      "$timeout_bin" "$quick_budget" "$SCRIPT_DIR/worktree_hygiene.sh" \
        --skip-push --skip-gh >"$WORKTREE_LOG" 2>&1 &
    else
      "$SCRIPT_DIR/worktree_hygiene.sh" --skip-push --skip-gh >"$WORKTREE_LOG" 2>&1 &
    fi
    hygiene_pid=$!
  fi

  wait "$audit_pid"; audit_rc=$?
  hygiene_rc=0
  if [[ -n "$hygiene_pid" ]]; then
    wait "$hygiene_pid"; hygiene_rc=$?
  fi

  cat "$QUICK_AUDIT_LOG"
  if [[ -n "$hygiene_pid" ]]; then
    echo
    echo "── Worktree hygiene preview (read-only; pushes and GitHub lookups disabled) ──"
    cat "$WORKTREE_LOG"
    if [[ "$hygiene_rc" -eq 124 ]]; then
      echo "Worktree preview reached its ${quick_budget}s budget; no changes were made."
    elif [[ "$hygiene_rc" -ne 0 ]]; then
      echo "Worktree preview failed (rc=$hygiene_rc); no changes were made."
    fi
  fi
  exit "$audit_rc"
) >"$QUICK_LOG" 2>&1 &
quick_pid=$!

wait "$topdown_pid"; topdown_rc=$?
wait "$history_pid"; history_rc=$?
wait "$quick_pid"; quick_rc=$?
render_rc=0

echo "=== Lane 1/3: top-down whole-disk accounting (directory/path buckets <=${granularity} GiB) ==="
if [[ "$topdown_rc" -eq 0 && -s "$TOPDOWN_JSON" ]]; then
  python3 - "$TOPDOWN_JSON" "$granularity" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1]))
threshold = float(sys.argv[2])

def gib(kb):
    return float(kb or 0) / (1024 * 1024)

print(
    f"Physical/APFS capacity: {gib(report.get('disk_total_kb')):.1f} GiB; "
    f"Data used: {gib(report.get('disk_used_kb')):.1f} GiB; "
    f"Data free: {gib(report.get('disk_free_kb')):.1f} GiB"
)
window = report.get("measurement_window") or {}
if window:
    interval = window.get("residual_interval_kb") or {}
    print(
        "Data measurement window: "
        f"{gib(window.get('disk_used_before_kb')):.1f} -> "
        f"{gib(window.get('disk_used_after_kb')):.1f} GiB used "
        f"(delta={gib(window.get('disk_used_delta_kb')):+.1f} GiB; "
        f"non_atomic={str(bool(window.get('non_atomic'))).lower()}); "
        f"residual interval={gib(interval.get('min')):.1f}..{gib(interval.get('max')):.1f} GiB"
    )

apfs = report.get("apfs_accounting") or {}
for store in apfs.get("physical_stores") or []:
    print(f"Physical store {store.get('device', '?')}: {gib(store.get('size_kb')):.1f} GiB")
if apfs:
    print(
        "APFS container equation: "
        f"{gib(apfs.get('volume_allocations_kb')):.1f} GiB volumes + "
        f"{gib(apfs.get('shared_allocation_kb')):.1f} GiB shared/metadata + "
        f"{gib(apfs.get('container_free_kb')):.1f} GiB free = "
        f"{gib(apfs.get('container_capacity_kb')):.1f} GiB capacity "
        f"(balanced={str(bool(apfs.get('equation_balanced'))).lower()})"
    )
volumes = []
for item in apfs.get("volumes") or []:
    kb = item.get("capacity_in_use_kb") or 0
    if gib(kb) >= threshold:
        roles = ",".join(item.get("roles") or []) or "no role"
        volumes.append((kb, item.get("name", "unknown"), roles))
if volumes:
    print(f"APFS volume allocations >= {threshold:g} GiB (separate roles):")
    for kb, name, roles in sorted(volumes, reverse=True):
        print(f"  {name} [{roles}]: {gib(kb):.1f} GiB")
else:
    print(f"APFS volume allocations >= {threshold:g} GiB: unavailable or none measured")

buckets = report.get("granularity_buckets") or []
oversize_files = report.get("oversize_indivisible_files") or []
print(f"Data directory/path buckets <= {threshold:g} GiB:")
if buckets:
    for item in buckets:
        print(f"  {gib(item.get('measured_kb')):8.1f} GiB  {item.get('path')}")
else:
    print("  none measured")
violations = [item for item in buckets if gib(item.get("measured_kb")) > threshold]
if violations:
    print("CONTRACT FAILURE: scanner emitted oversized normal buckets:")
    for item in violations:
        print(f"  {gib(item.get('measured_kb')):8.1f} GiB  {item.get('path')}")
if oversize_files:
    print(f"Indivisible files above {threshold:g} GiB (final path-level explanation):")
    for item in oversize_files:
        print(f"  {gib(item.get('measured_kb')):8.1f} GiB  {item.get('path')}")

purgeable = report.get("purgeable_kb") or 0
residual = report.get("residual_kb") or 0
used = report.get("disk_used_kb") or 0
bucket_total = report.get("granularity_bucket_total_kb") or 0
tail = report.get("granularity_tail_kb") or 0
oversize_total = report.get("oversize_indivisible_files_total_kb") or 0
equation = report.get("accounting_equation") or {}
print(
    "Displayed Data equation: "
    f"{gib(bucket_total):.1f} GiB bounded buckets + "
    f"{gib(oversize_total):.1f} GiB indivisible files + "
    f"{gib(tail):.1f} GiB measured tail + "
    f"{gib(purgeable):.1f} GiB purgeable estimate + "
    f"{gib(residual):.1f} GiB residual = {gib(used):.1f} GiB used "
    f"(balanced={str(bool(equation.get('displayed_balanced'))).lower()})"
)
print(
    "Residual means protected/APFS allocation not attributable by this session; "
    "it is not backup size and not reclaimable without evidence."
)
print(
    f"Scan mode: {report.get('mode', 'unknown')}; "
    f"nodes={report.get('nodes_processed', 0)}; "
    f"emergency node ceiling={(report.get('config') or {}).get('max_nodes', 'unknown')}; "
    f"elapsed={report.get('elapsed_s', 0)}s"
)
limits = report.get("limits") or {}
print(
    "Access context: "
    f"sudo_used={str(bool(limits.get('sudo_used'))).lower()}; "
    f"full_disk_access={limits.get('full_disk_access', 'not_inferred')}"
)
unfinished = report.get("frontier_unfinished") or []
if unfinished:
    print("Named unfinished frontier (permission/time/node/mount limits remain separate):")
    for item in unfinished:
        observed = item.get("observed_kb")
        size = f" ({gib(observed):.1f} GiB observed)" if observed is not None else ""
        print(f"  {item.get('reason', 'unknown')}: {item.get('path', '?')}{size}")
else:
    print("Named unfinished frontier: none")
if violations:
    raise SystemExit(2)
PY
  render_rc=$?
else
  echo "Top-down lane failed (rc=$topdown_rc); raw diagnostic follows:"
  sed -n '1,160p' "$TOPDOWN_LOG"
fi

echo
echo "=== Lane 2/3: coverage-validated snapshot deltas ==="
cat "$HISTORY_LOG"
[[ "$history_rc" -eq 0 ]] || echo "Snapshot-delta lane failed (rc=$history_rc)."

echo
echo "=== Lane 3/3: safe quick wins and obvious outliers ==="
cat "$QUICK_LOG"
[[ "$quick_rc" -eq 0 ]] || echo "Quick-win lane failed (rc=$quick_rc)."

if [[ "$topdown_rc" -ne 0 || "$render_rc" -ne 0 || "$history_rc" -ne 0 || "$quick_rc" -ne 0 ]]; then
  exit 1
fi
