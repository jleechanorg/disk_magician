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

for policy in AGENTS.md CLAUDE.md; do
  if grep -q 'tools/deploy_uv_tool.sh' "$REPO_ROOT/$policy"; then
    ok "$policy routes deployment through the provenance guard"
  else
    bad "$policy routes deployment through the provenance guard" "wrapper not referenced"
  fi
done

REMOTE="$WORK/remote.git"
TREE="$WORK/tree"
git init --bare -q "$REMOTE"
git init -q -b main "$TREE"
git -C "$TREE" config user.name "Disk Magician Test"
git -C "$TREE" config user.email "jleechan2015@users.noreply.github.com"
mkdir -p "$TREE/scripts" "$TREE/src/disk_magician"
cp "$SOURCE_DEPLOY" "$TREE/scripts/deploy_uv_tool.sh"
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

BASE_OUT="$WORK/base.out"
if "$TREE/scripts/deploy_uv_tool.sh" --check >"$BASE_OUT" 2>&1; then
  ok "clean HEAD equal to origin/main is deployable"
else
  bad "clean HEAD equal to origin/main is deployable" "$(cat "$BASE_OUT")"
fi

echo dirty >> "$TREE/pyproject.toml"
DIRTY_OUT="$WORK/dirty.out"
if "$TREE/scripts/deploy_uv_tool.sh" --check >"$DIRTY_OUT" 2>&1; then
  bad "dirty source is refused" "command unexpectedly succeeded"
elif grep -qi "dirty" "$DIRTY_OUT"; then
  ok "dirty source is refused"
else
  bad "dirty source is refused" "missing diagnostic: $(cat "$DIRTY_OUT")"
fi
git -C "$TREE" restore pyproject.toml

echo '# ahead' >> "$TREE/pyproject.toml"
git -C "$TREE" add pyproject.toml
git -C "$TREE" commit -qm "local branch ahead"
AHEAD_OUT="$WORK/ahead.out"
if "$TREE/scripts/deploy_uv_tool.sh" --check >"$AHEAD_OUT" 2>&1; then
  bad "branch-ahead source is refused" "command unexpectedly succeeded"
elif grep -q "origin/main" "$AHEAD_OUT"; then
  ok "branch-ahead source is refused"
else
  bad "branch-ahead source is refused" "missing diagnostic: $(cat "$AHEAD_OUT")"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
