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
# old: every file 10 days old; young: left fresh; linked: old but node_modules is a symlink
/usr/bin/find "$T/roots/old" "$T/roots/linked" -exec touch -h -t "$(date -v-10d +%Y%m%d%H%M)" {} + 2>/dev/null
mkdir -p "$T/home"

OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
check "dry-run lists old worktree node_modules" "WOULD-STRIP" "$OUT"
check "dry-run names old worktree" "$T/roots/old/node_modules" "$OUT"
[[ "$OUT" != *"$T/roots/young/node_modules"* ]] && ok "young worktree untouched" || bad "young worktree listed"
[[ "$OUT" != *"$T/roots/linked/node_modules"* ]] && ok "symlinked node_modules untouched" || bad "symlink listed"
[[ -d "$T/roots/old/node_modules" ]] && ok "dry-run deletes nothing" || bad "dry-run deleted"

OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
check "--clean without approval refuses" "Refusing to delete" "$OUT"
[[ -d "$T/roots/old/node_modules" ]] && ok "unapproved clean deletes nothing" || bad "unapproved clean deleted"

OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" WORKTREE_APPROVED=1 DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --clean 2>&1)"
check "approved clean strips" "STRIPPED" "$OUT"
[[ ! -e "$T/roots/old/node_modules" ]] && ok "old node_modules removed" || bad "old node_modules remains"
[[ -d "$T/roots/young/node_modules" ]] && ok "young node_modules kept" || bad "young node_modules removed"
[[ -L "$T/roots/linked/node_modules" && -d "$T/real_nm" ]] && ok "symlink target kept" || bad "symlink target damaged"
[[ -f "$T/roots/old/.git" ]] && ok "worktree .git preserved" || bad ".git removed"

# AO config worktreeDir: worktrees under a configured AO dir are never stripped.
printf 'projects:\n  demo:\n    worktreeDir: %s\n' "$T/roots" > "$T/ao.yaml"
mkdir -p "$T/roots/old/node_modules/y"; echo d > "$T/roots/old/node_modules/y/f"
/usr/bin/find "$T/roots/old" -exec touch -h -t "$(date -v-10d +%Y%m%d%H%M)" {} +
OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_AO_CONFIG="$T/ao.yaml" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
[[ "$OUT" != *"WOULD-STRIP"* ]] && ok "AO config worktreeDir worktree untouched" || bad "AO-owned worktree listed"

# safety_gate: a never_delete rule protects the directory.
mkdir -p "$T/cfg"; printf '{"never_delete": ["%s/roots/old/node_modules"]}' "$T" > "$T/cfg/safety.local.json"
OUT="$(env -i HOME="$T/home" PATH="/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin" DISK_MAGICIAN_SAFETY_FILE="$T/cfg/safety.local.json" DISK_MAGICIAN_WORKTREE_ROOTS="$T/roots" bash "$SCRIPT" --dry-run 2>&1)"
check "never_delete rule blocks the strip" "SAFETY-SKIP" "$OUT"

echo; echo "Results: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]
