#!/usr/bin/env bash
# tests/test_disk_snapshot_glob_overlap.sh
#
# Regression for the coverage-inflation bug the dot found on PR #210:
# monitored_globs under an already-measured monitored_dir were added on top of
# the parent's own measurement, so a 10 MiB parent holding 5 MiB of glob-matched
# children reported 15 MiB. That inflates snapshot_coverage_pct and can suppress
# the <70% coverage warning.
#
# Contract:
#   A) a glob match nested under a measured parent contributes 0 (deduped);
#   B) the same glob still counts when the parent's own measurement is
#      unavailable, so the child's only measurement is not lost.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_SH="$REPO_ROOT/scripts/disk_snapshot.sh"

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }
pass() { echo "PASS: $1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"

PARENT="$TMP/parent"
mkdir -p "$PARENT/child_a" "$PARENT/child_b" "$PARENT/other"
# ~6 MiB of children (5 of it inside the glob) + 1 MiB outside the glob.
dd if=/dev/zero of="$PARENT/child_a/blob" bs=1024 count=3072 2>/dev/null
dd if=/dev/zero of="$PARENT/child_b/blob" bs=1024 count=2048 2>/dev/null
dd if=/dev/zero of="$PARENT/other/blob"   bs=1024 count=1024 2>/dev/null

cat > "$FAKE_BIN/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/disk1s1 1000000000 1000000 999000000 1% /"
exit 0
EOF
chmod +x "$FAKE_BIN/df"

cat > "$FAKE_BIN/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "vm.swapusage: total = 1024.00M  used = 0.00M  free = 1024.00M  (encrypted)"
exit 0
EOF
chmod +x "$FAKE_BIN/sysctl"

make_config() {
  cat > "$TMP/config.json" <<EOF
{
  "monitored_dirs": [
    {"key": "parent", "path": "$PARENT", "timeout": 10}
  ],
  "monitored_globs": [
    {"key": "childglob", "pattern": "$PARENT/child*"}
  ],
  "monitored_file_globs": []
}
EOF
}
make_config

run_snapshot() {  # run_snapshot <outfile> <path-prefix>
  PATH="$2" HOME="$FAKE_HOME" \
    DISK_MAGICIAN_CONFIG="$TMP/config.json" \
    DISK_MAGICIAN_SNAPSHOT_BUDGET_SECONDS=60 \
    timeout 60 bash "$SNAPSHOT_SH" --output "$1" >"$TMP/stderr.log" 2>&1
}

# ── Case A: parent measured → glob fully deduped ─────────────────────────────
OUT_A="$TMP/a.json"
if ! run_snapshot "$OUT_A" "$FAKE_BIN:$PATH"; then
  fail "snapshot (case A) exited nonzero: $(tail -3 "$TMP/stderr.log")"
else
  python3 - "$OUT_A" <<'PY' && pass "glob under a measured parent is deduped to 0" || FAIL=1
import json, sys
d = json.load(open(sys.argv[1]))
dirs = d.get("directories") or {}
assert "childglob" in dirs, f"childglob missing from directories: {sorted(dirs)[:10]}"
assert dirs["childglob"] == 0, f"childglob should be deduped to 0 under a measured parent, got {dirs['childglob']}"
assert dirs.get("parent", 0) > 0, f"parent should be measured, got {dirs.get('parent')}"
PY
fi

# ── Case B: parent measurement unavailable → child must still count ──────────
# Fake du refuses only the parent path, so dir_size_kb(parent) is null while the
# child dirs still measure normally.
cat > "$FAKE_BIN/du" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == "$PARENT" ]]; then
    echo "du: cannot read parent" >&2
    exit 2
  fi
done
exec /usr/bin/du "\$@"
EOF
chmod +x "$FAKE_BIN/du"

OUT_B="$TMP/b.json"
if ! run_snapshot "$OUT_B" "$FAKE_BIN:$PATH"; then
  fail "snapshot (case B) exited nonzero: $(tail -3 "$TMP/stderr.log")"
else
  python3 - "$OUT_B" <<'PY' && pass "glob still counts when the parent is unavailable" || FAIL=1
import json, sys
d = json.load(open(sys.argv[1]))
dirs = d.get("directories") or {}
assert not dirs.get("parent"), f"parent should be unmeasured in case B, got {dirs.get('parent')}"
assert "childglob" in dirs, "childglob missing in case B"
assert dirs["childglob"] and dirs["childglob"] > 0, \
    f"childglob must keep its measurement when the parent is unavailable, got {dirs['childglob']}"
PY
fi

echo "FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
