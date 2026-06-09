#!/usr/bin/env bash
# disk_audit.sh — Deep disk usage diagnostics and cleanup
set -euo pipefail

MODE="audit"
DRY_RUN=false
LIVE=false
SHOW_HISTORY=true

for arg in "$@"; do
    case "$arg" in
        --clean)         MODE="clean" ;;
        --clean-all)     MODE="clean-all" ;;
        --dry-run)       DRY_RUN=true ;;
        --live)          LIVE=true ;;
        --no-history)    SHOW_HISTORY=false ;;
        --help|-h)
            echo "Usage: $0 [--clean|--clean-all] [--dry-run] [--live] [--no-history]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source snapshot_lib to find the correct snapshot file
# shellcheck source=scripts/snapshot_lib.sh
if [[ -f "$SCRIPT_DIR/snapshot_lib.sh" ]]; then
    source "$SCRIPT_DIR/snapshot_lib.sh"
fi

CONFIG_FILE="$REPO_ROOT/config.json"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/config.json.template"

# Resolve snapshot JSON
SNAPSHOT_JSON=""
if declare -f resolve_snapshot_path >/dev/null 2>&1; then
    SNAPSHOT_JSON="$(resolve_snapshot_path "$REPO_ROOT" || true)"
fi

SNAP_USABLE=false
SNAP_COVERAGE=""
SNAP_AGE_MIN=""
SNAP_CACHE=""
SNAP_REASON=""

_cleanup_snap() { [[ -n "$SNAP_CACHE" && -f "$SNAP_CACHE" ]] && rm -f "$SNAP_CACHE"; }
trap _cleanup_snap EXIT

_load_snapshot() {
    [[ -n "$SNAPSHOT_JSON" ]] || { SNAP_REASON="no snapshot found"; return 1; }
    command -v python3 &>/dev/null || { SNAP_REASON="python3 unavailable"; return 1; }
    SNAP_CACHE="$(mktemp -t disk_audit_snap.XXXXXX)"
    
    local meta
    meta=$(python3 - "$SNAPSHOT_JSON" "$SNAP_CACHE" <<'PY' 2>/dev/null || true
import json, sys, datetime
src, cache = sys.argv[1], sys.argv[2]
try:
    s = json.load(open(src))
except Exception:
    print("ERR\t\t\tparse_error"); sys.exit(0)
cov  = s.get("snapshot_coverage_pct", "")
warn = s.get("snapshot_warning", "") or ""
ts   = s.get("timestamp", "") or ""
dirs = s.get("directories", {}) or {}
with open(cache, "w") as fh:
    for k, v in dirs.items():
        if v is None:
            continue
        try:
            fh.write(f"{k}\t{int(v)}\n")
        except Exception:
            pass
age_min = ""
try:
    t = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    age_min = int((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() // 60)
except Exception:
    pass
print(f"OK\t{cov}\t{age_min}\t{warn}")
PY
)
    local _status _warn
    IFS=$'\t' read -r _status SNAP_COVERAGE SNAP_AGE_MIN _warn <<<"$meta"
    if [[ "$_status" != "OK" ]]; then
        SNAP_REASON="snapshot unreadable (${_status:-empty})"; return 1
    fi
    local cov_int="${SNAP_COVERAGE%.*}"
    if [[ -z "$cov_int" || "$cov_int" -lt 70 ]]; then
        SNAP_REASON="coverage ${SNAP_COVERAGE:-?}% < 70 — re-measuring live"; return 1
    fi
    if [[ "$_warn" == "low_coverage" ]]; then
        SNAP_REASON="snapshot_warning=low_coverage — re-measuring live"; return 1
    fi
    SNAP_USABLE=true
    return 0
}

fmt_size() {
    local kb="${1:-0}"
    awk "BEGIN{
        gb = $kb / 1024 / 1024
        if (gb >= 1) printf \"%.1fG\", gb
        else if (gb >= 0.001) printf \"%.0fM\", gb * 1024
        else printf \"%.0fK\", $kb
    }"
}

section() {
    echo
    echo "── $1 ──"
}

if [[ "$LIVE" != true ]]; then
    _load_snapshot || true
fi

# ── 1. Overall disk status ───────────────────────────────────────────────────
section "Disk Status"
echo "  Volume usage:"
if [[ "$OSTYPE" == "darwin"* ]]; then
    df -h /System/Volumes/Data 2>/dev/null | tail -1 | awk '{printf "    Data volume: %s used / %s total (%s free, %s capacity)\n", $3, $2, $4, $5}' || df -h / 2>/dev/null | tail -1 | awk '{printf "    Data volume: %s used / %s total (%s free, %s capacity)\n", $3, $2, $4, $5}'
else
    df -h / 2>/dev/null | tail -1 | awk '{printf "    Data volume: %s used / %s total (%s free, %s capacity)\n", $3, $2, $4, $5}'
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
    snapshot_count=$(tmutil listlocalsnapshots / 2>/dev/null | { grep -c "com.apple" || true; })
    if [[ "${snapshot_count:-0}" -gt 0 ]]; then
        echo "  APFS snapshots: $snapshot_count (these consume space not shown by du)"
    fi
fi

# ── 2. Largest directories ───────────────────────────────────────────────────
if [[ "$SNAP_USABLE" == true ]]; then
    section "Largest directories (snapshot-ranked, top 20)"
    printf "  Source:   %s\n" "${SNAPSHOT_JSON/#$HOME/~}"
    printf "  Coverage: %s%%   Age: %s min\n" "${SNAP_COVERAGE:-?}" "${SNAP_AGE_MIN:-?}"
    echo
    sort -t"$(printf '\t')" -k2 -rn "$SNAP_CACHE" | head -20 | while IFS="$(printf '\t')" read -r key kb; do
        [[ -n "$key" ]] || continue
        printf "    %-34s %8s\n" "$key" "$(fmt_size "$kb")"
    done
else
    section "Directory Breakdown (Live du)"
    echo "  Snapshot not usable ($SNAP_REASON). Run snapshot task first."
fi

# ── 3. Recent History Growth (regressions) ───────────────────────────────────
if [[ "$SHOW_HISTORY" == true && -f "$SCRIPT_DIR/disk_history.sh" ]]; then
    section "Recent growth (last 7 days, regressions only)"
    "$SCRIPT_DIR/disk_history.sh" --days 7 --regressions || true
fi

# ── 4. Actionable Cleanup Candidates ─────────────────────────────────────────
section "Actionable Findings"

# Docker VM check
if command -v docker &>/dev/null; then
    docker_data="$HOME/Library/Containers/com.docker.docker/Data"
    if [[ -d "$docker_data" ]]; then
        size_kb=$(du -sk "$docker_data" 2>/dev/null | awk '{print $1+0}' || echo 0)
        if [[ $size_kb -gt $((5 * 1024 * 1024)) ]]; then
            printf "  %-50s %8s  %s\n" "Docker VM disk image" "$(fmt_size "$size_kb")" "DESTRUCTIVE: reset Docker disk image / prune -a"
        fi
    fi
fi

# Codex sessions check
codex_sessions="$HOME/.codex/sessions"
if [[ -d "$codex_sessions" ]]; then
    size_kb=$(du -sk "$codex_sessions" 2>/dev/null | awk '{print $1+0}' || echo 0)
    if [[ $size_kb -gt $((1 * 1024 * 1024)) ]]; then
        printf "  %-50s %8s  %s\n" "Codex Sessions directory" "$(fmt_size "$size_kb")" "REVIEW: stale session folders"
    fi
fi

# Antigravity worktrees check
ag_worktrees="$HOME/.gemini/antigravity/worktrees"
if [[ -d "$ag_worktrees" ]]; then
    size_kb=$(du -sk "$ag_worktrees" 2>/dev/null | awk '{print $1+0}' || echo 0)
    if [[ $size_kb -gt $((500 * 1024)) ]]; then
        printf "  %-50s %8s  %s\n" "Antigravity Worktrees" "$(fmt_size "$size_kb")" "REVIEW: orphaned branch/PR checkouts"
    fi
fi

# ── 5. Cleanup Execution ─────────────────────────────────────────────────────
if [[ "$MODE" == "audit" ]]; then
    echo
    echo "  Run with --clean to clean SAFE targets, or --clean-all for interactive cleanup."
    exit 0
fi

# Safe Cleanups
if [[ "$MODE" == "clean" ]]; then
    clean_arg="--dry-run"
    if [[ "$DRY_RUN" == false ]]; then
        clean_arg="--clean"
    fi
    
    section "Executing Safe Cleanups"
    
    # Run Cache Cleanup
    if [[ -f "$SCRIPT_DIR/cleanup_dev_caches.sh" ]]; then
        "$SCRIPT_DIR/cleanup_dev_caches.sh" $clean_arg || true
    fi

    # Run Temp Cleanup
    if [[ -f "$SCRIPT_DIR/cleanup_tmp.sh" ]]; then
        "$SCRIPT_DIR/cleanup_tmp.sh" $clean_arg || true
    fi

    # Run Worktree Cleanup
    if [[ -f "$SCRIPT_DIR/cleanup_worktrees.sh" ]]; then
        "$SCRIPT_DIR/cleanup_worktrees.sh" $clean_arg || true
    fi

    # Run LLM Inspector Cleanup
    if [[ -f "$SCRIPT_DIR/cleanup_llm_inspector.sh" ]]; then
        "$SCRIPT_DIR/cleanup_llm_inspector.sh" $clean_arg || true
    fi

    # Run Agent Artifacts Cleanup
    if [[ -f "$SCRIPT_DIR/cleanup_agent_artifacts.sh" ]]; then
        "$SCRIPT_DIR/cleanup_agent_artifacts.sh" $clean_arg || true
    fi
fi

# Aggressive Cleanups
if [[ "$MODE" == "clean-all" ]]; then
    clean_arg="--dry-run"
    if [[ "$DRY_RUN" == false ]]; then
        clean_arg="--clean"
    fi

    section "Executing Aggressive/Interactive Cleanups"

    # Clean sessions
    if [[ -f "$SCRIPT_DIR/cleanup_sessions.sh" ]]; then
        "$SCRIPT_DIR/cleanup_sessions.sh" $clean_arg || true
    fi

    # Clean worktrees
    if [[ -f "$SCRIPT_DIR/cleanup_worktrees.sh" ]]; then
        "$SCRIPT_DIR/cleanup_worktrees.sh" $clean_arg || true
    fi

    # Clean APFS Snapshots
    if [[ -f "$SCRIPT_DIR/cleanup_apfs_snapshots.sh" ]]; then
        "$SCRIPT_DIR/cleanup_apfs_snapshots.sh" $clean_arg || true
    fi

    # Docker System Prune
    if command -v docker &>/dev/null; then
        if [[ "$DRY_RUN" == true ]]; then
            echo "  Docker: [dry-run] would run: docker system prune -a -f"
        else
            echo "  Docker: running system prune -a -f ..."
            docker system prune -a -f || true
        fi
    fi
fi

section "After Cleanup"
if [[ "$OSTYPE" == "darwin"* ]]; then
    df -h /System/Volumes/Data 2>/dev/null | tail -1 | awk '{printf "  Free space: %s\n", $4}' || df -h / 2>/dev/null | tail -1 | awk '{printf "  Free space: %s\n", $4}'
else
    df -h / 2>/dev/null | tail -1 | awk '{printf "  Free space: %s\n", $4}'
fi
