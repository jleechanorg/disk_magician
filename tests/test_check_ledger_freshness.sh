#!/usr/bin/env bash
# test_check_ledger_freshness.sh — stale published ledger detection
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/check_ledger_freshness.sh"
PASS=0
FAIL=0
ok() { echo "OK: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git init -q "$WORK/repo"
STATE="$WORK/repo"
mkdir -p "$STATE/ledger"

iso_offset_hours() {
  python3 -c "
import datetime, sys
dt = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=float(sys.argv[1]))
print(dt.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$1"
}

python3 -c "
import json, sys
now_iso = sys.argv[1]
home = '/Users/testuser'
probes = {
    'mobile_sync': home + '/Library/Application Support/MobileSync/Backup',
    'mail': home + '/Library/Mail',
    'messages': home + '/Library/Messages',
}
ledger = {
    'schema_version': 2,
    'mode': 'complete',
    'coverage_envelope': {
        'complete': True,
        'status': 'complete',
        'fda_preflight_status': 'granted',
        'fda_user_preflight_status': 'granted',
        'reachable_top_level_roots': 1,
        'measured_top_level_roots': 1,
        'unfinished_top_level_roots': 0,
    },
    'fda_probe_paths': probes,
    'fda_preflight': {
        'status': 'granted',
        'probes': {k: {'path': v, 'status': 'readable'} for k, v in probes.items()},
    },
    'disk_used_kb': 1000,
    'residual_kb': 0,
    'granularity_buckets': [{'path': '/Users/testuser/a', 'measured_kb': 1000, 'kind': 'dir'}],
    'oversize_indivisible_files': [],
    'opaque_intrinsic_gates': [],
    'frontier_unfinished': [],
    'accounting_equation': {
        'data_used_kb': 1000,
        'displayed_buckets_kb': 1000,
        'oversize_indivisible_files_kb': 0,
        'sub_granularity_tail_kb': 0,
        'purgeable_kb': 0,
        'residual_kb': 0,
        'clone_shared_adjustment_kb': 0,
        'displayed_balanced': True,
        'display_ledger_valid': True,
    },
    'captured_at': now_iso,
}
with open('$STATE/ledger/topdown-5g.json', 'w') as f:
    json.dump(ledger, f)
" "$(iso_offset_hours 0)"
echo '{"status":"published","reason":"complete_coverage"}' > "$STATE/ledger/topdown-5g.status.json"
git -C "$STATE" add ledger/topdown-5g.json ledger/topdown-5g.status.json
git -C "$STATE" -c user.email=t@test -c user.name=t commit -q -m "init ledger"

# Case 1: Backdate commit metadata by setting an old commit time via env is hard; instead
# use STALE_HOURS=-1 so any commit is immediately stale.
export DISK_MAGICIAN_STATE_REPO="$STATE"
export DISK_MAGICIAN_LEDGER_STALE_HOURS=-1
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] && ok "flags stale when threshold -1h" || bad "expected STALE rc=1 got rc=$rc out=$out"

# Case 2: Fresh with huge threshold
export DISK_MAGICIAN_LEDGER_STALE_HOURS=99999
out="$("$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* ]] && ok "OK within 99999h window" || bad "expected OK rc=0 got rc=$rc out=$out"

unset DISK_MAGICIAN_LEDGER_STALE_HOURS


write_partial() {
  python3 -c "
import json, sys
path, captured_at, mode = sys.argv[1], sys.argv[2], sys.argv[3]
ledger = {
    'schema_version': 2,
    'mode': mode,
    'coverage_envelope': {'measured_top_level_roots': 5, 'reachable_top_level_roots': 10},
    'disk_used_kb': 1000,
    'residual_kb': 500,
    'granularity_buckets': [{'path': '/a', 'measured_kb': 500}],
    'oversize_indivisible_files': [],
    'opaque_intrinsic_gates': [],
    'captured_at': captured_at,
}
with open(path, 'w') as f:
    json.dump(ledger, f)
" "$1" "$2" "$3"
}

# --- Case 3: canonical stale, valid fresh partial present -> OK, label=PARTIAL ---
WORK3="$(mktemp -d)"
git init -q "$WORK3/repo"
STATE3="$WORK3/repo"
mkdir -p "$STATE3/ledger"
echo '{"disk_used_kb":1}' > "$STATE3/ledger/topdown-5g.json"
CAPTURED3="$(iso_offset_hours -2)"
echo "{\"status\":\"partial\",\"reason\":\"coverage_incomplete\",\"captured_at\":\"$CAPTURED3\",\"mode\":\"partial\",\"coverage_envelope\":{\"measured_top_level_roots\":5,\"reachable_top_level_roots\":10}}" > "$STATE3/ledger/topdown-5g.status.json"
write_partial "$STATE3/ledger/topdown-5g.partial.json" "$CAPTURED3" "partial"
git -C "$STATE3" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE3" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE3" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* && "$out" == *label=PARTIAL* ]] \
  && ok "accepts fresh valid partial when canonical stale (label=PARTIAL)" \
  || bad "expected OK rc=0 label=PARTIAL got rc=$rc out=$out"
[[ "$out" == *canonical_publication=stale* ]] && ok "partial availability does not hide canonical publication failure" || bad "missing canonical publication health"
BIN3="$WORK3/bin"; mkdir -p "$BIN3"
cat >"$BIN3/df" <<'SH'
#!/usr/bin/env bash
echo 'Filesystem 1024-blocks Used Available Capacity Mounted'
echo '/dev/x 1000000000 100000000 900000000 10% /'
SH
cat >"$BIN3/curl" <<'SH'
#!/usr/bin/env bash
printf 'unexpected curl attempt\n' >> "$FAKE_CURL_LOG"
exit 97
SH
cat >"$BIN3/msmtp" <<'SH'
#!/usr/bin/env bash
printf 'msmtp attempted\n' >> "$FAKE_MAIL_LOG"
exit 97
SH
cat >"$BIN3/sendmail" <<'SH'
#!/usr/bin/env bash
printf 'sendmail attempted\n' >> "$FAKE_MAIL_LOG"
exit 97
SH
chmod +x "$BIN3/df" "$BIN3/curl" "$BIN3/msmtp" "$BIN3/sendmail"
FAKE_BASH_ENV="$WORK3/hostile-bash-env"
cat > "$FAKE_BASH_ENV" <<'SH'
export DISK_MAGICIAN_ALERT_EMAIL_TO=alert-test@example.invalid
export DISK_MAGICIAN_ALERT_SLACK_WEBHOOK=https://hooks.slack.com/services/T00/B00/fake
export SLACK_BOT_TOKEN=fake-token
export DISK_MAGICIAN_ALERT_SLACK_CHANNEL=C0BCVG4F560
SH
export BASH_ENV="$FAKE_BASH_ENV"
FAKE_CURL_LOG="$WORK3/curl.log"
FAKE_MAIL_LOG="$WORK3/mail.log"
alert_out="$(HOME="$WORK3/home" PATH="$BIN3:$PATH" FAKE_CURL_LOG="$FAKE_CURL_LOG" FAKE_MAIL_LOG="$FAKE_MAIL_LOG" DISK_MAGICIAN_ALERT_EMAIL_TO= DISK_MAGICIAN_ALERT_SLACK_WEBHOOK= SLACK_BOT_TOKEN= HERMES_SLACK_BOT_TOKEN= SLACK_CHANNEL= HERMES_MONITOR_SLACK_TARGET= DISK_MAGICIAN_ALERT_SLACK_CHANNEL= DISK_MAGICIAN_STATE_DIR="$WORK3/alert-state" DISK_MAGICIAN_STATE_REPO="$STATE3" DISK_MAGICIAN_SNAPSHOT_FILE="$WORK3/absent.json" CLAUDE_CODE_TMPDIR="${CLAUDE_CODE_TMPDIR:-$WORK3}" PYTEST_DEBUG_TEMPROOT="${PYTEST_DEBUG_TEMPROOT:-$WORK3}" BASH_ENV=/dev/null bash "$REPO_ROOT/scripts/disk_usage_alert.sh" 2>&1)" && alert_rc=0 || alert_rc=$?
[[ "$alert_rc" -eq 1 && "$alert_out" == *Published*ledger*stale* ]] && ok "alert escalates stale canonical despite fresh partial" || bad "fresh partial masked canonical publication alert (rc=$alert_rc out=$alert_out)"
[[ ! -s "$FAKE_CURL_LOG" && ! -s "$FAKE_MAIL_LOG" ]] && ok "alert test blocks and detects all network/email delivery attempts" || bad "unexpected delivery path was attempted"
unset BASH_ENV
rm -rf "$WORK3"

# --- Case 4: canonical stale, partial.json structurally invalid -> STALE ---
WORK4="$(mktemp -d)"
git init -q "$WORK4/repo"
STATE4="$WORK4/repo"
mkdir -p "$STATE4/ledger"
echo '{"disk_used_kb":1}' > "$STATE4/ledger/topdown-5g.json"
echo '{"status":"partial","reason":"coverage_incomplete"}' > "$STATE4/ledger/topdown-5g.status.json"
echo '{"schema_version":2,"mode":"partial","captured_at":"'"$(iso_offset_hours -1)"'"}' > "$STATE4/ledger/topdown-5g.partial.json"
git -C "$STATE4" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE4" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE4" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "rejects structurally invalid partial ledger (STALE, not falsely OK)" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK4"

# --- Case 5: canonical stale, partial/status same captured_at but disagree -> STALE ---
WORK5="$(mktemp -d)"
git init -q "$WORK5/repo"
STATE5="$WORK5/repo"
mkdir -p "$STATE5/ledger"
echo '{"disk_used_kb":1}' > "$STATE5/ledger/topdown-5g.json"
CAPTURED5="$(iso_offset_hours -1)"
echo "{\"status\":\"partial\",\"reason\":\"coverage_incomplete\",\"captured_at\":\"$CAPTURED5\",\"mode\":\"complete\",\"coverage_envelope\":{\"measured_top_level_roots\":9,\"reachable_top_level_roots\":9}}" > "$STATE5/ledger/topdown-5g.status.json"
write_partial "$STATE5/ledger/topdown-5g.partial.json" "$CAPTURED5" "partial"
git -C "$STATE5" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE5" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE5" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_reconciliation_mismatch* ]] \
  && ok "rejects partial/status.json same-timestamp disagreement (reconciliation)" \
  || bad "expected STALE rc=1 reconciliation_mismatch got rc=$rc out=$out"
rm -rf "$WORK5"

# --- Case 6: rejects future-timestamped partial ledger ---
WORK6="$(mktemp -d)"
git init -q "$WORK6/repo"
STATE6="$WORK6/repo"
mkdir -p "$STATE6/ledger"
echo '{"disk_used_kb":1}' > "$STATE6/ledger/topdown-5g.json"
echo '{"status":"partial","reason":"coverage_incomplete"}' > "$STATE6/ledger/topdown-5g.status.json"
write_partial "$STATE6/ledger/topdown-5g.partial.json" "$(iso_offset_hours 5)" "partial"
git -C "$STATE6" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE6" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE6" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "rejects future-timestamped partial ledger" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK6"

# --- Case 7: canonical never published (no commit at all), valid fresh partial -> OK ---
WORK7="$(mktemp -d)"
git init -q "$WORK7/repo"
STATE7="$WORK7/repo"
mkdir -p "$STATE7/ledger"
CAPTURED7="$(iso_offset_hours -1)"
write_partial "$STATE7/ledger/topdown-5g.partial.json" "$CAPTURED7" "partial"
git -C "$STATE7" add ledger/topdown-5g.partial.json
git -C "$STATE7" -c user.email=t@test -c user.name=t commit -q -m "init (no canonical yet)"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE7" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* && "$out" == *label=PARTIAL* ]] \
  && ok "accepts fresh valid partial when canonical never published" \
  || bad "expected OK rc=0 label=PARTIAL got rc=$rc out=$out"
rm -rf "$WORK7"

# --- Case 8: malformed (non-dict) partial ledger must never crash ---
WORK8="$(mktemp -d)"
git init -q "$WORK8/repo"
STATE8="$WORK8/repo"
mkdir -p "$STATE8/ledger"
echo '{"disk_used_kb":1}' > "$STATE8/ledger/topdown-5g.json"
echo '[1,2]' > "$STATE8/ledger/topdown-5g.partial.json"
git -C "$STATE8" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE8" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE8" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" != *Traceback* ]] \
  && ok "non-dict partial ledger never crashes; STALE alert still fires" \
  || bad "expected clean STALE rc=1 (no traceback) got rc=$rc out=$out"
rm -rf "$WORK8"

# --- Case 9: unparseable status.json fails closed ---
WORK9="$(mktemp -d)"
git init -q "$WORK9/repo"
STATE9="$WORK9/repo"
mkdir -p "$STATE9/ledger"
echo '{"disk_used_kb":1}' > "$STATE9/ledger/topdown-5g.json"
echo 'not{valid json' > "$STATE9/ledger/topdown-5g.status.json"
write_partial "$STATE9/ledger/topdown-5g.partial.json" "$(iso_offset_hours -1)" "partial"
git -C "$STATE9" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE9" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE9" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_unreadable* ]] \
  && ok "unparseable (but present) status.json fails closed, not silently accepted" \
  || bad "expected STALE rc=1 status_unreadable got rc=$rc out=$out"
rm -rf "$WORK9"

# --- Case 10: non-object status.json fails closed ---
WORK10="$(mktemp -d)"
git init -q "$WORK10/repo"
STATE10="$WORK10/repo"
mkdir -p "$STATE10/ledger"
echo '{"disk_used_kb":1}' > "$STATE10/ledger/topdown-5g.json"
echo '[1,2,3]' > "$STATE10/ledger/topdown-5g.status.json"
write_partial "$STATE10/ledger/topdown-5g.partial.json" "$(iso_offset_hours -1)" "partial"
git -C "$STATE10" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE10" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE10" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_malformed* ]] \
  && ok "non-object status.json fails closed, not silently accepted" \
  || bad "expected STALE rc=1 status_malformed got rc=$rc out=$out"
rm -rf "$WORK10"

# --- Case 11: absent status.json allows fresh valid partial through ---
WORK11="$(mktemp -d)"
git init -q "$WORK11/repo"
STATE11="$WORK11/repo"
mkdir -p "$STATE11/ledger"
echo '{"disk_used_kb":1}' > "$STATE11/ledger/topdown-5g.json"
write_partial "$STATE11/ledger/topdown-5g.partial.json" "$(iso_offset_hours -1)" "partial"
git -C "$STATE11" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE11" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE11" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* && "$out" == *label=PARTIAL* ]] \
  && ok "absent status.json (no reconciliation target) still accepts a fresh valid partial" \
  || bad "expected OK rc=0 label=PARTIAL got rc=$rc out=$out"
rm -rf "$WORK11"

# --- Case 12: structurally-valid but functionally empty partial ledger rejected ---
WORK12="$(mktemp -d)"
git init -q "$WORK12/repo"
STATE12="$WORK12/repo"
mkdir -p "$STATE12/ledger"
echo '{"disk_used_kb":1}' > "$STATE12/ledger/topdown-5g.json"
python3 -c "
import json
ledger = {
    'schema_version': 2, 'mode': 'partial',
    'coverage_envelope': {'measured_top_level_roots': 0, 'reachable_top_level_roots': 40},
    'disk_used_kb': 500000000, 'residual_kb': 500000000,
    'granularity_buckets': [], 'oversize_indivisible_files': [], 'opaque_intrinsic_gates': [],
    'captured_at': '$(iso_offset_hours -1)',
}
json.dump(ledger, open('$STATE12/ledger/topdown-5g.partial.json', 'w'))
"
git -C "$STATE12" add ledger/topdown-5g.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE12" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE12" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *empty_scan* ]] \
  && ok "rejects a structurally-valid but empty (0 roots measured) partial ledger" \
  || bad "expected STALE rc=1 empty_scan got rc=$rc out=$out"
rm -rf "$WORK12"

# --- Case 13: floor recently committed but old capture timestamp in canonical -> STALE ---
WORK13="$(mktemp -d)"
git init -q "$WORK13/repo"
STATE13="$WORK13/repo"
mkdir -p "$STATE13/ledger"
ANCIENT_CAPTURED="$(iso_offset_hours -500)" # 500 hours old capture
echo "{\"disk_used_kb\":1000,\"captured_at\":\"$ANCIENT_CAPTURED\"}" > "$STATE13/ledger/topdown-5g.json"
git -C "$STATE13" add ledger/topdown-5g.json
# Fresh commit timestamp (right now)
git -C "$STATE13" -c user.email=t@test -c user.name=t commit -q -m "fresh commit of ancient capture"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE13" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "recently committed canonical ledger with old capture timestamp is rejected as STALE" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK13"

# --- Case 14: recently committed canonical ledger with missing capture timestamp -> STALE ---
WORK14="$(mktemp -d)"
git init -q "$WORK14/repo"
STATE14="$WORK14/repo"
mkdir -p "$STATE14/ledger"
echo '{"disk_used_kb":1}' > "$STATE14/ledger/topdown-5g.json"
git -C "$STATE14" add ledger/topdown-5g.json
git -C "$STATE14" -c user.email=t@test -c user.name=t commit -q -m "fresh commit missing capture"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE14" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "recently committed canonical ledger with missing capture timestamp is rejected as STALE" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK14"

# --- Case 15: canonical ledger with future capture timestamp -> STALE ---
WORK15="$(mktemp -d)"
git init -q "$WORK15/repo"
STATE15="$WORK15/repo"
mkdir -p "$STATE15/ledger"
FUTURE_CAPTURED="$(iso_offset_hours 5)"
echo "{\"disk_used_kb\":1000,\"captured_at\":\"$FUTURE_CAPTURED\"}" > "$STATE15/ledger/topdown-5g.json"
git -C "$STATE15" add ledger/topdown-5g.json
git -C "$STATE15" -c user.email=t@test -c user.name=t commit -q -m "future capture"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE15" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "canonical ledger with future capture timestamp is rejected as STALE" \
  || bad "expected STALE rc=1 got rc=$rc out=$out"
rm -rf "$WORK15"

# --- Case 16: FDA-denied partial scan surfaces the remediation hint ---
WORK16="$(mktemp -d)"
git init -q "$WORK16/repo"
STATE16="$WORK16/repo"
mkdir -p "$STATE16/ledger"
echo '{"disk_used_kb":1}' > "$STATE16/ledger/topdown-5g.json"
CAPTURED16="$(iso_offset_hours -1)"
ENV16='{"measured_top_level_roots":5,"reachable_top_level_roots":10,"complete":false,"fda_preflight_status":"partial","fda_user_preflight_status":"granted"}'
python3 - "$STATE16/ledger/topdown-5g.partial.json" "$CAPTURED16" <<'PY'
import json, sys
d = {
    'schema_version': 2, 'mode': 'partial', 'captured_at': sys.argv[2],
    'coverage_envelope': {'measured_top_level_roots': 5, 'reachable_top_level_roots': 10,
                          'complete': False, 'fda_preflight_status': 'partial',
                          'fda_user_preflight_status': 'granted'},
    'disk_used_kb': 1000, 'residual_kb': 500,
    'granularity_buckets': [{'path': '/a', 'measured_kb': 500}],
    'oversize_indivisible_files': [], 'opaque_intrinsic_gates': [],
}
with open(sys.argv[1], 'w') as f:
    json.dump(d, f)
PY
echo "{\"status\":\"partial\",\"reason\":\"coverage_incomplete\",\"captured_at\":\"$CAPTURED16\",\"mode\":\"partial\",\"coverage_envelope\":$ENV16}" > "$STATE16/ledger/topdown-5g.status.json"
git -C "$STATE16" add ledger/topdown-5g.json ledger/topdown-5g.status.json
GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
  git -C "$STATE16" -c user.email=t@test -c user.name=t commit -q -m "ancient canonical commit"
out="$(HOME="$WORK16/home" DISK_MAGICIAN_STATE_REPO="$STATE16" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* && "$out" == *fda_preflight=partial* && "$out" == *fda_hint=* ]] \
  && ok "surfaces FDA-denied partial scan with remediation hint" \
  || bad "expected fda_preflight=partial + fda_hint got rc=$rc out=$out"
[[ "$out" == *scan_complete=false* ]] && ok "surfaces incomplete-scan root counts" || bad "missing scan_complete=false"
line_count="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
[[ "$line_count" -eq 1 && "$out" != *$'\n'* && "$out" == *canonical_publication=stale$'\t'fda_preflight=partial* ]] \
  && ok "partial-valid output prints a single OK line with FDA_FIELDS appended" \
  || bad "expected single OK line with FDA_FIELDS on same line, got line_count=$line_count out=$out"
rm -rf "$WORK16"

# --- Case 17: stale partial-only ledger before any complete publication is normal ---
WORK17="$(mktemp -d)"
git init -q "$WORK17/repo"
STATE17="$WORK17/repo"
mkdir -p "$STATE17/ledger"
CAPTURED17="$(iso_offset_hours -72)"
write_partial "$STATE17/ledger/topdown-5g.partial.json" "$CAPTURED17" "partial"
echo "{\"status\":\"partial\",\"reason\":\"coverage_incomplete\",\"captured_at\":\"$CAPTURED17\",\"mode\":\"partial\",\"coverage_envelope\":{\"measured_top_level_roots\":5,\"reachable_top_level_roots\":10}}" > "$STATE17/ledger/topdown-5g.status.json"
git -C "$STATE17" add ledger/topdown-5g.partial.json ledger/topdown-5g.status.json
git -C "$STATE17" -c user.email=t@test -c user.name=t commit -q -m "initial partial scan without complete publication"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE17" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 0 && "$out" == OK* && "$out" == *canonical_publication=unpublished* ]] \
  && ok "does not alert on an old partial-only ledger when no complete ledger has ever published" \
  || bad "expected OK unpublished state got rc=$rc out=$out"
rm -rf "$WORK17"

# --- Case 18: stale partial with malformed status and uncommitted canonical stays STALE ---
WORK18="$(mktemp -d)"
git init -q "$WORK18/repo"
STATE18="$WORK18/repo"
mkdir -p "$STATE18/ledger"
CAPTURED18="$(iso_offset_hours -72)"
write_partial "$STATE18/ledger/topdown-5g.partial.json" "$CAPTURED18" "partial"
echo 'not-json' > "$STATE18/ledger/topdown-5g.status.json"
echo '{"captured_at":"bad"}' > "$STATE18/ledger/topdown-5g.json"
git -C "$STATE18" add ledger/topdown-5g.partial.json ledger/topdown-5g.status.json
git -C "$STATE18" -c user.email=t@test -c user.name=t commit -q -m "partial state only"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE18" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "stale partial does not suppress malformed status or an uncommitted canonical file" \
  || bad "expected malformed status STALE with uncommitted canonical, got rc=$rc out=$out"
rm -rf "$WORK18"

# --- Case 19: stale partial with mismatched same-time status remains STALE ---
WORK19="$(mktemp -d)"
git init -q "$WORK19/repo"
STATE19="$WORK19/repo"
mkdir -p "$STATE19/ledger"
CAPTURED19="$(iso_offset_hours -72)"
write_partial "$STATE19/ledger/topdown-5g.partial.json" "$CAPTURED19" "partial"
echo "{\"captured_at\":\"$CAPTURED19\",\"mode\":\"complete\",\"coverage_envelope\":{\"measured_top_level_roots\":5,\"reachable_top_level_roots\":10}}" > "$STATE19/ledger/topdown-5g.status.json"
git -C "$STATE19" add ledger/topdown-5g.partial.json ledger/topdown-5g.status.json
git -C "$STATE19" -c user.email=t@test -c user.name=t commit -q -m "mismatched partial status"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE19" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_reconciliation_mismatch* ]] \
  && ok "stale partial does not suppress same-time status reconciliation mismatch" \
  || bad "expected reconciliation mismatch STALE, got rc=$rc out=$out"
rm -rf "$WORK19"

# --- Case 20: stale partial with empty status metadata cannot claim unpublished ---
WORK20="$(mktemp -d)"
git init -q "$WORK20/repo"
STATE20="$WORK20/repo"
mkdir -p "$STATE20/ledger"
CAPTURED20="$(iso_offset_hours -72)"
write_partial "$STATE20/ledger/topdown-5g.partial.json" "$CAPTURED20" "partial"
echo '{}' > "$STATE20/ledger/topdown-5g.status.json"
git -C "$STATE20" add ledger/topdown-5g.partial.json ledger/topdown-5g.status.json
git -C "$STATE20" -c user.email=t@test -c user.name=t commit -q -m "partial with empty status"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE20" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_malformed* ]] \
  && ok "empty status metadata cannot suppress stale partial-only alert" \
  || bad "expected stale malformed status, got rc=$rc out=$out"
rm -rf "$WORK20"

# --- Case 21: stale partial with status from another capture cannot claim unpublished ---
WORK21="$(mktemp -d)"
git init -q "$WORK21/repo"
STATE21="$WORK21/repo"
mkdir -p "$STATE21/ledger"
CAPTURED21="$(iso_offset_hours -72)"
write_partial "$STATE21/ledger/topdown-5g.partial.json" "$CAPTURED21" "partial"
OTHER_CAPTURED21="$(iso_offset_hours -73)"
echo "{\"captured_at\":\"$OTHER_CAPTURED21\",\"mode\":\"partial\",\"coverage_envelope\":{\"measured_top_level_roots\":5,\"reachable_top_level_roots\":10}}" > "$STATE21/ledger/topdown-5g.status.json"
git -C "$STATE21" add ledger/topdown-5g.partial.json ledger/topdown-5g.status.json
git -C "$STATE21" -c user.email=t@test -c user.name=t commit -q -m "partial with stale status metadata"
out="$(DISK_MAGICIAN_STATE_REPO="$STATE21" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *status_reconciliation_mismatch* ]] \
  && ok "status from another capture cannot suppress stale partial-only alert" \
  || bad "expected stale mismatched metadata, got rc=$rc out=$out"
rm -rf "$WORK21"

# --- Case 22: git history read failure cannot be mistaken for never published ---
WORK22="$(mktemp -d)"
git init -q "$WORK22/repo"
STATE22="$WORK22/repo"
mkdir -p "$STATE22/ledger" "$WORK22/bin"
CAPTURED22="$(iso_offset_hours -72)"
write_partial "$STATE22/ledger/topdown-5g.partial.json" "$CAPTURED22" "partial"
echo "{\"status\":\"partial\",\"reason\":\"coverage_incomplete\",\"captured_at\":\"$CAPTURED22\",\"mode\":\"partial\",\"coverage_envelope\":{\"measured_top_level_roots\":5,\"reachable_top_level_roots\":10}}" > "$STATE22/ledger/topdown-5g.status.json"
git -C "$STATE22" add ledger/topdown-5g.partial.json ledger/topdown-5g.status.json
git -C "$STATE22" -c user.email=t@test -c user.name=t commit -q -m "partial only"
cat > "$WORK22/bin/git" <<'SH'
#!/usr/bin/env bash
exit 128
SH
chmod +x "$WORK22/bin/git"
out="$(PATH="$WORK22/bin:$PATH" DISK_MAGICIAN_STATE_REPO="$STATE22" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* && "$out" == *history_unavailable* ]] \
  && ok "git history read failure fails closed rather than proving unpublished" \
  || bad "expected history failure STALE, got rc=$rc out=$out"
rm -rf "$WORK22"

# --- Case 23: stale partial suppression accepts only valid status metadata ---
for variant in null_status missing_both wrong_types empty_status empty_envelope broken_status_symlink canonical_symlink absent_status fresh_null_status complete_mode; do
  WORK23="$(mktemp -d)"
  git init -q "$WORK23/repo"
  STATE23="$WORK23/repo"
  mkdir -p "$STATE23/ledger"
  if [[ "$variant" == "fresh_null_status" ]]; then
    CAPTURED23="$(iso_offset_hours -1)"
  else
    CAPTURED23="$(iso_offset_hours -72)"
  fi
  write_partial "$STATE23/ledger/topdown-5g.partial.json" "$CAPTURED23" "partial"
  python3 - "$STATE23/ledger/topdown-5g.partial.json" "$STATE23/ledger/topdown-5g.status.json" "$CAPTURED23" "$variant" <<'PY'
import json, pathlib, sys
partial_path, status_path, captured_at, variant = sys.argv[1:]
partial = json.loads(pathlib.Path(partial_path).read_text())
status = {"captured_at": captured_at, "mode": "partial",
          "coverage_envelope": partial["coverage_envelope"]}
if variant == "null_status":
    status_value = None
elif variant == "missing_both":
    partial.pop("mode")
    partial.pop("coverage_envelope")
    status = {"captured_at": captured_at}
    status_value = status
elif variant == "wrong_types":
    partial["mode"] = 7
    partial["coverage_envelope"] = []
    status = {"captured_at": captured_at, "mode": 7, "coverage_envelope": []}
    status_value = status
elif variant == "empty_status":
    status_value = {}
elif variant == "empty_envelope":
    partial["coverage_envelope"] = {}
    status = {"captured_at": captured_at, "mode": "partial", "coverage_envelope": {}}
    status_value = status
elif variant in ("broken_status_symlink", "canonical_symlink"):
    status_value = status
elif variant == "fresh_null_status":
    status_value = None
elif variant == "complete_mode":
    partial["mode"] = "complete"
    status["mode"] = "complete"
    status_value = status
else:
    status_value = status
pathlib.Path(partial_path).write_text(json.dumps(partial))
if variant not in ("absent_status", "broken_status_symlink"):
    pathlib.Path(status_path).write_text(json.dumps(status_value))
PY
  if [[ "$variant" == "broken_status_symlink" ]]; then
    ln -s missing-status.json "$STATE23/ledger/topdown-5g.status.json"
  elif [[ "$variant" == "canonical_symlink" ]]; then
    ln -s missing-canonical.json "$STATE23/ledger/topdown-5g.json"
  fi
  git -C "$STATE23" add ledger/topdown-5g.partial.json
  [[ "$variant" == "absent_status" ]] || git -C "$STATE23" add ledger/topdown-5g.status.json
  git -C "$STATE23" -c user.email=t@test -c user.name=t commit -q -m "partial metadata $variant"
  out="$(DISK_MAGICIAN_STATE_REPO="$STATE23" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
  if [[ "$variant" == "absent_status" ]]; then
    [[ "$rc" -eq 0 && "$out" == OK* && "$out" == *canonical_publication=unpublished* ]] \
      && ok "legacy absent status remains allowed for valid stale partial" \
      || bad "expected absent-status compatibility, got rc=$rc out=$out"
  elif [[ "$variant" == "fresh_null_status" ]]; then
    [[ "$rc" -eq 0 && "$out" == OK* && "$out" == *label=PARTIAL* ]] \
      && ok "fresh partial with legacy null status keeps its existing compatibility behavior" \
      || bad "expected fresh-partial compatibility, got rc=$rc out=$out"
  elif [[ "$variant" == "complete_mode" ]]; then
    [[ "$rc" -eq 0 && "$out" == OK* && "$out" == *canonical_publication=unpublished* ]] \
      && ok "unpublished partial artifacts with producer mode complete remain non-alerting" \
      || bad "expected complete-mode unpublished state, got rc=$rc out=$out"
  else
    [[ "$rc" -eq 1 && "$out" == STALE* ]] \
      && ok "rejects stale partial with $variant metadata" \
      || bad "expected stale $variant metadata rejection, got rc=$rc out=$out"
  fi
  rm -rf "$WORK23"
done

# --- Case 24: shallow Git history cannot prove the canonical ledger never published ---
WORK24="$(mktemp -d)"
git init -q "$WORK24/repo"
STATE24="$WORK24/repo"
mkdir -p "$STATE24/ledger" "$WORK24/bin"
CAPTURED24="$(iso_offset_hours -72)"
write_partial "$STATE24/ledger/topdown-5g.partial.json" "$CAPTURED24" "partial"
echo "{\"status\":\"partial\",\"reason\":\"coverage_incomplete\",\"captured_at\":\"$CAPTURED24\",\"mode\":\"partial\",\"coverage_envelope\":{\"measured_top_level_roots\":5,\"reachable_top_level_roots\":10}}" > "$STATE24/ledger/topdown-5g.status.json"
git -C "$STATE24" add ledger/topdown-5g.partial.json ledger/topdown-5g.status.json
git -C "$STATE24" -c user.email=t@test -c user.name=t commit -q -m "partial in shallow state repo"
REAL_GIT="$(command -v git)"
cat > "$WORK24/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "${3:-}" == "log" ]]; then
  exit 0
fi
if [[ "${3:-}" == "rev-parse" && "${4:-}" == "--is-shallow-repository" ]]; then
  echo true
  exit 0
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$WORK24/bin/git"
out="$(REAL_GIT="$REAL_GIT" PATH="$WORK24/bin:$PATH" DISK_MAGICIAN_STATE_REPO="$STATE24" DISK_MAGICIAN_LEDGER_STALE_HOURS=48 "$SCRIPT" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -eq 1 && "$out" == STALE* ]] \
  && ok "shallow history cannot prove a stale partial was never published" \
  || bad "expected shallow-history STALE, got rc=$rc out=$out"
rm -rf "$WORK24"

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
