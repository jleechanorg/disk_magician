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
    __pycache__/*|*/__pycache__/*|*.pyc) continue ;;
  esac
  deployed_file="$deployed_root/$rel"
  if [[ ! -f "$deployed_file" ]] || ! cmp -s "$source_file" "$deployed_file"; then
    echo "deploy_uv_tool: deployed file mismatch: $rel" >&2
    exit 1
  fi
done < <(find "$REPO_ROOT/src/disk_magician" -type f -print0)

while IFS= read -r -d '' deployed_file; do
  rel="${deployed_file#"$deployed_root/"}"
  case "$rel" in
    __pycache__/*|*/__pycache__/*|*.pyc) continue ;;
  esac
  source_file="$REPO_ROOT/src/disk_magician/$rel"
  if [[ ! -f "$source_file" ]]; then
    echo "deploy_uv_tool: unexpected deployed file: $rel" >&2
    exit 1
  fi
done < <(find "$deployed_root" -type f -print0)

# Post-deploy smoke: both names are production entrypoints. Capture their
# actual help output and require the aliases to agree, rather than only
# checking that one executable starts.
smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/deploy_uv_tool.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT
for smoke_name in disk-magician diskm; do
  smoke_bin="$tool_root/bin/$smoke_name"
  if [[ ! -x "$smoke_bin" ]]; then
    echo "deploy_uv_tool: SMOKE FAILED — deployed entrypoint missing/not executable: $smoke_bin" >&2
    exit 1
  fi
  if ! "$smoke_bin" --help >"$smoke_dir/$smoke_name.help" 2>&1; then
    echo "deploy_uv_tool: SMOKE FAILED — $smoke_bin --help did not execute cleanly" >&2
    exit 1
  fi
done
if ! cmp -s "$smoke_dir/disk-magician.help" "$smoke_dir/diskm.help"; then
  echo "deploy_uv_tool: SMOKE FAILED — disk-magician and diskm --help differ" >&2
  exit 1
fi

# Re-pin the source after installation and package comparison. A successful
# install is not receipt-worthy if the checkout changed while it was running.
post_head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [[ "$post_head_sha" != "$head_sha" ]]; then
  echo "deploy_uv_tool: refusing source mutation during install/comparison (HEAD $post_head_sha != $head_sha)" >&2
  exit 1
fi
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]]; then
  echo "deploy_uv_tool: refusing source mutation during install/comparison: $REPO_ROOT" >&2
  exit 1
fi

state_dir="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
mkdir -p "$state_dir"
python3 - "$state_dir/deployed.json" "$REPO_ROOT" "$head_sha" "$installed_version" "$deployed_root" <<'PY'
import datetime
import hashlib
import json
import os
import subprocess
import sys
import tempfile

receipt_path, source_root, expected_sha, installed_version, package_root = sys.argv[1:]

def source_is_still_pinned():
    current_sha = subprocess.check_output(
        ["git", "-C", source_root, "rev-parse", "HEAD"],
        text=True,
    ).strip()
    if current_sha != expected_sha:
        raise RuntimeError("source HEAD changed before receipt publication")
    status = subprocess.check_output(
        ["git", "-C", source_root, "status", "--porcelain", "--untracked-files=normal"],
        text=True,
    )
    if status:
        raise RuntimeError("source tree changed before receipt publication")

def ignored_package_file(relative_path):
    parts = relative_path.split(os.sep)
    return (
        "__pycache__" in parts
        or relative_path.endswith(".pyc")
    )

def package_hashes(root):
    hashes = {}
    for current, dirs, files in os.walk(root):
        dirs[:] = sorted(name for name in dirs if name != "__pycache__")
        for name in sorted(files):
            full_path = os.path.join(current, name)
            relative_path = os.path.relpath(full_path, root)
            if ignored_package_file(relative_path):
                continue
            digest = hashlib.sha256()
            with open(full_path, "rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            hashes[relative_path.replace(os.sep, "/")] = digest.hexdigest()
    return hashes

source_is_still_pinned()
verified_hashes = package_hashes(os.path.join(source_root, "src", "disk_magician"))
if not verified_hashes or package_hashes(package_root) != verified_hashes:
    raise RuntimeError("deployed package changed before receipt publication")
source_is_still_pinned()
payload = {
    "schema_version": 1,
    "source_sha": expected_sha,
    "installed_version": installed_version,
    "deployed_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "package_root": os.path.realpath(package_root),
    "package_hashes": verified_hashes,
    "source_root": os.path.realpath(source_root),
    "override_state": False,
}

state_dir = os.path.dirname(os.path.realpath(receipt_path))
os.makedirs(state_dir, exist_ok=True)
temp_path = None
try:
    fd, temp_path = tempfile.mkstemp(prefix=".deployed.json.", dir=state_dir, text=True)
    with os.fdopen(fd, "w") as stream:
        json.dump(payload, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp_path, receipt_path)
    temp_path = None
except Exception:
    if temp_path is not None:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
    raise
PY

echo "deploy_uv_tool: deployed head=$head_sha version=$version smoke=ok verified_root=$deployed_root receipt=$state_dir/deployed.json"
