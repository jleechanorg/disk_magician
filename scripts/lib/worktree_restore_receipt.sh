#!/usr/bin/env bash
# Shared durable restore receipt validation for worktree retirement.
#
# Receipts are input-only evidence. The final gate streams their pinned remote
# objects through the evidence verifier; it never creates or uploads a backup.

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
    python3 -c 'import datetime,json,re,sys
from pathlib import PurePosixPath
metadata,worktree,ref,head,tree,remote_url,merge_ref=sys.argv[1:]
with open(metadata, encoding="utf-8") as fh:
    row=json.load(fh)
if row.get("format") != "disk-magician-worktree-restore-v1":
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
verifier=row.get("verifier")
if not isinstance(verifier, dict) or verifier.get("command") != "diskm worktree-restore-verify" or verifier.get("method") != "pinned fetched-only fsck and complete tar/blob/mode/symlink restore":
    raise SystemExit(1)
when=datetime.datetime.fromisoformat(row.get("verified_at", "").replace("Z", "+00:00"))
if when.tzinfo is None or when > datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit(1)
if restore.get("lfs") != "absent-in-selected-tree-and-reachable-history":
    raise SystemExit(1)
if restore.get("fsck") != "passed --full --strict" or restore.get("no_extra_files") is not True or type(restore.get("file_count")) is not int or restore["file_count"] < 0:
    raise SystemExit(1)
objects=backup.get("objects")
names={"metadata.json", "recovery.bundle", "tree.tar", "tree.manifest", "files.before.manifest", "files.after.manifest"}
prefix="gs://wa-test-evidence/agent-evidence/disk_magician/"
if not isinstance(objects, list) or len(objects) != len(names) or any(not isinstance(o, dict) for o in objects) or {o.get("path") for o in objects} != names:
    raise SystemExit(1)
roots=set()
for obj in objects:
    url=obj.get("object", "")
    relative=url[len(prefix):] if isinstance(url, str) and url.startswith(prefix) else ""
    path=PurePosixPath(relative)
    if not relative or str(path) != relative or path.is_absolute() or ".." in path.parts or "\\" in relative or not url.endswith("/" + obj["path"]):
        raise SystemExit(1)
    if not re.fullmatch(r"[1-9][0-9]*", str(obj.get("generation", ""))) or not re.fullmatch(r"[0-9a-f]{64}", str(obj.get("sha256", ""))) or type(obj.get("size")) is not int or obj["size"] < 0:
        raise SystemExit(1)
    roots.add(url.rsplit("/", 1)[0])
if len(roots) != 1:
    raise SystemExit(1)

' "$metadata" "$real" "$ref" "$sha" "$tree" "$remote_url" "$merge_ref"
}

# worktree_restore_receipt_matches_live <worktree> <receipt>
# Revalidate identity and compare the configured upstream SHA at the moment of
# the destructive caller's final gate.
worktree_restore_receipt_matches_live() {
    local path="$1" metadata="$2" real sha branch remote merge_ref remote_url live_sha status
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
' "$metadata" "$live_sha" || return 1
    local evidence_helper
    evidence_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/evidence_manifest.py" || return 1
    timeout 300 python3 "$evidence_helper" verify-receipt "$metadata" || return 1
    # Remote streaming can take time; bind the final result to fresh identity.
    worktree_restore_receipt_validate "$real" "$metadata" || return 1
    status="$(git -C "$real" status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)" || return 1
    [[ -z "$status" ]] || return 1
    live_sha="$(git -C "$real" ls-remote --heads "$remote_url" "$merge_ref" 2>/dev/null | awk 'NR == 1 {print $1}')"
    [[ -n "$live_sha" && "$live_sha" == "$sha" ]]
}
