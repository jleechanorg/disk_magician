#!/usr/bin/env bash
# symlink-shared-venvs.sh
# Replace per-worktree venvs in a repo with symlinks to a single
# canonical venv (the largest one). Dry-run by default; --clean to apply.
#
# Strategy: no new venv is created. We pick the LARGEST existing venv
# as canonical, rename the OTHERS to <name>.bak.<timestamp>, and put
# symlinks at the original paths pointing to the canonical.
#
# Safety invariants (matches cleanup_worktree_venvs.sh style):
#   - Dry-run by default; --clean required to actually modify
#   - Real venvs are renamed to <name>.bak.<timestamp> (NEVER deleted)
#   - Python version check: only symlink venvs that share the same
#     pyvenv.cfg `home` field as the canonical. Mixing uv-managed
#     python with system python would change behavior.
#   - Already-symlinked venvs are skipped (idempotent)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=true
ROOTS=("$HOME/.worktrees" "$HOME/projects" "$HOME/project_agento" "$HOME/projects_other" "$HOME/repos")
PURGE_BAK_DAYS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--purge-bak-days N] [--roots p1,p2,...] [-h|--help]

Replace per-worktree venvs with symlinks to the LARGEST existing venv.

Options:
  --clean                Actually replace venvs (default: dry-run).
  --dry-run              Print what would happen (default).
  --purge-bak-days N     Purge *.bak.* venv directories older than N days (default: disabled).
  --roots p1,p2,...      Comma-separated root dirs to scan.
  -h, --help             Show this help.

Examples:
  $(basename "$0") --dry-run
  $(basename "$0") --clean --purge-bak-days 1
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)
      DRY_RUN=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --purge-bak-days)
      [[ $# -ge 2 ]] || { echo "--purge-bak-days requires a value" >&2; exit 2; }
      PURGE_BAK_DAYS="$2"
      shift 2
      ;;
    --roots)
      [[ $# -ge 2 ]] || { echo "--roots requires a value" >&2; exit 2; }
      IFS=',' read -ra ROOTS <<<"$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] $*"
  else
    eval "$@"
  fi
}

# Relativize a path to be relative to a base directory. macOS realpath
# doesn't support --relative-to, so we fall back to python3.
relpath() {
  local target="$1" base="$2"
  if command -v realpath >/dev/null 2>&1 && realpath --relative-to="$base" "$target" >/dev/null 2>&1; then
    realpath --relative-to="$base" "$target"
  else
    python3 -c "import os.path,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))" "$target" "$base"
  fi
}

# Return the python `home` from pyvenv.cfg, or empty if no venv / malformed.
venv_python_home() {
  local venv="$1"
  local cfg="$venv/pyvenv.cfg"
  [[ -f "$cfg" ]] || return 0
  awk -F' *= *' '/^home *=/ {print $2; exit}' "$cfg" 2>/dev/null
}

# Find the canonical (largest) venv under <base>.
find_canonical() {
  local base="$1"
  local biggest="" biggest_size=0
  while IFS= read -r venv; do
    local sz home
    sz=$(du -sk "$venv" 2>/dev/null | awk '{print $1+0}')
    if (( sz > biggest_size )); then
      biggest_size=$sz
      biggest="$venv"
    fi
  done < <(find "$base" -maxdepth 6 \( -name venv -o -name .venv \) -type d 2>/dev/null)
  echo "$biggest $biggest_size"
}

# Find candidate base repos: depth-1 dirs that have at least 2 venvs
# at depth ≤6.
find_base_repos() {
  local root="$1"
  local d n
  while IFS= read -r d; do
    case "$(basename "$d")" in
      worktree_*|wt_*) continue ;;
    esac
    n=$(find "$d" -maxdepth 6 \( -name venv -o -name .venv \) \( -type d -o -type l \) 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$n" -ge 2 ]]; then
      echo "$d"
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

# Process a single repo.
process_repo() {
  local base="$1"
  log ""
  log "==> $(basename "$base")"

  # Read canonical
  local line canonical size_kb
  line=$(find_canonical "$base")
  canonical=$(echo "$line" | awk '{print $1}')
  size_kb=$(echo "$line" | awk '{print $2}')

  if [[ -z "$canonical" ]]; then
    log "  no venvs found, skipping"
    return 0
  fi
  log "  canonical: $canonical  (${size_kb}K)"

  local canonical_home
  canonical_home=$(venv_python_home "$canonical")
  log "  canonical python: $canonical_home"

  local replaced=0 skipped_link=0 skipped_python=0

  while IFS= read -r venv; do
    [[ "$venv" == "$canonical" ]] && continue

    if [[ -L "$venv" && -d "$venv" ]]; then
      log "  skip (already symlink): $venv"
      skipped_link=$((skipped_link+1))
      continue
    fi

    if [[ -L "$venv" ]]; then
      log "  dangling symlink, will repair: $venv"
    fi

    # Python-mix safety: only symlink if pyvenv.cfg home matches.
    local this_home
    this_home=$(venv_python_home "$venv")
    if [[ -n "$canonical_home" && -n "$this_home" && "$this_home" != "$canonical_home" ]]; then
      log "  SKIP (python mismatch: $this_home != $canonical_home): $venv"
      skipped_python=$((skipped_python+1))
      continue
    fi

    # Compute relative path from the venv's parent dir to the canonical.
    local venv_parent rel_target bak
    venv_parent="$(dirname "$venv")"
    rel_target="$(relpath "$canonical" "$venv_parent")"
    bak="${venv}.bak.$(date +%Y%m%d-%H%M%S)"

    if [[ "$DRY_RUN" == true ]]; then
      log "  [dry-run] would rename $venv → $bak"
      log "  [dry-run] would ln -sfn '$rel_target' '$venv'"
    else
      mv "$venv" "$bak"
      ln -sfn "$rel_target" "$venv"
      log "  linked: $venv → $rel_target  (backup: $bak)"
    fi
    replaced=$((replaced+1))
  done < <(find "$base" -maxdepth 6 \( -name venv -o -name .venv \) \( -type d -o -type l \) 2>/dev/null)

  log "  → $replaced replaced, $skipped_link already-symlinked, $skipped_python skipped (python mismatch)"
}

purge_bak_dirs() {
  local days="$1"
  log ""
  log "=== PURGING VENV BACKUPS (>= ${days} days old) ==="
  local now mtime age_days bak_dir freed_kb=0 count=0
  now=$(date +%s)

  for root in "${ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' bak_dir; do
      mtime=$(stat -f %m "$bak_dir" 2>/dev/null || stat -c %Y "$bak_dir" 2>/dev/null || echo "$now")
      age_days=$(( (now - mtime) / 86400 ))
      if (( age_days >= days )); then
        local sz
        sz=$(du -sk "$bak_dir" 2>/dev/null | awk '{print $1+0}')
        freed_kb=$((freed_kb + sz))
        count=$((count + 1))
        if [[ "$DRY_RUN" == true ]]; then
          log "  [dry-run] would remove backup (${sz}K, age ${age_days}d): $bak_dir"
        else
          rm -rf "$bak_dir"
          log "  removed backup (${sz}K, age ${age_days}d): $bak_dir"
        fi
      fi
    done < <(find "$root" -maxdepth 6 -type d \( -name "*.bak.*" -o -name "venv.bak*" -o -name ".venv.bak*" \) -print0 2>/dev/null)
  done
  log "  → $count backup(s) processed (total ${freed_kb}K)"
}

# Main loop
log "=== SYMLINK SHARED VENVS ==="
if [[ "$DRY_RUN" == true ]]; then
  log "Mode: dry-run (use --clean to actually replace)"
else
  log "Mode: CLEAN (will rename existing venvs to .bak.<ts>)"
fi
log "Roots: ${ROOTS[*]}"
log ""

for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || { log "Root missing, skipping: $root"; continue; }
  log "Scanning $root ..."

  while IFS= read -r base; do
    [[ -z "$base" ]] && continue
    process_repo "$base"
  done < <(find_base_repos "$root")
done

if [[ -n "$PURGE_BAK_DAYS" ]]; then
  purge_bak_dirs "$PURGE_BAK_DAYS"
fi

log ""
log "=== Done ==="
if [[ "$DRY_RUN" == true ]]; then
  log "This was a DRY-RUN. Re-run with --clean to apply."
fi
