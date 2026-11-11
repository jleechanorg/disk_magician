#!/usr/bin/env bash
# cleanup_dev_caches.sh — Cleanup dev tool caches that rebuild automatically.
#
# Defaults to actually deleting (use --dry-run to preview).
set -euo pipefail

# Shared measurement is independent of lifecycle deletion eligibility.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/scratch_budget.sh"

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"
# shellcheck source=scripts/lib/quarantine.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/quarantine.sh"

DRY_RUN=true
usage() {
  cat <<EOF
Usage: $(basename "$0") [--clean] [--dry-run] [-h|--help]

Options:
  --clean     Actually perform the cleanup (default: dry-run)
  --dry-run   Print what would be deleted without actually deleting
  -h|--help   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --clean)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

resolve_existing_path() {
  local path="$1" resolved=""
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath "$path" 2>/dev/null)" || resolved=""
  fi
  if [[ -z "$resolved" ]] && command -v python3 >/dev/null 2>&1; then
    resolved="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null)" || resolved=""
  fi
  [[ -n "$resolved" && -e "$resolved" ]] || return 1
  printf '%s\n' "$resolved"
}

size_kb() {
  local path="$1"
  if [[ ! -e "$path" ]]; then echo 0; return; fi
  scratch_budget_report_measurement "$path" || exit $?
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

TOTAL_FREED_KB=0

clean_dir_contents() {
  # machine-local safety guidelines gate (safety.local.json)
  if ! _safety_reason="$(safety_gate "$2" 2>/dev/null)"; then
    log "$1: SAFETY-SKIP ($_safety_reason)"
    return
  fi
  local label="$1" path="$2" recreate="${3:-false}" kind="${4:-}"

  if [[ ! -d "$path" ]]; then
    log "$label: directory not found, skipping"
    return
  fi

  local before_kb
  before_kb=$(size_kb "$path") || exit $?
  log "$label: before $(fmt_kb "$before_kb") ($path)"

  if [[ "$DRY_RUN" == true ]]; then
    log "$label: [dry-run] would delete contents of $path"
    return
  fi

  # Per-entry so each top-level cache entry gets its own C14 verdict; a kept
  # entry (provenance-less) does not abort the rest of the sweep.
  local entry
  while IFS= read -r -d '' entry; do
    [[ "${entry##*/}" == ".dm-quarantine" ]] && continue  # quarantine's own state
    if [[ -n "$kind" ]]; then
      c14_remove "$entry" --kind "$kind" || true
    else
      c14_remove "$entry" || true
    fi
  done < <(find "$path" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

  if [[ "$recreate" == true ]]; then
    mkdir -p "$path"
  fi

  local after_kb freed_kb
  after_kb=$(size_kb "$path") || exit $?
  freed_kb=$(( before_kb - after_kb ))
  [[ $freed_kb -lt 0 ]] && freed_kb=0
  TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed_kb ))
  log "$label: after $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
}

clean_whole_dir() {
  if ! _safety_reason="$(safety_gate "$2" 2>/dev/null)"; then
    log "$1: SAFETY-SKIP ($_safety_reason)"
    return
  fi
  local label="$1" path="$2" recreate="${3:-false}" kind="${4:-rebuildable}"
  if [[ ! -d "$path" ]]; then
    log "$label: directory not found, skipping"
    return
  fi
  local before_kb
  before_kb=$(size_kb "$path") || exit $?
  log "$label: before $(fmt_kb "$before_kb") ($path)"
  if [[ "$DRY_RUN" == true ]]; then
    log "$label: [dry-run] would delete $path"
    return
  fi
  if [[ -n "$kind" ]]; then
    c14_remove "$path" --kind "$kind" || true
  else
    c14_remove "$path" || true
  fi
  if [[ "$recreate" == true ]]; then
    mkdir -p "$path"
  fi
  local after_kb freed_kb
  after_kb=$(size_kb "$path") || exit $?
  freed_kb=$(( before_kb - after_kb ))
  [[ $freed_kb -lt 0 ]] && freed_kb=0
  TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed_kb ))
  log "$label: after $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
}

# 1. ~/.gemini/tmp/
log "=== Section 1: ~/.gemini/tmp/ ==="
clean_dir_contents "gemini tmp" "$HOME/.gemini/tmp" true

# 2. ~/.cache/uv/
log "=== Section 2: ~/.cache/uv/ ==="
clean_dir_contents "uv cache" "$HOME/.cache/uv" false rebuildable

# 3. ~/.cache/pre-commit/
log "=== Section 3: ~/.cache/pre-commit/ ==="
clean_dir_contents "pre-commit cache" "$HOME/.cache/pre-commit" false rebuildable

# 3b. Rebuildable user caches (user-approved 2026-10-08: "any caches"). Apps that
# are running (cmux, Aside, Chrome, Cursor) are left to their needs_decision gates.
# Sparkle staging is the exception to "rebuildable": its entries are extracted
# .app bundles, so it carries its own C14 kind (see below).
log "=== Section 3b: rebuildable user caches ==="
_user_tmp_root="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")"
_user_tmp_root="${_user_tmp_root%/}"
for whole_cache in \
  "jest_dx user tmp:$_user_tmp_root/jest_dx" \
  "jest_dx private tmp:/private/tmp/jest_dx" \
  "worldai-ios-compilation-cache:/private/tmp/worldai-ios-compilation-cache" \
  "claude-codex-usage rust target:$HOME/claude-codex-usage/src-tauri/target" \
  "ez-gh-actions rust target:$HOME/ez-gh-actions-workdir/ez-gh-actions/target" \
  "duplicate base venv:$HOME/.worktrees/worldarchitect.ai/zr-base-venv-dup-20261027" \
  "worldarchitect-main-origin venv:$HOME/worldarchitect-main-origin/venv" \
  "conductor manado venv:$HOME/conductor/workspaces/worldarchitect.ai/manado/venv"; do
  clean_whole_dir "${whole_cache%%:*}" "${whole_cache#*:}" false rebuildable
done
for approved_cache in \
  "Codex Sparkle update staging:$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation" \
  "worldai:$HOME/.cache/worldai" \
  "swiftpm:$HOME/Library/Caches/org.swift.swiftpm" \
  "ms-playwright:$HOME/Library/Caches/ms-playwright" \
  "ms-playwright linux:$HOME/.cache/ms-playwright" \
  "pip cache:$HOME/.cache/pip" \
  "cargo cache:$HOME/.cargo/registry/cache" \
  "CocoaPods:$HOME/Library/Caches/CocoaPods" \
  "granola updater:$HOME/Library/Caches/@granolaelectron-updater" \
  "GoogleUpdater crx_cache:$HOME/Library/Application Support/Google/GoogleUpdater/crx_cache" \
  "ezgha recovery target:$HOME/.cache/ezgha-recovery-target-20261004"; do
  approved_kind=rebuildable
  # Sparkle staging has its own C14 kind: an extracted .app is not a cache format,
  # so `rebuildable` would always answer kept:unproven-content (measured). The
  # kind only releases a staged bundle once its app is installed elsewhere.
  [[ "${approved_cache%%:*}" == "Codex Sparkle update staging" ]] && approved_kind="sparkle-update-staging"
  # The ezgha recovery target is explicitly a non-cache target (spec §7.2):
  # ordinary provenance, not the fixed cache-root table.
  [[ "${approved_cache%%:*}" == "ezgha recovery target" ]] && approved_kind=""
  clean_dir_contents "${approved_cache%%:*}" "${approved_cache#*:}" false "$approved_kind"
done

# 3b-trash. User Trash ($HOME/.Trash on macOS, $HOME/.local/share/Trash on Linux):
# detach any leftover diagnostic disk image mounted under ~/.Trash/dm-volume-reclaim.*
# before running C14 rebuildable removal.
# Prioritize >=1 MiB entries in descending size order so large multi-GiB items are
# reclaimed first without spending minutes probing hundreds of 4 KiB files.
# Per-volume trash ($mountpoint/.Trash-$UID) is a separate, easily-missed root: the
# desktop creates it on a mounted volume, so garbage there is invisible to the two
# global roots above. Measured on jeff-ubuntu 2026-11-02: ~/Scratch/.Trash-1000 held
# 21.9 GB / 56 entries while the host sat at 98%. Enumerate the configured quota
# volumes and add any .Trash-<uid> they contain, deduped by realpath so a volume that
# is also a scratch root is not scanned twice. (bead disk_magician-ylu2)
_trash_roots=("$HOME/.Trash" "$HOME/.local/share/Trash")
_uid="$(id -u)"
if declare -F scratch_roots_get_volumes >/dev/null 2>&1; then
  while IFS= read -r _vol; do
    [[ -n "$_vol" && -d "$_vol" && ! -L "$_vol" ]] || continue
    _pvt="$_vol/.Trash-$_uid"
    [[ -d "$_pvt" && ! -L "$_pvt" ]] && _trash_roots+=("$_pvt")
  done < <(scratch_roots_get_volumes 2>/dev/null || true)
fi
_trash_seen=()
for _trash_root in "${_trash_roots[@]}"; do
  _rr="$(cd "$_trash_root" 2>/dev/null && pwd -P)" || continue
  [[ -n "$_rr" ]] || continue
  case " ${_trash_seen[*]-} " in *" $_rr "*) continue ;; esac
  _trash_seen+=("$_rr")
  _trash_root="$_rr"
  [[ -d "$_trash_root" && ! -L "$_trash_root" ]] || continue
  if [[ "$_trash_root" == "$HOME/.Trash" && "$DRY_RUN" != true ]] && command -v hdiutil >/dev/null 2>&1; then
    for _trash_dmg_mnt in "$_trash_root"/dm-volume-reclaim.*/diagnostic; do
      [[ -d "$_trash_dmg_mnt" ]] && hdiutil detach "$_trash_dmg_mnt" >/dev/null 2>&1 || true
    done
  fi
  if _safety_reason="$(safety_gate "$_trash_root" 2>/dev/null)"; then
    _trash_before_kb=$(size_kb "$_trash_root") || exit $?
    log "user Trash: before $(fmt_kb "$_trash_before_kb") ($_trash_root)"
    if [[ "$DRY_RUN" == true ]]; then
      log "user Trash: [dry-run] would delete contents of $_trash_root"
    else
      _trash_scan_roots=("$_trash_root")
      [[ -d "$_trash_root/files" ]] && _trash_scan_roots+=("$_trash_root/files")
      for _scan_dir in "${_trash_scan_roots[@]}"; do
        [[ ! -L "$_scan_dir" ]] || continue
        while IFS= read -r -d '' _trash_entry; do
          # Path records are NUL-delimited: du output is not a filename protocol.
          # Reject symlinks and verify canonical immediate-child containment
          # before forwarding an absolute candidate to C14.
          [[ ! -L "$_trash_entry" ]] || continue
          _canonical_entry=""
          IFS= read -r -d '' _canonical_entry < <(python3 - "$_scan_dir" "$_trash_entry" <<'PY_TRASH'
import os, sys
root, entry = map(os.path.realpath, sys.argv[1:])
if os.path.dirname(entry) == root and os.path.lexists(entry):
    sys.stdout.buffer.write(os.fsencode(entry) + b'\0')
PY_TRASH
          ) || continue
          _trash_entry="$_canonical_entry"
          [[ -z "$_trash_entry" || "${_trash_entry##*/}" == ".dm-quarantine" ]] && continue
          if [[ "$_scan_dir" == "$_trash_root" && -d "$_trash_root/files" ]]; then
            case "${_trash_entry##*/}" in files|info|expunged) continue ;; esac
          fi
          # Remove restore metadata ONLY when the guarded removal actually succeeded.
          # Deleting .trashinfo for a file c14_remove refused leaves the file in Trash
          # with no restore path - lost metadata, unreclaimed space.
          if c14_remove "$_trash_entry" --kind rebuildable && [[ ! -e "$_trash_entry" ]]; then
            if [[ "$_trash_root" == "$HOME/.local/share/Trash" ]]; then
              rm -f "$_trash_root/info/${_trash_entry##*/}.trashinfo" 2>/dev/null || true
            fi
          fi
        done < <(python3 - "$_scan_dir" <<'PY_TRASH'
import os, subprocess, sys
# Keep the existing >=1 MiB, largest-first policy without parsing paths from du.
entries = []
with os.scandir(sys.argv[1]) as children:
    for child in children:
        if child.name.startswith("..") or child.is_symlink():
            continue
        result = subprocess.run(['du', '-sk', child.path], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        if result.returncode:
            continue
        try:
            size = int(result.stdout.split(b'\t', 1)[0])
        except ValueError:
            continue
        if size >= 1024:
            entries.append((size, os.fsencode(child.path)))
for _, path in sorted(entries, reverse=True):
    sys.stdout.buffer.write(path + b'\0')
PY_TRASH
        )
      done
      _trash_after_kb=$(size_kb "$_trash_root") || exit $?
      _trash_freed_kb=$(( _trash_before_kb - _trash_after_kb ))
      [[ $_trash_freed_kb -lt 0 ]] && _trash_freed_kb=0
      TOTAL_FREED_KB=$(( TOTAL_FREED_KB + _trash_freed_kb ))
      log "user Trash: after $(fmt_kb "$_trash_after_kb"), freed $(fmt_kb "$_trash_freed_kb")"
    fi
  else
    log "user Trash: SAFETY-SKIP ($_safety_reason)"
  fi
done
# 3b-hf. Hugging Face model caches. src/disk_magician/scripts/disk_report_html.py:215
# advertises huggingface cleanup, but this script had no such section, so
# ~/.cache/huggingface and ~/.cache/hy3dgen were unreachable (measured 11 GiB and
# 6.9 GiB on 2026-11-03). These are model downloads a running job may be using, so a
# root with ANY file touched in the last 24 h is preserved wholesale, and an
# unmeasurable scan also preserves (fail closed).
clean_hf_cache_if_idle() {
  local label="$1" path="$2" young rc=0
  if [[ ! -d "$path" ]]; then
    log "$label: directory not found, skipping"
    return
  fi
  scratch_budget_report_measurement "$path" || exit $?
  young="$(find "$path" -type f -mmin -1440 -print -quit 2>/dev/null)" || rc=$?
  if (( rc != 0 )); then
    log "$label: mtime scan failed (rc=$rc) — preserving (fail closed)"
    return
  fi
  if [[ -n "$young" ]]; then
    log "$label: recently written (${young#"$path"/}) — preserving active units, younger than 24h"
    # Model roots are lifecycle units: never turn internal blobs/snapshots into
    # deletion candidates just because measurement descends them. A download
    # in one model must not shelter a different, idle model.
    local units="$path" entry child_young child_rc
    [[ "$path" == "$HOME/.cache/huggingface" ]] && units="$path/hub"
    [[ -d "$units" && ! -L "$units" ]] || return 0
    while IFS= read -r -d '' entry; do
      [[ -d "$entry" && ! -L "$entry" && "${entry##*/}" != .* ]] || continue
      [[ ! -e "$entry/.git" && ! -L "$entry/.git" ]] || continue
      child_rc=0
      child_young="$(find "$entry" -type f -mmin -1440 -print -quit 2>/dev/null)" || child_rc=$?
      (( child_rc == 0 )) && [[ -z "$child_young" ]] || continue
      clean_whole_dir "$label idle unit" "$entry" false rebuildable
    done < <(find "$units" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    return
  fi
  clean_dir_contents "$label" "$path" true rebuildable
}
log "=== Section 3b-hf: Hugging Face caches ==="
clean_hf_cache_if_idle "huggingface cache" "$HOME/.cache/huggingface"
clean_hf_cache_if_idle "hy3dgen cache" "$HOME/.cache/hy3dgen"

# 3c. Rotated dated log dirs (YYYY.MM.DD or YYYY/MM/DD) older than 7 days. Only
# dated leaf dirs are candidates, so a year/month parent holding this week's
# logs is never removed on its own (older) mtime.
log "=== Section 3c: rotated dated log dirs (>7d) ==="
for dated_log_root in \
  "gcloud CLI logs:$HOME/.config/gcloud/logs" \
  "Codex app logs:$HOME/Library/Logs/com.openai.codex"; do
  dated_label="${dated_log_root%%:*}"
  dated_root="${dated_log_root#*:}"
  if [[ ! -d "$dated_root" ]]; then
    log "$dated_label: directory not found, skipping"
    continue
  fi
  dated_before_kb=$(size_kb "$dated_root") || exit $?
  log "$dated_label: before $(fmt_kb "$dated_before_kb") ($dated_root)"
  while IFS= read -r -d '' entry; do
    if [[ "$DRY_RUN" == true ]]; then
      log "$dated_label: [dry-run] would delete $entry"
    elif ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
      log "$dated_label: SAFETY-SKIP $entry ($_safety_reason)"
    else
      c14_remove "$entry" --kind rebuildable || true
    fi
  done < <(find "$dated_root" -mindepth 1 -maxdepth 3 -type d \
    \( -name '[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]' -o -path '*/[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]' \) \
    -mtime +7 -print0 2>/dev/null)
  if [[ "$DRY_RUN" != true ]]; then
    dated_after_kb=$(size_kb "$dated_root") || exit $?
    dated_freed_kb=$(( dated_before_kb - dated_after_kb ))
    [[ $dated_freed_kb -lt 0 ]] && dated_freed_kb=0
    TOTAL_FREED_KB=$(( TOTAL_FREED_KB + dated_freed_kb ))
    log "$dated_label: after $(fmt_kb "$dated_after_kb"), freed $(fmt_kb "$dated_freed_kb")"
  fi
done

# 4. opencode safe subdirs
log "=== Section 4: ~/.local/share/opencode/ (safe cache subdirs only) ==="
OPENCODE_DIR="$HOME/.local/share/opencode"
OPENCODE_SAFE_SUBDIRS=("repos" "log" "tool-output" "snapshot")
if [[ ! -d "$OPENCODE_DIR" ]]; then
  log "opencode data dir: not found, skipping"
else
  before_kb=$(size_kb "$OPENCODE_DIR") || exit $?
  log "opencode data dir: before $(fmt_kb "$before_kb") ($OPENCODE_DIR)"

  for subdir in "${OPENCODE_SAFE_SUBDIRS[@]}"; do
    target="$OPENCODE_DIR/$subdir"
    [[ ! -d "$target" ]] && continue
    while IFS= read -r -d '' entry; do
      [[ "${entry##*/}" == ".dm-quarantine" ]] && continue  # quarantine's own state
      if [[ "$DRY_RUN" == true ]]; then
        log "opencode $subdir/: [dry-run] would delete $entry"
      else
        log "opencode $subdir/: deleting $entry"
        if ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
          echo "SAFETY-SKIP "$entry" ($_safety_reason)"
        else
          c14_remove "$entry" --kind rebuildable || true
        fi
      fi
    done < <(find "$target" -mindepth 1 -maxdepth 1 -mtime +14 -print0 2>/dev/null)
  done

  if [[ "$DRY_RUN" != true ]]; then
    after_kb=$(size_kb "$OPENCODE_DIR") || exit $?
    freed_kb=$(( before_kb - after_kb ))
    [[ $freed_kb -lt 0 ]] && freed_kb=0
    TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed_kb ))
    log "opencode data dir: after $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
  fi
fi

# 5. cursor-agent old versions
log "=== Section 5: cursor-agent old versions ==="
CURSOR_VERSIONS_DIR="$HOME/.local/share/cursor-agent/versions"
if [[ ! -d "$CURSOR_VERSIONS_DIR" ]]; then
  log "cursor-agent versions: directory not found, skipping"
else
  before_kb=$(size_kb "$CURSOR_VERSIONS_DIR") || exit $?
  log "cursor-agent versions: before $(fmt_kb "$before_kb") ($CURSOR_VERSIONS_DIR)"

  ALL_VERSIONS=()
  while IFS= read -r version; do
    [[ -n "$version" ]] && ALL_VERSIONS[${#ALL_VERSIONS[@]}]="$version"
  done < <(find "$CURSOR_VERSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort || true)

  KEEP=2
  TOTAL_VERSIONS=${#ALL_VERSIONS[@]}
  ACTIVE_AGENT_TARGET=""
  CURSOR_VERSION_CLEANUP_BLOCKED=false
  if [[ -L "$HOME/.local/bin/agent" ]]; then
    if ! ACTIVE_AGENT_TARGET="$(resolve_existing_path "$HOME/.local/bin/agent")"; then
      log "cursor-agent versions: SAFETY-SKIP active agent target could not be resolved"
      CURSOR_VERSION_CLEANUP_BLOCKED=true
    fi
  fi

  if [[ "$CURSOR_VERSION_CLEANUP_BLOCKED" == true ]]; then
    log "cursor-agent versions: preserving all $TOTAL_VERSIONS version(s)"
  elif [[ $TOTAL_VERSIONS -le $KEEP ]]; then
    log "cursor-agent versions: only $TOTAL_VERSIONS version(s) present, nothing to delete"
  else
    DELETE_COUNT=$(( TOTAL_VERSIONS - KEEP ))
    KEPT_VERSIONS=("${ALL_VERSIONS[@]:$DELETE_COUNT}")

    for (( i=0; i<DELETE_COUNT; i++ )); do
      entry="${ALL_VERSIONS[$i]}"
      if ! entry_real="$(resolve_existing_path "$entry")"; then
        log "cursor-agent versions: SAFETY-SKIP candidate path could not be resolved: $entry"
        continue
      fi
      if [[ -n "$ACTIVE_AGENT_TARGET" && "$ACTIVE_AGENT_TARGET" == "$entry_real/"* ]]; then
        log "cursor-agent versions: preserving active version $entry"
        continue
      fi
      [[ "${entry##*/}" == ".dm-quarantine" ]] && continue  # quarantine's own state
      if [[ "$DRY_RUN" == true ]]; then
        log "cursor-agent versions: [dry-run] would delete $entry"
      else
        log "cursor-agent versions: deleting $entry"
        if ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
          echo "SAFETY-SKIP "$entry" ($_safety_reason)"
        else
          c14_remove "$entry" --kind rebuildable || true
        fi
      fi
    done

    if [[ "$DRY_RUN" != true ]]; then
      after_kb=$(size_kb "$CURSOR_VERSIONS_DIR") || exit $?
      freed_kb=$(( before_kb - after_kb ))
      [[ $freed_kb -lt 0 ]] && freed_kb=0
      TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed_kb ))
      log "cursor-agent versions: after $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
    fi
  fi
fi

# 6. ~/.npm/_cacache
log "=== Section 6: ~/.npm/_cacache ==="
clean_dir_contents "npm _cacache" "$HOME/.npm/_cacache" false rebuildable

# 7. claude-cli-nodejs and go-build Library/Caches (Fix #8)
#
# Both dirs are build/transform caches that auto-rebuild on next use:
#   - claude-cli-nodejs/ holds per-CLI-process worktree-shared caches
#     keyed by absolute path (e.g. "-Users-jleechan--hermes"). Rebuild
#     is fast on next invocation. Currently 365 MB.
#   - go-build/ holds Go compile-output caches (00/, 01/, ...). Rebuild
#     is fast on next go build. Currently 196 MB.
#
# Apply a 30-day mtime gate per-entry (top-level only). Older entries are
# stale build artifacts from completed work; recent entries (<30d) are
# likely part of an in-flight session and should be preserved for fast
# incremental rebuilds. This is more conservative than the 14-day gate
# used for opencode, because go/claude caches are larger and slower to
# rebuild than opencode snapshots.
#
# Both dirs are flat lists of subdirectories — same find pattern as the
# opencode section above. Pattern is: walk top-level entries, delete
# those whose mtime is older than 30 days. Files mixed with dirs are
# handled (rm -rf handles both).
DEV_CACHE_DAYS=30
for dev_cache_path in \
  "$HOME/Library/Caches/claude-cli-nodejs" \
  "$HOME/Library/Caches/go-build" \
  "$HOME/.cache/claude-cli-nodejs" \
  "$HOME/.cache/go-build"; do
  dev_cache_label=$(basename "$dev_cache_path")
  log "=== Section: $dev_cache_path (${DEV_CACHE_DAYS}d mtime) ==="
  if [[ ! -d "$dev_cache_path" ]]; then
    log "$dev_cache_label: directory not found, skipping"
    continue
  fi

  before_kb=$(size_kb "$dev_cache_path") || exit $?
  log "$dev_cache_label: before $(fmt_kb "$before_kb") ($dev_cache_path)"

  found_old_entry=false
  while IFS= read -r -d '' entry; do
    [[ "${entry##*/}" == ".dm-quarantine" ]] && continue  # quarantine's own state
    found_old_entry=true
    if [[ "$DRY_RUN" == true ]]; then
      log "$dev_cache_label: [dry-run] would delete $entry"
    else
      log "$dev_cache_label: deleting $entry"
      if ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
        echo "SAFETY-SKIP "$entry" ($_safety_reason)"
      else
        c14_remove "$entry" --kind rebuildable || true
      fi
    fi
  done < <(find "$dev_cache_path" -mindepth 1 -maxdepth 1 -mtime +"$DEV_CACHE_DAYS" -print0 2>/dev/null)

  if [[ "$found_old_entry" == false ]]; then
    log "$dev_cache_label: no entries older than ${DEV_CACHE_DAYS}d, nothing to delete"
    continue
  fi

  if [[ "$DRY_RUN" != true ]]; then
    after_kb=$(size_kb "$dev_cache_path") || exit $?
    freed_kb=$(( before_kb - after_kb ))
    [[ $freed_kb -lt 0 ]] && freed_kb=0
    TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed_kb ))
    log "$dev_cache_label: after $(fmt_kb "$after_kb"), freed $(fmt_kb "$freed_kb")"
  fi
done

# 8. ~/.local/state/fsevents-projects.state.json — the polling-fallback snapshot
# of scripts/watch_projects_fsevents.sh. Its rotated logs are bounded by that
# script's own KEEP_DAYS/MAX_BYTES, but the state cache is explicitly excluded
# from rotation and nothing else bounds it, so it is a pure accumulator
# (measured 634 MiB on 2026-10-17 — findings_wiki/2026-10-17-fsevents-state-
# cache-unbounded-growth.md). The watcher re-opens the path on every write and
# rebuilds the snapshot on its next poll, so dropping the file is safe.
#
# Two gates, both from the watcher's own constants: the file is dropped when it
# has not been written for KEEP_DAYS (dead watcher) OR when it exceeds the
# MAX_BYTES cap (a live watcher rewrites its mtime continuously, so an
# age-only gate would never fire on the file that actually grows). An
# unresolvable path, a non-regular file, or a safety rule keeps it.
FSEVENTS_STATE_DAYS=7
FSEVENTS_STATE_MAX_BYTES=16777216

# fsevents_state_is_stale <path>: rc 0 when the watcher has not written the
# cache for FSEVENTS_STATE_DAYS. A probe that cannot run keeps the file.
fsevents_state_is_stale() {
  local hit
  hit="$(find "$1" -maxdepth 0 -mtime +"$FSEVENTS_STATE_DAYS" -print 2>/dev/null)" || return 1
  [[ -n "$hit" ]]
}

log "=== Section: ~/.local/state/fsevents-projects.state.json (${FSEVENTS_STATE_DAYS}d or $(( FSEVENTS_STATE_MAX_BYTES / 1048576 ))M cap) ==="
FSEVENTS_STATE="$HOME/.local/state/fsevents-projects.state.json"
if [[ ! -d "${FSEVENTS_STATE%/*}" ]]; then
  log "fsevents state cache: directory not found, skipping"
elif [[ ! -e "$FSEVENTS_STATE" && ! -L "$FSEVENTS_STATE" ]]; then
  log "fsevents state cache: not found, skipping"
elif ! fsevents_state_resolved="$(resolve_existing_path "$FSEVENTS_STATE")"; then
  log "fsevents state cache: SAFETY-SKIP (path could not be resolved)"
elif [[ ! -f "$fsevents_state_resolved" ]]; then
  log "fsevents state cache: SAFETY-SKIP (not a regular file)"
else
  fsevents_state_kb=$(size_kb "$fsevents_state_resolved") || exit $?
  fsevents_state_reason=""
  if fsevents_state_is_stale "$fsevents_state_resolved"; then
    fsevents_state_reason="untouched for ${FSEVENTS_STATE_DAYS}d"
  elif (( fsevents_state_kb * 1024 > FSEVENTS_STATE_MAX_BYTES )); then
    fsevents_state_reason="over the $(( FSEVENTS_STATE_MAX_BYTES / 1048576 ))M cap"
  fi
  if [[ -z "$fsevents_state_reason" ]]; then
    log "fsevents state cache: $(fmt_kb "$fsevents_state_kb") — retained (recent and under the cap)"
  elif [[ "$DRY_RUN" == true ]]; then
    log "fsevents state cache: [dry-run] would drop $(fmt_kb "$fsevents_state_kb") ($fsevents_state_reason): $fsevents_state_resolved"
  elif ! _safety_reason="$(safety_gate "$fsevents_state_resolved" 2>/dev/null)"; then
    log "fsevents state cache: SAFETY-SKIP ($_safety_reason)"
  elif rm -f "$fsevents_state_resolved"; then
    TOTAL_FREED_KB=$(( TOTAL_FREED_KB + fsevents_state_kb ))
    deletion_log "cleanup_dev_caches" "drop_fsevents_state_cache" "$fsevents_state_kb" "$fsevents_state_resolved"
    log "fsevents state cache: dropped $(fmt_kb "$fsevents_state_kb") ($fsevents_state_reason); rebuilt on the next poll"
  else
    log "fsevents state cache: WARN failed to remove $fsevents_state_resolved"
  fi
fi

# N. ~/Snapchat/Dev/.cache/bazel — bazel output bases (hit 452.6G unnoticed;
# dot-dir invisible to Dev/* globs; regrows within hours of any bazel build).
log "=== Section: Dev/.cache/bazel (bazel output bases) ==="
DEV_BAZEL_CACHE="$HOME/Snapchat/Dev/.cache/bazel"
if [[ ! -d "$DEV_BAZEL_CACHE" ]]; then
  log "dev bazel cache: not found, skipping"
elif pgrep -f "bazel" >/dev/null 2>&1; then
  log "dev bazel cache: SKIP — live bazel process"
elif [[ -n "$(lsof +D "$DEV_BAZEL_CACHE" 2>/dev/null | head -2 | tail -1)" ]]; then
  log "dev bazel cache: SKIP — open files in cache"
else
  clean_dir_contents "dev bazel cache" "$DEV_BAZEL_CACHE" false rebuildable
fi

# N. ~/.cache/wiki-publish — shadow and review-council test checkouts
log "=== Section: ~/.cache/wiki-publish (shadow and review-council scratch) ==="
WIKI_PUBLISH_CACHE="$HOME/.cache/wiki-publish"
if [[ ! -d "$WIKI_PUBLISH_CACHE" ]]; then
  log "wiki-publish cache: not found, skipping"
else
  before_kb=$(size_kb "$WIKI_PUBLISH_CACHE") || exit $?
  log "wiki-publish cache: $(fmt_kb "$before_kb") ($WIKI_PUBLISH_CACHE) — retained; automatic deletion disabled until lifecycle provenance is known"
fi


echo
if [[ "$DRY_RUN" == true ]]; then
  log "=== DRY-RUN complete — no files deleted ==="
else
  log "=== Cleanup complete — total freed: $(fmt_kb "$TOTAL_FREED_KB") ==="
fi
