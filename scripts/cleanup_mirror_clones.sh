#!/usr/bin/env bash
# cleanup_mirror_clones.sh — Reclaim standalone mirror/project git clones whose
# work already exists on origin (bead disk_magician-mirror-clone-sweeper-g1xz).
#
# Candidate: a directory that is itself a git checkout (its own `.git`
# DIRECTORY) at or below a configured root. Linked worktrees (`.git` is a file)
# and plain directories are NOT candidates — cleanup_worktrees.sh owns the
# registered ones and nothing here may touch them.
#
# Defaults to DRY-RUN; --clean requires WORKTREE_APPROVED=1. Every preserved
# candidate prints its reason and the run ends with a reason histogram, which is
# how an operator learns what is holding the space.
set -euo pipefail

# A caller's repository context must never leak into a clone being inspected.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure lsof is reachable on macOS where /usr/sbin may not be in a non-login PATH.
if ! command -v lsof >/dev/null 2>&1 && [[ -x /usr/sbin/lsof ]]; then
  export PATH="$PATH:/usr/sbin"
fi
if [[ -z "${DISK_MAGICIAN_LSOF_BIN:-}" ]] && command -v lsof >/dev/null 2>&1; then
  export DISK_MAGICIAN_LSOF_BIN
  DISK_MAGICIAN_LSOF_BIN="$(command -v lsof)"
fi

FIND_BIN="$(command -v find 2>/dev/null || echo /usr/bin/find)"
PYTHON="${DISK_MAGICIAN_PYTHON_EXECUTABLE:-python3}"

# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"
# shellcheck source=scripts/lib/lsof_linux.sh
source "$SCRIPT_DIR/lib/lsof_linux.sh"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$SCRIPT_DIR/lib/worktree_ignored.sh"
# shellcheck source=scripts/worktree_remove_hook.sh
source "$SCRIPT_DIR/worktree_remove_hook.sh" # wrh_ao_skip_reason

DRY_RUN=true
MAX_GIB="${DISK_MAGICIAN_MIRROR_CLONE_MAX_GIB:-25}"
MAX_DEPTH="${DISK_MAGICIAN_MIRROR_CLONE_MAX_DEPTH:-3}"
ROOTS_RAW="${DISK_MAGICIAN_MIRROR_CLONE_ROOTS:-$HOME/mirror:$HOME/projects}"
# Repos whose `.git/worktrees/*/gitdir` registrations are authoritative even when
# the repo itself sits outside the swept roots (worldarchitect.ai is the named
# registry in the bead: three mirror paths are registered there).
REGISTRY_REPOS_RAW="${DISK_MAGICIAN_MIRROR_REGISTRY_REPOS:-$HOME/projects/worldarchitect.ai}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run|--clean] [--root DIR]... [--max-gib N] [--max-depth N] [-h|--help]

Reclaim standalone git clones (own .git directory) under ~/mirror and
~/projects whose work already exists on origin. Default is a DRY RUN.

Removal requires ALL of:
  - not this script's own repository and not protected by safety.local.json
  - not owned by the AO worktree config and not referenced by a git
    worktree registration (any *.git/worktrees/*/gitdir pointer) and holding
    no live linked worktree
  - git status --porcelain --untracked-files=normal empty, no
    assume-unchanged/skip-worktree entries, no ignored secret-like file
    (shared c14_probe.py rules), no stash
  - HEAD (and every local branch tip) advertised by origin RIGHT NOW via live
    git ls-remote — stale remote-tracking refs are never used, and any
    ls-remote failure preserves the clone
  - no live process cwd inside it (shared lsof snapshot) and no open file handle
  - not the current working directory of this run

Options:
  --clean, --apply   Execute removals (default: dry-run preview).
                     Requires WORKTREE_APPROVED=1.
  --dry-run          Preview candidates without modifying disk (default).
  --root DIR         Scan root; repeatable (default: \$HOME/mirror:\$HOME/projects;
                     env DISK_MAGICIAN_MIRROR_CLONE_ROOTS).
  --max-gib N        Per-run reclaim cap in GiB (default 25; 0 = no cap).
  --max-depth N      Maximum find depth of a candidate's .git entry below a
                     root (default 3, i.e. root/<a>/<b>/.git;
                     env DISK_MAGICIAN_MIRROR_CLONE_MAX_DEPTH).
  -h, --help         Show this help.

Environment:
  WORKTREE_APPROVED=1                 Required for --clean removals.
  DISK_MAGICIAN_MIRROR_CLONE_ROOTS    Colon-separated scan roots.
  DISK_MAGICIAN_MIRROR_REGISTRY_REPOS Colon-separated worktree-registry repos
                                      (default: \$HOME/projects/worldarchitect.ai).
  DISK_MAGICIAN_DELETION_LOG          Deletion log path (default:
                                      ~/Library/Logs/disk-magician-deletions.log).
EOF
}

ROOTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean|--apply) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --root)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Error: --root requires a directory" >&2; exit 2; }
      ROOTS+=("$2"); shift 2 ;;
    --root=*)
      ROOTS+=("${1#*=}"); shift ;;
    --max-gib)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "Error: --max-gib requires an integer" >&2; exit 2; }
      MAX_GIB="$2"; shift 2 ;;
    --max-gib=*)
      [[ "${1#*=}" =~ ^[0-9]+$ ]] || { echo "Error: --max-gib requires an integer" >&2; exit 2; }
      MAX_GIB="${1#*=}"; shift ;;
    --max-depth)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "Error: --max-depth requires an integer" >&2; exit 2; }
      MAX_DEPTH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$MAX_GIB" =~ ^[0-9]+$ ]] || MAX_GIB=25
MAX_GIB=$((10#$MAX_GIB))
MAX_KB=$(( MAX_GIB * 1024 * 1024 ))
[[ "$MAX_DEPTH" =~ ^[0-9]+$ ]] || MAX_DEPTH=3
MAX_DEPTH=$((10#$MAX_DEPTH))
(( MAX_DEPTH >= 1 )) || MAX_DEPTH=1

log() { printf '%s\n' "$*"; }
dry_prefix() { [[ "$DRY_RUN" == true ]] && printf 'DRY RUN: ' || true; }

# canonical_roots <raw-list>... — print existing, non-symlink, deduped roots.
canonical_roots() {
  local raw="$1" r canon existing already
  local -a out=()
  local IFS=':'
  for r in $raw; do
    [[ -n "$r" ]] || continue
    r="${r/#\~/$HOME}"
    [[ -d "$r" && ! -L "$r" ]] || continue
    canon="$(cd "$r" 2>/dev/null && pwd -P)" || continue
    already=false
    for existing in ${out[@]+"${out[@]}"}; do
      [[ "$existing" == "$canon" ]] && { already=true; break; }
    done
    [[ "$already" == true ]] || out+=("$canon")
  done
  printf '%s\n' ${out[@]+"${out[@]}"}
}

CANONICAL_ROOTS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && CANONICAL_ROOTS+=("$line")
done < <(
  if ((${#ROOTS[@]})); then
    for r in "${ROOTS[@]}"; do canonical_roots "$r"; done
  else
    canonical_roots "$ROOTS_RAW"
  fi
)

# Explicit --root rejects a missing root; the default set may legitimately be partial.
if ((${#ROOTS[@]})); then
  for r in "${ROOTS[@]}"; do
    expanded="${r/#\~/$HOME}"
    [[ -d "$expanded" ]] || { echo "Error: --root '$r' is not a directory" >&2; exit 2; }
  done
fi

if [[ "$DRY_RUN" == false ]]; then
  if [[ "${WORKTREE_APPROVED:-0}" != "1" ]]; then
    echo "Refusing to remove mirror clones: set WORKTREE_APPROVED=1 after explicit approval."
    exit 0
  fi
  if ((${#CANONICAL_ROOTS[@]})); then
    sandbox_guard_roots "${CANONICAL_ROOTS[@]}"
  fi
fi

log "=== MIRROR CLONE SWEEP ($([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo CLEAN)) — roots: ${CANONICAL_ROOTS[*]:-none}, max-depth: ${MAX_DEPTH}, cap: ${MAX_GIB} GiB ==="

if ((${#CANONICAL_ROOTS[@]} == 0)); then
  log "nothing to do: no scan root exists (${DISK_MAGICIAN_MIRROR_CLONE_ROOTS:-$ROOTS_RAW})"
  exit 0
fi

RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dm-mirror-clones.XXXXXX")" || {
  echo "Error: cannot allocate a run directory" >&2
  exit 1
}
trap 'rm -rf "$RUN_TMP"' EXIT

REASONS_FILE="$RUN_TMP/reasons.txt"
: >"$REASONS_FILE"

# ── Worktree-registry index ────────────────────────────────────────────────
# Every registered linked-worktree path is the target of a `<admin>/gitdir`
# pointer file. Reading the pointers (instead of `git worktree list`) also sees
# registrations whose worktree directory is gone — removing a re-cloned path
# under such a pointer is exactly what would strand the registration.
REGISTRY_ROOTS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && REGISTRY_ROOTS+=("$line")
done < <(
  for r in ${CANONICAL_ROOTS[@]+"${CANONICAL_ROOTS[@]}"}; do printf '%s\n' "$r"; done
  canonical_roots "$REGISTRY_REPOS_RAW"
)

REGISTRY_INDEX="$RUN_TMP/registered-worktrees.txt"
REGISTRY_COMPLETE=true
build_registry_index() {
  local root wtadmin pointer path
  : >"$REGISTRY_INDEX" || { REGISTRY_COMPLETE=false; return 0; }
  for root in ${REGISTRY_ROOTS[@]+"${REGISTRY_ROOTS[@]}"}; do
    [[ -d "$root" ]] || continue
    # The find result is staged in a file: an rc read inside a process
    # substitution could not clear REGISTRY_COMPLETE in this shell.
    if ! "$FIND_BIN" "$root" -maxdepth $((MAX_DEPTH + 2)) -type d -path '*/.git/worktrees' \
        -print0 2>/dev/null >"$RUN_TMP/admins.$$"; then
      REGISTRY_COMPLETE=false
      rm -f "$RUN_TMP/admins.$$"
      continue
    fi
    while IFS= read -r -d '' wtadmin; do
      if ! "$FIND_BIN" "$wtadmin" -mindepth 2 -maxdepth 2 -name gitdir -type f -print0 \
        2>/dev/null >"$RUN_TMP/gitdirs.$$"; then
        REGISTRY_COMPLETE=false
        continue
      fi
      while IFS= read -r -d '' pointer; do
        if ! path="$(head -c 4096 "$pointer" 2>/dev/null)"; then
          REGISTRY_COMPLETE=false
          continue
        fi
        path="${path%$'\n'}"
        case "$path" in
          /*/.git) printf '%s\n' "${path%/.git}" >>"$REGISTRY_INDEX" ;;
          /*) printf '%s\n' "$path" >>"$REGISTRY_INDEX" ;;
        esac
      done <"$RUN_TMP/gitdirs.$$"
      rm -f "$RUN_TMP/gitdirs.$$"
    done <"$RUN_TMP/admins.$$"
    rm -f "$RUN_TMP/admins.$$"
  done
  sort -u -o "$REGISTRY_INDEX" "$REGISTRY_INDEX" 2>/dev/null || REGISTRY_COMPLETE=false
}
build_registry_index
[[ "$REGISTRY_COMPLETE" == true ]] || log "WARNING: worktree-registry scan incomplete; every candidate is preserved."

# registry_hit <path>: prints "registered-worktree" when <path> is a registered
# worktree path, contains one, or lives inside one.
registry_hit() {
  [[ -s "$REGISTRY_INDEX" ]] || return 1
  awk -v c="$1" '
    { p = $0
      if (p == "" ) next
      if (p == c || index(p, c "/") == 1 || index(c, p "/") == 1) { hit = 1; exit } }
    END { if (hit) print "registered-worktree" }' "$REGISTRY_INDEX"
}

# ── Live-cwd snapshot (one lsof observation per run) ───────────────────────
CWD_KNOWN=true
if ! lsof_snapshot_cwds; then
  CWD_KNOWN=false
  log "WARNING: live-cwd observation incomplete (${LSOF_CWD_REASON:-unknown}); every candidate is preserved."
fi

# mirror_sha_on_origin_tips <repo> <tips-file> <sha>: rc 0 when <sha> is an
# advertised origin tip or an ancestor of one (the commit exists upstream).
# Fail closed on any git error.
mirror_sha_on_origin_tips() {
  local repo="$1" tips="$2" sha="$3" have unp
  [[ -n "$sha" ]] || return 1
  [[ -s "$tips" ]] || return 1
  grep -q "^${sha}[[:space:]]" "$tips" && return 0
  have="$(awk '{print $1}' "$tips" 2>/dev/null |
    GIT_NO_LAZY_FETCH=1 git -C "$repo" cat-file --batch-check='%(objectname)' 2>/dev/null |
    grep -v ' missing$' | sed 's/^/^/')" || return 1
  [[ -n "$have" ]] || return 1
  unp="$(git -C "$repo" rev-list --stdin -n1 < <(printf '%s\n%s\n' "$sha" "$have") 2>/dev/null)" || return 1
  [[ -z "$unp" ]]
}

# candidate_reason <dir>: prints a preserve reason, or nothing when <dir> is
# eligible.
candidate_reason() {
  local dir="$1" reason wts p head_sha tips shas sh origin_url rc=0

  # This script's own checkout (or an ancestor of it) must never be a candidate.
  case "$REPO_ROOT/" in
    "$dir"/*) echo "self-repo"; return 0 ;;
  esac

  reason="$(safety_gate "$dir" 2>/dev/null)" || { echo "safety:${reason:-unreadable}"; return 0; }

  # The AO helper reports through stdout (its rc is not part of its contract).
  reason="$(wrh_ao_skip_reason "$dir" 2>/dev/null || true)"
  [[ -z "$reason" ]] || { echo "$reason"; return 0; }

  [[ "$REGISTRY_COMPLETE" == true ]] || { echo "registry-incomplete"; return 0; }
  reason="$(registry_hit "$dir")"
  [[ -z "$reason" ]] || { echo "$reason"; return 0; }

  local status_porcelain
  if ! status_porcelain="$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" status --porcelain \
      --untracked-files=normal --ignore-submodules=none 2>/dev/null)"; then
    echo "status-failed"; return 0
  fi
  if [[ -n "$status_porcelain" ]]; then
    if grep -qE '^(\?\?|!!)' <<<"$status_porcelain"; then
      echo "untracked"
    else
      echo "dirty"
    fi
    return 0
  fi

  # Shared c14_probe.py rules: assume-unchanged/skip-worktree entries and
  # ignored secret-like files; anything unprovable keeps the clone.
  has_hidden_state "$dir" && { echo "hidden-state"; return 0; }

  if [[ -n "$(git -C "$dir" stash list 2>/dev/null || echo '?stash-error')" ]]; then
    echo "stash-present"; return 0
  fi

  if ! wts="$(git -C "$dir" worktree list --porcelain 2>/dev/null)"; then
    echo "worktree-list-failed"; return 0
  fi
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$dir" ]] || continue
    [[ -e "$p" ]] || continue
    echo "linked-worktrees"; return 0
  done < <(sed -n 's/^worktree //p' <<<"$wts" | tail -n +2)

  [[ "$CWD_KNOWN" == true ]] || { echo "cwd-unknown"; return 0; }
  cwd_list_has_path "$dir" "$LSOF_CWDS" && { echo "live-cwd"; return 0; }

  if ! origin_url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || [[ -z "$origin_url" ]]; then
    echo "no-origin"; return 0
  fi
  tips="$RUN_TMP/tips.$$"
  "$PYTHON" "$SCRIPT_DIR/c14_probe.py" lsremote "$origin_url" "$dir" >"$tips" 2>/dev/null || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$tips"
    if [[ "$rc" -eq 2 ]]; then echo "lsremote-deferred"; else echo "lsremote-failed"; fi
    return 0
  fi
  if [[ ! -s "$tips" ]]; then
    rm -f "$tips"
    echo "lsremote-failed"
    return 0
  fi
  if ! head_sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"; then
    rm -f "$tips"
    echo "head-missing"
    return 0
  fi
  shas="$RUN_TMP/shas.$$"
  { printf '%s\n' "$head_sha"
    git -C "$dir" for-each-ref --format='%(objectname)' refs/heads 2>/dev/null || true
  } | sort -u >"$shas"
  while IFS= read -r sh; do
    [[ -n "$sh" ]] || continue
    mirror_sha_on_origin_tips "$dir" "$tips" "$sh" && continue
    rm -f "$tips" "$shas"
    if [[ "$sh" == "$head_sha" ]]; then echo "unpushed-head"; else echo "unpushed-branch"; fi
    return 0
  done <"$shas"
  rm -f "$tips" "$shas"

  local open_st
  open_st="$("$PYTHON" "$SCRIPT_DIR/c14_probe.py" open-file "$dir" 2>/dev/null || echo 'kept:check-failed')"
  [[ "$open_st" == "no" ]] || { echo "open-file:${open_st:-check-failed}"; return 0; }

  return 0
}

# ── Sweep ─────────────────────────────────────────────────────────────────
CANDIDATES=0
ELIGIBLE=0
REMOVED=0
CAPPED=0
REMOVED_KB=0
REAL_KB=0

for root in ${CANONICAL_ROOTS[@]+"${CANONICAL_ROOTS[@]}"}; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' gitdir; do
    dir="$(dirname "$gitdir")"
    [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || continue
    # Only a checkout with its own .git DIRECTORY: a linked worktree (.git file)
    # belongs to another repository and is never a candidate here.
    [[ -d "$dir/.git" && ! -L "$dir/.git" ]] || continue

    CANDIDATES=$(( CANDIDATES + 1 ))
    reason="$(candidate_reason "$dir")"
    if [[ -n "$reason" ]]; then
      printf '%s\n' "$reason" >>"$REASONS_FILE"
      log "KEEP [$reason] $dir"
      continue
    fi

    dir_kb="$(DM_DELETION_LOGGED=0 deletion_size_kb "$dir")"
    [[ "$dir_kb" =~ ^[0-9]+$ ]] || dir_kb=0
    origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    ELIGIBLE=$(( ELIGIBLE + 1 ))

    if (( MAX_KB > 0 )) && (( REAL_KB + dir_kb > MAX_KB )); then
      CAPPED=$(( CAPPED + 1 ))
      log "capped:max-gib $dir ($(( dir_kb / 1024 )) MB) — rerun with --max-gib to raise"
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      log "DRY RUN: would remove: $dir ($(( dir_kb / 1024 )) MB, origin=$origin)"
      REAL_KB=$(( REAL_KB + dir_kb ))
      REMOVED=$(( REMOVED + 1 ))
      continue
    fi

    if DM_DELETION_LOGGED=1 rm_logged "$dir" && [[ ! -e "$dir" ]]; then
      deletion_log_removal "$dir" "$dir_kb" remove "mirror-clone origin=$origin"
      log "removed $dir ($(( dir_kb / 1024 )) MB, origin=$origin)"
      REAL_KB=$(( REAL_KB + dir_kb ))
      REMOVED=$(( REMOVED + 1 ))
      REMOVED_KB=$(( REMOVED_KB + dir_kb ))
    else
      printf '%s\n' "remove-failed" >>"$REASONS_FILE"
      log "KEEP [remove-failed] $dir"
    fi
  done < <("$FIND_BIN" "$root" -mindepth 1 -maxdepth "$MAX_DEPTH" -name .git -type d -prune \
    -print0 2>/dev/null | LC_ALL=C sort -z)
done

if (( CANDIDATES == 0 )); then
  log "nothing to do: no standalone git clone found under: ${CANONICAL_ROOTS[*]}"
fi

PRESERVED=$(( CANDIDATES - ELIGIBLE ))
log "$(dry_prefix)Done. Candidates: ${CANDIDATES}  eligible: ${ELIGIBLE}  $([[ "$DRY_RUN" == true ]] && echo would-remove || echo removed): ${REMOVED}  preserved: ${PRESERVED}  capped: ${CAPPED}"
if [[ "$DRY_RUN" == true ]]; then
  awk -v kb="$REAL_KB" 'BEGIN { printf "Reclaimable now: %.2f GiB\n", kb / 1048576 }'
else
  awk -v kb="$REMOVED_KB" 'BEGIN { printf "Freed: %.2f GiB\n", kb / 1048576 }'
fi

if [[ -s "$REASONS_FILE" ]]; then
  log "Preserve reasons (histogram):"
  sort "$REASONS_FILE" | uniq -c | sort -rn | while read -r count reason; do
    log "  ${reason}: ${count}"
  done
fi

if [[ "$DRY_RUN" == true ]] && (( ELIGIBLE > 0 )); then
  log "Re-run with WORKTREE_APPROVED=1 $(basename "$0") --clean to remove them."
fi
