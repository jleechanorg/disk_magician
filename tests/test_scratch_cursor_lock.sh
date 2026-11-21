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
  --caller cursor-test --script "$TMP/holder.sh" --scope cursor --key "$cursor_one" --args -- &
holder=$!
for _ in {1..50}; do [[ -e "$TMP/ready" ]] && break; sleep 0.02; done
[[ -e "$TMP/ready" ]]

set +e
HOME="$HOME" DISK_MAGICIAN_SCRATCH_LOCK_WAIT_SECONDS=0 \
  python3 "$ROOT/scripts/scratch_lock.py" run --caller same-cursor --script /usr/bin/true \
  --scope cursor --key "$TMP/cursors/../cursors/one.json" --args --
same_rc=$?
set -e
[[ "$same_rc" == 75 ]]

cat >"$TMP/reenter.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if python3 "$LOCK_HELPER" verify --fd "$DISK_MAGICIAN_SCRATCH_LOCK_FD"; then
  echo "cursor lock was accepted as the global cleanup lock" >&2
  exit 1
fi
source "$LOCK_LIB"
ORIG_ARGS=()
scratch_cursor_lock_acquire reenter "$CURSOR"
printf 'reentered\n' >> "$TRACE"
SH
chmod +x "$TMP/reenter.sh"
LOCK_HELPER="$ROOT/scripts/scratch_lock.py" LOCK_LIB="$ROOT/scripts/lib/scratch_lock.sh" \
  CURSOR="$cursor_two" TRACE="$TMP/reenter.log" HOME="$HOME" \
  python3 "$ROOT/scripts/scratch_lock.py" run --caller other-cursor \
  --script "$TMP/reenter.sh" --scope cursor --key "$cursor_two" --args --
[[ "$(cat "$TMP/reenter.log")" == reentered ]]
wait "$holder"
echo "PASS: separate cursors proceed while the same cursor defers"
