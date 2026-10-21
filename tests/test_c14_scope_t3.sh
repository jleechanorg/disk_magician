#!/usr/bin/env bash
# test_c14_scope_t3.sh — focused C14 scope fixes (bead disk_magician-cuea.12):
#
#   (1) Protected-root anchoring. A configured protected basename
#       (worldarchitect.ai, worldai_claw, wa-missions) is protected ONLY as a
#       top-level entry of a real scratch root and its descendants. A same-named
#       path component elsewhere — ~/.worktrees/worldarchitect.ai/foo or an
#       archive copy — is NOT automatically "kept:protected"; it reaches the
#       ordinary C14 checks.
#   (2) T3 owner-null transport. cleanup_worktrees.sh's sanctioned 3-day path
#       passes --t3-owner-null so C14 may free EXACTLY the candidate
#       worktree's own owner-null lease after every other check. Default C14
#       (no flag), T1, live/unknown/malformed owners, and ancestor/descendant
#       null leases all still keep.
#
# Real fixture Git repositories and real owner-null lease files; the actual
# artifact_removal_verdict is exercised, never a stub. Every fixture lives
# under /tmp HOME/state; ambient Git/test env is unset. No secret/.env read.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/scripts/lib/artifact_verdict.sh"
PROBE="$ROOT/scripts/c14_probe.py"

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi
}
assert_ne() {
    if [[ "$1" != "$2" ]]; then ok "$3 (got '$1', not '$2')"; else bad "$3 — unexpectedly '$2'"; fi
}

# Explicit, validated /tmp allocation.
TMP="$(mktemp -d /tmp/dm-c14-scope-t3.XXXXXX)" || { echo "FATAL: no /tmp fixture root" >&2; exit 2; }
[[ -d "$TMP" && ( "$TMP" == /tmp/dm-c14-scope-t3.* || "$TMP" == /private/tmp/dm-c14-scope-t3.* ) ]] || {
    echo "FATAL: fixture root not under /tmp: '$TMP'" >&2; exit 2;
}
TMP="$(cd "$TMP" && pwd -P)" || exit 2
cleanup() {
    case "$TMP" in /tmp/dm-c14-scope-t3.*|/private/tmp/dm-c14-scope-t3.*)
        chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP" ;;
    esac
}
trap cleanup EXIT

export HOME="$TMP/home"; mkdir -p "$HOME"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
PT="$TMP/ptmp"; mkdir -p "$PT"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PT" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$PT"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMP/utmp"; mkdir -p "$TMP/utmp"
mkdir -p "$TMP/remotes"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=c14-t3 GIT_AUTHOR_EMAIL=c14-t3@invalid
export GIT_COMMITTER_NAME=c14-t3 GIT_COMMITTER_EMAIL=c14-t3@invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CEILING_DIRECTORIES \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR GIT_EXEC_PATH \
    C14_INVENTORY_OUT C14_INVENTORY_FILE DISK_MAGICIAN_C14_LEDGER DISK_MAGICIAN_PROTECTED_TMP_ROOTS \
    DISK_MAGICIAN_LIFECYCLE_PARENT_PID DISK_MAGICIAN_ARCHIVE_ROOT 2>/dev/null || true

if [[ ! -f "$LIB" ]]; then echo "FATAL: $LIB missing" >&2; exit 2; fi
# shellcheck source=scripts/lib/artifact_verdict.sh
source "$LIB"

NOW="$(date +%s)"
age() { # BSD `date -r EPOCH`, GNU `date -d @EPOCH` fallback
    local ts; ts="$(date -r $((NOW - $2 * 60)) +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$((NOW - $2 * 60))" +%Y%m%d%H%M.%S)"
    find "$1" -exec touch -h -t "$ts" {} + 2>/dev/null
}

make_remote() { # <name>
    git init -q --bare -b main "$TMP/remotes/$1.git" || return 1
    mkdir -p "$TMP/seed-$1"
    git -C "$TMP/seed-$1" init -q -b main || return 1
    printf 'tracked\n' >"$TMP/seed-$1/tracked.txt"
    git -C "$TMP/seed-$1" add -A && git -C "$TMP/seed-$1" commit -qm init || return 1
    git -C "$TMP/seed-$1" push -q "$TMP/remotes/$1.git" main || return 1
}
released_clone() { # <dest> <remote>: clean clone with a released baseline lease.
    git clone -q "$TMP/remotes/$2.git" "$1" || return 1
    local f gd; f="$(lease_path_for "$1")"; mkdir -p "${f%/*}"
    gd="$(git -C "$1" rev-parse --absolute-git-dir)"
    printf '{"path":"%s","owner":{"pid":1},"released_at":1,"git_meta":%s}\n' \
        "$1" "$(python3 "$PROBE" gitmeta "$gd")" >"$f"
}
null_lease() { # <path>: a real lease file whose owner is null.
    local f; f="$(lease_path_for "$1")"; mkdir -p "${f%/*}"
    printf '{"path":"%s","owner":null}\n' "$1" >"$f"
}
verdict() { artifact_removal_verdict "$@"; }
verdict_t3() { # T3 transport: only cleanup_worktrees.sh's sanctioned call sets this.
    local p="$1"; shift
    artifact_removal_verdict "$p" --t3-owner-null "$@"
}

make_remote base || { echo "FATAL: git fixture setup failed" >&2; exit 2; }
git clone -q "$TMP/remotes/base.git" "$TMP/base" || exit 2
wt_add() { # <dest> <branch>
    git -C "$TMP/base" worktree add -q "$1" -b "$2" origin/main || return 1
    git -C "$1" push -q -u origin "$2" || return 1
}

echo "== (1) protected-root anchoring =="
# A real protected root and a descendant are protected.
mkdir -p "$PT/worldarchitect.ai"
released_clone "$PT/worldarchitect.ai/repo" base && age "$PT/worldarchitect.ai/repo" 50000
assert_eq "$(verdict "$PT/worldarchitect.ai/repo" --kind ephemeral)" kept:protected \
    "configured protected root under a scratch root is protected"
mkdir -p "$PT/worldarchitect.ai/repo/nested"
assert_eq "$(verdict "$PT/worldarchitect.ai/repo/nested" --kind ephemeral)" kept:protected \
    "descendant of a protected root is protected"

# A scratch-root symlink (alias) resolves to the same protection.
ln -s "$PT" "$TMP/alias"
assert_eq "$(verdict "$TMP/alias/worldarchitect.ai/repo" --kind ephemeral)" kept:protected \
    "alias/symlinked scratch root resolves to the protected root"

# A same-named component elsewhere is NOT protected: it reaches the ordinary
# checks. ~/.worktrees/worldarchitect.ai/foo is an otherwise-removable clean
# pushed clone, so "not protected" is proven by an actual remove.
mkdir -p "$HOME/.worktrees/worldarchitect.ai"
released_clone "$HOME/.worktrees/worldarchitect.ai/foo" base && age "$HOME/.worktrees/worldarchitect.ai/foo" 50000
assert_ne "$(verdict "$HOME/.worktrees/worldarchitect.ai/foo" --kind ephemeral)" kept:protected \
    "same-named repo outside a scratch root is not auto-protected"
assert_eq "$(verdict "$HOME/.worktrees/worldarchitect.ai/foo")" remove \
    "same-named repo outside a scratch root reaches full C14 and is removable"

# An archived copy under a scratch root is not protected either; it reaches the
# declared-ephemeral rules and is kept there for want of provenance.
mkdir -p "$PT/_disk_magician_archive/20200101T000000Z/worldarchitect.ai"
printf 'archived\n' >"$PT/_disk_magician_archive/20200101T000000Z/worldarchitect.ai/foo"
age "$PT/_disk_magician_archive/20200101T000000Z/worldarchitect.ai/foo" 50000
assert_eq "$(verdict "$PT/_disk_magician_archive/20200101T000000Z/worldarchitect.ai/foo" --kind ephemeral)" kept:unproven-content \
    "archived worldarchitect.ai copy is not protected; ordinary checks keep it"

# Other defaults and a custom configured basename.
mkdir -p "$PT/wa-missions/x" && age "$PT/wa-missions/x" 50000
assert_eq "$(verdict "$PT/wa-missions/x" --kind ephemeral)" kept:protected "default wa-missions root is protected"
released_clone "$PT/custom-root/br" base && age "$PT/custom-root" 50000
assert_eq "$(DISK_MAGICIAN_PROTECTED_TMP_ROOTS='custom-root' verdict "$PT/custom-root/br" --kind ephemeral)" kept:protected \
    "env-configured protected basename is protected"
assert_eq "$(verdict "$PT/custom-root/br" --kind ephemeral)" remove \
    "unlisted basename at the same location is not protected"

echo "== (2) T3 owner-null transport =="
# Candidate worktree with its OWN owner-null lease: default C14 keeps, T3 frees.
wt_add "$PT/parent-own/wt" wtown || { echo "FATAL: worktree add failed" >&2; exit 2; }
null_lease "$PT/parent-own/wt"
age "$PT/parent-own/wt" 120
assert_eq "$(verdict "$PT/parent-own/wt")" remove \
    "default C14 frees an owner-null linked worktree (2026-10-20 relax)"
assert_eq "$(verdict_t3 "$PT/parent-own/wt")" remove \
    "T3 frees the exact candidate worktree's own owner-null lease"
# 2026-10-20 relax guards: idle floor is max(caller floor, 60 min); AO paths and an
# unreadable AO config fail closed; unpushed/dirty keep.
assert_eq "$(verdict "$PT/parent-own/wt" --min-idle-minutes 300)" kept:recent-activity \
    "owner-null relax honors a caller idle floor above the tree's idle time"
assert_eq "$(verdict "$PT/parent-own/wt" --min-idle-minutes 5)" remove \
    "owner-null relax with a sub-60 caller floor still frees a 120-minute-idle tree"
age "$PT/parent-own/wt" 45
assert_eq "$(verdict "$PT/parent-own/wt" --min-idle-minutes 5)" kept:recent-activity \
    "owner-null relax never goes below the 60-minute floor (45 min idle kept)"
age "$PT/parent-own/wt" 120
git -C "$PT/parent-own/wt" commit -q --allow-empty -m unpushed && age "$PT/parent-own/wt" 120
assert_eq "$(verdict "$PT/parent-own/wt")" kept:not-pushed "owner-null relax keeps an unpushed worktree"
git -C "$PT/parent-own/wt" push -q origin wtown && age "$PT/parent-own/wt" 120
printf 'u\n' >"$PT/parent-own/wt/untracked.txt" && age "$PT/parent-own/wt" 120
assert_eq "$(verdict "$PT/parent-own/wt")" kept:dirty "owner-null relax keeps a dirty worktree"
rm -f "$PT/parent-own/wt/untracked.txt"; age "$PT/parent-own/wt" 120
printf 'worktreeDir: [unterminated\n' >"$TMP/ao-bad.yaml"
assert_eq "$(DISK_MAGICIAN_AO_CONFIG="$TMP/ao-bad.yaml" verdict "$PT/parent-own/wt")" kept:ao-config-unreadable \
    "AO config present but unparseable: owner-null relax fails closed"
assert_eq "$(DISK_MAGICIAN_AO_CONFIG="$TMP/ao-missing.yaml" verdict "$PT/parent-own/wt")" kept:ao-config-unreadable \
    "AO config explicitly named but unreadable: owner-null relax fails closed"
mkdir -p "$PT/aodir"
printf 'projects:\n  proj:\n    path: /nonexistent/proj\n    worktreeDir: "%s/aodir"\n' "$PT" >"$TMP/ao-ok.yaml"
wt_add "$PT/aodir/aowt" aowt || { echo "FATAL: ao worktree add failed" >&2; exit 2; }
null_lease "$PT/aodir/aowt"; age "$PT/aodir/aowt" 120
assert_eq "$(DISK_MAGICIAN_AO_CONFIG="$TMP/ao-ok.yaml" verdict "$PT/aodir/aowt")" kept:ao-owned \
    "worktree under a configured AO worktreeDir stays protected from the owner-null relax"
assert_eq "$(DISK_MAGICIAN_AO_CONFIG="$TMP/ao-ok.yaml" verdict "$PT/parent-own/wt")" remove \
    "worktree outside the configured AO dir is still freed"
# Consume the actual inventory through WRH; a verdict alone cannot prove removal.
t3_inv="$TMP/t3-inventory.json"
assert_eq "$(verdict_t3 "$PT/parent-own/wt" --inventory-out "$t3_inv")" remove "T3 publishes the removal inventory"
if wrh_remove_now "$PT/parent-own/wt" "$PT/parent-own/wt" --quarantine "$t3_inv" && [[ ! -e "$PT/parent-own/wt" ]]; then
    ok "WRH removes the exact T3 worktree using its C14 inventory"
else
    bad "WRH failed to consume the T3 inventory"
fi

# An ANCESTOR null lease is never accepted, even under T3.
mkdir -p "$PT/parent-anc"
wt_add "$PT/parent-anc/wt" wtanc || exit 2
null_lease "$PT/parent-anc"
age "$PT/parent-anc/wt" 120
assert_eq "$(verdict_t3 "$PT/parent-anc/wt")" kept:owner-unknown \
    "ancestor null lease still keeps under T3"

# A DESCENDANT null lease is never accepted, even under T3.
wt_add "$PT/parent-desc/wt" wtdesc || exit 2
mkdir -p "$PT/parent-desc/wt/sub"
null_lease "$PT/parent-desc/wt/sub"
age "$PT/parent-desc/wt" 120
assert_eq "$(verdict_t3 "$PT/parent-desc/wt")" kept:owner-unknown \
    "descendant null lease still keeps under T3"

# Live and malformed owners stay kept even under T3.
wt_add "$PT/parent-live/wt" wtlive || exit 2
f="$(lease_path_for "$PT/parent-live/wt")"; mkdir -p "${f%/*}"
printf '{"path":"%s","owner":{"pid":%d,"start_epoch":%s,"comm":"%s"},"created_epoch":%d,"ttl_hours":24}\n' \
    "$PT/parent-live/wt" $$ "$(_lease_ps_lstart_epoch $$)" "$(_lease_full_comm $$)" "$NOW" >"$f"
age "$PT/parent-live/wt" 120
assert_eq "$(verdict_t3 "$PT/parent-live/wt")" kept:live-owner "live owner still keeps under T3"

wt_add "$PT/parent-mal/wt" wtmal || exit 2
f="$(lease_path_for "$PT/parent-mal/wt")"; mkdir -p "${f%/*}"
printf '{"path":"%s","owner":5}\n' "$PT/parent-mal/wt" >"$f"
age "$PT/parent-mal/wt" 120
assert_eq "$(verdict_t3 "$PT/parent-mal/wt")" kept:owner-unknown "malformed owner still keeps under T3"

# Every other C14 check still applies under T3: an owner-null worktree with an
# unpushed commit must stay kept.
wt_add "$PT/parent-dirty/wt" wtdirty || exit 2
printf 'unpushed\n' >>"$PT/parent-dirty/wt/tracked.txt"
null_lease "$PT/parent-dirty/wt"
age "$PT/parent-dirty/wt" 120
assert_eq "$(verdict_t3 "$PT/parent-dirty/wt")" kept:dirty "T3 does not bypass content checks (dirty tracked change)"

# T1-style (non-T3) behaviour is unchanged: no flag, no free.
wt_add "$PT/parent-t1/wt" wtt1 || exit 2
null_lease "$PT/parent-t1/wt"
age "$PT/parent-t1/wt" 120
assert_eq "$(verdict "$PT/parent-t1/wt")" remove "no-flag C14 frees owner-null linked worktree (2026-10-20 relax)"

echo "== (3) owner-unknown relaxed for clean pushed linked worktrees (2026-10-20 operator decision) =="
# No --t3-owner-null flag anywhere below: the default verdict must free a
# clean, pushed, idle, non-AO linked worktree whose lease has no owner.
wt_add "$PT/rx-null/wt" rxnull || exit 2
null_lease "$PT/rx-null/wt"; age "$PT/rx-null/wt" 120
assert_eq "$(verdict "$PT/rx-null/wt")" remove "relax: clean+pushed worktree with owner-null lease -> remove"

wt_add "$PT/rx-nolease/wt" rxnolease || exit 2
age "$PT/rx-nolease/wt" 120
assert_eq "$(verdict "$PT/rx-nolease/wt")" remove "relax: clean+pushed worktree with no lease -> remove"

wt_add "$PT/rx-cwd/wt" rxcwd || exit 2
null_lease "$PT/rx-cwd/wt"; age "$PT/rx-cwd/wt" 120
( cd "$PT/rx-cwd/wt" && exec sleep 120 ) & rx_pid=$!
sleep 1
rx_v="$(verdict "$PT/rx-cwd/wt")"
kill "$rx_pid" 2>/dev/null; wait "$rx_pid" 2>/dev/null
[[ "$rx_v" == kept:* ]] && ok "relax: live cwd inside worktree is still kept ($rx_v)" || bad "relax: live cwd verdict not kept:* ($rx_v)"

wt_add "$PT/rx-live/wt" rxlive || exit 2
f="$(lease_path_for "$PT/rx-live/wt")"; mkdir -p "${f%/*}"
printf '{"path":"%s","owner":{"pid":%d,"start_epoch":%s,"comm":"%s"},"created_epoch":%d,"ttl_hours":24}\n' \
    "$PT/rx-live/wt" $$ "$(_lease_ps_lstart_epoch $$)" "$(_lease_full_comm $$)" "$NOW" >"$f"
age "$PT/rx-live/wt" 120
assert_eq "$(verdict "$PT/rx-live/wt")" kept:live-owner "relax: live-owner lease still keeps"

wt_add "$PT/rx-dirty/wt" rxdirty || exit 2
printf 'edit\n' >>"$PT/rx-dirty/wt/tracked.txt"; null_lease "$PT/rx-dirty/wt"; age "$PT/rx-dirty/wt" 120
assert_eq "$(verdict "$PT/rx-dirty/wt")" kept:dirty "relax: dirty worktree still keeps"

wt_add "$PT/rx-sec/wt" rxsec || exit 2
printf 'x\n' >"$PT/rx-sec/wt/deploy.pem"
git -C "$PT/rx-sec/wt" add deploy.pem && git -C "$PT/rx-sec/wt" commit -qm sec && git -C "$PT/rx-sec/wt" push -q origin rxsec
null_lease "$PT/rx-sec/wt"; age "$PT/rx-sec/wt" 120
assert_eq "$(verdict "$PT/rx-sec/wt")" kept:secret-like "relax: secret-like file still keeps"

wt_add "$PT/rx-unp/wt" rxunp || exit 2
printf 'u\n' >"$PT/rx-unp/wt/new.txt"
git -C "$PT/rx-unp/wt" add new.txt && git -C "$PT/rx-unp/wt" commit -qm unpushed
null_lease "$PT/rx-unp/wt"; age "$PT/rx-unp/wt" 120
rx_v="$(verdict "$PT/rx-unp/wt")"
[[ "$rx_v" == kept:* ]] && ok "relax: unpushed commit still keeps ($rx_v)" || bad "relax: unpushed commit not kept ($rx_v)"

wt_add "$PT/.ao/data/worktrees/rx-ao/wt" rxao || exit 2
null_lease "$PT/.ao/data/worktrees/rx-ao/wt"; age "$PT/.ao/data/worktrees/rx-ao/wt" 120
rx_v="$(verdict "$PT/.ao/data/worktrees/rx-ao/wt")"
[[ "$rx_v" == kept:* ]] && ok "relax: AO-owned worktree still keeps ($rx_v)" || bad "relax: AO-owned not kept ($rx_v)"

# Wiring: the flag is carried by the sanctioned T3 call site, and by exactly
# that one call site in production scripts (no global/other removal site can
# authorize an owner-null removal).
if grep -qF -- '--t3-owner-null' "$ROOT/scripts/cleanup_worktrees.sh"; then
    ok "cleanup_worktrees.sh T3 call site passes --t3-owner-null"
else
    bad "cleanup_worktrees.sh T3 call site does not pass --t3-owner-null"
fi
site_count="$(grep -rEl 'artifact_removal_verdict[^|]*--t3-owner-null' "$ROOT/scripts" --include='*.sh' | wc -l | tr -d ' ')"
if [[ "$site_count" == "1" ]] && grep -qE 'artifact_removal_verdict[^|]*--t3-owner-null' "$ROOT/scripts/cleanup_worktrees.sh"; then
    ok "--t3-owner-null is passed by exactly one production call site (cleanup_worktrees.sh)"
else
    bad "--t3-owner-null call sites: expected cleanup_worktrees.sh only, found $site_count"
fi

echo ""
echo "===================================="
echo "Results: $PASS passed, $FAIL failed"
echo "===================================="
[[ "$FAIL" -eq 0 ]]
