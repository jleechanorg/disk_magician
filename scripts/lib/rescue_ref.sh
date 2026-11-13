#!/usr/bin/env bash
# rescue_ref.sh — snapshot a git work tree to a remote rescue ref before removal.
#   rescue_check <dir>  rc 0 when rescuable (git tree, origin, no secret-like file, <= cap). No network/writes.
#   rescue_push  <dir>  push tracked+untracked (ignored excluded) snapshot to refs/diskm-rescue/...,
#                       verify via ls-remote, print the ref, log `rescue`. rc != 0 on any failure.
# The user's index and working tree are never touched: the snapshot uses a throwaway GIT_INDEX_FILE.

_RR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_RR_DIR/worktree_ignored.sh" ]] && source "$_RR_DIR/worktree_ignored.sh"
_RR_PROBE="$_RR_DIR/../c14_probe.py"

_rr_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
    else "$@"; fi
}

# rc 0 when a secret-like file is under <dir> (or the scan fails).
_rr_secret_like() {
    if declare -F _av_secret_like >/dev/null 2>&1; then _av_secret_like "$1"; return; fi
    local res
    res="$(find "$1" -path "$1/.git" -prune -o \( -iname '.env*' -o -iname '*.pem' -o -iname '*.key' \
        -o -iname '*.p12' -o -iname '*.pfx' -o -iname 'id_rsa*' -o -iname 'id_ed25519*' -o -iname 'id_ecdsa*' \
        -o -iname 'id_dsa*' -o -iname .npmrc -o -iname .netrc -o -iname '*credentials*' -o -iname 'secrets*' \) \
        -print -quit 2>/dev/null; echo "rc=$?")"
    [[ "$res" == "rc=0" ]] && return 1
    return 0
}

# The rescue snapshot has only HEAD as its parent. Reject local history or
# unreachable objects that the resulting commit would not retain.
_rr_history_captured() {
    local dir="$1" head outstanding unreachable flags
    local args=(--all --reflog)
    head="$(git -C "$dir" rev-parse --verify -q HEAD^{commit} 2>/dev/null)" || head=""
    [[ -z "$head" ]] || args+=(--not "$head")
    outstanding="$(git -C "$dir" rev-list "${args[@]}" 2>/dev/null)" || return 1
    [[ -z "$outstanding" ]] || return 1
    unreachable="$(git -C "$dir" fsck --connectivity-only --unreachable --no-reflogs --no-progress 2>/dev/null)" || return 1
    ! grep -q '^unreachable ' <<<"$unreachable" || return 1
    flags="$(git -C "$dir" ls-files -v 2>/dev/null)" || return 1
    declare -F _wi_has_flagged_index_entries >/dev/null 2>&1 || return 1
    _wi_has_flagged_index_entries "$dir" "$flags" && return 1
    git -C "$dir" diff --cached --quiet --ignore-submodules=none -- || return 1
    return 0
}

# Snapshot size in bytes (tracked + untracked non-ignored); rc 1 on failure.
_rr_size_bytes() {
    local dir="$1" total=0 n
    while IFS= read -r -d '' f; do
        n="$(stat -c %s -- "$dir/$f" 2>/dev/null || stat -f %z -- "$dir/$f" 2>/dev/null)" || continue
        [[ "$n" =~ ^[0-9]+$ ]] && total=$((total + n))
    done < <(git -C "$dir" ls-files -c -o --exclude-standard -z 2>/dev/null)
    echo "$total"
}

rescue_check() {
    local dir="${1:?rescue_check <dir>}" cap_mb="${DISK_MAGICIAN_RESCUE_CAP_MB:-200}" size url urls
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    [[ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]] || return 1
    # Only a work-tree root is rescuable: a subdirectory (e.g. venv/ inside a repo) would push
    # the parent's snapshot and then lose only the subdirectory's local state.
    [[ "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" == "$(cd "$dir" && pwd -P)" ]] || return 1
    _rr_history_captured "$dir" || return 1
    git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 1
    # A rescue destination borrowing Git objects from the candidate is not an
    # independent backup: deleting the source would remove both copies.
    urls="$(git -C "$dir" remote get-url --push --all origin 2>/dev/null)" || return 1
    [[ -n "$urls" ]] || return 1
    while IFS= read -r url; do
        [[ -n "$url" ]] || return 1
        python3 "$_RR_PROBE" lsremote "$url" "$dir" >/dev/null 2>&1 || return 1
    done <<<"$urls"
    # A nested repository snapshots as a bare gitlink (none of its files or commits), so the
    # push would succeed while its content is lost; keep such trees for on-origin or age.
    [[ -z "$(find "$dir" -mindepth 2 -name .git -print -quit 2>/dev/null)" ]] || return 1
    _rr_secret_like "$dir" && return 1
    declare -F has_ignored_user_data >/dev/null 2>&1 || return 1
    has_ignored_user_data "$dir" && return 1
    [[ "$cap_mb" =~ ^[0-9]+$ ]] || return 1
    size="$(_rr_size_bytes "$dir")" || return 1
    (( size <= cap_mb * 1024 * 1024 )) || return 1
    return 0
}

rescue_push() {
    local dir="${1:?rescue_push <dir>}" tmp idx head tree commit parent ref short host base out kb
    rescue_check "$dir" || { echo "rescue_push: not rescuable: $dir" >&2; return 1; }
    tmp="$(mktemp -d)" || return 1
    idx="$tmp/index"
    parent=""
    if head="$(git -C "$dir" rev-parse --verify -q HEAD^{commit})"; then
        parent="$head"
        GIT_INDEX_FILE="$idx" git -C "$dir" read-tree "$head" || { rm -rf -- "${tmp:?}"; return 1; }
    fi
    if ! GIT_INDEX_FILE="$idx" git -C "$dir" add -A . >/dev/null 2>&1; then
        rm -rf -- "${tmp:?}"; return 1
    fi
    tree="$(GIT_INDEX_FILE="$idx" git -C "$dir" write-tree)" || { rm -rf -- "${tmp:?}"; return 1; }
    rm -rf -- "${tmp:?}"
    commit="$(GIT_AUTHOR_NAME=diskm GIT_AUTHOR_EMAIL=diskm@localhost GIT_COMMITTER_NAME=diskm \
        GIT_COMMITTER_EMAIL=diskm@localhost git -C "$dir" commit-tree "$tree" ${parent:+-p "$parent"} \
        -m "diskm rescue snapshot of $dir")" || return 1
    short="${commit:0:8}"
    host="$(hostname -s 2>/dev/null || echo host)"
    base="$(basename "$dir")"
    base="${base//[^A-Za-z0-9._-]/_}"
    ref="refs/diskm-rescue/${host//[^A-Za-z0-9._-]/_}/$(date -u +%Y%m%d)/${base}-${short}"
    _rr_timeout 60 git -C "$dir" push -q origin "$commit:$ref" >/dev/null 2>&1 || { echo "rescue_push: push failed" >&2; return 1; }
    out="$(_rr_timeout 60 git -C "$dir" ls-remote origin "$ref" 2>/dev/null)" || return 1
    [[ "$out" == "$commit"$'\t'"$ref" ]] || { echo "rescue_push: verify mismatch" >&2; return 1; }
    if ! declare -F deletion_log >/dev/null 2>&1; then
        # shellcheck source=scripts/safety_lib.sh
        source "$_RR_DIR/../safety_lib.sh" 2>/dev/null || true
    fi
    kb=0
    if declare -F deletion_log >/dev/null 2>&1; then
        deletion_log rescue_ref rescue "$kb" "$dir" "ref=$ref commit=$commit"
    fi
    echo "$ref"
}
