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
# Hermetic PATH. The script prefers msmtp over sendmail, so inheriting the host
# PATH means a machine with a configured msmtp could bypass our stubs and send
# REAL mail from a test run. Allowlisting whole DIRECTORIES is not enough:
# dirname(df) may be /bin, which admits /bin/msmtp sitting beside it. Link only
# the individual executables we need into one fresh directory.
HERMETIC_TOOLS="bash sed grep cat mktemp rm printf dirname hostname python3 df awk head tr date ls wc sleep uname mkdir readlink chmod cp mv ln cmp touch test true false env sort uniq cut tee"
# The email path requires a timer; its absence is a separate, deliberate test case.
TIMER_REAL="$(command -v timeout 2>/dev/null || true)"
TOOLBIN="$TMP/toolbin"
mkdir -p "$TOOLBIN"
missing_tools=""
for tool in $HERMETIC_TOOLS; do
  real="$(command -v "$tool" 2>/dev/null)" || { missing_tools="${missing_tools:+$missing_tools }$tool"; continue; }
  ln -sf "$real" "$TOOLBIN/$tool" 2>/dev/null || missing_tools="${missing_tools:+$missing_tools }$tool"
done
# Keep the timer in its own directory so the no-timer case can omit it by PATH
# alone while every other tool stays available.
TIMERBIN="$TMP/timerbin"
mkdir -p "$TIMERBIN"
[[ -n "$TIMER_REAL" ]] && ln -sf "$TIMER_REAL" "$TIMERBIN/timeout" 2>/dev/null || true
HERMETIC_PATH="$BIN:$TIMERBIN:$TOOLBIN"
NOTIMER_PATH="$BIN:$TOOLBIN"
export PATH="$HERMETIC_PATH"

# Prove the premise, and ABORT rather than merely flagging it: continuing would
# run the email fixtures against a real mailer, which is the hazard itself.
if command -v msmtp >/dev/null 2>&1 || command -v sendmail >/dev/null 2>&1; then
  echo "FAIL: a host mailer is reachable on the hermetic PATH; aborting before any alert runs"
  echo "SOME TESTS FAILED"
  exit 1
fi
# Also verify by direct directory listing, so a PATH-resolved miss cannot hide it.
for sneaky in "$TOOLBIN/msmtp" "$TOOLBIN/sendmail"; do
  if [[ -e "$sneaky" ]]; then
    echo "FAIL: $sneaky exists; a mailer is reachable. Aborting."
    echo "SOME TESTS FAILED"
    exit 1
  fi
done

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
  # Bash 3.2 (macOS) treats "${arr[@]}" as unbound when the array is empty
  # under set -u, and the aggregate runner sets that. Seed a no-op so both
  # arrays are always safe to expand, and keep the expansions guarded.
  local rc
  env FAKE_CURL_LOG="$logfile" ${envvars[@]+"${envvars[@]}"} \
    bash "$ALERT" ${flags[@]+"${flags[@]}"} >/dev/null 2>${RUN_ERR:-/dev/null}
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

# ── 11. A curl-level failure must not abort the script ─────────────────────
# Regression: on the curl-failure path the handler read an undeclared variable,
# so under set -u the script died with "response: unbound variable" BEFORE
# printing the disk warning. Exit 1 then looked like the normal fired-alert code
# and hid the crash. Assert the warning still prints and the diagnostic names it.
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl: (7) Failed to connect\n' >&2
exit 7
EOF
chmod +x "$BIN/curl"
LOG11="$TMP/curl-11.log"; ERR11="$TMP/err-11.txt"; OUT11="$TMP/out-11.txt"
res="$(RUN_ERR="$ERR11" run_alert "$LOG11" "${FIRING_ENV[@]}" \
  DISK_MAGICIAN_ALERT_SLACK_WEBHOOK='https://hooks.slack.com/services/T00/B00/fake')"
! grep -q 'unbound variable' "$ERR11" \
  && pass "curl failure does not trigger an unbound-variable abort" \
  || fail "curl failure aborted the script: $(grep 'unbound variable' "$ERR11" | head -1)"
grep -q 'slack delivery FAILED' "$ERR11" \
  && pass "curl failure is reported as a delivery failure with detail" \
  || fail "curl failure produced no delivery-failure diagnostic"

# The whole point of the original bug: the local warning must still be emitted,
# and it must be emitted BEFORE any delivery attempt so a slow or wedged
# delivery path cannot delay it. Assert ordering, not mere presence: both
# orderings look identical once the run completes.
awk '/WARNING/{w=NR} /slack delivery/{d=NR} END{exit !(w && d && w<d)}' "$ERR11" \
  && pass "local warning is emitted before the delivery attempt" \
  || fail "local warning did not precede delivery (or was lost)"

# ── 12. A 200 with a rejection body must not be reported as delivered ──────
# Slack's webhook answers the literal body "ok" on acceptance; a 200 carrying
# an error string is a rejection. An empty 200 must also fail closed.
make_curl() { # make_curl <status> <body>
  cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do case "\$prev" in -o) out="\$a";; esac; prev="\$a"; done
printf '%s' '$2' > "\$out"
printf '%s' '$1'
EOF
  chmod +x "$BIN/curl"
}
for case in "200|ok" "200|invalid_payload" "200|"; do
  status="${case%%|*}"; body="${case#*|}"
  make_curl "$status" "$body"
  LOGX="$TMP/curl-ack-$status-${body:-empty}.log"; ERRX="$TMP/err-ack-$status-${body:-empty}.txt"
  RUN_ERR="$ERRX" run_alert "$LOGX" "${FIRING_ENV[@]}" \
    DISK_MAGICIAN_ALERT_SLACK_WEBHOOK='https://hooks.slack.com/services/T00/B00/fake' >/dev/null
  if [[ "$body" == "ok" ]]; then
    ! grep -q 'NOT acknowledged\|FAILED' "$ERRX" \
      && pass "HTTP 200 with body 'ok' is accepted" \
      || fail "an acknowledged 200 was reported as a problem"
  else
    grep -q 'NOT acknowledged' "$ERRX" \
      && pass "HTTP 200 with body '${body:-empty}' is NOT reported as delivered" \
      || fail "a 200 with body '${body:-empty}' was silently accepted"
  fi
done

# ── 13. Email must fail closed when no timer is available ──────────────────
# Without a 'timeout' binary the MTA call was unbounded, so a wedged relay could
# block the alert job forever. NOTIMER_PATH has every tool the script needs but
# no timer. Verify the premise instead of assuming it.
if PATH="$NOTIMER_PATH" command -v timeout >/dev/null 2>&1; then
  echo "SKIP: a timer is reachable on NOTIMER_PATH; case cannot be exercised"
else
  ERR13="$TMP/err-13.txt"
  before13="$TMP/mail-temps-before13"
  after13="$TMP/mail-temps-after13"
  ls "${TMPDIR:-/tmp}"/diskm-alert-* 2>/dev/null | wc -l | tr -d ' ' > "$before13"
  env PATH="$NOTIMER_PATH" FAKE_CURL_LOG="$TMP/curl-13.log" \
    HOME="$HOME" FAKE_SCRATCH_PATH="$SCRATCH_DIR" \
    DISK_MAGICIAN_DISKM_BIN="$BIN/disk-magician" \
    DISK_MAGICIAN_STATE_DIR="$DISK_MAGICIAN_STATE_DIR" \
    DISK_MAGICIAN_SCRATCH_FLOOR_GB=999999 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=0 \
    DISK_MAGICIAN_ALERT_EMAIL_TO='alerts@example.com' \
    bash "$ALERT" >/dev/null 2>"$ERR13" || true
  ls "${TMPDIR:-/tmp}"/diskm-alert-* 2>/dev/null | wc -l | tr -d ' ' > "$after13"
  grep -q 'no .timeout. command' "$ERR13" \
    && pass "email fails closed with a diagnostic when no timer is available" \
    || fail "email did not fail closed without a timer"
  [[ "$(cat "$after13")" -le "$(cat "$before13")" ]] \
    && pass "no-timer path creates no mail temp file" \
    || fail "no-timer path created $(( $(cat "$after13") - $(cat "$before13") )) mail temp file(s)"
fi

# ── 14. --status reports configuration without leaking destinations ─────────
OUT14="$(DISK_MAGICIAN_ALERT_SLACK_WEBHOOK='https://hooks.slack.com/services/SECRETXYZ' \
  DISK_MAGICIAN_ALERT_EMAIL_TO='secret@example.com' \
  bash "$ALERT" --status 2>/dev/null)"
grep -q 'Slack delivery configured: YES' <<<"$OUT14" \
  && pass "--status reports Slack delivery as configured" \
  || fail "--status omits Slack delivery state"
grep -q 'Email delivery configured: YES' <<<"$OUT14" \
  && pass "--status reports email delivery as configured" \
  || fail "--status omits email delivery state"
! grep -q 'SECRETXYZ\|secret@example.com' <<<"$OUT14" \
  && pass "--status never echoes destination values" \
  || fail "--status leaked a destination value"

# ── 15. A TERM-ignoring MTA must still be hard-bounded ──────────────────────
# Plain `timeout` sends TERM only. An MTA that ignores TERM outlived its budget
# (measured elsewhere: 2.23s actual against a 0.2s budget), so the bound has to
# include a KILL deadline. Assert wall clock, not just that timeout was invoked.
HARDMTA="$TMP/bin-hardmta"
mkdir -p "$HARDMTA"
cp "$BIN/curl" "$HARDMTA/curl" 2>/dev/null || true
cat > "$HARDMTA/sendmail" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
cat > /dev/null
sleep 8
EOF
chmod +x "$HARDMTA/sendmail"
cp "$BIN/disk-magician" "$HARDMTA/disk-magician" 2>/dev/null || true
chmod +x "$HARDMTA/disk-magician" 2>/dev/null || true
START15=$(date +%s)
env PATH="$HARDMTA:$HERMETIC_PATH" FAKE_CURL_LOG="$TMP/curl-15.log" \
  HOME="$HOME" FAKE_SCRATCH_PATH="$SCRATCH_DIR" \
  DISK_MAGICIAN_DISKM_BIN="$HARDMTA/disk-magician" \
  DISK_MAGICIAN_STATE_DIR="$DISK_MAGICIAN_STATE_DIR" \
  DISK_MAGICIAN_SCRATCH_FLOOR_GB=999999 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=0 \
  DISK_MAGICIAN_ALERT_EMAIL_TO='alerts@example.com' \
  DISK_MAGICIAN_ALERT_EMAIL_TIMEOUT_SEC=1 DISK_MAGICIAN_ALERT_EMAIL_KILL_GRACE_SEC=1 \
  bash "$ALERT" >/dev/null 2>&1 || true
ELAPSED15=$(( $(date +%s) - START15 ))
[[ "$ELAPSED15" -lt 8 ]] \
  && pass "a TERM-ignoring MTA is hard-killed inside its budget (${ELAPSED15}s < 8s)" \
  || fail "TERM-ignoring MTA outlived its budget (${ELAPSED15}s)"

# ── 16. A Slack failure must not suppress the email attempt ────────────────
CHAN_BIN="$TMP/bin-chan"
mkdir -p "$CHAN_BIN"
cat > "$CHAN_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl: (7) Failed to connect\n' >&2
exit 7
EOF
chmod +x "$CHAN_BIN/curl"
cat > "$CHAN_BIN/sendmail" <<'EOF'
#!/usr/bin/env bash
cat >> "$CHAN_MAIL_LOG"
exit 0
EOF
chmod +x "$CHAN_BIN/sendmail"
cp "$BIN/disk-magician" "$CHAN_BIN/disk-magician" 2>/dev/null || true
chmod +x "$CHAN_BIN/disk-magician" 2>/dev/null || true
MAIL16="$TMP/mail-16.log"
env PATH="$CHAN_BIN:$HERMETIC_PATH" CHAN_MAIL_LOG="$MAIL16" FAKE_CURL_LOG="$TMP/curl-16.log" \
  HOME="$HOME" FAKE_SCRATCH_PATH="$SCRATCH_DIR" \
  DISK_MAGICIAN_DISKM_BIN="$CHAN_BIN/disk-magician" \
  DISK_MAGICIAN_STATE_DIR="$DISK_MAGICIAN_STATE_DIR" \
  DISK_MAGICIAN_SCRATCH_FLOOR_GB=999999 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=0 \
  DISK_MAGICIAN_ALERT_SLACK_WEBHOOK='https://hooks.slack.com/services/T00/B00/fake' \
  DISK_MAGICIAN_ALERT_EMAIL_TO='alerts@example.com' \
  bash "$ALERT" >/dev/null 2>&1 || true
[[ -s "$MAIL16" ]] \
  && pass "email is still attempted after a Slack delivery failure" \
  || fail "a Slack failure suppressed the email attempt"

# ── 17. The host's own mailer must never be invoked ────────────────────────
# The script prefers msmtp over sendmail. A developer machine with a configured
# msmtp would otherwise bypass these fakes and could attempt REAL delivery from
# a test run. Plant an instrumented msmtp on the inherited PATH, confirm the
# hermetic PATH cannot see it, and assert it is never called.
HOSTMAIL="$TMP/host-mta"
mkdir -p "$HOSTMAIL"
cat > "$HOSTMAIL/msmtp" <<'EOF'
#!/usr/bin/env bash
echo invoked >> "$HOST_MTA_SENTINEL"
cat > /dev/null
exit 0
EOF
chmod +x "$HOSTMAIL/msmtp"
SENTINEL="$TMP/host-mta-invoked.log"
: > "$SENTINEL"

# With the hermetic PATH active, the planted mailer must not be resolvable.
if PATH="$HERMETIC_PATH" command -v msmtp >/dev/null 2>&1; then
  fail "the host mailer is reachable on the hermetic PATH"
else
  pass "hermetic PATH cannot resolve the host mailer"
fi

# Our fixtures must provide BOTH mailers so the script's msmtp preference can
# never reach past us to a host binary. Shadow the planted one by putting $BIN
# first and adding an msmtp stub alongside the sendmail stub.
cat > "$BIN/msmtp" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 0
EOF
chmod +x "$BIN/msmtp"
env PATH="$BIN:$HOSTMAIL:$HERMETIC_PATH" HOST_MTA_SENTINEL="$SENTINEL" \
  FAKE_CURL_LOG="$TMP/curl-17.log" HOME="$HOME" FAKE_SCRATCH_PATH="$SCRATCH_DIR" \
  DISK_MAGICIAN_DISKM_BIN="$BIN/disk-magician" \
  DISK_MAGICIAN_STATE_DIR="$DISK_MAGICIAN_STATE_DIR" \
  DISK_MAGICIAN_SCRATCH_FLOOR_GB=999999 DISK_MAGICIAN_SCRATCH_FLOOR_PCT=0 \
  DISK_MAGICIAN_ALERT_EMAIL_TO='alerts@example.com' \
  bash "$ALERT" >/dev/null 2>&1 || true
[[ ! -s "$SENTINEL" ]] \
  && pass "a full run never invokes the host's mailer" \
  || fail "the host mailer was invoked $(( $(wc -l < "$SENTINEL") )) time(s) from a test run"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL PASS"
  exit 0
fi
echo "SOME TESTS FAILED"
exit 1
