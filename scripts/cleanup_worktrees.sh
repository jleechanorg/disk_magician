#!/usr/bin/env bash
# cleanup_worktrees.sh — Orphaned Antigravity + governed repo-local Claude worktree cleanup.
#
# 1) Antigravity: scans ~/.gemini/antigravity/worktrees/ for unregistered folders (rm -rf).
# 2) Repo-local: scans configured repos via `git worktree list --porcelain`, targets
#    .claude/worktrees/, removes eligible dormant worktrees with `git worktree remove`.
#
# Defaults to dry-run. --clean requires WORKTREE_APPROVED=1.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/lsof_linux.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lsof_linux.sh"
# shellcheck source=scripts/lib/worktree_repo_discovery.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_repo_discovery.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ao_worktree_config.sh"
# shellcheck source=scripts/lib/worktree_merged_pr.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_merged_pr.sh"
# shellcheck source=scripts/lib/layout_standard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/layout_standard.sh"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_ignored.sh"
# shellcheck source=scripts/lib/quarantine.sh
# Brings artifact_removal_verdict (via artifact_verdict.sh) and, transitively,
# wrh_remove_now (worktree_remove_hook.sh) for the C14 -> WRH removal route.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/quarantine.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/actuator_deadline.sh"
act_parse_deadline_args "$@" || exit $?
if ((${#ACT_ARGS[@]})); then set -- "${ACT_ARGS[@]}"; else set --; fi
[[ -z "$ACT_DEADLINE_AT" || -n "$ACT_CURSOR" ]] || { echo "--deadline-at requires --cursor" >&2; exit 2; }

DRY_RUN=true
MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-3}"
REPO_LOCAL_REPOS=()
# Cache allocation is optional: disk-pressure failures retain the existing
# per-row lookup and lsof fail-closed behavior rather than aborting the run.
RUN_TMP="$(mktemp -d)" || RUN_TMP=""
if [[ -n "$RUN_TMP" && -d "$RUN_TMP" ]]; then
    trap 'rm -rf "$RUN_TMP"' EXIT
fi

usage() {
  cat <<'EOF'
Usage: cleanup_worktrees.sh [--clean] [--dry-run] [--min-age N] [--days N] [--repos p1,p2,...] [-h|--help]

Safely prunes stale linked git worktrees (default: >=3 days old, merged or pristine).

Options:
  --clean       Actually remove eligible worktrees (default: dry-run).
                Requires WORKTREE_APPROVED=1 in the environment.
  --dry-run     Print actions without touching disk (default).
  --min-age N   Minimum worktree age in days for repo-local removal (default: 3).
  --days N      Alias for --min-age N.
  --repos LIST  Comma-separated main repo paths (default: CLAUDE_WORKTREE_REPOS or
                $HOME/projects/worldarchitect.ai).
  -h, --help    Show this help.

Environment:
  WORKTREE_APPROVED=1      Required for --clean deletions.
  CLAUDE_WORKTREE_REPOS    Comma-separated repo paths.
  WORKTREE_MIN_AGE_DAYS    Default for --min-age when flag omitted (default: 3).
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

# Staleness floor: safety_worktree_floor_days (default and minimum 3 days; the
# configured worktree_min_stale_days may only RAISE it).
staleness_floor=$(safety_worktree_floor_days 2>/dev/null || echo 3)
if [[ "$staleness_floor" =~ ^[0-9]+$ ]]; then
  staleness_floor=$((10#$staleness_floor))
else
  staleness_floor=3
fi
[[ "$staleness_floor" -lt 3 ]] && staleness_floor=3

# Hard floor: staleness_floor days, may only be raised (env, CLI, or config), never
# lowered (CLAUDE.md invariant). Without this clamp, WORKTREE_MIN_AGE_DAYS=0
# or --min-age 0 would delete every dormant worktree regardless of age.
# Normalize via 10# BEFORE clamping: bash's `-lt`/`(( ))` parse a leading-
# zero numeral like "08" as octal (invalid digit -> arithmetic error), which
# would otherwise propagate as a fail-open crash into every downstream
# comparison, not just this clamp (found live by both /advice reviewers).
if [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]]; then
  MIN_AGE_DAYS=$((10#$MIN_AGE_DAYS))
else
  MIN_AGE_DAYS="$staleness_floor"
fi
[[ "$MIN_AGE_DAYS" -lt "$staleness_floor" ]] && MIN_AGE_DAYS="$staleness_floor"

# Bead plf: merged + clean worktrees use this floor instead; clamped to [3,7].
MERGED_MIN_DAYS="${DISK_MAGICIAN_MERGED_WORKTREE_MIN_DAYS:-3}"
if [[ "$MERGED_MIN_DAYS" =~ ^[0-9]+$ ]]; then
  MERGED_MIN_DAYS=$((10#$MERGED_MIN_DAYS))
else
  MERGED_MIN_DAYS=7
fi
[[ "$MERGED_MIN_DAYS" -lt 3 ]] && MERGED_MIN_DAYS=3
[[ "$MERGED_MIN_DAYS" -gt 7 ]] && MERGED_MIN_DAYS=7

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
echo "Merged clean worktree floor: ${MERGED_MIN_DAYS}d (others: ${MIN_AGE_DAYS}d)"

TOTAL_RECLAIMED_KB=0
ANTIGRAVITY_DELETED=0
ANTIGRAVITY_KEPT=0
REPO_LOCAL_ELIGIBLE=0
REPO_LOCAL_PRESERVED=0
ACT_STOP=0
ACT_DEFERRED_COUNT=0
ACT_INTERRUPTED_COUNT=0
ACT_CURSOR_INDEX=0
ACT_CURSOR_ITEMS='[]'
ACT_REPO_SCOPE=""
if ((${#REPO_LOCAL_REPOS[@]})); then ACT_REPO_SCOPE="$(printf '%s,' "${REPO_LOCAL_REPOS[@]}")"; fi
ACT_CURSOR_SOURCE="cleanup_worktrees|root=${WORKTREE_ROOT}|repos=${ACT_REPO_SCOPE}"
if [[ -n "$ACT_CURSOR" ]]; then
    ACT_CURSOR_STATE="$(act_cursor_load "$ACT_CURSOR" "$ACT_CURSOR_SOURCE")" || {
        echo "invalid cleanup_worktrees cursor" >&2; exit 3;
    }
    ACT_CURSOR_ITEMS="$(printf '%s' "$ACT_CURSOR_STATE" | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["items"],separators=(",",":")))')"
    ACT_CURSOR_INDEX="$(printf '%s' "$ACT_CURSOR_STATE" | python3 -c 'import json,sys;print(json.load(sys.stdin)["next_index"])')"
    ACT_CURSOR_LEN="$(printf '%s' "$ACT_CURSOR_ITEMS" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
    if (( ACT_CURSOR_INDEX >= ACT_CURSOR_LEN )); then
        ACT_CURSOR_ITEMS='[]'
        ACT_CURSOR_INDEX=0
        act_cursor_save "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" "$ACT_CURSOR_ITEMS" 0 || exit 3
    fi
fi
GOVERN_RUN_ID=""
GOVERN_FREE_BEFORE=""
if [[ -n "$ACT_CURSOR" ]]; then
    GOVERN_FREE_BEFORE="$(df -kP "$HOME" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%.0f\n", $4*1024}')"
    GOVERN_RUN_ID="$(python3 "$SCRIPT_DIR/job_receipt.py" begin --job cleanup_worktrees --trigger govern)" || exit 3
fi
# A begun govern receipt must always reach a terminal state, including an early
# checkpoint/cursor error (exit 3) that bypasses the normal finish block below.
# Reuse the same job_receipt machinery rather than a second framework.
GOVERN_RECEIPT_CLOSED=0
govern_receipt_finish() {
    [[ -n "$GOVERN_RUN_ID" && "$GOVERN_RECEIPT_CLOSED" == 0 ]] || return 0
    GOVERN_RECEIPT_CLOSED=1
    python3 "$SCRIPT_DIR/job_receipt.py" finish --job cleanup_worktrees --run-id "$GOVERN_RUN_ID" \
      --outcome "${GOVERN_OUTCOME:-error}" --reason "${GOVERN_REASON:-early_exit}" \
      --candidates "{\"removed_count\":${GOVERN_REMOVED:-0},\"deferred_count\":$ACT_DEFERRED_COUNT,\"interrupted_count\":$ACT_INTERRUPTED_COUNT}" \
      --postcondition "{\"df_delta_bytes\":null,\"freed_bytes\":null,\"free_bytes_before\":${GOVERN_FREE_BEFORE:-null},\"free_bytes_after\":null}" >/dev/null 2>&1 || true
}
govern_temp_cleanup() { [[ -z "$RUN_TMP" ]] || rm -rf "$RUN_TMP"; }
trap 'govern_receipt_finish; govern_temp_cleanup' EXIT

act_candidate_begin() {
    local path="$1" index items_before
    [[ -n "$ACT_CURSOR" ]] || return 0
    index="$(printf '%s' "$ACT_CURSOR_ITEMS" | python3 -c '
import json,sys
items=json.load(sys.stdin)
try: print(items.index(sys.argv[1]))
except ValueError: print(-1)
' "$path")"
    if [[ "$index" == -1 ]]; then
        items_before="$(printf '%s' "$ACT_CURSOR_ITEMS" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
        ACT_CURSOR_ITEMS="$(printf '%s' "$ACT_CURSOR_ITEMS" | python3 -c '
import json,sys
items=json.load(sys.stdin); items.append(sys.argv[1])
print(json.dumps(items,separators=(",",":")))
' "$path")"
        index="$items_before"
        act_cursor_save "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" "$ACT_CURSOR_ITEMS" "$ACT_CURSOR_INDEX" || return 3
        (( ACT_CURSOR_INDEX < items_before )) && return 1
    fi
    (( index < ACT_CURSOR_INDEX )) && return 1
    if (( index > ACT_CURSOR_INDEX )); then
        ACT_CURSOR_INDEX="$index"
        act_cursor_save "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" "$ACT_CURSOR_ITEMS" "$ACT_CURSOR_INDEX" || return 3
    fi
    if [[ -n "$ACT_DEADLINE_AT" ]] && ! act_unit_fits "${DISK_MAGICIAN_UNIT_BUDGET_S:-60}"; then
        # A unit that never started is an interrupted/unfinished visit, not a
        # completed C14 deferral: count interrupted only and leave the cursor here.
        ACT_STOP=1
        ACT_INTERRUPTED_COUNT=$((ACT_INTERRUPTED_COUNT + 1))
        echo "deadline_before_unit:$path"
        return 2
    fi
    ACT_CURRENT_INDEX="$index"
    if [[ -n "${DISK_MAGICIAN_TEST_CLEANUP_CANDIDATE_HOOK:-}" ]]; then
        "$DISK_MAGICIAN_TEST_CLEANUP_CANDIDATE_HOOK" "$path"
    fi
    return 0
}

act_candidate_done() {
    [[ -n "$ACT_CURSOR" ]] || return 0
    ACT_CURSOR_INDEX=$((ACT_CURRENT_INDEX + 1))
    act_cursor_save "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" "$ACT_CURSOR_ITEMS" "$ACT_CURSOR_INDEX"
}

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

# Machine-wide live process CWD snapshot (fail-closed): the one strict parser in
# scripts/lib/lsof_linux.sh decides whether the observation is complete. Any
# failure (a missing lsof, an incomplete/unparseable scan, a live uninspectable
# pid, or zero resolved cwds) leaves cwd unknown, which preserves candidates
# across all worktree roots.
GLOBAL_LIVE_CWDS=""
GLOBAL_CWD_BLOCKED=""
if lsof_snapshot_cwds; then
    GLOBAL_LIVE_CWDS="$LSOF_CWDS"
else
    GLOBAL_CWD_BLOCKED="cwd-unknown"
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

    local min_age=$MIN_AGE_DAYS now recently_active=false
    # AO-managed sessions keep the 7-day inactivity bar; the 3-day floor is for
    # human-created worktrees.
    if [[ "$wt_path" == *"ao/data/worktrees/"* && "$min_age" -lt 7 ]]; then
        min_age=7
    fi
    now="$(date +%s)"
    if worktree_is_recently_active "$wt_path" "$min_age" "$now"; then
        recently_active=true
    fi

    if [[ "$locked" == "1" ]]; then
        echo "locked"
        return 0
    fi

    if [[ "$prunable" == "1" ]]; then
        echo "prunable-unknown"
        return 0
    fi

    if [[ "$recently_active" == true ]]; then
        # Bead plf: a merged, fully clean, non-AO worktree may go at
        # MERGED_MIN_DAYS. Any failed or unknown condition stays "young".
        if (( min_age == 7 )) \
            && ! worktree_is_recently_active "$wt_path" "$MERGED_MIN_DAYS" "$now" \
            && [[ "$wt_path" != *"ao/data/worktrees/"* && -z "$(std_root_skip_reason "$wt_path" "$real_wt")" ]] \
            && [[ -z "$(classify_content_and_merge "$repo" "$wt_path" "$head_sha" "$branch")" ]] \
            && ! has_hidden_state "$wt_path" \
            && ! has_ignored_user_data "$wt_path"; then
            return 0
        fi
        echo "young"
        return 0
    fi

    # Every removal candidate, at any age, must also clear the secret-file /
    # hidden-index-state probe and the AO-config / live-cwd standard-root gate
    # (previously enforced only on the sub-7-day fast path).
    local verdict skip_reason
    verdict="$(classify_content_and_merge "$repo" "$wt_path" "$head_sha" "$branch")"
    if [[ -z "$verdict" ]]; then
        skip_reason="$(std_root_skip_reason "$wt_path" "$real_wt")"
        if [[ -n "$skip_reason" ]]; then
            echo "$skip_reason"
            return 0
        fi
        if has_hidden_state "$wt_path"; then
            echo "hidden-state"
            return 0
        fi
        if has_ignored_user_data "$wt_path"; then
            echo "ignored-data"
            return 0
        fi
    fi
    [[ -z "$verdict" ]] || echo "$verdict"
}

# classify_content_and_merge <repo> <wt> <head> <branch>: dirty/merge checks;
# prints a PRESERVE reason, or nothing when the worktree is clean and merged.
# worktree_head_reachable_from_main <repo> <head_sha> <main_ref> — rc 0 when the
# commit is an ancestor of main (merge-base --is-ancestor). Fail closed.
worktree_head_reachable_from_main() {
    local repo="$1" head_sha="$2" main_ref="$3"
    [[ -n "$head_sha" && -n "$main_ref" ]] || return 1
    git -C "$repo" merge-base --is-ancestor "$head_sha" "$main_ref" 2>/dev/null && return 0
    return 1
}

# worktree_head_on_origin_branch <repo> <branch> <head_sha> — rc 0 when the exact
# HEAD is the live tip of that branch on origin (git ls-remote). Fail closed on
# any error (no timeout available, remote unreachable, mismatch).
worktree_head_on_origin_branch() {
    local repo="$1" branch="$2" head_sha="$3" t=""
    [[ -n "$branch" && "$branch" != "detached" && -n "$head_sha" ]] || return 1
    command -v timeout >/dev/null 2>&1 && t="timeout 30s"
    local remote_oid
    # shellcheck disable=SC2086
    remote_oid="$(env -u GH_TOKEN -u GITHUB_TOKEN $t git -C "$repo" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')" || return 1
    [[ -n "$remote_oid" && "$remote_oid" == "$head_sha" ]] && return 0
    return 1
}

classify_content_and_merge() {
    local repo="$1" wt_path="$2" head_sha="$3" branch="$4"
    local status_porcelain status_rc=0
    status_porcelain="$(GIT_OPTIONAL_LOCKS=0 git -C "$wt_path" status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)" || status_rc=$?
    if [[ "$status_rc" -ne 0 ]]; then
        echo "status-failed"
        return 0
    fi
    if [[ -n "$status_porcelain" ]]; then
        status_porcelain="$(grep -vE '^\?\? \.husky/_(/.*)?$' <<<"$status_porcelain" || true)"
    fi
    if [[ -n "$status_porcelain" ]]; then
        if grep -qE '^(\?\?|!!)' <<<"$status_porcelain"; then
            echo "untracked"
            return 0
        fi
        echo "dirty"
        return 0
    fi

    if [[ -z "$head_sha" ]]; then
        echo "head-missing"
        return 0
    fi

    local main_ref
    if ! main_ref="$(resolve_main_ref "$repo")"; then
        echo "main-ref-missing"
        return 0
    fi

    # rev-list --count main..head is 0 exactly when head is reachable from main
    # (what merge-base --is-ancestor tests), so one call answers both questions.
    local ahead_count rev_rc=0
    ahead_count="$(git -C "$repo" rev-list --count "$main_ref..$head_sha" 2>/dev/null)" || rev_rc=$?
    if [[ "$rev_rc" -ne 0 || ! "$ahead_count" =~ ^[0-9]+$ ]]; then
        echo "rev-list-failed"
        return 0
    fi
    if (( ahead_count > 0 )); then
        local branch_clean="${branch#refs/heads/}"
        if [[ -n "$branch_clean" && "$branch_clean" != "detached" ]] && command -v gh >/dev/null 2>&1; then
            local origin_url owner_repo
            origin_url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
            if [[ -n "$origin_url" ]]; then
                owner_repo="$(echo "$origin_url" | sed -E 's#^(https?://)[^/@]+@#\1#; s#^(https?://[^/]+/|git@[^:]+:)##; s#\.git$##')"
                if [[ -n "$owner_repo" ]]; then
                    local pr_heads gh_rc=0
                    if ! pr_heads="$(worktree_cached_pr_heads "$repo" "$branch_clean" 2>/dev/null)"; then
                        pr_heads="$(env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh pr list --repo "$owner_repo" --head "$branch_clean" --state MERGED --json headRefOid -q '.[].headRefOid' 2>/dev/null)" || gh_rc=$?
                    fi
                    if [[ "$gh_rc" -eq 0 && -n "$pr_heads" && -n "$head_sha" ]]; then
                        if grep -qFx "$head_sha" <<<"$pr_heads"; then
                            return 0
                        fi
                        # Bead disk_magician-archive-same-volume-regrowth-03bn
                        # follow-up: this branch has a MERGED PR but the worktree
                        # HEAD differs from the merged PR head. Removal is still
                        # data-loss-safe when HEAD itself is already reachable from
                        # main OR is the exact live tip on origin (the commits
                        # exist elsewhere). Fail closed to PRESERVE otherwise.
                        if worktree_head_reachable_from_main "$repo" "$head_sha" "$main_ref" \
                           || worktree_head_on_origin_branch "$repo" "$branch_clean" "$head_sha"; then
                            return 0
                        fi
                        echo "merged-differing-head"
                        return 0
                    fi
                fi
            fi
        fi
        # A clean worktree whose branch tip is already on origin loses nothing
        # when removed (the branch ref and the remote copy both survive). The
        # remote is queried live; any failure keeps it "ahead-of-main".
        if [[ -n "$branch_clean" && "$branch_clean" != "detached" && -n "$head_sha" ]]; then
            local remote_oid="" t=""
            command -v timeout >/dev/null 2>&1 && t="timeout 30s"
            # shellcheck disable=SC2086
            remote_oid="$(env -u GH_TOKEN -u GITHUB_TOKEN $t git -C "$repo" ls-remote --heads origin "refs/heads/$branch_clean" 2>/dev/null | awk 'NR==1{print $1}')" || remote_oid=""
            if [[ -n "$remote_oid" && "$remote_oid" == "$head_sha" ]]; then
                if has_ignored_user_data "$wt_path"; then
                    echo "ignored-data"
                    return 0
                fi
                return 0
            fi
        fi
        echo "ahead-of-main"
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
    local git_dir main_repo worktrees listed_path listed_real line
    git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
    main_repo="${git_dir%/.git/worktrees/*}"
    [[ -d "$main_repo" ]] || return 1
    worktrees="$(git -C "$main_repo" worktree list --porcelain 2>/dev/null)" || return 0
    while IFS= read -r line; do
        case "$line" in
            worktree\ *)
                listed_path="${line#worktree }"
                listed_real="$(cd "$listed_path" 2>/dev/null && pwd -P || true)"
                [[ -n "$listed_real" && "$listed_real" == "$wt_path" ]] && return 0
                ;;
        esac
    done <<<"$worktrees"
    return 1
}

# Parse the AO config once. Invalid, unreadable, or unprojectable config blocks
# cleanup because ownership cannot be determined with confidence.
AO_CONFIG_PATH="${DISK_MAGICIAN_AO_CONFIG:-$HOME/.hermes/agent-orchestrator.yaml}"
AO_CONFIG_STATE="missing"
AO_CONFIG_LINES=""
if [[ -e "$AO_CONFIG_PATH" || -L "$AO_CONFIG_PATH" ]]; then
    if [[ -f "$AO_CONFIG_PATH" && -r "$AO_CONFIG_PATH" ]] \
        && AO_CONFIG_LINES="$(ao_worktree_dirs "$AO_CONFIG_PATH" 2>/dev/null)"; then
        AO_CONFIG_STATE="valid"
    else
        AO_CONFIG_STATE="invalid"
    fi
fi

antigravity_ao_owned() {
    local candidate="$1" kind dir real
    case "$candidate" in */.ao/data/worktrees/*|*/ao/data/worktrees/*) return 0 ;; esac
    [[ "$AO_CONFIG_STATE" == "invalid" ]] && return 0
    [[ "$AO_CONFIG_STATE" == "valid" ]] || return 1
    while read -r kind dir; do
        [[ -n "$dir" ]] || continue
        dir="$(expand_path "$dir")"
        real="$(cd "$dir" 2>/dev/null && pwd -P || printf '%s' "$dir")"
        [[ "$candidate" == "$dir" || "$candidate" == "$dir"/* || "$candidate" == "$real" || "$candidate" == "$real"/* ]] && return 0
    done <<<"$AO_CONFIG_LINES"
    return 1
}

process_antigravity_orphan() {
    local abs_subdir="$1"
    if is_worktree_active "$abs_subdir"; then
        ledger_line "antigravity" "PRESERVE" "$abs_subdir" "active"
        ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
        return 0
    fi
    if worktree_is_recently_active "$abs_subdir" "$MIN_AGE_DAYS"; then
        ledger_line "antigravity" "PRESERVE" "$abs_subdir" "young" " (< ${MIN_AGE_DAYS} days)"
        ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
        return 0
    fi
    if [[ -n "$GLOBAL_CWD_BLOCKED" ]]; then
        ledger_line "antigravity" "PRESERVE" "$abs_subdir" "$GLOBAL_CWD_BLOCKED"
        ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
        return 0
    fi
    if list_has_child_of "$abs_subdir" "$GLOBAL_LIVE_CWDS"; then
        ledger_line "antigravity" "PRESERVE" "$abs_subdir" "live-cwd"
        ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
        return 0
    fi
    if [[ ! -e "$abs_subdir/.git" && ! -L "$abs_subdir/.git" ]]; then
        ledger_line "antigravity" "PRESERVE" "$abs_subdir" "not-git"
        ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
        return 0
    fi
    if [[ "$AO_CONFIG_STATE" == "invalid" ]]; then
        ledger_line "antigravity" "PRESERVE" "$abs_subdir" "ao-config-unreadable"
        ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
        return 0
    fi
    if antigravity_ao_owned "$abs_subdir"; then
        ledger_line "antigravity" "PRESERVE" "$abs_subdir" "ao-owned"
        ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
        return 0
    fi
    if [[ -e "$abs_subdir/.git" || -L "$abs_subdir/.git" ]]; then
        local status_porcelain status_rc=0
        status_porcelain="$(GIT_OPTIONAL_LOCKS=0 git -C "$abs_subdir" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)" || status_rc=$?
        if [[ "$status_rc" -ne 0 ]]; then
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "status-failed"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi
        if [[ -n "$status_porcelain" ]]; then
            if grep -qE '^(\?\?|!!)' <<<"$status_porcelain"; then
                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "untracked"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                return 0
            fi
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "dirty"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi

        if has_ignored_user_data "$abs_subdir"; then
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "ignored-data"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi

        if has_hidden_state "$abs_subdir"; then
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "hidden-state"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi

        local ag_main_repo=""
        if [[ -f "$abs_subdir/.git" ]]; then
            local gitdir_line
            gitdir_line=$(grep '^gitdir: ' "$abs_subdir/.git" 2>/dev/null || true)
            local git_dir
            git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
            if [[ "$git_dir" == *"/.git/worktrees/"* ]]; then
                ag_main_repo="${git_dir%/.git/worktrees/*}"
            elif [[ "$git_dir" == *"/.git" ]]; then
                ag_main_repo="${git_dir%/.git}"
            elif [[ -n "$git_dir" && -d "$git_dir" ]]; then
                ag_main_repo="$(git -C "$git_dir" rev-parse --show-toplevel 2>/dev/null || echo "$git_dir")"
            fi
        elif [[ -d "$abs_subdir/.git" ]]; then
            ag_main_repo="$abs_subdir"
        fi
        if [[ -z "$ag_main_repo" || ! -d "$ag_main_repo" ]]; then
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "main-repo-missing"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi

        local main_ref
        if ! main_ref="$(resolve_main_ref "$ag_main_repo" 2>/dev/null)"; then
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "main-ref-missing"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi

        local head_sha
        head_sha="$(git -C "$abs_subdir" rev-parse HEAD 2>/dev/null || true)"
        if [[ -z "$head_sha" ]]; then
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "head-missing"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi

        if ! git -C "$ag_main_repo" merge-base --is-ancestor "$head_sha" "$main_ref" 2>/dev/null; then
            local ahead_count rev_rc=0
            ahead_count="$(git -C "$ag_main_repo" rev-list --count "$main_ref..$head_sha" 2>/dev/null)" || rev_rc=$?
            if [[ "$rev_rc" -ne 0 ]]; then
                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "rev-list-failed"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                return 0
            fi
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
                            if ! pr_heads="$(worktree_cached_pr_heads "$ag_main_repo" "$branch_clean" 2>/dev/null)"; then
                                pr_heads="$(env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh pr list --repo "$owner_repo" --head "$branch_clean" --state MERGED --json headRefOid -q '.[].headRefOid' 2>/dev/null)" || gh_rc=$?
                            fi
                            if [[ "$gh_rc" -eq 0 && -n "$pr_heads" && -n "$head_sha" ]]; then
                                if grep -qFx "$head_sha" <<<"$pr_heads"; then
                                    eligible_by_pr=true
                                else
                                    ledger_line "antigravity" "PRESERVE" "$abs_subdir" "merged-differing-head"
                                    ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                                    return 0
                                fi
                            fi
                        fi
                    fi
                fi
                if [[ "$eligible_by_pr" == false ]]; then
                    ledger_line "antigravity" "PRESERVE" "$abs_subdir" "ahead-of-main"
                    ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                    return 0
                fi
            else
                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "non-ancestor"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                return 0
            fi
        fi
    fi
    local local_kb local_mb _safety_reason
    local_kb=$(size_kb "$abs_subdir")
    local_mb=$(( local_kb / 1024 ))
    if [[ "$DRY_RUN" == true ]]; then
        ledger_line "antigravity" "ELIGIBLE" "$abs_subdir" "" " (~${local_mb}M, rm -rf orphan)"
        TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + local_kb ))
        ANTIGRAVITY_DELETED=$(( ANTIGRAVITY_DELETED + 1 ))
    else
        if [[ -e "$abs_subdir/.git" || -L "$abs_subdir/.git" ]] && has_hidden_state "$abs_subdir"; then
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "hidden-state"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi
        if [[ -e "$abs_subdir/.git" || -L "$abs_subdir/.git" ]] && has_ignored_user_data "$abs_subdir"; then
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "ignored-data"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi
        if ! _safety_reason="$(safety_gate "$abs_subdir" 2>/dev/null)"; then
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "$_safety_reason"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi
        local final_status final_status_rc=0
        if [[ -e "$abs_subdir/.git" || -L "$abs_subdir/.git" ]]; then
            final_status="$(GIT_OPTIONAL_LOCKS=0 git -C "$abs_subdir" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)" || final_status_rc=$?
            if [[ "$final_status_rc" -ne 0 || -n "$final_status" ]]; then
                ledger_line "antigravity" "PRESERVE" "$abs_subdir" "changed-after-size"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                return 0
            fi
        fi
        local ag_c14_result
        if [[ -n "$ACT_DEADLINE_AT" ]]; then
            ag_c14_result="$(quarantine_remove "$abs_subdir" --deadline-at "$ACT_DEADLINE_AT")"
        else
            ag_c14_result="$(quarantine_remove "$abs_subdir")"
        fi
        if [[ "$ag_c14_result" != removed:* || -e "$abs_subdir" || -L "$abs_subdir" ]]; then
            # A deferred quarantine verdict is a completed visit for this pass
            # (the candidate is left in place); count it and let the caller
            # advance the cursor via act_candidate_done.
            [[ "$ag_c14_result" == deferred:* ]] && ACT_DEFERRED_COUNT=$(( ACT_DEFERRED_COUNT + 1 ))
            ledger_line "antigravity" "PRESERVE" "$abs_subdir" "${ag_c14_result#kept:}"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            return 0
        fi
        ledger_line "antigravity" "DELETE" "$abs_subdir" "" " (~${local_mb}M)"
        TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + local_kb ))
        ANTIGRAVITY_DELETED=$(( ANTIGRAVITY_DELETED + 1 ))
    fi
}

if [[ -d "$WORKTREE_ROOT" ]]; then
    echo ""
    echo "--- Antigravity orphans ($WORKTREE_ROOT) ---"
    real_worktree_root="$(cd "$WORKTREE_ROOT" 2>/dev/null && pwd -P || true)"
    for parent_dir in "$WORKTREE_ROOT"/*; do
        [[ "$ACT_STOP" == 0 ]] || break
        [[ -e "$parent_dir" ]] || continue
        if [[ -L "$parent_dir" ]]; then
            ledger_line "antigravity" "PRESERVE" "$parent_dir" "symlink-parent"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            continue
        fi
        [[ -d "$parent_dir" ]] || continue
        for subdir in "$parent_dir"/*; do
            [[ "$ACT_STOP" == 0 ]] || break
            [[ -e "$subdir" ]] || continue
            if [[ -L "$subdir" ]]; then
                ledger_line "antigravity" "PRESERVE" "$subdir" "symlink-candidate"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                continue
            fi
            [[ -d "$subdir" ]] || continue
            abs_subdir="$(cd "$subdir" 2>/dev/null && pwd -P || true)"
            if [[ -z "$abs_subdir" || -z "$real_worktree_root" || "$abs_subdir" != "$real_worktree_root"/*/* ]]; then
                ledger_line "antigravity" "PRESERVE" "$subdir" "outside-root"
                ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
                continue
            fi
            if act_candidate_begin "$abs_subdir"; then :; else
                candidate_rc=$?
                [[ "$candidate_rc" == 1 ]] && continue
                [[ "$candidate_rc" == 2 ]] && break
                exit "$candidate_rc"
            fi
            process_antigravity_orphan "$abs_subdir"
            act_candidate_done || exit 3
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
        if [[ "$abs_path" != "$main_wt_path" && -f "$abs_path/.git" ]]; then
            match=true
        elif [[ "$abs_path" == *"/.claude/worktrees/"* || \
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

        if act_candidate_begin "$abs_path"; then :; else
            candidate_rc=$?
            wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
            [[ "$candidate_rc" == 1 || "$candidate_rc" == 2 ]] && return 0
            return "$candidate_rc"
        fi

        if [[ -n "$std_real" ]]; then
            local std_skip
            std_skip="$(std_root_skip_reason "$abs_path" "$std_real")"
            if [[ -n "$std_skip" ]]; then
                ledger_line "repo-local" "PRESERVE" "$abs_path" "$std_skip"
                REPO_LOCAL_PRESERVED=$(( REPO_LOCAL_PRESERVED + 1 ))
                act_candidate_done || return 3
                wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
                return 0
            fi
        fi

        local reason size_kb_val size_fmt branch_label extra age_label age_days
        reason="$(classify_repo_local_worktree "$repo_abs" "$abs_path" "$head_sha" "$locked" "$prunable" "$branch")"
        size_fmt='-'
        age_label='-'
        if [[ -z "$reason" ]]; then
            age_days="$(worktree_age_days "$abs_path")" || age_days='?'
            [[ "$age_days" =~ ^(0|[1-9][0-9]*)$ ]] || age_days='?'
            age_label="${age_days}d"
            size_kb_val=$(size_kb "$abs_path")
            size_fmt=$(fmt_kb "$size_kb_val")
        fi
        branch_label="${branch:-detached}"
        extra=" | age=${age_label} size=${size_fmt} head=${head_sha:0:8} branch=${branch_label}"

        if [[ -n "$reason" ]]; then
            ledger_line "repo-local" "PRESERVE" "$abs_path" "$reason" "$extra"
            REPO_LOCAL_PRESERVED=$(( REPO_LOCAL_PRESERVED + 1 ))
        else
            if [[ "$DRY_RUN" == true ]]; then
                ledger_line "repo-local" "ELIGIBLE" "$abs_path" "" "$extra"
                TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + size_kb_val ))
                REPO_LOCAL_ELIGIBLE=$(( REPO_LOCAL_ELIGIBLE + 1 ))
            else
                if has_hidden_state "$abs_path"; then
                    ledger_line "repo-local" "PRESERVE" "$abs_path" "hidden-state" "$extra"
                    REPO_LOCAL_PRESERVED=$(( REPO_LOCAL_PRESERVED + 1 ))
                    act_candidate_done || return 3
                    wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
                    return 0
                fi
                if has_ignored_user_data "$abs_path"; then
                    ledger_line "repo-local" "PRESERVE" "$abs_path" "ignored-data" "$extra"
                    REPO_LOCAL_PRESERVED=$(( REPO_LOCAL_PRESERVED + 1 ))
                    act_candidate_done || return 3
                    wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
                    return 0
                fi
                local final_status final_status_rc=0
                final_status="$(GIT_OPTIONAL_LOCKS=0 git -C "$abs_path" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)" || final_status_rc=$?
                if [[ -n "$final_status" ]]; then
                    final_status="$(grep -vE '^\?\? \.husky/_(/.*)?$' <<<"$final_status" || true)"
                fi
                if [[ "$final_status_rc" -ne 0 || -n "$final_status" ]]; then
                    ledger_line "repo-local" "PRESERVE" "$abs_path" "changed-after-size" "$extra"
                    REPO_LOCAL_PRESERVED=$(( REPO_LOCAL_PRESERVED + 1 ))
                    act_candidate_done || return 3
                    wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
                    return 0
                fi
                GIT_OPTIONAL_LOCKS=0 git -C "$abs_path" reflog expire --expire-unreachable="${MIN_AGE_DAYS}.days.ago" --all 2>/dev/null || true
                # Restore directory mtimes bumped by prior venv/deps/cache strip passes
                # back to the worktree's true last-activity epoch before C14 inventory.
                local wt_act_epoch
                wt_act_epoch="$(worktree_last_activity_epoch "$abs_path" 2>/dev/null || echo 0)"
                if [[ "$wt_act_epoch" =~ ^[1-9][0-9]*$ ]]; then
                    python3 - "$abs_path" "$wt_act_epoch" <<'PY' 2>/dev/null || true
import os, sys
root, cap = sys.argv[1], int(sys.argv[2])
for dp, dns, _ in os.walk(root, topdown=False, followlinks=False):
    try:
        st = os.lstat(dp)
        if int(st.st_mtime) > cap:
            os.utime(dp, (cap, cap), follow_symlinks=False)
    except Exception:
        pass
PY
                fi
                # Same C14 -> WRH route as worktree_reap: the REAL verdict
                # writes the single original receipt, and WRH consumes exactly
                # that receipt. No fresh inventory may reauthorize removal.
                local cw_c14_inv cw_c14_verdict cw_removed=0
                cw_c14_inv="$(mktemp "${TMPDIR:-/tmp}/cw-c14-inv.XXXXXX")"
                if [[ -n "$cw_c14_inv" ]]; then
                    # T3 context: this is the sanctioned cleanup_worktrees.sh
                    # 3-day path. --t3-owner-null lets C14 free EXACTLY this
                    # candidate's own owner-null lease (never an
                    # ancestor/descendant), after all other C14 checks and the
                    # recency/policy/remote proof above.
                    if [[ -n "$ACT_DEADLINE_AT" ]]; then
                        cw_c14_verdict="$(artifact_removal_verdict "$abs_path" --t3-owner-null --inventory-out "$cw_c14_inv" --deadline-at "$ACT_DEADLINE_AT")"
                    else
                        cw_c14_verdict="$(artifact_removal_verdict "$abs_path" --t3-owner-null --inventory-out "$cw_c14_inv")"
                    fi
                    if [[ "$cw_c14_verdict" == remove ]]; then
                        if [[ -n "$ACT_DEADLINE_AT" ]]; then
                            wrh_remove_now "$abs_path" "$abs_path" --quarantine "$cw_c14_inv" --deadline-at "$ACT_DEADLINE_AT" && [[ ! -e "$abs_path" ]] && cw_removed=1
                        else
                            wrh_remove_now "$abs_path" "$abs_path" --quarantine "$cw_c14_inv" && [[ ! -e "$abs_path" ]] && cw_removed=1
                        fi
                    fi
                    if [[ "$cw_removed" == 1 ]]; then
                        rm -f "$cw_c14_inv"
                        ledger_line "repo-local" "DELETE" "$abs_path" "" "$extra"
                        TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + size_kb_val ))
                        REPO_LOCAL_ELIGIBLE=$(( REPO_LOCAL_ELIGIBLE + 1 ))
                    else
                        rm -f "$cw_c14_inv"
                        # A deferred verdict is a completed visit for this pass
                        # (the candidate stays put and the cursor advances via
                        # act_candidate_done); a failed quarantine is kept.
                        [[ "$cw_c14_verdict" == deferred:* ]] && ACT_DEFERRED_COUNT=$(( ACT_DEFERRED_COUNT + 1 ))
                        ledger_line "repo-local" "PRESERVE" "$abs_path" "${cw_c14_verdict#kept:}" "$extra"
                        REPO_LOCAL_PRESERVED=$(( REPO_LOCAL_PRESERVED + 1 ))
                    fi
                else
                    ledger_line "repo-local" "PRESERVE" "$abs_path" "check-failed" "$extra"
                    REPO_LOCAL_PRESERVED=$(( REPO_LOCAL_PRESERVED + 1 ))
                fi
            fi
        fi

        act_candidate_done || return 3
        wt_path=""; head_sha=""; branch=""; locked=0; prunable=0
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$ACT_STOP" == 0 ]] || break
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
            locked|locked\ *)
                locked=1
                ;;
            prunable*)
                prunable=1
                ;;
        esac
    done <<<"$porcelain"
    if [[ "$ACT_STOP" == 0 ]]; then
        flush_block
    else
        # A cooperative deadline stop is a normal partial pass, not an error.
        return 0
    fi
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
# Loaded even without STD_ROOT: the plf merged fast path also consults it.
if [[ "$AO_CONFIG_STATE" == "invalid" ]]; then
    STD_BLOCKED="ao-config-unreadable"
elif [[ "$AO_CONFIG_STATE" == "valid" ]]; then
        ao_lines="$AO_CONFIG_LINES"
        while read -r kind d; do
            [[ -n "$d" ]] || continue
            d="$(expand_path "$d")"
            d="$d"$'\n'"$(cd "$d" 2>/dev/null && pwd -P || printf '%s' "$d")"$'\n'
            if [[ "$kind" == C ]]; then STD_AO_PARENTS+="$d"; else STD_AO_DIRS+="$d"; fi
        done <<<"$ao_lines"
fi

# std_root_skip_reason <abs> <real>: prints why a standard-root worktree is off-limits.
std_root_skip_reason() {
    if [[ -n "$STD_BLOCKED" ]]; then
        echo "$STD_BLOCKED"
    elif [[ "$1" == *"/.ao/data/worktrees/"* || "$1" == *"/ao/data/worktrees/"* \
        || "$2" == *"/.ao/data/worktrees/"* || "$2" == *"/ao/data/worktrees/"* ]] \
        || list_has_parent_of "$1" "$STD_AO_DIRS" || list_has_parent_of "$2" "$STD_AO_DIRS" \
        || list_has_line "${1%/*}" "$STD_AO_PARENTS" || list_has_line "${2%/*}" "$STD_AO_PARENTS"; then
        echo "ao-owned"
    elif [[ -n "$GLOBAL_CWD_BLOCKED" ]]; then
        echo "$GLOBAL_CWD_BLOCKED"
    elif list_has_child_of "$2" "$GLOBAL_LIVE_CWDS" || list_has_child_of "$1" "$GLOBAL_LIVE_CWDS"; then
        echo "live-cwd"
    fi
}

is_live_cwd() {
    local wt="$1" real_wt
    real_wt="$(cd "$wt" 2>/dev/null && pwd -P || printf '%s' "$wt")"
    [[ -n "$GLOBAL_CWD_BLOCKED" ]] && return 0
    list_has_child_of "$real_wt" "$GLOBAL_LIVE_CWDS" || list_has_child_of "$wt" "$GLOBAL_LIVE_CWDS"
}

is_ao_managed_worktree() {
    local wt="$1"
    local real_wt
    real_wt="$(cd "$wt" 2>/dev/null && pwd -P || printf '%s' "$wt")"
    if [[ -n "$STD_BLOCKED" || "$AO_CONFIG_STATE" == "invalid" ]]; then
        return 0
    fi
    if [[ "$wt" == *"ao/data/worktrees/"* || "$real_wt" == *"ao/data/worktrees/"* ]]; then
        return 0
    fi
    if antigravity_ao_owned "$wt" || antigravity_ao_owned "$real_wt"; then
        return 0
    fi
    local skip_reason
    skip_reason="$(std_root_skip_reason "$wt" "$real_wt" 2>/dev/null || true)"
    if [[ "$skip_reason" == "ao-owned" || "$skip_reason" == "ao-config-unreadable" ]]; then
        return 0
    fi
    return 1
}

if ((${#REPO_LOCAL_REPOS[@]})); then
    for repo in "${REPO_LOCAL_REPOS[@]}"; do
        [[ "$ACT_STOP" == 0 ]] || break
        process_repo_local_worktrees "$repo"
    done
fi

if [[ -n "$ACT_CURSOR" ]]; then
    act_cursor_save "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" "$ACT_CURSOR_ITEMS" "$ACT_CURSOR_INDEX" || {
        echo "failed to checkpoint cleanup_worktrees" >&2; exit 3;
    }
    GOVERN_FREE_AFTER="$(df -kP "$HOME" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%.0f\n", $4*1024}')"
    GOVERN_DELTA=""
    if [[ "$GOVERN_FREE_BEFORE" =~ ^[0-9]+$ && "$GOVERN_FREE_AFTER" =~ ^[0-9]+$ ]]; then
        GOVERN_DELTA=$((GOVERN_FREE_AFTER - GOVERN_FREE_BEFORE))
    fi
    GOVERN_REMOVED=0
    [[ "$DRY_RUN" == true ]] || GOVERN_REMOVED=$((ANTIGRAVITY_DELETED + REPO_LOCAL_ELIGIBLE))
    GOVERN_FREED="null"
    [[ "$GOVERN_DELTA" =~ ^-?[0-9]+$ ]] && GOVERN_FREED=$(( GOVERN_DELTA > 0 ? GOVERN_DELTA : 0 ))
    GOVERN_OUTCOME=success
    GOVERN_REASON=cleanup_pass_complete
    [[ "$ACT_STOP" == 0 ]] || { GOVERN_OUTCOME=partial; GOVERN_REASON=deadline_before_candidate; }
    python3 "$SCRIPT_DIR/job_receipt.py" finish --job cleanup_worktrees --run-id "$GOVERN_RUN_ID" \
      --outcome "$GOVERN_OUTCOME" --reason "$GOVERN_REASON" \
      --candidates "{\"removed_count\":$GOVERN_REMOVED,\"deferred_count\":$ACT_DEFERRED_COUNT,\"interrupted_count\":$ACT_INTERRUPTED_COUNT}" \
      --postcondition "{\"df_delta_bytes\":${GOVERN_DELTA:-null},\"freed_bytes\":$GOVERN_FREED,\"free_bytes_before\":${GOVERN_FREE_BEFORE:-null},\"free_bytes_after\":${GOVERN_FREE_AFTER:-null}}" || exit 3
    GOVERN_RECEIPT_CLOSED=1
fi

total_gb=$(awk "BEGIN {printf \"%.2f\", $TOTAL_RECLAIMED_KB / 1048576}")

echo ""
echo "=== Summary ==="
echo "Antigravity: ${ANTIGRAVITY_DELETED} eligible orphan(s), ${ANTIGRAVITY_KEPT} active preserved."
echo "Repo-local:  ${REPO_LOCAL_ELIGIBLE} eligible, ${REPO_LOCAL_PRESERVED} preserved."
echo "Reclaimable: ~${total_gb} GB (${TOTAL_RECLAIMED_KB} KB)"
if [[ "$DRY_RUN" == true ]]; then
    echo "Run with --clean and WORKTREE_APPROVED=1 to proceed."
fi
