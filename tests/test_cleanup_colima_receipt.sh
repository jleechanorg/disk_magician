#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/cmr.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
STATE="$TMP/state"
BIN="$TMP/bin"
mkdir -p "$HOME_DIR/.colima/default" "$HOME_DIR/.colima/_lima" "$STATE" "$BIN"
python3 - "$HOME_DIR/.colima/default/docker.sock" <<'PY'
import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()
PY
cat > "$BIN/docker" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "context show") echo colima ;;
  "context inspect colima --format {{.Endpoints.docker.Host}}") echo "unix://$HOME/.colima/default/docker.sock" ;;
  "info") exit 0 ;;
  "system df") echo 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE' ;;
  "builder prune -af --reserved-space 5g") printf 'Deleted build cache objects:\ncache-id-1\nTotal reclaimed space: 1B\n' ;;
  "image prune -af") printf 'Deleted Images:\nuntagged: example:old\ndeleted: sha256:image1\nTotal reclaimed space: 2B\n' ;;
  "system prune -f") printf 'Deleted Containers:\ncontainer1\nDeleted Networks:\nnetwork1\nDeleted Images:\ndeleted: sha256:image2\nTotal reclaimed space: 3B\n' ;;
  *) echo "unexpected docker args: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$BIN/docker"
HOME="$HOME_DIR" PATH="$BIN:$PATH" DISK_MAGICIAN_STATE_DIR="$STATE" \
  DISK_MAGICIAN_ACTUATOR_TRIGGER=act bash "$ROOT/scripts/cleanup_colima.sh" --clean >/dev/null
python3 - "$STATE/receipts/cleanup_colima.json" <<'PY'
import json,sys
receipt=json.load(open(sys.argv[1]))['last_terminal']
assert receipt['outcome']=='success', receipt
assert receipt['candidates']['removed_count']==5, receipt['candidates']
assert receipt['candidates']['deferred_count']==0, receipt['candidates']
assert receipt['candidates']['interrupted_count']==0, receipt['candidates']
assert receipt['postcondition']['df_delta_bytes'] is not None, receipt['postcondition']
print('PASS: governed Colima receipt counts emitted Docker resource IDs, not df deltas')
PY
