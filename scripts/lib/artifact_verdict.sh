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
    local r=$1 root=${2:-$1} deadline=${3:-} gd cd kv out adv='' have tips='' unp v linked= scope=(--all --reflog)
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
        out="$(python3 "$_AV_DIR/../c14_probe.py" lsremote "${kv#*$'\n'}" "$root" ${deadline:+"$deadline"})" || {
            [[ "$out" == deferred:* ]] && { echo "$out"; return 1; }
            echo kept:remote-unverified; return 1;
        }
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
c14_check_repo_list() {
    local root=$1 deadline=${2:-} r v done=
    while IFS= read -r -d '' r; do
        [[ "$r" == OK ]] && { done=1; continue; }
        [[ "$r" == kept:* ]] && { echo "$r"; return 1; }
        v="$(c14_repo_content_ok "$r")" || { echo "$v"; return 1; }
        v="$(c14_repo_pushed_ok "$r" "$root" "$deadline")" || { echo "$v"; return 1; }
    done
    [[ -n "$done" ]] || { echo kept:check-failed; return 1; }
    echo ok
}

c14_repos_ok() {
    local root=$1 inv=${2:-} deadline=${3:-}
    if [[ "$inv" == --outer-certificate ]]; then
        c14_check_repo_list "$root" "" < <(c14_discover_repos "$root" && printf 'OK\0')
        return
    fi
    if [[ -n "$inv" ]]; then
        c14_check_repo_list "$root" "$deadline" < <(C14_ROOT="$root" python3 "$_AV_DIR/../c14_probe.py" repos "$inv" && printf 'OK\0')
    else
        c14_check_repo_list "$root" "$deadline" < <(c14_discover_repos "$root" && printf 'OK\0')
    fi
}

# c14_ephemeral_retention <canonical path>: minutes of the declared-ephemeral row E2-E7
# it matches (§7.2; longest wins), rc 1 for none. Fixed floors; E1 is not a row here.
c14_ephemeral_retention() {
    local p=$1 r rel
    while IFS= read -r r; do
        r="$(cd "$r" 2>/dev/null && pwd -P)" && rel=${p#"$r"/} && [[ "$rel" != "$p" && ! "$rel" =~ ^(_disk_magician_archive|system-|com\.apple\.|PowerlogHelperd) ]] || continue
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
# _av_rebuildable <path>: rc 0 under the cache-root table (§7.2 (b)) or, as cleanup_worktree_venvs,
# an untracked venv dir atop a linked worktree passing the content and push checks.
_av_rebuildable() (
    local h w g t re='^(\.cache/(uv|pre-commit)|\.npm/_cacache|\.local/share/opencode/(repos|log|tool-output|snapshot)|Snapchat/Dev/\.cache/bazel|Library/Developer/(Xcode/DerivedData|CoreSimulator/(Caches|Temp)))/[^/]'
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES
    [[ "${1##*/}" =~ ^(venv|\.venv|venv\.bak(\..+)?)$ ]] && { w="$(git -C "${1%/*}" rev-parse --show-toplevel 2>/dev/null)" && [[ "$w" == "${1%/*}" ]] && g="$(git -C "$w" rev-parse --absolute-git-dir 2>/dev/null)" && [[ "$g" != "$(git -C "$w" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]] && t="$(git --literal-pathspecs -C "$w" ls-files -- "${1##*/}" 2>/dev/null)" && [[ -z "$t" ]] && c14_repo_content_ok "$w" >/dev/null && c14_repo_pushed_ok "$w" >/dev/null; return; }
    h="$(cd "$HOME" 2>/dev/null && pwd -P)" && [[ -n "$h" && "${1#"$h"/}" =~ $re ]]
)
# _av_newest_mtime <path>: newest mtime of <path> and everything under it; rc 1 if unmeasurable.
_av_newest_mtime() { python3 "$_AV_DIR/../c14_probe.py" newest-mtime "$1"; }
# _av_open_file <path>: rc 0 when lsof prints anything (an open non-cwd fd or an error).
_av_open_file() { python3 "$_AV_DIR/../c14_probe.py" open-file "$1" "${2:-}"; }
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
    if [[ -d "$1" ]]; then
        if [[ -n "${2:-}" ]]; then C14_ROOT="$1" python3 "$_AV_DIR/../c14_probe.py" repos "$2"
        else c14_discover_repos "$1"; fi
    fi
}

# _av_path_identity <path>: filesystem identity in the format used by
# cleanup_code_sign_clones.sh. Both macOS and GNU stat forms are accepted.
_av_path_identity() {
    local id
    id="$(stat -f '%d:%i:%u' "$1" 2>/dev/null)" || id=''
    [[ "$id" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || id="$(stat -c '%d:%i:%u' "$1" 2>/dev/null)" || return 1
    [[ "$id" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
    printf '%s\n' "$id"
}

# _av_os_clone_proof <path> <candidate-id> <parent-id> <X-root-id>: the
# caller freezes all three identities during enumeration and passes them back
# at the final verdict. The path must still be a recognized code-sign clone
# under the canonical X scan root and each identity must still match.
_av_os_clone_proof() {
    local p=$1 candidate_id=$2 parent_id=$3 root_id=$4 user_tmp x_dir parent base uid
    [[ "$candidate_id" =~ ^[0-9]+:[0-9]+:[0-9]+$ && "$parent_id" =~ ^[0-9]+:[0-9]+:[0-9]+$ &&
        "$root_id" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
    if [[ -n "${DISK_MAGICIAN_CODE_SIGN_X_DIR:-}" ]]; then
        x_dir="$(cd "$DISK_MAGICIAN_CODE_SIGN_X_DIR" 2>/dev/null && pwd -P)" || return 1
    else
        user_tmp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" || return 1
        user_tmp="$(cd "$user_tmp" 2>/dev/null && pwd -P)" || return 1
        x_dir="$(cd "$(dirname "$user_tmp")/X" 2>/dev/null && pwd -P)" || return 1
    fi
    [[ -n "$x_dir" && -d "$x_dir" && ! -L "$x_dir" && "$p" == "$x_dir/"* ]] || return 1
    parent=${p%/*}; base=${p##*/}
    if [[ "$parent" == "$x_dir" ]]; then
        [[ "$base" == *.code_sign_clone ]] || return 1
    else
        [[ "${parent%/*}" == "$x_dir" && "${parent##*/}" == *.code_sign_clone && "$base" == code_sign_clone.* ]] || return 1
    fi
    [[ -d "$p" && ! -L "$p" && ! -L "$parent" ]] || return 1
    uid="$(id -u)" || return 1
    [[ "$(_av_path_identity "$p")" == "$candidate_id" && "${candidate_id##*:}" == "$uid" &&
        "$(_av_path_identity "$parent")" == "$parent_id" && "$(_av_path_identity "$x_dir")" == "$root_id" &&
        "${parent_id##*:}" == "$uid" && "${root_id##*:}" == "$uid" ]]
}

# artifact_removal_verdict <path> [...] | --self-test
_av_artifact_removal_verdict() {
    [[ "${1:-}" == --self-test ]] && { echo incomplete; return 0; }
    local p=${1:-} kind='' deadline='' inventory_out='' q done='' st newest ret frozen_id='' frozen_parent_id='' frozen_root_id='' inv
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kind|--frozen-identity|--frozen-parent-identity|--frozen-root-identity|--deadline-at|--cursor|--inventory-out)
                [[ $# -ge 2 ]] || { echo kept:check-failed; return 0; }
                case "$1" in
                    --kind) kind=$2 ;;
                    --frozen-identity) frozen_id=$2 ;;
                    --frozen-parent-identity) frozen_parent_id=$2 ;;
                    --frozen-root-identity) frozen_root_id=$2 ;;
                    --deadline-at) deadline=$2 ;;
                    --inventory-out) inventory_out=$2 ;;
                esac
                shift 2 ;;
            *) shift ;;
        esac
    done
    p=${p%/} && [[ ! "${p##*/}" =~ ^\.{0,2}$ ]] && p="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/${p##*/}" && [[ -e "$p" && ! -L "$p" ]] || { echo kept:check-failed; return 0; }
    if [[ -n "$deadline" && ! "$deadline" =~ ^[0-9]+([.][0-9]+)?$ ]]; then echo kept:check-failed; return 0; fi
    "$_AV_DIR/../safety_check.sh" "$p" >/dev/null 2>&1 || { echo kept:protected; return 0; }
    q="$_AV_DIR/../../config.json" && [[ -f "$q" ]] || q+=.template  # never-touch tmp roots, as cleanup_tmp.sh
    while IFS= read -r st; do [[ "/$p/" != *"/$st/"* ]] || { echo kept:protected; return 0; }; done < <(scratch_roots_protected "$q")
    if [[ -n "${DISK_MAGICIAN_TEST_AFTER_NOMINATE:-}" ]]; then
        [[ "${DISK_MAGICIAN_TEST_CONTEXT:-}" == 1 ]] || { echo kept:check-failed; return 0; }
        printf 'race fixture\n' >"$DISK_MAGICIAN_TEST_AFTER_NOMINATE" || { echo kept:check-failed; return 0; }
    fi
    inv=${C14_INVENTORY_FILE:-}
    [[ -n "$inv" ]] || { echo kept:check-failed; return 0; }
    st="$(python3 "$_AV_DIR/../c14_probe.py" inventory "$p" "$inv" ${deadline:+"$deadline"})"
    if [[ "$st" != ok ]]; then echo "${st:-kept:check-failed}"; return 0; fi
    while IFS= read -r -d '' q; do  # a lease not dead or released keeps; absent only on ENOENT
        [[ "$q" == OK ]] && { done=1; continue; }
        q="$(lease_path_for "$q")" || { echo kept:check-failed; return 0; }
        case "$(python3 -c 'import os,sys;d=os.path.dirname(sys.argv[1])
try:os.stat(d);os.stat(sys.argv[1]);print("lease" if os.access(d,os.R_OK|os.X_OK) else "")
except FileNotFoundError:print("none")' "$q" 2>/dev/null)" in none) continue ;; lease) ;; *) echo kept:owner-unknown; return 0 ;; esac
        case "$(lease_owner_state "$q")" in dead|released) ;; alive*) echo kept:live-owner; return 0 ;; *) echo kept:owner-unknown; return 0 ;; esac
    done < <(_av_lease_scope "$p" "$inv" && printf 'OK\0')
    [[ -n "$done" ]] || { echo kept:check-failed; return 0; }
    wrh_live_cwd_reason "$p"
    [[ -z "$WRH_LIVE_CWD_REASON" ]] || { echo "kept:$WRH_LIVE_CWD_REASON"; return 0; }
    st="$(_av_open_file "$p" "$deadline")"
    [[ "$st" == deferred:* ]] && { echo "$st"; return 0; }
    [[ "$st" == yes ]] && { echo kept:open-file; return 0; }
    newest="$(_av_newest_mtime "$inv")" || { echo kept:mtime-unmeasurable; return 0; }
    (( $(date +%s) - newest >= 3600 )) || { echo kept:recent-activity; return 0; }
    st="$(python3 "$_AV_DIR/../c14_probe.py" secrets "$inv")"
    if [[ "$st" != no ]]; then [[ "$st" == yes ]] && st=kept:secret-like; echo "${st:-kept:check-failed}"; return 0; fi
    if [[ -d "$p" ]]; then st="$(c14_repos_ok "$p" "$inv" "$deadline")" || { echo "$st"; return 0; }; fi
    case "$kind" in
        ephemeral) ret="$(c14_ephemeral_retention "$p")" || { echo kept:unproven-content; return 0; }
            (( $(date +%s) - newest > ret * 60 )) || { echo kept:recent-activity; return 0; } ;;
        rebuildable) _av_rebuildable "$p" || { echo kept:unproven-content; return 0; } ;;
        os_clone) _av_os_clone_proof "$p" "$frozen_id" "$frozen_parent_id" "$frozen_root_id" || { echo kept:check-failed; return 0; } ;;
        '') st="$({ C14_ROOT="$p" python3 "$_AV_DIR/../c14_probe.py" repos "$inv" && printf 'OK\0'; } |
                    python3 "$_AV_DIR/../c14_probe.py" provenance "$p" "$(lease_path_for "$p")" "$deadline")"
            [[ "$st" == ok ]] || { [[ "$st" == kept:* ]] && echo "$st" || echo kept:check-failed; return 0; } ;;
        *) echo kept:unproven-content; return 0 ;;
    esac
    if [[ -n "$inventory_out" ]]; then
        mkdir -p "$(dirname "$inventory_out")" || { echo kept:check-failed; return 0; }
        st="$(python3 "$_AV_DIR/../c14_probe.py" merge-inventory "$inv" "${C14_ADMIN_INVENTORY:-}" "$inventory_out.tmp.$$")"
        [[ "$st" == ok ]] && mv -f "$inventory_out.tmp.$$" "$inventory_out" || { rm -f "$inventory_out.tmp.$$"; echo kept:check-failed; return 0; }
    fi
    echo remove
}

artifact_removal_verdict() {
    [[ "${1:-}" == --self-test ]] && { echo incomplete; return 0; }
    local tmpdir inv result reason admin_inv
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/c14-verdict.XXXXXX")" || { echo kept:check-failed; return 0; }
    inv="$tmpdir/inventory.json"
    admin_inv=${C14_INVENTORY_OUT:-"$inv.admin.jsonl"}
    result="$(C14_INVENTORY_FILE="$inv" C14_ADMIN_INVENTORY="$admin_inv" C14_INVENTORY_OUT="$admin_inv" _av_artifact_removal_verdict "$@")"
    if [[ ( "$result" == kept:* || "$result" == deferred:* ) && -f "$inv" && -n "${DISK_MAGICIAN_C14_LEDGER:-}" ]]; then
        reason=${result#*:}
        python3 "$_AV_DIR/../c14_probe.py" account "$inv" "$DISK_MAGICIAN_C14_LEDGER" "$reason" >/dev/null 2>&1 || true
    fi
    rm -f "$inv"
    rmdir "$tmpdir" 2>/dev/null || true
    echo "${result:-kept:check-failed}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then artifact_removal_verdict "$@"; fi
