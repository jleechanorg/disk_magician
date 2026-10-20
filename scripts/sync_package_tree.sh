#!/usr/bin/env bash
# sync_package_tree.sh — one-way sync of canonical root files into
# src/disk_magician/ (bead jleechan-jujr).
#
# The repo root is the source of truth; src/disk_magician/ is the packaged
# mirror consumed by pyproject/pip (it also carries package-only files —
# cli.py, __init__.py, *.egg-info/ — which are outside the canonical set
# below and are never touched by this script).
#
# Usage: sync_package_tree.sh [--check]
#   (no args)  sync root -> src/disk_magician/: create/update changed files,
#              remove dest files whose root counterpart no longer exists.
#   --check    write nothing; list drifted files and exit 1 if any exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_ROOT="$REPO_ROOT/src/disk_magician"

CHECK_ONLY=false
STAGE_DIR=""
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
elif [[ "${1:-}" == "--stage" ]]; then
  STAGE_DIR="${2:-}"
  [[ -n "$STAGE_DIR" ]] || { echo "Usage: $0 [--check | --stage <dest_dir>]" >&2; exit 2; }
fi

# Canonical file set, expressed as glob patterns relative to REPO_ROOT.
PATTERNS=(
  "disk_magician.sh"
  "config.json.template"
  "config/*.txt"
  "scripts/*.sh"
  "scripts/*.py"
  "scripts/lib/*.sh"
  "scripts/lib/*.py"
  "launchd/*.plist"
  "launchd/*.plist.template"
  "launchd/*.c"
  "tools/*.sh"
)

if [[ -n "$STAGE_DIR" ]]; then
  mkdir -p "$STAGE_DIR"
  for pkg_file in "__init__.py" "cli.py"; do
    if [[ -f "$DEST_ROOT/$pkg_file" ]]; then
      cp -p "$DEST_ROOT/$pkg_file" "$STAGE_DIR/$pkg_file"
    fi
  done
  for pattern in "${PATTERNS[@]}"; do
    for src in "$REPO_ROOT"/$pattern; do
      [[ -f "$src" ]] || continue
      rel="${src#"$REPO_ROOT"/}"
      mkdir -p "$(dirname "$STAGE_DIR/$rel")"
      cp -p "$src" "$STAGE_DIR/$rel"
    done
  done
  exit 0
fi

drift=()

if [[ "$CHECK_ONLY" == true && ! -f "$DEST_ROOT/disk_magician.sh" && ! -d "$DEST_ROOT/scripts" && ! -d "$DEST_ROOT/launchd" && ! -d "$DEST_ROOT/config" && ! -f "$DEST_ROOT/config.json.template" ]]; then
  [[ -f "$REPO_ROOT/setup.py" ]] || drift+=("MISSING setup.py")
  [[ -f "$DEST_ROOT/__init__.py" ]] || drift+=("MISSING src/disk_magician/__init__.py")
  [[ -f "$DEST_ROOT/cli.py" ]] || drift+=("MISSING src/disk_magician/cli.py")
  for pattern in "${PATTERNS[@]}"; do
    matched=false
    for src in "$REPO_ROOT"/$pattern; do
      if [[ -f "$src" ]]; then
        matched=true
        break
      fi
    done
    [[ "$matched" == true ]] || drift+=("MISSING $pattern")
  done
  if [[ ${#drift[@]} -eq 0 ]]; then
    echo "sync_package_tree: single-source package layout verified (0 drifted files)"
    exit 0
  fi
  echo "sync_package_tree --check: ${#drift[@]} drifted file(s):"
  printf '  %s\n' "${drift[@]}"
  exit 1
fi

sync_file() {
  local rel="$1" src="$REPO_ROOT/$1" dest="$DEST_ROOT/$1"
  if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
    drift+=("MODIFY $rel")
    if [[ "$CHECK_ONLY" == false ]]; then
      mkdir -p "$(dirname "$dest")"
      cp -p "$src" "$dest"
    fi
  fi
}

remove_orphans() {
  local pattern="$1" dest
  for dest in "$DEST_ROOT"/$pattern; do
    [[ -f "$dest" ]] || continue
    local rel="${dest#"$DEST_ROOT"/}"
    [[ -f "$REPO_ROOT/$rel" ]] && continue
    drift+=("REMOVE $rel")
    [[ "$CHECK_ONLY" == false ]] && rm -f "$dest"
  done
}

for pattern in "${PATTERNS[@]}"; do
  for src in "$REPO_ROOT"/$pattern; do
    [[ -f "$src" ]] || continue
    sync_file "${src#"$REPO_ROOT"/}"
  done
  remove_orphans "$pattern"
done

if [[ ${#drift[@]} -eq 0 ]]; then
  echo "sync_package_tree: src/disk_magician/ is in sync with repo root (0 drifted files)"
  exit 0
fi

if [[ "$CHECK_ONLY" == true ]]; then
  echo "sync_package_tree --check: ${#drift[@]} drifted file(s):"
  printf '  %s\n' "${drift[@]}"
  exit 1
fi

echo "sync_package_tree: synced ${#drift[@]} file(s):"
printf '  %s\n' "${drift[@]}"

