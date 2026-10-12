#!/usr/bin/env bash
# artifact_verdict.sh — C14 artifact_removal_verdict (spec §7.2), sourced.
# Discovery and per-repository content checks; the verdict keeps every path and
# the self-test is `incomplete` until the rest of C14 lands (activation blocked).

_AV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$_AV_DIR/worktree_ignored.sh"
# shellcheck source=scripts/worktree_remove_hook.sh
source "$_AV_DIR/../worktree_remove_hook.sh" # has_hidden_state
# shellcheck source=scripts/lib/scratch_roots.sh
source "$_AV_DIR/scratch_roots.sh"

# c14_discover_repos <root>: print every repository under <root> (itself
# included), NUL-terminated and absolute: a dir holding a `.git` dir or file,
# or a bare repo (HEAD + objects/ + refs/). No -prune, so ignored dirs are
# walked too. rc 1 when the walk is incomplete or a path escapes <root>; the
# OK sentinel can never be a find path, which starts with "/".
c14_discover_repos() {
    local root p d done=
    root="$(cd "$1" 2>/dev/null && pwd -P)" && [[ "$root" == /* ]] || return 1
    while IFS= read -r -d '' p; do
        [[ "$p" == OK ]] && { done=1; continue; }
        [[ "$p" == "$root"/* ]] || return 1
        d="${p%/*}"
        if [[ "${p##*/}" == .git ]]; then
            printf '%s\0' "$d"
        # A bare repo; git internals (.git/modules, .git/worktrees) go with their owner.
        elif [[ -f "$p" && -d "$d/objects" && -d "$d/refs" && "/$d/" != */.git/* ]]; then
            printf '%s\0' "$d"
        fi
    done < <(find "$root" \( -name .git -o -name HEAD \) -print0 2>/dev/null && printf 'OK\0')
    [[ -n "$done" ]]
}

# c14_repo_content_ok <repo>: print `ok` (rc 0) or `kept:<reason>` (rc 1).
# Git env dropped; git must resolve <repo> itself, not an ancestor (broken .git).
c14_repo_content_ok() (
    local r=$1 st flags && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES
    case "$(git -C "$r" rev-parse --is-bare-repository 2>/dev/null)" in
        true) [[ "$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null)" == "$r" ]] && { echo ok; return 0; } ;;
        false) [[ "$(git -C "$r" rev-parse --show-toplevel 2>/dev/null)" == "$r" ]] ;;
        *) false ;;
    esac || { echo kept:check-failed; return 1; }
    if ! st="$(git -C "$r" status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null)" ||
        ! flags="$(git -C "$r" ls-files -v 2>/dev/null)"; then
        echo kept:check-failed; return 1
    fi
    # Tracked or submodule changes, untracked files, or hidden index flags.
    if [[ -n "$st" ]] || grep -q '^[a-zS]' <<<"$flags"; then
        echo kept:dirty; return 1
    fi
    has_hidden_state "$r" && { echo kept:secret-like; return 1; }
    has_ignored_user_data "$r" && { echo kept:ignored-data; return 1; }
    echo ok
)

# c14_repo_pushed_ok <repo> [<root>]: all commits in the live ls-remote set of remotes
# outside <root> (default <repo>). Independent repo: every ref and reflog, no unreachable
# object, .git = lease git_meta. Registered linked worktree: only its branch, the branch
# reflog and the ids under its admin dir (allowlisted names), then wrh_removal_verdict.
c14_repo_pushed_ok() (
    local r=$1 root=${2:-$1} gd cd kv out adv have tips='' unp v linked= scope=(--all --reflog)
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES
    gd="$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null)" &&
        cd="$(git -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
        { echo kept:check-failed; return 1; }
    if [[ "$cd" != "$gd" ]]; then
        [[ "$(git -C "$r" config --get extensions.refStorage || echo files)" == files ]] &&
            tips="$(python3 "$_AV_DIR/../c14_probe.py" admin "$gd" "$(lease_path_for "$r" 2>/dev/null)")" ||
            { echo kept:check-failed; return 1; }
        [[ "$tips" == kept:* ]] && { echo "$tips"; return 1; }
        tips+=$'\n'"$(git -C "$r" rev-parse --verify -q HEAD)" || { echo kept:check-failed; return 1; }
        scope=() linked=1
    fi
    while IFS= read -r -d '' kv; do
        out="$(python3 "$_AV_DIR/../c14_probe.py" lsremote "${kv#*$'\n'}" "$root")" || { echo kept:remote-unverified; return 1; }
        adv+="$out"$'\n'
    done < <(git -C "$r" config -z --get-regexp '^remote\..*\.url$' 2>/dev/null)
    # Advertised SHAs present locally become negative tips.
    have="$(cut -f1 <<<"$adv" | git -C "$r" cat-file --batch-check='%(objectname)' 2>/dev/null | grep -v ' missing$' | sed 's/^/^/')"
    unp="$(git -C "$r" rev-list ${scope[@]+"${scope[@]}"} --stdin -n1 < <(printf '%s\n' $tips $have) 2>/dev/null)" || { echo kept:check-failed; return 1; }
    [[ -z "$unp" ]] || { echo kept:not-pushed; return 1; }
    if [[ -n "$linked" ]]; then  # linked: unreachable objects stay in the common store
        v="$(wrh_removal_verdict "$r" minutes:30 origin-or-merged-pr)"
        [[ "$v" == remove ]] && { echo ok; return 0; }
        echo "$v"; return 1
    fi
    out="$(git -C "$r" fsck --connectivity-only --unreachable --no-reflogs --no-progress 2>/dev/null)" ||
        { echo kept:check-failed; return 1; }
    grep -q '^unreachable ' <<<"$out" && { echo kept:unreachable-object; return 1; }
    v="$(python3 "$_AV_DIR/../c14_probe.py" gitmeta "$gd" "$(lease_path_for "$r" 2>/dev/null)")"
    echo "${v:-kept:check-failed}"
    [[ "$v" == ok ]]
)

# c14_repos_ok <root> [--outer-certificate <receipt>]: content and remote checks on every
# repository found; `ok` or the first kept reason. Certificate unused here.
c14_repos_ok() {
    local r v done=
    while IFS= read -r -d '' r; do
        [[ "$r" == OK ]] && { done=1; continue; }
        v="$(c14_repo_content_ok "$r")" || { echo "$v"; return 1; }
        v="$(c14_repo_pushed_ok "$r" "$1")" || { echo "$v"; return 1; }
    done < <(c14_discover_repos "$1" && printf 'OK\0')
    [[ -n "$done" ]] || { echo kept:check-failed; return 1; }
    echo ok
}

# c14_ephemeral_retention <canonical path>: minutes of the declared-ephemeral row E2-E7
# it matches (§7.2; longest wins), rc 1 for none. Fixed floors; E1 is not a row here.
c14_ephemeral_retention() {
    local p=$1 r rel
    while IFS= read -r r; do
        r="$(cd "$r" 2>/dev/null && pwd -P)" && rel=${p#"$r"/} && [[ "$rel" != "$p" && "$rel" != _disk_magician_archive* ]] || continue
        if [[ "$rel" =~ ^(pr[0-9]|pr-|pr_|claude-|claude_)[^/]*$ ]]; then echo 2880
        elif [[ ( "$rel" =~ ^agent_prompt_[^/]*\.txt$ && -f "$p" ) || ( "$rel" =~ ^[^/]+(/[^/]+)?$ && -d "$p/.git" ) ]]; then echo 240
        elif [[ ( "$rel" =~ ^cli_validation_gemini_[^/]*$ && -d "$p" ) || ( "$rel" != */* && -f "$p/.git" ) ]]; then echo 60
        else continue; fi
        return 0
    done < <(scratch_roots_get_unique)
    rel=${p#"$HOME"/}
    if [[ "$rel" =~ ^\.gemini/antigravity/(brain|implicit)\.backup$ ]]; then echo 43200
    elif [[ "$rel" =~ ^\.gemini/antigravity(-cli)?/brain/[^/]+$ ]]; then echo 30240
    elif [[ "$rel" =~ ^\.aside/u/[^/]+/sessions/[^/]+$ || "$rel" =~ ^\.claude/supervisor/cmux-codex-launchd\.[0-9]{8}T[0-9]{6}\.log$ ]]; then echo 10080
    elif [[ "$rel" =~ ^\.llm-inspector/captures/(capture-[^/]*\.json|[^/]*\.summary\.json)$ ]]; then echo 4320
    else return 1; fi
}
# _av_newest_mtime <path>: newest mtime of <path> and everything under it; rc 1 if unmeasurable.
_av_newest_mtime() ( set -o pipefail; find "$1" -print0 2>/dev/null | xargs -0 stat -f %m 2>/dev/null | sort -n | tail -1 | grep -E '^[0-9]+$'; )
# _av_open_file <path>: rc 0 when lsof prints anything (an open non-cwd fd or an error).
_av_open_file() {
    local d=() && [[ -d "$1" ]] && d=(+D)
    [[ -n "$(lsof -w -n -P -Fn -a -d '^cwd' ${d[@]+"${d[@]}"} "$1" 2>&1)" ]]
}
# _av_secret_like <path>: rc 0 when a secret-like name (wrh patterns) is under <path> or find fails.
_av_secret_like() {
    local out
    out="$(find "$1" \( -iname '.env*' -o -iname '*.pem' -o -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' \
        -o -iname 'id_rsa*' -o -iname 'id_ed25519*' -o -iname 'id_ecdsa*' -o -iname 'id_dsa*' -o -iname .npmrc \
        -o -iname .netrc -o -iname '*credentials*' -o -iname 'secrets*' \) ! -name '*.pyc' ! -path '*/__pycache__/*' \
        -print 2>/dev/null)" || return 0
    [[ -n "$out" ]]
}
# _av_lease_scope <path>: NUL-list <path>, its ancestors below its scratch root (else
# $HOME, else /) and every repository under it; rc 1 when discovery is incomplete.
_av_lease_scope() {
    local a=${1%/*} r stops=$'\n'
    while IFS= read -r r; do r="$(cd "$r" 2>/dev/null && pwd -P)" && stops+="$r"$'\n'; done < <(scratch_roots_get_unique)
    stops+="$(cd "$HOME" 2>/dev/null && pwd -P)"$'\n'
    printf '%s\0' "$1"
    while [[ -n "$a" && "$stops" != *$'\n'"$a"$'\n'* ]]; do printf '%s\0' "$a"; a=${a%/*}; done
    [[ ! -d "$1" ]] || c14_discover_repos "$1"
}

# artifact_removal_verdict <path> [...] | --self-test
artifact_removal_verdict() {
    [[ "${1:-}" == --self-test ]] && { echo incomplete; return 0; }
    local p kind='' q done='' st newest ret  # --kind ephemeral adds provenance (c); others keep
    [[ "${2:-}" == --kind ]] && kind=${3:-}
    p=${1%/} && [[ ! "${p##*/}" =~ ^\.{0,2}$ ]] && p="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/${p##*/}" && [[ -e "$p" && ! -L "$p" ]] || { echo kept:check-failed; return 0; }
    "$_AV_DIR/../safety_check.sh" "$p" >/dev/null 2>&1 || { echo kept:protected; return 0; }
    while IFS= read -r -d '' q; do  # a lease not dead or released keeps; absent only on ENOENT
        [[ "$q" == OK ]] && { done=1; continue; }
        q="$(lease_path_for "$q")" || { echo kept:check-failed; return 0; }
        case "$(python3 -c 'import os,sys;d=os.path.dirname(sys.argv[1])
try:os.stat(d);os.stat(sys.argv[1]);print("lease" if os.access(d,os.R_OK|os.X_OK) else "")
except FileNotFoundError:print("none")' "$q" 2>/dev/null)" in none) continue ;; lease) ;; *) echo kept:owner-unknown; return 0 ;; esac
        case "$(lease_owner_state "$q")" in dead|released) ;; alive*) echo kept:live-owner; return 0 ;; *) echo kept:owner-unknown; return 0 ;; esac
    done < <(_av_lease_scope "$p" && printf 'OK\0')
    [[ -n "$done" ]] || { echo kept:check-failed; return 0; }
    wrh_live_cwd_reason "$p"
    [[ -z "$WRH_LIVE_CWD_REASON" ]] || { echo "kept:$WRH_LIVE_CWD_REASON"; return 0; }
    _av_open_file "$p" && { echo kept:open-file; return 0; }
    newest="$(_av_newest_mtime "$p")" || { echo kept:mtime-unmeasurable; return 0; }
    (( $(date +%s) - newest >= 3600 )) || { echo kept:recent-activity; return 0; }
    _av_secret_like "$p" && { echo kept:secret-like; return 0; }
    if [[ -d "$p" ]]; then st="$(c14_repos_ok "$p")" || { echo "$st"; return 0; }; fi
    [[ "$kind" == ephemeral ]] && ret="$(c14_ephemeral_retention "$p")" || { echo kept:unproven-content; return 0; }
    (( $(date +%s) - newest > ret * 60 )) || { echo kept:recent-activity; return 0; }
    echo remove
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then artifact_removal_verdict "$@"; fi
