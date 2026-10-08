#!/usr/bin/env bash
# worktree_create_hook.sh — `diskm worktree-create-hook`, Claude Code
# WorktreeCreate hook (spec D3 + Implementation Preconditions P1).
#
# stdin: {"name": ..., "cwd": ..., ...}. Creates the worktree under
# $STANDARD_WORKTREE_ROOT/<main-repo>/<name> on a unique branch
# worktree-<name>[-N] from origin/HEAD (path also gets -N if taken) (fallback HEAD); prints the absolute
# path as the only stdout line. Never fetches; git add is capped at 30 s.
# DISK_MAGICIAN_WORKTREE_HOOK=off -> <repo>/.claude/worktrees/<name>.

_WTH_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# shellcheck source=scripts/worktree_new.sh
source "$_WTH_DIR/worktree_new.sh"

wth_main() {
    local fields name cwd repo path branch n k p rc tries=0
    fields="$(python3 -c '
import json, sys
d = json.load(sys.stdin)
n, c = d["name"], d["cwd"]
if not (isinstance(n, str) and isinstance(c, str)) or "\n" in n + c: sys.exit(1)
print(n); print(c)
' 2>/dev/null)" || { echo "worktree-create-hook: bad stdin JSON" >&2; return 1; }
    name="$(sed -n 1p <<<"$fields")"
    cwd="$(sed -n 2p <<<"$fields")"
    { _layout_valid_component "$name" && git check-ref-format --branch "worktree-$name" >/dev/null 2>&1; } ||
        { echo "worktree-create-hook: bad name: $name" >&2; return 1; }
    repo="$(wtn_main_repo "$cwd")" || { echo "worktree-create-hook: not a git repo: $cwd" >&2; return 1; }

    if [[ "${DISK_MAGICIAN_WORKTREE_HOOK:-}" == "off" ]]; then
        path="$repo/.claude/worktrees/$name"
    else
        path="$(standard_worktree_path "$(wtn_repo_name "$repo")" "$name")" || return 1
    fi

    # Branch taken -> worktree-<name>-N; path taken -> <path>-N. A lost claim
    # race on either (rc 2 path, rc 3 branch) re-picks instead of failing.
    branch="worktree-$name"
    n=2
    p="$path"
    k=2
    while [[ "$k" -le 100 && "$n" -le 100 && "$tries" -lt 50 ]]; do
        if wtn_branch_exists "$repo" "$branch" || wtn_remote_branch_exists "$repo" "$branch"; then
            branch="worktree-$name-$n"; n=$((n + 1)); continue
        fi
        if [[ -e "$p" || -L "$p" ]]; then
            p="$path-$k"; k=$((k + 1)); continue
        fi
        tries=$((tries + 1))
        wtn_create "$repo" "$branch" "$p" "$(wtn_default_base "$repo")" new; rc=$?
        case "$rc" in
            2) p="$path-$k"; k=$((k + 1)) ;;
            3) branch="worktree-$name-$n"; n=$((n + 1)) ;;
            *) return "$rc" ;;
        esac
    done
    echo "worktree-create-hook: no free path for $path" >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    wth_main
    exit $?
fi
