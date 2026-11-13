#!/usr/bin/env bash
# Model-cache rows of C14's cache-root table (scripts/lib/artifact_verdict.sh,
# _av_rebuildable): a Hugging Face (hub/modules/xet) or Hunyuan3D (tencent) entry is
# rebuildable ONLY under its registered $HOME root. The same shape under an arbitrary
# path stays kept:no-proof, a client's credential file beside the cache is not
# classified by its parent's name, and secret-like content still blocks.
#
# Portable on purpose (Python sets mtimes), so it runs on the Linux host where the
# macOS-only tests/test_artifact_verdict.sh cannot (`date -r <epoch>`).
set -uo pipefail
# 2026-11-12 operator decision: the verdict is "no veto AND at least one proof". An entry
# outside the rebuildable rows, and one inside them but too young, is `kept:no-proof`
# (was kept:unproven-content / kept:recent-activity); secret-like content is no longer a
# veto.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/artifact_verdict.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/dm-c14-cache-rows.XXXXXX")" || exit 1
# /bin/rm, not a bare rm: the fixture HOME replaces $HOME, so an rm wrapper on the
# real PATH ($HOME/.local/bin/guards/rm) would not resolve and silently delete nothing.
trap 'chmod -R u+rwx "$T" 2>/dev/null; /bin/rm -rf "$T"' EXIT
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}

export HOME="$T/home"
export DISK_MAGICIAN_STATE_DIR="$T/state"
mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR"
# shellcheck source=scripts/lib/artifact_verdict.sh
source "$LIB"
av() { artifact_removal_verdict "$@"; }
# age <path> <minutes>: make <path> (every entry, symlinks not followed) idle by
# touching mtimes only — the content and identity the verdict checks stay as built.
age() {
    python3 - "$1" "$2" <<'PY'
import os, sys, time
root, minutes = sys.argv[1], int(sys.argv[2])
when = time.time() - minutes * 60
paths = [root]
for dirpath, dirnames, filenames in os.walk(root):
    paths += [os.path.join(dirpath, n) for n in dirnames + filenames]
for p in sorted(paths, key=len, reverse=True):
    os.utime(p, (when, when), follow_symlinks=False)
PY
}

echo "== registered model-cache roots =="
mkdir -p "$HOME/.cache/huggingface/hub/models--org--m/snapshots/abc" \
    "$HOME/.cache/huggingface/modules/pkg" "$HOME/.cache/huggingface/xet/chunk" \
    "$HOME/.cache/hy3dgen/tencent/checkpoint"
for d in .cache/huggingface/hub/models--org--m/snapshots/abc .cache/huggingface/modules/pkg \
    .cache/huggingface/xet/chunk .cache/hy3dgen/tencent/checkpoint; do
    printf 'weights' >"$HOME/$d/blob"
done
age "$HOME/.cache/huggingface" 120
age "$HOME/.cache/hy3dgen" 120
assert_eq "$(av "$HOME/.cache/huggingface/hub" --kind rebuildable)" remove \
    "huggingface hub entry under the registered root"
assert_eq "$(av "$HOME/.cache/huggingface/modules" --kind rebuildable)" remove \
    "huggingface modules entry under the registered root"
assert_eq "$(av "$HOME/.cache/huggingface/xet" --kind rebuildable)" remove \
    "huggingface xet entry under the registered root"
assert_eq "$(av "$HOME/.cache/hy3dgen/tencent" --kind rebuildable)" remove \
    "hy3dgen tencent entry under the registered root"

echo "== the same shapes elsewhere stay unproven =="
mkdir -p "$HOME/Downloads/hub/x" "$HOME/.cache/unregistered/hub/x" "$T/scratch/hub/x" "$T/scratch/tencent/x"
for d in "$HOME/Downloads/hub/x" "$HOME/.cache/unregistered/hub/x" "$T/scratch/hub/x" "$T/scratch/tencent/x"; do
    printf 'payload' >"$d/blob"
done
age "$HOME/Downloads" 120
age "$HOME/.cache/unregistered" 120
age "$T/scratch" 120
assert_eq "$(av "$HOME/Downloads/hub" --kind rebuildable)" kept:no-proof \
    "a \`hub\` dir under an arbitrary \$HOME path"
assert_eq "$(av "$HOME/.cache/unregistered/hub" --kind rebuildable)" kept:no-proof \
    "a \`hub\` dir under an unregistered cache root"
assert_eq "$(av "$T/scratch/hub" --kind rebuildable)" kept:no-proof \
    "a \`hub\` dir outside \$HOME"
assert_eq "$(av "$T/scratch/tencent" --kind rebuildable)" kept:no-proof \
    "a \`tencent\` dir outside \$HOME"
assert_eq "$(av "$HOME/.cache/huggingface" --kind rebuildable)" kept:no-proof \
    "the cache root itself is not an entry"
mkdir -p "$HOME/.cache/huggingface/stored_tokens/x" && printf 'payload' >"$HOME/.cache/huggingface/stored_tokens/x/blob"
age "$HOME/.cache/huggingface/stored_tokens" 120
assert_eq "$(av "$HOME/.cache/huggingface/stored_tokens" --kind rebuildable)" kept:no-proof \
    "an undeclared dir under huggingface cache root stays unproven"

echo "== credential files and secret-like content =="
printf 'hf_token=abc' >"$HOME/.cache/huggingface/token"
age "$HOME/.cache/huggingface" 120
assert_eq "$(av "$HOME/.cache/huggingface/token" --kind rebuildable)" kept:no-proof \
    "a credential FILE at the cache root is never classified by its parent's name"
printf 'HF_TOKEN=abc' >"$HOME/.cache/huggingface/hub/models--org--m/.env"
age "$HOME/.cache/huggingface/hub" 120
assert_eq "$(av "$HOME/.cache/huggingface/hub" --kind rebuildable)" remove \
    "a secret-like file inside the model cache no longer blocks (it only removes proofs)"
/bin/rm -f "$HOME/.cache/huggingface/hub/models--org--m/.env"
age "$HOME/.cache/huggingface/hub" 120
assert_eq "$(av "$HOME/.cache/huggingface/hub" --kind rebuildable)" remove \
    "the same entry is rebuildable again once the secret-like file is gone"

echo "== recency gate still applies =="
mkdir -p "$HOME/.cache/huggingface/xet-fresh/c" && printf 'x' >"$HOME/.cache/huggingface/xet-fresh/c/f"
assert_eq "$(av "$HOME/.cache/huggingface/xet-fresh" --kind rebuildable)" kept:no-proof \
    "a model-cache entry written minutes ago has no proof (1 h idle floor on rebuildable)"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
