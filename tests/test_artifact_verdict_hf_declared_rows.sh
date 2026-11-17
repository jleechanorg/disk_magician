#!/usr/bin/env bash
# Verdict-only declared cache-row regression; never invokes cleanup.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:?admitted Scratch TMPDIR required}/pr316-declared-rows.XXXXXX")" || exit 1
export HOME="$T/home" DISK_MAGICIAN_STATE_DIR="$T/state"
mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR"
# All payload names are ordinary; classification, not a secret-name match,
# must keep the unproven directories after the 48 h recency floor. Retain
# fixtures for parent inspection.
python3 - "$HOME" <<'PY_FIXTURE'
import os, pathlib, sys, time
home = pathlib.Path(sys.argv[1])
rows = ("huggingface/hub", "huggingface/modules", "huggingface/xet",
        "hy3dgen/tencent", "huggingface/stored_tokens", "huggingface/user_notes")
for rel in rows:
    d = home / ".cache" / rel
    d.mkdir(parents=True)
    (d / "payload.txt").write_bytes(b"ordinary fixture payload\n")
(home / ".cache/huggingface/token").write_bytes(b"fixture-not-a-real-token\n")
# 2026-11-12 operator decision: no veto AND at least one proof. The undeclared rows
# must remain kept:no-proof even when older than the 48 h recency floor.
def when_for(path):
    return time.time() - 4 * 86400
for root, dirs, files in os.walk(home, topdown=False):
    for name in files + dirs:
        p = os.path.join(root, name); w = when_for(p)
        os.utime(p, (w, w), follow_symlinks=False)
    w = when_for(root); os.utime(root, (w, w), follow_symlinks=False)
PY_FIXTURE
[[ "$?" == 0 ]] || exit 1
# shellcheck source=scripts/lib/artifact_verdict.sh
source "$ROOT/scripts/lib/artifact_verdict.sh"
PASS=0 FAIL=0
check() {
    local rel="$1" expected="$2" got rc=0
    got="$(artifact_removal_verdict "$HOME/.cache/$rel" --kind rebuildable)" || rc=$?
    printf 'case=%s rc=%s expected=%s actual=%s\n' "$rel" "$rc" "$expected" "$got"
    if [[ "$rc" == 0 && "$got" == "$expected" ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}
printf 'sandbox=%s\n' "$T"
for rel in huggingface/hub huggingface/modules huggingface/xet hy3dgen/tencent; do
    check "$rel" remove
done
check huggingface/token kept:no-proof
check huggingface/stored_tokens kept:no-proof
check huggingface/user_notes kept:no-proof
python3 - "$HOME" <<'PY_READBACK'
import hashlib, pathlib, sys
home = pathlib.Path(sys.argv[1])
for rel in ("huggingface/hub", "huggingface/modules", "huggingface/xet",
            "hy3dgen/tencent", "huggingface/stored_tokens", "huggingface/user_notes"):
    p = home / ".cache" / rel / "payload.txt"
    data = p.read_bytes()
    assert data == b"ordinary fixture payload\n", rel
    print("preserved", rel, hashlib.sha256(data).hexdigest())
p = home / ".cache/huggingface/token"
assert p.read_bytes() == b"fixture-not-a-real-token\n"
print("preserved huggingface/token", hashlib.sha256(p.read_bytes()).hexdigest())
PY_READBACK
if [[ "$?" != 0 ]]; then FAIL=$((FAIL + 1)); fi
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
