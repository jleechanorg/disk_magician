#!/usr/bin/env bash
# Tests for scripts/cleanup_worktree_deps.sh (3-day floor, dormant worktrees only).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/cleanup_worktree_deps.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
# Unprivileged Linux lsof fails closed on other users' processes (by design), so
# tests on Linux use a shim that reports every cwd this user can read from /proc.
LSOF_SHIM=""
if [[ "$(uname)" == Linux ]]; then
  mkdir -p "$T/linuxbin"; LSOF_SHIM="$T/linuxbin:"
  printf '#!/bin/sh\nfor d in /proc/[0-9]*; do c=$(readlink "$d/cwd" 2>/dev/null) && printf "p%%s\\nn%%s\\n" "${d#/proc/}" "$c"; done; exit 0\n' > "$T/linuxbin/lsof"; chmod +x "$T/linuxbin/lsof"
fi
ok() { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
old_ts() { date -v-10d +%Y%m%d%H%M 2>/dev/null || date -d "10 days ago" +%Y%m%d%H%M; }
hours_ts() { date -v-"$1"H +%Y%m%d%H%M 2>/dev/null || date -d "$1 hours ago" +%Y%m%d%H%M; }
check() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1 (missing: $2)"; }

git init -q "$T/base"; echo src > "$T/base/src.txt"; git -C "$T/base" add src.txt; git -C "$T/base" -c user.email=t@t -c user.name=t commit -q -m init
mkdir -p "$T/roots"
for n in old young linked; do git -C "$T/base" worktree add -q -b "b-$n" "$T/roots/$n"; mkdir -p "$T/roots/$n/node_modules/x"; echo d > "$T/roots/$n/node_modules/x/f"; done
mkdir -p "$T/real_nm"; rm -rf "$T/roots/linked/node_modules"; ln -s "$T/real_nm" "$T/roots/linked/node_modules"
git -C "$T/base" worktree add -q -b "b-external" "$T/external_repo/wt"
mkdir -p "$T/external_repo/wt/node_modules/x"; echo external > "$T/external_repo/wt/node_modules/x/f"
ln -s "$T/external_repo" "$T/roots/repo-link"
# old: every file 10 days old; young: left fresh; linked: old but node_modules is a symlink
/usr/bin/find "$T/roots/old" "$T/roots/linked" "$T/external_repo/wt" -exec touch -h -t "$(old_ts)" {} + 2>/dev/null
mkdir -p "$T/home"

OUT="$(env -i HOME="$T/home" PATH="${LSOF_SHIM}/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
check "dry-run lists old worktree node_modules" "WOULD-STRIP" "$OUT"
check "dry-run names old worktree" "$T/roots/old/node_modules" "$OUT"
[[ "$OUT" != *"$T/roots/young/node_modules"* ]] && ok "young worktree untouched" || bad "young worktree listed"
[[ "$OUT" != *"$T/roots/linked/node_modules"* ]] && ok "symlinked node_modules untouched" || bad "symlink listed"
[[ "$OUT" != *"$T/roots/repo-link/wt/node_modules"* ]] && ok "symlinked worktree ancestor untouched" || bad "external worktree dependency listed"
[[ -d "$T/roots/old/node_modules" ]] && ok "dry-run deletes nothing" || bad "dry-run deleted"

OUT="$(env -i HOME="$T/home" PATH="${LSOF_SHIM}/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
check "--clean without approval refuses" "Refusing to delete" "$OUT"
[[ -d "$T/roots/old/node_modules" ]] && ok "unapproved clean deletes nothing" || bad "unapproved clean deleted"

OUT="$(env -i HOME="$T/home" PATH="${LSOF_SHIM}/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" WORKTREE_APPROVED=1 DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
check "approved clean strips" "STRIPPED" "$OUT"
[[ ! -e "$T/roots/old/node_modules" ]] && ok "old node_modules removed" || bad "old node_modules remains"
[[ -d "$T/roots/young/node_modules" ]] && ok "young node_modules kept" || bad "young node_modules removed"
[[ -L "$T/roots/linked/node_modules" && -d "$T/real_nm" ]] && ok "symlink target kept" || bad "symlink target damaged"
[[ -f "$T/external_repo/wt/node_modules/x/f" ]] && ok "external worktree dependencies kept" || bad "external worktree dependencies removed"
[[ -f "$T/roots/old/.git" ]] && ok "worktree .git preserved" || bad ".git removed"

# AO config worktreeDir: worktrees under a configured AO dir are never stripped.
printf 'projects:\n  demo:\n    worktreeDir: %s\n' "$T/roots" > "$T/ao.yaml"
mkdir -p "$T/roots/old/node_modules/y"; echo d > "$T/roots/old/node_modules/y/f"
/usr/bin/find "$T/roots/old" -exec touch -h -t "$(old_ts)" {} +
OUT="$(env -i HOME="$T/home" PATH="${LSOF_SHIM}/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_AO_CONFIG="$T/ao.yaml" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
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
/usr/bin/find "$T/roots/demo/wt1" "$T/roots/other_repo/wt_old" "$T/roots/other_repo/wt_linked_packages" -exec touch -h -t "$(old_ts)" {} + 2>/dev/null
OUT="$(env -i HOME="$T/home" PATH="${LSOF_SHIM}/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" WORKTREE_APPROVED=1 DISK_MAGICIAN_AO_CONFIG="$T/ao_top.yaml" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
[[ "$OUT" != *"$T/roots/old/node_modules"* ]] && ok "direct child of top-level AO worktreeDir protected" || bad "direct child of top-level AO worktreeDir stripped"
[[ "$OUT" != *"$T/roots/demo/wt1/node_modules"* && -d "$T/roots/demo/wt1/node_modules" ]] && ok "AO project worktree under top-level worktreeDir protected" || bad "AO project worktree stripped"
check "non-AO repo worktree under top-level worktreeDir stripped" "$T/roots/other_repo/wt_old/packages/pkg-a/node_modules" "$OUT"
[[ ! -e "$T/roots/other_repo/wt_old/packages/pkg-a/node_modules" ]] && ok "monorepo packages/*/node_modules removed" || bad "monorepo packages/*/node_modules remains"
[[ "$OUT" != *"$T/roots/other_repo/wt_old/packages/pkg-link/node_modules"* && -f "$T/external/pkg/node_modules/m/f" ]] && ok "symlinked package ancestor protected" || bad "symlinked package ancestor traversed"
[[ "$OUT" != *"$T/roots/other_repo/wt_linked_packages/packages/pkg/node_modules"* && -f "$T/external/pkg/node_modules/m/f" ]] && ok "symlinked packages ancestor protected" || bad "symlinked packages ancestor traversed"
[[ ! -e "$T/roots/other_repo/wt_linked_packages/node_modules" ]] && ok "linked-packages worktree still strips regular root dependencies" || bad "linked-packages worktree not processed"

# safety_gate: a never_delete rule protects the directory.
mkdir -p "$T/cfg"; printf '{"never_delete": ["%s/roots/old/node_modules"]}' "$T" > "$T/cfg/safety.local.json"
OUT="$(env -i HOME="$T/home" PATH="${LSOF_SHIM}/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_SAFETY_FILE="$T/cfg/safety.local.json" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
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
/usr/bin/find "$T/roots/nested" -exec touch -h -t "$(old_ts)" {} + 2>/dev/null
OUT="$(env -i HOME="$T/home" PATH="${LSOF_SHIM}/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
check "nested daemon/target (Cargo.toml sibling) listed" "$T/roots/nested/daemon/target" "$OUT"
check "nested node_modules (package.json sibling) listed" "$T/roots/nested/app/node_modules" "$OUT"
[[ "$OUT" != *"$T/roots/nested/not_build/target"* ]] && ok "nested target without a Cargo.toml sibling preserved" || bad "manifest-less nested target listed"
check "root target with Cargo.toml still listed" "$T/roots/nested/target" "$OUT"
[[ "$OUT" != *"linked_daemon"* && "$OUT" != *"$T/external_daemon/target"* ]] && ok "symlinked nested parent not traversed" || bad "symlinked nested parent traversed"
OUT="$(env -i HOME="$T/home" PATH="${LSOF_SHIM}/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" WORKTREE_APPROVED=1 DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
[[ ! -e "$T/roots/nested/daemon/target" && -f "$T/roots/nested/daemon/Cargo.toml" ]] && ok "nested daemon/target removed, manifest kept" || bad "nested daemon/target not removed"
[[ ! -e "$T/roots/nested/app/node_modules" && -f "$T/roots/nested/app/package.json" ]] && ok "nested node_modules removed, package.json kept" || bad "nested node_modules not removed"
[[ -f "$T/roots/nested/not_build/target/debug/app" ]] && ok "manifest-less nested target survives --clean" || bad "manifest-less nested target removed"
[[ ! -e "$T/roots/nested/target" && -f "$T/roots/nested/Cargo.toml" ]] && ok "root target removed beside its Cargo.toml" || bad "root target not removed"
[[ -f "$T/external_daemon/target/debug/app" ]] && ok "external symlink target survives --clean" || bad "external symlink target damaged"

# ---- DISK_MAGICIAN_DEPS_IDLE_MINUTES: guarded short-idle override --------------
ENVBASE=(env -i HOME="$T/home" PATH="${LSOF_SHIM}/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin")
G=(git -c user.email=t@t -c user.name=t)
git init -q --bare "$T/origin.git"
git init -q "$T/ibase"; printf 'node_modules/\nios/Pods/\nios/build/\nbuild/\n.venv/\n.next/\n__pycache__/\n.env*\n' > "$T/ibase/.gitignore"
echo src > "$T/ibase/src.txt"; git -C "$T/ibase" add .; "${G[@]}" -C "$T/ibase" commit -q -m init
git -C "$T/ibase" remote add origin "$T/origin.git"; git -C "$T/ibase" push -q origin HEAD:refs/heads/main; git -C "$T/ibase" fetch -q origin
mkdir -p "$T/iroots" "$T/real_nm2"; echo keep > "$T/real_nm2/f"
for n in ok dirty unpushed live tracked symlinked secret fresh locked; do
  git -C "$T/ibase" worktree add -q -b "i-$n" "$T/iroots/$n"
  mkdir -p "$T/iroots/$n/node_modules/x" "$T/iroots/$n/ios/Pods/p" "$T/iroots/$n/ios/build" "$T/iroots/$n/build"
  echo d > "$T/iroots/$n/node_modules/x/f"; echo d > "$T/iroots/$n/ios/Pods/p/f"; echo d > "$T/iroots/$n/ios/build/f"; echo d > "$T/iroots/$n/build/f"
  echo SECRET > "$T/iroots/$n/.env.local"
done
mkdir -p "$T/iroots/ok/.venv/lib" "$T/iroots/ok/.next/c" "$T/iroots/ok/pkg/__pycache__"
echo d > "$T/iroots/ok/.venv/lib/f"; echo d > "$T/iroots/ok/.next/c/f"; echo d > "$T/iroots/ok/pkg/__pycache__/m.pyc"
echo new > "$T/iroots/dirty/new.txt"
echo more > "$T/iroots/unpushed/more.txt"; git -C "$T/iroots/unpushed" add -f more.txt; "${G[@]}" -C "$T/iroots/unpushed" commit -q -m local
rm -rf "$T/iroots/tracked/build"; mkdir -p "$T/iroots/tracked/build"; echo t > "$T/iroots/tracked/build/keep.txt"
git -C "$T/iroots/tracked" add -f build/keep.txt; "${G[@]}" -C "$T/iroots/tracked" commit -q -m trackbuild; git -C "$T/iroots/tracked" push -q origin HEAD:refs/heads/tracked-b
rm -rf "$T/iroots/symlinked/node_modules"; ln -s "$T/real_nm2" "$T/iroots/symlinked/node_modules"
mkdir -p "$T/iroots/secret/node_modules/pkg"; echo SECRET > "$T/iroots/secret/node_modules/pkg/.env"
git -C "$T/ibase" worktree lock "$T/iroots/locked"
/usr/bin/find "$T/iroots" -mindepth 1 -not -path '*/fresh*' -not -path '*/.git' -not -path '*/.git/*' -exec touch -h -t "$(hours_ts 3)" {} + 2>/dev/null
(cd "$T/iroots/live" && exec sleep 300) & LIVE_PID=$!
sleep 1
irun() { "${ENVBASE[@]}" "$@" DISK_MAGICIAN_WORKTREE_ROOTS="$T/iroots" bash "$SCRIPT" ${MODE:---dry-run} 2>&1; }
OUT="$(irun)"
[[ "$OUT" != *"WOULD-STRIP"* ]] && ok "override unset: 3h-idle clean pushed worktree kept" || bad "override unset stripped"
OUT="$(irun DISK_MAGICIAN_DEPS_IDLE_MINUTES=30)"
[[ "$OUT" != *"WOULD-STRIP"* ]] && ok "override=30 (<60) ignored" || bad "override=30 honored"
OUT="$(irun DISK_MAGICIAN_DEPS_IDLE_MINUTES=abc)"
[[ "$OUT" != *"WOULD-STRIP"* ]] && ok "override non-numeric ignored" || bad "override=abc honored"
OUT="$(irun DISK_MAGICIAN_DEPS_IDLE_MINUTES=120)"
for d in node_modules ios/Pods ios/build build .venv .next pkg/__pycache__; do check "override=120 lists ok/$d" "$T/iroots/ok/$d" "$OUT"; done
[[ "$OUT" != *"$T/iroots/symlinked/node_modules"* ]] && ok "symlinked node_modules not listed" || bad "symlinked node_modules listed"
for w in dirty unpushed live fresh locked; do [[ "$OUT" != *"$T/iroots/$w/"* ]] && ok "override=120 skips $w worktree" || bad "override=120 listed $w"; done
check "tracked worktree node_modules listed" "$T/iroots/tracked/node_modules" "$OUT"
[[ "$OUT" != *"WOULD-STRIP"*"$T/iroots/tracked/build"* ]] && ok "tracked build/ never listed" || bad "tracked build/ listed"
check "secret-bearing dir reported" "SECRET-SKIP $T/iroots/secret/node_modules" "$OUT"
[[ "$OUT" != *"WOULD-STRIP"*"$T/iroots/secret/node_modules"* ]] && ok "secret-bearing dir not stripped" || bad "secret dir listed"
[[ -d "$T/iroots/ok/node_modules" ]] && ok "override dry-run deletes nothing" || bad "override dry-run deleted"
OUT="$(MODE=--clean irun WORKTREE_APPROVED=1 DISK_MAGICIAN_DEPS_IDLE_MINUTES=120)"
for d in node_modules ios/Pods ios/build build .venv .next pkg/__pycache__; do [[ ! -e "$T/iroots/ok/$d" ]] && ok "clean removed ok/$d" || bad "ok/$d remains"; done
[[ -f "$T/iroots/ok/.env.local" && -f "$T/iroots/ok/src.txt" && -f "$T/iroots/ok/.git" ]] && ok ".env.local, tracked files, .git preserved" || bad "env/tracked/.git damaged"
[[ -f "$T/iroots/tracked/build/keep.txt" ]] && ok "tracked build/keep.txt kept" || bad "tracked build removed"
[[ -L "$T/iroots/symlinked/node_modules" && -f "$T/real_nm2/f" ]] && ok "symlinked node_modules not followed" || bad "symlink followed"
[[ -f "$T/iroots/secret/node_modules/pkg/.env" ]] && ok "secret-bearing node_modules kept" || bad "secret node_modules removed"
for w in dirty unpushed live fresh locked; do [[ -d "$T/iroots/$w/node_modules" ]] && ok "$w node_modules kept after clean" || bad "$w node_modules removed"; done
kill "$LIVE_PID" 2>/dev/null || true

echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]
