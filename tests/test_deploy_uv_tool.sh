#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DEPLOY="$REPO_ROOT/tools/deploy_uv_tool.sh"
WORK="$(mktemp -d -t deploy_uv_tool_test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL + 1)); }

if [[ ! -x "$SOURCE_DEPLOY" ]]; then
  bad "deploy helper exists" "missing executable: $SOURCE_DEPLOY"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

REMOTE="$WORK/remote.git"
TREE="$WORK/tree"
STATE_DIR="$WORK/state"
TOOL_ROOT="$WORK/tool-root"
UV_STUB="$WORK/uv"
mkdir -p "$STATE_DIR"
git init --bare -q "$REMOTE"
git init -q -b main "$TREE"
git -C "$TREE" config user.name "Disk Magician Test"
git -C "$TREE" config user.email "jleechan2015@users.noreply.github.com"
mkdir -p "$TREE/scripts" "$TREE/src/disk_magician/nested" "$TREE/src/disk_magician/launchd"
cp "$SOURCE_DEPLOY" "$TREE/scripts/deploy_uv_tool.sh"
printf 'fixture-content\n' > "$TREE/src/disk_magician/fixture.txt"
printf 'nested-content\n' > "$TREE/src/disk_magician/nested/module.py"
printf '<plist>generated</plist>\n' > "$TREE/src/disk_magician/launchd/generated.plist"
cat > "$TREE/scripts/sync_package_tree.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--check" ]] || exit 2
echo "sync-package-check-pass"
EOF
chmod +x "$TREE/scripts/deploy_uv_tool.sh" "$TREE/scripts/sync_package_tree.sh"
cat > "$TREE/pyproject.toml" <<'EOF'
[project]
name = "disk-magician"
version = "9.9.9"
EOF
git -C "$TREE" add .
git -C "$TREE" commit -qm "test baseline"
git -C "$TREE" remote add origin "$REMOTE"
git -C "$TREE" push -qu origin main

cat > "$UV_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repo="${!#}"
deployed="$DISK_MAGICIAN_TOOL_ROOT/lib/python3.13/site-packages/disk_magician"
rm -rf "$DISK_MAGICIAN_TOOL_ROOT"
mkdir -p "$DISK_MAGICIAN_TOOL_ROOT/bin" "$deployed"
cp -R "$repo/src/disk_magician/." "$deployed/"
mode="${UV_MODE:-normal}"
case "$mode" in
  missing-file) rm -f "$deployed/nested/module.py" ;;
  changed-file) printf 'changed-by-uv\n' > "$deployed/fixture.txt" ;;
  extra-file) printf 'obsolete\n' > "$deployed/removed_module.py" ;;
  mutate-source) printf 'mutated-during-install\n' >> "$repo/pyproject.toml" ;;
esac
cat > "$DISK_MAGICIAN_TOOL_ROOT/bin/python" <<'PYTHON'
#!/usr/bin/env bash
if [[ "${UV_MODE:-normal}" == wrong-version ]]; then
  echo 9.9.8
else
  echo 9.9.9
fi
PYTHON
chmod +x "$DISK_MAGICIAN_TOOL_ROOT/bin/python"
if [[ "$mode" != missing-disk-magician ]]; then
  cat > "$DISK_MAGICIAN_TOOL_ROOT/bin/disk-magician" <<'ENTRY'
#!/usr/bin/env bash
if [[ "${UV_MODE:-normal}" == fail-disk-magician ]]; then exit 7; fi
printf '%s\n' 'disk-magician help'
ENTRY
  chmod +x "$DISK_MAGICIAN_TOOL_ROOT/bin/disk-magician"
fi
if [[ "$mode" != missing-diskm ]]; then
  cat > "$DISK_MAGICIAN_TOOL_ROOT/bin/diskm" <<'ENTRY'
#!/usr/bin/env bash
if [[ "${UV_MODE:-normal}" == fail-diskm ]]; then exit 8; fi
if [[ "${UV_MODE:-normal}" == different-help ]]; then
  printf '%s\n' 'diskm help differs'
else
  printf '%s\n' 'disk-magician help'
fi
ENTRY
  chmod +x "$DISK_MAGICIAN_TOOL_ROOT/bin/diskm"
fi
EOF
chmod +x "$UV_STUB"

run_deploy() {
  UV_MODE="${1:-normal}" DISK_MAGICIAN_UV_BIN="$UV_STUB" \
    DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
    "$TREE/scripts/deploy_uv_tool.sh" >"$WORK/run.out" 2>&1
}

if DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh" --check >"$WORK/base-check.out" 2>&1 && [[ ! -e "$STATE_DIR/deployed.json" ]]; then
  ok "clean HEAD equal to origin/main is deployable and check-only writes no receipt"
else
  bad "clean HEAD equal to origin/main is deployable and check-only writes no receipt" "$(cat "$WORK/base-check.out")"
fi

if run_deploy normal; then
  ok "successful install publishes a receipt"
else
  bad "successful install publishes a receipt" "$(cat "$WORK/run.out")"
fi

RECEIPT="$STATE_DIR/deployed.json"
if [[ -f "$RECEIPT" ]]; then
  ok "success receipt exists"
else
  bad "success receipt exists" "missing $RECEIPT"
fi

BASE_SHA="$(git -C "$TREE" rev-parse HEAD)"
EXPECTED_FIXTURE_HASH="$(python3 - "$TREE/src/disk_magician/fixture.txt" "$TREE/src/disk_magician/nested/module.py" <<'PY'
import hashlib
import json
import sys
print(json.dumps({path.rsplit('/src/disk_magician/', 1)[1]: hashlib.sha256(open(path, 'rb').read()).hexdigest() for path in sys.argv[1:]}, sort_keys=True))
PY
)"
if python3 - "$RECEIPT" "$BASE_SHA" "$EXPECTED_FIXTURE_HASH" "$TREE" "$TOOL_ROOT" <<'PY'
import json
import os
import sys

receipt_path, expected_sha, expected_hashes_json, source_root, tool_root = sys.argv[1:]
receipt = json.load(open(receipt_path))
expected_hashes = json.loads(expected_hashes_json)
assert receipt["schema_version"] == 1
assert receipt["source_sha"] == expected_sha
assert receipt["installed_version"] == "9.9.9"
assert receipt["deployed_at"].endswith("Z")
assert receipt["package_root"] == os.path.realpath(os.path.join(tool_root, "lib/python3.13/site-packages/disk_magician"))
assert receipt["package_hashes"] == expected_hashes
assert receipt["source_root"] == os.path.realpath(source_root)
assert receipt["override_state"] == "none"
PY
then
  ok "receipt records exact SHA, version, resolved roots, and package hashes"
else
  bad "receipt records exact SHA, version, resolved roots, and package hashes" "receipt validation failed"
fi

if "$TOOL_ROOT/bin/disk-magician" --help >"$WORK/help1" 2>&1 && "$TOOL_ROOT/bin/diskm" --help >"$WORK/help2" 2>&1 && cmp -s "$WORK/help1" "$WORK/help2"; then
  ok "both installed entrypoints execute and help output agrees"
else
  bad "both installed entrypoints execute and help output agrees" "entrypoint help mismatch"
fi

RECEIPT_BYTES="$WORK/receipt.before"
cp "$RECEIPT" "$RECEIPT_BYTES"
assert_failed_preserves_receipt() {
  local name="$1"
  shift
  if "$@" >"$WORK/$name.out" 2>&1; then
    bad "$name" "command unexpectedly succeeded"
  elif cmp -s "$RECEIPT_BYTES" "$RECEIPT"; then
    ok "$name"
  else
    bad "$name" "receipt changed after failure: $(cat "$WORK/$name.out")"
  fi
}

assert_failed_preserves_receipt wrong-installed-version env UV_MODE=wrong-version DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
assert_failed_preserves_receipt missing-package-file env UV_MODE=missing-file DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
assert_failed_preserves_receipt changed-package-file env UV_MODE=changed-file DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
assert_failed_preserves_receipt extra-package-file env UV_MODE=extra-file DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
assert_failed_preserves_receipt missing-disk-magician env UV_MODE=missing-disk-magician DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
assert_failed_preserves_receipt missing-diskm env UV_MODE=missing-diskm DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
assert_failed_preserves_receipt failing-disk-magician env UV_MODE=fail-disk-magician DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
assert_failed_preserves_receipt failing-diskm env UV_MODE=fail-diskm DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
assert_failed_preserves_receipt differing-help env UV_MODE=different-help DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
assert_failed_preserves_receipt changed-source-during-install env UV_MODE=mutate-source DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh"
git -C "$TREE" restore pyproject.toml

if DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$STATE_DIR" \
  "$TREE/scripts/deploy_uv_tool.sh" --check >"$WORK/check.out" 2>&1 && cmp -s "$RECEIPT_BYTES" "$RECEIPT"; then
  ok "--check does not write the receipt"
else
  bad "--check does not write the receipt" "$(cat "$WORK/check.out")"
fi

echo dirty >> "$TREE/pyproject.toml"
assert_failed_preserves_receipt dirty-source env DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh" --check
git -C "$TREE" restore pyproject.toml

echo '# ahead' >> "$TREE/pyproject.toml"
git -C "$TREE" add pyproject.toml
git -C "$TREE" commit -qm "local branch ahead"
assert_failed_preserves_receipt branch-ahead env DISK_MAGICIAN_STATE_DIR="$STATE_DIR" "$TREE/scripts/deploy_uv_tool.sh" --check
git -C "$TREE" reset --hard -q origin/main

BLOCKED_STATE="$WORK/blocked-state"
printf 'existing receipt bytes\n' > "$BLOCKED_STATE"
if cmp -s "$RECEIPT_BYTES" "$RECEIPT" && ! env UV_MODE=normal DISK_MAGICIAN_UV_BIN="$UV_STUB" DISK_MAGICIAN_TOOL_ROOT="$TOOL_ROOT" DISK_MAGICIAN_STATE_DIR="$BLOCKED_STATE" "$TREE/scripts/deploy_uv_tool.sh" >"$WORK/atomic.out" 2>&1 && cmp -s "$RECEIPT_BYTES" "$RECEIPT"; then
  ok "atomic write failure is nonzero and preserves prior receipt"
else
  bad "atomic write failure is nonzero and preserves prior receipt" "$(cat "$WORK/atomic.out")"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
