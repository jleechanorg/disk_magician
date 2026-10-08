#!/usr/bin/env bash
# cleanup_worktree_venvs.sh — Strip Python venvs from dormant Git worktrees.
#
# Walks configured roots (default: ~/projects) and removes venv/.venv directories
# whose parent worktree is older than --min-age days (default 7, per the
# project worktree safety rule). The worktree shell (source + .git) is preserved;
# only the venv is removed. Re-create with `python -m venv .venv && pip install -r
# requirements.txt` if the worktree is revisited.
#
# Defaults to dry-run. To actually strip, the safety rule requires the literal
# `WORKTREE_APPROVED` env var in addition to --clean, matching the worktree
# cleanup policy in the repo CLAUDE.md.
#
# --purge-bak-days N (bead disk_magician-7v3) additionally purges venv.bak.*
# dirs (timestamped backups left behind when a venv gets renamed out of the
# way instead of deleted) that are older than N days, but ONLY inside
# worktrees that already clear the --min-age recency floor — a venv.bak sitting
# in a worktree touched within the protected window stays untouched regardless
# of the bak dir's own age. Same --clean / WORKTREE_APPROVED=1 gate applies.
#
# Roots also expand to include each project's <repo>/.claude/worktrees/* agent
# working copies (not `git worktree list` entries in the parent repo's own
# metadata sense, but genuine `.git`-pointer worktrees of that repo) so both
# the venv-strip and venv.bak-purge passes reach them without depending on
# find's maxdepth math.
#
# Concurrency: an mkdir-based lock (mirrors snapshot_commit.sh's
# ~/.disk_magician_state/snapshot.lock) makes a second overlapping invocation
# skip immediately rather than run alongside the first (bead disk_magician-w7m
# — 2-3 concurrent PIDs observed after RunAtLoad was added to the launchd job).
#
# Safety invariants:
#   - Never strips a venv whose parent worktree saw ANY activity within
#     --min-age days (see scripts/lib/worktree_recency.sh — real activity, not
#     a .git-pointer or directory-mtime proxy, and fails closed to "active")
#   - Never strips a venv inside a base repo (only inside worktrees, detected
#     by the .git file pointer that `git worktree add` creates)
#   - Never strips a venv that is itself a symlink (already centralized)
#   - Never strips a venv whose parent lacks a readable .git pointer
#   - Refuses to run --clean without WORKTREE_APPROVED=1 in the environment
#   - --purge-bak-days never touches a venv.bak.* dir whose parent worktree
#     is inside the --min-age protected floor (fail closed if unmeasurable —
#     worktree_age_days's own fail-closed contract covers this)
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"
# shellcheck source=scripts/lib/worktree_recency.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/layout_standard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/layout_standard.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=true
MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-7}"
if [[ -n "${DISK_MAGICIAN_WORKTREE_ROOTS:-}" ]]; then
  IFS=',' read -r -a ROOTS <<< "$DISK_MAGICIAN_WORKTREE_ROOTS"
else
  ROOTS=("$HOME/projects")
  [[ -d "$HOME/project_worldaiclaw" ]] && ROOTS+=("$HOME/project_worldaiclaw")
  [[ -d "$HOME/wc-wt" ]] && ROOTS+=("$HOME/wc-wt")
  [[ -d "$STANDARD_WORKTREE_ROOT" ]] && ROOTS+=("$STANDARD_WORKTREE_ROOT")
fi
PURGE_BAK_DAYS=""

# Concurrency lock (bead disk_magician-w7m). Overridable for tests via
# DISK_MAGICIAN_STATE_DIR, matching pressure_sweep.sh's convention.
STATE_DIR="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
LOCK_DIR="$STATE_DIR/cleanup_worktree_venvs.lock"
LOCK_TTL_SEC="${DISK_MAGICIAN_CLEANUP_VENVS_LOCK_TTL_SEC:-3600}"

usage() {
  cat <<'EOF'
Usage: cleanup_worktree_venvs.sh [--clean] [--dry-run] [--min-age N] [--days N]
                                [--roots PATH,...] [--purge-bak-days N]
                                [-h|--help]

Safely prunes Python virtual environments in stale git worktrees (>7 days old).

Options:
  --clean                Actually strip the venvs (default: dry-run).
                         Requires WORKTREE_APPROVED=1 in env.
  --dry-run              Print what would be stripped without touching disk.
  --min-age N            Minimum worktree age in days to qualify (default: 7).
  --days N               Alias for --min-age N.
  --roots p1,p2,...      Comma-separated root dirs to scan (default: $HOME/projects).
                         Each root's <repo>/.claude/worktrees/* agent working
                         copies are scanned automatically in addition.
  --purge-bak-days N     Also purge venv.bak.* dirs older than N days, but only
                         inside worktrees already past --min-age (default: dry-run;
                         requires --clean + WORKTREE_APPROVED=1 to actually delete).
  -h, --help             Show this help.

Environment:
  WORKTREE_APPROVED=1    Required to permit --clean. Aligns with the
                         worktree-safety rule in CLAUDE.md.
  DISK_MAGICIAN_STATE_DIR  Overrides the lock directory's parent (tests only).

Examples:
  cleanup_worktree_venvs.sh --dry-run
  cleanup_worktree_venvs.sh --min-age 30 --dry-run
  WORKTREE_APPROVED=1 cleanup_worktree_venvs.sh --clean
  cleanup_worktree_venvs.sh --purge-bak-days 30 --dry-run
  WORKTREE_APPROVED=1 cleanup_worktree_venvs.sh --clean --purge-bak-days 30
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)
      DRY_RUN=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --min-age|--days)
      [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
      MIN_AGE_DAYS="$2"
      shift 2
      ;;
    --roots)
      [[ $# -ge 2 ]] || { echo "--roots requires a value" >&2; exit 2; }
      IFS=',' read -ra ROOTS <<<"$2"
      shift 2
      ;;
    --purge-bak-days)
      [[ $# -ge 2 ]] || { echo "--purge-bak-days requires a value" >&2; exit 2; }
      [[ "$2" =~ ^[0-9]+$ ]] || { echo "--purge-bak-days requires an integer" >&2; exit 2; }
      PURGE_BAK_DAYS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Staleness floor: read from safety.local.json (safety_min_stale_days), with a
# hardcoded baseline floor of 7 days. CLAUDE.md invariant: the configured floor
# may only RAISE the floor, never lower it below 7.
staleness_floor=$(safety_min_stale_days 2>/dev/null || echo 7)
if [[ "$staleness_floor" =~ ^[0-9]+$ ]]; then
  staleness_floor=$((10#$staleness_floor))
else
  staleness_floor=7
fi
[[ "$staleness_floor" -lt 7 ]] && staleness_floor=7

# Hard floor: staleness_floor days, may only be raised (env, CLI, or config), never
# lowered (CLAUDE.md invariant). Without this clamp, WORKTREE_MIN_AGE_DAYS=0
# or --min-age 0 would delete every dormant worktree regardless of age.
# Normalize via 10# BEFORE clamping: bash's `-lt`/`(( ))` parse a leading-
# zero numeral like "08" as octal (invalid digit -> arithmetic error), which
# would otherwise propagate as a fail-open crash into every downstream
# comparison, not just this clamp (found live by both /advice reviewers).
if [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]]; then
  MIN_AGE_DAYS=$((10#$MIN_AGE_DAYS))
else
  MIN_AGE_DAYS="$staleness_floor"
fi
[[ "$MIN_AGE_DAYS" -lt "$staleness_floor" ]] && MIN_AGE_DAYS="$staleness_floor"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

size_kb() {
  local path="$1"
  if [[ ! -e "$path" ]]; then echo 0; return; fi
  du -sk "$path" 2>/dev/null | awk '{print $1+0}'
}

fmt_kb() {
  local kb="${1:-0}"
  awk "BEGIN{
    if ($kb >= 1048576)  printf \"%.1fG\", $kb / 1048576
    else if ($kb >= 1024) printf \"%.0fM\", $kb / 1024
    else                  printf \"%dK\", $kb
  }"
}

# Returns 0 if the path looks like a Git worktree (has a .git *file*, the
# marker `git worktree add` creates). Returns 1 if the path is a regular
# repo (has a .git *directory*) or not a Git checkout at all.
#
# We deliberately do NOT require the gitdir target directory to still exist.
# A long-dormant worktree whose parent repo has pruned its `.git/worktrees/`
# metadata will have a .git file pointing at a missing dir — but the file's
# presence is itself the signal that this dir was created as a worktree and
# the 7d age gate is the real safety check. Demanding the gitdir also exist
# would cause us to skip exactly the worktrees we most want to drain.
is_likely_worktree() {
  local p="$1"
  local git_path="$p/.git"

  # A regular repo has a .git directory; worktrees have a .git file.
  [[ -f "$git_path" ]] || return 1

  return 0
}

# expand_roots_with_agent_worktrees <root...>
# Prints each input root, plus every <root>/.claude/worktrees,
# <root>/*/.claude/worktrees and <root>/*/*/.claude/worktrees dir (shell globs,
# no recursive find — bead disk_magician-9h3: the old depth-4 find stalled
# ~16 min on ~/projects). Those are
# AoE agent-tree working copies — genuine `.git`-pointer worktrees of their
# parent repo, but not entries in that repo's own `git worktree list` output
# in the sense worktree_hygiene.sh cares about (bead disk_magician-7v3: this
# script previously only reached them by depth-6 luck from the default
# $HOME/projects root; treating each .claude/worktrees dir as its own root
# guarantees both the venv-strip and venv.bak-purge passes reach every child
# regardless of how deeply the parent repo itself is nested).
#
# Portable dedup (no `declare -A` — macOS ships /bin/bash 3.2, matching the
# convention already documented in cleanup_tmp.sh / sweeper_health_check.sh):
# a plain "seen so far" array checked with a linear scan. Root counts here
# are small (tens, not thousands), so O(n^2) is a non-issue.
_expand_roots_seen=()
_expand_roots_already_seen() {
  local candidate="$1" s
  # Length-gate before expanding "${arr[@]}": under `set -u`, bash < 4.4
  # treats expanding an empty array as an unbound-variable error.
  if (( ${#_expand_roots_seen[@]} > 0 )); then
    for s in "${_expand_roots_seen[@]}"; do
      [[ "$s" == "$candidate" ]] && return 0
    done
  fi
  return 1
}
# _physically_under <path> <root> <root_p> — true when <path> is lexically
# under <root> (or <root_p>) AND resolves to the same place under <root_p>, i.e.
# no symlinked component between root and path, and every directory on the way
# is readable. The old `find -P` never followed symlinked dirs nor listed
# unreadable ones, so discovery must not either (no broadening).
_physically_under() {
  local rel phys
  case "$1" in "$2"/*) rel="${1#"$2"/}" ;; "$3"/*) rel="${1#"$3"/}" ;; *) return 1 ;; esac
  phys="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$rel" && "$phys" == "$3/$rel" ]] || return 1
  # find could not list an unreadable (e.g. exec-only) directory; neither may we
  while [[ "$phys" == "$3"/* ]]; do
    [[ -r "$phys" ]] || return 1
    phys="${phys%/*}"
  done
  [[ -r "$3" ]]
}
expand_roots_with_agent_worktrees() {
  _expand_roots_seen=()
  local root root_p wt_dir
  for root in "$@"; do
    if ! _expand_roots_already_seen "$root"; then
      _expand_roots_seen+=("$root")
      printf '%s\n' "$root"
    fi
    [[ -d "$root" ]] || continue
    # the old `find -P "$root"` never descended into a symlinked start point
    [[ -L "$root" ]] && continue
    root_p="$(cd "$root" && pwd -P)" || continue
    for wt_dir in "$root/.claude/worktrees" "$root"/*/.claude/worktrees "$root"/*/*/.claude/worktrees; do
      [[ -d "$wt_dir" ]] || continue
      _physically_under "$wt_dir" "$root" "$root_p" || continue
      if ! _expand_roots_already_seen "$wt_dir"; then
        _expand_roots_seen+=("$wt_dir")
        printf '%s\n' "$wt_dir"
      fi
    done
  done
}

# collect_candidate_worktrees <root...> — fills CANDIDATE_WTS with worktree
# dirs (.git FILE) found without recursive traversal (bead disk_magician-9h3):
#   - <root>/*, <root>/*/* (shell globs; never <root> itself)
#   - `git worktree list --porcelain` of any repo at those paths, kept only
#     when the listed worktree lies under the same root at depth <=5 (the old
#     find's venv scope was depth 2..6)
#   - never through a symlinked directory (the old find -P did not follow them)
# Deduped by physical path so /var and /private/var aliases count once.
CANDIDATE_WTS=()
_cand_keys=$'\n'
_add_candidate() {
  local wt="$1" key
  is_likely_worktree "$wt" || return 0
  key="$(cd "$wt" 2>/dev/null && pwd -P)" || return 0
  case "$_cand_keys" in *$'\n'"$key"$'\n'*) return 0 ;; esac
  _cand_keys="${_cand_keys}${key}"$'\n'
  CANDIDATE_WTS+=("$wt")
}
# _within_old_depth <wt> <root> <root_p> — true when <wt> lies strictly under
# root at depth <=5, so its venv sits within the old `find -mindepth 2
# -maxdepth 6` scope: the new discovery may only narrow what is stripped.
_within_old_depth() {
  local wt="$1" rel slashes
  case "$wt" in "$2"/*) rel="${wt#"$2"/}" ;; "$3"/*) rel="${wt#"$3"/}" ;; *) return 1 ;; esac
  slashes="${rel//[^\/]/}"
  [[ -n "$rel" && ${#slashes} -le 4 ]]
}
collect_candidate_worktrees() {
  local root root_p d line wt
  for root in "$@"; do
    [[ -d "$root" ]] || continue
    [[ -L "$root" ]] && continue
    root_p="$(cd "$root" && pwd -P)"
    for d in "$root"/* "$root"/*/*; do
      [[ -d "$d" ]] || continue
      _physically_under "$d" "$root" "$root_p" || continue
      _add_candidate "$d"
      [[ -d "$d/.git" ]] && command -v git >/dev/null 2>&1 || continue
      while IFS= read -r line; do
        [[ "$line" == "worktree "* ]] || continue
        wt="${line#worktree }"
        _within_old_depth "$wt" "$root" "$root_p" && _physically_under "$wt" "$root" "$root_p" \
          && _add_candidate "$wt"
      done < <(git -c core.fsmonitor=false -C "$d" worktree list --porcelain 2>/dev/null || true)
    done
  done
}

# worktree_age_days comes from scripts/lib/worktree_recency.sh, sourced at the
# top of this file.
#
# It replaces a `stat -f %m <wt>/.git` proxy that rested on a false premise:
# that the `.git` pointer file "is only touched by git operations (checkout,
# merge, rebase, status)". It is not — for a linked worktree that file is
# written once by `git worktree add` and then left alone, so it measured
# creation age. Two of 30 live worldarchitect.ai worktrees sampled 2026-07-27
# reported 20.4 days from that proxy while their newest file was 12.8 days old,
# i.e. inside the 14-day protected window they were supposed to be inside.
#
# The original rationale for NOT using the parent dir mtime still holds and is
# preserved by the shared helper: `venv` is one of the pruned directory names,
# so this script's own `rm -rf venv` cannot bump the worktree's computed
# activity and re-classify the whole dormant pool as "too young" next pass.

# Detects venv dirs that are already centralized (symlinks) or are broken
# symlinks. Returns 0 if the venv should be skipped from stripping.
is_already_centralized_or_broken() {
  local venv_path="$1"

  # -L follows the symlink; if it does not resolve, the link is broken.
  if [[ -L "$venv_path" ]]; then
    if [[ -e "$venv_path" ]]; then
      log "  skip (symlink to existing target — already centralized): $venv_path"
    else
      log "  skip (broken symlink): $venv_path"
    fi
    return 0
  fi
  return 1
}

# Concurrency guard (bead disk_magician-w7m): mkdir-based lock mirroring
# snapshot_commit.sh's ~/.disk_magician_state/snapshot.lock. Contention =
# log one line and skip this run entirely (exit 0) — never queue, never
# block, matching the repo's stated concurrent-run policy.
acquire_cleanup_venvs_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
  fi
  local held_pid age
  held_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  age=$(( $(date +%s) - $(stat -f '%m' "$LOCK_DIR" 2>/dev/null || stat -c '%Y' "$LOCK_DIR" 2>/dev/null || date +%s) ))
  if [[ "$age" -gt "$LOCK_TTL_SEC" ]] && { [[ -z "$held_pid" ]] || ! kill -0 "$held_pid" 2>/dev/null; }; then
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo $$ > "$LOCK_DIR/pid"
      trap 'rm -rf "$LOCK_DIR"' EXIT
      return 0
    fi
  fi
  log "cleanup_worktree_venvs: skipped, lock held by pid ${held_pid:-?} (age ${age}s) — not queuing"
  return 1
}

# Gate: refuse --clean without the explicit approval token, matching the
# repo worktree-safety rule (which guards against accidental mass deletion).
if [[ "$DRY_RUN" == false ]]; then
  if [[ "${WORKTREE_APPROVED:-}" != "1" ]]; then
    echo "ERROR: --clean requires WORKTREE_APPROVED=1 in the environment." >&2
    echo "       This script strips files inside Git worktrees, which the" >&2
    echo "       repo CLAUDE.md flags as requiring explicit approval." >&2
    echo "" >&2
    echo "Re-run as:" >&2
    echo "  WORKTREE_APPROVED=1 $0 --clean" >&2
    exit 3
  fi
fi

acquire_cleanup_venvs_lock || exit 0

# Expand configured roots to also cover each repo's <repo>/.claude/worktrees/*
# agent working copies (see expand_roots_with_agent_worktrees above).
# Portable read loop, not `mapfile` (macOS /bin/bash 3.2 doesn't have it).
_EXPANDED_ROOTS=()
while IFS= read -r _expanded_root; do
  [[ -n "$_expanded_root" ]] && _EXPANDED_ROOTS+=("$_expanded_root")
done < <(expand_roots_with_agent_worktrees "${ROOTS[@]}")
if (( ${#_EXPANDED_ROOTS[@]} > 0 )); then
  ROOTS=("${_EXPANDED_ROOTS[@]}")
else
  ROOTS=()
fi

log "=== STRIP DORMANT WORKTREE VENVS ==="
if [[ "$DRY_RUN" == true ]]; then
  log "Mode: dry-run (use WORKTREE_APPROVED=1 $0 --clean to actually strip)"
else
  log "Mode: CLEAN (destructive)"
fi
log "Min age:    ${MIN_AGE_DAYS} days"
log "Roots:      ${ROOTS[*]}"
if (( ${#ROOTS[@]} > 0 )); then
  collect_candidate_worktrees "${ROOTS[@]}"
fi
log "Candidate worktrees: ${#CANDIDATE_WTS[@]}"
log ""

# Candidate venv dirnames. Covers both `venv` and `.venv` (the dominant
# conventions across the 156 worktrees in ~/projects).
VENV_NAMES=(venv .venv)

# Per-venv safety: we only strip a venv whose *parent* is a worktree (not
# a base repo) AND whose parent is older than MIN_AGE_DAYS. Only direct
# <worktree>/venv and <worktree>/.venv children of CANDIDATE_WTS are checked.
TOTAL_FREED_KB=0
STRIPPED_COUNT=0
SKIPPED_NOT_WORKTREE=0
SKIPPED_TOO_YOUNG=0
SKIPPED_ALREADY_CENTRALIZED=0
SKIPPED_NO_VENV=0
INSPECTED=0

for root in "${ROOTS[@]}"; do
  [[ -d "$root" ]] || log "Root missing, skipping: $root"
done

for wt in ${CANDIDATE_WTS[@]+"${CANDIDATE_WTS[@]}"}; do
  for venv_name in "${VENV_NAMES[@]}"; do
    venv_path="$wt/$venv_name"
    [[ -L "$venv_path" || -d "$venv_path" ]] || continue
    INSPECTED=$(( INSPECTED + 1 ))
    parent="$(dirname "$venv_path")"

    # Defensive: refuse if parent is not a worktree (e.g. venv inside the
    # base repo, where the user is actively working).
    if ! is_likely_worktree "$parent"; then
      SKIPPED_NOT_WORKTREE=$(( SKIPPED_NOT_WORKTREE + 1 ))
      continue
    fi

    # Skip symlinked / broken venvs.
    if is_already_centralized_or_broken "$venv_path"; then
      SKIPPED_ALREADY_CENTRALIZED=$(( SKIPPED_ALREADY_CENTRALIZED + 1 ))
      continue
    fi

    # Age gate: parent worktree must be older than the threshold.
    age_days="$(worktree_age_days "$parent")"
    if [[ -z "$age_days" ]]; then
      log "  skip (could not stat parent): $venv_path"
      continue
    fi
    if (( age_days < MIN_AGE_DAYS )); then
      SKIPPED_TOO_YOUNG=$(( SKIPPED_TOO_YOUNG + 1 ))
      continue
    fi

    venv_kb=$(size_kb "$venv_path")
    venv_pretty=$(fmt_kb "$venv_kb")

    if [[ "$DRY_RUN" == true ]]; then
      log "  [dry-run] would strip $venv_path (${venv_pretty}, parent ${age_days}d old)"
      TOTAL_FREED_KB=$(( TOTAL_FREED_KB + venv_kb ))
      STRIPPED_COUNT=$(( STRIPPED_COUNT + 1 ))
    else
      log "  stripping $venv_path (${venv_pretty}, parent ${age_days}d old)"
      if ! _safety_reason="$(safety_gate "$venv_path" 2>/dev/null)"; then
        echo "SAFETY-SKIP $venv_path ($_safety_reason)"
      elif rm -rf "$venv_path" 2>/dev/null; then
        TOTAL_FREED_KB=$(( TOTAL_FREED_KB + venv_kb ))
        STRIPPED_COUNT=$(( STRIPPED_COUNT + 1 ))
      else
        log "    FAILED to remove $venv_path"
      fi
    fi
  done
done

log ""
log "=== Summary ==="
log "  Inspected venv dirs:    $INSPECTED"
log "  Stripped:               $STRIPPED_COUNT  ($(fmt_kb "$TOTAL_FREED_KB"))"
log "  Skipped (not worktree): $SKIPPED_NOT_WORKTREE"
log "  Skipped (too young):    $SKIPPED_TOO_YOUNG  (< ${MIN_AGE_DAYS} days old)"
log "  Skipped (centralized):  $SKIPPED_ALREADY_CENTRALIZED  (symlink / broken)"
if [[ "$DRY_RUN" == true ]]; then
  log ""
  log "This was a DRY-RUN. Re-run with WORKTREE_APPROVED=1 $0 --clean to apply."
fi

# --purge-bak-days (bead disk_magician-7v3): purge venv.bak.* dirs older than
# N days, gated by the SAME --min-age recency floor as the venv strip above —
# a worktree inside the protected window keeps its venv.bak.* dirs regardless
# of how old those dirs individually look. worktree_age_days fails closed
# (unmeasurable -> age 0 -> protected), so an unmeasurable worktree is
# automatically skipped here without extra logic.
purge_bak_dirs() {
  local purge_days="$1"
  log ""
  log "=== PURGE STALE venv.bak.* DIRS (older than ${purge_days}d, parent worktree >= ${MIN_AGE_DAYS}d) ==="

  local bak_freed_kb=0 bak_count=0 skipped_young_wt=0 skipped_young_bak=0 skipped_not_wt=0
  local wt bak_path parent bak_age_days bak_kb bak_pretty _safety_reason

  for wt in ${CANDIDATE_WTS[@]+"${CANDIDATE_WTS[@]}"}; do
    for bak_path in "$wt/venv.bak" "$wt"/venv.bak.* "$wt/.venv.bak" "$wt"/.venv.bak.*; do
      [[ -d "$bak_path" && ! -L "$bak_path" ]] || continue
      parent="$(dirname "$bak_path")"

      # Same base-repo defense as the venv strip: only ever touch a bak dir
      # whose parent is a genuine worktree, not the base repo itself.
      if ! is_likely_worktree "$parent"; then
        skipped_not_wt=$(( skipped_not_wt + 1 ))
        continue
      fi

      # Hard gate: parent worktree must be past the recency floor. Fails
      # closed — an unmeasurable parent reads as age 0, i.e. "recently
      # active", i.e. protected.
      if worktree_is_recently_active "$parent" "$MIN_AGE_DAYS"; then
        skipped_young_wt=$(( skipped_young_wt + 1 ))
        log "  skip (parent worktree < ${MIN_AGE_DAYS}d, protected): $bak_path"
        continue
      fi

      # The bak dir's own age: its rename/creation mtime, not the worktree's.
      bak_age_days=$(( ( $(date +%s) - $(stat -f '%m' "$bak_path" 2>/dev/null || stat -c '%Y' "$bak_path" 2>/dev/null || date +%s) ) / 86400 ))
      if (( bak_age_days < purge_days )); then
        skipped_young_bak=$(( skipped_young_bak + 1 ))
        continue
      fi

      bak_kb=$(size_kb "$bak_path")
      bak_pretty=$(fmt_kb "$bak_kb")

      if [[ "$DRY_RUN" == true ]]; then
        log "  [dry-run] would purge $bak_path (${bak_pretty}, ${bak_age_days}d old, parent worktree stale)"
        bak_freed_kb=$(( bak_freed_kb + bak_kb ))
        bak_count=$(( bak_count + 1 ))
      else
        log "  purging $bak_path (${bak_pretty}, ${bak_age_days}d old)"
        if ! _safety_reason="$(safety_gate "$bak_path" 2>/dev/null)"; then
          echo "SAFETY-SKIP $bak_path ($_safety_reason)"
        elif rm -rf "$bak_path" 2>/dev/null; then
          bak_freed_kb=$(( bak_freed_kb + bak_kb ))
          bak_count=$(( bak_count + 1 ))
        else
          log "    FAILED to purge $bak_path"
        fi
      fi
    done
  done

  log ""
  log "=== venv.bak purge summary ==="
  log "  Purged:                    $bak_count  ($(fmt_kb "$bak_freed_kb"))"
  log "  Skipped (not worktree):    $skipped_not_wt"
  log "  Skipped (parent < ${MIN_AGE_DAYS}d):    $skipped_young_wt"
  log "  Skipped (bak dir < ${purge_days}d): $skipped_young_bak"
  if [[ "$DRY_RUN" == true ]]; then
    log ""
    log "This was a DRY-RUN. Re-run with WORKTREE_APPROVED=1 $0 --clean --purge-bak-days ${purge_days} to apply."
  fi
}

if [[ -n "$PURGE_BAK_DAYS" ]]; then
  purge_bak_dirs "$PURGE_BAK_DAYS"
fi
