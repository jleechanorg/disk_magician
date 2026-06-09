#!/usr/bin/env bash
# snapshot_lib.sh — shared helper for selecting the *current host's* disk snapshot.
#
# Multiple machines commit their own backup/<host>/disk_snapshot.json into the
# backup repo. A naive glob (backup/*/disk_snapshot.json) picks the first alphabetical
# match. Both audit and history must agree on the SAME file, so the selection lives here.
#
# Selection strategy (host-agnostic):
#   1. Honor $DISK_SNAPSHOT_JSON if it points at a real file.
#   2. Otherwise pick the candidate with the NEWEST embedded "timestamp" field.
#   3. Fall back to filesystem mtime, then to the first existing candidate.

resolve_snapshot_path() {
    local backup_root="$1"

    # 1. Explicit override.
    if [[ -n "${DISK_SNAPSHOT_JSON:-}" && -f "${DISK_SNAPSHOT_JSON}" ]]; then
        printf '%s\n' "$DISK_SNAPSHOT_JSON"
        return 0
    fi

    local candidates=()
    local f
    for f in "$backup_root"/backup/*/disk_snapshot.json; do
        [[ -f "$f" ]] && candidates+=("$f")
    done
    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 1
    fi
    if [[ ${#candidates[@]} -eq 1 ]]; then
        printf '%s\n' "${candidates[0]}"
        return 0
    fi

    # 2. Newest embedded timestamp wins.
    local best
    best=$(python3 - "${candidates[@]}" <<'PY' 2>/dev/null
import json, os, sys
best_key = None
best_path = ""
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception:
        continue
    ts = str(data.get("timestamp") or "")
    # current-schema files carry snapshot_coverage_pct; prefer them on ties
    has_cov = 1 if data.get("snapshot_coverage_pct") is not None else 0
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        mtime = 0.0
    key = (ts, has_cov, mtime)
    if best_key is None or key > best_key:
        best_key = key
        best_path = path
print(best_path)
PY
)
    if [[ -n "$best" && -f "$best" ]]; then
        printf '%s\n' "$best"
        return 0
    fi

    # 3. Fallback: newest mtime, else first candidate.
    local newest="" newest_mt=-1 mt
    for f in "${candidates[@]}"; do
        mt=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0)
        if [[ "$mt" -gt "$newest_mt" ]]; then
            newest_mt="$mt"; newest="$f"
        fi
    done
    printf '%s\n' "${newest:-${candidates[0]}}"
}
