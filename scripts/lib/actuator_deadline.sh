# shellcheck shell=bash
# Cooperative deadline and resumable-enumeration helpers for governed actuators.

ACT_DEADLINE_AT="${ACT_DEADLINE_AT:-}"
ACT_CURSOR="${ACT_CURSOR:-}"
ACT_ARGS=()

act_parse_deadline_args() {
  ACT_DEADLINE_AT="${ACT_DEADLINE_AT:-}"
  ACT_CURSOR="${ACT_CURSOR:-}"
  ACT_ARGS=()
  while (($#)); do
    case "$1" in
      --deadline-at)
        (($# >= 2)) || { echo "missing value for --deadline-at" >&2; return 2; }
        [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "invalid monotonic deadline" >&2; return 2; }
        ACT_DEADLINE_AT="$2"
        shift 2
        ;;
      --cursor)
        (($# >= 2)) || { echo "missing value for --cursor" >&2; return 2; }
        [[ -n "$2" ]] || { echo "empty cursor path" >&2; return 2; }
        ACT_CURSOR="$2"
        shift 2
        ;;
      *)
        ACT_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

act_mono_now() {
  python3 -c 'import time; print(f"{time.monotonic():.6f}")'
}

# Returns success only if one full unit fits before the soft deadline.
act_unit_fits() {
  local unit_budget="$1" deadline="${ACT_DEADLINE_AT:-}"
  [[ "$unit_budget" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 2
  [[ -n "$deadline" ]] || return 0
  python3 - "$deadline" "$unit_budget" <<'PY'
import sys, time
try:
    deadline, budget = map(float, sys.argv[1:])
except (TypeError, ValueError):
    sys.exit(2)
sys.exit(0 if time.monotonic() + budget <= deadline else 1)
PY
}

# Cursor JSON is {"schema":1,"source":key,"items":[...],"next_index":N}.
# Emit one compact JSON object so paths containing whitespace/newlines stay exact.
act_cursor_load() {
  local path="$1" source="$2"
  python3 - "$path" "$source" <<'PY'
import json, os, sys
path, source = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as f: value = json.load(f)
except FileNotFoundError:
    value = {"schema": 1, "source": source, "items": [], "next_index": 0}
except (OSError, ValueError):
    sys.exit(2)
if (not isinstance(value, dict) or value.get("schema") != 1 or
    value.get("source") != source or not isinstance(value.get("items"), list) or
    any(not isinstance(item, str) for item in value["items"]) or
    not isinstance(value.get("next_index"), int) or isinstance(value["next_index"], bool) or
    not 0 <= value["next_index"] <= len(value["items"])):
    sys.exit(2)
print(json.dumps(value, separators=(",", ":")))
PY
}

act_cursor_save() {
  local path="$1" source="$2" items_json="$3" next_index="$4"
  printf '%s' "$items_json" | python3 -c '
import json, os, sys, tempfile
path, source, raw_index = sys.argv[1:]
raw_items = sys.stdin.read()
try:
    items, index = json.loads(raw_items), int(raw_index)
except (ValueError, TypeError):
    sys.exit(2)
if (not isinstance(items, list) or any(not isinstance(x, str) for x in items) or
    str(index) != raw_index or not 0 <= index <= len(items)):
    sys.exit(2)
parent = os.path.dirname(os.path.abspath(path))
os.makedirs(parent, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".act-cursor-", dir=parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"schema": 1, "source": source, "items": items, "next_index": index}, f,
                  separators=(",", ":"))
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
' "$path" "$source" "$next_index"
}

# act_cursor_reset_once <path> <source> — the ONE reset point at the START of a
# governed invocation. A fully-consumed cursor (next_index at/past the last
# item) means the previous pass finished; clear it so the next pass revisits
# every candidate — including one that was deferred earlier — instead of
# reporting `kept:cursor-complete` forever. Called exactly once per invocation,
# NEVER per candidate (a per-candidate reset loses the resume list and is the
# Cursor review 5/6 defect). Returns 0 (nothing to do), 2 (invalid/corrupt
# cursor), or 3 (reset could not be persisted); callers fail closed on non-zero.
act_cursor_reset_once() {
  local path="$1" source="$2" state complete
  state="$(act_cursor_load "$path" "$source")" || return 2
  complete="$(printf '%s' "$state" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(1 if d["next_index"] >= len(d["items"]) else 0)')" || return 2
  [[ "$complete" == 1 ]] || return 0
  act_cursor_save "$path" "$source" "[]" 0 || return 3
}
