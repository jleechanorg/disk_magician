#!/usr/bin/env bash
# Deploy the uv tool only from a clean checkout exactly matching origin/main.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true
if [[ $# -gt 0 && "$CHECK_ONLY" != true ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

git -C "$REPO_ROOT" fetch --quiet origin main
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]]; then
  echo "deploy_uv_tool: refusing dirty source tree: $REPO_ROOT" >&2
  exit 1
fi

head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
main_sha="$(git -C "$REPO_ROOT" rev-parse refs/remotes/origin/main)"
if [[ "$head_sha" != "$main_sha" ]]; then
  echo "deploy_uv_tool: refusing HEAD $head_sha; expected origin/main $main_sha" >&2
  exit 1
fi

"$REPO_ROOT/scripts/sync_package_tree.sh" --check
version="$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$REPO_ROOT/pyproject.toml" | head -n 1)"
[[ -n "$version" ]] || { echo "deploy_uv_tool: package version is missing" >&2; exit 1; }

if [[ "$CHECK_ONLY" == true ]]; then
  echo "deploy_uv_tool: ready head=$head_sha version=$version"
  exit 0
fi

uv_bin="${DISK_MAGICIAN_UV_BIN:-$(command -v uv || true)}"
[[ -x "$uv_bin" ]] || { echo "deploy_uv_tool: uv executable not found" >&2; exit 1; }
"$uv_bin" tool install --force --reinstall "$REPO_ROOT"

tool_root="${DISK_MAGICIAN_TOOL_ROOT:-$HOME/.local/share/uv/tools/disk-magician}"
tool_python="$tool_root/bin/python"
[[ -x "$tool_python" ]] || { echo "deploy_uv_tool: installed tool Python missing: $tool_python" >&2; exit 1; }
installed_version="$($tool_python -c 'from importlib.metadata import version; print(version("disk-magician"))')"
if [[ "$installed_version" != "$version" ]]; then
  echo "deploy_uv_tool: installed version $installed_version != source $version" >&2
  exit 1
fi

deployed_root=""
for candidate in "$tool_root"/lib/python*/site-packages/disk_magician; do
  [[ -d "$candidate" ]] || continue
  [[ -z "$deployed_root" ]] || { echo "deploy_uv_tool: multiple deployed package roots" >&2; exit 1; }
  deployed_root="$candidate"
done
[[ -n "$deployed_root" ]] || { echo "deploy_uv_tool: deployed package root not found" >&2; exit 1; }

while IFS= read -r -d '' source_file; do
  rel="${source_file#"$REPO_ROOT/src/disk_magician/"}"
  case "$rel" in
    __pycache__/*|*/__pycache__/*|*.pyc|launchd/*.plist) continue ;;
  esac
  deployed_file="$deployed_root/$rel"
  if [[ ! -f "$deployed_file" ]] || ! cmp -s "$source_file" "$deployed_file"; then
    echo "deploy_uv_tool: deployed file mismatch: $rel" >&2
    exit 1
  fi
done < <(find "$REPO_ROOT/src/disk_magician" -type f -print0)

echo "deploy_uv_tool: deployed head=$head_sha version=$version verified_root=$deployed_root"
