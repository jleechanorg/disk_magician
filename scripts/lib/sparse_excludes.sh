# shellcheck shell=bash
# sparse_excludes.sh — per-repo sparse-checkout exclusions (bead disk_magician-yc7g).
#
# sparse_excludes_for_repo <repo-basename> prints the configured paths, one per
# line. Source: `worktree_sparse_excludes` ({"<repo>": ["path", ...]}) in the
# winning config (scripts/resolve_config.py); when that key is absent the
# built-in default applies, so a host whose config predates the key still
# excludes roadmap's ~9.8 GiB dashboards/prw/telemetry. A present key (even {})
# replaces the default.
_SPARSE_EX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sparse_excludes_for_repo() {
  local cfg
  cfg="$(python3 "$_SPARSE_EX_DIR/../resolve_config.py" 2>/dev/null || true)"
  python3 -c '
import json, sys
cfg, repo = sys.argv[1], sys.argv[2]
m = {"roadmap": ["dashboards/prw/telemetry"]}
try:
    m = json.load(open(cfg)).get("worktree_sparse_excludes", m)
except Exception:
    pass
for p in (m.get(repo) or []) if isinstance(m, dict) else []:
    p = str(p).strip().strip("/")
    if p:
        print(p)
' "$cfg" "$1" 2>/dev/null || true
}

# sparse_repo_name <path> — repo basename of the repo owning <path> (bare ".git" suffix stripped).
sparse_repo_name() {
  local c b
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  b="$(basename "$c")"
  [[ "$b" == ".git" ]] && b="$(basename "$(dirname "$c")")"
  printf '%s\n' "${b%.git}"
}
