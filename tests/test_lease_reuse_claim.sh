#!/usr/bin/env bash
# test_lease_reuse_claim.sh — focused regression for the shared reuse-claim
# owner/released-state contract.
#
# Bug (found in final integration): lease_claim_reuse converted a lease to a
# fresh live owner + pending reuse claim but carried the old `released_at`
# forward. A claimed lease then still read as "released", so a concurrent
# remover could treat the pending claim as free, and the claimer's own C14
# post-claim check could misread the origin state. A fresh claim must clear
# released_at while preserving the original lease for rollback.
#
# Pure/jurisdictionless: exercises the real python writer with no live ps, no
# real worktree and no host state. Fixtures are explicit /tmp paths.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/worktree_lease.sh
source "$REPO_ROOT/scripts/lib/worktree_lease.sh"

TMP="$(mktemp -d /tmp/dm-lease-reuse-claim.XXXXXX)" || { echo "FATAL: mktemp failed"; exit 1; }
[[ -n "$TMP" && "$TMP" == /* && -d "$TMP" ]] || { echo "FATAL: bad fixture root '$TMP'"; exit 1; }
trap 'rm -rf -- "$TMP"' EXIT

fail=0
ok()  { echo "ok   - $*"; }
bad() { echo "FAIL - $*"; fail=$((fail + 1)); }

LEASE="$TMP/lease.json"
cat > "$LEASE" <<'JSON'
{
  "path": "/tmp/example-worktree",
  "repo": "/tmp/example-repo",
  "branch": "worktree-old",
  "created_epoch": 1700000000,
  "ttl_hours": 24,
  "released_at": "2026-10-10T00:00:00+00:00",
  "owner": {"pid": 424242, "start_epoch": 1700000000, "comm": "claude"},
  "admin_id": "admin-old",
  "admin_birth_epoch": 1700000000,
  "checkout_dev": 1,
  "checkout_ino": 2
}
JSON
expected="$(shasum -a 256 "$LEASE" | awk '{print $1}')"

# Empty repo identity args skip the external stat checks; owner_tsv "-" -> null.
lease_claim_reuse "$LEASE" "$expected" "worktree-old" "deadbeef" "-" "" "" "" "" "" "" ||
    bad "lease_claim_reuse returned non-zero"

python3 - "$LEASE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("pending") is True, "pending not set"
assert "released_at" not in d and d.get("released_at") is None, \
    "fresh reuse claim must clear the old released_at"
assert d.get("owner") is None, "owner should be null for owner_tsv '-'"
prev = d.get("reuse", {}).get("previous_lease")
assert isinstance(prev, dict), "previous_lease must be retained for rollback"
assert prev.get("released_at") == "2026-10-10T00:00:00+00:00", \
    "previous_lease must preserve the original released state"
assert d.get("reuse", {}).get("state") == "pending", "reuse state not pending"
print("ok")
PY
[[ $? == 0 ]] && ok "claim clears released_at and retains rollback previous_lease" \
    || bad "claim released-state contract violated"

# A second claim on an already-pending lease must be refused (no double claim).
expected2="$(shasum -a 256 "$LEASE" | awk '{print $1}')"
if lease_claim_reuse "$LEASE" "$expected2" "worktree-old" "deadbeef" "-" "" "" "" "" "" ""; then
    bad "second claim on a pending lease was accepted"
else
    ok "second claim on a pending lease refused"
fi

# --- exact-candidate binding (parent review: no ambient same-owner bypass) ---
# A pending reuse claim is only honored for the exact candidate path it names
# and the exact live owner; an ancestor candidate or a different owner keeps.
ps_ok=0
if command -v ps >/dev/null 2>&1 && ps -p $$ -o pid= >/dev/null 2>&1; then
    ts_="$(LC_ALL=C TZ=UTC _lease_ps -p $$ -o lstart= 2>/dev/null)" && [[ -n "$ts_" ]] && \
        ep_="$(_lease_lstart_to_epoch "$ts_" 2>/dev/null)" && [[ "$ep_" =~ ^-?[0-9]+$ ]] && ps_ok=1
fi
if (( ps_ok == 0 )); then
    echo "skip - live-process candidate-binding cases (ps unavailable in this sandbox)"
else
    cand="$TMP/candidate-live"
    mkdir -p "$cand"
    claim="$TMP/claim-live.json"
    cat > "$claim" <<JSON
{
  "path": "$cand",
  "repo": "$TMP/repo",
  "branch": "worktree-old",
  "created_epoch": $(date +%s),
  "ttl_hours": 24,
  "pending": true,
  "owner": {"pid": $$, "start_epoch": $ep_, "comm": "bash"},
  "reuse": {"state": "pending", "old_branch": "worktree-old", "old_tip": "deadbeef",
            "previous_lease": {"released_at": "2026-10-10T00:00:00+00:00"}}
}
JSON
    own="$$"$'\t'"$ep_"$'\t'"bash"
    [[ "$(lease_owner_state_for "$claim" "$own" "$cand")" == own-live ]] \
        && ok "exact candidate + exact owner pending claim reports own-live" \
        || bad "exact candidate pending claim did not report own-live"
    [[ "$(lease_owner_state_for "$claim" "$own" "$TMP")" == alive ]] \
        && ok "pending claim is not exempted for an ancestor candidate" \
        || bad "pending claim leaked an ancestor exemption"
    [[ "$(lease_owner_state_for "$claim" "1	1	claude" "$cand")" == alive ]] \
        && ok "pending claim is not exempted for a different owner" \
        || bad "pending claim leaked a different-owner exemption"
    python3 - "$claim" "$TMP/claim-noprev.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d["reuse"].pop("previous_lease",None)
json.dump(d,open(sys.argv[2],"w"))
PY
    [[ "$(lease_owner_state_for "$TMP/claim-noprev.json" "$own" "$cand")" == alive ]] \
        && ok "pending claim without previous_lease proof is not exempted" \
        || bad "pending claim without rollback proof leaked an exemption"
fi

echo
if (( fail == 0 )); then
    echo "RESULT: PASS ($0)"
    exit 0
fi
echo "RESULT: FAIL ($fail)"
exit 1
