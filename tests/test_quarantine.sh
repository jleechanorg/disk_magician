#!/usr/bin/env bash
# quarantine_remove phase 1 (spec §7.2 C14): verdict-bound inventory, intent sidecar,
# renamex_np(RENAME_EXCL) commit point, identity/live-user/re-hash checks, exclusive rollback.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT=/tmp/disk_magician/fixtures
mkdir -p "$FIXTURE_ROOT"
TMP="$(cd "$(mktemp -d "$FIXTURE_ROOT/quarantine-test.XXXXXX")" && pwd -P)"
MNT=""
cleanup() {
  [[ -n "$MNT" ]] && hdiutil detach -quiet -force "$MNT" >/dev/null 2>&1
  [[ "$TMP" == /private/tmp/disk_magician/fixtures/quarantine-test.* || "$TMP" == /tmp/disk_magician/fixtures/quarantine-test.* ]] && rm -rf "$TMP"
}
trap cleanup EXIT
PASS=0 FAIL=0
check() { local label="$1"; shift; if "$@"; then echo "PASS: $label"; PASS=$((PASS+1)); else echo "FAIL: $label"; FAIL=$((FAIL+1)); fi; }

# Independent inventory writer for the stub verdict (same shape C14 emits with --inventory-out).
cat > "$TMP/inv.py" <<'PY'
import hashlib, json, os, stat, sys
root, out = sys.argv[1], []
def ent(rel, full):
    st = os.lstat(full); e = {"path": rel, "dev": st.st_dev, "ino": st.st_ino}
    if stat.S_ISDIR(st.st_mode): e["type"] = "dir"
    elif stat.S_ISLNK(st.st_mode): e.update(type="symlink", target=os.readlink(full))
    else: e.update(type="file", size=st.st_size, sha256=hashlib.sha256(open(full, "rb").read()).hexdigest())
    out.append(e)
ent(".", root)
for d, ds, fs in os.walk(root):
    for n in ds + fs: ent(os.path.relpath(os.path.join(d, n), root), os.path.join(d, n))
json.dump(out, sys.stdout)
PY

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/quarantine.sh" || { echo "FAIL: source quarantine.sh"; exit 1; }
STUB_VERDICT=""
artifact_removal_verdict() {
  [[ -n "$STUB_VERDICT" ]] && { echo "$STUB_VERDICT"; return 0; }
  [[ -n "${VERDICT_ARG_FILE:-}" ]] && printf '%s\n' "$1" > "$VERDICT_ARG_FILE"
  [[ -z "${EXPECTED_VERDICT_PATH:-}" || "$1" == "$EXPECTED_VERDICT_PATH" ]] || { echo kept:wrong-verdict-path; return 0; }
  if [[ "$2" == --inventory-out ]]; then
    [[ -z "${DISK_MAGICIAN_TEST_VERDICT_BEFORE_INVENTORY:-}" ]] || bash -c "$DISK_MAGICIAN_TEST_VERDICT_BEFORE_INVENTORY"
    python3 "$TMP/inv.py" "$1" > "$3" || return 1
    [[ -z "${DISK_MAGICIAN_TEST_VERDICT_AFTER_INVENTORY:-}" ]] || bash -c "$DISK_MAGICIAN_TEST_VERDICT_AFTER_INVENTORY"
    echo remove
  fi
}

N=0
fixture() {  # fresh parent/art with a published report.md (version A), a subdir and a symlink
  N=$((N+1)); A="$TMP/p$N/art"; Q="$TMP/p$N/.dm-quarantine"
  mkdir -p "$A/sub"; printf 'AAAA' > "$A/report.md"; echo x > "$A/sub/x.txt"; ln -s report.md "$A/link"
}
OUT=""
run() { OUT="$(env TMPDIR="$TMP" "$@" bash -c "source '$ROOT/scripts/lib/quarantine.sh'; $(declare -f artifact_removal_verdict); STUB_VERDICT='$STUB_VERDICT' TMP='$TMP' quarantine_remove '$A'")"; }
intact() { [[ "$(cat "$A/report.md")" == "$1" && -f "$A/sub/x.txt" && -L "$A/link" ]]; }
qcount() { local n=0 f; for f in "$Q"/*; do [[ -e "$f" ]] && n=$((n+1)); done; echo "$n"; }
qid() { echo "${OUT#*:}"; }

# Happy path: proven root is quarantined (phase 2 is a stub, so it stays there).
fixture; run X=1
check 'proven root: quarantined:<id>' [ "${OUT%%:*}" = quarantined ]
check 'proven root: original path gone' [ ! -e "$A" ]
check 'proven root: content moved intact' [ "$(cat "$Q/$(qid)/report.md")" = AAAA ]
check 'proven root: sidecar holds phase intent + inventory' python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["phase"]=="intent" and d["original"]==sys.argv[2] and d["inventory"]' "$Q/$(qid).json" "$A"
check 'proven root: .dm-quarantine is 0700' [ "$(stat -f %Lp "$Q")" = 700 ]

# An existing .dm-quarantine must be a real 0700 dir owned by us; a symlink or 0755 dir keeps the artifact.
fixture; mkdir -p "$TMP/outside$N"; chmod 755 "$TMP/outside$N"; ln -s "$TMP/outside$N" "$Q"; run X=1
check 'symlinked qdir: kept:quarantine-dir-unsafe' [ "$OUT" = kept:quarantine-dir-unsafe ]
check 'symlinked qdir: untouched, nothing moved outside' bash -c '[[ -f "$1/report.md" && -z "$(ls -A "$2")" ]]' _ "$A" "$TMP/outside$N"
fixture; mkdir -m 755 "$Q"; run X=1
check '0755 qdir: kept:quarantine-dir-unsafe' [ "$OUT" = kept:quarantine-dir-unsafe ]
check '0755 qdir: untouched, qdir empty' bash -c '[[ -f "$1/report.md" && -z "$(ls -A "$2")" ]]' _ "$A" "$Q"

# Non-remove verdicts pass through and touch nothing.
fixture; STUB_VERDICT=kept:unproven-content run X=1
check 'kept verdict passes through' [ "$OUT" = kept:unproven-content ]
check 'kept verdict: untouched, no quarantine dir' bash -c '[[ -f "$1/report.md" && ! -e "$2" ]]' _ "$A" "$Q"
fixture; OUT="$(bash -c "source '$ROOT/scripts/lib/quarantine.sh'; quarantine_remove '$A'")"
check 'no verdict function: kept:check-failed' [ "$OUT" = kept:check-failed ]
check 'no verdict function: untouched' intact AAAA
fixture; STUB_VERDICT=remove run X=1
check 'remove without inventory: kept:check-failed, untouched' bash -c '[[ "$1" == kept:check-failed && -f "$2/report.md" && $(ls -A "$3" 2>/dev/null | wc -l) -eq 0 ]]' _ "$OUT" "$A" "$Q"

# Verdict binding: A rewritten to same-length B after C14, before the rename.
fixture; run DISK_MAGICIAN_TEST_AFTER_VERDICT='printf BBBB > "$DM_Q_PATH/report.md"'
check 'rewrite before rename: kept:rehash-mismatch' [ "$OUT" = kept:rehash-mismatch ]
check 'rewrite before rename: rolled back, B intact' intact BBBB
check 'rewrite before rename: quarantine empty' [ "$(qcount)" = 0 ]
# Same rewrite after the rename, before the re-hash.
fixture; run DISK_MAGICIAN_TEST_AFTER_QUARANTINE='printf BBBB > "$DM_Q_DEST/report.md"'
check 'rewrite after rename: kept:rehash-mismatch' [ "$OUT" = kept:rehash-mismatch ]
check 'rewrite after rename: rolled back, B intact' intact BBBB
check 'rewrite after rename: quarantine empty' [ "$(qcount)" = 0 ]

# Live user: a file inside is held open after the rename.
fixture; run DISK_MAGICIAN_TEST_AFTER_QUARANTINE="sleep 30 < \"\$DM_Q_DEST/report.md\" & echo \$! > '$TMP/pid'"
kill "$(cat "$TMP/pid")" 2>/dev/null
check 'open file: kept:live-user' [ "$OUT" = kept:live-user ]
check 'open file: rolled back intact' intact AAAA
# Single-file root held open: `lsof +D` on a file exits 1 with only a stderr warning, which must not read as "no user".
fixture; A="$TMP/p$N/rotated.log"; printf 'LOG' > "$A"
run DISK_MAGICIAN_TEST_AFTER_QUARANTINE="sleep 30 < \"\$DM_Q_DEST\" & echo \$! > '$TMP/pid'; sleep 0.3"
kill "$(cat "$TMP/pid")" 2>/dev/null
check 'open single file: kept:live-user' [ "$OUT" = kept:live-user ]
check 'open single file: rolled back intact' [ "$(cat "$A")" = LOG ]
check 'open single file: quarantine empty' [ "$(qcount)" = 0 ]
# lsof exits 1 with an error on stderr (stat failure, unreadable subtree): check-failed, rolled back.
mkdir -p "$TMP/fakebin"; printf '#!/bin/sh\necho "lsof: WARNING: can'"'"'t stat()" >&2\nexit 1\n' > "$TMP/fakebin/lsof"; chmod +x "$TMP/fakebin/lsof"
fixture; run PATH="$TMP/fakebin:$PATH"
check 'lsof error: kept:check-failed' [ "$OUT" = kept:check-failed ]
check 'lsof error: rolled back intact' intact AAAA
# Same hook also recreates the original path (empty dir, which plain rename(2) would replace): rollback hits EEXIST.
fixture; run DISK_MAGICIAN_TEST_AFTER_QUARANTINE="sleep 30 < \"\$DM_Q_DEST/report.md\" & echo \$! > '$TMP/pid'; mkdir \"\$DM_Q_PATH\""
kill "$(cat "$TMP/pid")" 2>/dev/null
check 'recreated original: quarantine_conflict:<id>' [ "${OUT%%:*}" = quarantine_conflict ]
check 'recreated original: new empty dir untouched' bash -c '[[ -d "$1" && -z "$(ls -A "$1")" ]]' _ "$A"
check 'recreated original: artifact still quarantined' [ "$(cat "$Q/$(qid)/report.md")" = AAAA ]
check 'recreated original: sidecar kept' [ -f "$Q/$(qid).json" ]

# A changed quarantine entry must never be rolled back over the source or lose the intent record.
fixture; run DISK_MAGICIAN_TEST_AFTER_QUARANTINE="mv \"\$DM_Q_DEST\" '$TMP/original$N'; mkdir \"\$DM_Q_DEST\"; printf SUBSTITUTE > \"\$DM_Q_DEST/report.md\""
check 'replaced quarantine entry: conflict reported' [ "${OUT%%:*}" = quarantine_conflict ]
check 'replaced quarantine entry: source not falsely restored' [ ! -e "$A" ]
check 'replaced quarantine entry: original retained separately' [ "$(cat "$TMP/original$N/report.md")" = AAAA ]
check 'replaced quarantine entry: sidecar retained' [ -f "$Q/$(qid).json" ]

# Replacing .dm-quarantine after intent creation must not redirect the candidate into a symlink target.
fixture; mkdir "$TMP/outside$N"; run DISK_MAGICIAN_TEST_BEFORE_QUARANTINE_RENAME="mv '$Q' '$Q.saved'; ln -s '$TMP/outside$N' '$Q'"
check 'replaced quarantine dir: conflict reported' [ "${OUT%%:*}" = quarantine_conflict ]
check 'replaced quarantine dir: source remains in place' intact AAAA
check 'replaced quarantine dir: outside untouched' [ -z "$(ls -A "$TMP/outside$N")" ]
check 'replaced quarantine dir: intent retained with original dir' [ -f "$Q.saved/$(qid).json" ]

# Source swapped for another dir between lstat and rename: identity mismatch.
fixture; run DISK_MAGICIAN_TEST_BEFORE_QUARANTINE_RENAME="mv \"\$DM_Q_PATH\" '$TMP/aside'; cp -R '$TMP/aside' \"\$DM_Q_PATH\""
check 'swap before rename: kept:identity-mismatch' [ "$OUT" = kept:identity-mismatch ]
check 'swap before rename: swapped dir back in place' intact AAAA
check 'swap before rename: real artifact untouched' [ "$(cat "$TMP/aside/report.md")" = AAAA ]
check 'swap before rename: quarantine empty' [ "$(qcount)" = 0 ]

# Parent location is frozen before the verdict: retargeting a parent symlink to
# a directory with a hard link to the same file must not move that alias.
N=$((N+1)); ORIG="$TMP/parent-original$N"; OTHER="$TMP/parent-other$N"; LINK="$TMP/parent-link$N"
mkdir "$ORIG" "$OTHER"; printf 'SAME-INODE' > "$ORIG/item"; ln "$ORIG/item" "$OTHER/item"; ln -s "$ORIG" "$LINK"
A="$LINK/item"; Q="$ORIG/.dm-quarantine"
run DISK_MAGICIAN_TEST_AFTER_VERDICT="mv '$LINK' '$LINK.saved'; ln -s '$OTHER' '$LINK'"
check 'retargeted parent with hard link: kept:parent-identity-mismatch' [ "$OUT" = kept:parent-identity-mismatch ]
check 'retargeted parent: both original and hard link remain' bash -c '[[ "$(cat "$1/item")" == SAME-INODE && "$(cat "$2/item")" == SAME-INODE ]]' _ "$ORIG" "$OTHER"
check 'retargeted parent: neither directory got a quarantine' [ ! -e "$ORIG/.dm-quarantine" ] && [ ! -e "$OTHER/.dm-quarantine" ]

# A parent alias retargeted during the verdict still gives C14 the frozen canonical candidate.
N=$((N+1)); ORIG="$TMP/verdict-parent-original$N"; OTHER="$TMP/verdict-parent-other$N"; LINK="$TMP/verdict-parent-link$N"
mkdir "$ORIG" "$OTHER"; printf 'SAME-INODE' > "$ORIG/item"; ln "$ORIG/item" "$OTHER/item"; ln -s "$ORIG" "$LINK"
A="$LINK/item"; Q="$ORIG/.dm-quarantine"; VERDICT_ARG_FILE="$TMP/verdict-arg$N"; EXPECTED_VERDICT_PATH="$ORIG/item"
run VERDICT_ARG_FILE="$VERDICT_ARG_FILE" EXPECTED_VERDICT_PATH="$EXPECTED_VERDICT_PATH" \
  DISK_MAGICIAN_TEST_VERDICT_BEFORE_INVENTORY="rm '$LINK'; ln -s '$OTHER' '$LINK'" \
  DISK_MAGICIAN_TEST_VERDICT_AFTER_INVENTORY="rm '$LINK'; ln -s '$ORIG' '$LINK'"
check 'verdict-time parent retarget: C14 receives frozen canonical candidate' [ "$(cat "$VERDICT_ARG_FILE")" = "$ORIG/item" ]
check 'verdict-time parent retarget: only the original path is quarantined' bash -c '[[ "${1%%:*}" == quarantined && ! -e "$2" && "$(cat "$3")" == SAME-INODE && -e "$4" ]]' _ "$OUT" "$ORIG/item" "$Q/$(qid)" "$OTHER/item"

# renamex_np missing: no rename at all.
fixture; run DISK_MAGICIAN_TEST_RENAMEX_SYMBOL=renamex_np_missing
check 'renamex_np missing: kept:exclusive_rename_unavailable' [ "$OUT" = kept:exclusive_rename_unavailable ]
check 'renamex_np missing: untouched, no sidecar' bash -c '[[ -f "$1/report.md" && $(ls -A "$2" | wc -l) -eq 0 ]]' _ "$A" "$Q"

# ENOSPC on the intent sidecar aborts before the rename.
fixture; run DISK_MAGICIAN_TEST_INTENT_ERRNO=28
check 'ENOSPC sidecar: kept:intent-write-failed' [ "$OUT" = kept:intent-write-failed ]
check 'ENOSPC sidecar: untouched, no partial sidecar' bash -c '[[ -f "$1/report.md" && $(ls -A "$2" | wc -l) -eq 0 ]]' _ "$A" "$Q"

# Quarantine dir on another device: kept:cross-device, nothing copied.
if [[ "$(uname)" == Darwin ]] && hdiutil create -quiet -size 4m -fs HFS+ -volname dmq "$TMP/q.dmg" >/dev/null 2>&1; then
  fixture; mkdir -p "$Q"
  if hdiutil attach -quiet -nobrowse -mountpoint "$Q" "$TMP/q.dmg" >/dev/null 2>&1; then
    MNT="$Q"; chmod 700 "$Q"; run X=1
    check 'cross-device: kept:cross-device' [ "$OUT" = kept:cross-device ]
    check 'cross-device: untouched' intact AAAA
    check 'cross-device: nothing copied or written' [ -z "$(find "$Q" -mindepth 1 ! -name '.*' -print -quit)" ]
  else echo "SKIP: cross-device (hdiutil attach failed)"; fi
else echo "SKIP: cross-device (no hdiutil)"; fi

echo "quarantine: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
