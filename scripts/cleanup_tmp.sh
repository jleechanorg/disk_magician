#!/usr/bin/env bash
# cleanup_tmp.sh — Delete stale git clones and temp logs from system temp directories.
#
# Defaults to DRY-RUN; pass --clean to actually delete. Callers that must
# delete (disk_audit.sh safe-clean path, pressure sweeps) pass --clean.
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/worktree_safety.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_safety.sh"
# shellcheck source=scripts/lib/scratch_roots.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_roots.sh"
# shellcheck source=scripts/lib/scratch_budget.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_budget.sh"
# shellcheck source=scripts/lib/scratch_lock.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_lock.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lsof_linux.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/artifact_verdict.sh"
# shellcheck source=scripts/lib/actuator_deadline.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/actuator_deadline.sh"
dylib_candidate_file=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE="$REPO_ROOT/config.json"
[[ -f "$CONFIG_FILE" ]] || CONFIG_FILE="$REPO_ROOT/config.json.template"

# Default thresholds (minutes unless noted)
GIT_CLONE_MIN=240
AGENT_PROMPT_MIN=240
CLI_VALIDATION_MIN=60
WORKTREE_POINTER_MIN=30
WORKTREE_POINTER_MIN_KB=51200
# --large branch safety (hours): a top-level /private/tmp dir with any file
# mtime within this window is considered "active use" and is skipped
# regardless of size or protected-root status.
LARGE_TMP_ACTIVE_HOURS="${LARGE_TMP_ACTIVE_HOURS:-24}"
# --large branch: how long an archived dir sits under
# /private/tmp/_disk_magician_archive/<ts>/ before a later --large run may
# permanently rm -rf it and actually reclaim the space.
LARGE_TMP_ARCHIVE_RETENTION_HOURS="${LARGE_TMP_ARCHIVE_RETENTION_HOURS:-24}"
# Stale children of a protected root. The protected-roots list guards a
# canonical evidence/repo root that lands directly in /private/tmp (e.g.
# worldarchitect.ai's evidence path) -- see the 9 logged incidents documented
# in tests/test_cleanup_tmp_large_protections.sh. Protecting the whole parent
# also hid its stale scratch children from every sweeper (2026-10-12: a 9.0 GB
# 'split-gates' child sat 26h idle and was invisible, bead
# disk_magician-tmp-protected-root-blocks-stale-children-ekm1). Children are
# therefore evaluated individually, on a stricter clock, and the canonical
# children below stay permanently protected.
PROTECTED_ROOT_CHILD_MIN_AGE_HOURS="${PROTECTED_ROOT_CHILD_MIN_AGE_HOURS:-48}"
# Basenames, relative to any protected root, that are never reclaimed.
DEFAULT_PROTECTED_ROOT_CHILDREN=(evidence)
PROTECTED_ROOT_CHILDREN=()
if [[ -n "${DISK_MAGICIAN_PROTECTED_ROOT_CHILDREN:-}" ]]; then
  read -r -a PROTECTED_ROOT_CHILDREN <<<"$DISK_MAGICIAN_PROTECTED_ROOT_CHILDREN"
fi
if [[ ${#PROTECTED_ROOT_CHILDREN[@]} -eq 0 ]]; then
  PROTECTED_ROOT_CHILDREN=("${DEFAULT_PROTECTED_ROOT_CHILDREN[@]}")
fi
# Hard cap (bead jleechan-mtow): an archive entry older than this is purged
# even if it still looks active (marker/mtime/open files). Without a cap, a
# process holding fds into an archived dir keeps it alive forever and the
# quarantine grows unboundedly — the leak class this repo exists to prevent.
LARGE_TMP_ARCHIVE_MAX_HOURS="${LARGE_TMP_ARCHIVE_MAX_HOURS:-168}"
# Overridable so sandboxed tests can point archiving at a fixture tree
# instead of the real /private/tmp; production always uses the default.
ARCHIVE_ROOT="${DISK_MAGICIAN_ARCHIVE_ROOT:-${DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE:-/private/tmp}/_disk_magician_archive}"
# Same env var and default as cleanup_worktrees.sh / cleanup_worktree_venvs.sh
# / worktree_hygiene.sh, for the orphaned /tmp worktree-pointer guard below --
# this was a bare hardcoded 14 that neither tracked the repo's 7-day floor
# change nor honored the override the sibling scripts respect (found in
# /advice review of PR #55).
WORKTREE_MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-7}"
# Hard floor: 7 days, may only be raised, never lowered (CLAUDE.md
# invariant). Missed in the sibling scripts' clamp sweep (found in /advice
# re-review of PR #55) -- WORKTREE_MIN_AGE_DAYS=0 would otherwise let this
# script's orphaned-worktree-pointer guard qualify every pointer for removal.
# Normalize via 10# BEFORE clamping: bash's `-lt`/`(( ))` parse a leading-
# zero numeral like "08" as octal (invalid digit -> arithmetic error), which
# would otherwise propagate as a fail-open crash into every downstream
# comparison, not just this clamp (found live by both /advice reviewers).
if [[ "$WORKTREE_MIN_AGE_DAYS" =~ ^[0-9]+$ ]]; then
  WORKTREE_MIN_AGE_DAYS=$((10#$WORKTREE_MIN_AGE_DAYS))
else
  WORKTREE_MIN_AGE_DAYS=7
fi
[[ "$WORKTREE_MIN_AGE_DAYS" -lt 7 ]] && WORKTREE_MIN_AGE_DAYS=7


if [[ -f "$CONFIG_FILE" ]]; then
  read -r GIT_CLONE_MIN AGENT_PROMPT_MIN CLI_VALIDATION_MIN WORKTREE_POINTER_MIN WORKTREE_POINTER_MIN_KB LARGE_TMP_ACTIVE_HOURS LARGE_TMP_ARCHIVE_RETENTION_HOURS LARGE_TMP_ARCHIVE_MAX_HOURS <<<"$(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || echo "240 240 60 30 51200 24 24 168"
import json, os, sys
data = json.load(open(sys.argv[1]))
t = data.get("cleanup_thresholds", {})
print(f"{t.get('git_clone_minutes', 240)} {t.get('agent_prompt_minutes', 240)} {t.get('cli_validation_minutes', 60)} {t.get('worktree_pointer_minutes', 30)} {t.get('worktree_pointer_min_kb', 51200)} {os.environ.get('LARGE_TMP_ACTIVE_HOURS', t.get('large_tmp_active_hours', 24))} {os.environ.get('LARGE_TMP_ARCHIVE_RETENTION_HOURS', t.get('large_tmp_archive_retention_hours', 24))} {os.environ.get('LARGE_TMP_ARCHIVE_MAX_HOURS', t.get('large_tmp_archive_max_hours', 168))}")
PY
)"
fi

# --large branch: top-level /private/tmp basenames that are NEVER deleted or
# archived, regardless of mtime/size — a documented canonical evidence/repo
# root landing directly in /private/tmp (e.g. worldarchitect.ai's evidence
# path) must never be treated as scratch. Override via
# DISK_MAGICIAN_PROTECTED_TMP_ROOTS (space-separated) or config.json's
# top-level "protected_tmp_roots" array; env wins over config.
DEFAULT_PROTECTED_TMP_ROOTS=(worldarchitect.ai worldai_claw wa-missions)
PROTECTED_TMP_ROOTS=()
if [[ -n "${DISK_MAGICIAN_PROTECTED_TMP_ROOTS:-}" ]]; then
  read -r -a PROTECTED_TMP_ROOTS <<<"$DISK_MAGICIAN_PROTECTED_TMP_ROOTS"
elif [[ -f "$CONFIG_FILE" ]]; then
  # Portable read loop (not `mapfile`/`readarray`) — macOS ships /bin/bash
  # 3.2 by default and launchd jobs without an interactive PATH fall back to
  # it even though the shebang is `env bash`.
  while IFS= read -r root; do
    [[ -n "$root" ]] && PROTECTED_TMP_ROOTS+=("$root")
  done < <(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
for r in data.get("protected_tmp_roots") or []:
    print(r)
PY
)
fi
if [[ ${#PROTECTED_TMP_ROOTS[@]} -eq 0 ]]; then
  PROTECTED_TMP_ROOTS=("${DEFAULT_PROTECTED_TMP_ROOTS[@]}")
fi

# --large may descend one level into active top-level directories only when
# their basename is explicitly known to contain independent cleanup units.
# A generic directory-with-children test is unsafe: an active build workspace
# can contain both fresh logs and idle-but-required sources.  The canonical
# agent-scratch root has per-runtime/run-id children by contract.  Additional
# container roots must be named explicitly via the environment or config.
DEFAULT_SCRATCH_CONTAINER_ROOTS=(agent-scratch)
SCRATCH_CONTAINER_ROOTS=()
if [[ -n "${DISK_MAGICIAN_SCRATCH_CONTAINER_ROOTS:-}" ]]; then
  read -r -a SCRATCH_CONTAINER_ROOTS <<<"$DISK_MAGICIAN_SCRATCH_CONTAINER_ROOTS"
elif [[ -f "$CONFIG_FILE" ]]; then
  while IFS= read -r root; do
    [[ -n "$root" ]] && SCRATCH_CONTAINER_ROOTS+=("$root")
  done < <(python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
for r in data.get("scratch_container_roots") or []:
    print(r)
PY
)
fi
if [[ ${#SCRATCH_CONTAINER_ROOTS[@]} -eq 0 ]]; then
  SCRATCH_CONTAINER_ROOTS=("${DEFAULT_SCRATCH_CONTAINER_ROOTS[@]}")
fi

DRY_RUN=true
INCLUDE_LARGE=false
INCLUDE_OPENCODE_DYLIBS=false
LARGE_TMP_MIN_KB="${LARGE_TMP_MIN_KB:-102400}"
# Size-budget mode (bead disk_magician-d45): 0 disables. Env default lets
# pressure_sweep.sh and launchd jobs enable it without a CLI edit.
BUDGET_GB="${DISK_MAGICIAN_SCRATCH_BUDGET_GB:-0}"
# Hard floor (minutes): never evict anything younger than this, regardless
# of budget pressure. Default 2h; clamped to a 1h minimum in scratch_budget.sh.
BUDGET_FLOOR_MINUTES="${DISK_MAGICIAN_SCRATCH_BUDGET_FLOOR_MINUTES:-120}"
# The lock helper re-execs this script with its original arguments, including
# governor flags, so preserve the complete argv before stripping those flags.
SCRATCH_LOCK_ORIGINAL_ARGS=("$@")
act_parse_deadline_args "$@" || exit 2
# Bash 3.2 with nounset treats an empty array expansion as an unbound
# variable; keep the no-argument caller contract portable.
if ((${#ACT_ARGS[@]})); then set -- "${ACT_ARGS[@]}"; else set --; fi
usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [--large] [--opencode-dylibs] [--budget-gb N] [--budget-floor-minutes N] [--help]

Delete stale agent git clones and temp files from system temp paths.

Options:
  --clean      Actually perform the cleanup (default: dry-run)
  --dry-run    Run in dry-run/preview mode
  --large      Include top-level /private/tmp dirs larger than LARGE_TMP_MIN_KB
  --opencode-dylibs
               Include closed OpenCode libopentui dylibs in DARWIN_USER_TEMP_DIR
  --budget-gb N
               Size-budget eviction: when a scratch root (see
               scripts/lib/scratch_roots.sh) exceeds N GiB of matched
               candidates, evict oldest-first (by content mtime) until
               under budget. 0 disables (default; env
               DISK_MAGICIAN_SCRATCH_BUDGET_GB).
  --budget-floor-minutes N
               Never evict anything younger than N minutes under budget
               mode (default 120, hard minimum 60; env
               DISK_MAGICIAN_SCRATCH_BUDGET_FLOOR_MINUTES).
  -h, --help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --large)   INCLUDE_LARGE=true ;;
    --opencode-dylibs) INCLUDE_OPENCODE_DYLIBS=true ;;
    --budget-gb)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --budget-gb requires a numeric argument" >&2
        exit 2
      fi
      BUDGET_GB="$2"; shift
      ;;
    --budget-gb=*) BUDGET_GB="${1#*=}" ;;
    --budget-floor-minutes)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Error: --budget-floor-minutes requires a numeric argument" >&2
        exit 2
      fi
      BUDGET_FLOOR_MINUTES="$2"; shift
      ;;
    --budget-floor-minutes=*) BUDGET_FLOOR_MINUTES="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if ! [[ "$BUDGET_GB" =~ ^[0-9]+$ ]]; then
  echo "Error: --budget-gb must be a non-negative integer, got '$BUDGET_GB'" >&2
  exit 2
fi
if ! [[ "$BUDGET_FLOOR_MINUTES" =~ ^[0-9]+$ ]]; then
  echo "Error: --budget-floor-minutes must be a non-negative integer, got '$BUDGET_FLOOR_MINUTES'" >&2
  exit 2
fi

if [[ "$INCLUDE_LARGE" == true && "$DRY_RUN" != true && "${LARGE_TMP_APPROVED:-0}" != "1" ]]; then
  echo "Refusing large /private/tmp deletion: set LARGE_TMP_APPROVED=1 after reviewing dry-run output." >&2
  exit 0
fi

if [[ "$INCLUDE_OPENCODE_DYLIBS" == true && "$DRY_RUN" != true && "${OPENCODE_DYLIBS_APPROVED:-0}" != "1" ]]; then
  echo "Refusing OpenCode dylib cleanup: set OPENCODE_DYLIBS_APPROVED=1 after reviewing dry-run output." >&2
  exit 0
fi

# Shared lock invariant: serialize destructive sweep against cleanup_pr_scratch.
# Dry-run (--dry-run) is read-only and skips the lock.
[[ "$DRY_RUN" == false ]] && { scratch_lock_acquire "cleanup_tmp" ${SCRATCH_LOCK_ORIGINAL_ARGS[@]+"${SCRATCH_LOCK_ORIGINAL_ARGS[@]}"} || exit 1; }

# Root list (bead disk_magician-d45): /private/tmp, /tmp, and the
# canonicalized macOS per-user temp dir, all owned by scripts/lib/scratch_roots.sh
# so the next scratch root only needs to be added in one place.
TMP_DIRS=()
while IFS= read -r _scratch_root; do
  TMP_DIRS+=("$_scratch_root")
done < <(scratch_roots_get_unique)
# USER_TMP is consumed directly (not via TMP_DIRS) by the --opencode-dylibs
# branch below, which existed before scratch_roots.sh and predates the
# root-list unification.
USER_TMP="$(scratch_roots_get_user_tmp)"
# PRIVATE_TMP_ROOT is consumed directly (not via TMP_DIRS) by the --large
# branch below, which scans/archives top-level /private/tmp dirs separately
# from the small-file loop above. Overridable via
# DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE (scripts/lib/scratch_roots.sh) so
# tests can confine --large to a fixture root instead of hardcoding
# `find /private/tmp` (bead disk_magician-ka4).
PRIVATE_TMP_ROOT="$(scratch_roots_get_private_tmp)"

# Candidate scope/order is part of the resume contract. A cursor created for
# different effective thresholds, modes, budgets, or roots fails closed.
ACT_CURSOR_SOURCE="cleanup_tmp:v1:dry=${DRY_RUN}:large=${INCLUDE_LARGE}:dylibs=${INCLUDE_OPENCODE_DYLIBS}:budget=${BUDGET_GB}:floor=${BUDGET_FLOOR_MINUTES}:git=${GIT_CLONE_MIN}:prompt=${AGENT_PROMPT_MIN}:cli=${CLI_VALIDATION_MIN}:pointer=${WORKTREE_POINTER_MIN}:${WORKTREE_POINTER_MIN_KB}:large_min=${LARGE_TMP_MIN_KB}:active=${LARGE_TMP_ACTIVE_HOURS}:retention=${LARGE_TMP_ARCHIVE_RETENTION_HOURS}:max=${LARGE_TMP_ARCHIVE_MAX_HOURS}:archive=${ARCHIVE_ROOT}:tmp=${TMP_DIRS[*]}:user_tmp=${USER_TMP}:private_tmp=${PRIVATE_TMP_ROOT}:protected=${PROTECTED_TMP_ROOTS[*]}"
if [[ -n "$ACT_CURSOR" ]]; then
  act_cursor_load "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" >/dev/null || {
    echo "cleanup_tmp: cursor invalid or options changed; preserving candidates" >&2
    exit 2
  }
  # Initialize/reset once per invocation (Cursor review 5/6): a
  # fully-consumed cursor begins a fresh pass so later candidates and
  # deferred units are revisited instead of reported cursor-complete forever.
  # act_cursor_reset_once is the shared, single reset point — resetting per
  # candidate would lose the resume list. Dry runs never mutate the cursor (a
  # preview must not consume progress).
  if [[ "$DRY_RUN" != true ]]; then
    act_cursor_reset_once "$ACT_CURSOR" "$ACT_CURSOR_SOURCE" || {
      echo "cleanup_tmp: cursor reset failed; preserving candidates" >&2
      exit 2
    }
  fi
fi

# Hard production guard (bead disk_magician-ka4): abort before any deletion
# if DISK_MAGICIAN_TEST_SANDBOX is set and any resolved root falls outside
# it. No-op in production (env unset).
sandbox_guard_roots "${TMP_DIRS[@]:-}" "$ARCHIVE_ROOT" "${USER_TMP:-}" "${PRIVATE_TMP_ROOT:-}"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2; }
dry_prefix() { [[ "$DRY_RUN" == true ]] && echo "DRY RUN: " || echo ""; }

CANDIDATE_REMOVED_COUNT=0
CANDIDATE_DEFERRED_COUNT=0
CANDIDATE_INTERRUPTED_COUNT=0
cleanup_tmp_count_candidate_result() {
  case "$1" in
    removed:*) CANDIDATE_REMOVED_COUNT=$((CANDIDATE_REMOVED_COUNT + 1)) ;;
    deferred:deadline-before-unit) CANDIDATE_INTERRUPTED_COUNT=$((CANDIDATE_INTERRUPTED_COUNT + 1)) ;;
    deferred:*) CANDIDATE_DEFERRED_COUNT=$((CANDIDATE_DEFERRED_COUNT + 1)) ;;
  esac
}
RECEIPT_HELPER="${DISK_MAGICIAN_RECEIPT_HELPER:-$SCRIPT_DIR/job_receipt.py}"
cleanup_tmp_df_free_bytes() {
  df -kP "$REPO_ROOT" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print $4 * 1024}'
}
RECEIPT_FREE_BEFORE="$(cleanup_tmp_df_free_bytes)"
[[ "$RECEIPT_FREE_BEFORE" =~ ^[0-9]+$ ]] || RECEIPT_FREE_BEFORE=""
RECEIPT_PRECONDITION='{}'
[[ -n "$RECEIPT_FREE_BEFORE" ]] && RECEIPT_PRECONDITION="{\"free_bytes_before\":${RECEIPT_FREE_BEFORE}}"
RECEIPT_TRIGGER="${DISK_MAGICIAN_RECEIPT_TRIGGER:-actuator}"
RECEIPT_CLEAR_STALE_ARGS=()
[[ "$DRY_RUN" == false ]] && RECEIPT_CLEAR_STALE_ARGS=(--clear-stale-active)
RECEIPT_RUN_ID="$(python3 "$RECEIPT_HELPER" begin --job cleanup_tmp ${RECEIPT_CLEAR_STALE_ARGS[@]+"${RECEIPT_CLEAR_STALE_ARGS[@]}"} --trigger "$RECEIPT_TRIGGER" --precondition "$RECEIPT_PRECONDITION")" || {
  log "ERROR: failed to record cleanup_tmp receipt begin"
  exit 1
}
RECEIPT_FINISHED=false
cleanup_tmp_finish_receipt() {
  local rc="${1:-0}" sig="${2:-0}" free_after="" delta="null" freed="null" outcome reason safety
  [[ "$RECEIPT_FINISHED" == true ]] && return 0
  RECEIPT_FINISHED=true
  free_after="$(cleanup_tmp_df_free_bytes)"
  [[ "$free_after" =~ ^[0-9]+$ ]] || free_after=""
  if [[ -n "$RECEIPT_FREE_BEFORE" && -n "$free_after" ]]; then
    delta=$(( free_after - RECEIPT_FREE_BEFORE ))
    freed=$(( delta > 0 ? delta : 0 ))
  fi
  if [[ "$sig" != 0 || "$rc" == 124 || "$rc" == 137 ]]; then
    outcome=timeout
    reason="interrupted; signal=${sig}; exit=${rc}"
    CANDIDATE_INTERRUPTED_COUNT=$(( CANDIDATE_INTERRUPTED_COUNT + 1 ))
  elif (( rc != 0 )); then
    outcome=error
    reason="cleanup_tmp exited ${rc}"
  elif [[ "$delta" == null ]]; then
    outcome=error
    reason="df postcondition unavailable"
  elif [[ "$DRY_RUN" == true && "$CANDIDATE_REMOVED_COUNT" == 0 ]]; then
    outcome=success_noop
    reason="dry-run completed"
  elif [[ "$CANDIDATE_INTERRUPTED_COUNT" -gt 0 || "$CANDIDATE_DEFERRED_COUNT" -gt 0 ]]; then
    outcome=partial
    reason="completed with candidate deferrals or interruptions"
  elif [[ "$CANDIDATE_REMOVED_COUNT" -gt 0 ]]; then
    outcome=success
    reason="C14 removals completed"
  else
    outcome=success_noop
    reason="no eligible removals"
  fi
  safety='{"status":"guarded","reason":"C14 verdict required for destructive paths","delegated":false}'
  python3 "$RECEIPT_HELPER" finish --job cleanup_tmp --run-id "$RECEIPT_RUN_ID" \
    --outcome "$outcome" --reason "$reason" --safety "$safety" \
    --candidates "{\"count\":null,\"bytes\":null,\"removed_count\":${CANDIDATE_REMOVED_COUNT},\"deferred_count\":${CANDIDATE_DEFERRED_COUNT},\"interrupted_count\":${CANDIDATE_INTERRUPTED_COUNT}}" \
    --postcondition "{\"free_bytes_before\":${RECEIPT_FREE_BEFORE:-null},\"free_bytes_after\":${free_after:-null},\"df_delta_bytes\":${delta},\"freed_bytes\":${freed}}" >/dev/null || {
      log "ERROR: failed to record cleanup_tmp receipt finish"
      return 1
    }
}
cleanup_tmp_exit_trap() {
  local rc=$? sig="${1:-0}"
  trap - EXIT HUP INT TERM
  cleanup_tmp_finish_receipt "$rc" "$sig" || rc=1
  if [[ "$sig" != 0 ]]; then
    [[ -n "${dylib_candidate_file:-}" ]] && rm -f "$dylib_candidate_file"
    kill -"$sig" "$$" 2>/dev/null || exit "$((128 + sig))"
  fi
  if [[ -n "${dylib_candidate_file:-}" ]]; then rm -f "$dylib_candidate_file"; fi
  return "$rc"
}
scratch_lock_set_traps
trap 'cleanup_tmp_exit_trap 0' EXIT
trap 'cleanup_tmp_exit_trap 1' HUP
trap 'cleanup_tmp_exit_trap 2' INT
trap 'cleanup_tmp_exit_trap 15' TERM

# Per-probe bound (seconds) for du / recency find / lsof snapshot on a single
# entry. Exceeding it fails closed for that entry only.
PROBE_TIMEOUT_SEC="${DISK_MAGICIAN_PROBE_TIMEOUT_SECONDS:-30}"
if ! [[ "$PROBE_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]]; then
  log "invalid DISK_MAGICIAN_PROBE_TIMEOUT_SECONDS='${PROBE_TIMEOUT_SEC}', using 30"
  PROBE_TIMEOUT_SEC=30
fi
UNBOUNDED_WARNED=false
warn_unbounded_probes_once() {
  [[ "$UNBOUNDED_WARNED" == true ]] && return 0
  UNBOUNDED_WARNED=true
  log "WARNING: no timeout binary found; du/find probes are unbounded."
}

# resolve_timeout_bin [override] — print a GNU-style timeout executable, or
# nothing. A non-empty override must be executable or nothing is printed.
resolve_timeout_bin() {
  local candidate
  if [[ -n "${1:-}" ]]; then
    [[ -x "$1" ]] && echo "$1"
    return 0
  fi
  for candidate in "$(command -v timeout 2>/dev/null || true)" "$(command -v gtimeout 2>/dev/null || true)" \
      /opt/homebrew/bin/timeout /opt/homebrew/bin/gtimeout /usr/local/bin/timeout /usr/local/bin/gtimeout; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
}

path_size_kb() {
  # Bead disk_magician-lsl: `du -sk` can emit zero, one, or (under a TOCTOU
  # race / BSD-du edge case on a live, churning TMPDIR) multiple lines.
  # Take the first numeric field of the LAST line; default to 0 when there
  # is no line at all. A one-line-per-input-line awk (the old
  # `{print $1+0}`) instead produced a multi-line "kb" value that broke
  # every downstream `$(( total_kb + kb ))` / `[[ $kb -lt N ]]` caller.
  # `du`'s own exit status is neutralized with `|| true` (not just its
  # stderr) so a `du` failure never makes this function's caller (e.g.
  # `kb=$(path_size_kb "$path")` under `set -eo pipefail`) abort the whole
  # script instead of falling back to 0.
  # Bounded (pressure sweeps share one step budget): a du that exceeds the probe
  # timeout prints -1 (size unknown, distinct from an empty 0 KB entry). Every
  # caller must preserve a negative result; only that entry is affected.
  # Any non-success du with no numeric total is unknown (-1), never 0. rc 1 WITH
  # a numeric total (EACCES/ENOENT partial) stays a lower bound.
  local tbin out rc=0 total
  tbin="$(resolve_timeout_bin "${DISK_MAGICIAN_PROBE_TIMEOUT_BIN:-}")"
  if [[ -n "$tbin" ]]; then
    out="$("$tbin" --kill-after=2s "${PROBE_TIMEOUT_SEC}s" du -sk "$1" 2>/dev/null)" || rc=$?
    if (( rc == 124 || rc == 137 )); then
      log "du exceeded ${PROBE_TIMEOUT_SEC}s, size unknown (preserving): $1"
      echo -1
      return 0
    fi
    if (( rc >= 125 && rc <= 127 )); then
      log "du wrapper failed rc=${rc}, size unknown (preserving): $1"
      echo -1
      return 0
    fi
  else
    warn_unbounded_probes_once
    out="$(du -sk "$1" 2>/dev/null)" || rc=$?
  fi
  total="$(awk '$1 ~ /^[0-9]+$/ {f=$1; n=1} END{if (n) print f}' <<<"$out")"
  if [[ -z "$total" ]] && (( rc != 0 )); then
    log "du failed rc=${rc}, size unknown (preserving): $1"
    echo -1
    return 0
  fi
  echo "${total:-0}"
}

# remove_path <path> — requests canonical C14 removal and records the outcome
# in the caller's scope. A command substitution would run this in a subshell and
# discard both the completion flag and the CANDIDATE_* counters, so callers call
# it directly and then read REMOVE_PATH_KB / REMOVE_PATH_COMPLETED.
REMOVE_PATH_KB=0
REMOVE_PATH_COMPLETED=false
remove_path() {
  local path="$1"
  local kb result
  REMOVE_PATH_KB=0
  REMOVE_PATH_COMPLETED=false
  kb=$(path_size_kb "$path")
  if (( kb < 0 )); then
    log "Preserving (size unknown, not removing): $path"
    return 0
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would remove: $path  (${kb} KB)"
    REMOVE_PATH_COMPLETED=true
  else
    log "Requesting C14 removal: $path  (${kb} KB)"
    if ! _safety_reason="$(safety_gate "$path" 2>/dev/null)"; then
      echo "SAFETY-SKIP "$path" ($_safety_reason)"
      return 0
    fi
    result="$(DM_DELETION_LOGGED=1 scratch_budget_quarantine_remove "$path")"
    cleanup_tmp_count_candidate_result "$result"
    if [[ "$result" == removed:* ]]; then
      deletion_log "cleanup_tmp.sh" "remove" "$kb" "$path"
      REMOVE_PATH_COMPLETED=true
    else
      log "Preserving (C14 $result): $path"
      kb=0
    fi
  fi
  REMOVE_PATH_KB="$kb"
  return 0
}

# is_protected_root <basename> — true if the top-level /private/tmp dir
# basename is on the never-touch list (see PROTECTED_TMP_ROOTS above).
is_protected_root() {
  local base="$1" root
  for root in "${PROTECTED_TMP_ROOTS[@]}"; do
    [[ "$base" == "$root" ]] && return 0
  done
  return 1
}

# is_protected_root_child <basename> -- true for a child of a protected root
# that must never be reclaimed even when stale (the canonical evidence dirs).
is_protected_root_child() {
  local base="$1" child
  for child in "${PROTECTED_ROOT_CHILDREN[@]}"; do
    [[ "$base" == "$child" ]] && return 0
  done
  return 1
}

# scan_protected_root_children <protected_root_path> -- evaluate the DIRECT
# children of a protected root so stale scratch inside it is still reclaimable
# while the root and its canonical children (evidence/) are never touched.
# Uses the same guards as the large-dir class (marker, recency, size, open
# files, unsaved work) on a stricter recency clock.
scan_protected_root_children() {
  local root="$1" child base rel kb archive_rc
  while IFS= read -r -d '' child; do
    base="$(basename "$child")"
    if is_protected_root_child "$base"; then
      log "Skipping protected child of a protected root: $child"
      continue
    fi
    if [[ -e "$child/.in-use" ]]; then
      log "Skipping active-use marker (.in-use present): $child"
      continue
    fi
    if has_recent_activity "$child" "$PROTECTED_ROOT_CHILD_MIN_AGE_HOURS"; then
      log "Skipping recently active protected-root child (mtime/ctime within ${PROTECTED_ROOT_CHILD_MIN_AGE_HOURS}h): $child"
      continue
    fi
    kb=$(path_size_kb "$child")
    if [[ "$kb" -lt 0 ]]; then
      log "Skipping protected-root child (size unknown): $child"
      continue
    fi
    if [[ "$kb" -lt "$LARGE_TMP_MIN_KB" ]]; then
      continue
    fi
    if [[ "$DRY_RUN" != true ]] && has_open_files "$child"; then
      log "Skipping in-use protected-root child: $child  (${kb} KB)"
      continue
    fi
    if declare -F worktree_has_unsaved_work >/dev/null 2>&1 && worktree_has_unsaved_work "$child"; then
      log "Skipping protected-root child with unsaved work (uncommitted/unpushed/no-upstream): $child"
      continue
    fi
    archive_rc=0
    archive_path "$child" "$kb" "$(basename "$root")" >/dev/null || archive_rc=$?
    (( archive_rc == 1 )) && continue
    if (( archive_rc != 0 )); then
      log "ERROR: could not archive: $child (rc=$archive_rc); preserving and continuing"
      cleanup_tmp_count_candidate_result deferred:archive-error
      continue
    fi
    ARCHIVED_KB=$(( ARCHIVED_KB + kb ))
    DIRS_ARCHIVED=$(( DIRS_ARCHIVED + 1 ))
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
}

# is_protected_tmp_path <path> — true for a configured protected root and
# everything below it, regardless of which cleanup class discovered it first.
is_protected_tmp_path() {
  local path="$1" root
  for root in "${PROTECTED_TMP_ROOTS[@]}"; do
    case "/$path/" in
      *"/$root/"*) return 0 ;;
    esac
  done
  return 1
}

# tmp_root_grace_minutes <window_mins> — root-grace minutes: env value read as
# DECIMAL (08/09 are invalid octal in bare (( ))), non-numeric/empty/negative/
# padded -> 30, floor 5, ceiling <window_mins>; digit strings over 6 chars use
# the window so $((10#...)) cannot overflow.
tmp_root_grace_minutes() {
  local mins="$1" g="${DISK_MAGICIAN_TMP_ROOT_GRACE_MINUTES:-30}"
  [[ "$g" =~ ^[0-9]+$ ]] || g=30
  if (( ${#g} > 6 )); then g=$mins; else g=$((10#$g)); fi
  if (( g < 5 )); then g=5; fi
  if (( g > mins )); then g=$mins; fi
  printf '%s\n' "$g"
}

# has_recent_activity <dir> <hours> — true if any entry UNDER <dir> (never
# <dir> itself) has an mtime OR ctime within the last <hours>; the dir ITSELF
# counts only within a short grace (DISK_MAGICIAN_TMP_ROOT_GRACE_MINUTES). ctime catches
# structural activity that leaves old mtimes: mv/tar -x/cp -p/rsync -a of old
# content into the tree give the moved file a fresh ctime. Fails CLOSED: any
# error reading the tree (permission denied, vanished path, etc.) is treated as
# "active" so the caller skips deletion rather than risking a false-negative on
# a directory it can't actually inspect. Uses /usr/bin/find explicitly — some
# shells in this fleet alias `find` to an incompatible wrapper that rejects
# -mmin. -mmin/-cmin exist in both BSD and GNU find.
#
# -mindepth 1 is load-bearing (bead disk_magician-7871): without it the probe's
# first hit is frequently <dir> itself, whose mtime moves on any child
# create/delete/rename even when no content changed. That made touched-but-stale
# trees permanently "active": /private/tmp/worldai_frontend sat at 20+ GiB with
# 8.7h-old content and a fresh dir mtime, so every pass skipped it and /tmp
# doubled while the sweeper correctly reported "Dirs removed: 0".
has_recent_activity() {
  local dir="$1" hours="$2" mins grace hit_file rc=0 tbin
  mins=$(( hours * 60 ))
  # The ROOT's own mtime/ctime counts only within a short grace (default 30m,
  # floor 5, clamped to the normal window): enough to protect a child that was
  # just deleted/renamed away, far too short to pin a quiet tree (7871).
  grace="$(tmp_root_grace_minutes "$mins")"
  # Test seam: fixtures cannot backdate ctime (touch -t sets it to now), so a
  # test context judges mtime only unless a test opts into the ctime signal.
  local -a recent_expr=( \( -mmin "-${mins}" -o -cmin "-${mins}" \) )
  local -a root_expr=( \( -mmin "-${grace}" -o -cmin "-${grace}" \) )
  if [[ -n "${DISK_MAGICIAN_TEST_CONTEXT:-}" && "${DISK_MAGICIAN_TEST_CTIME_SIGNAL:-}" != 1 ]]; then
    recent_expr=( -mmin "-${mins}" )
    root_expr=( -mmin "-${grace}" )
  fi
  hit_file="$(mktemp -t disk-magician-activity.XXXXXX)"
  tbin="$(resolve_timeout_bin "${DISK_MAGICIAN_PROBE_TIMEOUT_BIN:-}")"
  [[ -n "$tbin" ]] || warn_unbounded_probes_once
  # Probe 1: entries under the dir. Probe 2: the dir itself, short grace.
  local pass
  for pass in under root; do
    if [[ "$pass" == under ]]; then
      if [[ -n "$tbin" ]]; then
        "$tbin" --kill-after=2s "${PROBE_TIMEOUT_SEC}s" /usr/bin/find "$dir" -mindepth 1 "${recent_expr[@]}" -print -quit >"$hit_file" 2>/dev/null || rc=$?
      else
        /usr/bin/find "$dir" -mindepth 1 "${recent_expr[@]}" -print -quit >"$hit_file" 2>/dev/null || rc=$?
      fi
    elif [[ ! -s "$hit_file" ]] && (( rc == 0 )); then
      if [[ -n "$tbin" ]]; then
        "$tbin" --kill-after=2s "${PROBE_TIMEOUT_SEC}s" /usr/bin/find "$dir" -maxdepth 0 "${root_expr[@]}" -print -quit >"$hit_file" 2>/dev/null || rc=$?
      else
        /usr/bin/find "$dir" -maxdepth 0 "${root_expr[@]}" -print -quit >"$hit_file" 2>/dev/null || rc=$?
      fi
    fi
  done
  if (( rc != 0 )); then
    rm -f "$hit_file"
    log "Active-use check failed for $dir (find rc=${rc}) — fail-closed, treating as active."
    return 0
  fi
  if [[ -s "$hit_file" ]]; then
    rm -f "$hit_file"
    return 0
  fi
  rm -f "$hit_file"
  return 1
}

# has_active_marker <dir> — true when any quarantined subtree carries the
# explicit active-use marker. The marker moves with an archived directory, so
# purge checks recursively rather than only at the timestamp directory root.
has_active_marker() {
  local dir="$1" hit_file
  hit_file="$(mktemp -t disk-magician-marker.XXXXXX)"
  /usr/bin/find "$dir" -name .in-use -print 2>/dev/null | head -n 1 >"$hit_file" || true
  if [[ -s "$hit_file" ]]; then
    rm -f "$hit_file"
    return 0
  fi
  rm -f "$hit_file"
  return 1
}


# lsof escapes ambiguous path bytes depending on locale; preserve those candidates.
has_ambiguous_lsof_path() {
  local LC_ALL=C
  [[ "$1" == *[![:print:]]* || "$1" == *\\* ]]
}

# has_open_files <dir> — true when lsof finds an open file or cannot prove the
# tree is closed. Uses bounded targetless machine-format lsof (-n -P -F n) with
# escalation (--kill-after=2s).
# Fails closed (returns 0, unsafe/active) on canonicalization failure, control
# characters in candidate/canonical path, missing lsof, missing timeout, timeout,
# nonzero status, relevant or unknown stderr diagnostics, unknown path formats,
# or malformed records. Unrelated mount-stat warnings are ignored.
# Returns 1 only when authoritatively proven that no open files match.
has_open_files() {
  local dir="$1"
  if has_ambiguous_lsof_path "$dir"; then
    log "Open-file check input path contains control characters, non-ASCII bytes, or backslashes for $dir — fail-closed, treating as active."
    return 0
  fi

  local canon_dir
  canon_dir=$(cd "$dir" 2>/dev/null && pwd -P) || {
    log "Open-file check canonicalization failed for $dir — fail-closed, treating as active."
    return 0
  }
  if [[ -z "$canon_dir" ]]; then
    log "Open-file check canonicalization failed for $dir — fail-closed, treating as active."
    return 0
  fi
  [[ "$canon_dir" != "/" ]] && canon_dir="${canon_dir%/}"

  if has_ambiguous_lsof_path "$canon_dir"; then
    log "Open-file check canonical path contains control characters, non-ASCII bytes, or backslashes for $dir — fail-closed, treating as active."
    return 0
  fi

  local lsof_bin=""
  if [[ -n "${DISK_MAGICIAN_LSOF_BIN:-}" ]]; then
    lsof_bin="$DISK_MAGICIAN_LSOF_BIN"
  elif command -v lsof >/dev/null 2>&1; then
    lsof_bin="$(command -v lsof)"
  elif [[ -x /usr/sbin/lsof ]]; then
    lsof_bin=/usr/sbin/lsof
  fi
  if [[ -z "$lsof_bin" || ! -x "$lsof_bin" ]]; then
    log "Open-file check unavailable for $dir (lsof not found or not executable) — fail-closed, treating as active."
    return 0
  fi

  local timeout_bin=""
  if [[ -n "${DISK_MAGICIAN_TIMEOUT_BIN:-}" ]]; then
    timeout_bin="$DISK_MAGICIAN_TIMEOUT_BIN"
  elif command -v timeout >/dev/null 2>&1; then
    timeout_bin="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="$(command -v gtimeout)"
  else
    local candidate
    for candidate in /opt/homebrew/bin/timeout /opt/homebrew/bin/gtimeout /usr/local/bin/timeout /usr/local/bin/gtimeout; do
      if [[ -x "$candidate" ]]; then
        timeout_bin="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$timeout_bin" || ! -x "$timeout_bin" ]]; then
    log "Open-file check unavailable for $dir (timeout executable not found or not executable) — fail-closed, treating as active."
    return 0
  fi

  local timeout_sec="${DISK_MAGICIAN_LSOF_TIMEOUT_SECONDS:-15}"
  if ! [[ "$timeout_sec" =~ ^[1-9][0-9]?$ ]] || (( timeout_sec > 60 )); then
    log "Open-file check invalid timeout '$timeout_sec' for $dir — fail-closed, treating as active."
    return 0
  fi

  local hit_file err_file rc=0
  hit_file="$(mktemp -t disk-magician-lsof.XXXXXX)"
  err_file="$(mktemp -t disk-magician-lsof-error.XXXXXX)"

  "$timeout_bin" --kill-after=2s "${timeout_sec}s" "$lsof_bin" +w -n -P -F fnt >"$hit_file" 2>"$err_file" || rc=$?

  # Bash command substitution silently removes NUL bytes. A malformed lsof
  # warning could then look like an allowlisted mount warning, so reject NULs
  # in the original byte stream before converting stderr to shell text.
  local -a stderr_filter_status
  if LC_ALL=C tr -d '\000' <"$err_file" | cmp -s - "$err_file"; then
    stderr_filter_status=("${PIPESTATUS[@]}")
  else
    stderr_filter_status=("${PIPESTATUS[@]}")
  fi
  if (( stderr_filter_status[0] != 0 || stderr_filter_status[1] > 1 )); then
    rm -f "$hit_file" "$err_file"
    log "Open-file check failed for $dir (could not validate lsof stderr bytes) — fail-closed, treating as active."
    return 0
  fi
  if (( stderr_filter_status[1] == 1 )); then
    rm -f "$hit_file" "$err_file"
    log "Open-file check failed for $dir (lsof stderr contained NUL bytes) — fail-closed, treating as active."
    return 0
  fi

  local err_content="" diagnostic="" non_newline_stderr=""
  if ! err_content=$(cat "$err_file" && printf '.'); then
    rm -f "$hit_file" "$err_file"
    log "Open-file check failed for $dir (could not read lsof stderr) — fail-closed, treating as active."
    return 0
  fi
  err_content="${err_content%.}"
  # Treat the final line terminator as part of the last stderr line; retain
  # any preceding blank line so the parser can reject malformed extra output.
  [[ "$err_content" == *$'\n' ]] && err_content="${err_content%$'\n'}"
  non_newline_stderr="${err_content//$'\n'/}"
  if [[ -s "$err_file" && -z "$non_newline_stderr" ]]; then
    rm -f "$hit_file" "$err_file"
    log "Open-file check failed for $dir (lsof stderr contained only line breaks) — fail-closed, treating as active."
    return 0
  fi
  diagnostic="${err_content%%$'\n'*}"

  if (( rc != 0 )); then
    rm -f "$hit_file" "$err_file"
    log "Open-file check failed for $dir (lsof rc=${rc}${diagnostic:+: $diagnostic}) — fail-closed, treating as active."
    return 0
  fi

  if lsof_stderr_incomplete_for_path "$err_content" "$canon_dir"; then
    rm -f "$hit_file" "$err_file"
    log "Open-file check failed for $dir (lsof rc=${rc}: ${diagnostic}) — fail-closed, treating as active."
    return 0
  fi
  rm -f "$err_file"

  if [[ ! -s "$hit_file" ]]; then
    rm -f "$hit_file"
    log "Open-file check produced empty output for $dir — fail-closed, treating as active."
    return 0
  fi

  local line tag val
  local has_open=1
  local seen_process=0
  local current_process=0
  local descriptor_type=""
  local seen_named_path=0
  local malformed=0
  local unknown_path=0
  local unknown_path_val=""
  local norm_val=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    tag="${line:0:1}"
    case "$tag" in
      p)
        val="${line#p}"
        if [[ "$val" =~ ^[0-9]+$ ]]; then
          seen_process=1
          current_process=1
          descriptor_type=""
        else
          malformed=1
          break
        fi
        ;;
      f)
        descriptor_type=""
        if (( current_process == 0 )); then
          malformed=1
          break
        fi
        val="${line#f}"
        if ! [[ "$val" =~ ^\*?[a-zA-Z0-9.]+$ ]]; then
          malformed=1
          break
        fi
        ;;
      t)
        if (( current_process == 0 )) || [[ -z "${line#t}" ]]; then
          malformed=1
          break
        fi
        descriptor_type="${line#t}"
        ;;
      n)
        if (( current_process == 0 )); then
          malformed=1
          break
        fi
        val="${line#n}"
        if [[ -z "$val" ]]; then
          # Empty n records are valid for unnamed descriptors
          :
        else
          seen_named_path=1
          if [[ "$descriptor_type" == "PSXSHM" || "$descriptor_type" == "PSXSEM" ]]; then
            # POSIX IPC names do not identify filesystem paths.
            :
          elif [[ "$val" == "/"* ]]; then
            # Check for non-canonical relative traversal components inside path
            if [[ "$val" == *"/../"* || "$val" == *"/.." ]]; then
              unknown_path=1
              unknown_path_val="$val"
              break
            fi
            # Normalize known macOS top-level aliases with component boundaries
            if [[ "$val" == "/var" || "$val" == "/var/"* ]]; then
              norm_val="/private${val}"
            elif [[ "$val" == "/tmp" || "$val" == "/tmp/"* ]]; then
              norm_val="/private${val}"
            elif [[ "$val" == "/etc" || "$val" == "/etc/"* ]]; then
              norm_val="/private${val}"
            else
              norm_val="$val"
            fi

            # Exact or slash-delimited prefix compare against canonical dir
            if [[ "$norm_val" == "$canon_dir" || "$norm_val" == "$canon_dir/"* || "$val" == "$canon_dir" || "$val" == "$canon_dir/"* ]]; then
              has_open=0
              break
            fi
          elif [[ "$val" == "->"* || "$val" == "["* || "$val" == *":"* || "$val" == "count="* || "$val" == "(revoked)" || "$val" =~ ^[0-9A-Fa-f-]{36} ]]; then
            # Recognized non-filesystem lsof descriptor (pipe, socket, kernel control, mach port)
            :
          else
            unknown_path=1
            unknown_path_val="$val"
            break
          fi
        fi
        ;;
      *)
        malformed=1
        break
        ;;
    esac
  done < "$hit_file"
  rm -f "$hit_file"

  if (( unknown_path != 0 )); then
    log "Open-file check encountered unknown path format '$unknown_path_val' for $dir — fail-closed, treating as active."
    return 0
  fi

  if (( malformed != 0 || seen_process == 0 || seen_named_path == 0 )); then
    log "Open-file check produced malformed output for $dir — fail-closed, treating as active."
    return 0
  fi

  if (( has_open == 0 )); then
    return 0
  fi

  return 1
}

# archive_path <dir> <size_kb> — move (not delete) a large top-level /private/tmp dir
# into a dated quarantine root instead of an instant rm -rf. Same-filesystem
# mv is a rename (near-zero cost, frees no space immediately) so a later
# --large run can still purge_aged_archives() once the retention window
# passes, giving a real recovery window before space is reclaimed.
archive_classify() {  # <path>: sets _ARCH_CANON/_ARCH_RETENTION; rc 1 on refusal (logged)
  local path="$1" c14_verdict="" secret_out="" secret_rc=0 repo_verdict=""
  secret_out="$(/usr/bin/find "$path" \( -iname '.env*' -o -iname '*.pem' -o -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' \
    -o -iname 'id_rsa*' -o -iname 'id_ed25519*' -o -iname 'id_ecdsa*' -o -iname 'id_dsa*' -o -iname .npmrc \
    -o -iname .netrc -o -iname '*credentials*' -o -iname 'secrets*' \) ! \( -name '*.pyc' \( -path '*/node_modules/*' -o -path '*/site-packages/*' -o -path '*/venv/*' -o -path '*/.venv/*' \) \) \
    -print -quit 2>/dev/null)" || secret_rc=$?
  if (( secret_rc != 0 )); then
    c14_verdict="kept:check-failed"
  elif [[ -n "$secret_out" ]]; then
    c14_verdict="kept:secret-like"
  else
    repo_verdict="$(c14_repos_ok "$path" "" "${ACT_DEADLINE_AT:-}")" || c14_verdict="${repo_verdict:-kept:check-failed}"
  fi
  if [[ -n "$c14_verdict" ]]; then
    log "Skipping archive candidate (C14 $c14_verdict): $path"
    cleanup_tmp_count_candidate_result "$c14_verdict"
    return 1
  fi
  # Declared-ephemeral retention: without a row the receipt says 0 minutes and
  # C14 never purges, so same-volume archiving would grow forever.
  _ARCH_CANON="$(cd "$path" 2>/dev/null && pwd -P)" || _ARCH_CANON="$path"
  if ! _ARCH_RETENTION="$(c14_ephemeral_retention "$_ARCH_CANON")"; then
    log "Skipping archive candidate (C14 kept:unproven-content): $path"
    cleanup_tmp_count_candidate_result kept:unproven-content
    return 1
  fi
  return 0
}

archive_path() {
  local path="$1" kb="$2" sub="${3:-}" ts dest entry receipt safety_reason canon="" retention=""
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$ARCHIVE_ROOT/$ts${sub:+/$sub}"

  # Every refusal gate runs for BOTH dry-run and clean so a preview reports
  # exactly what a clean run would do (CodeRabbit #207). The safety gate is
  # shared; the clean path also enforces the deadline budget before classifying.
  if ! safety_reason="$(safety_gate "$path" 2>/dev/null)"; then
    log "SAFETY-SKIP $path ($safety_reason)"
    return 1
  fi

  if [[ "$DRY_RUN" == true ]]; then
    archive_classify "$path" || return 1
    log "DRY RUN: would archive: $path -> $dest/  (${kb} KB)"
  else
    # Clean path keeps the historical gate order: safety -> deadline ->
    # verdict -> retention.
    if ! act_unit_fits 0; then
      log "Archive deferred:deadline-before-unit $path"
      cleanup_tmp_count_candidate_result deferred:deadline-before-unit
      return 1
    fi
    archive_classify "$path" || return 1
    canon="$_ARCH_CANON"
    retention="$_ARCH_RETENTION"
    if ! mkdir -p "$dest"; then
      log "ERROR: could not create archive destination: $dest"
      return 2
    fi
    entry="$dest/${path##*/}"
    receipt="$entry.c14-origin.json"
    if ! python3 "$SCRIPT_DIR/c14_probe.py" archive-receipt "$canon" "$receipt" "" "$retention"; then
      log "ERROR: could not write archive origin receipt: $receipt"
      return 2
    fi
    # Receipt preparation can consume the remaining budget. Keep its evidence
    # (as on a failed mv), but never relocate the source after that expiry.
    if ! act_unit_fits 0; then
      log "Archive deferred:deadline-before-unit $path"
      cleanup_tmp_count_candidate_result deferred:deadline-before-unit
      return 1
    fi
    log "Archiving: $path -> $dest/  (${kb} KB)"
    if ! mv "$path" "$dest/"; then
      log "ERROR: could not archive: $path -> $dest/"
      return 2
    fi
    deletion_log "cleanup_tmp.sh" "archive" "$kb" "$path -> $dest/"
  fi
  echo "$kb"
}

# warn_if_long_lived <dir> <age_hours> — loud signal when an archive entry
# has dodged the purge for more than two retention windows: something is
# keeping quarantined data alive and the operator should look at it before
# the LARGE_TMP_ARCHIVE_MAX_HOURS hard cap eventually force-purges it.
warn_if_long_lived() {
  local d="$1" age_hours="$2"
  local warn_after=$(( LARGE_TMP_ARCHIVE_RETENTION_HOURS * 2 ))
  if (( age_hours > warn_after )); then
    log "WARNING: archive entry still alive after ${age_hours}h (>2x retention ${LARGE_TMP_ARCHIVE_RETENTION_HOURS}h; hard cap ${LARGE_TMP_ARCHIVE_MAX_HOURS}h): $d"
  fi
}

# purge_archive_entry <d> <mins> — apply the retention/activity/C14 gates to one
# archived candidate unit. Mutates TOTAL_KB/DIRS_DELETED. Never recurses into
# unknown archive bytes: only the named unit is a candidate, and removal is
# delegated to C14 (which re-validates the origin receipt).
archive_overcap_kept() {
  log "archive_overcap_kept path=$1 reason=$2"
  [[ "$DRY_RUN" == true ]] && return 0
  python3 - "$SCRIPT_DIR" "$1" "$2" <<'PY' || log "archive alert recording failed"
import os, sys
sys.path.insert(0, sys.argv[1])
import budget_history
state = os.environ.get("DISK_MAGICIAN_STATE_DIR", os.path.expanduser("~/.disk_magician_state"))
budget_history.record_event(state, "archive_overcap_kept", path=sys.argv[2], reason=sys.argv[3])
PY
}

purge_archive_entry() {
  local d="$1" mins="$2"
  local kb entry_mtime age_hours result size_unknown=false now_epoch
  now_epoch="$(date +%s)"
  # Size first because du can be slow. All safety probes follow it, with the
  # open-file check last immediately before the destructive operation.
  kb=$(path_size_kb "$d")
  size_unknown=false
  (( kb < 0 )) && { size_unknown=true; kb=0; }
  # Hard cap (bead jleechan-mtow): past LARGE_TMP_ARCHIVE_MAX_HOURS the
  # entry is purged even if activity probes would keep it — otherwise a
  # process holding fds into the archive keeps it alive unboundedly. If
  # the entry's mtime can't be read, fall through to the guarded path
  # (fail closed toward keeping data, not toward the cap).
  # BSD stat returns an epoch for -f %m; GNU stat treats -f as a
  # filesystem query and can succeed with nonnumeric output. Validate the
  # result before arithmetic, then use GNU -c %Y or fail closed to now.
  local stat_mtime=""
  stat_mtime="$(stat -f %m "$d" 2>/dev/null)" || stat_mtime=""
  if [[ ! "$stat_mtime" =~ ^[0-9]+$ ]]; then
    stat_mtime="$(stat -c %Y "$d" 2>/dev/null)" || stat_mtime=""
  fi
  [[ "$stat_mtime" =~ ^[0-9]+$ ]] || stat_mtime="$now_epoch"
  entry_mtime="$stat_mtime"
  age_hours=$(( (now_epoch - entry_mtime) / 3600 ))
  # Not yet aged out (find -mmin equivalent for receipt-discovered units).
  (( now_epoch - entry_mtime <= mins * 60 )) && return 0
  if [[ "$size_unknown" == true ]]; then
    log "Skipping aged archive (size unknown): $d"
    if (( age_hours > LARGE_TMP_ARCHIVE_MAX_HOURS )); then
      archive_overcap_kept "$d" size-unknown
    fi
    return 0
  fi
  if has_active_marker "$d"; then
    log "Skipping marked-active aged archive: $d"
    if (( age_hours > LARGE_TMP_ARCHIVE_MAX_HOURS )); then
      archive_overcap_kept "$d" active-marker
    else
      warn_if_long_lived "$d" "$age_hours"
    fi
    return 0
  fi
  if has_recent_activity "$d" "$LARGE_TMP_ACTIVE_HOURS"; then
    log "Skipping recently-active aged archive: $d"
    if (( age_hours > LARGE_TMP_ARCHIVE_MAX_HOURS )); then
      archive_overcap_kept "$d" recent-activity
    else
      warn_if_long_lived "$d" "$age_hours"
    fi
    return 0
  fi
  if has_open_files "$d"; then
    log "Skipping in-use aged archive: $d"
    if (( age_hours > LARGE_TMP_ARCHIVE_MAX_HOURS )); then
      archive_overcap_kept "$d" open-file
    else
      warn_if_long_lived "$d" "$age_hours"
    fi
    return 0
  fi
  if (( age_hours > LARGE_TMP_ARCHIVE_MAX_HOURS )); then
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY RUN: would request C14 purge for over-cap archive (${age_hours}h > max ${LARGE_TMP_ARCHIVE_MAX_HOURS}h): $d  (${kb} KB)"
    else
      result="$(DM_DELETION_LOGGED=1 scratch_budget_quarantine_remove "$d")"
      cleanup_tmp_count_candidate_result "$result"
      if [[ "$result" == removed:* ]]; then
        log "Purged over-cap archive after C14 approval (${age_hours}h > max ${LARGE_TMP_ARCHIVE_MAX_HOURS}h): $d  (${kb} KB)"
        deletion_log "cleanup_tmp.sh" "purge_archive_overcap" "$kb" "$d"
      else
        archive_overcap_kept "$d" "$result"
        return 0
      fi
    fi
    TOTAL_KB=$(( TOTAL_KB + kb ))
    DIRS_DELETED=$(( DIRS_DELETED + 1 ))
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would purge aged archive (>${LARGE_TMP_ARCHIVE_RETENTION_HOURS}h): $d  (${kb} KB)"
  else
    result="$(DM_DELETION_LOGGED=1 scratch_budget_quarantine_remove "$d")"
    cleanup_tmp_count_candidate_result "$result"
    if [[ "$result" == removed:* ]]; then
      log "Purged aged archive after C14 approval (>${LARGE_TMP_ARCHIVE_RETENTION_HOURS}h): $d  (${kb} KB)"
      deletion_log "cleanup_tmp.sh" "purge_archive" "$kb" "$d"
    else
      log "Skipping aged archive (C14 $result): $d"
      warn_if_long_lived "$d" "$age_hours"
      return 0
    fi
  fi
  TOTAL_KB=$(( TOTAL_KB + kb ))
  DIRS_DELETED=$(( DIRS_DELETED + 1 ))
  return 0
}

# purge_aged_archives — permanently remove C14-approved inactive archive entries older than
# LARGE_TMP_ARCHIVE_RETENTION_HOURS. Safety checks run again at purge time
# because quarantined content can become active during its recovery window.
# The former age-only hard cap now reports a kept entry instead of bypassing
# C14 activity, ownership, provenance, and quarantine checks.
purge_aged_archives() {
  [[ -d "$ARCHIVE_ROOT" ]] || return 0
  local scan_hours mins d
  scan_hours="$LARGE_TMP_ARCHIVE_RETENTION_HOURS"
  (( LARGE_TMP_ARCHIVE_MAX_HOURS < scan_hours )) && scan_hours="$LARGE_TMP_ARCHIVE_MAX_HOURS"
  mins=$(( scan_hours * 60 ))
  # Depth-2 units: top-level archives at "$ARCHIVE_ROOT/<ts>/<unit>". Raw
  # (unreceipted) directories stay visible here so their keep/over-cap reason
  # is still reported; C14 refuses to remove them. Skip depth-2 container
  # directories whose children carry depth-3 origin receipts below.
  while IFS= read -r -d '' d; do
    if [[ ! -e "$d.c14-origin.json" && ! -L "$d.c14-origin.json" ]] &&
       [[ -n "$(/usr/bin/find "$d" -mindepth 1 -maxdepth 1 -type f -name '*.c14-origin.json' -print -quit 2>/dev/null || true)" ]]; then
      continue
    fi
    purge_archive_entry "$d" "$mins"
  done < <(/usr/bin/find "$ARCHIVE_ROOT" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null || true)
  # Descended container children live at "$ARCHIVE_ROOT/<ts>/<container>/<unit>"
  # and are discovered by their origin receipts, never by blindly walking and
  # deleting container bytes. Each receipt names exactly one candidate unit;
  # C14 re-validates the receipt's identity + E2 row before removal. A
  # receipt-less container is left untouched (its own bytes are never removed
  # here). The receipt sidecar itself is provenance metadata and is preserved.
  # The receipt is a SIBLING file of its unit, one level below the container:
  # "$ARCHIVE_ROOT/<ts>/<container>/<unit>.c14-origin.json" is depth 3, so the
  # scan is bounded to that exact depth — never deeper, which would descend
  # into archived content and could name an arbitrary inner path.
  while IFS= read -r -d '' d; do
    d="${d%.c14-origin.json}"
    [[ -d "$d" && ! -L "$d" ]] || continue
    purge_archive_entry "$d" "$mins"
  done < <(/usr/bin/find "$ARCHIVE_ROOT" -mindepth 3 -maxdepth 3 -type f -name '*.c14-origin.json' -print0 2>/dev/null || true)
}

log "$(dry_prefix)cleanup_tmp.sh starting"

DIRS_DELETED=0
FILES_DELETED=0
TOTAL_KB=0
DIRS_ARCHIVED=0
ARCHIVED_KB=0

# Scan all temp directories for git clones & validation scratch dirs
for tmp_dir in "${TMP_DIRS[@]}"; do
  [[ -d "$tmp_dir" ]] || continue
  log "Scanning $tmp_dir ..."

  # 1. Any directory containing a .git folder and older than GIT_CLONE_MIN
  while IFS= read -r -d '' subdir; do
    [[ -d "$subdir/.git" ]] || continue
    if is_protected_tmp_path "$subdir"; then
      log "Skipping protected root (in PROTECTED_TMP_ROOTS): $subdir"
      continue
    fi
    # Skip essential system or user active directories
    case "$(basename "$subdir")" in
      claude-*|system-*|com.apple.*|PowerlogHelperd*|_disk_magician_archive*) continue ;;
    esac
    if [[ "$DRY_RUN" != true && -n "$USER_TMP" && "$tmp_dir" == "$USER_TMP" && -z "${DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE:-}" ]]; then
      if ! repo_v="$(c14_repos_ok "$subdir" "" "${ACT_DEADLINE_AT:-}" 2>/dev/null)"; then
        log "Preserving (C14 ${repo_v:-kept:check-failed}): $subdir"
        cleanup_tmp_count_candidate_result "${repo_v:-kept:check-failed}"
        continue
      fi
    fi

    remove_path "$subdir"
    kb="$REMOVE_PATH_KB"
    if [[ "$REMOVE_PATH_COMPLETED" == true ]]; then
      TOTAL_KB=$(( TOTAL_KB + kb ))
      DIRS_DELETED=$(( DIRS_DELETED + 1 ))
    fi
  done < <(find "$tmp_dir" -mindepth 1 -maxdepth 2 -type d \
              -mmin "+${GIT_CLONE_MIN}" -print0 2>/dev/null || true)

  # 2. agent_prompt_*.txt files older than AGENT_PROMPT_MIN
  while IFS= read -r -d '' f; do
    files_completed=0
    local_kb=$(path_size_kb "$f")
    if (( local_kb < 0 )); then
      log "Skipping (size unknown): $f"
      continue
    fi
    if [[ "$DRY_RUN" == true ]]; then
      log "DRY RUN: would remove: $f  (${local_kb} KB)"
      files_completed=1
    else
      log "Requesting C14 removal: $f  (${local_kb} KB)"
      if ! _safety_reason="$(safety_gate "$f" 2>/dev/null)"; then
        echo "SAFETY-SKIP "$f" ($_safety_reason)"
      else
        result="$(DM_DELETION_LOGGED=1 scratch_budget_quarantine_remove "$f")"
        cleanup_tmp_count_candidate_result "$result"
        if [[ "$result" == removed:* ]]; then
          deletion_log "cleanup_tmp.sh" "remove" "$local_kb" "$f"
          files_completed=1
        else
          log "Preserving (C14 $result): $f"
        fi
      fi
    fi
    if [[ "${files_completed:-0}" == 1 ]]; then
      TOTAL_KB=$(( TOTAL_KB + local_kb ))
      FILES_DELETED=$(( FILES_DELETED + 1 ))
    fi
  done < <(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type f \
              -name "agent_prompt_*.txt" \
              -mmin "+${AGENT_PROMPT_MIN}" -print0 2>/dev/null || true)

  # 3. cli_validation_gemini_* dirs older than CLI_VALIDATION_MIN
  while IFS= read -r -d '' d; do
    if is_protected_tmp_path "$d"; then
      log "Skipping protected root (in PROTECTED_TMP_ROOTS): $d"
      continue
    fi
    remove_path "$d"
    kb="$REMOVE_PATH_KB"
    if [[ "$REMOVE_PATH_COMPLETED" == true ]]; then
      TOTAL_KB=$(( TOTAL_KB + kb ))
      DIRS_DELETED=$(( DIRS_DELETED + 1 ))
    fi
  done < <(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d \
              -name "cli_validation_gemini_*" \
              -mmin "+${CLI_VALIDATION_MIN}" -print0 2>/dev/null || true)

  # 4. Worktree-linked dirs: .git is a file (worktree pointer) pointing at
  #    <parent_repo>/.git/worktrees/<name>/. Safety:
  #      - parse the "gitdir:" line
  #      - confirm the resolved gitdir exists
  #      - confirm it lives under a parent repo's .git/worktrees/
  #      - confirm the parent repo is NOT currently checked out to this worktree
  #      - honor the worktree-pointer mtime + min-size filters
  while IFS= read -r -d '' subdir; do
    # .git must be a regular file (worktree pointer), not a directory
    [[ -f "$subdir/.git" ]] || continue
    if is_protected_tmp_path "$subdir"; then
      log "Skipping protected root (in PROTECTED_TMP_ROOTS): $subdir"
      continue
    fi
    # Skip essential system or user active directories
    case "$(basename "$subdir")" in
      claude-*|system-*|com.apple.*|PowerlogHelperd*|_disk_magician_archive*) continue ;;
    esac

    # Parse the gitdir: line from the pointer file
    gitdir_line=$(head -n 1 "$subdir/.git" 2>/dev/null || true)
    [[ "$gitdir_line" == gitdir:* ]] || continue
    gitdir_path="${gitdir_line#gitdir: }"
    # Resolve relative paths against the worktree dir
    if [[ "$gitdir_path" != /* ]]; then
      gitdir_path="$subdir/$gitdir_path"
    fi
    # Normalize via cd + pwd
    gitdir_path=$(cd "$subdir" && cd "$gitdir_path" 2>/dev/null && pwd) || continue
    [[ -d "$gitdir_path" ]] || continue

    # Confirm the gitdir lives under some <repo>/.git/worktrees/<name>
    case "$gitdir_path" in
      */.git/worktrees/*) : ;;
      *) continue ;;
    esac

    # Derive the parent repo's .git path
    parent_git_dir=$(echo "$gitdir_path" | sed -E 's#/\.git/worktrees/[^/]+/?\$##')
    [[ -d "$parent_git_dir" ]] || continue

    # Derive the parent repo's work-tree (working dir)
    parent_work_tree=$(git -C "$parent_git_dir" rev-parse --show-toplevel 2>/dev/null || true)
    [[ -n "$parent_work_tree" && -d "$parent_work_tree" ]] || continue

    # Safety: the worktree must NOT be the currently checked-out branch of the parent repo
    current_link=$(readlink "$parent_git_dir" 2>/dev/null || true)
    if [[ -n "$current_link" ]]; then
      # If HEAD points into the same worktrees/<name>/ we're considering, skip
      case "$current_link" in
        *"/worktrees/$(basename "$subdir")"|*"/worktrees/$(basename "$subdir")/") continue ;;
      esac
    fi
    # Also skip if the worktree dir IS the parent repo's toplevel
    if [[ "$(cd "$subdir" && pwd)" == "$(cd "$parent_work_tree" && pwd)" ]]; then
      continue
    fi

    # Worktree safety rule floor (same WORKTREE_MIN_AGE_DAYS as the other
    # worktree-cleanup scripts)
    if worktree_is_recently_active "$subdir" "$WORKTREE_MIN_AGE_DAYS"; then
      log "Skipping recently active worktree pointer (<${WORKTREE_MIN_AGE_DAYS}d): $subdir"
      continue
    fi

    # Unsaved work guard
    if worktree_has_unsaved_work "$subdir"; then
      log "Skipping worktree pointer with unsaved work: $subdir"
      continue
    fi

    # Size filter
    kb=$(path_size_kb "$subdir")
    if (( kb < 0 )); then
      log "Skipping (size unknown): $subdir"
      continue
    fi
    if [[ "$kb" -lt "$WORKTREE_POINTER_MIN_KB" ]]; then
      log "Skipping (under min size ${WORKTREE_POINTER_MIN_KB} KB): $subdir  (${kb} KB)"
      continue
    fi

    remove_path "$subdir"
    kb="$REMOVE_PATH_KB"
    if [[ "$REMOVE_PATH_COMPLETED" == true ]]; then
      TOTAL_KB=$(( TOTAL_KB + kb ))
      DIRS_DELETED=$(( DIRS_DELETED + 1 ))
    fi
  done < <(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d \
              -mmin "+${WORKTREE_POINTER_MIN}" -print0 2>/dev/null || true)
done

if [[ "$INCLUDE_OPENCODE_DYLIBS" == true ]]; then
  log "Scanning DARWIN_USER_TEMP_DIR for OpenCode libopentui dylibs ..."
  if [[ -z "$USER_TMP" || ! -d "$USER_TMP" ]]; then
    log "Skipping OpenCode dylibs: DARWIN_USER_TEMP_DIR is unavailable"
  elif ! command -v otool >/dev/null 2>&1; then
    log "Skipping OpenCode dylibs: otool is unavailable"
  elif [[ "$DRY_RUN" != true ]] && ! command -v lsof >/dev/null 2>&1; then
    log "Skipping OpenCode dylibs: lsof is unavailable, cannot prove files are closed"
  else
    dylib_candidate_file=$(mktemp -t disk-magician-opencode-dylibs.XXXXXX)
    find "$USER_TMP" -mindepth 1 -maxdepth 1 -type f \
      -name '.*.dylib' -print0 2>/dev/null > "$dylib_candidate_file" || true

    open_dylibs=""
    lsof_rc=0
    if command -v lsof >/dev/null 2>&1; then
      set +e
      lsof_output=$(lsof +D "$USER_TMP" -Fn 2>/dev/null)
      lsof_rc=$?
      set -e
      open_dylibs=$(sed -n 's/^n//p' <<<"$lsof_output")
    fi
    if [[ "$DRY_RUN" != true && "$lsof_rc" -gt 1 ]]; then
      log "Skipping OpenCode dylibs: lsof failed (rc=${lsof_rc}), cannot prove files are closed"
    else
      dylib_candidates=0
      dylib_deleted=0
      while IFS= read -r -d '' f; do
        [[ -f "$f" ]] || continue
        otool_output=$(otool -D "$f" 2>/dev/null || true)
        grep -Fxq '@rpath/libopentui.dylib' <<<"$otool_output" || continue
        dylib_candidates=$(( dylib_candidates + 1 ))
        if grep -Fxq "$f" <<<"$open_dylibs"; then
          log "Skipping in-use OpenCode dylib: $f"
          continue
        fi
        if [[ "$DRY_RUN" == true ]]; then
          log "DRY RUN: would remove closed OpenCode dylib: $f"
        else
          dylib_remove_result=kept:check-failed
          if ! _safety_reason="$(safety_gate "$f" 2>/dev/null)"; then
            echo "SAFETY-SKIP "$f" ($_safety_reason)"
          else
            dylib_remove_result="$(DM_DELETION_LOGGED=1 scratch_budget_quarantine_remove "$f")"
            cleanup_tmp_count_candidate_result "$dylib_remove_result"
            if [[ "$dylib_remove_result" == removed:* ]]; then
              deletion_log "cleanup_tmp.sh" "remove_dylib" 0 "$f"
              dylib_deleted=$(( dylib_deleted + 1 ))
            else
              log "Preserving OpenCode dylib (C14 $dylib_remove_result): $f"
            fi
          fi
        fi
      done < "$dylib_candidate_file"
      log "$(dry_prefix)OpenCode dylibs: candidates ${dylib_candidates}, deleted ${dylib_deleted}"
      FILES_DELETED=$(( FILES_DELETED + dylib_deleted ))
    fi
    if ! _safety_reason="$(safety_gate "$dylib_candidate_file" 2>/dev/null)"; then
      echo "SAFETY-SKIP "$dylib_candidate_file" ($_safety_reason)"
    else
      rm -f "$dylib_candidate_file"
    fi
    dylib_candidate_file=""
  fi
fi

# is_scratch_container <dir> — explicitly known non-git container that holds
# child directories.  Exact basename membership proves the children are
# independent cleanup units; arbitrary active directories remain atomic.
is_scratch_container() {
  local d="$1" base root hit
  base="$(basename "$d")"
  for root in "${SCRATCH_CONTAINER_ROOTS[@]}"; do
    [[ "$base" == "$root" ]] || continue
    [[ -e "$d/.git" || -L "$d/.git" ]] && return 1
    hit="$(/usr/bin/find "$d" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)"
    [[ -n "$hit" ]]
    return
  done
  return 1
}

# container_child_has_protected_repository <child> — true when a descended
# cleanup unit contains any repository/worktree that is too recent or cannot
# be proved clean and pushed.  Repositories may live several levels below the
# immediate container child (runtime/run-id/repo), so checking only
# <child>/.git can lose nested work. Discovery failures protect the whole child.
container_child_has_protected_repository() {
  local child="$1" marker_file marker repo rc=0 tbin
  marker_file="$(mktemp -t disk-magician-container-git.XXXXXX)" || {
    log "Skipping container child (cannot allocate nested-repository scan): $child"
    return 0
  }

  tbin="$(resolve_timeout_bin "${DISK_MAGICIAN_PROBE_TIMEOUT_BIN:-}")"
  if [[ -n "$tbin" ]]; then
    "$tbin" --kill-after=2s "${PROBE_TIMEOUT_SEC}s" \
      /usr/bin/find "$child" -name .git -prune -print0 >"$marker_file" 2>/dev/null || rc=$?
  else
    warn_unbounded_probes_once
    /usr/bin/find "$child" -name .git -prune -print0 >"$marker_file" 2>/dev/null || rc=$?
  fi
  if (( rc != 0 )); then
    rm -f "$marker_file"
    log "Skipping container child (nested-repository scan failed rc=${rc}): $child"
    return 0
  fi

  while IFS= read -r -d '' marker; do
    repo="${marker%/.git}"
    if worktree_is_recently_active "$repo" "$WORKTREE_MIN_AGE_DAYS"; then
      rm -f "$marker_file"
      log "Skipping container child with recently active nested repository/worktree (<${WORKTREE_MIN_AGE_DAYS}d): $repo (child: $child)"
      return 0
    fi
    if worktree_has_unsaved_work "$repo"; then
      rm -f "$marker_file"
      log "Skipping container child with nested repository unsaved work (uncommitted/unpushed/no-upstream): $repo (child: $child)"
      return 0
    fi
  done < "$marker_file"

  rm -f "$marker_file"
  return 1
}

# large_consider_entry <dir> <depth> — --large gates for one candidate: depth 0
# is a top-level tmp entry, depth 1 a child of a descended container.
large_consider_entry() {
  local d="$1" depth="$2" base kb archive_rc=0
  local scratch_container=false
  base="$(basename "$d")"

  case "$base" in
    com.apple.*|system-*|PowerlogHelperd*|systemd-private-*|snap-private-tmp|.X11-unix|.XIM-unix|.ICE-unix|.Test-unix|.font-unix) return 0 ;;
    # Our own quarantine root — never re-archive/delete it here;
    # purge_aged_archives() below is the only thing that touches it.
    _disk_magician_archive|.dm-quarantine) return 0 ;;
  esac
  case "$base" in
    wt_*|worktree_*)
      # Misleading-log defect (found live 2026-07-22 during the tmp-scratch
      # incident diagnosis): this used to log "Skipping ..." unconditionally
      # BEFORE the approval check, so even when TMP_WORKTREES_APPROVED=1 was
      # set and the dir was about to be evaluated normally, the log said
      # "Skipping" -- misread as the gate being broken. Only log "Skipping"
      # on the actual skip path now; the approved fall-through gets its own
      # distinct line.
      if [[ "${TMP_WORKTREES_APPROVED:-0}" != "1" ]]; then
        log "Skipping temp worktree dir (requires TMP_WORKTREES_APPROVED=1): $d"
        return 0
      fi
      # Even when approved, NEVER archive a worktree with unsaved work —
      # archiving then purging it would permanently lose uncommitted or
      # unpushed commits. cleanup_tmp is not git-recovery-aware. (codex review)
      if worktree_has_unsaved_work "$d"; then
        log "Skipping approved worktree with unsaved work (uncommitted/unpushed/no-upstream): $d"
        return 0
      fi
      log "Worktree dir approved + clean, evaluating: $d"
      ;;
  esac

  if is_protected_root "$base" || { (( depth > 0 )) && is_protected_tmp_path "$d"; }; then
    log "Skipping protected root (in PROTECTED_TMP_ROOTS): $d"
    if (( depth == 0 )); then
      scan_protected_root_children "$d"
    fi
    return 0
  fi

  if (( depth == 0 )) && is_scratch_container "$d"; then
    scratch_container=true
  fi

  # cleanup_tmp is not an exception to the canonical worktree recency floor,
  # and a child can contain repositories below its root (runtime/run-id/repo).
  # Protect the whole cleanup unit if any nested repository is recent, dirty,
  # unpushed, lacks an upstream, or cannot be measured safely.
  if (( depth > 0 )) && container_child_has_protected_repository "$d"; then
    return 0
  fi

  # Cheap recency/marker verdicts first: an entry that is too recent to touch
  # never pays for du or lsof (bead dcz: pressure step budget).
  if [[ -e "$d/.in-use" ]]; then
    log "Skipping active-use marker (.in-use present): $d"
    return 0
  fi

  if [[ "$scratch_container" != true ]] && has_active_marker "$d"; then
    log "Skipping active-use marker (.in-use present): $d"
    return 0
  fi

  # A declared scratch container is NEVER judged (or archived) as a unit: it is
  # a long-lived parent of per-task dirs, so every immediate child is evaluated
  # on its own (one level only). This must not depend on the container's own
  # mtime: with the -mindepth 1 recency probe (bead disk_magician-7871) a
  # container whose children are all stale no longer looks "recent", and
  # falling through would archive the container wholesale -- bypassing the
  # per-child C14 verdicts that tests/test_cleanup_tmp_container_descend.sh
  # t20a pins. Descend unconditionally, then let each child decide.
  if [[ "$scratch_container" == true ]]; then
    log "Descending into scratch container (children evaluated individually): $d"
    while IFS= read -r -d '' child; do
      large_consider_entry "$child" 1
    done < <(/usr/bin/find "$d" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
    return 0
  fi
  if has_recent_activity "$d" "$LARGE_TMP_ACTIVE_HOURS"; then
    log "Skipping recently active dir (mtime/ctime within ${LARGE_TMP_ACTIVE_HOURS}h): $d"
    return 0
  fi

  kb=$(path_size_kb "$d")
  if [[ "$kb" -lt 0 ]]; then
    log "Skipping large-dir candidate (size unknown): $d"
    return 0
  fi
  if [[ "$kb" -lt "$LARGE_TMP_MIN_KB" ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" != true ]] && has_open_files "$d"; then
    log "Skipping in-use large tmp dir: $d  (${kb} KB)"
    return 0
  fi

  archive_path "$d" "$kb" "$( (( depth > 0 )) && basename "$(dirname "$d")" )" >/dev/null || archive_rc=$?
  if (( archive_rc == 1 )); then
    return 0
  fi
  if (( archive_rc != 0 )); then
    log "ERROR: could not archive: $d (rc=$archive_rc); preserving and continuing"
    cleanup_tmp_count_candidate_result deferred:archive-error
    return 0
  fi
  ARCHIVED_KB=$(( ARCHIVED_KB + kb ))
  DIRS_ARCHIVED=$(( DIRS_ARCHIVED + 1 ))
}

if [[ "$INCLUDE_LARGE" == true && -z "$PRIVATE_TMP_ROOT" ]]; then
  # Fail closed (bead disk_magician-ka4): an unresolvable private-tmp root
  # (e.g. DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE pointing at a dir that
  # doesn't exist) must never silently fall back to the real /private/tmp.
  log "Skipping --large scan: private-tmp root is unavailable (resolution failed closed)"
elif [[ "$INCLUDE_LARGE" == true ]]; then
  log "Scanning $PRIVATE_TMP_ROOT for large top-level dirs >= ${LARGE_TMP_MIN_KB} KB (active-use window: ${LARGE_TMP_ACTIVE_HOURS}h, protected roots: ${PROTECTED_TMP_ROOTS[*]}, scratch containers: ${SCRATCH_CONTAINER_ROOTS[*]}) ..."
  while IFS= read -r -d '' d; do
    large_consider_entry "$d" 0
  done < <(find "$PRIVATE_TMP_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
fi

# Always purge aged archives if the archive directory exists, regardless of --large.
# This prevents _disk_magician_archive quarantine from accumulating indefinitely
# when standard/regular cleanup_tmp.sh runs occur without --large.
purge_aged_archives

# Size-budget mode (bead disk_magician-d45): evicts oldest-first,
# independent of the 24h/4h age gates above, so 0-24h scratch growth is no
# longer structurally invisible to every sweeper. Runs last so the normal
# age-based passes above get first crack at reclaiming space cheaply.
BUDGET_DIRS_DELETED=0
BUDGET_FILES_DELETED=0
BUDGET_KB_FREED=0
if [[ "$BUDGET_GB" -gt 0 ]]; then
  BUDGET_KB=$(( BUDGET_GB * 1024 * 1024 ))
  for tmp_dir in "${TMP_DIRS[@]}"; do
    [[ -d "$tmp_dir" ]] || continue
    scratch_budget_evict_root "$tmp_dir" "$BUDGET_KB" "$BUDGET_FLOOR_MINUTES"
  done
  log "$(dry_prefix)Budget mode done. Dirs evicted: ${BUDGET_DIRS_DELETED}  Files evicted: ${BUDGET_FILES_DELETED}  Total freed: ${BUDGET_KB_FREED} KB"
fi

log "$(dry_prefix)Done. Dirs removed: ${DIRS_DELETED}  Files removed: ${FILES_DELETED}  Total freed: ${TOTAL_KB} KB  (~$(( TOTAL_KB / 1024 )) MB)  Dirs archived: ${DIRS_ARCHIVED}  Total archived: ${ARCHIVED_KB} KB"
