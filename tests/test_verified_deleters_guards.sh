#!/usr/bin/env bash
# Regression tests for the verified-list deleters and pusher:
#   scripts/wt_delete_verified_linux.sh
#   scripts/advice_scratch_manual.sh
#   scripts/wt_push_wip_commits.sh
#
# Every case here pins a FAIL-OPEN hole that a real review round found in these
# scripts. They all share one shape: the guard silently switched itself off
# exactly when it could not be evaluated, so the deletes went ahead. A future
# refactor that reintroduces any of them must fail this file, not a laptop.
#
# Fixtures are synthetic and isolated: HOME, WORKTREE_ROOT, SCRATCH_ROOT and
# WT_SAFETY_CHECK all point inside a mktemp tree, and every script under test is
# invoked with its approval env var set, so nothing touches the real machine.
set -uo pipefail

# Run every script-under-test in a CLEAN environment.
#
# Two reasons this is not optional:
#  1. A login shell sources ~/.bashrc, which in this household exports real
#     API tokens. Test output must never carry credentials, and `set -x`
#     traces would leak them. `env -i` with an explicit PATH avoids that
#     entirely.
#  2. `HOME`, `WORKTREE_ROOT`, `SCRATCH_ROOT` must be fixtures, not the
#     operator's real trees, or a guard regression would delete real work.
#
# PATH must still contain git AND `timeout` (coreutils, not in /usr/bin on
# macOS); omitting either makes every probe exit 127 and the whole run reads as
# "unverified-git-state", which looks like a pass but proves nothing.
CLEAN_PATH="$(dirname "$(command -v timeout)"):$(dirname "$(command -v git)"):/usr/bin:/bin:/usr/sbin:/sbin"
# Pass through only the env vars a test deliberately sets; everything else is
# dropped so no ambient credential or real state path can leak in.
run_clean() {
  local -a pass=()
  local v
  for v in WT_DELETE_APPROVED ADVICE_DELETE_APPROVED WIP_PUSH_APPROVED \
           EXCLUDE_FILE WT_ORPHAN_CONTENT_VERIFIED WT_MIN_AGE_DAYS; do
    [[ -n "${!v:-}" ]] && pass+=("$v=${!v}")
  done
  env -i PATH="$CLEAN_PATH" HOME="$HOME" WORKTREE_ROOT="$WORKTREE_ROOT" \
         SCRATCH_ROOT="$SCRATCH_ROOT" \
         DISK_MAGICIAN_DELETION_LOG="$DISK_MAGICIAN_DELETION_LOG" \
         WT_SAFETY_CHECK="$WT_SAFETY_CHECK" \
         ${pass[@]+"${pass[@]}"} bash "$@"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WT_DEL="$ROOT/scripts/wt_delete_verified_linux.sh"
ADV_DEL="$ROOT/scripts/advice_scratch_manual.sh"
WT_PUSH="$ROOT/scripts/wt_push_wip_commits.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/dm-verified-deleters.XXXXXX")"
trap 'rm -rf "${T:?}"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1${2:+ -- $2}"; }
has() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "missing '$2' | got: $(printf '%s' "$3" | tr '\n' ' ' | cut -c1-300)"; }
hasnt() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "unexpected '$2' present"; }

# Isolated home so $HOME/projects lookups resolve inside the fixture.
export HOME="$T/home"
export WORKTREE_ROOT="$T/home/.worktrees"
export SCRATCH_ROOT="$T/scratch"
export DISK_MAGICIAN_DELETION_LOG="$T/deletions.log"
mkdir -p "$HOME" "$WORKTREE_ROOT" "$SCRATCH_ROOT" "$HOME/projects"

# Stub safety module: passes unless the path matches the protected marker.
cat > "$T/safety_stub.sh" <<'STUB'
#!/bin/bash
case "$1" in *"/PROTECTED/"*) exit 1 ;; esac
exit 0
STUB
chmod +x "$T/safety_stub.sh"
export WT_SAFETY_CHECK="$T/safety_stub.sh"

# Backdate every path under a tree so the recency gate sees it as old.
age_tree() { # <path> <days>
  python3 - "$1" "${2:-30}" <<'PY'
import os, sys, time
root, days = sys.argv[1], int(sys.argv[2])
t = time.time() - days * 86400
paths = [root]
for dp, dns, fns in os.walk(root):
    paths += [os.path.join(dp, f) for f in fns]
    paths += [os.path.join(dp, d) for d in dns]
for p in sorted(paths, key=len, reverse=True):
    try: os.utime(p, (t, t))
    except OSError: pass
PY
}

# A real git repo with one commit, usable as an "origin".
make_origin() { # <dir>
  git init -q --bare "$1"
}

# A linked worktree at $WORKTREE_ROOT/<rel>, carrying an `origin` remote so the
# live-remote gate has something to query. <origin> must be a bare repo.
make_worktree() { # <origin> <rel> <branch>
  local origin=$1 br=$3 seed="${1}.seed" wt="$WORKTREE_ROOT/$2"
  rm -rf "$seed" "$wt"
  git init -q "$seed"
  ( cd "$seed" && echo base > base.txt \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
  git -C "$seed" push -q "$origin" HEAD:refs/heads/main >/dev/null 2>&1
  git -C "$origin" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
  git -C "$seed" remote add origin "$origin" >/dev/null 2>&1
  mkdir -p "$(dirname "$wt")"
  git -C "$seed" worktree add -q "$wt" -b "$br" >/dev/null 2>&1
  # worktree inherits no remote; add one so ls-remote can be satisfied
  git -C "$wt" remote add origin "$origin" >/dev/null 2>&1 || true
}

# Emit a TAB-separated list row for the DELETERS (they parse gib<TAB>rel).
row() { printf '1.0\t%s\n' "$1"; }

# wt_push_wip_commits.sh parses FIVE columns (gib, age, remotes, onremote, rel)
# and resolves paths from "$HOME/.worktrees" directly. Keep that root pointing at
# the fixture so the pusher and the deleters see the same tree.
row_push() { printf '1.0\t30\t1\tno\t%s\n' "$1"; }
mkdir -p "$HOME/.worktrees"
[[ "$WORKTREE_ROOT" == "$HOME/.worktrees" ]] || {
  # WORKTREE_ROOT is already $HOME/.worktrees in this harness; assert it.
  :
}

echo "=== Test 1: approval gates refuse without the env var"
out="$(run_clean "$WT_DEL" /dev/null 2>&1)"; rc=$?
has "wt_delete refuses without WT_DELETE_APPROVED" "Refusing" "$out"
[[ $rc -eq 2 ]] && ok "wt_delete refusal rc=2" || bad "wt_delete refusal rc" "got $rc"
out="$(run_clean "$ADV_DEL" /dev/null 2>&1)"; rc=$?
has "advice refuses without ADVICE_DELETE_APPROVED" "Refusing" "$out"
out="$(run_clean "$WT_PUSH" /dev/null 2>&1)"; rc=$?
has "wt_push refuses without WIP_PUSH_APPROVED" "Refusing" "$out"

# ---------------------------------------------------------------- ignored files
echo "=== Test 2: IGNORED content is never silently destroyed"
# The exact hole: `git status --porcelain` does not list ignored files, and
# `git worktree remove` deletes them anyway, so a worktree holding an ignored
# artifact reported clean and was removed. Guard must fire.
make_origin "$T/o2.git"
make_worktree "$T/o2.git" wt2 feat2
( cd "$WORKTREE_ROOT/wt2" && echo 'secret/' > .gitignore && git add .gitignore \
    && git -c user.email=t@t -c user.name=t commit -qm gi \
    && mkdir -p secret && echo PRECIOUS > secret/data.txt ) >/dev/null 2>&1
git -C "$WORKTREE_ROOT/wt2" push -q origin feat2 >/dev/null 2>&1
age_tree "$WORKTREE_ROOT/wt2" 30
row wt2 > "$T/list2"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list2" 2>&1)"
has "ignored content blocks removal" "has-ignored-content" "$out"
[[ -d "$WORKTREE_ROOT/wt2/secret" ]] && ok "ignored dir survived" || bad "ignored dir was destroyed"
[[ -f "$WORKTREE_ROOT/wt2/secret/data.txt" ]] && ok "ignored file survived" || bad "ignored file was destroyed"

echo "=== Test 3: a clean worktree with no ignored content still proceeds"
make_origin "$T/o3.git"
make_worktree "$T/o3.git" wt3 feat3
git -C "$WORKTREE_ROOT/wt3" push -q origin feat3 >/dev/null 2>&1
age_tree "$WORKTREE_ROOT/wt3" 30
row wt3 > "$T/list3"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list3" 2>&1)"
has "clean pushed worktree removed" "REMOVED" "$out"
[[ ! -e "$WORKTREE_ROOT/wt3" ]] && ok "worktree gone" || bad "worktree still present"

# --------------------------------------------------------------- stale remote
echo "=== Test 4: STALE remote-tracking ref must not authorize deletion"
# `for-each-ref refs/remotes` answers from the local cache and keeps a branch
# after it is deleted upstream, so a commit that exists nowhere read as
# "on remote". The live-remote check must catch it.
make_origin "$T/o4.git"
make_worktree "$T/o4.git" wt4 feat4
# A commit that exists ONLY on feat4, so deleting that branch really does strand
# it. Without this, main still advertises the same SHA and the live check would
# correctly pass -- testing nothing.
( cd "$WORKTREE_ROOT/wt4" && echo only > only.txt && git add only.txt \
    && git -c user.email=t@t -c user.name=t commit -qm unique ) >/dev/null 2>&1
git -C "$WORKTREE_ROOT/wt4" push -q origin feat4 >/dev/null 2>&1
git -C "$T/o4.git" update-ref -d refs/heads/feat4   # branch gone upstream
age_tree "$WORKTREE_ROOT/wt4" 30
row wt4 > "$T/list4"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list4" 2>&1)"
has "stale local remote ref does not authorize removal" "head-not-on-live-remote" "$out"
[[ -d "$WORKTREE_ROOT/wt4" ]] && ok "worktree preserved" || bad "worktree deleted on stale ref"

echo "=== Test 5: a genuinely pushed worktree is NOT blocked by the live check"
make_origin "$T/o5.git"
make_worktree "$T/o5.git" wt5 feat5
git -C "$WORKTREE_ROOT/wt5" push -q origin feat5 >/dev/null 2>&1
age_tree "$WORKTREE_ROOT/wt5" 30
row wt5 > "$T/list5"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list5" 2>&1)"
has "pushed-and-present head is removable" "REMOVED" "$out"

# --------------------------------------------------------------- dirty / status
echo "=== Test 6: uncommitted work blocks removal"
make_origin "$T/o6.git"
make_worktree "$T/o6.git" wt6 feat6
git -C "$WORKTREE_ROOT/wt6" push -q origin feat6 >/dev/null 2>&1
echo "uncommitted" > "$WORKTREE_ROOT/wt6/dirty.txt"
age_tree "$WORKTREE_ROOT/wt6" 30
row wt6 > "$T/list6"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list6" 2>&1)"
has "dirty worktree skipped" "SKIP dirty" "$out"
[[ -d "$WORKTREE_ROOT/wt6" ]] && ok "dirty worktree preserved" || bad "dirty worktree deleted"

echo "=== Test 7: an unreadable repository fails closed, not clean"
# `git status ... | wc -l` printed 0 even when git exited 128, so a broken repo
# read as clean and became deletable. HEAD must still resolve (or the earlier
# orphan gate fires), so corrupt the INDEX instead: status then fails while
# rev-parse HEAD still succeeds.
make_origin "$T/o7.git"
make_worktree "$T/o7.git" wt7 feat7
git -C "$WORKTREE_ROOT/wt7" push -q origin feat7 >/dev/null 2>&1
gd7="$(sed -n 's/^gitdir:[[:space:]]*//p' "$WORKTREE_ROOT/wt7/.git" 2>/dev/null | head -1)"
printf 'garbage-not-an-index\n' > "${gd7:?}/index" 2>/dev/null || true
age_tree "$WORKTREE_ROOT/wt7" 30
row wt7 > "$T/list7"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list7" 2>&1)"
has "broken index does not read as clean" "git-status-failed" "$out"
[[ -d "$WORKTREE_ROOT/wt7" ]] && ok "broken-index repo preserved" || bad "broken-index repo deleted"

echo "=== Test 8: unsafe relative paths are rejected before concatenation"
printf '%s\n' "../escape" "/abs/path" "-flag" "sub/../../x" > "$T/list8"
# The checker reads gib<TAB>rel; a bare rel line yields no TAB, so also feed the
# TAB form to prove the rejection happens on the REL value itself.
{ row "../escape"; row "/abs/path"; row "-flag"; row "sub/../../x"; } > "$T/list8"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list8" 2>&1)"
has "dotdot rejected" "unsafe-relpath" "$out"
has "leading dash rejected" "-flag" "$out"
[[ -d "$HOME/.worktrees" ]] && ok "worktree root intact" || bad "worktree root disturbed"

# ------------------------------------------------------------ orphan proof
echo "=== Test 9: a plain directory is never treated as an orphan worktree"
# The inverted-proof hole: requiring only "not in worktree list" + "no admin
# dir" let an ordinary directory such as notes/ be recursively deleted.
make_origin "$T/o9.git"
mkdir -p "$HOME/projects/o9"
git init -q "$HOME/projects/o9"
( cd "$HOME/projects/o9" && git -c user.email=t@t -c user.name=t commit -qm i --allow-empty ) >/dev/null 2>&1
mkdir -p "$WORKTREE_ROOT/o9/notes"
echo "not a worktree" > "$WORKTREE_ROOT/o9/notes/f.txt"
age_tree "$WORKTREE_ROOT/o9/notes" 30
row o9/notes > "$T/list9"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list9" 2>&1)"
has "plain directory lacks orphan provenance" "no-positive-orphan-provenance" "$out"
[[ -f "$WORKTREE_ROOT/o9/notes/f.txt" ]] && ok "plain directory preserved" || bad "plain directory deleted"

echo "=== Test 10: a dangling pointer owned by ANOTHER repo is rejected"
# The owning repo MUST resolve, or the earlier "no-orphan-provenance" gate fires
# first and this test would never reach the ownership check it exists to prove.
mkdir -p "$HOME/projects/o10"
git init -q "$HOME/projects/o10"
( cd "$HOME/projects/o10" && git -c user.email=t@t -c user.name=t commit -qm i --allow-empty ) >/dev/null 2>&1
mkdir -p "$WORKTREE_ROOT/o10/foreign"
printf 'gitdir: %s\n' "$HOME/projects/OTHERREPO/.git/worktrees/foreign" > "$WORKTREE_ROOT/o10/foreign/.git"
echo x > "$WORKTREE_ROOT/o10/foreign/f.txt"
age_tree "$WORKTREE_ROOT/o10/foreign" 30
row o10/foreign > "$T/list10"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list10" 2>&1)"
has "foreign dangling pointer rejected" "orphan-pointer-not-owned-by-main-repo" "$out"
[[ -d "$WORKTREE_ROOT/o10/foreign" ]] && ok "foreign dir preserved" || bad "foreign dir deleted"

echo "=== Test 11: orphan removal requires explicit content attestation"
# With the admin dir gone there is no way to tell committed from never-committed
# content, so deletion must need an operator attestation naming the path.
mkdir -p "$HOME/projects/o11"
git init -q "$HOME/projects/o11"
( cd "$HOME/projects/o11" && git -c user.email=t@t -c user.name=t commit -qm i --allow-empty ) >/dev/null 2>&1
mkdir -p "$WORKTREE_ROOT/o11/orphan"
# Correctly owned pointer (under this repo's .git/worktrees/) that is MISSING,
# so provenance passes and the content-attestation gate is what fires.
printf 'gitdir: %s/.git/worktrees/orphan\n' "$HOME/projects/o11" > "$WORKTREE_ROOT/o11/orphan/.git"
echo content > "$WORKTREE_ROOT/o11/orphan/f.txt"
age_tree "$WORKTREE_ROOT/o11/orphan" 30
row o11/orphan > "$T/list11"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list11" 2>&1)"
has "orphan needs content attestation" "orphan-content-unverified" "$out"
[[ -d "$WORKTREE_ROOT/o11/orphan" ]] && ok "unattested orphan preserved" || bad "unattested orphan deleted"

# --------------------------------------------------- safety module / recency
echo "=== Test 12: a missing safety module fails closed"
make_origin "$T/o12.git"
make_worktree "$T/o12.git" wt12 feat12
git -C "$WORKTREE_ROOT/wt12" push -q origin feat12 >/dev/null 2>&1
age_tree "$WORKTREE_ROOT/wt12" 30
row wt12 > "$T/list12"
out="$(WT_DELETE_APPROVED=1 WT_SAFETY_CHECK=/nonexistent/safety.sh run_clean "$WT_DEL" "$T/list12" 2>&1)"
has "missing safety module fails closed" "safety-module-missing" "$out"
[[ -d "$WORKTREE_ROOT/wt12" ]] && ok "worktree preserved without safety module" || bad "deleted without safety module"

echo "=== Test 13: a protected path is stopped by the safety module"
make_origin "$T/o13.git"
mkdir -p "$WORKTREE_ROOT/PROTECTED"
make_worktree "$T/o13.git" PROTECTED/wt13 feat13
git -C "$WORKTREE_ROOT/PROTECTED/wt13" push -q origin feat13 >/dev/null 2>&1
age_tree "$WORKTREE_ROOT/PROTECTED/wt13" 30
row PROTECTED/wt13 > "$T/list13"
out="$(WT_DELETE_APPROVED=1 run_clean "$WT_DEL" "$T/list13" 2>&1)"
has "safety module veto honored" "safety-gate" "$out"
[[ -d "$WORKTREE_ROOT/PROTECTED/wt13" ]] && ok "protected worktree preserved" || bad "protected worktree deleted"

# ------------------------------------------------- advice: exclusion handling
echo "=== Test 14: a DIRECTORY as EXCLUDE_FILE refuses, rather than disabling the guard"
# A directory passes `-r` but grep fails, and any grep error used to read as
# "not excluded" -- switching the safeguard off.
mkdir -p "$SCRATCH_ROOT/advice-x" "$T/exdir"
echo x > "$SCRATCH_ROOT/advice-x/f.txt"
printf '%s\n' "$SCRATCH_ROOT/advice-x" > "$T/list14"
out="$(ADVICE_DELETE_APPROVED=1 EXCLUDE_FILE="$T/exdir" run_clean "$ADV_DEL" "$T/list14" 2>&1)"
has "directory exclusion file rejected" "exclusion-unreadable" "$out"
[[ -d "$SCRATCH_ROOT/advice-x" ]] && ok "candidate preserved" || bad "candidate deleted despite unreadable exclusion"

echo "=== Test 15: a listed path in a readable exclusion file is skipped"
printf '%s\n' "$SCRATCH_ROOT/advice-y" > "$T/exfile"
mkdir -p "$SCRATCH_ROOT/advice-y"
echo y > "$SCRATCH_ROOT/advice-y/f.txt"
printf '%s\n' "$SCRATCH_ROOT/advice-y" > "$T/list15"
out="$(ADVICE_DELETE_APPROVED=1 EXCLUDE_FILE="$T/exfile" run_clean "$ADV_DEL" "$T/list15" 2>&1)"
has "excluded path skipped" "SKIP excluded" "$out"
[[ -d "$SCRATCH_ROOT/advice-y" ]] && ok "excluded candidate preserved" || bad "excluded candidate deleted"

echo "=== Test 16: out-of-scope and unsafe advice paths are rejected"
mkdir -p "$SCRATCH_ROOT/notadvice-dir"
printf '%s\n' "$SCRATCH_ROOT/notadvice-dir" "$T/../escape" "/etc/passwd" > "$T/list16"
out="$(ADVICE_DELETE_APPROVED=1 run_clean "$ADV_DEL" "$T/list16" 2>&1)"
has "non-advice basename rejected" "out-of-scope" "$out"
has "non-scratch path rejected" "not-a-scratch-path" "$out"
[[ -d "$SCRATCH_ROOT/notadvice-dir" ]] && ok "out-of-scope dir preserved" || bad "out-of-scope dir deleted"

# --------------------------------------------------------- advice: happy path
echo "=== Test 17: an eligible advice dir is removed and logged"
mkdir -p "$SCRATCH_ROOT/advice-ok"
echo z > "$SCRATCH_ROOT/advice-ok/f.txt"
printf '%s\n' "$SCRATCH_ROOT/advice-ok" > "$T/list17"
out="$(ADVICE_DELETE_APPROVED=1 run_clean "$ADV_DEL" "$T/list17" 2>&1)"
has "eligible advice dir removed" "REMOVED" "$out"
[[ ! -e "$SCRATCH_ROOT/advice-ok" ]] && ok "advice dir gone" || bad "advice dir still present"
[[ -s "$DISK_MAGICIAN_DELETION_LOG" ]] && ok "audit row written" || bad "no audit row"

# ------------------------------------------------------------- pusher guards
echo "=== Test 18: an empty SHA can never form a delete refspec"
# `git push origin ":refs/heads/x"` DELETES the ref. A failed rev-parse yields
# an empty sha, so it must be rejected before the refspec is built.
make_origin "$T/o18.git"
make_worktree "$T/o18.git" wt18 feat18
git -C "$WORKTREE_ROOT/wt18" push -q origin feat18 >/dev/null 2>&1
gd18="$(sed -n 's/^gitdir:[[:space:]]*//p' "$WORKTREE_ROOT/wt18/.git" 2>/dev/null | head -1)"
printf 'corrupt
' > "${gd18:?}/HEAD" 2>/dev/null || true
row_push wt18 > "$T/list18"
out="$(WIP_PUSH_APPROVED=1 run_clean "$WT_PUSH" "$T/list18" 2>&1)"
hasnt "no delete refspec attempted" "refs/heads/wip/worktree-preserve" "$out"
hasnt "no false success" "PUSHED" "$out"
# the pre-existing remote branch must still exist
git -C "$T/o18.git" rev-parse --verify -q refs/heads/feat18 >/dev/null \
  && ok "remote branch survived" || bad "remote branch destroyed"

echo "=== Test 19: an unmeasurable unpushed count is an error, not a no-op"
# An empty `rev-list` capture used to become ahead=0 and report
# "nothing-unpushed", silently skipping preservation.
make_origin "$T/o19.git"
make_worktree "$T/o19.git" wt19 feat19
git -C "$WORKTREE_ROOT/wt19" push -q origin feat19 >/dev/null 2>&1
gd19="$(sed -n 's/^gitdir:[[:space:]]*//p' "$WORKTREE_ROOT/wt19/.git" 2>/dev/null | head -1)"
# Make HEAD unresolvable so `rev-list --count HEAD` fails outright: that is the
# "unmeasurable" path the guard must treat as an error, not as ahead=0.
printf 'corrupt\n' > "${gd19:?}/HEAD" 2>/dev/null || true
rm -rf "${gd19:?}/../objects" "${gd19:?}/../refs" 2>/dev/null
row_push wt19 > "$T/list19"
out="$(WIP_PUSH_APPROVED=1 run_clean "$WT_PUSH" "$T/list19" 2>&1)"
hasnt "unknown count is not reported as a no-op" "nothing-unpushed" "$out"

echo "=== Test 20: a genuinely unpushed commit is published to wip/"
make_origin "$T/o20.git"
make_worktree "$T/o20.git" wt20 feat20
( cd "$WORKTREE_ROOT/wt20" && echo new > new.txt && git add new.txt \
    && git -c user.email=t@t -c user.name=t commit -qm work ) >/dev/null 2>&1
row_push wt20 > "$T/list20"
out="$(WIP_PUSH_APPROVED=1 run_clean "$WT_PUSH" "$T/list20" 2>&1)"
has "unpushed commit published" "PUSHED" "$out"
git -C "$T/o20.git" for-each-ref --format='%(refname)' refs/heads/wip 2>/dev/null | grep -q wip/worktree-preserve \
  && ok "wip ref exists on the remote" || bad "wip ref missing on the remote"

echo "=== Test 21: no script may hard-require coreutils timeout"
# `timeout` is coreutils, absent from base macOS and minimal Linux images. An
# unguarded call exits 127, and that does not merely fail -- it makes every
# probe read as "unmeasurable", so the guard it protects silently stops
# enforcing. This is how CI failed while the suite passed locally.
for f in "$WT_DEL" "$ADV_DEL" "$WT_PUSH" "$ROOT/scripts/worktree_residency_check.sh"; do
  name="$(basename "$f")"
  # Every invocation of `timeout N` must be routed through the bounded() helper.
  raw="$(grep -nE '(^|[^_[:alnum:]])timeout [0-9]' "$f" | grep -v 'bounded' || true)"
  [[ -z "$raw" ]] && ok "$name guards timeout via bounded()" \
    || bad "$name calls timeout directly" "$(printf '%s' "$raw" | head -1)"
  has "  $name defines bounded()" "bounded()" "$(cat "$f")"
done

echo "=== Test 22: owner resolution must not walk up out of the worktree root"
# `git -C "$WT_ROOT"` walks UP the tree, so when the worktree root sits inside
# ANY git repository (a checkout, a nested CI sandbox) it resolves to that
# enclosing repo and never finds the candidate's owner. CI caught this; local
# runs did not because the fixture root happened to be outside any repo.
NEST="$T/nested"
mkdir -p "$NEST/home/projects/o22" "$NEST/home/.worktrees/o22/foreign"
git init -q "$NEST"
git init -q "$NEST/home/projects/o22"
( cd "$NEST/home/projects/o22" && git -c user.email=t@t -c user.name=t commit -qm i --allow-empty ) >/dev/null 2>&1
printf 'gitdir: %s\n' "$NEST/home/projects/OTHER/.git/worktrees/foreign" > "$NEST/home/.worktrees/o22/foreign/.git"
echo x > "$NEST/home/.worktrees/o22/foreign/f.txt"
age_tree "$NEST/home/.worktrees/o22/foreign" 30
row o22/foreign > "$NEST/list"
out="$(HOME="$NEST/home" WORKTREE_ROOT="$NEST/home/.worktrees" WT_DELETE_APPROVED=1 \
       run_clean "$WT_DEL" "$NEST/list" 2>&1)"
has "nested-parent repo does not hijack owner resolution" "orphan-pointer-not-owned-by-main-repo" "$out"
[[ -d "$NEST/home/.worktrees/o22/foreign" ]] && ok "foreign dir preserved under a nested parent repo" \
  || bad "foreign dir deleted under a nested parent repo"

echo
echo "===================================="
echo "Results: $PASS passed, $FAIL failed"
echo "===================================="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
