#!/usr/bin/env bash
# shellcheck shell=bash
# layout_standard.sh — single source of truth for where agents put disk-heavy
# output (spec docs/superpowers/specs/2026-10-05-standard-worktree-root-and-
# evidence-location-design.md, D1):
#   worktrees  -> $HOME/.worktrees/<repo>/<name>
#   evidence   -> /tmp/<repo>/evidence/<slug>/ (scratch), durable copies in a
#                 gist or $EVIDENCE_GCS_PREFIX/<repo>/<slug>/
#
# Exposes:
#   standard_worktree_path <repo> <name>   # prints path; rc 1 on unsafe input
#   path_is_under_standard_root <abs-path> # rc 0 if strictly below the root
#
# Not meant to be executed directly.

STANDARD_WORKTREE_ROOT="${STANDARD_WORKTREE_ROOT:-$HOME/.worktrees}"
EVIDENCE_TMP_ROOT="${EVIDENCE_TMP_ROOT:-/tmp}"
EVIDENCE_GCS_PREFIX="${EVIDENCE_GCS_PREFIX:-gs://wa-test-evidence/agent-evidence}"

_layout_valid_component() {
    local c="${1:-}"
    [[ -n "$c" && "$c" != "." && "$c" != ".." && "$c" != *"/"* ]]
}

standard_worktree_path() {
    local repo="${1:-}" name="${2:-}"
    _layout_valid_component "$repo" || return 1
    _layout_valid_component "$name" || return 1
    printf '%s/%s/%s\n' "${STANDARD_WORKTREE_ROOT%/}" "$repo" "$name"
}

# Resolves symlinks in the longest existing prefix (so a link inside the root
# that points elsewhere does not count) and normalizes `..` lexically.
_layout_resolve() {
    python3 - "$1" <<'PY'
import os, sys
p = os.path.normpath(sys.argv[1])
head, tail = p, []
while head and not os.path.exists(head):
    head, t = os.path.split(head)
    tail.insert(0, t)
print(os.path.join(os.path.realpath(head or "/"), *tail))
PY
}

path_is_under_standard_root() {
    local p="${1:-}"
    [[ "$p" == /* ]] || return 1
    local root resolved
    root="$(_layout_resolve "${STANDARD_WORKTREE_ROOT%/}")" || return 1
    resolved="$(_layout_resolve "$p")" || return 1
    [[ "$resolved" == "$root/"* ]]
}
