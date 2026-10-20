#!/usr/bin/env bash
# tests/test_reclaim_catalog.sh — scripts/lib/reclaim_catalog.py is the single
# reclaim table shared by `diskm report --html` and the routine.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$REPO_ROOT/scripts/lib/reclaim_catalog.py"
PASS=0; FAIL=0; XFAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "== (a) --json prints a JSON array =="
json="$(python3 "$CATALOG" --json 2>&1)" && ok "--json exits 0" || bad "--json failed: $json"
python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list) and d' <<<"$json" 2>/dev/null \
  && ok "output is a non-empty JSON array" || bad "output is not a JSON array"

echo "== (b) safe/gated rows carry actuator, age_days, class =="
out="$(python3 - "$json" <<'PY'
import json, sys
allowed = {"dev_caches", "tmp", "worktrees", "worktree_deps", "colima", "xcode", "codex_db",
           "claude_state", "task_scratch", "pr_scratch", "antigravity_brain", "codex_documents",
           "apfs_snapshots", "uv_cache", "dark_factory", "sessions", "dir_prune"}
for row in json.loads(sys.argv[1]):
    if row["bucket"] not in ("safe", "gated"):
        continue
    if row.get("actuator") not in allowed:
        print(f"{row['key']}: actuator {row.get('actuator')!r} not allowed")
    if not (isinstance(row.get("age_days"), int) and row["age_days"] >= 0):
        print(f"{row['key']}: age_days {row.get('age_days')!r}")
    if "class" not in row:
        print(f"{row['key']}: no class field")
PY
)" || out="(catalog JSON unreadable)"
[[ -z "$out" ]] && ok "every safe/gated row is complete" || { bad "incomplete rows"; echo "$out"; }

echo "== (c) every actuator names an existing script =="
missing="$(python3 - "$json" "$REPO_ROOT" <<'PY'
import json, os, sys
scripts = {"dev_caches": "cleanup_dev_caches.sh", "tmp": "cleanup_tmp.sh",
           "worktrees": "cleanup_worktrees.sh", "worktree_deps": "cleanup_worktree_deps.sh",
           "colima": "cleanup_colima.sh", "xcode": "cleanup_xcode.sh", "codex_db": "cleanup_codex_db.sh",
           "claude_state": "cleanup_claude_state.sh", "task_scratch": "cleanup_task_scratch.sh",
           "pr_scratch": "cleanup_pr_scratch.sh", "antigravity_brain": "cleanup_antigravity_brain.sh",
           "codex_documents": "cleanup_codex_documents.sh", "apfs_snapshots": "cleanup_apfs_snapshots.sh",
           "uv_cache": "cleanup_uv_cache.sh", "dark_factory": "cleanup_dark_factory.sh",
           "sessions": "cleanup_sessions.sh", "dir_prune": "reclaim_dir_prune.sh"}
for a in sorted({r["actuator"] for r in json.loads(sys.argv[1]) if r.get("actuator")}):
    if not os.path.isfile(os.path.join(sys.argv[2], "scripts", scripts.get(a, "?"))):
        print(a)
PY
)" || missing="(catalog JSON unreadable)"
if [[ -z "$missing" ]]; then
  ok "all actuator scripts exist"
elif [[ "$missing" == dir_prune && ! -f "$REPO_ROOT/scripts/reclaim_dir_prune.sh" ]]; then
  # Expected until Task A2 adds scripts/reclaim_dir_prune.sh.
  echo "  XFAIL: dir_prune actuator not yet present (Task A2)"; XFAIL=$((XFAIL + 1))
else
  bad "missing actuator scripts: $(tr '\n' ' ' <<<"$missing")"
fi

echo "== (d) the report renders from the shared table =="
grep -q '^CATALOG_RULES' "$REPO_ROOT/scripts/disk_report_html.py" \
  && bad "disk_report_html.py still defines CATALOG_RULES inline" || ok "no inline CATALOG_RULES in the report"
n="$(cd "$REPO_ROOT/scripts" && python3 -c 'import disk_report_html as r; print(len(r.CATALOG_RULES))' 2>&1)"
[[ "$n" == 40 ]] && ok "report sees the same 40 keys" || bad "report key count: $n"
for f in pyproject.toml setup.py scripts/sync_package_tree.sh; do
  grep -q 'scripts/lib/\*\.py' "$REPO_ROOT/$f" && ok "$f packages scripts/lib/*.py" || bad "$f does not package scripts/lib/*.py"
done

echo "PASS=$PASS FAIL=$FAIL XFAIL=$XFAIL"
[[ "$FAIL" -eq 0 ]]
