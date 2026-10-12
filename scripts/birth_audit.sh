#!/usr/bin/env bash
# birth_audit.sh — the `diskm govern` birth-audit phase (spec C7, detection only): count births (birth_audit.py), then
# adopt each unattempted bypass entry with an ownerless lease. Adoption grants no removal authority.
set -uo pipefail
_BA_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
source "$_BA_DIR/lib/worktree_lease.sh"; source "$_BA_DIR/lib/scratch_roots.sh"; source "$_BA_DIR/lib/layout_standard.sh"
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
python3 "$_BA_DIR/birth_audit.py" "$(scratch_roots_get_private_tmp)" "${TMPDIR:-$(scratch_roots_get_user_tmp)}" \
    "$HOME/Documents/Codex" "$STANDARD_WORKTREE_ROOT" > "$out" || exit $?
while IFS= read -r -d '' p; do
    f="$(lease_path_for "$p")"; [[ -e "$f" ]] && continue
    IFS=$'\t' read -r admin birth < <(_lease_admin_info "$p")
    mkdir -p "$(lease_dir)" && _lease_emit_json "$f" "$p" "" "" birth-audit False - - - "$admin" "$birth" \
        "${DISK_MAGICIAN_LEASE_TTL_HOURS:-24}" "$([[ -f "$p/.git" ]] && echo worktree || echo scratch)" birth-audit ||
        echo "birth-audit: lease write failed: $p" >&2
done < "$out"
