#!/usr/bin/env bash
# scratch_new.sh — `diskm scratch-new <repo-path> <purpose> [--kind scratch|evidence]
# [--detach <sha>] [--est-gb N]` (spec C3): admit, create ~/.worktrees/<repo>/
# scratch-<purpose>-<UTC ts> (a detached worktree with --detach) or, for evidence,
# $EVIDENCE_TMP_ROOT/<repo>/evidence/<purpose>-<UTC ts>, lease it, print the path.
# Exit 2 bad args or path outside its root, 75 admission refused (nothing created).
_SN_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# shellcheck source=scripts/worktree_new.sh
source "$_SN_DIR/worktree_new.sh"

# sn_admit <class> <est> <dest> <producer> — caller contract: 0/10 proceed, 75
# refuse, 76 retry once then refuse, any other rc proceeds as degraded (bypass).
# DISK_MAGICIAN_ADMIT_BIN replaces `diskm admit` in tests.
sn_admit() {
    local rc tries=0 admit=("${DISK_MAGICIAN_ADMIT_BIN:-python3}")
    [[ -n "${DISK_MAGICIAN_ADMIT_BIN:-}" ]] || admit+=("$_SN_DIR/disk_budget.py")
    while :; do
        "${admit[@]}" --class "$1" --est-gb "$2" --dest "$3" --producer "$4" --source scratch-new >&2; rc=$?
        case "$rc" in
            0|10) return 0 ;;
            75|76) [[ "$rc" == 76 ]] && (( tries++ == 0 )) && continue
                echo "disk-admission: refused ($1, rc $rc)" >&2; return 75 ;;
            *) echo "admission_degraded:caller (admit rc $rc)" >&2; return 0 ;;
        esac
    done
}

sn_main() {
    local -a pos=()
    local kind=scratch sha="" est=1 repo name path root cls=worktrees src=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kind) kind="${2:-}"; shift 2 || return 2 ;;
            --detach) sha="${2:-}"; shift 2 || return 2 ;;
            --est-gb) est="${2:-}"; shift 2 || return 2 ;;
            -*) echo "scratch-new: unknown option: $1" >&2; return 2 ;;
            *) pos+=("$1"); shift ;;
        esac
    done
    [[ ${#pos[@]} -eq 2 && "${pos[1]}" =~ ^[a-z0-9-]{1,40}$ && "$est" =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
        [[ "$kind" == scratch || ( "$kind" == evidence && -z "$sha" ) ]] ||
        { echo "usage: diskm scratch-new <repo-path> <purpose ^[a-z0-9-]{1,40}\$> [--kind scratch|evidence] [--detach <sha>] [--est-gb N]" >&2; return 2; }
    repo="$(wtn_main_repo "${pos[0]}")" || { echo "scratch-new: not a git repo: ${pos[0]}" >&2; return 2; }
    name="$(wtn_repo_name "$repo")"
    if [[ "$kind" == evidence ]]; then
        cls=tmp_containers root="$EVIDENCE_TMP_ROOT" path="${EVIDENCE_TMP_ROOT%/}/$name/evidence/${pos[1]}-$(date -u +%Y%m%dT%H%M%SZ)"
    else
        root="$STANDARD_WORKTREE_ROOT" path="$(standard_worktree_path "$name" "scratch-${pos[1]}-$(date -u +%Y%m%dT%H%M%SZ)")" || return 2
    fi
    [[ "$(_layout_resolve "$path")" == "$(_layout_resolve "${root%/}")/"* ]] ||
        { echo "scratch-new: $path resolves outside $root" >&2; return 2; }
    if [[ -n "$sha" ]]; then
        sha="$(git -C "$repo" rev-parse -q --verify "$sha^{commit}")" || { echo "scratch-new: unknown commit" >&2; return 1; }
        src="git:$(git -C "$repo" remote get-url origin 2>/dev/null || echo "$repo")@$sha"
    fi
    sn_admit "$cls" "$est" "$path" "scratch-new:$name" || return $?
    mkdir -p "$(dirname "$path")" && mkdir "$path" || return 1
    if [[ -n "$sha" ]] && ! wtn_timeout "${WTN_ADD_TIMEOUT:-30}" git -C "$repo" worktree add --detach "$path" "$sha" >&2; then
        wtn_registered "$repo" "$path" || wtn_unclaim "$path"
        return 1
    fi
    declare -F lease_write >/dev/null 2>&1 && { lease_write "$path" "$repo" "" scratch-new --kind "$kind" \
        --producer scratch-new ${src:+--source "$src"} >/dev/null 2>&1 || echo "scratch-new: lease write failed: $path" >&2; }
    printf '%s\n' "$path"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sn_main "$@"
    exit $?
fi
