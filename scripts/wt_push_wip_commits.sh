#!/bin/bash
# Push unpushed COMMITS from NEEDS-REVIEW worktrees to wip/ branches.
#
# WHY THIS IS NOT `git add -A && git commit && git push`:
#   Several of these worktrees carry `D ` (staged deletion) entries from sparse
#   checkouts -- one had 9,466 of them. `git add -A` would commit those as real
#   deletions of remote files. This script therefore NEVER touches the index or
#   the working tree. It pushes the existing commits only:
#
#       git push origin <HEAD-sha>:refs/heads/wip/worktree-preserve/<date>/<name>
#
#   The remote ref is created from the commit already in the object store, so
#   whatever is (or is not) staged is irrelevant to what gets published.
#
# Safety:
#  - refuses unless WIP_PUSH_APPROVED=1
#  - skips any worktree whose git admin dir is missing (orphaned; nothing to push)
#  - skips any worktree with zero commits not already on a remote (no-op)
#  - never force-pushes; never uses --mirror; never deletes a remote branch
#  - verifies the remote ref actually exists after the push before reporting ok
set -uo pipefail
LIST="${1:-/tmp/wt-pushable.txt}"
[[ "${WIP_PUSH_APPROVED:-0}" == "1" ]] || { echo "Refusing: set WIP_PUSH_APPROVED=1" >&2; exit 2; }
[[ -f "$LIST" ]] || { echo "missing list: $LIST" >&2; exit 2; }

DATE="$(date -u +%Y%m%d)"
ok=0; skip=0; fail=0
: > /tmp/wt-pushed-refs.txt

while IFS=$'\t' read -r _gib _age _rem _onrem rel; do
  [[ -n "${rel:-}" ]] || continue
  wt="$HOME/.worktrees/$rel"
  [[ -d "$wt" ]] || { echo "SKIP not-a-dir: $rel"; skip=$((skip+1)); continue; }

  # orphaned git admin dir => no object store to push from
  if ! GIT_OPTIONAL_LOCKS=0 timeout 30 git -C "$wt" rev-parse HEAD >/dev/null 2>&1; then
    echo "SKIP orphaned-admin: $rel"; skip=$((skip+1)); continue
  fi

  # anything to push?
  # An UNKNOWN count must never collapse to 0: "we could not measure" reported
  # as "nothing to preserve" silently drops unpushed work. Keep the failure and
  # count it as an error, not a no-op.
  if ! ahead_raw="$(GIT_OPTIONAL_LOCKS=0 timeout 60 git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null)"; then
    echo "FAILED unmeasurable-unpushed-count: $rel"; fail=$((fail+1)); continue
  fi
  ahead="${ahead_raw//[!0-9]/}"
  if [[ -z "$ahead" ]]; then
    echo "FAILED unmeasurable-unpushed-count: $rel"; fail=$((fail+1)); continue
  fi
  if (( ahead == 0 )); then
    echo "SKIP nothing-unpushed: $rel"; skip=$((skip+1)); continue
  fi

  # SHA must be a full 40/64-hex object id. A failed/timed-out rev-parse yields
  # an EMPTY string, and `git push origin "$sha:$ref"` with an empty source is
  # the refspec DELETE form (`:refs/heads/x`) -- it silently removes the remote
  # ref instead of publishing anything. Measured 2026-11-04: `git push origin
  # ":refs/heads/victim"` printed `- [deleted] victim`. Never push on an
  # unvalidated capture.
  sha=$(timeout 30 git -C "$wt" rev-parse HEAD 2>/dev/null)
  if [[ ! "$sha" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
    echo "SKIP unvalidated-sha ('$sha'): $rel"; skip=$((skip+1)); continue
  fi
  # Re-confirm the object actually resolves before using it in a refspec.
  if ! timeout 30 git -C "$wt" cat-file -e "$sha^{commit}" 2>/dev/null; then
    echo "SKIP sha-not-a-commit: $rel"; skip=$((skip+1)); continue
  fi
  name=$(echo "$rel" | tr '/' '-')
  ref="refs/heads/wip/worktree-preserve/$DATE/$name"

  # commits-only push: <sha>:<ref>. The index is not involved.
  if timeout 300 git -C "$wt" push origin "$sha:$ref" >/dev/null 2>&1; then
    # prove the remote actually has it
    if timeout 60 git -C "$wt" ls-remote --heads origin "$ref" 2>/dev/null | grep -q "${sha:0:40}"; then
      printf 'PUSHED %s  (%s commits)  %s\n' "${sha:0:10}" "$ahead" "$ref"
      printf '%s\t%s\n' "$rel" "$ref" >> /tmp/wt-pushed-refs.txt
      ok=$((ok+1))
    else
      echo "FAILED verify: $rel ($ref)"; fail=$((fail+1))
    fi
  else
    echo "FAILED push: $rel"; fail=$((fail+1))
  fi
done < "$LIST"

printf '\n=== pushed=%d skipped=%d failed=%d ===\n' "$ok" "$skip" "$fail"
(( fail == 0 )) || exit 1
exit 0
