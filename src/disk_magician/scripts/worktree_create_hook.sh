#!/usr/bin/env bash
# worktree_create_hook.sh — `diskm worktree-create-hook`, Claude Code
# WorktreeCreate hook (spec D3 + Implementation Preconditions P1).
#
# stdin: {"name": ..., "cwd": ..., ...}. Creates the worktree under
# $STANDARD_WORKTREE_ROOT/<main-repo>/<name> on a unique branch
# worktree-<name>[-N] from origin/HEAD (fallback HEAD); prints the absolute
# path as the only stdout line. Never fetches; git add is capped at 30 s.
# DISK_MAGICIAN_WORKTREE_HOOK=off -> <repo>/.claude/worktrees/<name>.

_WTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/worktree_new.sh
source "$_WTH_DIR/worktree_new.sh"

wth_main() {
    local fields name cwd repo path branch n
    fields="$(python3 -c '
import json, sys
d = json.load(sys.stdin)
n, c = str(d["name"]), str(d["cwd"])
if "\n" in n + c: sys.exit(1)
print(n); print(c)
' 2>/dev/null)" || { echo "worktree-create-hook: bad stdin JSON" >&2; return 1; }
    name="$(sed -n 1p <<<"$fields")"
    cwd="$(sed -n 2p <<<"$fields")"
    _layout_valid_component "$name" || { echo "worktree-create-hook: bad name: $name" >&2; return 1; }
    repo="$(wtn_main_repo "$cwd")" || { echo "worktree-create-hook: not a git repo: $cwd" >&2; return 1; }

    if [[ "${DISK_MAGICIAN_WORKTREE_HOOK:-}" == "off" ]]; then
        path="$repo/.claude/worktrees/$name"
    else
        path="$(standard_worktree_path "$(basename "$repo")" "$name")" || return 1
    fi

    branch="worktree-$name"
    n=2
    while wtn_branch_exists "$repo" "$branch"; do
        branch="worktree-$name-$n"
        n=$((n + 1))
    done
    wtn_create "$repo" "$branch" "$path" "$(wtn_default_base "$repo")"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    wth_main
    exit $?
fi
