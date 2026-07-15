#!/usr/bin/env bash
# cleanup_worktrees.sh — Orphaned Antigravity + governed repo-local Claude worktree cleanup.
#
# 1) Antigravity: scans ~/.gemini/antigravity/worktrees/ for unregistered folders (rm -rf).
# 2) Repo-local: scans configured repos via `git worktree list --porcelain`, targets
#    .claude/worktrees/, removes eligible dormant worktrees with `git worktree remove`.
#
# Defaults to dry-run. --clean requires WORKTREE_APPROVED=1.
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

DRY_RUN=true
MIN_AGE_DAYS=14
REPO_LOCAL_REPOS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--min-age N] [--repos p1,p2,...] [-h|--help]

Clean orphaned Antigravity worktrees and governed repo-local .claude/worktrees.

Options:
  --clean       Actually remove eligible worktrees (default: dry-run).
                Requires WORKTREE_APPROVED=1 in the environment.
  --dry-run     Print actions without touching disk (default).
  --min-age N   Minimum worktree age in days for repo-local removal (default: 14).
  --repos LIST  Comma-separated main repo paths (default: CLAUDE_WORKTREE_REPOS or
                \$HOME/projects/worldarchitect.ai).
  -h, --help    Show this help.

Environment:
  WORKTREE_APPROVED=1      Required for --clean deletions.
  CLAUDE_WORKTREE_REPOS    Comma-separated repo paths.
  WORKTREE_MIN_AGE_DAYS    Default for --min-age when flag omitted.
EOF
}

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        --clean) DRY_RUN=false ;;
        --dry-run) DRY_RUN=true ;;
        --min-age)
            [[ $# -ge 2 ]] || { echo "--min-age requires a value" >&2; exit 2; }
            MIN_AGE_DAYS="$2"
            shift
            ;;
        --repos)
            [[ $# -ge 2 ]] || { echo "--repos requires a value" >&2; exit 2; }
            IFS=',' read -ra REPO_LOCAL_REPOS <<<"$2"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [[ ${#REPO_LOCAL_REPOS[@]} -eq 0 ]]; then
    if [[ -n "${CLAUDE_WORKTREE_REPOS:-}" ]]; then
        IFS=',' read -ra REPO_LOCAL_REPOS <<<"${CLAUDE_WORKTREE_REPOS// /,}"
    else
        # Auto-discover main repositories that have registered worktrees
        discovered_repos_str="$HOME/projects/worldarchitect.ai"
        
        find_repos_from_worktrees() {
            local search_dir="$1"
            [[ -d "$search_dir" ]] || return 0
            while IFS= read -r git_file; do
                local gitdir_line
                gitdir_line=$(grep '^gitdir: ' "$git_file" 2>/dev/null || true)
                if [[ -n "$gitdir_line" ]]; then
                    local git_dir main_repo
                    git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
                    main_repo="${git_dir%/.git/worktrees/*}"
                    if [[ -d "$main_repo" ]]; then
                        discovered_repos_str="${discovered_repos_str} ${main_repo}"
                    fi
                fi
            done < <(find "$search_dir" -type f -name ".git" 2>/dev/null)
        }
        
        find_repos_from_worktrees "$HOME/.ao/data/worktrees"
        find_repos_from_worktrees "$HOME/.gemini/antigravity/worktrees"
        
        # Also check all .claude/worktrees and projects
        if [[ -d "$HOME/projects" ]]; then
            for repo_dir in "$HOME/projects"/*; do
                [[ -d "$repo_dir" ]] || continue
                claude_wt_dir="$repo_dir/.claude/worktrees"
                if [[ -d "$claude_wt_dir" ]]; then
                    while IFS= read -r git_file; do
                        gitdir_line=$(grep '^gitdir: ' "$git_file" 2>/dev/null || true)
                        if [[ -n "$gitdir_line" ]]; then
                            git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
                            main_repo="${git_dir%/.git/worktrees/*}"
                            if [[ -d "$main_repo" ]]; then
                                discovered_repos_str="${discovered_repos_str} ${main_repo}"
                            fi
                        fi
                    done < <(find "$claude_wt_dir" -type f -name ".git" 2>/dev/null)
                fi
            done
        fi
        
        # Dedup the repository list using tr/sort/uniq
        if [[ -n "$discovered_repos_str" ]]; then
            while IFS= read -r repo; do
                [[ -n "$repo" ]] && REPO_LOCAL_REPOS+=("$repo")
            done < <(echo "$discovered_repos_str" | tr ' ' '\n' | sort -u)
        fi
    fi
fi

if [[ -n "${WORKTREE_MIN_AGE_DAYS:-}" && "$MIN_AGE_DAYS" == 14 && "$#" -eq 0 ]]; then
    MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS}"
fi

WORKTREE_ROOT="${HOME}/.gemini/antigravity/worktrees"
CLAUDE_WORKTREE_MARKER="/.claude/worktrees/"

if [[ "$DRY_RUN" == true ]]; then
    echo "=== WORKTREE CLEANUP (DRY-RUN) ==="
else
    echo "=== WORKTREE CLEANUP ==="
    if [[ "${WORKTREE_APPROVED:-0}" != "1" ]]; then
        echo "Refusing to delete worktrees: set WORKTREE_APPROVED=1 after explicit approval."
        exit 0
    fi
fi

TOTAL_RECLAIMED_KB=0
ANTIGRAVITY_DELETED=0
ANTIGRAVITY_KEPT=0
REPO_LOCAL_ELIGIBLE=0
REPO_LOCAL_PRESERVED=0

expand_path() {
    local p="$1"
    if [[ "$p" == "~/"* ]]; then
        printf '%s\n' "${HOME}/${p:2}"
    elif [[ "$p" == "~" ]]; then
        printf '%s\n' "$HOME"
    else
        printf '%s\n' "$p"
    fi
}

size_kb() {
    local path="$1"
    [[ -e "$path" ]] || { echo 0; return; }
    du -sk "$path" 2>/dev/null | awk '{print $1+0}'
}

fmt_kb() {
    local kb="${1:-0}"
    awk "BEGIN{
        if ($kb >= 1048576)  printf \"%.1fG\", $kb / 1048576
        else if ($kb >= 1024) printf \"%.0fM\", $kb / 1024
        else                  printf \"%dK\", $kb
    }"
}

worktree_age_days() {
    local wt_path="$1"
    local mtime_epoch
    mtime_epoch=$(stat -f '%m' "$wt_path/.git" 2>/dev/null || true)
    if [[ -z "$mtime_epoch" ]]; then
        mtime_epoch=$(stat -f '%m' "$wt_path" 2>/dev/null || true)
    fi
    [[ -n "$mtime_epoch" ]] || return 1
    local now
    now=$(date +%s)
    echo $(( (now - mtime_epoch) / 86400 ))
}

resolve_main_ref() {
    local repo="$1"
    if git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
        echo "origin/main"
        return 0
    fi
    if git -C "$repo" rev-parse --verify --quiet main >/dev/null 2>&1; then
        echo "main"
        return 0
    fi
    return 1
}

classify_repo_local_worktree() {
    local repo="$1" wt_path="$2" head_sha="$3" locked="$4" prunable="$5"

    local age_days
    if ! age_days="$(worktree_age_days "$wt_path")"; then
        echo "age-unknown"
        return 0
    fi

    local min_age=$MIN_AGE_DAYS
    if [[ "$wt_path" == *"/.ao/data/worktrees/"* || "$wt_path" == *"/ao/data/worktrees/"* ]]; then
        min_age=1
    fi

    if [[ "$locked" == "1" ]]; then
        # Stale lock detection: only auto-unlock automated/orchestrator worktrees
        local is_automated=false
        if [[ "$wt_path" == *"/.ao/data/worktrees/"* || \
              "$wt_path" == *"/ao/data/worktrees/"* || \
              "$wt_path" == *"/antigravity/worktrees/"* ]]; then
            is_automated=true
        fi

        if [[ "$is_automated" == "true" ]] && (( age_days >= min_age )); then
            if [[ "$DRY_RUN" == false ]]; then
                git -C "$repo" worktree unlock "$wt_path" 2>/dev/null || true
            fi
        else
            echo "locked"
            return 0
        fi
    fi

    if [[ "$prunable" == "1" ]]; then
        echo "prunable-unknown"
        return 0
    fi

    if (( age_days < min_age )); then
        echo "young"
        return 0
    fi

    local status_porcelain
    status_porcelain="$(git -C "$wt_path" status --porcelain 2>/dev/null || true)"
    if [[ -n "$status_porcelain" ]]; then
        if grep -qE '^(\?\?|!!)' <<<"$status_porcelain"; then
            echo "untracked"
            return 0
        fi
        if grep -qE '^[ MADRCU?][ MADRCU?]' <<<"$status_porcelain"; then
            echo "dirty"
            return 0
        fi
    fi

    local main_ref
    if ! main_ref="$(resolve_main_ref "$repo")"; then
        echo "main-ref-missing"
        return 0
    fi

    if ! git -C "$repo" merge-base --is-ancestor "$head_sha" "$main_ref" 2>/dev/null; then
        local ahead_count
        ahead_count="$(git -C "$repo" rev-list --count "$main_ref..$head_sha" 2>/dev/null || echo 0)"
        if [[ "$ahead_count" -gt 0 ]]; then
            echo "ahead-of-main"
        else
            echo "non-ancestor"
        fi
        return 0
    fi

    echo ""
}

ledger_line() {
    local scope="$1" action="$2" path="$3" reason="${4:-}" extra="${5:-}"
    if [[ -n "$reason" ]]; then
        printf '  LEDGER %-12s %-9s %s | %s%s\n' "$scope" "$action" "$path" "$reason" "$extra"
    else
        printf '  LEDGER %-12s %-9s %s%s\n' "$scope" "$action" "$path" "$extra"
    fi
}

is_worktree_active() {
    local wt_path="$1"
    local git_file="$wt_path/.git"
    [[ -f "$git_file" ]] || return 1
    local gitdir_line
    gitdir_line=$(grep '^gitdir: ' "$git_file" 2>/dev/null || true)
    [[ -n "$gitdir_line" ]] || return 1
    local git_dir main_repo
    git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
    main_repo="${git_dir%/.git/worktrees/*}"
    [[ -d "$main_repo" ]] || return 1
    git -C "$main_repo" worktree list --porcelain 2>/dev/null | grep -qF "^worktree ${wt_path}$"
}

if [[ -d "$WORKTREE_ROOT" ]]; then
    echo ""
    echo "--- Antigravity orphans ($WORKTREE_ROOT) ---"
    for parent_dir in "$WORKTREE_ROOT"/*; do
        [[ -d "$parent_dir" ]] || continue
        for subdir in "$parent_dir"/*; do
            [[ -d "$subdir" ]] || continue
            abs_subdir=$(cd "$subdir" && pwd -P)
            if is_worktree_active "$abs_subdir"; then
                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "active"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                continue
            fi
            local_kb=$(size_kb "$abs_subdir")
            local_mb=$(( local_kb / 1024 ))
            if ! _safety_reason="$(safety_gate "$abs_subdir")"; then
                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "safety.local: $_safety_reason"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                continue
            fi
            if [[ "$DRY_RUN" == true ]]; then
                ledger_line "antigravity" "ELIGIBLE" "$abs_subdir" "" " (~${local_mb}M, rm -rf orphan)"
                TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + local_kb ))
                ANTIGRAVITY_DELETED=$(( ANTIGRAVITY_DELETED + 1 ))
            else
                ledger_line "antigravity" "DELETE" "$abs_subdir" "" " (~${local_mb}M)"
                rm -rf "$abs_subdir"
                TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + local_kb ))
                ANTIGRAVITY_DELETED=$(( ANTIGRAVITY_DELETED + 1 ))
            fi
        done
    done
else
    echo ""
    echo "--- Antigravity orphans: root missing ($WORKTREE_ROOT), skipping ---"
fi

process_repo_local_worktrees() {
    local repo="$1"
    local repo_abs main_wt_path

    if [[ ! -d "$repo/.git" && ! -f "$repo/.git" ]]; then
        echo "  Repo missing or not a git checkout, skipping: $repo"
        return 0
    fi

    repo_abs=$(cd "$repo" && pwd -P)
    main_wt_path="$repo_abs"

    echo ""
    echo "--- Repo-local .claude/worktrees ($repo_abs) ---"

    local porcelain
    if ! porcelain="$(git -C "$repo_abs" worktree list --porcelain 2>/dev/null)"; then
        echo "  git worktree list failed for $repo_abs"
        return 0
    fi

    local wt_path="" head_sha="" branch="" locked=0 prunable=0
    flush_block() {
        [[ -n "$wt_path" ]] || return 0

        local abs_path
        abs_path=$(expand_path "$wt_path")

        local match=false
        if [[ "$abs_path" == *"/.claude/worktrees/"* || \
              "$abs_path" == *"/.ao/data/worktrees/"* || \
              "$abs_path" == *"/ao/data/worktrees/"* || \
              "$abs_path" == *"/antigravity/worktrees/"* || \
              "$(basename "$abs_path")" == wt-* ]]; then
            match=true
        fi

        if [[ "$match" == false ]]; then
            wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
            return 0
        fi
        if [[ "$abs_path" == "$main_wt_path" ]]; then
            wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
            return 0
        fi

        local reason size_kb_val size_fmt branch_label extra age_label
        reason="$(classify_repo_local_worktree "$repo_abs" "$abs_path" "$head_sha" "$locked" "$prunable")"
        size_kb_val=$(size_kb "$abs_path")
        size_fmt=$(fmt_kb "$size_kb_val")
        branch_label="${branch:-detached}"
        age_label=$(worktree_age_days "$abs_path" 2>/dev/null || echo '?')
        extra=" | age=${age_label}d size=${size_fmt} head=${head_sha:0:8} branch=${branch_label}"

        if [[ -z "$reason" ]] && ! _safety_reason="$(safety_gate "$abs_path")"; then
            reason="safety.local: $_safety_reason"
        fi
        if [[ -n "$reason" ]]; then
            ledger_line "repo-local" "PRESERVE" "$abs_path" "$reason" "$extra"
            REPO_LOCAL_PRESERVED=$(( REPO_LOCAL_PRESERVED + 1 ))
        else
            if [[ "$DRY_RUN" == true ]]; then
                ledger_line "repo-local" "ELIGIBLE" "$abs_path" "" "$extra"
            else
                ledger_line "repo-local" "DELETE" "$abs_path" "" "$extra"
                git -C "$repo_abs" worktree remove --force --force "$abs_path"
            fi
            TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + size_kb_val ))
            REPO_LOCAL_ELIGIBLE=$(( REPO_LOCAL_ELIGIBLE + 1 ))
        fi

        wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            flush_block
            continue
        fi
        case "$line" in
            worktree\ *)
                flush_block
                wt_path="${line#worktree }"
                ;;
            HEAD\ *)
                head_sha="${line#HEAD }"
                ;;
            branch\ *)
                branch="${line#branch refs/heads/}"
                ;;
            detached)
                branch="detached"
                ;;
            locked)
                locked=1
                ;;
            prunable*)
                prunable=1
                ;;
        esac
    done <<<"$porcelain"
    flush_block
}

for repo in "${REPO_LOCAL_REPOS[@]}"; do
    process_repo_local_worktrees "$repo"
done

total_gb=$(awk "BEGIN {printf \"%.2f\", $TOTAL_RECLAIMED_KB / 1048576}")

echo ""
echo "=== Summary ==="
echo "Antigravity: ${ANTIGRAVITY_DELETED} eligible orphan(s), ${ANTIGRAVITY_KEPT} active preserved."
echo "Repo-local:  ${REPO_LOCAL_ELIGIBLE} eligible, ${REPO_LOCAL_PRESERVED} preserved."
echo "Reclaimable: ~${total_gb} GB (${TOTAL_RECLAIMED_KB} KB)"
if [[ "$DRY_RUN" == true ]]; then
    echo "Run with --clean and WORKTREE_APPROVED=1 to proceed."
fi
