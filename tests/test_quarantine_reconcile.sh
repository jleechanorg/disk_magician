#!/usr/bin/env bash
# diskm quarantine-reconcile: finishes deferred phase 2, keeps anything whose
# identity or manifest does not validate, prunes stale sidecar update files.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT=/tmp/disk_magician/fixtures
mkdir -p "$FIXTURE_ROOT"
TMP="$(cd "$(mktemp -d "$FIXTURE_ROOT/qreconcile-test.XXXXXX")" && pwd -P)"
trap '[[ "$TMP" == /private/tmp/disk_magician/fixtures/qreconcile-test.* || "$TMP" == /tmp/disk_magician/fixtures/qreconcile-test.* ]] && rm -rf "$TMP"' EXIT
export DISK_MAGICIAN_STATE_DIR="$TMP/state" DISK_MAGICIAN_DELETION_LOG="$TMP/deletions.log"
mkdir -p "$DISK_MAGICIAN_STATE_DIR" "$TMP/scratch"
PASS=0 FAIL=0
check() { local label="$1"; shift; if "$@"; then echo "PASS: $label"; PASS=$((PASS+1)); else echo "FAIL: $label"; FAIL=$((FAIL+1)); fi; }

cat > "$TMP/inv.py" <<'PY'
import hashlib, json, os, stat, sys
root, out = sys.argv[1], []
def ent(rel, full):
    st = os.lstat(full); e = {"path": rel, "dev": st.st_dev, "ino": st.st_ino}
    if stat.S_ISDIR(st.st_mode): e["type"] = "dir"
    else: e.update(type="file", size=st.st_size, sha256=hashlib.sha256(open(full, "rb").read()).hexdigest())
    out.append(e)
ent(".", root)
for d, ds, fs in os.walk(root):
    for n in ds + fs: ent(os.path.relpath(os.path.join(d, n), root), os.path.join(d, n))
json.dump(out, sys.stdout)
PY

QR="$ROOT/scripts/quarantine_rename.py"
N=0
# deferred_entry: leaves a phase-2 entry journaled "deleting" (killed mid-delete).
deferred_entry() {
  N=$((N+1)); P="$TMP/scratch/p$N"; A="$P/art"; Q="$P/.dm-quarantine"
  mkdir -p "$A/sub"; printf 'AAAA' > "$A/report.md"; echo x > "$A/sub/x.txt"; echo y > "$A/sub/y.txt"
  python3 "$QR" bind "$A" "$TMP/b$N.json" >/dev/null
  python3 "$TMP/inv.py" "$A" > "$TMP/i$N.json"
  QID="$(python3 "$QR" phase1 "$A" "$TMP/i$N.json" "$TMP/b$N.json")"; QID="${QID#quarantined:}"
  ( DISK_MAGICIAN_TEST_KILL_AT=mid_delete python3 "$QR" phase2 "$TMP/b$N.json" "$QID" >/dev/null 2>&1 ) 2>/dev/null || true
}
qr() { bash "$ROOT/scripts/quarantine_reconcile.sh" --root "$TMP/scratch" "$@" 2>&1; }

# Deferred entry: dry-run reports it and changes nothing; --clean finishes and logs it.
deferred_entry; ID1="$QID"; Q1="$Q"; A1="$A"
OUT="$(qr --dry-run)"
check 'dry-run lists the deferred entry as purge' grep -q "^purge.$ID1" <<<"$OUT"
check 'dry-run leaves the quarantine payload in place' [ -e "$Q1/$ID1" ]
OUT="$(qr --clean --deadline-seconds 60)"
check 'clean finishes phase 2 (result removed)' grep -q "^result.removed:$ID1" <<<"$OUT"
check 'clean removes payload, sidecar and index entry' bash -c '[[ ! -e "$1/$2" && ! -e "$1/$2.json" && ! -e "$3/quarantine-index/$2.json" ]]' _ "$Q1" "$ID1" "$DISK_MAGICIAN_STATE_DIR"
check 'clean logs quarantine-phase2 to the deletion log' grep -q "quarantine-phase2" "$DISK_MAGICIAN_DELETION_LOG"

# Identity mismatch: the index no longer matches the parent, so nothing is deleted.
deferred_entry; ID2="$QID"; Q2="$Q"
python3 - "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$ID2.json" <<'PY'
import json, sys
p = sys.argv[1]; r = json.load(open(p)); r["parent_ino"] += 1; json.dump(r, open(p, "w"))
PY
OUT="$(qr --clean --deadline-seconds 60)"
check 'identity mismatch is reported kept' grep -q "^kept.$ID2" <<<"$OUT"
check 'identity mismatch leaves the payload' [ -e "$Q2/$ID2/report.md" -o -e "$Q2/$ID2/sub" ]
rm -f "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$ID2.json"

# Unreadable manifest: kept, payload untouched.
deferred_entry; ID3="$QID"; Q3="$Q"
printf '{not json' > "$Q3/$ID3.json"
OUT="$(qr --clean --deadline-seconds 60)"
check 'unreadable manifest is reported, not purged' grep -q "$ID3" <<<"$OUT"
check 'unreadable manifest leaves payload and sidecar' [ -e "$Q3/$ID3" -a -e "$Q3/$ID3.json" ]
rm -f "$DISK_MAGICIAN_STATE_DIR/quarantine-index/$ID3.json"

# Partial update files: pruned when they match the temp-name shape; other files kept.
deferred_entry; ID4="$QID"; Q4="$Q"
: > "$Q4/$ID4.json.update.0123456789abcdef"; printf 'partial' > "$Q4/$ID4.json.update.fedcba9876543210"; echo keep > "$Q4/note.txt"
qr --clean --deadline-seconds 60 >/dev/null
check 'stale sidecar update files are pruned' bash -c '! ls "$1"/*.json.update.* >/dev/null 2>&1' _ "$Q4"
check 'unrelated files in the store are kept' [ -f "$Q4/note.txt" ]
check 'pruned partials are logged' grep -q "quarantine-partial" "$DISK_MAGICIAN_DELETION_LOG"

# Orphan store (no index entry) is reported, never touched.
mkdir -p "$TMP/scratch/orph/.dm-quarantine/abc"; chmod 700 "$TMP/scratch/orph/.dm-quarantine"
OUT="$(qr --clean --deadline-seconds 60)"
check 'orphan store is reported' grep -q "^orphan-store.*orph/.dm-quarantine" <<<"$OUT"
check 'orphan store content is untouched' [ -d "$TMP/scratch/orph/.dm-quarantine/abc" ]

# Dispatcher wiring.
check 'diskm dispatcher routes quarantine-reconcile' bash -c '"$1/disk_magician.sh" quarantine-reconcile --root "$2" --dry-run >/dev/null 2>&1' _ "$ROOT" "$TMP/scratch"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
