#!/usr/bin/env bash
# tests/test_alert_delivery_slack.sh — alert delivery to a human channel.
#
# Measured 2026-11-16 (jleechanorg/roadmap alerting-delivery-audit-2026-11-16):
# diskm alerts reached no human anywhere. disk_usage_alert.sh wrote its warning
# to stdout, and the installed units sent stdout to a log file and nothing else:
#   - Linux  diskm-usage-alert.service: StandardOutput/Error=append:$HOME/.disk_magician_state/disk-usage-alert.log
#   - macOS  com.jleechan.disk-usage-alert.plist: StandardOutPath=$HOME/Library/Logs/disk-usage-alert.log
# No Slack, no email, no log shipper. jeff-ubuntu's log held 236 WARNING lines
# at the time of measurement, so conditions were firing into a file.
#
# Contract under test: loud alert conditions are POSTed to a Slack webhook when
# one is configured, delivery failures never change the script's exit contract
# (exit 1 still means "an alert fired"), and a silent run posts nothing.
#
# Hermetic: a fake `curl` on PATH records invocations, so no network is touched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ALERT="$REPO_ROOT/scripts/disk_usage_alert.sh"

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }
pass() { echo "PASS: $1"; }

[[ -f "$ALERT" ]] || { echo "FAIL: missing $ALERT"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Fake curl: records argv, optionally fails ─────────────────────────────────
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
{ printf '%s\n' "---CALL---"; printf '%s\n' "$@"; } >> "$FAKE_CURL_LOG"
if [[ "${FAKE_CURL_FAIL:-0}" == "1" ]]; then
  printf 'curl: (7) Failed to connect\n' >&2
  exit 7
fi
printf 'ok\n'
exit 0
EOF
chmod +x "$BIN/curl"
export PATH="$BIN:$PATH"

# ── Fake diskm so only the volume path is exercised ──────────────────────────
cat > "$BIN/disk-magician" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "volume" && "${2:-}" == "path" && "${3:-}" == "scratch" ]]; then
  printf '%s\n' "$FAKE_SCRATCH_PATH"
  exit 0
fi
exit 1
EOF
chmod +x "$BIN/disk-magician"

SCRATCH_DIR="$TMP/scratch"
mkdir -p "$SCRATCH_DIR"
export FAKE_SCRATCH_PATH="$SCRATCH_DIR"
export DISK_MAGICIAN_DISKM_BIN="$BIN/disk-magician"
export DISK_MAGICIAN_STATE_DIR="$TMP/state"
mkdir -p "$DISK_MAGICIAN_STATE_DIR"
# Never touch the operator's real silence marker: this test supplies its own
# HOME so every $HOME-derived path (including the marker) is a temp dir.
OPERATOR_HOME="${HOME}"
REAL_MARKER_PRE="$TMP/real-marker-before"
[[ -f "$OPERATOR_HOME/.disk_magician_alert.silenced" ]] && cp "$OPERATOR_HOME/.disk_magician_alert.silenced" "$REAL_MARKER_PRE"
export HOME="$TMP/home"
mkdir -p "$HOME"

# Force the floor arm to fire so there is something loud to deliver.
FIRING_ENV=(DISK_MAGICIAN_SCRATCH_FLOOR_GB=999999 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=0)
SILENT_ENV=(DISK_MAGICIAN_SCRATCH_FLOOR_GB=0 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=0)

# Args after the log path may be VAR=value assignments or script flags. Split
# them explicitly: passing a flag straight to `env` makes `env` consume it, so
# a "--dry-run" intended for the script silently never reaches it.
run_alert() { # run_alert <curl-log> [VAR=value...] [--script-flag...]; echoes "rc=<n>"
  local logfile="$1"; shift
  local -a envvars=() flags=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --*) flags+=("$arg") ;;
      *=*) envvars+=("$arg") ;;
      *)   flags+=("$arg") ;;
    esac
  done
  local rc
  env FAKE_CURL_LOG="$logfile" "${envvars[@]}" bash "$ALERT" "${flags[@]}" >/dev/null 2>${RUN_ERR:-/dev/null}
  rc=$?
  echo "rc=$rc"
}

curl_calls() { [[ -f "$1" ]] && grep -c -- '---CALL---' "$1" || echo 0; }

# ── 1. A firing alert with a webhook configured is POSTed ────────────────────
LOG1="$TMP/curl-1.log"
res="$(run_alert "$LOG1" "${FIRING_ENV[@]}" DISK_MAGICIAN_ALERT_SLACK_WEBHOOK='https://hooks.slack.com/services/T00/B00/fake')"
[[ "$(curl_calls "$LOG1")" -ge 1 ]] \
  && pass "firing alert posts to the configured Slack webhook" \
  || fail "firing alert did not post to Slack ($res, calls=$(curl_calls "$LOG1"))"

grep -q 'hooks.slack.com' "$LOG1" 2>/dev/null \
  && pass "post targets the configured webhook URL" \
  || fail "post did not use the configured webhook URL"

grep -qE '"(text|blocks)"' "$LOG1" 2>/dev/null \
  && pass "post body carries Slack message content" \
  || fail "post body has no text/blocks field"

# ── 2. Exit contract is preserved: alert fired still means exit 1 ────────────
[[ "$res" == "rc=1" ]] \
  && pass "exit 1 still signals a fired alert after delivery" \
  || fail "delivery changed the exit contract: got $res"

# ── 3. No webhook configured: silent run, no curl, no crash ──────────────────
LOG3="$TMP/curl-3.log"
res="$(run_alert "$LOG3" "${FIRING_ENV[@]}")"
[[ "$(curl_calls "$LOG3")" -eq 0 ]] \
  && pass "no webhook configured means no delivery attempt" \
  || fail "attempted delivery without a configured webhook"

[[ "$res" == "rc=1" ]] \
  && pass "unconfigured-delivery run still honours the exit contract" \
  || fail "unconfigured-delivery run changed exit code: $res"

# ── 4. Delivery failure must not change the signal ───────────────────────────
LOG4="$TMP/curl-4.log"
res="$(run_alert "$LOG4" "${FIRING_ENV[@]}" FAKE_CURL_FAIL=1 DISK_MAGICIAN_ALERT_SLACK_WEBHOOK='https://hooks.slack.com/services/T00/B00/fake')"
[[ "$res" == "rc=1" ]] \
  && pass "failed delivery still exits 1 (alert fired), never masking the condition" \
  || fail "failed delivery changed the exit contract: $res"

# ── 5. Exactly one delivery per run, never a per-arm burst ──────────────────
# A single run can satisfy several arms at once (space, swap, ledger, volume).
# Each must not send its own message: one run, one notification.
LOG5="$TMP/curl-5.log"
res="$(run_alert "$LOG5" "${FIRING_ENV[@]}" DISK_MAGICIAN_ALERT_SLACK_WEBHOOK='https://hooks.slack.com/services/T00/B00/fake')"
calls="$(curl_calls "$LOG5")"
[[ "$calls" -eq 1 ]] \
  && pass "one run performs exactly one delivery regardless of how many arms fired" \
  || fail "expected exactly 1 delivery, got $calls"

# The delivered body must aggregate the whole run, not a single arm: the floor
# arm is what we forced, so its text must be present in the one message.
grep -q 'Scratch volume headroom low' "$LOG5" 2>/dev/null \
  && pass "delivered body carries the actual fired condition" \
  || fail "delivered body is missing the fired condition text"

# ── 6. Silence must suppress delivery too, not just the text ────────────────
SILENCE="$HOME/.disk_magician_alert.silenced"
printf '2026-11-16T00:00:00Z\n' > "$SILENCE"
LOG6="$TMP/curl-6.log"
res="$(run_alert "$LOG6" "${FIRING_ENV[@]}" DISK_MAGICIAN_ALERT_SLACK_WEBHOOK='https://hooks.slack.com/services/T00/B00/fake')"
rm -f "$SILENCE"
[[ "$(curl_calls "$LOG6")" -eq 0 ]] \
  && pass "active silence suppresses delivery as well as text" \
  || fail "silenced run still posted to Slack"


# ── 7. Email delivery when a recipient is configured ────────────────────────
# A fake sendmail records the message it was handed, so a host without a real
# MTA can still prove the email path is wired.
cat > "$BIN/sendmail" <<'EOF'
#!/usr/bin/env bash
cat >> "$FAKE_MAIL_LOG"
printf '\n%s\n' '---SENT---' >> "$FAKE_MAIL_LOG"
exit 0
EOF
chmod +x "$BIN/sendmail"

MAIL7="$TMP/mail-7.log"
LOG7="$TMP/curl-7.log"
res="$(run_alert "$LOG7" "${FIRING_ENV[@]}" \
  FAKE_MAIL_LOG="$MAIL7" \
  DISK_MAGICIAN_ALERT_EMAIL_TO='alerts@example.com')"
[[ -s "$MAIL7" ]] && pass "configured email recipient receives the alert" \
  || fail "no email was handed to sendmail"
grep -q 'Subject: \[diskm\] alert fired on ' "$MAIL7" 2>/dev/null \
  && pass "email carries a host-specific subject" \
  || fail "email subject missing or malformed"
grep -q 'Scratch volume headroom low' "$MAIL7" 2>/dev/null \
  && pass "email body carries the fired condition" \
  || fail "email body missing the fired condition"
grep -q 'To: alerts@example.com' "$MAIL7" 2>/dev/null \
  && pass "email is addressed to the configured recipient" \
  || fail "email recipient header missing"
[[ "$res" == "rc=1" ]] && pass "email delivery preserves the exit contract" \
  || fail "email delivery changed the exit code: $res"

# ── 8. Email failure must not change the signal either ─────────────────────
cat > "$BIN/sendmail" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf 'sendmail: cannot connect to relay\n' >&2
exit 75
EOF
chmod +x "$BIN/sendmail"
LOG8="$TMP/curl-8.log"
res="$(run_alert "$LOG8" "${FIRING_ENV[@]}" DISK_MAGICIAN_ALERT_EMAIL_TO='alerts@example.com')"
[[ "$res" == "rc=1" ]] && pass "failed email delivery still exits 1" \
  || fail "failed email delivery changed the exit contract: $res"

# ── 9. --dry-run must be accepted and must not deliver ──────────────────────
# Regression: the script advertised --dry-run in its usage text and
# deliver_alert honoured DRY_RUN, but no case arm set it. The flag therefore
# hit the default arm and the script exited with "Unknown arg", so a documented
# flag did nothing. Assert acceptance directly (no "Unknown arg") and assert no
# delivery happened.
LOG9="$TMP/curl-9.log"
OUT9="$TMP/out-9.txt"
res="$(RUN_ERR="$OUT9" run_alert "$LOG9" "${FIRING_ENV[@]}" --dry-run \
  DISK_MAGICIAN_ALERT_SLACK_WEBHOOK='https://hooks.slack.com/services/T00/B00/fake')"
! grep -q 'Unknown arg' "$OUT9" \
  && pass "--dry-run is accepted, not rejected as an unknown argument" \
  || fail "--dry-run hit the default arm and was rejected"

[[ "$(curl_calls "$LOG9")" -eq 0 ]] \
  && pass "--dry-run performs no Slack delivery" \
  || fail "--dry-run delivered to Slack ($(curl_calls "$LOG9") calls)"

MAIL9="$TMP/mail-9.log"
res="$(run_alert "$LOG9" "${FIRING_ENV[@]}" --dry-run \
  FAKE_MAIL_LOG="$MAIL9" DISK_MAGICIAN_ALERT_EMAIL_TO='alerts@example.com' 2>/dev/null)"
[[ ! -s "$MAIL9" ]] \
  && pass "--dry-run performs no email delivery" \
  || fail "--dry-run sent email"

# ── 10. This suite must never mutate the operator's real silence marker ─────
# The test isolates HOME, so the script's $HOME-derived marker is a temp path.
REAL_MARKER="$OPERATOR_HOME/.disk_magician_alert.silenced"
if [[ -e "$REAL_MARKER" ]]; then
  cmp -s "$REAL_MARKER" "$TMP/real-marker-before" \
    && pass "operator silence marker left untouched by this suite" \
    || fail "this suite modified the operator's real silence marker"
else
  [[ -e "$REAL_MARKER" ]] && fail "this suite created the operator's real silence marker"
  pass "operator silence marker not created by this suite"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
fi
echo "SOME TESTS FAILED"
exit 1
