#!/usr/bin/env bash
# Tests for scripts/cleanup_worktree_deps.sh (3-day floor, dormant worktrees only).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/cleanup_worktree_deps.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
check() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1 (missing: $2)"; }

git init -q "$T/base"; echo src > "$T/base/src.txt"; git -C "$T/base" add src.txt; git -C "$T/base" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$T/roots"
for n in old young linked; do git -C "$T/base" worktree add -q -b "b-$n" "$T/roots/$n"; mkdir -p "$T/roots/$n/node_modules/x"; echo d > "$T/roots/$n/node_modules/x/f"; done
mkdir -p "$T/real_nm"; rm -rf "$T/roots/linked/node_modules"; ln -s "$T/real_nm" "$T/roots/linked/node_modules"
git -C "$T/base" worktree add -q -b "b-external" "$T/external_repo/wt"
mkdir -p "$T/external_repo/wt/node_modules/x"; echo external > "$T/external_repo/wt/node_modules/x/f"
ln -s "$T/external_repo" "$T/roots/repo-link"
# old: every file 10 days old; young: left fresh; linked: old but node_modules is a symlink
/usr/bin/find "$T/roots/old" "$T/roots/linked" "$T/external_repo/wt" -exec touch -h -t "$(date -v-10d +%Y%m%d%H%M)" {} + 2>/dev/null
mkdir -p "$T/home"

OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
check "dry-run lists old worktree node_modules" "WOULD-STRIP" "$OUT"
check "dry-run names old worktree" "$T/roots/old/node_modules" "$OUT"
[[ "$OUT" != *"$T/roots/young/node_modules"* ]] && ok "young worktree untouched" || bad "young worktree listed"
[[ "$OUT" != *"$T/roots/linked/node_modules"* ]] && ok "symlinked node_modules untouched" || bad "symlink listed"
[[ "$OUT" != *"$T/roots/repo-link/wt/node_modules"* ]] && ok "symlinked worktree ancestor untouched" || bad "external worktree dependency listed"
[[ -d "$T/roots/old/node_modules" ]] && ok "dry-run deletes nothing" || bad "dry-run deleted"

OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
check "--clean without approval refuses" "Refusing to delete" "$OUT"
[[ -d "$T/roots/old/node_modules" ]] && ok "unapproved clean deletes nothing" || bad "unapproved clean deleted"

OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" WORKTREE_APPROVED=1 DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
check "approved clean strips" "STRIPPED" "$OUT"
[[ ! -e "$T/roots/old/node_modules" ]] && ok "old node_modules removed" || bad "old node_modules remains"
[[ -d "$T/roots/young/node_modules" ]] && ok "young node_modules kept" || bad "young node_modules removed"
[[ -L "$T/roots/linked/node_modules" && -d "$T/real_nm" ]] && ok "symlink target kept" || bad "symlink target damaged"
[[ -f "$T/external_repo/wt/node_modules/x/f" ]] && ok "external worktree dependencies kept" || bad "external worktree dependencies removed"
[[ -f "$T/roots/old/.git" ]] && ok "worktree .git preserved" || bad ".git removed"

# AO config worktreeDir: worktrees under a configured AO dir are never stripped.
printf 'projects:\n  demo:\n    worktreeDir: %s\n' "$T/roots" > "$T/ao.yaml"
mkdir -p "$T/roots/old/node_modules/y"; echo d > "$T/roots/old/node_modules/y/f"
/usr/bin/find "$T/roots/old" -exec touch -h -t "$(date -v-10d +%Y%m%d%H%M)" {} +
OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_AO_CONFIG="$T/ao.yaml" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
[[ "$OUT" != *"WOULD-STRIP"* ]] && ok "AO config worktreeDir worktree untouched" || bad "AO-owned worktree listed"

# Top-level AO worktreeDir protects direct children and configured project subtrees,
# while non-AO repo worktrees (<default>/<other_repo>/<wt>) ARE stripped (including packages/*/node_modules).
printf 'worktreeDir: %s\nprojects:\n  demo:\n    path: /tmp/demo\n' "$T/roots" > "$T/ao_top.yaml"
mkdir -p "$T/roots/demo" "$T/roots/other_repo"
git -C "$T/base" worktree add -q -b "b-demo-wt1" "$T/roots/demo/wt1"
mkdir -p "$T/roots/demo/wt1/node_modules/z"; echo d > "$T/roots/demo/wt1/node_modules/z/f"
git -C "$T/base" worktree add -q -b "b-other-old" "$T/roots/other_repo/wt_old"
mkdir -p "$T/roots/other_repo/wt_old/packages/pkg-a/node_modules/m"
echo '{}' > "$T/roots/other_repo/wt_old/packages/pkg-a/package.json"
echo d > "$T/roots/other_repo/wt_old/packages/pkg-a/node_modules/m/f"
# Symlinked package ancestors must never expose external dependency dirs.
mkdir -p "$T/external/pkg/node_modules/m"
echo '{}' > "$T/external/pkg/package.json"
echo external > "$T/external/pkg/node_modules/m/f"
ln -s "$T/external/pkg" "$T/roots/other_repo/wt_old/packages/pkg-link"
git -C "$T/base" worktree add -q -b "b-linked-packages" "$T/roots/other_repo/wt_linked_packages"
ln -s "$T/external" "$T/roots/other_repo/wt_linked_packages/packages"
# A regular root dependency forces the strip loop even when packages is a link.
mkdir -p "$T/roots/other_repo/wt_linked_packages/node_modules/m"
echo d > "$T/roots/other_repo/wt_linked_packages/node_modules/m/f"
/usr/bin/find "$T/roots/demo/wt1" "$T/roots/other_repo/wt_old" "$T/roots/other_repo/wt_linked_packages" -exec touch -h -t "$(date -v-10d +%Y%m%d%H%M)" {} + 2>/dev/null
OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" WORKTREE_APPROVED=1 DISK_MAGICIAN_AO_CONFIG="$T/ao_top.yaml" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
[[ "$OUT" != *"$T/roots/old/node_modules"* ]] && ok "direct child of top-level AO worktreeDir protected" || bad "direct child of top-level AO worktreeDir stripped"
[[ "$OUT" != *"$T/roots/demo/wt1/node_modules"* && -d "$T/roots/demo/wt1/node_modules" ]] && ok "AO project worktree under top-level worktreeDir protected" || bad "AO project worktree stripped"
check "non-AO repo worktree under top-level worktreeDir stripped" "$T/roots/other_repo/wt_old/packages/pkg-a/node_modules" "$OUT"
[[ ! -e "$T/roots/other_repo/wt_old/packages/pkg-a/node_modules" ]] && ok "monorepo packages/*/node_modules removed" || bad "monorepo packages/*/node_modules remains"
[[ "$OUT" != *"$T/roots/other_repo/wt_old/packages/pkg-link/node_modules"* && -f "$T/external/pkg/node_modules/m/f" ]] && ok "symlinked package ancestor protected" || bad "symlinked package ancestor traversed"
[[ "$OUT" != *"$T/roots/other_repo/wt_linked_packages/packages/pkg/node_modules"* && -f "$T/external/pkg/node_modules/m/f" ]] && ok "symlinked packages ancestor protected" || bad "symlinked packages ancestor traversed"
[[ ! -e "$T/roots/other_repo/wt_linked_packages/node_modules" ]] && ok "linked-packages worktree still strips regular root dependencies" || bad "linked-packages worktree not processed"

# safety_gate: a never_delete rule protects the directory.
mkdir -p "$T/cfg"; printf '{"never_delete": ["%s/roots/old/node_modules"]}' "$T" > "$T/cfg/safety.local.json"
OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_SAFETY_FILE="$T/cfg/safety.local.json" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
check "never_delete rule blocks the strip" "SAFETY-SKIP" "$OUT"

# Fail closed when lsof output is unparseable: nothing may be stripped.
mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "nrelative/path"\n' > "$T/fakebin/lsof"; chmod +x "$T/fakebin/lsof"
OUT="$(env -i HOME="$T/home" PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin" WORKTREE_APPROVED=1 DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
check "unparseable lsof output refuses" "cwd unknown, refusing" "$OUT"
[[ "$OUT" != *"STRIPPED"* ]] && ok "unparseable lsof strips nothing" || bad "stripped despite bad lsof"
printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/lsof"
OUT="$(env -i HOME="$T/home" PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin" WORKTREE_APPROVED=1 DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
check "failing lsof refuses" "cwd unknown, refusing" "$OUT"

# Nested rebuildable caches (depth >= 2): a target/ or node_modules/ is stripped
# only when its parent dir holds the manifest that produces it (Cargo.toml or
# package.json). A dir that merely shares the name is preserved.
git -C "$T/base" worktree add -q -b "b-nested" "$T/roots/nested"
mkdir -p "$T/roots/nested/daemon/target/debug"
echo 'fn main() {}' > "$T/roots/nested/daemon/Cargo.toml"
echo bin > "$T/roots/nested/daemon/target/debug/app"
mkdir -p "$T/roots/nested/not_build/target/debug"
echo bin > "$T/roots/nested/not_build/target/debug/app"
# A workspace-root manifest does not authorize nested targets; only the sibling
# manifest beside the dir proves it is cargo build output.
echo '[workspace]' > "$T/roots/nested/Cargo.toml"
mkdir -p "$T/roots/nested/target/debug"
echo bin > "$T/roots/nested/target/debug/app"
mkdir -p "$T/roots/nested/app/node_modules/left-pad"
echo '{}' > "$T/roots/nested/app/package.json"
echo dep > "$T/roots/nested/app/node_modules/left-pad/index.js"
# A symlinked parent is not traversed, even though the external tree has a manifest.
mkdir -p "$T/external_daemon/target/debug"
echo 'fn main() {}' > "$T/external_daemon/Cargo.toml"
echo bin > "$T/external_daemon/target/debug/app"
ln -s "$T/external_daemon" "$T/roots/nested/linked_daemon"
/usr/bin/find "$T/roots/nested" -exec touch -h -t "$(date -v-10d +%Y%m%d%H%M)" {} + 2>/dev/null
OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
check "nested daemon/target (Cargo.toml sibling) listed" "$T/roots/nested/daemon/target" "$OUT"
check "nested node_modules (package.json sibling) listed" "$T/roots/nested/app/node_modules" "$OUT"
[[ "$OUT" != *"$T/roots/nested/not_build/target"* ]] && ok "nested target without a Cargo.toml sibling preserved" || bad "manifest-less nested target listed"
check "root target with Cargo.toml still listed" "$T/roots/nested/target" "$OUT"
[[ "$OUT" != *"linked_daemon"* && "$OUT" != *"$T/external_daemon/target"* ]] && ok "symlinked nested parent not traversed" || bad "symlinked nested parent traversed"
OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" WORKTREE_APPROVED=1 DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
[[ ! -e "$T/roots/nested/daemon/target" && -f "$T/roots/nested/daemon/Cargo.toml" ]] && ok "nested daemon/target removed, manifest kept" || bad "nested daemon/target not removed"
[[ ! -e "$T/roots/nested/app/node_modules" && -f "$T/roots/nested/app/package.json" ]] && ok "nested node_modules removed, package.json kept" || bad "nested node_modules not removed"
[[ -f "$T/roots/nested/not_build/target/debug/app" ]] && ok "manifest-less nested target survives --clean" || bad "manifest-less nested target removed"
[[ ! -e "$T/roots/nested/target" && -f "$T/roots/nested/Cargo.toml" ]] && ok "root target removed beside its Cargo.toml" || bad "root target not removed"
[[ -f "$T/external_daemon/target/debug/app" ]] && ok "external symlink target survives --clean" || bad "external symlink target damaged"

# Candidates >= 90d (>3 months) are stripped by --clean without WORKTREE_APPROVED=1, while < 90d are preserved.
mkdir -p "$T/roots90"
git -C "$T/base" worktree add -q -b "b-ancient90" "$T/roots90/ancient"
git -C "$T/base" worktree add -q -b "b-mid30" "$T/roots90/mid"
mkdir -p "$T/roots90/ancient/node_modules/x" "$T/roots90/mid/node_modules/x"
echo d > "$T/roots90/ancient/node_modules/x/f"
echo d > "$T/roots90/mid/node_modules/x/f"
/usr/bin/find "$T/roots90/ancient" -exec touch -h -t "$(date -v-100d +%Y%m%d%H%M)" {} + 2>/dev/null
/usr/bin/find "$T/roots90/mid" -exec touch -h -t "$(date -v-30d +%Y%m%d%H%M)" {} + 2>/dev/null
OUT90="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots90" bash "$SCRIPT" --clean 2>&1)"
[[ ! -e "$T/roots90/ancient/node_modules" ]] && ok ">=90d worktree node_modules stripped without WORKTREE_APPROVED=1" || bad ">=90d worktree node_modules not stripped"
[[ -d "$T/roots90/mid/node_modules" ]] && ok "<90d worktree node_modules preserved without WORKTREE_APPROVED=1" || bad "<90d worktree node_modules stripped without approval"

echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]
