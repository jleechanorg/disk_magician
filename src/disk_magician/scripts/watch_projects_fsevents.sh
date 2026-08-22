#!/usr/bin/env bash
# watch_projects_fsevents.sh — Real-time filesystem event watcher for ~/projects/ (bead disk_magician-qq1).
#
# Streams directory events (creations, deletions, modifications) for ~/projects/
# to ~/.local/state/fsevents-projects.log with ISO8601 timestamps and event flags.
#
# Uses `fswatch` (FSEvents on macOS / inotify on Linux) when available, or falls back
# to a lightweight stat/scandir polling watcher.
#
# Rotates logs daily and retains 7 days of archives.
#
# Usage: watch_projects_fsevents.sh [options]
#   --watch-dir <path>       Directory to watch (default: $HOME/projects)
#   --log-file <path>        Log file destination (default: $HOME/.local/state/fsevents-projects.log)
#   --state-file <path>      State cache file for polling fallback (default: $HOME/.local/state/fsevents-projects.state.json)
#   --keep-days <days>       Retention days for rotated logs (default: 7)
#   --max-bytes <bytes>      Max log size before size rotation (default: 16777216 = 16MB)
#   --poll-interval <sec>    Poll interval for fallback watcher in seconds (default: 2)
#   --once                   Single scan against state file, log changes, and exit
#   --rotate                 Perform log rotation and pruning now, then exit
#   --status                 Print current configuration, backend, log stats, and exit
#   -h, --help               Show this help message
set -euo pipefail

WATCH_DIR="${WATCH_DIR:-$HOME/projects}"
LOG_FILE="${LOG_FILE:-$HOME/.local/state/fsevents-projects.log}"
STATE_FILE="${STATE_FILE:-$HOME/.local/state/fsevents-projects.state.json}"
KEEP_DAYS="${KEEP_DAYS:-7}"
MAX_BYTES="${MAX_BYTES:-16777216}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
MODE="watch"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch-dir)      WATCH_DIR="$2"; shift 2 ;;
    --log-file)       LOG_FILE="$2"; shift 2 ;;
    --state-file)     STATE_FILE="$2"; shift 2 ;;
    --keep-days)      KEEP_DAYS="$2"; shift 2 ;;
    --max-bytes)      MAX_BYTES="$2"; shift 2 ;;
    --poll-interval)  POLL_INTERVAL="$2"; shift 2 ;;
    --once)           MODE="once"; shift ;;
    --rotate)         MODE="rotate"; shift ;;
    --status)         MODE="status"; shift ;;
    -h|--help)
      sed -n '2,19p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

detect_backend() {
  if command -v fswatch >/dev/null 2>&1; then
    echo "fswatch"
  else
    echo "python-stat-fallback"
  fi
}

BACKEND="$(detect_backend)"

if [[ "$MODE" == "status" ]]; then
  echo "Watch directory:   $WATCH_DIR (exists: $([[ -d "$WATCH_DIR" ]] && echo YES || echo NO))"
  echo "Log file:          $LOG_FILE (exists: $([[ -f "$LOG_FILE" ]] && echo YES || echo NO))"
  echo "State file:        $STATE_FILE"
  echo "Backend:           $BACKEND"
  echo "Retention days:    $KEEP_DAYS"
  echo "Max log size:      $MAX_BYTES bytes ($(( MAX_BYTES / 1024 / 1024 )) MB)"
  echo "Poll interval:     ${POLL_INTERVAL}s"
  if [[ -f "$LOG_FILE" ]]; then
    size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    echo "Current log size:  ${size} bytes (${lines} lines)"
  fi
  exit 0
fi

# Ensure directories exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$STATE_FILE")"
mkdir -p "$WATCH_DIR"

rotate_logs() {
  python3 - "$LOG_FILE" "$KEEP_DAYS" "$MAX_BYTES" <<'PY'
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

log_path = Path(sys.argv[1])
keep_days = int(sys.argv[2])
max_bytes = int(sys.argv[3])
log_dir = log_path.parent
base_name = log_path.name

if not log_dir.exists():
    sys.exit(0)

now = time.time()
max_age_seconds = keep_days * 86400

# 1. Prune expired archives older than keep_days
for item in log_dir.glob(f"{base_name}.*"):
    if item.name.endswith(".state.json"):
        continue
    try:
        mtime = item.stat().st_mtime
        if now - mtime > max_age_seconds:
            item.unlink()
    except OSError:
        pass

# 2. Check if main log needs rotation (size or date rollover)
if not log_path.exists() or log_path.stat().st_size == 0:
    sys.exit(0)

file_stat = log_path.stat()
file_size = file_stat.st_size
file_mtime = file_stat.st_mtime

file_day = datetime.fromtimestamp(file_mtime, timezone.utc).strftime("%Y-%m-%d")
current_day = datetime.now(timezone.utc).strftime("%Y-%m-%d")

needs_rotation = (file_size >= max_bytes) or (file_day != current_day)

if needs_rotation:
    archive_name = f"{base_name}.{file_day}"
    archive_path = log_dir / archive_name
    
    # If date-based archive already exists, add index suffix
    counter = 1
    while archive_path.exists():
        archive_path = log_dir / f"{base_name}.{file_day}.{counter}"
        counter += 1
        
    try:
        log_path.rename(archive_path)
    except OSError:
        pass

# 3. Cap total archives to keep_days
archives = sorted(
    [p for p in log_dir.glob(f"{base_name}.*") if not p.name.endswith(".state.json")],
    key=lambda p: p.stat().st_mtime if p.exists() else 0
)
while len(archives) > keep_days:
    oldest = archives.pop(0)
    try:
        oldest.unlink()
    except OSError:
        pass
PY
}

if [[ "$MODE" == "rotate" ]]; then
  rotate_logs
  echo "Log rotation completed for $LOG_FILE (retention: ${KEEP_DAYS} days)."
  exit 0
fi

# Fallback / Python monitor engine
run_python_watcher() {
  local mode="$1"
  python3 - "$WATCH_DIR" "$LOG_FILE" "$STATE_FILE" "$KEEP_DAYS" "$MAX_BYTES" "$POLL_INTERVAL" "$mode" <<'PY'
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

watch_dir = Path(sys.argv[1]).resolve()
log_file = Path(sys.argv[2]).resolve()
state_file = Path(sys.argv[3]).resolve()
keep_days = int(sys.argv[4])
max_bytes = int(sys.argv[5])
poll_interval = float(sys.argv[6])
mode = sys.argv[7]

EXCLUDE_NAMES = {".git", "node_modules", "venv", ".venv", "__pycache__", ".pytest_cache", ".ruff_cache"}

def scan_tree(root: Path, max_depth: int = 4) -> dict:
    """Fast shallow/bounded scan of the watch directory."""
    entries = {}
    if not root.exists():
        return entries
    
    root_str = str(root)
    for dirpath, dirnames, filenames in os.walk(root_str, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root_str)
        depth = 0 if rel_dir == "." else len(Path(rel_dir).parts)
        
        # Exclude internal deep caches from recursion but note their directory
        dirnames[:] = [d for d in dirnames if d not in EXCLUDE_NAMES and not d.startswith(".tmp")]
        if depth >= max_depth:
            dirnames[:] = []
            
        for d in dirnames:
            p = os.path.join(dirpath, d)
            try:
                st = os.stat(p)
                entries[p] = {"is_dir": True, "mtime": int(st.st_mtime_ns), "size": st.st_size}
            except OSError:
                continue
                
        for f in filenames:
            p = os.path.join(dirpath, f)
            try:
                st = os.stat(p)
                entries[p] = {"is_dir": False, "mtime": int(st.st_mtime_ns), "size": st.st_size}
            except OSError:
                continue
    return entries

def format_event(path: str, flags: str, now_ts: str) -> str:
    return f"{now_ts} {path} {flags}"

def emit_events(events: list[str]) -> None:
    if not events:
        return
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a", encoding="utf-8") as f:
        for ev in events:
            f.write(ev + "\n")
            print(ev, flush=True)

def diff_scans(old_entries: dict, new_entries: dict, now_ts: str) -> list[str]:
    events = []
    old_keys = set(old_entries.keys())
    new_keys = set(new_entries.keys())
    
    # Created
    for p in sorted(new_keys - old_keys):
        meta = new_entries[p]
        flag = "Created IsDir" if meta["is_dir"] else "Created IsFile"
        events.append(format_event(p, flag, now_ts))
        
    # Removed
    for p in sorted(old_keys - new_keys):
        meta = old_entries[p]
        flag = "Removed IsDir" if meta["is_dir"] else "Removed IsFile"
        events.append(format_event(p, flag, now_ts))
        
    # Modified
    for p in sorted(old_keys & new_keys):
        old_m = old_entries[p]
        new_m = new_entries[p]
        if old_m["mtime"] != new_m["mtime"] or old_m["size"] != new_m["size"]:
            flag = "Updated IsDir" if new_m["is_dir"] else "Updated IsFile"
            events.append(format_event(p, flag, now_ts))
            
    return events

# Load previous state if available
previous_state = {}
state_file_existed = state_file.exists()
if state_file_existed:
    try:
        with state_file.open("r", encoding="utf-8") as f:
            previous_state = json.load(f)
    except Exception:
        previous_state = {}

if mode == "once":
    current_scan = scan_tree(watch_dir)
    now_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if state_file_existed:
        events = diff_scans(previous_state, current_scan, now_ts)
        emit_events(events)
    # Save state
    state_file.parent.mkdir(parents=True, exist_ok=True)
    with state_file.open("w", encoding="utf-8") as f:
        json.dump(current_scan, f)
    sys.exit(0)

# Continuous watch loop
current_state = scan_tree(watch_dir)
# If no state file, seed with current
if not previous_state:
    previous_state = current_state
    state_file.parent.mkdir(parents=True, exist_ok=True)
    with state_file.open("w", encoding="utf-8") as f:
        json.dump(previous_state, f)

last_rotate_day = datetime.now(timezone.utc).strftime("%Y-%m-%d")

while True:
    time.sleep(poll_interval)
    now = datetime.now(timezone.utc)
    now_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    today = now.strftime("%Y-%m-%d")
    
    # Check date rotation daily
    if today != last_rotate_day:
        last_rotate_day = today
        # Run rotation logic
        if log_file.exists() and log_file.stat().st_size > 0:
            archive = log_file.parent / f"{log_file.name}.{today}"
            try:
                log_file.rename(archive)
            except OSError:
                pass
                
    new_scan = scan_tree(watch_dir)
    events = diff_scans(previous_state, new_scan, now_ts)
    if events:
        emit_events(events)
        previous_state = new_scan
        with state_file.open("w", encoding="utf-8") as f:
            json.dump(previous_state, f)
PY
}

# fswatch backend runner
run_fswatch_watcher() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting fswatch on $WATCH_DIR -> $LOG_FILE"
  fswatch -xr "$WATCH_DIR" | while IFS= read -r line; do
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
      log_line="$line"
    else
      log_line="$ts $line"
    fi
    rotate_logs
    echo "$log_line" >> "$LOG_FILE"
    echo "$log_line"
  done
}

if [[ "$MODE" == "once" ]]; then
  run_python_watcher "once"
  exit 0
fi

if [[ "$BACKEND" == "fswatch" ]]; then
  run_fswatch_watcher
else
  run_python_watcher "watch"
fi
