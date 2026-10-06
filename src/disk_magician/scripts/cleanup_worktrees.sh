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
# shellcheck source=scripts/lib/worktree_recency.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/worktree_repo_discovery.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_repo_discovery.sh"
# shellcheck source=scripts/lib/layout_standard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/layout_standard.sh"

DRY_RUN=true
MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-7}"
REPO_LOCAL_REPOS=()

usage() {
  cat <<'EOF'
Usage: cleanup_worktrees.sh [--clean] [--dry-run] [--min-age N] [--days N] [--repos p1,p2,...] [-h|--help]

Safely prunes stale linked git worktrees (default: >=7 days old, merged or pristine).

Options:
  --clean       Actually remove eligible worktrees (default: dry-run).
                Requires WORKTREE_APPROVED=1 in the environment.
  --dry-run     Print actions without touching disk (default).
  --min-age N   Minimum worktree age in days for repo-local removal (default: 7).
  --days N      Alias for --min-age N.
  --repos LIST  Comma-separated main repo paths (default: CLAUDE_WORKTREE_REPOS or
                $HOME/projects/worldarchitect.ai).
  -h, --help    Show this help.

Environment:
  WORKTREE_APPROVED=1      Required for --clean deletions.
  CLAUDE_WORKTREE_REPOS    Comma-separated repo paths.
  WORKTREE_MIN_AGE_DAYS    Default for --min-age when flag omitted (default: 7).
EOF
}

while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        --clean) DRY_RUN=false ;;
        --dry-run) DRY_RUN=true ;;
        --min-age|--days)
            [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
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
        while IFS= read -r repo; do
            [[ -n "$repo" ]] && REPO_LOCAL_REPOS+=("$repo")
        done < <(discover_worktree_repos)
    fi
fi

# Hard floor: 7 days, may only be raised (env, CLI, or config), never
# lowered (CLAUDE.md invariant). Without this clamp, WORKTREE_MIN_AGE_DAYS=0
# or --min-age 0 would delete every dormant worktree regardless of age.
# Normalize via 10# BEFORE clamping: bash's `-lt`/`(( ))` parse a leading-
# zero numeral like "08" as octal (invalid digit -> arithmetic error), which
# would otherwise propagate as a fail-open crash into every downstream
# comparison, not just this clamp (found live by both /advice reviewers).
if [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]]; then
  MIN_AGE_DAYS=$((10#$MIN_AGE_DAYS))
else
  MIN_AGE_DAYS=7
fi
[[ "$MIN_AGE_DAYS" -lt 7 ]] && MIN_AGE_DAYS=7

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

# Age comes from scripts/lib/worktree_recency.sh (sourced at the top of this
# file), which measures real activity — newest non-pruned file in the tree plus
# git admin-dir writes — and fails closed to age 0 when it cannot tell.
# This used to stat `<wt>/.git`, which for a linked worktree is a static
# `gitdir:` pointer written once at creation, so it reported creation age and
# marked actively-edited worktrees deletable. See that file's header for the
# measured false-old rate on this machine.

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

# list_has_parent_of <path> <list>: some list entry contains path.
# list_has_child_of <path> <list>: some list entry is inside path.
list_has_parent_of() {
    P="$1" awk 'length($0) && (ENVIRON["P"] == $0 || index(ENVIRON["P"], $0 "/") == 1) {f=1; exit} END {exit !f}' <<<"$2"
}
list_has_line() {
    P="$1" awk 'length($0) && $0 == ENVIRON["P"] {f=1; exit} END {exit !f}' <<<"$2"
}
list_has_child_of() {
    P="$1" awk 'length($0) && ($0 == ENVIRON["P"] || index($0, ENVIRON["P"] "/") == 1) {f=1; exit} END {exit !f}' <<<"$2"
}

# Machine-wide live process CWD snapshot (fail-closed): if lsof fails, or returns
# an incomplete, unparseable, or unresolved observation (e.g. readlink/stat permission
# errors in /proc), or if stderr cannot be captured via temp file, cwd is unknown
# and live-process protection preserves candidates across all worktree roots.
GLOBAL_LIVE_CWDS=""
GLOBAL_CWD_BLOCKED=""
_lsof_bin="$(command -v lsof 2>/dev/null || echo /usr/sbin/lsof)"
if [[ ! -x "$_lsof_bin" ]]; then
    GLOBAL_CWD_BLOCKED="cwd-unknown"
else
    _lsof_tmp="$(mktemp -t lsof_err.XXXXXX 2>/dev/null || echo "")"
    if [[ -z "$_lsof_tmp" || ! -f "$_lsof_tmp" ]]; then
        GLOBAL_CWD_BLOCKED="cwd-unknown"
    else
        _lsof_rc=0
        _lsof_out="$("$_lsof_bin" -d cwd -Fn 2>"$_lsof_tmp")" || _lsof_rc=$?
        if ! _lsof_err="$(cat "$_lsof_tmp" 2>/dev/null)"; then
            rm -f "$_lsof_tmp"
            GLOBAL_CWD_BLOCKED="cwd-unknown"
        else
            rm -f "$_lsof_tmp"
            if [[ "$_lsof_rc" -ne 0 ]]; then
                GLOBAL_CWD_BLOCKED="cwd-unknown"
            elif [[ -n "$_lsof_err" ]] && grep -qiE 'warning|permission denied|cannot|error' <<<"$_lsof_err"; then
                GLOBAL_CWD_BLOCKED="cwd-unknown"
            elif [[ -z "$_lsof_out" ]]; then
                GLOBAL_CWD_BLOCKED="cwd-unknown"
            elif grep -qiE '\(readlink:|\(stat:|\(lstat:|permission denied|/proc/[0-9]+/cwd' <<<"$_lsof_out"; then
                GLOBAL_CWD_BLOCKED="cwd-unknown"
            elif grep -qE '^n[^/]' <<<"$_lsof_out"; then
                GLOBAL_CWD_BLOCKED="cwd-unknown"
            else
                GLOBAL_LIVE_CWDS="$(sed -n 's/^n\(\/.*\)$/\1/p' <<<"$_lsof_out")"
                if [[ -z "$GLOBAL_LIVE_CWDS" ]]; then
                    GLOBAL_CWD_BLOCKED="cwd-unknown"
                fi
            fi
        fi
    fi
fi

classify_repo_local_worktree() {
    local repo="$1" wt_path="$2" head_sha="$3" locked="$4" prunable="$5" branch="${6:-}"

    # Fail-closed live process protection: never touch a worktree whose path
    # (or physical realpath) is currently the cwd of any running process,
    # or if lsof failed.
    local real_wt
    real_wt="$(cd "$wt_path" 2>/dev/null && pwd -P || printf '%s' "$wt_path")"
    if [[ -n "$GLOBAL_CWD_BLOCKED" ]]; then
        echo "$GLOBAL_CWD_BLOCKED"
        return 0
    fi
    if list_has_child_of "$real_wt" "$GLOBAL_LIVE_CWDS" || list_has_child_of "$wt_path" "$GLOBAL_LIVE_CWDS"; then
        echo "live-cwd"
        return 0
    fi

    local age_days
    if ! age_days="$(worktree_age_days "$wt_path")"; then
        echo "age-unknown"
        return 0
    fi

    local min_age=$MIN_AGE_DAYS

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
            local branch_clean="${branch#refs/heads/}"
            if [[ -n "$branch_clean" && "$branch_clean" != "detached" ]] && command -v gh >/dev/null 2>&1; then
                local origin_url owner_repo
                origin_url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
                if [[ -n "$origin_url" ]]; then
                    owner_repo="$(echo "$origin_url" | sed -E 's#^(https?://)[^/@]+@#\1#; s#^(https?://[^/]+/|git@[^:]+:)##; s#\.git$##')"
                    if [[ -n "$owner_repo" ]]; then
                        local pr_heads gh_rc=0
                        pr_heads="$(env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh pr list --repo "$owner_repo" --head "$branch_clean" --state MERGED --json headRefOid -q '.[].headRefOid' 2>/dev/null)" || gh_rc=$?
                        if [[ "$gh_rc" -eq 0 && -n "$pr_heads" && -n "$head_sha" ]]; then
                            if grep -qFx "$head_sha" <<<"$pr_heads"; then
                                return 0
                            else
                                echo "merged-differing-head"
                                return 0
                            fi
                        fi
                    fi
                fi
            fi
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
            if worktree_is_recently_active "$abs_subdir" "$MIN_AGE_DAYS"; then
                age_label=$(worktree_age_days "$abs_subdir" 2>/dev/null || echo '?')
                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "young" " (age=${age_label}d < ${MIN_AGE_DAYS}d)"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                continue
            fi
            if [[ -n "$GLOBAL_CWD_BLOCKED" ]]; then
                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "$GLOBAL_CWD_BLOCKED"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                continue
            fi
            if list_has_child_of "$abs_subdir" "$GLOBAL_LIVE_CWDS"; then
                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "live-cwd"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                continue
            fi
            if [[ -e "$abs_subdir/.git" ]]; then
                local status_porcelain
                status_porcelain="$(git -C "$abs_subdir" status --porcelain 2>/dev/null || true)"
                if [[ -n "$status_porcelain" ]]; then
                    if grep -qE '^(\?\?|!!)' <<<"$status_porcelain"; then
                        ledger_line "antigravity" "PRESERVE" "$abs_subdir" "untracked"
                        ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                        continue
                    fi
                    if grep -qE '^[ MADRCU?][ MADRCU?]' <<<"$status_porcelain"; then
                        ledger_line "antigravity" "PRESERVE" "$abs_subdir" "dirty"
                        ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                        continue
                    fi
                fi

                local ag_main_repo=""
                if [[ -f "$abs_subdir/.git" ]]; then
                    local gitdir_line
                    gitdir_line=$(grep '^gitdir: ' "$abs_subdir/.git" 2>/dev/null || true)
                    local git_dir
                    git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
                    ag_main_repo="${git_dir%/.git/worktrees/*}"
                elif [[ -d "$abs_subdir/.git" ]]; then
                    ag_main_repo="$abs_subdir"
                fi
                if [[ -n "$ag_main_repo" && -d "$ag_main_repo" ]]; then
                    local main_ref
                    if main_ref="$(resolve_main_ref "$ag_main_repo" 2>/dev/null)"; then
                        local head_sha
                        head_sha="$(git -C "$abs_subdir" rev-parse HEAD 2>/dev/null || true)"
                        if [[ -n "$head_sha" ]] && ! git -C "$ag_main_repo" merge-base --is-ancestor "$head_sha" "$main_ref" 2>/dev/null; then
                            local ahead_count
                            ahead_count="$(git -C "$ag_main_repo" rev-list --count "$main_ref..$head_sha" 2>/dev/null || echo 0)"
                            if [[ "$ahead_count" -gt 0 ]]; then
                                local branch
                                branch="$(git -C "$abs_subdir" symbolic-ref HEAD 2>/dev/null || echo "detached")"
                                local branch_clean="${branch#refs/heads/}"
                                local eligible_by_pr=false
                                if [[ -n "$branch_clean" && "$branch_clean" != "detached" ]] && command -v gh >/dev/null 2>&1; then
                                    local origin_url owner_repo
                                    origin_url="$(git -C "$ag_main_repo" remote get-url origin 2>/dev/null || true)"
                                    if [[ -n "$origin_url" ]]; then
                                        owner_repo="$(echo "$origin_url" | sed -E 's#^(https?://)[^/@]+@#\1#; s#^(https?://[^/]+/|git@[^:]+:)##; s#\.git$##')"
                                        if [[ -n "$owner_repo" ]]; then
                                            local pr_heads gh_rc=0
                                            pr_heads="$(env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh pr list --repo "$owner_repo" --head "$branch_clean" --state MERGED --json headRefOid -q '.[].headRefOid' 2>/dev/null)" || gh_rc=$?
                                            if [[ "$gh_rc" -eq 0 && -n "$pr_heads" && -n "$head_sha" ]]; then
                                                if grep -qFx "$head_sha" <<<"$pr_heads"; then
                                                    eligible_by_pr=true
                                                else
                                                    ledger_line "antigravity" "PRESERVE" "$abs_subdir" "merged-differing-head"
                                                    ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                                                    continue
                                                fi
                                            fi
                                        fi
                                    fi
                                fi
                                if [[ "$eligible_by_pr" == false ]]; then
                                    ledger_line "antigravity" "PRESERVE" "$abs_subdir" "ahead-of-main"
                                    ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                                    continue
                                fi
                            else
                                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "non-ancestor"
                                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                                continue
                            fi
                        fi
                    fi
                fi
            fi
            local_kb=$(size_kb "$abs_subdir")
            local_mb=$(( local_kb / 1024 ))
            if [[ "$DRY_RUN" == true ]]; then
                ledger_line "antigravity" "ELIGIBLE" "$abs_subdir" "" " (~${local_mb}M, rm -rf orphan)"
                TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + local_kb ))
                ANTIGRAVITY_DELETED=$(( ANTIGRAVITY_DELETED + 1 ))
            else
                ledger_line "antigravity" "DELETE" "$abs_subdir" "" " (~${local_mb}M)"
                if ! _safety_reason="$(safety_gate "$abs_subdir" 2>/dev/null)"; then
                  echo "SAFETY-SKIP "$abs_subdir" ($_safety_reason)"
                else
                  rm -rf "$abs_subdir"
                fi
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
        local base_name
        base_name="$(basename "$abs_path")"
        if [[ "$abs_path" == *"/.claude/worktrees/"* || \
              "$abs_path" == *"/.ao/data/worktrees/"* || \
              "$abs_path" == *"/ao/data/worktrees/"* || \
              "$abs_path" == *"/antigravity/worktrees/"* || \
              "$base_name" == wt-* || \
              "$base_name" == wt_* || \
              "$base_name" == worktree_* || \
              "$base_name" == worktree-* ]]; then
            match=true
        fi
        local std_real=""
        if [[ "$abs_path" == "$STD_ROOT/"* || "$abs_path" == "$STD_ROOT_REAL/"* ]]; then
            match=true
            std_real="$(cd "$abs_path" 2>/dev/null && pwd -P || printf '%s' "$abs_path")"
        fi

        if [[ "$match" == false ]]; then
            wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
            return 0
        fi
        if [[ "$abs_path" == "$main_wt_path" ]]; then
            wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
            return 0
        fi

        if [[ -n "$std_real" ]]; then
            local std_skip
            std_skip="$(std_root_skip_reason "$abs_path" "$std_real")"
            if [[ -n "$std_skip" ]]; then
                ledger_line "repo-local" "PRESERVE" "$abs_path" "$std_skip"
                REPO_LOCAL_PRESERVED=$(( REPO_LOCAL_PRESERVED + 1 ))
                wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
                return 0
            fi
        fi

        local reason size_kb_val size_fmt branch_label extra age_label
        reason="$(classify_repo_local_worktree "$repo_abs" "$abs_path" "$head_sha" "$locked" "$prunable" "$branch")"
        size_kb_val=$(size_kb "$abs_path")
        size_fmt=$(fmt_kb "$size_kb_val")
        branch_label="${branch:-detached}"
        age_label=$(worktree_age_days "$abs_path" 2>/dev/null || echo '?')
        extra=" | age=${age_label}d size=${size_fmt} head=${head_sha:0:8} branch=${branch_label}"

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

# Standard root (spec D6): governed like other agent roots, except worktrees
# under an AO worktreeDir (AO owns those sessions) or that a live process has
# as cwd. One lsof snapshot per run; if it fails, the whole root is skipped.
STD_ROOT="${STANDARD_WORKTREE_ROOT%/}"
STD_ROOT_REAL="$(cd "$STD_ROOT" 2>/dev/null && pwd -P || printf '%s' "$STD_ROOT")"
STD_AO_DIRS=""      # AO owns everything under these
STD_AO_PARENTS=""   # AO owns direct children of these (<default>/<sessionId>)
STD_BLOCKED=""
STD_LIVE_CWDS=""
# ao_worktree_dirs <yaml>: per-project worktreeDir -> "P <dir>". The top-level
# default (column 0, the live config sets it to ~/.worktrees) is NOT owned
# whole: projects lacking their own worktreeDir get "P <default>/<key>" and
# "P <default>/<basename path>", and "C <default>" covers <default>/<session>.
ao_worktree_dirs() {
    awk '
        function val(l) { sub(/^[^:]*:[[:space:]]*/, "", l); sub(/[[:space:]]+#.*$/, "", l)
                          gsub(/["\047]/, "", l); sub(/[[:space:]]+$/, "", l); return l }
        /^[^[:space:]#]/ { inproj = ($0 ~ /^projects:/); key = "" }
        /^worktreeDir:/ { def = val($0); next }
        inproj && /^  [^[:space:]#][^:]*:[[:space:]]*$/ { key = $1; sub(/:$/, "", key); keys[++n] = key; next }
        /^[[:space:]]+worktreeDir:/ { d = val($0); if (d != "") print "P " d; if (key != "") own[key] = 1; next }
        key != "" && /^    path:/ { p = val($0); sub(/\/+$/, "", p); sub(/.*\//, "", p); base[key] = p }
        END {
            if (def == "") exit
            sub(/\/+$/, "", def); print "C " def
            for (i = 1; i <= n; i++) if (!own[keys[i]]) {
                print "P " def "/" keys[i]
                if (base[keys[i]] != "") print "P " def "/" base[keys[i]]
            }
        }' "$1"
}
if [[ -d "$STD_ROOT" ]]; then
    ao_cfg="${DISK_MAGICIAN_AO_CONFIG:-$HOME/.hermes/agent-orchestrator.yaml}"
    if [[ -e "$ao_cfg" ]]; then
        if ao_lines="$(ao_worktree_dirs "$ao_cfg" 2>/dev/null)"; then
            while read -r kind d; do
                [[ -n "$d" ]] || continue
                d="$(expand_path "$d")"
                d="$d"$'\n'"$(cd "$d" 2>/dev/null && pwd -P || printf '%s' "$d")"$'\n'
                if [[ "$kind" == C ]]; then STD_AO_PARENTS+="$d"; else STD_AO_DIRS+="$d"; fi
            done <<<"$ao_lines"
        else
            STD_BLOCKED="ao-config-unreadable"
        fi
    fi
fi

# std_root_skip_reason <abs> <real>: prints why a standard-root worktree is off-limits.
std_root_skip_reason() {
    if [[ -n "$STD_BLOCKED" ]]; then
        echo "$STD_BLOCKED"
    elif list_has_parent_of "$1" "$STD_AO_DIRS" || list_has_parent_of "$2" "$STD_AO_DIRS" \
        || list_has_line "${1%/*}" "$STD_AO_PARENTS" || list_has_line "${2%/*}" "$STD_AO_PARENTS"; then
        echo "ao-owned"
    elif [[ -n "$GLOBAL_CWD_BLOCKED" ]]; then
        echo "$GLOBAL_CWD_BLOCKED"
    elif list_has_child_of "$2" "$GLOBAL_LIVE_CWDS" || list_has_child_of "$1" "$GLOBAL_LIVE_CWDS"; then
        echo "live-cwd"
    fi
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
