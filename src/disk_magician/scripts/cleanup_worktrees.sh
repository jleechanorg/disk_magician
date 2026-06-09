#!/usr/bin/env bash
# cleanup_worktrees.sh — Dynamically discover and clean orphaned Git worktrees.
#
# Scans ~/.gemini/antigravity/worktrees/ and dynamically reads the .git file
# inside each candidate folder to determine if it is registered in the main repo.
set -euo pipefail

DRY_RUN=true
for arg in "$@"; do
    case "$arg" in
        --clean) DRY_RUN=false ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Usage: $0 [--clean] [--dry-run]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

WORKTREE_ROOT="${HOME}/.gemini/antigravity/worktrees"

if [[ ! -d "$WORKTREE_ROOT" ]]; then
    echo "No Antigravity worktree root at $WORKTREE_ROOT - nothing to do."
    exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "=== WORKTREE CLEANUP (DRY-RUN) ==="
else
    echo "=== WORKTREE CLEANUP ==="
fi

TOTAL_RECLAIMED_KB=0
DELETED_COUNT=0
KEPT_COUNT=0

# Helper to check if a worktree is active in its main repo
is_worktree_active() {
    local wt_path="$1"
    local git_file="$wt_path/.git"
    
    if [[ ! -f "$git_file" ]]; then
        # No .git file found -> corrupted/incomplete checkout, definitely orphaned
        return 1
    fi

    local gitdir_line
    gitdir_line=$(cat "$git_file" 2>/dev/null | grep '^gitdir: ' || true)
    if [[ -z "$gitdir_line" ]]; then
        return 1
    fi

    local git_dir
    git_dir=$(echo "$gitdir_line" | cut -d' ' -f2)
    
    # Extract the main repository path by stripping the worktrees suffix
    # worktree metadata format: /path/to/main/repo/.git/worktrees/name
    local main_repo="${git_dir%/.git/worktrees/*}"
    
    if [[ ! -d "$main_repo" ]]; then
        # Main repository no longer exists -> orphaned
        return 1
    fi

    # Check if this worktree is registered in the main repo's worktree list
    # git worktree list --porcelain outputs: worktree <path>
    if git -C "$main_repo" worktree list --porcelain 2>/dev/null | grep -q "^worktree ${wt_path}$"; then
        return 0 # Active
    fi

    return 1 # Orphaned
}

# Scan folders two levels deep: worktrees/<project>/<branch_or_pr>
for parent_dir in "$WORKTREE_ROOT"/*; do
    [[ -d "$parent_dir" ]] || continue
    
    for subdir in "$parent_dir"/*; do
        [[ -d "$subdir" ]] || continue
        
        abs_subdir=$(realpath "$subdir")
        
        if is_worktree_active "$abs_subdir"; then
            echo "  KEEP (active): $abs_subdir"
            KEPT_COUNT=$(( KEPT_COUNT + 1 ))
            continue
        fi

        # Orphaned or broken worktree
        size_kb=$(du -sk "$abs_subdir" 2>/dev/null | awk '{print $1+0}' || echo 0)
        size_mb=$(( size_kb / 1024 ))
        
        if [[ "$DRY_RUN" == true ]]; then
            echo "  ORPHANED (would delete): $abs_subdir (~$size_mb MB)"
            TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + size_kb ))
            DELETED_COUNT=$(( DELETED_COUNT + 1 ))
        else
            echo "  DELETING: $abs_subdir (~$size_mb MB) ..."
            rm -rf "$abs_subdir"
            TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + size_kb ))
            DELETED_COUNT=$(( DELETED_COUNT + 1 ))
        fi
    done
done

total_gb=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RECLAIMED_KB / 1048576}")

echo ""
if [[ "$DRY_RUN" == true ]]; then
    echo "Summary: Found $DELETED_COUNT orphaned worktree(s), ~$total_gb GB reclaimable."
    echo "Kept $KEPT_COUNT active worktree(s)."
    echo "Run with --clean to proceed."
else
    echo "Summary: Successfully deleted $DELETED_COUNT orphaned worktree(s), ~$total_gb GB freed."
    echo "Kept $KEPT_COUNT active worktree(s)."
fi
