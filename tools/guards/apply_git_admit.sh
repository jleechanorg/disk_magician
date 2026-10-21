#!/usr/bin/env bash
# apply_git_admit.sh — apply tools/guards/git.patch (plan Task B2, run in Task C3) to the live git
# guard shim. Applies only when `diskm policy approved external_edits` is 0 AND the shim's SHA256
# equals the patch's base-sha256; otherwise prints the patch and the reason and exits 75. No flag
# bypasses either check. An already-patched shim is reported and left alone (rc 0).
# Usage: apply_git_admit.sh [--shim PATH]   (default ~/.local/bin/guards/git)
set -euo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
shim="$HOME/.local/bin/guards/git"
case "${1:-}" in
    --shim) shim="${2:?--shim needs a path}" ;;
    "") ;;
    *) echo "usage: apply_git_admit.sh [--shim PATH]" >&2; exit 2 ;;
esac
sha256() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The shim sources admit_caller.sh from this package root.
sed "s|@DISK_MAGICIAN_ROOT@|$ROOT|g" "$HERE/git.patch" >"$work/git.patch"
want="$(sed -n 's/^# base-sha256: //p' "$HERE/git.patch")"
refuse() {
    echo "apply_git_admit: refused: $1" >&2
    echo "--- patch that would be applied to $shim ---"
    cat "$work/git.patch"
    exit 75
}

python3 "$ROOT/scripts/policy_provenance.py" approved external_edits >/dev/null 2>&1 ||
    refuse "decision external_edits is not recorded (diskm policy approve external_edits --from-transcript <session.jsonl>)"
[[ -f "$shim" ]] || refuse "no shim at $shim"
if patch -s -f -R --dry-run "$shim" <"$work/git.patch" >/dev/null 2>&1; then
    echo "apply_git_admit: already applied to $shim"
    exit 0
fi
have="$(sha256 "$shim")"
[[ "$have" == "$want" ]] || refuse "shim sha256 $have != base-sha256 $want (the shim changed; regenerate the patch)"

cp -p "$shim" "$work/git"
patch -s -f "$work/git" <"$work/git.patch"
bash -n "$work/git"
chmod +x "$work/git"
cp -p "$shim" "$shim.pre-admit.bak"
cp -p "$work/git" "$shim.admit.tmp" && mv -f "$shim.admit.tmp" "$shim"
echo "apply_git_admit: applied to $shim (backup: $shim.pre-admit.bak)"
