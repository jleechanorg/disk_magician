#!/usr/bin/env bash
set -euo pipefail
REPO=${1:?usage: test_discover_cache_stat_portability.sh REPO}
WORK=$(mktemp -d)
FAKE_HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_HOME/small_dir" "$FAKE_BIN"
printf 'sample\n' > "$FAKE_HOME/small_dir/file"
cat > "$FAKE_BIN/stat" <<'STAT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-f" ]]; then
  echo 'GNU stat filesystem output leaked from failed BSD probe'
  exit 1
fi
if [[ "${1:-}" == "-c" ]]; then
  echo 1700000000
  exit 0
fi
exec /usr/bin/stat "$@"
STAT
chmod +x "$FAKE_BIN/stat"
PATH="$FAKE_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" /bin/bash "$REPO/scripts/disk_snapshot.sh" --discover --json >/dev/null
PATH="$FAKE_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" /bin/bash "$REPO/scripts/disk_snapshot.sh" --discover --json > "$WORK/second.json"
python3 - "$WORK/second.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert result['cache_hits'] >= 1, result
PY
