#!/bin/bash
# Per-path deleter for a HAND-VERIFIED scratch artifact list.
#
# WHY THIS EXISTS
# ---------------
# The canonical scratch pruner (`diskm scratch-prune`) can force-remove
# candidates past their safety keeps with SCRATCH_TOP_LEVEL_APPROVED=1. That
# override is GLOBAL to the pass: on 2026-11-04 it removed 76 directories that
# were outside the requested scope (86 total overrides, 8 of them
# `kept:secret-like`), because the flag applies to every candidate the scan
# reaches, not just the ones the operator inspected.
#
# This script is the alternative for a verified, explicitly-scoped cleanup: it
# deletes ONLY the absolute paths in the supplied list, re-validating each one
# immediately before removal, and writes a canonical deletion-log row for every
# removal so the audit trail survives.
#
# Safety contract (every check re-run per path, just before deletion):
#   - absolute path, exactly ONE component below $SCRATCH_ROOT
#   - basename must contain $SCOPE_MATCH (scope guard; default "advice")
#   - not a symlink; must be a real directory
#   - must not appear in $EXCLUDE_FILE (one absolute path per line)
#   - no live process whose command line mentions the path
#   - requires ADVICE_DELETE_APPROVED=1
#
# Env: SCRATCH_ROOT, SCOPE_MATCH, EXCLUDE_FILE, DISK_MAGICIAN_DELETION_LOG
set -uo pipefail

LIST="${1:-}"
SCRATCH_ROOT="${SCRATCH_ROOT:-/Volumes/diskm-scratch}"
SCOPE_MATCH="${SCOPE_MATCH:-advice}"
EXCLUDE_FILE="${EXCLUDE_FILE:-}"

if [[ -n "${DISK_MAGICIAN_DELETION_LOG:-}" ]]; then
  LOG="$DISK_MAGICIAN_DELETION_LOG"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  LOG="$HOME/Library/Logs/disk-magician-deletions.log"
else
  LOG="$HOME/.disk_magician_state/deletions.log"
fi

[[ "${ADVICE_DELETE_APPROVED:-0}" == "1" ]] || { echo "Refusing: set ADVICE_DELETE_APPROVED=1" >&2; exit 2; }
[[ -n "$LIST" && -f "$LIST" ]] || { echo "usage: $0 <path-list-file> (see header for env)" >&2; exit 2; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

PSDUMP="$(mktemp "${TMPDIR:-/tmp}/dm-adel-ps.XXXXXX")" || exit 1
ps -Ao pid,command > "$PSDUMP" 2>/dev/null || true

# in_live_use <path> -- rc 0 when a live process MAY hold this path.
#
# FAIL-CLOSED and PIPEFAIL-SAFE by construction:
#  * `producer | grep -q` is unusable under `set -o pipefail`: grep exits on the
#    first match, the producer takes SIGPIPE, and the PIPELINE reports 141 --
#    i.e. a real match reads as "not live". Measured 2026-11-04:
#      producer | grep -Fq match   ->  rc=141
#    So capture the output first, then match on the string, never on the pipe.
#  * If lsof exists but fails/times out, that is UNKNOWN, not "not live". Any
#    uncertainty returns 0 (treat as live) so the candidate is preserved.
in_live_use() {
  local p=$1 pid cwd listing
  if command -v lsof >/dev/null 2>&1; then
    if listing="$(timeout 60 lsof -nP -F n 2>/dev/null)"; then
      case "$listing" in *"$p"*) return 0 ;; esac
    else
      return 0   # probe unavailable -> preserve
    fi
  fi
  if [[ -d /proc ]]; then
    for pid in /proc/[0-9]*; do
      cwd=$(readlink "$pid/cwd" 2>/dev/null) || continue
      case "$cwd" in "$p"|"$p"/*) return 0 ;; esac
    done
  fi
  # Refresh the command-line probe PER CANDIDATE, immediately before deletion.
  # The one-time snapshot taken at startup cannot see a process that started
  # afterwards, and a process may hold the path in argv while its cwd and open
  # descriptors live elsewhere. Ignoring a failed capture is also fail-open.
  local fresh
  if ! fresh="$(timeout 30 ps -Ao pid,command 2>/dev/null)"; then
    return 0   # probe unavailable -> preserve
  fi
  [[ -n "$fresh" ]] || return 0
  case "$fresh" in *"$p"*) return 0 ;; esac
  return 1
}

deletion_log() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "advice_scratch_manual.sh" "remove" "$1" "$2" \
    >>"$LOG" 2>/dev/null
}

removed=0
skipped=0
failed=0
removed_kb=0

while IFS= read -r p || [[ -n "$p" ]]; do
  [[ -n "$p" ]] || continue

  case "$p" in
    "$SCRATCH_ROOT"/?*) ;;
    *) echo "SKIP not-a-scratch-path: $p"; skipped=$((skipped+1)); continue ;;
  esac

  rel="${p#"$SCRATCH_ROOT"/}"
  case "$rel" in
    */*) echo "SKIP nested-path: $p"; skipped=$((skipped+1)); continue ;;
  esac

  # Scope guard. A plain substring match is too weak: "notadvice-dir" contains
  # "advice" and passed, so a hand-list typo could delete an unrelated path.
  # Require the token to appear as a name-delimited segment: start of name, or
  # after a `-`/`_`/`.` separator.
  case "$rel" in
    "$SCOPE_MATCH"*|*[-_.]"$SCOPE_MATCH"*) ;;
    *) echo "SKIP out-of-scope ($SCOPE_MATCH): $p"; skipped=$((skipped+1)); continue ;;
  esac

  # A configured exclusion file that cannot be read must REFUSE the candidate,
  # not silently pass it. `[[ -f ]] && grep` makes a mistyped path look like
  # "nothing excluded", which turns the safeguard off exactly when it cannot be
  # evaluated. Proven readable once up front; re-checked here per path.
  if [[ -n "$EXCLUDE_FILE" ]]; then
    # A DIRECTORY is readable but grep fails on it, and `grep` rc>1 means the
    # read failed -- not "no match". Distinguish the three outcomes explicitly;
    # only rc 1 (a genuine no-match) may fall through to deletion.
    if [[ ! -f "$EXCLUDE_FILE" || ! -r "$EXCLUDE_FILE" ]]; then
      echo "SKIP exclusion-unreadable: $p"; skipped=$((skipped+1)); continue
    fi
    grep -Fxq "$p" "$EXCLUDE_FILE"
    case $? in
      0) echo "SKIP excluded: $p"; skipped=$((skipped+1)); continue ;;
      1) : ;;  # no match -- allowed to continue
      *) echo "SKIP exclusion-check-failed: $p"; skipped=$((skipped+1)); continue ;;
    esac
  fi

  if [[ -L "$p" ]]; then echo "SKIP symlink: $p"; skipped=$((skipped+1)); continue; fi
  if [[ ! -d "$p" ]]; then echo "SKIP not-a-dir: $p"; skipped=$((skipped+1)); continue; fi

  if in_live_use "$p"; then
    echo "SKIP live-process: $p"; skipped=$((skipped+1)); continue
  fi

  kb="$(du -x -P -sk "$p" 2>/dev/null | awk '{print $1}')"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0

  # Read-only subtrees (dr-xr-xr-x, e.g. sealed evidence trees) block rm -rf
  # from descending; grant owner-write on directories only.
  find "$p" -type d -exec chmod u+w {} + 2>/dev/null || true

  if rm -rf -- "$p" 2>/dev/null && [[ ! -e "$p" ]]; then
    # The audit row is part of the contract, not a side effect. A failed append
    # leaves a deletion nobody can account for, so it counts as a failure.
    if ! deletion_log "$kb" "$p"; then
      echo "LOGGED-FAILED (deleted but audit row missing): $p"
      failed=$((failed+1))
    fi
    removed=$((removed+1))
    removed_kb=$((removed_kb+kb))
    printf 'REMOVED %6.2f GiB  %s\n' "$(awk -v k="$kb" 'BEGIN{print k/1048576}')" "$rel"
  else
    echo "FAILED $p"
    failed=$((failed+1))
  fi
done < "$LIST"

rm -f "$PSDUMP" 2>/dev/null || true

printf '\n=== summary: %d removed (%.2f GiB), %d skipped, %d failed ===\n' \
  "$removed" "$(awk -v k="$removed_kb" 'BEGIN{print k/1048576}')" "$skipped" "$failed"

(( failed == 0 )) || exit 1
exit 0
