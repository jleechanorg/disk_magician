#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t dm-cursor-lock.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/cursors"
chmod 700 "$HOME"

cat >"$TMP/holder.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
touch "$READY"
sleep 2
SH
chmod +x "$TMP/holder.sh"

cursor_one="$TMP/cursors/one.json"
cursor_two="$TMP/cursors/two.json"
READY="$TMP/ready" HOME="$HOME" python3 "$ROOT/scripts/scratch_lock.py" run \
  --caller cursor-test --script "$TMP/holder.sh" --key "$cursor_one" --args -- &
holder=$!
for _ in {1..50}; do [[ -e "$TMP/ready" ]] && break; sleep 0.02; done
[[ -e "$TMP/ready" ]]

set +e
HOME="$HOME" \
  python3 "$ROOT/scripts/scratch_lock.py" run --caller same-cursor --script /usr/bin/true \
  --key "$TMP/cursors/../cursors/one.json" --args --
same_rc=$?
set -e
[[ "$same_rc" == 75 ]]

cat >"$TMP/reenter.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if python3 "$LOCK_HELPER" verify --fd "$DISKM_CLEANUP_CURSOR_FD" --key "$OTHER_CURSOR"; then
  echo "cursor FD was accepted for a different checkpoint" >&2
  exit 1
fi
source "$LOCK_LIB"
ORIG_ARGS=()
scratch_cursor_lock_acquire reenter "$CURSOR"
printf 'reentered\n' >> "$TRACE"
SH
chmod +x "$TMP/reenter.sh"
LOCK_HELPER="$ROOT/scripts/scratch_lock.py" LOCK_LIB="$ROOT/scripts/lib/scratch_lock.sh" \
  CURSOR="$cursor_two" OTHER_CURSOR="$cursor_one" TRACE="$TMP/reenter.log" HOME="$HOME" \
  python3 "$ROOT/scripts/scratch_lock.py" run --caller other-cursor \
  --script "$TMP/reenter.sh" --key "$cursor_two" --args --
[[ "$(cat "$TMP/reenter.log")" == reentered ]]
wait "$holder"
git_bin="$(command -v git)"
git_check="$(GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=tool.marker GIT_CONFIG_VALUE_0=preserve \
  GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=true \
  python3 "$ROOT/scripts/scratch_lock.py" run --caller git-test --script "$git_bin" \
  --key "$cursor_two" --args -- config --get core.fsmonitor)"
[[ "$git_check" == false ]]
echo "PASS: separate cursors proceed while the same cursor defers"
