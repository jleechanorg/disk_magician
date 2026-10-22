#!/usr/bin/env bash
# cleanup_ao.sh — retire Agent Orchestrator sessions through its owner CLI.
# Defaults to a read-only preview. It never unlinks AO paths or edits AO DBs.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=true
STOP_PRODUCERS=false
STOP_ONLY=false
ALL_SESSIONS=false
IGNORE_AGE=false
MIN_AGE_MINUTES=""
CWD_SCAN_OK=false
MANIFEST_PATH="${AO_CLEAR_MANIFEST:-/tmp/disk_magician/evidence/ao-retirement-owner-manifest.json}"
LOG_PATH="${AO_CLEAR_LOG:-/tmp/disk_magician/evidence/ao-retirement.log}"
VERIFY_TIMEOUT_SEC="${AO_CLEAR_VERIFY_TIMEOUT_SEC:-30}"
VERIFICATION_FAILURES=0

usage() {
  cat <<'USAGE'
Usage: cleanup_ao.sh [--dry-run] [--manifest PATH]
       cleanup_ao.sh --clean --stop-producers --all --ignore-age --min-age-minutes 360
       cleanup_ao.sh --stop-producers-only

Retire known Agent Orchestrator sessions through the supported `ao` owner
lifecycle. The default is a read-only preview. --clean requires the explicit
--stop-producers gate and first stops/disables known user-level producers.
Dirty, unpushed, secret-bearing, missing, or live-cwd workspaces are preserved.

  --dry-run             Preview producer, session, and cleanup operations.
  --clean               Run exact-ID owner session termination for eligible sessions.
  --stop-producers      Required with --clean; stop known producers first.
  --all                 Required with --clean; authorize all eligible owners/projects.
  --ignore-age          Required with --clean; explicitly waive the age filter.
  --min-age-minutes N   Require workspaces to be quiet for N minutes before retirement.
  --stop-producers-only Stop/disable producers and verify they are inactive.
  --manifest PATH       Write the fresh owner directory manifest to PATH.
  -h, --help            Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --clean) DRY_RUN=false ;;
    --stop-producers) STOP_PRODUCERS=true ;;
    --all) ALL_SESSIONS=true ;;
    --ignore-age) IGNORE_AGE=true ;;
    --min-age-minutes)
      shift
      MIN_AGE_MINUTES="${1:?--min-age-minutes requires a value}"
      [[ "$MIN_AGE_MINUTES" =~ ^[1-9][0-9]*$ ]] || {
        echo '--min-age-minutes must be a positive integer.' >&2
        exit 2
      }
      ;;
    --stop-producers-only) STOP_PRODUCERS=true; STOP_ONLY=true; DRY_RUN=false ;;
    --manifest) shift; MANIFEST_PATH="${1:?--manifest requires a path}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$DRY_RUN" == false && "$STOP_PRODUCERS" != true ]]; then
  echo "Refusing --clean without --stop-producers; producer quiescence is the first stage." >&2
  exit 2
fi
if [[ "$DRY_RUN" == false && "$STOP_ONLY" == false && "$ALL_SESSIONS" != true ]]; then
  echo 'Refusing --clean without --all; cleanup is scoped to explicitly authorized owners/projects.' >&2
  exit 2
fi
if [[ "$DRY_RUN" == false && "$STOP_ONLY" == false && "$IGNORE_AGE" != true ]]; then
  echo 'Refusing --clean without --ignore-age; the age waiver must be explicit.' >&2
  exit 2
fi
if [[ "$DRY_RUN" == false && "$STOP_ONLY" == false && "$MIN_AGE_MINUTES" != 360 ]]; then
  echo 'Refusing AO retirement without explicit --min-age-minutes 360.' >&2
  exit 2
fi
if [[ "$IGNORE_AGE" == true && "$ALL_SESSIONS" != true ]]; then
  echo 'Refusing --ignore-age without --all.' >&2
  exit 2
fi
if [[ "$DRY_RUN" == false && "${AO_CLEAR_APPROVED:-}" != 1 ]]; then
  echo 'Refusing AO retirement without AO_CLEAR_APPROVED=1.' >&2
  exit 2
fi

mkdir -p "$(dirname "$MANIFEST_PATH")" "$(dirname "$LOG_PATH")"
: >"$LOG_PATH"
log() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S%z')] $*"
  printf '%s\n' "$line" | tee -a "$LOG_PATH"
}

DESKTOP_DB="$HOME/.ao/data/ao.db"
FACTORY_ROOT="$HOME/.local/state/dark-factory/native-ao"
FACTORY_DB="$FACTORY_ROOT/data/ao.db"

write_manifest() {
  local output="$1"
  python3 -c '
import datetime, json, os, sqlite3, sys
out, desktop_db, factory_db, factory_root = sys.argv[1:]
owners = [("desktop", desktop_db, os.path.expanduser("~/.ao")), ("factory", factory_db, factory_root)]
result = {"schema_version": 1, "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "owners": []}
for owner, db, root in owners:
    if not os.path.isfile(db):
        raise SystemExit(f"missing AO owner database: {db}")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    rows = conn.execute("SELECT id, project_id, is_terminated, activity_state, workspace_path, branch FROM sessions ORDER BY id").fetchall()
    conn.close()
    result["owners"].append({"owner": owner, "db": db, "root": root, "sessions": [
        {"id": r[0], "project_id": r[1], "is_terminated": int(r[2]), "activity_state": r[3], "workspace_path": r[4], "branch": r[5]} for r in rows
    ]})
with open(out, "w", encoding="utf-8") as fh:
    json.dump(result, fh, indent=2, sort_keys=True)
    fh.write("\n")
' "$output" "$DESKTOP_DB" "$FACTORY_DB" "$FACTORY_ROOT"
}

if [[ "$STOP_PRODUCERS" == true ]]; then
  if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
  fi
  [[ -d "$XDG_RUNTIME_DIR" ]] || { log "ERROR: XDG_RUNTIME_DIR is unavailable: $XDG_RUNTIME_DIR"; exit 1; }
fi

# These exact units are the observed producers/owners. Never use a wildcard.
PRODUCER_UNITS=(
  jleechanorg-pr-green-daily.timer
  jleechanorg-pr-green-daily.service
  ai.dark-factory.daemon.service
)

stop_producers() {
  local unit enabled active
  for unit in "${PRODUCER_UNITS[@]}"; do
    enabled="$(systemctl --user is-enabled "$unit" 2>/dev/null || true)"
    active="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
    if [[ "$DRY_RUN" == true ]]; then
      log "[dry-run] systemctl --user stop/disable $unit (enabled=$enabled active=$active)"
      continue
    fi
    if [[ "$active" == active || "$active" == activating ]]; then
      log "+ systemctl --user stop $unit"
      if ! systemctl --user stop "$unit"; then
        log "ERROR: failed to stop producer $unit"
        return 1
      fi
    fi
    if [[ "$enabled" == enabled || "$enabled" == enabled-runtime ]]; then
      log "+ systemctl --user disable $unit"
      if ! systemctl --user disable "$unit"; then
        log "ERROR: failed to disable producer $unit"
        return 1
      fi
    fi
  done
}

verify_producers_inactive() {
  local unit active
  for unit in "${PRODUCER_UNITS[@]}"; do
    active="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
    log "Producer verification: $unit state=$active"
    # `is-active` returns a non-zero status for an inactive unit.  Validate the
    # state text as well, so a missing user bus or any other query failure
    # cannot be mistaken for successful quiescence.
    if [[ "$active" != inactive ]]; then
      log "ERROR: producer $unit is not verified inactive"
      return 1
    fi
  done
}

session_db_state() {
  local db="$1" id="$2"
  python3 -c '
import sqlite3, sys
db, sid = sys.argv[1:]
try:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
    row = conn.execute("SELECT is_terminated FROM sessions WHERE id = ?", (sid,)).fetchone()
    conn.close()
except Exception:
    print("unreadable")
else:
    print("missing" if row is None else ("1" if bool(row[0]) else "0"))
' "$db" "$id"
}

verify_session_retired() {
  local owner="$1" db="$2" id="$3" path="$4"
  local deadline db_state path_present
  [[ "$VERIFY_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || VERIFY_TIMEOUT_SEC=30
  deadline=$((SECONDS + VERIFY_TIMEOUT_SEC))
  while :; do
    db_state="$(session_db_state "$db" "$id" 2>/dev/null || printf '%s' unreadable)"
    if [[ -e "$path" || -L "$path" ]]; then path_present=1; else path_present=0; fi
    if [[ "$db_state" == 1 && "$path_present" == 0 ]]; then
      log "VERIFY owner=$owner session=$id db_terminated=1 path_present=0 result=pass"
      return 0
    fi
    (( SECONDS >= deadline )) && break
    sleep 1
  done
  log "VERIFY owner=$owner session=$id db_terminated=$db_state path_present=$path_present result=fail"
  return 1
}

if [[ "$STOP_ONLY" == true ]]; then
  stop_producers
  verify_producers_inactive
  log 'Producer shutdown finished; AO owner daemons remain available for retirement.'
  exit 0
fi

workspace_under_root() {
  local path="$1" root="$2"
  [[ "$path" == /* && "$path" != *$'\n'* && -d "$path" && ! -L "$path" ]] || return 1
  [[ "$path" == "$root/data/worktrees/"* ]]
}

workspace_has_live_cwd() {
  [[ "$CWD_SCAN_OK" == true ]] || return 2
  cwd_list_has_path "$1" "$LSOF_CWDS"
}

workspace_preservation_reason() {
  local path="$1" root="$2" branch upstream ignored cwd_rc status_output ignored_output
  local remote merge_ref remote_url local_sha remote_sha
  workspace_under_root "$path" "$root" || { printf '%s' 'workspace missing, symlinked, or outside owner root'; return; }
  git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '%s' 'workspace is not a readable Git worktree'; return; }
  if [[ -n "$MIN_AGE_MINUTES" ]] && worktree_is_recently_active_minutes "$path" "$MIN_AGE_MINUTES"; then
    printf '%s' 'workspace was active within the minimum age window'; return
  fi
  if ! status_output="$(git -C "$path" status --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null)"; then
    printf '%s' 'workspace status could not be verified'; return
  fi
  [[ -z "$status_output" ]] || { printf '%s' 'workspace has dirty or untracked files'; return; }
  if ! ignored_output="$(git -C "$path" status --porcelain=v1 --ignored --untracked-files=all 2>/dev/null)"; then
    printf '%s' 'workspace ignored files could not be verified'; return
  fi
  ignored="$(printf '%s\n' "$ignored_output" | sed -n 's/^!! //p')"
  if [[ -n "$ignored" ]] && printf '%s\n' "$ignored" | grep -Eiq '(^|/)(\.env([^/]*|$)|\.npmrc|\.netrc|id_(rsa|ed25519|ecdsa|dsa)([^/]*|$)|[^/]*(credentials|secrets)[^/]*)$|\.(pem|key|p12|pfx)$'; then
    printf '%s' 'workspace contains an ignored secret-like file'; return
  fi
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [[ -n "$branch" ]] || { printf '%s' 'detached HEAD requires preservation'; return; }
  upstream="$(git -C "$path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  [[ -n "$upstream" ]] || { printf '%s' 'branch has no upstream; pushed state is unknown'; return; }
  remote="$(git -C "$path" config --get "branch.$branch.remote" 2>/dev/null || true)"
  merge_ref="$(git -C "$path" config --get "branch.$branch.merge" 2>/dev/null || true)"
  [[ -n "$remote" && "$remote" != . && "$merge_ref" == refs/heads/* ]] || { printf '%s' 'upstream remote could not be verified'; return; }
  remote_url="$(git -C "$path" remote get-url "$remote" 2>/dev/null || true)"
  [[ -n "$remote_url" ]] || { printf '%s' 'upstream remote URL could not be verified'; return; }
  local_sha="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
  remote_sha="$(git -C "$path" ls-remote --heads "$remote_url" "$merge_ref" 2>/dev/null | awk 'NR == 1 {print $1}')"
  [[ -n "$local_sha" && "$local_sha" == "$remote_sha" ]] || { printf '%s' 'branch tip is not verified on the live remote'; return; }
  workspace_has_live_cwd "$path"
  cwd_rc=$?
  case "$cwd_rc" in
    0) printf '%s' 'workspace is a live process cwd' ;;
    2) printf '%s' 'live-cwd scan was incomplete' ;;
    *) return 0 ;;
  esac
}

retire_owner() {
  local owner db root run_file port id project terminated path branch reason
  owner="$1"; db="$2"; root="$3"; run_file="$4"; port="$5"
  local -a env_prefix=(env AO_RUN_FILE="$run_file" AO_DATA_DIR="$root/data")
  [[ -n "$port" ]] && env_prefix+=(AO_PORT="$port")
  log "Owner $owner: evaluating manifest entries"
  while IFS=$'\t' read -r id project terminated path branch; do
    [[ -n "$id" ]] || continue
    reason="$(workspace_preservation_reason "$path" "$root")"
    if [[ -n "$reason" ]]; then
      log "PRESERVE owner=$owner session=$id project=$project path=$path reason=$reason"
      continue
    fi
    if [[ "$DRY_RUN" == true ]]; then
      log "[dry-run] ${env_prefix[*]} ao session kill $id -p $project"
    else
      log "+ ${env_prefix[*]} ao session kill $id -p $project"
      if "${env_prefix[@]}" ao session kill "$id" -p "$project"; then
        if ! verify_session_retired "$owner" "$db" "$id" "$path"; then
          VERIFICATION_FAILURES=$((VERIFICATION_FAILURES + 1))
        fi
      else
        log "VERIFY owner=$owner session=$id db_terminated=unknown path_present=unknown result=kill-command-failed"
        VERIFICATION_FAILURES=$((VERIFICATION_FAILURES + 1))
      fi
    fi
  done < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); o=next(x for x in d["owners"] if x["owner"]==sys.argv[2]); [print("\t".join(str(s.get(k,"")) for k in ("id","project_id","is_terminated","workspace_path","branch"))) for s in o["sessions"]]' "$MANIFEST_PATH" "$owner")

}

source "$SCRIPT_DIR/lib/lsof_linux.sh"
source "$SCRIPT_DIR/lib/worktree_recency.sh"

log "Stage 1: producer quiescence"
if [[ "$STOP_PRODUCERS" == true ]]; then stop_producers; else log "[dry-run] pass --stop-producers to enable producer stop"; fi
if [[ "$STOP_PRODUCERS" == true && "$DRY_RUN" == false ]]; then verify_producers_inactive; fi
if ! lsof_snapshot_cwds; then
  CWD_SCAN_OK=false
  log "ERROR: live-cwd scan unavailable; preserving all workspaces (${LSOF_CWD_REASON:-unknown})"
  [[ "$DRY_RUN" == true ]] || exit 1
else
  CWD_SCAN_OK=true
fi
log "Stage 2: fresh owner manifest after producer quiescence"
write_manifest "$MANIFEST_PATH"
log "Wrote fresh owner/session directory manifest: $MANIFEST_PATH"
log "Stage 3: owner session lifecycle"
retire_owner desktop "$DESKTOP_DB" "$HOME/.ao" "$HOME/.ao/running.json" ""
retire_owner factory "$FACTORY_DB" "$FACTORY_ROOT" "$FACTORY_ROOT/running.json" "7831"

if (( VERIFICATION_FAILURES > 0 )); then
  log "AO retirement finished with $VERIFICATION_FAILURES verification failure(s)."
  exit 1
fi
log "Completed AO retirement plan; no raw filesystem removal was performed by diskm."
