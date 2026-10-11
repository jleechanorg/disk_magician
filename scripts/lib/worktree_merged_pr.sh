# shellcheck shell=bash
# worktree_merged_pr.sh — gh-verified merged-PR head proof (plan Task 3b).
#
# A worktree branch is only provably safe to remove when its exact HEAD was
# merged: either via the batched cache (below) or a live per-branch
# `gh pr list --state MERGED` query. Everything else — gh failure, an OPEN
# PR's newer head, an empty branch (detached HEAD), an unresolvable remote —
# fails closed to rc 1 (not proven).
#
# Cache layout (library-owned, NOT the caller's run tmp):
#   ${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}/pr_cache/<owner_repo>.tsv
#   line 1: "#epoch <population-seconds>"
#   then:   "<branch>\t<head-oid> <head-oid> ..."
# Fresh for 1h; writes are atomic (temp file + mv). Git refnames cannot
# contain tab or space, so the TSV keys are unambiguous.
#
# Sourcing this file runs no top-level code.

_wmp_cache_dir() {
    printf '%s/pr_cache\n' "${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
}

# _wmp_owner_repo <main_repo> — "owner/repo" from the origin remote URL.
_wmp_owner_repo() {
    local repo="$1" origin_url owner_repo
    origin_url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
    [[ -n "$origin_url" ]] || return 1
    owner_repo="$(echo "$origin_url" | sed -E 's#^(https?://)[^/@]+@#\1#; s#^(https?://[^/]+/|git@[^:]+:)##; s#\.git$##')"
    [[ "$owner_repo" =~ ^[^/]+/[^/]+$ ]] || return 1
    printf '%s\n' "$owner_repo"
}

_wmp_cache_file() {
    local repo="$1" owner
    owner="$(_wmp_owner_repo "$repo")" || return 1
    printf '%s/%s.tsv\n' "$(_wmp_cache_dir)" "$owner"
}

_wmp_cache_fresh() {
    local file="$1" epoch now
    [[ -f "$file" && -r "$file" ]] || return 1
    epoch="$(awk 'NR==1 && $1=="#epoch" { print $2; exit }' "$file" 2>/dev/null)"
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    now="$(date +%s)"
    (( now - epoch < 3600 )) || return 1
}

# worktree_pr_cache_populate <main_repo> — batched gh graphql query over the
# repo's worktree branches (MERGED PR heads by headRefName), written atomically
# into the library-owned cache. rc 0 when a fresh cache exists afterwards.
# A batch with alias-specific errors contributes only its valid branches; a
# repository-wide error or parse failure contributes nothing.
worktree_pr_cache_populate() {
    local repo="$1" worktrees line
    local -a branches=()
    local owner cache dir tmp start end index query fields response batch_ok=false any_ok=false
    command -v gh >/dev/null 2>&1 || return 1
    owner="$(_wmp_owner_repo "$repo")" || return 1
    cache="$(_wmp_cache_dir)/$owner.tsv"
    _wmp_cache_fresh "$cache" && return 0
    worktrees="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || return 1
    while IFS= read -r line; do
        case "$line" in branch\ refs/heads/*) branches+=("${line#branch refs/heads/}") ;; esac
    done <<<"$worktrees"
    dir="$(_wmp_cache_dir)"
    mkdir -p "$(dirname "$cache")" 2>/dev/null || return 1
    tmp="$(mktemp "$dir/.pr-cache.XXXXXX")" || return 1
    printf '#epoch %s\n' "$(date +%s)" > "$tmp"
    for ((start=0; start<${#branches[@]}; start+=40)); do
        end=$((start + 40))
        (( end <= ${#branches[@]} )) || end=${#branches[@]}
        query='query($owner: String!, $name: String!'
        fields=''
        local -a variables=(-f "owner=${owner%%/*}" -f "name=${owner#*/}")
        for ((index=start; index<end; index++)); do
            query+=", \$b${index}: String!"
            fields+=" b${index}: pullRequests(headRefName: \$b${index}, states: MERGED, first: 30, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { headRefOid } }"
            variables+=(-f "b${index}=${branches[index]}")
        done
        query+=") { repository(owner: \$owner, name: \$name) {${fields} } }"
        batch_ok=false
        response="$tmp.response"
        if env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh api graphql -f "query=$query" "${variables[@]}" > "$response" 2>/dev/null; then
            if python3 - "$tmp" "$response" "$start" "${branches[@]:start:end-start}" <<'PY'
import json, sys
target, response, start, *branches = sys.argv[1:]
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
    with open(target, 'a') as out:
        for index, branch in enumerate(branches, int(start)):
            alias = 'b' + str(index)
            value = repository.get(alias)
            if alias in failed or not isinstance(value, dict):
                continue
            nodes = value.get('nodes')
            if not isinstance(nodes, list) or any(not isinstance(node, dict) or not isinstance(node.get('headRefOid'), str) or not node['headRefOid'] for node in nodes):
                continue
            out.write(branch + '\t' + ' '.join(node['headRefOid'] for node in nodes) + '\n')
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
PY
            then
                batch_ok=true
            fi
        fi
        rm -f "$response"
        [[ "$batch_ok" == true ]] && any_ok=true
    done
    # Always stamp the attempt for the TTL hour: a fully-failed batch (gh
    # outage / malformed response) must not be retried per worktree; per-branch
    # live fallbacks remain the safety net and fail closed.
    mv -f "$tmp" "$cache"
    return 0
}

# worktree_cached_pr_heads <main_repo> <branch> — MERGED PR heads for branch
# (one per line) from a fresh cache, populating it first when needed.
# rc 1 on any miss, stale cache, or populate failure (caller falls back to a
# live per-branch gh query or treats the worktree as unverified).
worktree_cached_pr_heads() {
    local repo="$1" branch="$2" cache
    [[ -n "$branch" && "$branch" != "detached" ]] || return 1
    worktree_pr_cache_populate "$repo" 2>/dev/null || true
    cache="$(_wmp_cache_file "$repo")" || return 1
    _wmp_cache_fresh "$cache" || return 1
    # Prints the heads one per line (as the per-row gh call does); rc 1 on miss.
    WMP_KEY="$branch" awk -F '\t' 'NR > 1 && $1 == ENVIRON["WMP_KEY"] { n = split($2, h, " "); for (i = 1; i <= n; i++) print h[i]; found = 1; exit } END { exit !found }' "$cache" 2>/dev/null
}

# worktree_head_is_merged_pr <main_repo> <branch> <head_sha>
# rc 0 IFF a gh-verified MERGED PR for that branch has exactly this head.
# rc 1 otherwise — gh failure, empty branch (no gh call at all), differing
# head, or unresolvable remote. Fails closed.
worktree_head_is_merged_pr() {
    local repo="$1" branch="$2" head="$3" owner heads=""
    [[ -n "$branch" && "$branch" != "detached" ]] || return 1
    [[ -n "$head" ]] || return 1
    if heads="$(worktree_cached_pr_heads "$repo" "$branch" 2>/dev/null)" && [[ -n "$heads" ]]; then
        grep -qFx "$head" <<<"$heads" && return 0
        return 1
    fi
    command -v gh >/dev/null 2>&1 || return 1
    owner="$(_wmp_owner_repo "$repo")" || return 1
    heads="$(env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh pr list --repo "$owner" --head "$branch" --state MERGED --json headRefOid -q '.[].headRefOid' 2>/dev/null)" || return 1
    [[ -n "$heads" ]] || return 1
    grep -qFx "$head" <<<"$heads"
}
