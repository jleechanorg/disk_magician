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
# Prevent macOS tar (bsdtar) from writing AppleDouble metadata (._*) files into archives
export COPYFILE_DISABLE=1

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
# --archive-to DIR: move a clone onto DIR (typically a non-POSIX volume such as
# NTFS) as <name>-<sha>.tar.zst instead of destroying it, and remove the source
# only after the archive verifies when read back FROM DIR.
ARCHIVE_TO=""
# --archive-relaxed-content-gates: with --archive-to, stop treating the gates
# whose only purpose is to prove the content exists elsewhere (dirty, untracked,
# hidden state, stash, unpushed refs) as preservation gates — the tar IS the
# copy. Gates that protect identity or prove the tree is not in use stay hard.
# OFF by default: enabling it is a data-safety decision, not a flag default.
RELAX_CONTENT_GATES=false
# Test seam: the verify test needs a tar that produces a wrong archive. Replacing
# this binary exercises the real verify path instead of bypassing it.
if [[ -n "${DISK_MAGICIAN_ARCHIVE_TAR_BIN:-}" ]]; then
  TAR_BIN="$DISK_MAGICIAN_ARCHIVE_TAR_BIN"
elif command -v gtar >/dev/null 2>&1; then
  TAR_BIN="gtar"
elif [[ -x /opt/homebrew/bin/gtar ]]; then
  TAR_BIN="/opt/homebrew/bin/gtar"
else
  TAR_BIN="tar"
fi
ZSTD_BIN="${DISK_MAGICIAN_ARCHIVE_ZSTD_BIN:-zstd}"
ARCHIVE_KB=0
ARCHIVED=0
ARCHIVE_FAILURES=0
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
  --archive-to DIR   Archive each eligible clone to DIR/<name>-<sha>.tar.zst and
                     remove the source ONLY after the archive verifies when read
                     back from DIR. DIR must be an existing directory outside
                     every scan root. tar keeps symlinks and exec bits intact,
                     so DIR may be a filesystem that cannot (NTFS).
  --archive-relaxed-content-gates
                     With --archive-to, also archive clones preserved only
                     because their content might not exist elsewhere (dirty,
                     untracked, hidden-state, stash, unpushed). The archive is
                     the copy, so those gates stop blocking. Identity and
                     in-use gates (self-repo, safety, AO, registered/live
                     worktrees, live-cwd, open-file, origin unreachable) still
                     preserve. DEFAULT OFF.
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
    --archive-to)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Error: --archive-to requires a directory" >&2; exit 2; }
      ARCHIVE_TO="${2%/}"; shift 2 ;;
    --archive-to=*)
      ARCHIVE_TO="${1#*=}"; ARCHIVE_TO="${ARCHIVE_TO%/}"; shift ;;
    --archive-relaxed-content-gates) RELAX_CONTENT_GATES=true; shift ;;
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

if [[ -n "$ARCHIVE_TO" ]]; then
  [[ -d "$ARCHIVE_TO" ]] || { echo "Error: --archive-to '$ARCHIVE_TO' is not a directory" >&2; exit 2; }
  command -v "$TAR_BIN" >/dev/null 2>&1 || { echo "Error: tar not found: $TAR_BIN" >&2; exit 2; }
  command -v "$ZSTD_BIN" >/dev/null 2>&1 || { echo "Error: zstd not found: $ZSTD_BIN" >&2; exit 2; }
  ARCHIVE_REAL="$(cd "$ARCHIVE_TO" && pwd -P)" || exit 2
  # An archive written inside a swept root would be scanned as a candidate, and
  # a root inside the archive target would archive its own output.
  for r in ${CANONICAL_ROOTS[@]+"${CANONICAL_ROOTS[@]}"}; do
    case "$ARCHIVE_REAL/" in
      "$r"/*) echo "Error: --archive-to '$ARCHIVE_REAL' is inside scan root '$r'" >&2; exit 2 ;;
    esac
    case "$r/" in
      "$ARCHIVE_REAL"/*) echo "Error: scan root '$r' is inside --archive-to '$ARCHIVE_REAL'" >&2; exit 2 ;;
    esac
  done
elif [[ "$RELAX_CONTENT_GATES" == true ]]; then
  echo "Error: --archive-relaxed-content-gates requires --archive-to" >&2
  exit 2
fi

log "=== MIRROR CLONE SWEEP ($([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo CLEAN)) — roots: ${CANONICAL_ROOTS[*]:-none}, max-depth: ${MAX_DEPTH}, cap: ${MAX_GIB} GiB$( [[ -n "$ARCHIVE_TO" ]] && printf ', archive-to: %s%s' "$ARCHIVE_TO" "$( [[ "$RELAX_CONTENT_GATES" == true ]] && printf ' (relaxed content gates)' || true )" ) ==="

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

# gated_reason <reason>: rc 0 = content gate relaxed, keep evaluating;
# rc 1 (reason printed) = preserve the clone. Only used by --archive-to's
# relaxed mode, where the archive is the copy that proves the content survives.
gated_reason() {
  if [[ "$RELAX_CONTENT_GATES" == true ]]; then
    CONTENT_GATED=true
    return 0
  fi
  echo "$1"
  return 1
}

# candidate_reason <dir>: prints a preserve reason, or nothing when <dir> is
# eligible.
candidate_reason() {
  local dir="$1" reason wts p head_sha tips shas sh origin_url rc=0

  CONTENT_GATED=false

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
      gated_reason untracked || return 0
    else
      gated_reason dirty || return 0
    fi
  fi

  # Shared c14_probe.py rules: assume-unchanged/skip-worktree entries and
  # ignored secret-like files; anything unprovable keeps the clone.
  has_hidden_state "$dir" && { gated_reason hidden-state || return 0; }

  if [[ -n "$(git -C "$dir" stash list 2>/dev/null || echo '?stash-error')" ]]; then
    gated_reason stash-present || return 0
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
    if [[ "$sh" == "$head_sha" ]]; then
      gated_reason unpushed-head || { rm -f "$tips" "$shas"; return 0; }
    else
      gated_reason unpushed-branch || { rm -f "$tips" "$shas"; return 0; }
    fi
  done <"$shas"
  rm -f "$tips" "$shas"

  local open_st
  open_st="$("$PYTHON" "$SCRIPT_DIR/c14_probe.py" open-file "$dir" 2>/dev/null || echo 'kept:check-failed')"
  [[ "$open_st" == "no" ]] || { echo "open-file:${open_st:-check-failed}"; return 0; }

  return 0
}

# ── Verified archiving (--archive-to) ─────────────────────────────────────
# ntfs_safe_name <name>: replace characters NTFS/Windows reject and strip
# trailing dots or spaces, so an archive name cannot fail to land on the target
# volume. Case collisions are handled separately by archive_target_available.
ntfs_safe_name() {
  local n="$1"
  n="${n//[<>:\"/\\|?*]/_}"
  n="$(printf '%s' "$n" | tr -d '\000-\037')"
  while [[ "$n" == *[.\ ] ]]; do n="${n%?}"; done
  [[ -n "$n" ]] || n="_"
  printf '%s' "$n"
}

# lower <s>: portable lowercase (macOS bash 3.2 has no ${s,,}).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

file_dev_ino() {
  local identity
  if identity="$(stat -c '%d:%i' "$1" 2>/dev/null)" && [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]]; then
    printf '%s\n' "$identity"
  elif identity="$(stat -f '%d:%i' "$1" 2>/dev/null)" && [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]]; then
    printf '%s\n' "$identity"
  else
    return 1
  fi
}

# archive_target_available <basename>: rc 1 when an existing archive entry
# matches case-insensitively. NTFS is case-insensitive, so `Foo-abc` and
# `foo-abc` are the same file and the second would silently replace the first.
archive_target_available() {
  local base existing
  base="$(lower "$1")"
  for existing in ${ARCHIVE_NAMES[@]+"${ARCHIVE_NAMES[@]}"}; do
    [[ "$(lower "$existing")" == "$base" ]] && return 1
  done
  if [[ -d "$ARCHIVE_REAL" ]]; then
    while IFS= read -r existing; do
      [[ -n "$existing" ]] || continue
      [[ "$(lower "$existing")" == "$base" ]] && return 1
    done < <("$FIND_BIN" "$ARCHIVE_REAL" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null)
  fi
  return 0
}

# archive_and_verify <dir>: write <ARCHIVE_REAL>/<name>-<sha>.tar.zst, prove it
# by reading it back FROM ARCHIVE_REAL, and print the target path on success.
# Every failure path prints a reason on stderr and leaves <dir> untouched.
archive_and_verify() {
  local dir="$1" base sha target part node avail_kb detail
  base="$(ntfs_safe_name "$(basename "$dir")")"
  sha="$(git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null)" || return 1
  target="$ARCHIVE_REAL/$base-$sha.tar.zst"
  archive_target_available "$(basename "$target")" || { echo "archive-name-collision" >&2; return 1; }

  avail_kb="$(df -Pk "$ARCHIVE_REAL" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$avail_kb" =~ ^[0-9]+$ ]] || { echo "archive-space-unknown" >&2; return 1; }
  node="$(deletion_size_kb "$dir")"
  [[ "$node" =~ ^[0-9]+$ ]] || node=0
  (( avail_kb > node )) || { echo "archive-space-insufficient" >&2; return 1; }

  part="$target.part-$$"
  # tar is required rather than a plain copy: it is what preserves POSIX
  # symlinks and exec bits onto a volume that cannot hold either.
  # --hard-dereference keeps each hardlink an independent regular file so the
  # manifest comparison is exact; --one-file-system matches the source manifest.
  # Names are stored as `./<path>` (tar -C <clone> .) so they compare directly
  # against the source manifest, which is root-relative.
  local -a tar_args=( -C "$dir" --zstd --one-file-system )
  if "$TAR_BIN" --version 2>/dev/null | grep -qi 'gnu tar'; then
    tar_args+=( --hard-dereference )
  fi
  if ! "$TAR_BIN" "${tar_args[@]}" \
      -cf "$part" -- . 2>"$RUN_TMP/tar.err"; then
    rm -f "$part"; echo "tar-failed" >&2; return 1
  fi
  sync 2>/dev/null || true

  if ! "$PYTHON" "$SCRIPT_DIR/lib/mirror_archive_manifest.py" source "$dir" \
      "$RUN_TMP/manifest.src.$$" >/dev/null 2>&1; then
    rm -f "$part"; echo "source-manifest-failed" >&2; return 1
  fi
  if ! "$ZSTD_BIN" -dc -- "$part" 2>"$RUN_TMP/zstd.err" \
      | "$PYTHON" "$SCRIPT_DIR/lib/mirror_archive_manifest.py" archive - \
          "$RUN_TMP/manifest.arc.$$" >/dev/null 2>&1; then
    rm -f "$part" "$RUN_TMP/manifest.src.$$"; echo "archive-unreadable" >&2; return 1
  fi
  if ! cmp -s "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$"; then
    detail="$(diff -u "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$" 2>/dev/null \
      | sed -n '3,5p' | tr '\n' ' ')"
    rm -f "$part" "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$"
    echo "archive-mismatch:${detail:- manifest differs}" >&2
    return 1
  fi

  # Atomic publish under directory mutex without clobbering
  local lock_dir="$ARCHIVE_REAL/.archive-publish.lock"
  local locked=false
  local i
  for (( i=0; i<50; i++ )); do
    if mkdir "$lock_dir" 2>/dev/null; then
      locked=true
      break
    fi
    sleep 0.1
  done
  if [[ "$locked" != true ]]; then
    rm -f "$part" "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$"
    echo "archive-lock-timeout" >&2
    return 1
  fi

  # Inside the lock: re-verify target does not exist case-insensitively
  if ! archive_target_available "$(basename "$target")" || [[ -e "$target" || -L "$target" ]]; then
    rm -f "$part" "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$"
    rmdir "$lock_dir" 2>/dev/null || true
    echo "archive-name-collision" >&2
    return 1
  fi

  # Publish via hardlink with mv -n fallback (no-clobber)
  local published=false
  if ln -- "$part" "$target" 2>/dev/null; then
    rm -f -- "$part"
    published=true
  elif [[ ! -e "$target" && ! -L "$target" ]] && mv -n -- "$part" "$target" 2>/dev/null; then
    if [[ -f "$target" && ! -e "$part" ]]; then
      published=true
    fi
  fi

  if [[ "$published" != true ]]; then
    rm -f "$part" "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$"
    rmdir "$lock_dir" 2>/dev/null || true
    echo "archive-publish-failed" >&2
    return 1
  fi
  rmdir "$lock_dir" 2>/dev/null || true

  # Re-verify the archive manifest by reading back from the published $target
  rm -f "$RUN_TMP/manifest.arc.$$"
  if ! "$ZSTD_BIN" -dc -- "$target" 2>"$RUN_TMP/zstd.err" \
      | "$PYTHON" "$SCRIPT_DIR/lib/mirror_archive_manifest.py" archive - \
          "$RUN_TMP/manifest.arc.$$" >/dev/null 2>&1; then
    rm -f "$RUN_TMP/manifest.src.$$"; echo "archive-unreadable" >&2; return 1
  fi
  if ! cmp -s "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$"; then
    detail="$(diff -u "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$" 2>/dev/null \
      | sed -n '3,5p' | tr '\n' ' ')"
    rm -f "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$"
    echo "archive-mismatch:${detail:- manifest differs}" >&2
    return 1
  fi
  rm -f "$RUN_TMP/manifest.src.$$" "$RUN_TMP/manifest.arc.$$"

  ARCHIVE_NAMES+=("$(basename "$target")")
  printf '%s\n' "$target"
}

# ── Sweep ──────────────────────────────────────────────────────────────────
CANDIDATES=0
ELIGIBLE=0
REMOVED=0
CAPPED=0
REMOVED_KB=0
REAL_KB=0
ARCHIVE_NAMES=()
if [[ -n "$ARCHIVE_TO" ]]; then
  # Seed the case-collision index from what is already on the volume.
  while IFS= read -r line; do
    [[ -n "$line" ]] && ARCHIVE_NAMES+=("$line")
  done < <("$FIND_BIN" "$ARCHIVE_REAL" -mindepth 1 -maxdepth 1 -name '*.tar.zst' -exec basename {} \; 2>/dev/null)
fi

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
    # --archive-to with --clean would otherwise need a live re-clone to recover;
    # record what the clone was so the archive name and log line stay truthful.
    dir_sha="$(git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    dir_dev_ino=""
    if [[ -n "$ARCHIVE_TO" ]] && ! dir_dev_ino="$(file_dev_ino "$dir")"; then
      printf '%s\n' "archive-identity-unavailable" >>"$REASONS_FILE"
      log "KEEP [archive-identity-unavailable] $dir (source identity could not be verified)"
      continue
    fi
    ELIGIBLE=$(( ELIGIBLE + 1 ))

    if (( MAX_KB > 0 )) && (( REAL_KB + dir_kb > MAX_KB )); then
      CAPPED=$(( CAPPED + 1 ))
      log "capped:max-gib $dir ($(( dir_kb / 1024 )) MB) — rerun with --max-gib to raise"
      continue
    fi

    if [[ -n "$ARCHIVE_TO" ]]; then
      if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN: would archive: $dir ($(( dir_kb / 1024 )) MB -> $ARCHIVE_TO, sha=$dir_sha)"
        ARCHIVE_KB=$(( ARCHIVE_KB + dir_kb ))
        REAL_KB=$(( REAL_KB + dir_kb ))
        ARCHIVED=$(( ARCHIVED + 1 ))
        continue
      fi
      if ! archive_target="$(archive_and_verify "$dir")"; then
        printf '%s\n' "archive-failed" >>"$REASONS_FILE"
        log "KEEP [archive-failed] $dir (source left intact)"
        ARCHIVE_FAILURES=$(( ARCHIVE_FAILURES + 1 ))
        continue
      fi

      # Post-archive live-use/identity recheck before rm_logged
      CWD_KNOWN=true
      if ! lsof_snapshot_cwds; then
        CWD_KNOWN=false
        log "WARNING: live-cwd observation incomplete (${LSOF_CWD_REASON:-unknown}); preserving $dir"
      fi

      post_reason="$(candidate_reason "$dir")"
      if [[ -z "$post_reason" ]]; then
        if ! current_dev_ino="$(file_dev_ino "$dir")"; then
          post_reason="identity-unavailable"
        elif [[ "$current_dev_ino" != "$dir_dev_ino" ]]; then
          post_reason="identity-changed"
        fi
      fi
      if [[ -z "$post_reason" ]]; then
        current_sha="$(git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
        if [[ "$current_sha" != "$dir_sha" ]]; then
          post_reason="head-changed"
        fi
      fi

      if [[ -n "$post_reason" ]]; then
        printf '%s\n' "$post_reason" >>"$REASONS_FILE"
        log "KEEP [post-archive-${post_reason}] $dir (verified archive retained: $archive_target)"
        continue
      fi

      if DM_DELETION_LOGGED=1 rm_logged "$dir" && [[ ! -e "$dir" ]]; then
        deletion_log_removal "$dir" "$dir_kb" remove \
          "mirror-clone-archived archive=$archive_target origin=$origin"
        log "archived $dir ($(( dir_kb / 1024 )) MB) -> $archive_target"
        ARCHIVE_KB=$(( ARCHIVE_KB + dir_kb ))
        ARCHIVED=$(( ARCHIVED + 1 ))
        REAL_KB=$(( REAL_KB + dir_kb ))
        REMOVED=$(( REMOVED + 1 ))
      else
        printf '%s\n' "remove-failed" >>"$REASONS_FILE"
        log "KEEP [remove-failed] $dir (verified archive retained: $archive_target)"
      fi
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
if [[ -n "$ARCHIVE_TO" ]]; then
  log "$(dry_prefix)Done. Candidates: ${CANDIDATES}  eligible: ${ELIGIBLE}  $([[ "$DRY_RUN" == true ]] && echo would-archive || echo archived): ${ARCHIVED}  archive-failures: ${ARCHIVE_FAILURES}  preserved: ${PRESERVED}  capped: ${CAPPED}"
else
  log "$(dry_prefix)Done. Candidates: ${CANDIDATES}  eligible: ${ELIGIBLE}  $([[ "$DRY_RUN" == true ]] && echo would-remove || echo removed): ${REMOVED}  preserved: ${PRESERVED}  capped: ${CAPPED}"
fi
if [[ "$DRY_RUN" == true ]]; then
  awk -v kb="$REAL_KB" 'BEGIN { printf "Reclaimable now: %.2f GiB\n", kb / 1048576 }'
  if [[ -n "$ARCHIVE_TO" ]]; then
    awk -v kb="$ARCHIVE_KB" 'BEGIN { printf "Would archive: %.2f GiB (measured from source tree)\n", kb / 1048576 }'
  fi
else
  if [[ -n "$ARCHIVE_TO" ]]; then
    awk -v kb="$ARCHIVE_KB" 'BEGIN { printf "Archived and verified: %.2f GiB\n", kb / 1048576 }'
  else
    awk -v kb="$REMOVED_KB" 'BEGIN { printf "Freed: %.2f GiB\n", kb / 1048576 }'
  fi
fi

if [[ -s "$REASONS_FILE" ]]; then
  log "Preserve reasons (histogram):"
  sort "$REASONS_FILE" | uniq -c | sort -rn | while read -r count reason; do
    log "  ${reason}: ${count}"
  done
fi

if [[ "$DRY_RUN" == true ]] && (( ELIGIBLE > 0 )); then
  if [[ -n "$ARCHIVE_TO" ]]; then
    log "Re-run with WORKTREE_APPROVED=1 $(basename "$0") --clean --archive-to $ARCHIVE_TO to archive them."
  else
    log "Re-run with WORKTREE_APPROVED=1 $(basename "$0") --clean to remove them."
  fi
fi
