#!/usr/bin/env bash
# Session-exit lease release (governor T12, spec C8). Temp dirs only; release
# never deletes, so every worktree directory must survive.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(cd "$(mktemp -d /tmp/lease-release-test.XXXXXX)" && pwd -P)"
trap '[[ "$TMP" == /tmp/lease-release-test.* || "$TMP" == /private/tmp/lease-release-test.* ]] && rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
check() { local label="$1"; shift; if "$@"; then echo "PASS: $label"; PASS=$((PASS+1)); else echo "FAIL: $label"; FAIL=$((FAIL+1)); fi; }
export DISK_MAGICIAN_STATE_DIR="$TMP/state" FAKE_PS_DIR="$TMP/ps" DISK_MAGICIAN_PS_BIN="$TMP/bin/ps"
mkdir -p "$TMP/bin" "$FAKE_PS_DIR/comm" "$FAKE_PS_DIR/lstart" "$FAKE_PS_DIR/args" "$TMP/wt"
cat > "$TMP/bin/ps" <<'MOCK'
#!/bin/bash
pid= spec=
while [[ $# -gt 0 ]]; do case "$1" in -p) pid="$2"; shift 2;; -o) spec="$2"; shift 2;; *) shift;; esac; done
case "$spec" in lstart=) f="$FAKE_PS_DIR/lstart/$pid";; args=) f="$FAKE_PS_DIR/args/$pid";; ppid=,comm=) f="$FAKE_PS_DIR/comm/$pid";; *) exit 1;; esac
[[ -f "$f" ]] || exit 1
cat "$f"
MOCK
chmod +x "$TMP/bin/ps"
lstart() { python3 -c 'import sys; from datetime import datetime,timezone; print(datetime.fromtimestamp(int(sys.argv[1]),timezone.utc).strftime("%a %b %d %H:%M:%S %Y"))' "$1"; }
# 500 = ending runtime, 501 = another live runtime, 502 = dead (no ps entry).
for p in 500 501; do lstart "1760000$p" > "$FAKE_PS_DIR/lstart/$p"; echo /usr/bin/claude > "$FAKE_PS_DIR/args/$p"; echo "1 claude" > "$FAKE_PS_DIR/comm/$p"; done
source "$ROOT/scripts/lib/worktree_lease.sh"

# lease_write records the owning session from DISK_MAGICIAN_OWNER_SESSION.
lstart 1760000600 > "$FAKE_PS_DIR/lstart/$$"; echo "1 claude" > "$FAKE_PS_DIR/comm/$$"; echo /usr/bin/claude > "$FAKE_PS_DIR/args/$$"
mkdir -p "$TMP/wt/w"; DISK_MAGICIAN_OWNER_SESSION=S0 lease_write "$TMP/wt/w" repo br test
check 'lease_write records owner.session' test "$(_lease_get "$(lease_path_for "$TMP/wt/w")" owner)" = "{'pid': $$, 'start_epoch': 1760000600, 'comm': 'claude', 'session': 'S0'}"
mkdir -p "$TMP/wt/w2"; (unset DISK_MAGICIAN_OWNER_SESSION; lease_write "$TMP/wt/w2" repo br test)
check 'no session env, no session key' test "$(python3 -c 'import json,sys; print("session" in json.load(open(sys.argv[1]))["owner"])' "$(lease_path_for "$TMP/wt/w2")")" = False

mk() { # mk <name> <session> <pid>
    mkdir -p "$TMP/wt/$1"
    _lease_emit_json "$(lease_path_for "$TMP/wt/$1")" "$TMP/wt/$1" repo br test False "$3" "1760000$3" claude - - 24
    python3 - "$(lease_path_for "$TMP/wt/$1")" "$2" <<'PY'
import json,sys
p,s=sys.argv[1:]; d=json.load(open(p)); d["owner"]["session"]=s; json.dump(d,open(p,"w"))
PY
}
released() { test -n "$(_lease_get "$(lease_path_for "$TMP/wt/$1")" released_at)"; }
mk A S 500; mk B S 501; mk C T 500; mk D S 502
snap() { cat "$(lease_dir)"/*.json | shasum; }
before="$(snap)"
out="$(lease_release_owner_session U 500 1760000500)"; rc=$?
check 'unknown session rc 0' test "$rc" = 0
check 'unknown session changes nothing' test "$(snap)" = "$before"
out="$(lease_release_owner_session S 500 1760000500)"; rc=$?
check 'release rc 0' test "$rc" = 0
check 'A (session S, ending runtime) released' released A
check 'B (session S, other live pid) not released' bash -c "! test -n \"\$(source '$ROOT/scripts/lib/worktree_lease.sh'; _lease_get '$(lease_path_for "$TMP/wt/B")' released_at)\""
check 'B reported release_skipped_live_owner' grep -q "^release_skipped_live_owner $TMP/wt/B\$" <<<"$out"
check 'C (session T) untouched' bash -c "! test -n \"\$(source '$ROOT/scripts/lib/worktree_lease.sh'; _lease_get '$(lease_path_for "$TMP/wt/C")' released_at)\""
check 'D (session S, dead owner) released' released D
check 'released worktrees still exist' test -d "$TMP/wt/A" -a -d "$TMP/wt/D"
check 'A reads released to the reaper' test "$(lease_owner_state "$(lease_path_for "$TMP/wt/A")")" = released
# Runtime start epoch mismatch: same pid, other start -> not the ending runtime.
mk E S 501; out="$(lease_release_owner_session S 501 1)"
check 'pid match with other start epoch is not self' grep -q "release_skipped_live_owner $TMP/wt/E" <<<"$out"

# CLI dispatch.
mk F S2 500
bash "$ROOT/disk_magician.sh" lease-release --owner-session S2 --runtime-pid 500 --runtime-start-epoch 1760000500 > "$TMP/cli.out" 2>&1; rc=$?
check 'diskm lease-release rc 0' test "$rc" = 0
check 'diskm lease-release releases F' released F
bash "$ROOT/disk_magician.sh" lease-release > /dev/null 2>&1; rc=$?
check 'diskm lease-release without --owner-session rc 2' test "$rc" = 2

# Hook template: passes session_id through, never blocks, ignores junk.
cat > "$TMP/bin/diskm-stub" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
exit 3
STUB
chmod +x "$TMP/bin/diskm-stub"
export STUB_LOG="$TMP/stub.log" DISKM_BIN="$TMP/bin/diskm-stub"
HOOK="$ROOT/hooks/session-end-lease-release.sh"
out="$(printf '{"session_id":"abc-123","hook_event_name":"SessionEnd"}' | bash "$HOOK")"; rc=$?
check 'hook exits 0' test "$rc" = 0
check 'hook prints nothing' test -z "$out"
check 'hook calls lease-release with the session' test "$(cat "$STUB_LOG" 2>/dev/null)" = 'lease-release --owner-session abc-123'
: > "$STUB_LOG"
printf 'not json' | bash "$HOOK"; rc=$?
printf '{"session_id":"x; rm -rf /"}' | bash "$HOOK"
check 'hook on junk exits 0' test "$rc" = 0
check 'hook on junk or unsafe id calls nothing' test ! -s "$STUB_LOG"

printf '%s passed; %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
