#!/usr/bin/env bash
# worktree_hygiene.sh — repeatable IDENTIFY -> TRIAGE -> CLASSIFY worktree
# cleanup, formalizing the manual sweep run 2026-07-16 (bead jleechan-ue9w).
#
# 1) IDENTIFY: worktrees under each --repos entry whose most-recent file
#    mtime (excluding .git/, node_modules/, venv/, __pycache__/) is older
#    than --min-age days.
# 2) TRIAGE per candidate: uncommitted/untracked status, `git push origin
#    HEAD:<branch>` preservation (never --force; non-FF retries to a
#    backup/<branch>-<date> ref), `gh pr list` PR coverage, ahead-count and
#    merge-base vs the repo's main ref.
# 3) CLASSIFY: SAFE (zero-ahead or merged-PR-and-clean) vs NEEDS-REVIEW
#    (open PR, detached-unpushed, untracked, large diff, no merge-base,
#    unpushed-ahead, or generically dirty).
#
# Defaults to dry-run. --execute requires WORKTREE_APPROVED=1. Deletions use
# `git worktree remove --force`, never raw `rm -rf` (that leaves dangling
# worktree metadata in the main repo's .git).
#
# NEEDS-REVIEW candidates are NOT auto-filed as beads here — this script only
# classifies and reports; routing NEEDS-REVIEW output to an agent for
# bead-worthiness judgment is a deliberate separate step (that's a judgment
# call, not a deterministic git-state check, so it does not belong in bash).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/worktree_repo_discovery.sh
source "$SCRIPT_DIR/lib/worktree_repo_discovery.sh"

EXECUTE=false
MIN_AGE_DAYS=14
REPOS=()
SKIP_PUSH=false
SKIP_GH=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [--execute] [--min-age N] [--repos p1,p2,...] [--skip-push] [--skip-gh] [-h|--help]

Repeatable worktree-hygiene sweep: IDENTIFY -> TRIAGE -> CLASSIFY -> (optionally) DELETE.

Options:
  --execute     Actually delete SAFE-classified worktrees via
                'git worktree remove --force' (default: dry-run/report-only).
                Requires WORKTREE_APPROVED=1 in the environment.
  --min-age N   Minimum worktree age in days for candidacy (default: 14).
  --repos LIST  Comma-separated main repo paths to scan (default:
                CLAUDE_WORKTREE_REPOS env override, else auto-discover --
                same logic as cleanup_worktrees.sh).
  --skip-push   Skip the 'git push origin HEAD:<branch>' preservation step
                during triage (offline/test runs). push_status="skipped".
  --skip-gh     Skip the 'gh pr list' lookup during triage (offline/test
                runs). pr_state="unknown".
  -h, --help    Show this help.

Environment:
  WORKTREE_APPROVED=1      Required for --execute deletions.
  CLAUDE_WORKTREE_REPOS    Comma-separated repo paths (same as --repos).
EOF
}

# ---------------------------------------------------------------------------
# Sourceable functions (safe to `source` this file without running main).
# ---------------------------------------------------------------------------

# identify_candidates <repo_path> <min_age_days>
# Echoes newline-separated worktree paths (excluding the main worktree)
# whose most-recent non-ignored file mtime is older than min_age_days.
identify_candidates() {
    local repo_path="$1" min_age_days="$2"
    local repo_abs main_wt_abs
    repo_abs=$(cd "$repo_path" 2>/dev/null && pwd -P) || return 0
    main_wt_abs="$repo_abs"

    local porcelain
    porcelain="$(git -C "$repo_abs" worktree list --porcelain 2>/dev/null)" || return 0

    local now
    now=$(date +%s)

    local path=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            path=""
            continue
        fi
        case "$line" in
            worktree\ *)
                path="${line#worktree }"
                if [[ "$path" != "$main_wt_abs" && -d "$path" ]]; then
                    local latest_mtime
                    latest_mtime=$(find "$path" -type f \
                        -not -path '*/.git/*' \
                        -not -path '*/node_modules/*' \
                        -not -path '*/venv/*' \
                        -not -path '*/__pycache__/*' \
                        -exec stat -f '%m' {} \; 2>/dev/null | sort -rn | head -1)
                    if [[ -z "$latest_mtime" ]]; then
                        latest_mtime=$(stat -f '%m' "$path" 2>/dev/null || echo "$now")
                    fi
                    local age_days=$(( (now - latest_mtime) / 86400 ))
                    if (( age_days >= min_age_days )); then
                        echo "$path"
                    fi
                fi
                ;;
        esac
    done <<<"$porcelain"
}

# redact_url <url>
# Strips embedded credentials from a git remote URL.
redact_url() {
    local url="$1"
    # https://TOKEN@host/... or https://user:TOKEN@host/... -> https://host/...
    echo "$url" | sed -E 's#^(https?://)[^/@]+@#\1#'
}

# classify_candidate <uncommitted_count> <untracked_present:0|1> <push_status> <pr_state> <ahead_count> <has_merge_base:0|1>
# Echoes exactly one line: SAFE|<reason> or NEEDS-REVIEW|<reason>
classify_candidate() {
    local uncommitted_count="$1" untracked_present="$2" push_status="$3" \
          pr_state="$4" ahead_count="$5" has_merge_base="$6"

    if (( ahead_count == 0 && uncommitted_count == 0 && untracked_present == 0 )); then
        echo "SAFE|zero-ahead"
        return 0
    fi
    if [[ "$pr_state" == "merged" && "$uncommitted_count" -eq 0 && "$untracked_present" -eq 0 ]]; then
        echo "SAFE|merged-pr-clean"
        return 0
    fi
    if [[ "$pr_state" == "open" ]]; then
        echo "NEEDS-REVIEW|open-pr"
        return 0
    fi
    if [[ "$push_status" == "rejected-nonff" ]]; then
        echo "NEEDS-REVIEW|detached-unpushed"
        return 0
    fi
    if (( untracked_present == 1 )); then
        echo "NEEDS-REVIEW|untracked"
        return 0
    fi
    if (( uncommitted_count > 50 )); then
        echo "NEEDS-REVIEW|large-diff"
        return 0
    fi
    if (( has_merge_base == 0 )); then
        echo "NEEDS-REVIEW|no-merge-base"
        return 0
    fi
    if (( ahead_count > 0 )) && [[ "$push_status" == "no-remote" || "$push_status" == "skipped" ]]; then
        echo "NEEDS-REVIEW|unpushed-ahead"
        return 0
    fi
    echo "NEEDS-REVIEW|dirty"
}

# resolve_main_ref <repo_path>
# Echoes the best available "main" ref (origin/main preferred, else main).
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

# triage_candidate <repo_path> <wt_path> <branch>
# Echoes: <uncommitted_count>|<untracked_present>|<push_status>|<pr_state>|<ahead_count>|<has_merge_base>
triage_candidate() {
    local repo_path="$1" wt_path="$2" branch="$3"

    local status_porcelain uncommitted_count untracked_present
    status_porcelain="$(git -C "$wt_path" status --porcelain 2>/dev/null || true)"
    if [[ -z "$status_porcelain" ]]; then
        uncommitted_count=0
    else
        uncommitted_count=$(printf '%s\n' "$status_porcelain" | grep -c . || true)
    fi
    untracked_present=0
    if printf '%s\n' "$status_porcelain" | grep -qE '^\?\?'; then
        untracked_present=1
    fi

    local push_status="no-remote"
    if [[ "${SKIP_PUSH:-false}" == true ]]; then
        push_status="skipped"
    else
        if git -C "$wt_path" remote get-url origin >/dev/null 2>&1; then
            local push_rc
            git -C "$wt_path" push origin "HEAD:${branch}" >/dev/null 2>&1
            push_rc=$?
            if [[ $push_rc -eq 0 ]]; then
                push_status="pushed"
            else
                # Non-fast-forward (or any) rejection: retry to a dated
                # backup ref instead of forcing the original branch.
                local backup_ref
                backup_ref="backup/${branch}-$(date +%Y%m%d)"
                if git -C "$wt_path" push origin "HEAD:${backup_ref}" >/dev/null 2>&1; then
                    push_status="pushed"
                else
                    push_status="rejected-nonff"
                fi
            fi
        else
            push_status="no-remote"
        fi
    fi

    local pr_state="unknown"
    if [[ "${SKIP_GH:-false}" == true ]]; then
        pr_state="unknown"
    else
        local origin_url owner_repo
        origin_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"
        if [[ -n "$origin_url" ]]; then
            local safe_url
            safe_url="$(redact_url "$origin_url")"
            owner_repo="$(echo "$safe_url" | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##; s#\.git$##')"
            if [[ -n "$owner_repo" ]] && command -v gh >/dev/null 2>&1; then
                local pr_json
                pr_json="$(gh pr list --repo "$owner_repo" --head "$branch" --state all \
                    --json number,state,title 2>/dev/null || true)"
                if [[ -n "$pr_json" && "$pr_json" != "[]" ]]; then
                    if echo "$pr_json" | grep -qi '"state":"OPEN"'; then
                        pr_state="open"
                    elif echo "$pr_json" | grep -qi '"state":"MERGED"'; then
                        pr_state="merged"
                    elif echo "$pr_json" | grep -qi '"state":"CLOSED"'; then
                        pr_state="closed"
                    else
                        pr_state="none"
                    fi
                else
                    pr_state="none"
                fi
            else
                pr_state="unknown"
            fi
        else
            pr_state="unknown"
        fi
    fi

    local ahead_count=0 has_merge_base=1
    local main_ref
    if main_ref="$(resolve_main_ref "$repo_path")"; then
        if git -C "$wt_path" merge-base "$main_ref" HEAD >/dev/null 2>&1; then
            has_merge_base=1
            ahead_count="$(git -C "$wt_path" rev-list --count "${main_ref}..HEAD" 2>/dev/null || echo 0)"
        else
            has_merge_base=0
            ahead_count="$(git -C "$wt_path" rev-list --count HEAD 2>/dev/null || echo 0)"
        fi
    else
        has_merge_base=0
        ahead_count="$(git -C "$wt_path" rev-list --count HEAD 2>/dev/null || echo 0)"
    fi

    echo "${uncommitted_count}|${untracked_present}|${push_status}|${pr_state}|${ahead_count}|${has_merge_base}"
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

ledger_line() {
    local action="$1" path="$2" reason="${3:-}"
    if [[ -n "$reason" ]]; then
        printf '  LEDGER %-17s %-14s %s | %s\n' "worktree-hygiene" "$action" "$path" "$reason"
    else
        printf '  LEDGER %-17s %-14s %s\n' "worktree-hygiene" "$action" "$path"
    fi
}

branch_for_worktree() {
    local repo_path="$1" wt_path="$2"
    git -C "$repo_path" worktree list --porcelain 2>/dev/null | awk -v p="$wt_path" '
        $1 == "worktree" { cur = $2 }
        cur == p && $1 == "branch" { sub(/^refs\/heads\//, "", $2); print $2; exit }
        cur == p && $1 == "detached" { print "detached"; exit }
    '
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            --execute) EXECUTE=true ;;
            --min-age)
                [[ $# -ge 2 ]] || { echo "--min-age requires a value" >&2; exit 2; }
                MIN_AGE_DAYS="$2"
                shift
                ;;
            --repos)
                [[ $# -ge 2 ]] || { echo "--repos requires a value" >&2; exit 2; }
                IFS=',' read -ra REPOS <<<"$2"
                shift
                ;;
            --skip-push) SKIP_PUSH=true ;;
            --skip-gh) SKIP_GH=true ;;
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

    if [[ ${#REPOS[@]} -eq 0 ]]; then
        while IFS= read -r repo; do
            [[ -n "$repo" ]] && REPOS+=("$repo")
        done < <(discover_worktree_repos "${CLAUDE_WORKTREE_REPOS:-}")
    fi

    if [[ "$EXECUTE" == true ]]; then
        echo "=== WORKTREE HYGIENE ==="
        if [[ "${WORKTREE_APPROVED:-0}" != "1" ]]; then
            echo "Refusing to delete worktrees: set WORKTREE_APPROVED=1 after explicit approval."
            exit 0
        fi
    else
        echo "=== WORKTREE HYGIENE (DRY-RUN) ==="
    fi

    local safe_count=0 review_count=0 preserved_count=0

    for repo in "${REPOS[@]}"; do
        [[ -d "$repo" ]] || continue
        local repo_abs
        repo_abs=$(cd "$repo" 2>/dev/null && pwd -P) || continue

        echo ""
        echo "--- ${repo_abs} ---"

        local candidates
        candidates="$(identify_candidates "$repo_abs" "$MIN_AGE_DAYS" || true)"

        local porcelain all_paths=()
        porcelain="$(git -C "$repo_abs" worktree list --porcelain 2>/dev/null || true)"
        while IFS= read -r line; do
            case "$line" in
                worktree\ *) all_paths+=("${line#worktree }") ;;
            esac
        done <<<"$porcelain"

        for wt_path in "${all_paths[@]}"; do
            [[ "$wt_path" == "$repo_abs" ]] && continue
            [[ -d "$wt_path" ]] || continue

            if ! grep -qxF "$wt_path" <<<"$candidates"; then
                ledger_line "PRESERVE" "$wt_path" "young"
                preserved_count=$(( preserved_count + 1 ))
                continue
            fi

            local branch
            branch="$(branch_for_worktree "$repo_abs" "$wt_path")"
            [[ -n "$branch" ]] || branch="detached"

            local record
            record="$(triage_candidate "$repo_abs" "$wt_path" "$branch")"

            IFS='|' read -r uncommitted_count untracked_present push_status pr_state ahead_count has_merge_base <<<"$record"

            local verdict
            verdict="$(classify_candidate "$uncommitted_count" "$untracked_present" \
                "$push_status" "$pr_state" "$ahead_count" "$has_merge_base")"

            local class="${verdict%%|*}" reason="${verdict#*|}"

            if [[ "$class" == "SAFE" ]]; then
                ledger_line "SAFE" "$wt_path" "$reason"
                safe_count=$(( safe_count + 1 ))
                if [[ "$EXECUTE" == true ]]; then
                    ledger_line "DELETE" "$wt_path" ""
                    git -C "$repo_abs" worktree remove --force "$wt_path"
                fi
            else
                ledger_line "NEEDS-REVIEW" "$wt_path" "$reason"
                review_count=$(( review_count + 1 ))
            fi
        done
    done

    echo ""
    echo "Worktree-hygiene: ${safe_count} safe, ${review_count} needs-review, ${preserved_count} preserved (young)."
    echo "Note: NEEDS-REVIEW candidates are NOT auto-filed as beads by this script."
    echo "Route them to an agent (or manual triage) to judge bead-worthiness -- that's"
    echo "a judgment call, not a deterministic git-state check."
    if [[ "$EXECUTE" == false && "$safe_count" -gt 0 ]]; then
        echo "Run with --execute and WORKTREE_APPROVED=1 to delete the SAFE set."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
