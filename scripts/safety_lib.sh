# shellcheck shell=bash
# safety_lib.sh — machine-local safety guidelines for cleanup scripts.
#
# Source this file, then call:
#   safety_is_protected <abs-path>   rc 0 = protected (prints reason), rc 1 = not
#   safety_min_stale_days            prints the staleness floor in days
#   safety_file_in_use               prints which safety file is being consulted
#
# Rules live in a machine-local, gitignored safety.local.json. Resolution order:
#   1. <repo-root>/safety.local.json           (dev checkout override)
#   2. ~/.config/disk-magician/safety.local.json  (canonical machine-local file;
#      also the only reachable location for the uv-tool-packaged copy)
#   3. <repo-root>/safety.local.json.template  (committed baseline)
#
# Matching semantics (both directions, so deleting a parent of a protected
# path is also blocked):
#   - candidate matches a protected glob, or is a descendant of one
#   - a protected path is a descendant of the candidate
# The /System/Volumes/Data firmlink alias of $HOME is normalized on both sides
# (mirrors sync_user_config.py / disk_frontier_scan.py home_variants).

_SAFETY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SAFETY_REPO_ROOT="$(cd "$_SAFETY_LIB_DIR/.." && pwd)"

safety_file_in_use() {
  local candidate
  for candidate in \
    "$_SAFETY_REPO_ROOT/safety.local.json" \
    "$HOME/.config/disk-magician/safety.local.json" \
    "$_SAFETY_REPO_ROOT/safety.local.json.template"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

# safety_is_protected <abs-path>
# rc 0: protected — reason printed to stdout as "<rule-list>: <pattern> (<note>)"
# rc 1: not protected
# rc 2: usage / unreadable safety file (fails OPEN as "protected" is the safe
#       default only for rc 0; callers treat rc 2 as protected to fail closed)
safety_is_protected() {
  local target="${1:-}"
  [[ -n "$target" ]] || return 2
  local safety_file
  safety_file="$(safety_file_in_use)" || return 1  # no file at all -> nothing protected
  python3 - "$safety_file" "$target" <<'PY'
import fnmatch
import json
import os
import sys

safety_file, target = sys.argv[1], sys.argv[2]

DATA_PREFIX = "/System/Volumes/Data"


def canon(path):
    path = os.path.normpath(os.path.expandvars(os.path.expanduser(path)))
    if path.startswith(DATA_PREFIX + "/"):
        path = path[len(DATA_PREFIX):]
    return path


try:
    with open(safety_file) as fh:
        cfg = json.load(fh)
except (OSError, ValueError) as exc:
    print(f"unreadable safety file {safety_file}: {exc}", file=sys.stderr)
    sys.exit(2)


def entries(section):
    for item in cfg.get(section, []):
        if isinstance(item, str):
            yield item, ""
        elif isinstance(item, dict) and item.get("path"):
            yield item["path"], item.get("reason", "")


target_c = canon(target)
target_parts = target_c.rstrip("/").split(os.sep)
ancestors = [os.sep.join(target_parts[: i + 1]) or os.sep for i in range(len(target_parts))]

for section in ("never_delete", "protected_live_paths", "needs_decision"):
    for raw, reason in entries(section):
        pat = canon(raw)
        # candidate (or an ancestor of it) matches the protected glob
        if any(fnmatch.fnmatch(a, pat) for a in ancestors):
            note = f" ({reason})" if reason else ""
            print(f"{section}: {raw}{note}")
            sys.exit(0)
        # a protected path lives INSIDE the candidate (glob literal prefix)
        literal = pat.split("*", 1)[0].split("?", 1)[0].split("[", 1)[0]
        literal = literal.rstrip("/")
        if literal and (literal == target_c or literal.startswith(target_c.rstrip("/") + os.sep)):
            note = f" ({reason})" if reason else ""
            print(f"{section} (descendant): {raw}{note}")
            sys.exit(0)

sys.exit(1)
PY
}

# safety_gate <abs-path> — call-site wrapper for cleanup scripts.
# rc 0 = safe to proceed (nothing printed).
# rc 1 = do NOT delete; the reason is printed. An unreadable safety file
#        (safety_is_protected rc 2) also lands here: fail closed.
safety_gate() {
  local reason rc
  reason="$(safety_is_protected "$1")" && rc=0 || rc=$?
  if [[ "$rc" -eq 1 ]]; then
    return 0
  fi
  echo "${reason:-safety file unreadable — failing closed}"
  return 1
}

# sandbox_guard_roots <root> [<root> ...] — hard production guard (bead
# disk_magician-ka4 incident: a completed test run's REAL cleanup_tmp.sh
# --clean --large deleted content under host /private/tmp and $TMPDIR
# because no fixture-confinement check existed). When
# DISK_MAGICIAN_TEST_SANDBOX=<dir> is set (tests always set it), abort
# BEFORE any deletion (exit 90, deletes nothing) if any given root resolves
# outside <dir>. Production (env unset) is a no-op passthrough — this never
# changes real cleanup behavior.
sandbox_guard_roots() {
  local sandbox="${DISK_MAGICIAN_TEST_SANDBOX:-}"
  [[ -z "$sandbox" ]] && return 0
  local canon_sandbox
  canon_sandbox="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$sandbox" 2>/dev/null)"
  if [[ -z "$canon_sandbox" ]]; then
    echo "FATAL sandbox_guard_roots: cannot resolve DISK_MAGICIAN_TEST_SANDBOX=$sandbox — aborting before any deletion." >&2
    exit 90
  fi
  local root canon_root
  for root in "$@"; do
    [[ -z "$root" ]] && continue
    canon_root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$root" 2>/dev/null)"
    case "$canon_root" in
      "$canon_sandbox"|"$canon_sandbox"/*) continue ;;
      *)
        echo "FATAL sandbox_guard_roots: DISK_MAGICIAN_TEST_SANDBOX=$sandbox set but root '$root' resolves to '${canon_root:-<unresolvable>}', outside sandbox '$canon_sandbox' — aborting before any deletion." >&2
        exit 90
        ;;
    esac
  done
}

# deletion_log <script-name> <action> <kb> <path> — appends a persistent,
# tab-separated audit line for every ACTUAL (non-dry-run) removal/archival,
# independent of the caller's own stdout/stderr redirection or EXIT trap
# (bead disk_magician-ka4: the 2026-09-22 incident's per-run "Removing:" log
# lived only in the test's own mktemp dir and was deleted by its EXIT trap,
# so the actually-removed set was unrecoverable). Default path:
# ~/Library/Logs/disk-magician-deletions.log; override (tests set this
# inside their own fixture root) via DISK_MAGICIAN_DELETION_LOG. Best-effort:
# a log-write failure never blocks or fails the caller's cleanup.
deletion_log() {
  local script="$1" action="$2" kb="$3" path="$4"
  local log_path="${DISK_MAGICIAN_DELETION_LOG:-$HOME/Library/Logs/disk-magician-deletions.log}"
  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$script" "$action" "$kb" "$path" \
    >>"$log_path" 2>/dev/null || true
}

# findings_wiki_docs — list machine-local finding docs (fork-tracked knowledge
# layer; see findings_wiki/README.md). Prints one path per line; rc 1 if none.
findings_wiki_docs() {
  local dir="$_SAFETY_REPO_ROOT/findings_wiki" found=false f
  [[ -d "$dir" ]] || return 1
  for f in "$dir"/*.md; do
    [[ -e "$f" ]] || break
    case "$(basename "$f")" in README.md|TEMPLATE.md) continue ;; esac
    echo "$f"
    found=true
  done
  [[ "$found" == true ]]
}

# safety_min_stale_days — staleness floor in days (default 7 when unset).
safety_min_stale_days() {
  local safety_file
  if ! safety_file="$(safety_file_in_use)"; then
    echo 7
    return 0
  fi
  python3 - "$safety_file" <<'PY' || echo 7
import json
import sys

try:
    with open(sys.argv[1]) as fh:
        cfg = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)
value = cfg.get("min_stale_days", 7)
# Hard floor: this setting may only INCREASE the 7-day floor, never lower
# it (CLAUDE.md invariant). Clamp instead of merely rejecting negatives —
# a config value of 0-6 previously passed through unclamped, silently
# defeating the floor for every caller of safety_min_stale_days.
print(max(7, int(value)) if isinstance(value, (int, float)) else 7)
PY
}
