#!/usr/bin/env bash
# removal_activation_ok: a decision activates removal only with C14 present and, for D1,
# the CLAUDE.md amendment verified on a freshly fetched origin/main (spec §7.3).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d /tmp/removal-activation-test.XXXXXX)" && pwd -P)"
trap '[[ "$TMP" == /private/tmp/removal-activation-test.* || "$TMP" == /tmp/removal-activation-test.* ]] && rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() { local label="$1"; shift; if "$@"; then echo "PASS: $label"; PASS=$((PASS+1)); else echo "FAIL: $label"; FAIL=$((FAIL+1)); fi; }
export HOME="$TMP/home" DISK_MAGICIAN_POLICY_FILE="$TMP/cfg/standing_decisions.json" DISK_MAGICIAN_STATE_DIR="$TMP/state"
export STANDARD_WORKTREE_ROOT="$TMP/worktrees"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME" "$TMP/bin"
g() { git -C "$TMP/$1" "${@:2}" >/dev/null 2>&1; }

# Fixture: bare remote whose main carries the amendment; a clone holds a copy of scripts/.
git init -q --bare -b main "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/repo" 2>/dev/null
echo base > "$TMP/repo/CLAUDE.md"; g repo add -A; g repo commit -qm base
echo 'policy:worktree_reap_remove' >> "$TMP/repo/CLAUDE.md"; g repo commit -qam amendment
AMEND="$(git -C "$TMP/repo" rev-parse HEAD)"; g repo push -q origin HEAD:main
cp -R "$ROOT/scripts" "$ROOT/disk_magician.sh" "$TMP/repo/"
LIB="$TMP/repo/scripts/lib"
rm -f "$LIB/artifact_verdict.sh"
export DISK_MAGICIAN_POLICY_REPO="$TMP/repo"
policy() { bash "$TMP/repo/disk_magician.sh" policy "$@" >/dev/null 2>&1; }
OUT=""
activate() { OUT="$(source "$LIB/removal_activation.sh"; removal_activation_ok "$1")"; }
blocked() { ! activate "$1" && [[ "$OUT" == "activation_blocked:$2" ]]; }
c14() { printf 'artifact_removal_verdict() { [[ "$1" == --self-test ]] && echo %s; }\n' "$1" > "$LIB/artifact_verdict.sh"; }
T="$TMP/t.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"approve D1 worktree_reap_remove and D1b worktree_cleanup and claude_state_cleanup"}}' > "$T"
PH='approve D1 worktree_reap_remove'

check 'no decision blocks' blocked worktree_reap_remove decision_missing
policy approve worktree_reap_remove --phrase "$PH" --from-transcript "$T"
check 'D1 approved, no C14 lib blocks c14_missing' blocked worktree_reap_remove c14_missing
reap_log() { bash "$TMP/repo/scripts/worktree_reap.sh" --mode remove 2>&1; }
reap_mode() { [[ "$(reap_log)" == *'remove mode not approved'* ]]; }
check 'D1 approved, no C14 lib: reap nominates' reap_mode
c14 fail
check 'C14 self-test failure blocks' blocked worktree_reap_remove c14_missing
c14 ok
check 'lib present, no amendment blocks' blocked worktree_reap_remove amendment_missing
echo side > "$TMP/repo/side"; g repo add side; g repo commit -qm side
policy set-amendment worktree_reap_remove "$(git -C "$TMP/repo" rev-parse HEAD)"
check 'amendment not an ancestor blocks' blocked worktree_reap_remove amendment_not_on_main
policy set-amendment worktree_reap_remove "$AMEND"
check 'all present activates' activate worktree_reap_remove
check 'all present: reap leaves remove mode' bash -c '[[ "$(bash "$1/scripts/worktree_reap.sh" --mode remove 2>&1)" != *"remove mode not approved"* ]]' _ "$TMP/repo"

# Revert lands on the remote while the local origin/main still points at the amendment.
git clone -q "$TMP/remote.git" "$TMP/other" 2>/dev/null
g other revert --no-edit HEAD; g other push -q origin HEAD:main
check 'local origin/main still at amendment' test "$(git -C "$TMP/repo" rev-parse origin/main)" = "$AMEND"
check 'revert on remote blocks amendment_reverted' blocked worktree_reap_remove amendment_reverted
check 'revert: reap nominates' reap_mode
echo 'policy:worktree_reap_remove' >> "$TMP/other/CLAUDE.md"; g other commit -qam reapply; g other push -q origin HEAD:main

# Freshness: an unreachable remote or a hung fetch never falls back to the stale local ref.
g repo remote set-url origin "$TMP/missing.git"
check 'unreachable remote blocks policy_unverified' blocked worktree_reap_remove policy_unverified
g repo remote set-url origin "$TMP/remote.git"
cat > "$TMP/bin/git" <<EOF
#!/bin/bash
[[ " \$* " == *" fetch "* ]] && exec sleep 30
exec "$(command -v git)" "\$@"
EOF
chmod +x "$TMP/bin/git"
start=$(date +%s)
check 'hung fetch blocks policy_unverified' env PATH="$TMP/bin:$PATH" DISK_MAGICIAN_POLICY_FETCH_TIMEOUT=1 bash -c "$(declare -f blocked activate); LIB='$LIB'; blocked worktree_reap_remove policy_unverified"
check 'hung fetch bounded by timeout' test $(( $(date +%s) - start )) -lt 15
check 'remote restored with marker activates' activate worktree_reap_remove

# Other decisions need no fetch; revoke deactivates at the next call.
check 'D1b unrecorded blocks' blocked worktree_cleanup decision_missing
policy approve worktree_cleanup --phrase 'D1b worktree_cleanup' --from-transcript "$T"
check 'D1b approved with C14 activates' activate worktree_cleanup
rm -f "$LIB/artifact_verdict.sh"
check 'D1b approved without C14 blocks' blocked worktree_cleanup c14_missing
c14 ok
policy revoke worktree_reap_remove
check 'revoke blocks at next call' blocked worktree_reap_remove decision_missing
check 'revoke: reap nominates' reap_mode
check 'claude_state unrecorded blocks' blocked claude_state_cleanup decision_missing

echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
