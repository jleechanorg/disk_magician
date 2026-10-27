#!/usr/bin/env bash
set -euo pipefail
REPO=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
WORK=$(mktemp -d)
FAKE_HOME="$WORK/home"
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_HOME/small_dir" "$FAKE_BIN"
printf 'sample\n' > "$FAKE_HOME/small_dir/file"
cat > "$FAKE_BIN/stat" <<'STAT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-f" ]]; then echo 111; exit 1; fi
if [[ "${1:-}" == "-c" ]]; then echo 222; exit 0; fi
exec /usr/bin/stat "$@"
STAT
chmod +x "$FAKE_BIN/stat"
PATH="$FAKE_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" /bin/bash "$REPO/scripts/disk_snapshot.sh" --discover --json >/dev/null
python3 - "$FAKE_HOME/.disk_magician_state/discover_cache.json" <<'PY'
import json, sys
cache = json.load(open(sys.argv[1]))
assert next(v for p, v in cache.items() if p.endswith('/small_dir'))['mtime'] == 222, cache
PY
PATH="$FAKE_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" /bin/bash "$REPO/scripts/disk_snapshot.sh" --discover --json > "$WORK/second.json"
python3 - "$WORK/second.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert result['cache_hits'] >= 1, result
PY
cat > "$FAKE_BIN/stat" <<'STAT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-f" ]]; then echo 'not a timestamp'; exit 1; fi
if [[ "${1:-}" == "-c" ]]; then echo 333; exit 1; fi
exec /usr/bin/stat "$@"
STAT
PATH="$FAKE_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" /bin/bash "$REPO/scripts/disk_snapshot.sh" --discover --json >/dev/null
python3 - "$FAKE_HOME/.disk_magician_state/discover_cache.json" <<'PY'
import json, sys
cache = json.load(open(sys.argv[1]))
assert next(v for p, v in cache.items() if p.endswith('/small_dir'))['mtime'] == 0, cache
PY
printf 'new child\n' > "$FAKE_HOME/small_dir/child"
PATH="$FAKE_BIN:/usr/bin:/bin" HOME="$FAKE_HOME" /bin/bash "$REPO/scripts/disk_snapshot.sh" --discover --json > "$WORK/after-child.json"
python3 - "$WORK/after-child.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert result['cache_misses'] >= 1, result
PY
