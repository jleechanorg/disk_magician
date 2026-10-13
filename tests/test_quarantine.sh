#!/usr/bin/env bash
# quarantine_remove phases 1–2 (spec §7.2 C14): verdict-bound inventory,
# exclusive quarantine, then fd-relative inventory-only deletion.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT=/tmp/disk_magician/fixtures
mkdir -p "$FIXTURE_ROOT"
TMP="$(cd "$(mktemp -d "$FIXTURE_ROOT/quarantine-test.XXXXXX")" && pwd -P)"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
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
  local candidate="$1" inventory_out="${3:-}"
  [[ -n "$STUB_VERDICT" ]] && { echo "$STUB_VERDICT"; return 0; }
  [[ -n "${VERDICT_ARG_FILE:-}" ]] && printf '%s\n' "$1" > "$VERDICT_ARG_FILE"
  [[ -n "${VERDICT_ARGS_FILE:-}" ]] && printf '%s\n' "$@" > "$VERDICT_ARGS_FILE"
  [[ -z "${EXPECTED_VERDICT_PATH:-}" || "$1" == "$EXPECTED_VERDICT_PATH" ]] || { echo kept:wrong-verdict-path; return 0; }
  if [[ "$2" == --inventory-out ]]; then
    shift 3
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --kind) [[ $# -ge 2 ]] || { echo kept:check-failed; return 0; }; case "$2" in ephemeral|rebuildable|os_clone) ;; *) echo kept:check-failed; return 0 ;; esac; shift 2 ;;
        --frozen-identity|--frozen-parent-identity|--frozen-root-identity) [[ $# -ge 2 ]] || { echo kept:check-failed; return 0; }; shift 2 ;;
        --deadline-at) [[ $# -ge 2 && "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo kept:check-failed; return 0; }; shift 2 ;;
        *) echo kept:check-failed; return 0 ;;
      esac
    done
    [[ -z "${DISK_MAGICIAN_TEST_VERDICT_BEFORE_INVENTORY:-}" ]] || bash -c "$DISK_MAGICIAN_TEST_VERDICT_BEFORE_INVENTORY"
    python3 "$TMP/inv.py" "$candidate" > "$inventory_out" || return 1
    [[ -z "${DISK_MAGICIAN_TEST_VERDICT_AFTER_INVENTORY:-}" ]] || bash -c "$DISK_MAGICIAN_TEST_VERDICT_AFTER_INVENTORY"
    echo remove
  fi
}

N=0 ACTIVE_STATE=""
fixture() {  # fresh parent/art with a report, nested files and a symlink
  N=$((N+1)); A="$TMP/p$N/art"; Q="$TMP/p$N/.dm-quarantine"
  export DISK_MAGICIAN_STATE_DIR="${ACTIVE_STATE:-$TMP/state-$N}"; mkdir -p "$DISK_MAGICIAN_STATE_DIR"
  mkdir -p "$A/sub/deep"; printf 'AAAA' > "$A/report.md"; echo x > "$A/sub/x.txt"; echo y > "$A/sub/deep/y.txt"; ln -s report.md "$A/link"
}
OUT=""
run() { OUT="$(env TMPDIR="$TMP" "$@" bash -c "source '$ROOT/scripts/lib/quarantine.sh'; $(declare -f artifact_removal_verdict); STUB_VERDICT='$STUB_VERDICT' TMP='$TMP' quarantine_remove '$A'")"; }
run_nounset() { OUT="$(env TMPDIR="$TMP" "$@" bash -u -c "source '$ROOT/scripts/lib/quarantine.sh'; $(declare -f artifact_removal_verdict); STUB_VERDICT='$STUB_VERDICT' TMP='$TMP' quarantine_remove '$A'")"; }
run_contract() {
  local qpath qtmp qverdict arg qarg command shell_bin
  printf -v qpath '%q' "$A"; printf -v qtmp '%q' "$TMP"; printf -v qverdict '%q' "$STUB_VERDICT"
  command="source '$ROOT/scripts/lib/quarantine.sh'; $(declare -f artifact_removal_verdict); STUB_VERDICT=$qverdict TMP=$qtmp; quarantine_remove $qpath"
  for arg in "$@"; do printf -v qarg '%q' "$arg"; command+=" $qarg"; done
  shell_bin="${QUARANTINE_TEST_BASH:-bash}"
  if [[ "${QUARANTINE_TEST_NOUNSET:-0}" == 1 ]]; then
    OUT="$(env TMPDIR="$TMP" VERDICT_ARGS_FILE="$TMP/verdict-args" "$shell_bin" -uc "$command")"
  else
    OUT="$(env TMPDIR="$TMP" VERDICT_ARGS_FILE="$TMP/verdict-args" "$shell_bin" -c "$command")"
  fi
}
intact() { [[ "$(cat "$A/report.md")" == "$1" && -f "$A/sub/x.txt" && -L "$A/link" ]]; }
qcount() { local n=0 f; for f in "$Q"/*; do [[ -e "$f" ]] && n=$((n+1)); done; echo "$n"; }
qid() { local value="${OUT#*:}"; echo "${value%%:*}"; }
sidecar_id() { local f; f="$(find "$Q" -maxdepth 1 -name '*.json' -print -quit)"; basename "$f" .json; }
index_id() { local f; f="$(find "$DISK_MAGICIAN_STATE_DIR/quarantine-index" -maxdepth 1 -name '*.json' -print -quit)"; basename "$f" .json; }
prepare_inputs() {
  fixture
  BINDING="$TMP/binding$N.json"; INV="$TMP/inventory$N.json"
  python3 "$ROOT/scripts/quarantine_rename.py" bind "$A" "$BINDING" >/dev/null
  python3 "$TMP/inv.py" "$A" > "$INV"
}
prepare_quarantine() {
  prepare_inputs
  OUT="$(python3 "$ROOT/scripts/quarantine_rename.py" phase1 "$A" "$INV" "$BINDING")"
  QID="${OUT#quarantined:}"
}

# Successful C14 verdict survives rename and phase-1 re-hash, then phase 2 removes it.
fixture; run X=1
check 'proven root: phase 1 + phase 2 report removed' [ "$OUT" = "removed:$(qid)" ]
check 'proven root: original and quarantine candidate are gone' [ ! -e "$A" ] && [ ! -e "$Q/$(qid)" ]
check 'proven root: sidecar is dropped after candidate' [ ! -e "$Q/$(qid).json" ]
check 'proven root: .dm-quarantine is 0700' [ "$(stat -f %Lp "$Q")" = 700 ]

# Removal-site options are explicit and preserved to the C14 dispatcher.
fixture; run_contract --kind os_clone --frozen-identity 1:2:501 --frozen-parent-identity 3:4:501 --frozen-root-identity 5:6:501 --deadline-at 123.5
OPTION_QID="$(sidecar_id)"
check 'caller options: path reaches artifact_removal_verdict' grep -Fx "$A" "$TMP/verdict-args"
check 'caller options: kind and deadline values are preserved' bash -c 'grep -Fx -- --kind "$1" >/dev/null && grep -Fx os_clone "$1" >/dev/null && grep -Fx -- --deadline-at "$1" >/dev/null && grep -Fx 123.5 "$1" >/dev/null' _ "$TMP/verdict-args"
check 'caller options: frozen identity proof is preserved' bash -c 'grep -Fx -- --frozen-identity "$1" >/dev/null && grep -Fx 1:2:501 "$1" >/dev/null && grep -Fx -- --frozen-parent-identity "$1" >/dev/null && grep -Fx 3:4:501 "$1" >/dev/null && grep -Fx -- --frozen-root-identity "$1" >/dev/null && grep -Fx 5:6:501 "$1" >/dev/null' _ "$TMP/verdict-args"
check 'caller options: expired deadline keeps deleting sidecar and index' [ "$OUT" = kept:quarantine_partial_kept ] && [ -f "$Q/$OPTION_QID.json" ] && [ -f "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$OPTION_QID.json" ]
fixture; run_contract --unknown-option value
check 'caller options: unknown option fails closed' [ "$OUT" = kept:check-failed ] && [ -e "$A" ]
fixture; QUARANTINE_TEST_BASH=/bin/bash QUARANTINE_TEST_NOUNSET=1 run_contract
check 'Bash 3.2 nounset: no optional args reaches removal verdict' bash -c 'case "$1" in removed:*) exit 0;; *) exit 1;; esac' _ "$OUT"

# A write after the deleting state is durable invalidates the hash and remains quarantined.
fixture; run DISK_MAGICIAN_TEST_BEFORE_UNLINK='printf BBBB > "$DM_Q_PATH/report.md"'
QID="$(sidecar_id)"
check 'phase 2 rewrite: kept:quarantine_partial_kept' [ "$OUT" = kept:quarantine_partial_kept ]
check 'phase 2 rewrite: changed file and deleting sidecar remain' bash -c '[[ "$(cat "$1")" == BBBB && "$(python3 -c '\''import json,sys; print(json.load(open(sys.argv[1]))["phase"])'\'' "$2")" == deleting ]]' _ "$Q/$QID/report.md" "$Q/$QID.json"

# An inventoried directory replaced by a symlink is never followed into the outside tree.
fixture; mkdir -p "$TMP/outside$N"; printf OUTSIDE > "$TMP/outside$N/keep"
run DISK_MAGICIAN_TEST_BEFORE_UNLINK="mv \"\$DM_Q_PATH/sub\" '$TMP/moved$N'; ln -s '$TMP/outside$N' \"\$DM_Q_PATH/sub\""
QID="$(sidecar_id)"
check 'directory-to-symlink swap: kept:quarantine_partial_kept' [ "$OUT" = kept:quarantine_partial_kept ]
check 'directory-to-symlink swap: outside data untouched' [ "$(cat "$TMP/outside$N/keep")" = OUTSIDE ]
check 'directory-to-symlink swap: sidecar and replacement symlink remain' [ -L "$Q/$QID/sub" ] && [ -f "$Q/$QID.json" ]

# A crash after the candidate is removed but before the final sidecar unlink is resumable.
fixture; run DISK_MAGICIAN_TEST_KILL_AT=before_sidecar_drop
CRASH_SIDE="$(find "$Q" -maxdepth 1 -name '*.json' -print -quit)"; CRASH_ID="$(basename "$CRASH_SIDE" .json)"
check 'crash before sidecar drop: deleting sidecar remains, root is gone' bash -c '[[ ! -e "$1" && "$(python3 -c '\''import json,sys; print(json.load(open(sys.argv[1]))["phase"])'\'' "$2")" == deleting ]]' _ "$Q/$CRASH_ID" "$CRASH_SIDE"
BINDING="$TMP/resume-binding.json"; python3 "$ROOT/scripts/quarantine_rename.py" bind "$A" "$BINDING" >/dev/null
RESUME="$(quarantine_phase2 "$BINDING" "$CRASH_ID")"
check 'crash before sidecar drop: retry drops the final sidecar' [ "$RESUME" = removed ] && [ ! -e "$CRASH_SIDE" ]

# The terminal index record makes each sidecar/index cleanup gap crash-recoverable.
fixture; DISK_MAGICIAN_TEST_KILL_AT=after_terminal_index run
CRASH_ID="$(index_id)"
check 'phase2 terminal-mark crash leaves durable index marker' python3 -c 'import json,sys; assert json.load(open(sys.argv[1])).get("terminal") == "removed"' "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$CRASH_ID.json"
RECOVERED="$(bash "$ROOT/disk_magician.sh" quarantine reconcile)"
check 'phase2 terminal-mark crash reconciles cleanly' bash -c '[[ "$1" == *"reconciled:$2:terminal-removed"* && ! -e "$3" ]]' _ "$RECOVERED" "$CRASH_ID" "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$CRASH_ID.json"

prepare_quarantine; CRASH_ID="$QID"
RESTORE_CRASH="$(env DISK_MAGICIAN_TEST_KILL_AT=after_terminal_index bash "$ROOT/disk_magician.sh" quarantine restore "$QID" 2>&1 || true)"
check 'restore terminal-mark crash leaves restored root and durable index' bash -c '[[ -e "$1" ]] && python3 -c '\''import json,sys; assert json.load(open(sys.argv[1])).get("terminal") == "restored"'\'' "$2"' _ "$A" "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$QID.json"
RECOVERED="$(bash "$ROOT/disk_magician.sh" quarantine reconcile)"
check 'restore terminal-mark crash reconciles cleanly' bash -c '[[ "$1" == *"reconciled:$2:terminal-restored"* && ! -e "$3" && ! -e "$4" ]]' _ "$RECOVERED" "$QID" "$Q/$QID.json" "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$QID.json"

prepare_quarantine; CRASH_ID="$QID"; mv "$Q/$QID" "$A"
env DISK_MAGICIAN_TEST_KILL_AT=after_terminal_index bash "$ROOT/disk_magician.sh" quarantine reconcile >/dev/null 2>&1 || true
check 'reconcile terminal-mark crash leaves durable index marker' python3 -c 'import json,sys; assert json.load(open(sys.argv[1])).get("terminal") == "original"' "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$CRASH_ID.json"
RECOVERED="$(bash "$ROOT/disk_magician.sh" quarantine reconcile)"
check 'reconcile terminal-mark crash clears both metadata files' bash -c '[[ "$1" == *"reconciled:$2:terminal-original"* && ! -e "$3" && ! -e "$4" ]]' _ "$RECOVERED" "$CRASH_ID" "$Q/$CRASH_ID.json" "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$CRASH_ID.json"

fixture; run DISK_MAGICIAN_TEST_INDEX_DROP_FAIL=1 X=1
CRASH_ID="$(index_id)"
check 'index cleanup failure preserves terminal recovery marker' bash -c '[[ "$1" == kept:quarantine_partial_kept && ! -e "$2" ]] && python3 -c '\''import json,sys; assert json.load(open(sys.argv[1])).get("terminal") == "removed"'\'' "$3"' _ "$OUT" "$Q/$CRASH_ID.json" "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$CRASH_ID.json"
RECOVERED="$(bash "$ROOT/disk_magician.sh" quarantine reconcile)"
check 'index cleanup failure is replayed by reconcile' bash -c '[[ "$1" == *"reconciled:$2:terminal-removed"* && ! -e "$3" ]]' _ "$RECOVERED" "$CRASH_ID" "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$CRASH_ID.json"
# A missing frozen root does not prove deletion: it may have moved elsewhere.
prepare_quarantine; MOVED="$TMP/moved-root-$QID"; mv "$Q/$QID" "$MOVED"
PHASE2="$(python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID")"
check 'missing quarantine root: preserve recovery records and moved payload' bash -c '[[ "$1" == kept:quarantine_partial_kept && -f "$2" && -f "$3/quarantine-index/$4.json" && -f "$5/report.md" ]]' _ "$PHASE2" "$Q/$QID.json" "$DISK_MAGICIAN_STATE_DIR" "$QID" "$MOVED"

# Moving the root after phase 2 observes it is also ambiguous, so no completion marker is written.
prepare_quarantine; MOVED="$TMP/moved-during-delete-$QID"
PHASE2="$(env DISK_MAGICIAN_TEST_BEFORE_UNLINK="mv '$Q/$QID' '$MOVED'" python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID")"
check 'root moved during delete: preserve recovery records and moved payload' bash -c '[[ "$1" == kept:quarantine_partial_kept && -f "$2" && -f "$3/quarantine-index/$4.json" && -f "$5/report.md" ]]' _ "$PHASE2" "$Q/$QID.json" "$DISK_MAGICIAN_STATE_DIR" "$QID" "$MOVED"

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
fixture; STUB_VERDICT=kept:unproven-content run_nounset X=1
check 'nounset no-option kept verdict passes through' [ "$OUT" = kept:unproven-content ]
check 'nounset no-option kept verdict: untouched' intact AAAA
fixture; OUT="$(bash -c "source '$ROOT/scripts/lib/quarantine.sh'; artifact_removal_verdict() { :; }; quarantine_remove '$A'")"
check 'no verdict function: kept:check-failed' [ "$OUT" = kept:check-failed ]
check 'no verdict function: untouched' intact AAAA
fixture; STUB_VERDICT=remove run X=1
check 'remove without inventory: kept:check-failed, untouched' bash -c '[[ "$1" == kept:check-failed && -f "$2/report.md" && $(ls -A "$3" 2>/dev/null | wc -l) -eq 0 ]]' _ "$OUT" "$A" "$Q"

# Caller rejects unknown options before they can influence a replacement verdict implementation.
fixture; OUT="$(bash -c "source '$ROOT/scripts/lib/quarantine.sh'; artifact_removal_verdict() { touch '$TMP/verdict-called'; echo remove; }; quarantine_remove '$A' --unsupported-option" 2>/dev/null)"
check 'unknown caller option: kept before verdict' [ "$OUT" = kept:check-failed ]
check 'unknown caller option: verdict not called' [ ! -e "$TMP/verdict-called" ]
check 'unknown caller option: source untouched' intact AAAA

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

# A replacement after rollback's identity check is detected after the rename;
# recovery metadata records where the inventoried inode can still be found.
fixture; run \
  DISK_MAGICIAN_TEST_AFTER_QUARANTINE='printf BBBB > "$DM_Q_DEST/report.md"' \
  DISK_MAGICIAN_TEST_BEFORE_ROLLBACK_RENAME='printf occupied > "$DM_Q_DEST.json.update"; mv "$DM_Q_DEST" "$DM_Q_DEST.saved"; mkdir "$DM_Q_DEST"; printf SUBSTITUTE > "$DM_Q_DEST/report.md"'
check 'rollback source swap: conflict reported' [ "${OUT%%:*}" = quarantine_conflict ]
check 'rollback source swap: replacement path identity is not claimed as restored' [ "$(cat "$A/report.md")" = SUBSTITUTE ]
check 'rollback source swap: inventoried artifact remains at the reported path' bash -c '[[ "$(cat "$1/report.md")" == BBBB && "$(python3 -c '\''import json,sys; d=json.load(open(sys.argv[1])); c=d["rollback_conflict"]; assert d["phase"]=="rollback_conflict" and c["expected_locations_in_quarantine"]==[sys.argv[2]]; print("ok")'\'' "$2" "$1")" == ok ]]' _ "$Q/$(qid).saved" "$Q/$(qid).json"
check 'rollback source swap: recovery sidecar remains' [ -f "$Q/$(qid).json" ]
check 'rollback source swap: fixed-name temp collision does not block metadata update' python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["phase"]=="rollback_conflict"' "$Q/$(qid).json"

# If the post-rollback metadata update fails, retain the durable rollback intent and both payloads.
fixture; run \
  DISK_MAGICIAN_TEST_AFTER_QUARANTINE='printf BBBB > "$DM_Q_DEST/report.md"' \
  DISK_MAGICIAN_TEST_BEFORE_ROLLBACK_RENAME='mv "$DM_Q_DEST" "$DM_Q_DEST.saved"; mkdir "$DM_Q_DEST"; printf SUBSTITUTE > "$DM_Q_DEST/report.md"' \
  DISK_MAGICIAN_TEST_SIDECAR_UPDATE_FAIL_AT=2
QID="$(qid)"
check 'rollback source swap with metadata update failure: failure reported' [ "$OUT" = "quarantine_conflict:$QID:rollback-state-update-failed" ]
check 'rollback source swap with metadata update failure: both payloads remain' [ "$(cat "$A/report.md")" = SUBSTITUTE ] && [ "$(cat "$Q/$QID.saved/report.md")" = BBBB ]
check 'rollback source swap with metadata update failure: rollback intent remains durable' python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["phase"]=="rollback_pending" and d["rollback"]["expected"]=={"dev":d["dev"],"ino":d["ino"]} and d["rollback"]["reason"]=="rehash-mismatch"' "$Q/$QID.json"

# A moved parent leaves only descriptor-relative recovery names; stale absolute paths are not published.
fixture; run \
  DISK_MAGICIAN_TEST_AFTER_QUARANTINE='printf BBBB > "$DM_Q_DEST/report.md"' \
  DISK_MAGICIAN_TEST_BEFORE_ROLLBACK_RENAME='mv "$DM_Q_DEST" "$DM_Q_DEST.saved"; mkdir "$DM_Q_DEST"; printf SUBSTITUTE > "$DM_Q_DEST/report.md"; mv "$(dirname "$DM_Q_PATH")" "$(dirname "$DM_Q_PATH").moved"'
QID="$(qid)"; MOVED_PARENT="$(dirname "$A").moved"; MOVED_Q="$MOVED_PARENT/.dm-quarantine"
check 'moved parent rollback: conflict reported' [ "${OUT%%:*}" = quarantine_conflict ]
check 'moved parent rollback: both payloads preserved under moved parent' [ "$(cat "$MOVED_PARENT/art/report.md")" = SUBSTITUTE ] && [ "$(cat "$MOVED_Q/$QID.saved/report.md")" = BBBB ]
check 'moved parent rollback: sidecar preserves directory identities and relative recovery name' python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d["rollback_conflict"]; assert not c["parent_path_bound"] and c["quarantine_dir_bound"] and c["original_path"] is None and c["quarantine_path"] is None and c["expected_locations_in_quarantine"]==[] and c["expected_entry_names_in_bound_quarantine"]==[sys.argv[2]] and c["parent_identity"]=={"dev":d["parent_dev"],"ino":d["parent_ino"]} and c["quarantine_identity"]=={"dev":d["quarantine_dev"],"ino":d["quarantine_ino"]}' "$MOVED_Q/$QID.json" "$QID.saved"

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
check 'verdict-time parent retarget: only the original path is removed' bash -c '[[ "${1%%:*}" == removed && ! -e "$2" && ! -e "$3" && "$(cat "$4")" == SAME-INODE ]]' _ "$OUT" "$ORIG/item" "$Q/$(qid)" "$OTHER/item"

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

# Durable reconciliation resolves pre-delete crashes through the advisory index.
prepare_inputs; env DISK_MAGICIAN_TEST_KILL_AT=after_intent python3 "$ROOT/scripts/quarantine_rename.py" phase1 "$A" "$INV" "$BINDING"; KILL_RC=$?
QID="$(index_id)"; RECON="$(quarantine_reconcile)"
check 'crash after intent: original is retained and metadata reconciled' bash -c '[[ "$1" -eq 137 && -f "$2/report.md" && "$3" == *"reconciled:$4:original"* && ! -e "$5/$4.json" ]]' _ "$KILL_RC" "$A" "$RECON" "$QID" "$Q"
prepare_inputs; env DISK_MAGICIAN_TEST_KILL_AT=after_rename python3 "$ROOT/scripts/quarantine_rename.py" phase1 "$A" "$INV" "$BINDING"; KILL_RC=$?
QID="$(index_id)"; RECON="$(quarantine_reconcile)"
check 'crash after rename: exclusive rollback restores the artifact' bash -c '[[ "$1" -eq 137 && -f "$2/report.md" && ! -e "$3/$4" && "$5" == *"reconciled:$4:rolled-back"* ]]' _ "$KILL_RC" "$A" "$Q" "$QID" "$RECON"
prepare_inputs; env DISK_MAGICIAN_TEST_AFTER_QUARANTINE='printf BBBB > "$DM_Q_DEST/report.md"' DISK_MAGICIAN_TEST_KILL_AT=before_rollback python3 "$ROOT/scripts/quarantine_rename.py" phase1 "$A" "$INV" "$BINDING"; KILL_RC=$?
QID="$(index_id)"; RECON="$(quarantine_reconcile)"
check 'crash before rollback: rollback_pending is reconciled' bash -c '[[ "$1" -eq 137 && "$(cat "$2/report.md" 2>/dev/null)" == BBBB && ! -e "$3/$4" && "$5" == *"reconciled:$4:rolled-back"* ]]' _ "$KILL_RC" "$A" "$Q" "$QID" "$RECON"

# Mid-delete resume never sweeps new entries and rechecks every remaining digest.
prepare_quarantine; MTIMES="$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_atime_ns, s.st_mtime_ns)' "$Q/$QID/report.md")"; env DISK_MAGICIAN_TEST_KILL_AT=mid_delete python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID" >/dev/null 2>&1; KILL_RC=$?
printf BBBB > "$Q/$QID/report.md"; python3 -c 'import os,sys; a,m=map(int,sys.argv[2:]); os.utime(sys.argv[1],ns=(a,m))' "$Q/$QID/report.md" $MTIMES; printf EXTRA > "$Q/$QID/new-after-crash"
RECON="$(quarantine_reconcile)"
check 'mid-delete crash: changed and added entries remain quarantined' bash -c '[[ "$1" -eq 137 && "$2" == *quarantine_partial_kept* && "$(cat "$3/$4/report.md")" == BBBB && "$(cat "$3/$4/new-after-crash")" == EXTRA && -f "$3/$4.json" ]]' _ "$KILL_RC" "$RECON" "$Q" "$QID"

# Malformed sidecars alert without touching payload; exact-ID restore works only to a free path.
prepare_quarantine; printf '{malformed' > "$Q/$QID.json"; RECON="$(quarantine_reconcile)"
check 'malformed sidecar: alert and keep indexed payload' bash -c '[[ "$1" == *"alert:$2:"* && -f "$3/$2/report.md" && -f "$4/quarantine-index/$2.json" ]]' _ "$RECON" "$QID" "$Q" "$DISK_MAGICIAN_STATE_DIR"
prepare_quarantine; RESTORE="$(bash "$ROOT/disk_magician.sh" quarantine restore "$QID")"
check 'restore: exact kept artifact returns when original path is free' bash -c '[[ "$1" == "restored:$2" && -f "$3/report.md" && ! -e "$4/$2" && ! -e "$5/quarantine-index/$2.json" ]]' _ "$RESTORE" "$QID" "$A" "$Q" "$DISK_MAGICIAN_STATE_DIR"
# A same-length replacement inserted after the pre-rename inventory must not be reported as restored.
prepare_quarantine; MOVED="$TMP/restore-original-$QID"; REPLACEMENT="$TMP/restore-replacement-$QID"
mkdir -p "$REPLACEMENT"; printf EVIL > "$REPLACEMENT/report.md"
RESTORE="$(env DISK_MAGICIAN_TEST_BEFORE_RESTORE_RENAME="mv '$Q/$QID' '$MOVED'; mv '$REPLACEMENT' '$Q/$QID'" python3 "$ROOT/scripts/quarantine_rename.py" restore "$QID")"
check 'restore replacement race: conflict keeps recovery records and does not claim replacement' bash -c '[[ "$1" == kept:restore-identity-mismatch && -f "$2/report.md" && "$(cat "$2/report.md")" == EVIL && -f "$4/$3.json" && "$(python3 -c '\''import json,sys; print(json.load(open(sys.argv[1]))["phase"])'\'' "$4/$3.json")" == restore_conflict && -f "$5/quarantine-index/$3.json" && -f "$6/report.md" ]]' _ "$RESTORE" "$A" "$QID" "$Q" "$DISK_MAGICIAN_STATE_DIR" "$MOVED"
check 'restore unknown id: kept' [ "$(bash "$ROOT/disk_magician.sh" quarantine restore ffffffffffffffff)" = kept:unknown-quarantine-id ]

# An expired absolute monotonic deadline leaves a cursor which the next call resumes.
ACTIVE_STATE="$TMP/state-deadline"; prepare_quarantine; QID_A="$QID"; A_A="$A"; Q_A="$Q"
ACTIVE_STATE="$TMP/state-deadline"; prepare_quarantine; QID_B="$QID"; A_B="$A"; Q_B="$Q"
CURSOR="$TMP/reconcile.cursor"; NOW="$(python3 -c 'import time; print(time.monotonic())')"
RECON="$(quarantine_reconcile --deadline-at "$NOW" --cursor "$CURSOR")"
check 'deadline: deferred cursor preserves unprocessed sidecars' bash -c '[[ "$1" == deferred:* && -f "$2" && -f "$3/$5.json" && -e "$3/$5" && -f "$4/$6.json" && -e "$4/$6" && -f "$7/quarantine-index/$5.json" && -f "$7/quarantine-index/$6.json" ]]' _ "$RECON" "$CURSOR" "$Q_A" "$Q_B" "$QID_A" "$QID_B" "$DISK_MAGICIAN_STATE_DIR"
RECON="$(quarantine_reconcile --cursor "$CURSOR")"
check 'deadline resume: cursor processes remaining indexed entries' bash -c '[[ "$1" == *"reconciled:$2:rolled-back"* && "$1" == *"reconciled:$3:rolled-back"* && ! -e "$4" && -f "$5/report.md" && -f "$6/report.md" ]]' _ "$RECON" "$QID_A" "$QID_B" "$CURSOR" "$A_A" "$A_B"
ACTIVE_STATE=""

# A crash while persisting the post-delete marker must preserve the prior valid sidecar.
prepare_quarantine
env DISK_MAGICIAN_TEST_KILL_AT=before_root_removed_replace python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID" >/dev/null 2>&1; KILL_RC=$?
RECON="$(quarantine_reconcile)"
check 'root-removed marker crash: payload is gone but sidecar remains valid and indexed' python3 -c 'import json,os,sys; assert sys.argv[1]=="137"; d=json.load(open(sys.argv[2])); assert d["phase"]=="deleting" and d.get("root_removed") is not True; assert not os.path.lexists(sys.argv[3]); assert os.path.isfile(sys.argv[4]); assert os.path.isfile(sys.argv[5]); assert "kept" in sys.argv[6]' "$KILL_RC" "$Q/$QID.json" "$Q/$QID" "$Q/$QID.json" "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$QID.json" "$RECON"

# A crash after unlink but before its progress record leaves the absence ambiguous and the record retained.
prepare_quarantine
env DISK_MAGICIAN_TEST_KILL_AT=entry_removed_before_journal python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID" >/dev/null 2>&1; KILL_RC=$?
RECON="$(quarantine_reconcile)"
check 'entry crash before progress journal: ambiguous absence keeps recovery records' python3 -c 'import json,os,sys; assert sys.argv[1]=="137" and "kept:quarantine_partial_kept" in sys.argv[2]; d=json.load(open(sys.argv[3])); assert d["phase"]=="deleting"; done=set(d.get("removed_paths",[])); assert any(e["path"]!="." and e["path"] not in done and not os.path.lexists(os.path.join(sys.argv[4],*e["path"].split("/"))) for e in d["inventory"]); assert os.path.lexists(sys.argv[4]); assert os.path.isfile(sys.argv[5])' "$KILL_RC" "$RECON" "$Q/$QID.json" "$Q/$QID" "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$QID.json"

# A crash after the progress record is durable resumes from the exact completed entry.
prepare_quarantine
env DISK_MAGICIAN_TEST_KILL_AT=mid_delete python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID" >/dev/null 2>&1; KILL_RC=$?
RECON="$(quarantine_reconcile)"
check 'entry crash after progress journal: resume completes and drops records' python3 -c 'import os,sys; assert sys.argv[1]=="137" and "removed" in sys.argv[2] and "kept" not in sys.argv[2]; assert not os.path.lexists(sys.argv[3]); assert not os.path.lexists(sys.argv[4]); assert not os.path.exists(sys.argv[5])' "$KILL_RC" "$RECON" "$A" "$Q/$QID.json" "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$QID.json"

# A child moved by the root-open hook, before its first lookup, is not mistaken for prior deletion.
prepare_quarantine; MOVED="$TMP/moved-child-before-lookup-$QID"
RECON="$(env DISK_MAGICIAN_TEST_AFTER_ROOT_OPEN="mv \"\$DM_Q_PATH/sub\" '$MOVED'" python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID")"
check 'child moved before lookup: payload and recovery records remain' bash -c '[[ "$1" == kept:quarantine_partial_kept && -f "$2/x.txt" && -f "$2/deep/y.txt" && -f "$3/$4.json" && -f "$5/quarantine-index/$4.json" ]]' _ "$RECON" "$MOVED" "$Q" "$QID" "$DISK_MAGICIAN_STATE_DIR"

# If the quarantined root moves after opening, phase2 must stop before deleting through its fd.
prepare_quarantine; MOVED="$TMP/moved-after-open-$QID"
RECON="$(env DISK_MAGICIAN_TEST_AFTER_ROOT_OPEN="mv \"\$DM_Q_PATH\" '$MOVED'" python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID")"
check 'root moved after open: deletion stops and recovery records remain' bash -c '[[ "$1" == kept:quarantine_partial_kept && -f "$2/report.md" && "$(cat "$2/report.md")" == AAAA && -f "$3/$4.json" && -f "$5/quarantine-index/$4.json" ]]' _ "$RECON" "$MOVED" "$Q" "$QID" "$DISK_MAGICIAN_STATE_DIR"

# A child directory moved after open must not be recursively deleted via its stale descriptor.
prepare_quarantine; MOVED="$TMP/moved-child-after-open-$QID"
RECON="$(env DISK_MAGICIAN_TEST_AFTER_CHILD_OPEN="[[ \"\$DM_Q_PATH\" == */sub ]] && mv \"\$DM_Q_PATH\" '$MOVED'" python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID")"
check 'child moved after open: payload and recovery records remain' bash -c '[[ "$1" == kept:quarantine_partial_kept && -f "$2/x.txt" && -f "$2/deep/y.txt" && -f "$3/$4.json" && -f "$5/quarantine-index/$4.json" ]]' _ "$RECON" "$MOVED" "$Q" "$QID" "$DISK_MAGICIAN_STATE_DIR"

# The same ancestry check applies to a deeper directory opened below a child.
prepare_quarantine; MOVED="$TMP/moved-deep-after-open-$QID"
RECON="$(env DISK_MAGICIAN_TEST_AFTER_CHILD_OPEN="[[ \"\$DM_Q_PATH\" == */sub/deep ]] && mv \"\$DM_Q_PATH\" '$MOVED'" python3 "$ROOT/scripts/quarantine_rename.py" phase2 "$BINDING" "$QID")"
check 'deep child moved after open: its payload and recovery records remain' bash -c '[[ "$1" == kept:quarantine_partial_kept && -f "$2/y.txt" && -f "$3/$4.json" && -f "$5/quarantine-index/$4.json" ]]' _ "$RECON" "$MOVED" "$Q" "$QID" "$DISK_MAGICIAN_STATE_DIR"
ACTIVE_STATE=""

echo "quarantine: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
