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
        # Stale lock detection: only auto-unlock automated/orchestrator worktrees
        local is_automated=false
        if [[ "$wt_path" == *"/.ao/data/worktrees/"* || \
              "$wt_path" == *"/ao/data/worktrees/"* || \
              "$wt_path" == *"/antigravity/worktrees/"* ]]; then
            is_automated=true
        fi

        if [[ "$is_automated" == "true" && "$recently_active" == false ]]; then
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

    if [[ "$recently_active" == true ]]; then
        # Bead plf: a merged, fully clean, non-AO worktree may go at
        # MERGED_MIN_DAYS. Any failed or unknown condition stays "young".
        if (( min_age == 7 )) \
            && ! worktree_is_recently_active "$wt_path" "$MERGED_MIN_DAYS" "$now" \
            && [[ "$wt_path" != *"ao/data/worktrees/"* && -z "$(std_root_skip_reason "$wt_path" "$real_wt")" ]] \
            && [[ -z "$(classify_content_and_merge "$repo" "$wt_path" "$head_sha" "$branch")" ]] \
            && ! has_hidden_state "$wt_path"; then
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
    fi
    [[ -z "$verdict" ]] || echo "$verdict"
}

# has_hidden_state <wt>: rc 0 when state `git status` cannot see exists
# (assume-unchanged/skip-worktree entries, ignored secret-like files) or a
# probe fails/times out (fail closed).
has_hidden_state() {
    local out flags t=""
    command -v timeout >/dev/null 2>&1 && t="timeout 60s"
    flags="$(git -C "$1" ls-files -v 2>/dev/null)" || return 0
    grep -q '^[a-zS]' <<<"$flags" && return 0
    # shellcheck disable=SC2086
    out="$($t git -C "$1" ls-files -o -i --exclude-standard -- \
        ':(icase).env*' ':(icase)*/.env*' ':(icase)*.pem' ':(icase)*.key' \
        ':(icase)*.p12' ':(icase)*.pfx' ':(icase)id_rsa*' ':(icase)*/id_rsa*' \
        ':(icase)id_ed25519*' ':(icase)*/id_ed25519*' ':(icase)id_ecdsa*' ':(icase)*/id_ecdsa*' \
        ':(icase)id_dsa*' ':(icase)*/id_dsa*' \
        ':(icase).npmrc' ':(icase)*/.npmrc' ':(icase).netrc' ':(icase)*/.netrc' \
        ':(icase)*credentials*' ':(icase)secrets*' ':(icase)*/secrets*' 2>/dev/null)" || return 0
    [[ -n "$out" ]]
}

# Persist across the command substitutions used by classification. Cache names
# are digests, but the stored repo and branch are also checked byte for byte:
# a filename collision or an unreadable record must never approve a worktree.
repo_local_cached_pr_heads() {
    # Per-run cache files: repos.tsv maps owner_repo -> index; repo<index>/index.tsv
    # holds "branch<TAB>oid oid ...". Git refnames cannot contain tab, newline,
    # space or backslash, and keys reach awk through ENVIRON (no -v escapes).
    local repo="$1" owner_repo="$2" branch_clean="$3" cache_dir idx
    [[ -n "$RUN_TMP" && -d "$RUN_TMP" ]] || return 1
    [[ "$owner_repo" =~ ^[^/]+/[^/]+$ ]] || return 1
    idx="$(DWR_KEY="$owner_repo" awk -F '\t' '$1 == ENVIRON["DWR_KEY"] { print $2; exit }' "$RUN_TMP/repos.tsv" 2>/dev/null)"
    if [[ -z "$idx" ]]; then
        idx="$(( $(awk 'END { print NR }' "$RUN_TMP/repos.tsv" 2>/dev/null || echo 0) + 1 ))"
        cache_dir="$RUN_TMP/repo$idx"
        mkdir "$cache_dir" || return 1
        printf '%s\t%s\n' "$owner_repo" "$idx" >> "$RUN_TMP/repos.tsv"
        populate_repo_pr_cache "$repo" "$owner_repo" "$cache_dir" || true
    fi
    cache_dir="$RUN_TMP/repo$idx"
    # Prints the heads one per line (as the per-row gh call does); rc 1 on miss.
    DWR_KEY="$branch_clean" awk -F '\t' '$1 == ENVIRON["DWR_KEY"] { n = split($2, h, " "); for (i = 1; i <= n; i++) print h[i]; found = 1; exit } END { exit !found }' "$cache_dir/index.tsv" 2>/dev/null
}

populate_repo_pr_cache() {
    local repo="$1" owner_repo="$2" cache_dir="$3" worktrees line
    worktrees="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || return 1
    local branches=()
    while IFS= read -r line; do
        case "$line" in branch\ refs/heads/*) branches+=("${line#branch refs/heads/}");; esac
    done <<<"$worktrees"
    local start index end query fields response
    for ((start=0; start<${#branches[@]}; start+=40)); do
        end=$((start + 40))
        (( end <= ${#branches[@]} )) || end=${#branches[@]}
        query='query($owner: String!, $name: String!'
        fields=''
        local variables=(-f "owner=${owner_repo%%/*}" -f "name=${owner_repo#*/}")
        for ((index=start; index<end; index++)); do
            query+=", \$b${index}: String!"
            fields+=" b${index}: pullRequests(headRefName: \$b${index}, states: MERGED, first: 30, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { headRefOid } }"
            variables+=(-f "b${index}=${branches[index]}")
        done
        query+=") { repository(owner: \$owner, name: \$name) {${fields} } }"
        response="$cache_dir/response.json"
        if env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh api graphql -f "query=$query" "${variables[@]}" > "$response" 2>/dev/null; then
            python3 - "$cache_dir" "$owner_repo" "$response" "$start" "${branches[@]:start:end-start}" <<'PY' || true
import json, os, sys
directory, owner_repo, response, start, *branches = sys.argv[1:]
try:
    with open(response) as source:
        payload = json.load(source)
    repository = payload['data']['repository']
    if not isinstance(repository, dict):
        sys.exit(1)
    errors = payload.get('errors', [])
    if not isinstance(errors, list):
        sys.exit(1)
    failed = set()
    for error in errors:
        path = error.get('path') if isinstance(error, dict) else None
        # A request/repository-wide or malformed error cannot identify a safe
        # subset. Alias-specific errors invalidate only the affected branches.
        if not isinstance(path, list) or len(path) < 2 or path[0] != 'repository' or not isinstance(path[1], str):
            sys.exit(1)
        failed.add(path[1])
    for index, branch in enumerate(branches, int(start)):
        alias = 'b' + str(index)
        value = repository.get(alias)
        if alias in failed or not isinstance(value, dict):
            continue
        nodes = value.get('nodes')
        if not isinstance(nodes, list) or any(not isinstance(node, dict) or not isinstance(node.get('headRefOid'), str) or not node['headRefOid'] for node in nodes):
            continue
        with open(os.path.join(directory, 'index.tsv'), 'a') as target:
            target.write(branch + '\t' + ' '.join(node['headRefOid'] for node in nodes) + '\n')
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
PY
        fi
    done
}

# classify_content_and_merge <repo> <wt> <head> <branch>: dirty/merge checks;
# prints a PRESERVE reason, or nothing when the worktree is clean and merged.
classify_content_and_merge() {
    local repo="$1" wt_path="$2" head_sha="$3" branch="$4"
    local status_porcelain status_rc=0
    status_porcelain="$(git -C "$wt_path" status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)" || status_rc=$?
    if [[ "$status_rc" -ne 0 ]]; then
        echo "status-failed"
        return 0
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
                    if ! pr_heads="$(repo_local_cached_pr_heads "$repo" "$owner_repo" "$branch_clean" 2>/dev/null)"; then
                        pr_heads="$(env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh pr list --repo "$owner_repo" --head "$branch_clean" --state MERGED --json headRefOid -q '.[].headRefOid' 2>/dev/null)" || gh_rc=$?
                    fi
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
        # A clean worktree whose branch tip is already on origin loses nothing
        # when removed (the branch ref and the remote copy both survive). The
        # remote is queried live; any failure keeps it "ahead-of-main".
        if [[ -n "$branch_clean" && "$branch_clean" != "detached" && -n "$head_sha" ]]; then
            local remote_oid="" t=""
            command -v timeout >/dev/null 2>&1 && t="timeout 30s"
            # shellcheck disable=SC2086
            remote_oid="$(env -u GH_TOKEN -u GITHUB_TOKEN $t git -C "$repo" ls-remote --heads origin "refs/heads/$branch_clean" 2>/dev/null | awk 'NR==1{print $1}')" || remote_oid=""
            if [[ -n "$remote_oid" && "$remote_oid" == "$head_sha" ]]; then
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
    local git_dir main_repo
    git_dir=$(echo "$gitdir_line" | cut -d' ' -f2-)
    main_repo="${git_dir%/.git/worktrees/*}"
    [[ -d "$main_repo" ]] || return 1
    git -C "$main_repo" worktree list --porcelain 2>/dev/null | grep -qF "^worktree ${wt_path}$"
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
    if [[ -e "$abs_subdir/.git" || -L "$abs_subdir/.git" ]]; then
        local status_porcelain status_rc=0
        status_porcelain="$(git -C "$abs_subdir" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)" || status_rc=$?
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
                            pr_heads="$(env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh pr list --repo "$owner_repo" --head "$branch_clean" --state MERGED --json headRefOid -q '.[].headRefOid' 2>/dev/null)" || gh_rc=$?
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
        ledger_line "antigravity" "DELETE" "$abs_subdir" "" " (~${local_mb}M)"
        if ! _safety_reason="$(safety_gate "$abs_subdir" 2>/dev/null)"; then
            echo "SAFETY-SKIP $abs_subdir ($_safety_reason)"
        else
            rm -rf "$abs_subdir"
        fi
        TOTAL_RECLAIMED_KB=$(( TOTAL_RECLAIMED_KB + local_kb ))
        ANTIGRAVITY_DELETED=$(( ANTIGRAVITY_DELETED + 1 ))
    fi
}

if [[ -d "$WORKTREE_ROOT" ]]; then
    echo ""
    echo "--- Antigravity orphans ($WORKTREE_ROOT) ---"
    real_worktree_root="$(cd "$WORKTREE_ROOT" 2>/dev/null && pwd -P || true)"
    for parent_dir in "$WORKTREE_ROOT"/*; do
        [[ -e "$parent_dir" ]] || continue
        if [[ -L "$parent_dir" ]]; then
            ledger_line "antigravity" "PRESERVE" "$parent_dir" "symlink-parent"
            ANTIGRAVITY_KEPT=$(( ANTIGRAVITY_KEPT + 1 ))
            continue
        fi
        [[ -d "$parent_dir" ]] || continue
        for subdir in "$parent_dir"/*; do
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
            process_antigravity_orphan "$abs_subdir"
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
            locked|locked\ *)
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
# Loaded even without STD_ROOT: the plf merged fast path also consults it.
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
