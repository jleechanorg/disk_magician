#!/usr/bin/env bash
# test_c14_adoption_lease.sh — a birth-audit adoption lease (owner null,
# kind scratch, creator birth-audit) is a ledger record, not an ownership claim:
# it must not veto C14 removal. Every other owner-null/foreign/corrupt/live
# lease still keeps. Real artifact_removal_verdict; /tmp fixtures only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3 (= $2)"; else bad "$3 — expected '$2', got '$1'"; fi; }

TMP="$(mktemp -d /tmp/dm-c14-adopt.XXXXXX)" || exit 2
TMP="$(cd "$TMP" && pwd -P)" || exit 2
case "$TMP" in /tmp/dm-c14-adopt.*|/private/tmp/dm-c14-adopt.*) ;; *) exit 2 ;; esac
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home" DISK_MAGICIAN_STATE_DIR="$TMP/state"
PT="$TMP/ptmp"; mkdir -p "$HOME" "$DISK_MAGICIAN_STATE_DIR" "$PT" "$TMP/utmp"
export DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE="$PT" DISK_MAGICIAN_TMP_ROOT_OVERRIDE="$PT"
export DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE="$TMP/utmp"
unset C14_INVENTORY_OUT C14_INVENTORY_FILE DISK_MAGICIAN_C14_LEDGER DISK_MAGICIAN_PROTECTED_TMP_ROOTS 2>/dev/null || true

# shellcheck source=scripts/lib/artifact_verdict.sh
source "$ROOT/scripts/lib/artifact_verdict.sh"
NOW="$(date +%s)"
age() { find "$1" -exec touch -h -t "$(date -r $((NOW - $2 * 60)) +%Y%m%d%H%M.%S)" {} +; }
eph() { artifact_removal_verdict "$1" --kind ephemeral; }

# fixture <name> <lease-json-body-or-RAW:text>: aged scratch dir with a nested
# file whose lease record is the given JSON ("%P" is the nested path).
fixture() {
    local d="$PT/$1" n f; n="$d/nested.txt"
    export DISK_MAGICIAN_STATE_DIR="$TMP/state-$1"  # a corrupt record poisons the whole lease scan
    mkdir -p "$d" && printf 'x\n' >"$n" && age "$d" 50000
    f="$(lease_path_for "$n")" && mkdir -p "${f%/*}" || return 1
    if [[ "$2" == RAW:* ]]; then printf '%s' "${2#RAW:}" >"$f"
    else printf '%s\n' "${2//%P/$n}" >"$f"; fi
}
J() { printf '{"path":"%%P","owner":%s,"creator":"%s","kind":"%s","released_at":null}' "$1" "$2" "$3"; }

export DISK_MAGICIAN_STATE_DIR="$TMP/state-control"; mkdir -p "$PT/pr-control" && printf 'x\n' >"$PT/pr-control/f" && age "$PT/pr-control" 50000
assert_eq "$(eph "$PT/pr-control")" remove "control: aged scratch dir with no lease"

fixture pr-adopt "$(J null birth-audit scratch)"
assert_eq "$(eph "$PT/pr-adopt")" remove "nested birth-audit owner-null scratch lease does not veto"
fixture pr-wt "$(J null birth-audit worktree)"
assert_eq "$(eph "$PT/pr-wt")" kept:owner-unknown "owner-null worktree lease still keeps"
fixture pr-ev "$(J null birth-audit evidence)"
assert_eq "$(eph "$PT/pr-ev")" kept:owner-unknown "owner-null evidence lease still keeps"
fixture pr-other "$(J null someone-else scratch)"
assert_eq "$(eph "$PT/pr-other")" kept:owner-unknown "owner-null scratch lease from another creator still keeps"
fixture pr-nokind '{"path":"%P","owner":null,"creator":"birth-audit"}'
assert_eq "$(eph "$PT/pr-nokind")" kept:owner-unknown "owner-null lease with no kind still keeps"
fixture pr-noowner '{"path":"%P","creator":"birth-audit","kind":"scratch"}'
assert_eq "$(eph "$PT/pr-noowner")" kept:owner-unknown "lease with no owner field keeps"
fixture pr-pending '{"path":"%P","owner":null,"pending":true,"creator":"birth-audit","kind":"scratch"}'
assert_eq "$(eph "$PT/pr-pending")" kept:owner-unknown "pending owner-null lease keeps"
fixture pr-corrupt 'RAW:{not json'
case "$(eph "$PT/pr-corrupt")" in kept:*) ok "corrupt lease keeps" ;; *) bad "corrupt lease keeps" ;; esac
fixture pr-live "$(J "{\"pid\":$$,\"start_epoch\":$(_lease_ps_lstart_epoch $$),\"comm\":\"$(_lease_full_comm $$)\"}" birth-audit scratch)"
assert_eq "$(eph "$PT/pr-live")" kept:live-owner "live-owner lease keeps even with birth-audit scratch fields"
fixture pr-mixed "$(J null birth-audit scratch)"
printf 'y\n' >"$PT/pr-mixed/second.txt"; age "$PT/pr-mixed" 50000
f="$(lease_path_for "$PT/pr-mixed/second.txt")"; mkdir -p "${f%/*}"
printf '{"path":"%s","owner":null,"creator":"x","kind":"scratch"}\n' "$PT/pr-mixed/second.txt" >"$f"
assert_eq "$(eph "$PT/pr-mixed")" kept:owner-unknown "an adoption lease does not mask a sibling foreign owner-null lease"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
