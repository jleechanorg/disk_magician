#!/usr/bin/env bash
# test_scratch_dir.sh — `diskm scratch-dir [subpath]` resolver tests.
set -uo pipefail
unset BASH_ENV

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISKM="$REPO_ROOT/disk_magician.sh"
ADAPTER="$REPO_ROOT/.agents/skills/scratch-space/scripts/scratch-dir.sh"

PASS=0 FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }
assert_contains() { if [[ "$1" == *"$2"* ]]; then ok "$3"; else bad "$3 — missing '$2' in: $1"; fi; }

T="$(mktemp -d /tmp/dm-scratch-dir.XXXXXX)" || exit 1
[[ "$T" == /tmp/dm-scratch-dir.* && -d "$T" && ! -L "$T" ]] || exit 1
T="$(cd -- "$T" && pwd -P)" || exit 1
cleanup_fixture() {
  case "${T:-}" in
    /tmp/dm-scratch-dir.*|/private/tmp/dm-scratch-dir.*) rm -rf -- "$T" ;;
  esac
}
trap cleanup_fixture EXIT

mkdir -p "$T/active" "$T/fast" "$T/home" "$T/bin"
export HOME="$T/home"

cat > "$T/bin/mock_diskm_active" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "volume path scratch") printf '%s\\n' "$T/active"; exit 0 ;;
  scratch-dir*) printf 'adapter-cli:%s\\n' "\${2:-}"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/mock_diskm_active"

echo "== 1. Active volume resolution =="
OUT="$(DISKM_SCRATCH="$T/fast" DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_active" bash "$DISKM" scratch-dir)"
RC=$?
assert_eq "$RC" 0 "active volume exit code is 0"
assert_eq "$OUT" "$T/active" "active volume path wins over stale DISKM_SCRATCH"

OUT_PKG="$(PYTHONPATH="$REPO_ROOT/src" DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_active" python3 -m disk_magician.cli scratch-dir)"
assert_eq "$OUT_PKG" "$T/active" "packaged CLI scratch-dir returns active volume root"

OUT_ADAPTER="$(DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_active" bash "$ADAPTER" adapter-subpath)"
assert_eq "$OUT_ADAPTER" "adapter-cli:adapter-subpath" "skill adapter delegates to canonical CLI"

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/diskm" <<'EOF'
#!/usr/bin/env bash
printf 'home-fallback:%s\n' "${2:-}"
EOF
chmod +x "$HOME/.local/bin/diskm"
OUT_ADAPTER_HOME="$(env -u DISK_MAGICIAN_DISKM_BIN PATH=/usr/bin:/bin HOME="$HOME" bash "$ADAPTER" home-subpath)"
assert_eq "$OUT_ADAPTER_HOME" "home-fallback:home-subpath" "skill adapter uses user-local CLI fallback"

echo "== 2. Subpath creation (scratch-dir tmp) =="
OUT="$(DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_active" bash "$DISKM" scratch-dir tmp)"
RC=$?
assert_eq "$RC" 0 "scratch-dir tmp exit code is 0"
assert_eq "$OUT" "$T/active/tmp" "scratch-dir tmp returns subpath"
[[ -d "$T/active/tmp" ]] && ok "subpath directory was created" || bad "subpath directory not created"

OUT_NESTED="$(DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_active" bash "$DISKM" scratch-dir "nested/deep/dir")"
assert_eq "$OUT_NESTED" "$T/active/nested/deep/dir" "nested subpath returned"
[[ -d "$T/active/nested/deep/dir" ]] && ok "nested directory was created" || bad "nested directory not created"

echo "== 2b. Symlink containment is fail-closed before creation =="
OUTSIDE="$T/outside"
mkdir -p "$OUTSIDE"
ln -s "$OUTSIDE" "$T/active/intermediate"
RC=0
ERR="$(DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_active" bash "$DISKM" scratch-dir intermediate/created 2>&1)" || RC=$?
assert_eq "$RC" 75 "intermediate symlink exits 75"
assert_eq "$ERR" "scratch-dir: subpath escapes Scratch root" "intermediate symlink error"
[[ ! -e "$OUTSIDE/created" ]] && ok "intermediate symlink created nothing outside Scratch" || bad "intermediate symlink escaped Scratch"

ln -s "$OUTSIDE" "$T/active/final"
RC=0
ERR="$(DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_active" bash "$DISKM" scratch-dir final 2>&1)" || RC=$?
assert_eq "$RC" 75 "final symlink exits 75"
assert_eq "$ERR" "scratch-dir: subpath escapes Scratch root" "final symlink error"

ln -s "$T/active" "$T/active/inside"
OUT_INSIDE="$(DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_active" bash "$DISKM" scratch-dir inside/created 2>&1)"
assert_eq "$OUT_INSIDE" "$T/active/inside/created" "inward symlink remains physically contained"
[[ -d "$T/active/created" ]] && ok "inward symlink created only inside Scratch" || bad "inward symlink was not usable"
[[ ! -e "$OUTSIDE/created" ]] && ok "final symlink created nothing outside Scratch" || bad "final symlink escaped Scratch"

echo "== 3. Path traversal rejection (scratch-dir ../bad exits 2) =="
RC=0
ERR="$(bash "$DISKM" scratch-dir ../bad 2>&1)" || RC=$?
assert_eq "$RC" 2 "scratch-dir ../bad exits 2"
assert_contains "$ERR" "invalid subpath" "scratch-dir ../bad error message"

RC=0
ERR="$(bash "$DISKM" scratch-dir "foo/../bar" 2>&1)" || RC=$?
assert_eq "$RC" 2 "scratch-dir foo/../bar exits 2"

RC=0
ERR="$(bash "$DISKM" scratch-dir "" 2>&1)" || RC=$?
assert_eq "$RC" 2 "scratch-dir empty string exits 2"

echo "== 4. /tmp fallback when no Scratch volume is configured =="
cat > "$T/bin/mock_diskm_no_volume" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "volume path scratch" ]] && exit 3
exit 1
EOF
chmod +x "$T/bin/mock_diskm_no_volume"

printf '{"budgets":{"daily":5}}' > "$T/legacy-config.json"

OUT="$(env -u DISKM_SCRATCH DISK_MAGICIAN_CONFIG="$T/legacy-config.json" DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_no_volume" bash "$DISKM" scratch-dir)"
RC=$?
assert_eq "$RC" 0 "fallback exit code is 0"
assert_contains "$OUT" "tmp" "/tmp fallback root contains tmp"

OUT_FALLBACK_SUB="$(env -u DISKM_SCRATCH DISK_MAGICIAN_CONFIG="$T/legacy-config.json" DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_no_volume" bash "$DISKM" scratch-dir "test-fallback-$$-$RANDOM")"
RC=$?
assert_eq "$RC" 0 "fallback subpath exit code is 0"
[[ -d "$OUT_FALLBACK_SUB" ]] && ok "fallback subpath directory exists" || bad "fallback subpath directory missing"
rm -rf "$OUT_FALLBACK_SUB" 2>/dev/null || true

echo "== 5. Registered but unavailable Scratch fails closed =="
cat > "$T/bin/mock_diskm_unavailable" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "volume path scratch" ]] && exit 75
exit 1
EOF
chmod +x "$T/bin/mock_diskm_unavailable"

RC=0
ERR="$(env -u DISKM_SCRATCH DISK_MAGICIAN_CONFIG="$T/legacy-config.json" DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_unavailable" bash "$DISKM" scratch-dir 2>&1)" || RC=$?
assert_eq "$RC" 75 "unavailable registered Scratch exits 75"
assert_contains "$ERR" "Scratch volume lookup failed" "unavailable registered Scratch reports lookup failure"

RC=0
ERR="$(DISKM_SCRATCH="$T/missing" DISK_MAGICIAN_DISKM_BIN="$T/bin/mock_diskm_active" bash "$DISKM" scratch-dir 2>&1)" || RC=$?
assert_eq "$RC" 0 "stale DISKM_SCRATCH does not override active volume"
assert_eq "$ERR" "$T/active" "stale DISKM_SCRATCH resolves through active volume identity"

RC=0
ERR="$(DISK_MAGICIAN_DISKM_BIN="$T/bin/missing-diskm" bash "$DISKM" scratch-dir 2>&1)" || RC=$?
assert_eq "$RC" 75 "invalid configured CLI exits 75"
assert_contains "$ERR" "configured Disk Magician CLI is unavailable" "invalid configured CLI fails closed"

echo "== test_scratch_dir summary: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]] || exit 1
