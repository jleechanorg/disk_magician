#!/usr/bin/env bash
# Shared durable restore receipt validation for worktree retirement.
#
# Receipts are input-only evidence.  This library never creates, fetches, or
# uploads a backup; callers decide whether a receipt is required for their
# operation and invoke the live-match check immediately before removal.

# worktree_restore_receipt_resolve <worktree> <receipt-root>
# Resolve one exact receipt name.  A root may itself be a receipt file, but a
# directory must contain exactly one of the target's canonical names.
worktree_restore_receipt_resolve() {
    local path="$1" root="$2" real sha leaf candidate metadata=""
    real="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
    sha="$(git -C "$real" rev-parse --verify HEAD 2>/dev/null)" || return 1
    [[ -n "$root" ]] || return 1
    if [[ -f "$root" ]]; then
        metadata="$root"
    elif [[ -d "$root" && ! -L "$root" ]]; then
        leaf="${real##*/}"
        leaf="${leaf//[^A-Za-z0-9._-]/_}"
        [[ -n "$leaf" ]] || leaf=worktree
        for candidate in \
            "$root/${leaf}-${sha}/restore-receipt.json" \
            "$root/${leaf}-${sha}/metadata.json" \
            "$root/${leaf}-${sha}.json" \
            "$root/${leaf}/restore-receipt.json"; do
            [[ -f "$candidate" && ! -L "$candidate" ]] || continue
            [[ -z "$metadata" ]] || return 1
            metadata="$candidate"
        done
    fi
    [[ -n "$metadata" && -f "$metadata" && ! -L "$metadata" ]] || return 1
    printf '%s\n' "$metadata"
}

# worktree_restore_receipt_validate <worktree> <receipt>
# Validate the receipt against the current worktree identity and configured
# upstream.  The remote SHA is checked again by the live-match function.
worktree_restore_receipt_validate() {
    local path="$1" metadata="$2" real sha ref tree branch remote merge_ref remote_url
    real="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
    [[ -f "$metadata" && ! -L "$metadata" ]] || return 1
    sha="$(git -C "$real" rev-parse --verify HEAD 2>/dev/null)" || return 1
    ref="$(git -C "$real" symbolic-ref -q HEAD 2>/dev/null || printf 'HEAD')"
    tree="$(git -C "$real" rev-parse --verify "$sha^{tree}" 2>/dev/null)" || return 1
    branch="$(git -C "$real" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
    remote="$(git -C "$real" config --get "branch.$branch.remote" 2>/dev/null)" || return 1
    merge_ref="$(git -C "$real" config --get "branch.$branch.merge" 2>/dev/null)" || return 1
    [[ "$merge_ref" == refs/heads/* && "$remote" != . ]] || return 1
    remote_url="$(git -C "$real" remote get-url "$remote" 2>/dev/null)" || return 1
    python3 -c 'import json,sys
metadata,worktree,ref,head,tree,remote_url,merge_ref=sys.argv[1:]
with open(metadata, encoding="utf-8") as fh:
    row=json.load(fh)
if row.get("format") not in ("disk-magician-ao-restore-v1", "disk-magician-worktree-restore-v1"):
    raise SystemExit(1)
if row.get("status") != "verified":
    raise SystemExit(1)
if [row.get(k) for k in ("worktree", "ref", "head", "tree")] != [worktree, ref, head, tree]:
    raise SystemExit(1)
remote=row.get("remote")
if not isinstance(remote, dict) or [remote.get(k) for k in ("url", "ref", "sha")] != [remote_url, merge_ref, head]:
    raise SystemExit(1)
backup=row.get("durable_backup")
restore=row.get("restore")
if not isinstance(backup, dict) or backup.get("status") != "verified" or backup.get("fetched") is not True:
    raise SystemExit(1)
if not isinstance(restore, dict) or restore.get("status") != "verified":
    raise SystemExit(1)
if [backup.get(k) for k in ("head", "tree")] != [head, tree]:
    raise SystemExit(1)
if [restore.get(k) for k in ("head", "tree")] != [head, tree]:
    raise SystemExit(1)
' "$metadata" "$real" "$ref" "$sha" "$tree" "$remote_url" "$merge_ref"
}

# worktree_restore_receipt_matches_live <worktree> <receipt>
# Revalidate identity and compare the configured upstream SHA at the moment of
# the destructive caller's final gate.
worktree_restore_receipt_matches_live() {
    local path="$1" metadata="$2" real sha branch remote merge_ref remote_url live_sha
    real="$(cd "$path" 2>/dev/null && pwd -P)" || return 1
    worktree_restore_receipt_validate "$real" "$metadata" || return 1
    sha="$(git -C "$real" rev-parse --verify HEAD 2>/dev/null)" || return 1
    branch="$(git -C "$real" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
    remote="$(git -C "$real" config --get "branch.$branch.remote" 2>/dev/null)" || return 1
    merge_ref="$(git -C "$real" config --get "branch.$branch.merge" 2>/dev/null)" || return 1
    remote_url="$(git -C "$real" remote get-url "$remote" 2>/dev/null)" || return 1
    live_sha="$(git -C "$real" ls-remote --heads "$remote_url" "$merge_ref" 2>/dev/null | awk 'NR == 1 {print $1}')"
    [[ -n "$live_sha" && "$live_sha" == "$sha" ]] || return 1
    python3 -c 'import json,sys
metadata,live_sha=sys.argv[1:]
with open(metadata, encoding="utf-8") as fh:
    remote=json.load(fh).get("remote")
if not isinstance(remote, dict) or remote.get("sha") != live_sha:
    raise SystemExit(1)
' "$metadata" "$live_sha"
}
