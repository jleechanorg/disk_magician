#!/usr/bin/env bash
# cleanup_dev_caches.sh — Cleanup dev tool caches that rebuild automatically.
#
# Defaults to actually deleting (use --dry-run to preview).
set -euo pipefail

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
  before_kb=$(size_kb "$path")
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
  after_kb=$(size_kb "$path")
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

# 3b. Rebuildable user caches (user-approved 2026-10-08: "any caches").
log "=== Section 3b: rebuildable user caches ==="
for approved_cache in \
  "worldai:$HOME/.cache/worldai" \
  "swiftpm:$HOME/Library/Caches/org.swift.swiftpm" \
  "ms-playwright:$HOME/Library/Caches/ms-playwright" \
  "ms-playwright linux:$HOME/.cache/ms-playwright" \
  "camoufox:$HOME/.cache/camoufox" \
  "CocoaPods:$HOME/Library/Caches/CocoaPods" \
  "granola updater:$HOME/Library/Caches/@granolaelectron-updater" \
  "ezgha recovery target:$HOME/.cache/ezgha-recovery-target-20261004" \
  "gradle caches:$HOME/.gradle/caches" \
  "gradle daemon:$HOME/.gradle/daemon" \
  "gradle wrapper dists:$HOME/.gradle/wrapper/dists" \
  "npm _npx:$HOME/.npm/_npx" \
  "pnpm cache:$HOME/Library/Caches/pnpm" \
  "pnpm linux cache:$HOME/.cache/pnpm" \
  "cargo registry cache:$HOME/.cargo/registry/cache" \
  "cargo registry src:$HOME/.cargo/registry/src" \
  "Google caches:$HOME/Library/Caches/Google" \
  "Homebrew caches:$HOME/Library/Caches/Homebrew" \
  "pip caches:$HOME/Library/Caches/pip" \
  "pip linux caches:$HOME/.cache/pip" \
  "puppeteer caches:$HOME/.cache/puppeteer" \
  "Xcode caches:$HOME/Library/Caches/com.apple.dt.Xcode" \
  "SentryCrash caches:$HOME/Library/Caches/SentryCrash" \
  "SiriTTS caches:$HOME/Library/Caches/SiriTTS" \
  "Cursor Cache:$HOME/Library/Application Support/Cursor/Cache" \
  "Cursor CachedData:$HOME/Library/Application Support/Cursor/CachedData" \
  "Cursor CachedExtensionVSIXs:$HOME/Library/Application Support/Cursor/CachedExtensionVSIXs" \
  "Cursor Code Cache:$HOME/Library/Application Support/Cursor/Code Cache" \
  "Cursor GPUCache:$HOME/Library/Application Support/Cursor/GPUCache" \
  "discord Cache:$HOME/Library/Application Support/discord/Cache" \
  "discord Code Cache:$HOME/Library/Application Support/discord/Code Cache" \
  "discord GPUCache:$HOME/Library/Application Support/discord/GPUCache" \
  "Chrome Default Cache:$HOME/Library/Application Support/Google/Chrome/Default/Cache" \
  "Chrome Default Code Cache:$HOME/Library/Application Support/Google/Chrome/Default/Code Cache" \
  "Chrome Default SW CacheStorage:$HOME/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage"; do
  approved_kind=rebuildable
  # The ezgha recovery target is explicitly a non-cache target (spec §7.2):
  # ordinary provenance, not the fixed cache-root table.
  [[ "${approved_cache%%:*}" == "ezgha recovery target" ]] && approved_kind=""
  clean_dir_contents "${approved_cache%%:*}" "${approved_cache#*:}" false "$approved_kind"
done
for chrome_prof in "$HOME/Library/Application Support/Google/Chrome"/Profile\ *; do
  [[ -d "$chrome_prof" ]] || continue
  clean_dir_contents "Chrome $(basename "$chrome_prof") Cache" "$chrome_prof/Cache" false rebuildable
  clean_dir_contents "Chrome $(basename "$chrome_prof") Code Cache" "$chrome_prof/Code Cache" false rebuildable
  clean_dir_contents "Chrome $(basename "$chrome_prof") SW CacheStorage" "$chrome_prof/Service Worker/CacheStorage" false rebuildable
done

# 4. opencode safe subdirs
log "=== Section 4: ~/.local/share/opencode/ (safe cache subdirs only) ==="
OPENCODE_DIR="$HOME/.local/share/opencode"
OPENCODE_SAFE_SUBDIRS=("repos" "log" "tool-output" "snapshot")
if [[ ! -d "$OPENCODE_DIR" ]]; then
  log "opencode data dir: not found, skipping"
else
  before_kb=$(size_kb "$OPENCODE_DIR")
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
    after_kb=$(size_kb "$OPENCODE_DIR")
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
  before_kb=$(size_kb "$CURSOR_VERSIONS_DIR")
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
      after_kb=$(size_kb "$CURSOR_VERSIONS_DIR")
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

  before_kb=$(size_kb "$dev_cache_path")
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
    after_kb=$(size_kb "$dev_cache_path")
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
  fsevents_state_kb=$(size_kb "$fsevents_state_resolved")
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
  elif c14_remove "$fsevents_state_resolved" --kind rebuildable; then
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
  before_kb=$(size_kb "$WIKI_PUBLISH_CACHE")
  log "wiki-publish cache: $(fmt_kb "$before_kb") ($WIKI_PUBLISH_CACHE) — retained; automatic deletion disabled until lifecycle provenance is known"
fi


# N. Darwin user clang cache (/private/var/folders/*/*/C/clang/ModuleCache*)
log "=== Section: Darwin user clang ModuleCache ==="
for clang_cache in /private/var/folders/*/*/C/clang/ModuleCache*; do
  [[ -d "$clang_cache" ]] || continue
  clean_dir_contents "clang module cache" "$clang_cache" false rebuildable
done

# N. ~/.peekaboo/snapshots entries older than 30 days
log "=== Section: ~/.peekaboo/snapshots (entries older than 30d) ==="
PEEKABOO_SNAPSHOTS="$HOME/.peekaboo/snapshots"
if [[ ! -d "$PEEKABOO_SNAPSHOTS" ]]; then
  log "peekaboo snapshots: directory not found, skipping"
else
  before_kb=$(size_kb "$PEEKABOO_SNAPSHOTS")
  log "peekaboo snapshots: before $(fmt_kb "$before_kb") ($PEEKABOO_SNAPSHOTS)"
  peek_deleted=0
  peek_freed_kb=0

  while IFS= read -r -d '' entry; do
    [[ -e "$entry" ]] || continue
    [[ "${entry##*/}" == ".dm-quarantine" ]] && continue
    [[ -n "$entry" && "$entry" == "$PEEKABOO_SNAPSHOTS/"* ]] || continue

    kb=$(size_kb "$entry")
    if [[ "$DRY_RUN" == true ]]; then
      log "peekaboo snapshots: [dry-run] would delete $entry ($(fmt_kb "$kb"))"
      peek_deleted=$(( peek_deleted + 1 ))
      peek_freed_kb=$(( peek_freed_kb + kb ))
    else
      if ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
        echo "SAFETY-SKIP "$entry" ($_safety_reason)"
        continue
      fi
      log "peekaboo snapshots: deleting $entry ($(fmt_kb "$kb"))"
      chmod -R u+w "$entry" 2>/dev/null || true
      if c14_remove "$entry" --kind rebuildable; then
        peek_deleted=$(( peek_deleted + 1 ))
        peek_freed_kb=$(( peek_freed_kb + kb ))
        deletion_log "cleanup_dev_caches.sh" "remove" "$kb" "$entry"
      else
        echo "SKIP (c14 kept): $entry"
      fi
    fi
  done < <(find "$PEEKABOO_SNAPSHOTS" -mindepth 1 -maxdepth 1 -mtime +30 -print0 2>/dev/null)

  if [[ "$DRY_RUN" != true ]]; then
    after_kb=$(size_kb "$PEEKABOO_SNAPSHOTS")
    TOTAL_FREED_KB=$(( TOTAL_FREED_KB + peek_freed_kb ))
    log "peekaboo snapshots: after $(fmt_kb "$after_kb"), freed $(fmt_kb "$peek_freed_kb") ($peek_deleted items)"
  else
    log "peekaboo snapshots: [dry-run] would remove $peek_deleted items, freeing $(fmt_kb "$peek_freed_kb")"
  fi
fi

# N. Stale .beads/.br_recovery bundles (>= 7d)
log "=== Section: Stale .beads/.br_recovery bundles (>= 7d) ==="
BR_RECOVERY_GLOBS=(
  "$HOME"/projects/*/.beads/.br_recovery
  "$HOME"/.worktrees/*/*/.beads/.br_recovery
  "$HOME"/project_worldaiclaw/*/.beads/.br_recovery
  "$HOME"/projects_other/*/.beads/.br_recovery
)

br_deleted=0
br_freed_kb=0

for rec_dir in "${BR_RECOVERY_GLOBS[@]}"; do
  [[ -d "$rec_dir" ]] || continue

  br_candidates=()
  while IFS= read -r -d '' item; do
    [[ -e "$item" ]] || continue
    [[ "${item##*/}" == ".dm-quarantine" ]] && continue
    if [[ "$(basename "$item")" == "schema-migrations" ]]; then
      continue
    fi
    br_candidates+=("$item")
  done < <(find "$rec_dir" -mindepth 1 -maxdepth 1 -mtime +7 -print0 2>/dev/null || true)

  if [[ -d "$rec_dir/schema-migrations" ]]; then
    while IFS= read -r -d '' sm_item; do
      [[ -e "$sm_item" ]] || continue
      [[ "${sm_item##*/}" == ".dm-quarantine" ]] && continue
      br_candidates+=("$sm_item")
    done < <(find "$rec_dir/schema-migrations" -mindepth 1 -maxdepth 1 -mtime +7 -print0 2>/dev/null || true)
  fi

  for candidate in "${br_candidates[@]}"; do
    [[ -e "$candidate" ]] || continue
    [[ -n "$candidate" && "$candidate" == "$rec_dir/"* ]] || continue

    kb=$(size_kb "$candidate")
    if [[ "$DRY_RUN" == true ]]; then
      log "br_recovery: [dry-run] would delete $candidate ($(fmt_kb "$kb"))"
      br_deleted=$(( br_deleted + 1 ))
      br_freed_kb=$(( br_freed_kb + kb ))
    else
      if ! _safety_reason="$(safety_gate "$candidate" 2>/dev/null)"; then
        echo "SAFETY-SKIP "$candidate" ($_safety_reason)"
        continue
      fi
      log "br_recovery: deleting $candidate ($(fmt_kb "$kb"))"
      chmod -R u+w "$candidate" 2>/dev/null || true
      if c14_remove "$candidate" --kind rebuildable; then
        br_deleted=$(( br_deleted + 1 ))
        br_freed_kb=$(( br_freed_kb + kb ))
        deletion_log "cleanup_dev_caches.sh" "remove" "$kb" "$candidate"
      else
        echo "SKIP (c14 kept): $candidate"
      fi
    fi
  done

  # Prune schema-migrations dir if empty
  if [[ -d "$rec_dir/schema-migrations" && "$DRY_RUN" == false ]]; then
    rmdir "$rec_dir/schema-migrations" 2>/dev/null || true
  fi
done

if [[ "$DRY_RUN" != true ]]; then
  TOTAL_FREED_KB=$(( TOTAL_FREED_KB + br_freed_kb ))
  log "br_recovery: freed $(fmt_kb "$br_freed_kb") across $br_deleted items"
else
  log "br_recovery: [dry-run] would remove $br_deleted items, freeing $(fmt_kb "$br_freed_kb")"
fi

# ---------------------------------------------------------------------------
# 16. Non-default Rustup toolchains (~/.rustup/toolchains/*)
# ---------------------------------------------------------------------------
echo
log "--- 16. Non-default Rustup toolchains ---"
if [[ -d "$HOME/.rustup/toolchains" ]]; then
  default_tc=""
  rustup_bin="$(PATH="$HOME/.cargo/bin:$PATH" command -v rustup 2>/dev/null || true)"
  if [[ -n "$rustup_bin" ]]; then
    default_tc="$("$rustup_bin" toolchain list 2>/dev/null | awk '/\(default\)/ {print $1; exit}')"
  fi
  if [[ -z "$default_tc" && -f "$HOME/.rustup/settings.toml" ]]; then
    default_tc="$(sed -n 's/^default_toolchain *= *"\([^"]*\)".*/\1/p' "$HOME/.rustup/settings.toml" 2>/dev/null | head -n 1)"
  fi
  if [[ -n "$default_tc" && -d "$HOME/.rustup/toolchains/$default_tc" ]]; then
    for tc_dir in "$HOME/.rustup/toolchains"/*; do
      [[ -d "$tc_dir" && ! -L "$tc_dir" ]] || continue
      tc_name="$(basename "$tc_dir")"
      [[ "$tc_name" == "$default_tc" ]] && continue
      clean_dir_contents "Rustup non-default toolchain ($tc_name)" "$tc_dir" false rebuildable
      [[ "$DRY_RUN" == false ]] && rmdir "$tc_dir" 2>/dev/null || true
    done
  fi
fi

# ---------------------------------------------------------------------------
# 17. Idle Android SDK system-images / emulator / ndk
# ---------------------------------------------------------------------------
echo
log "--- 17. Idle Android SDK system-images / emulator / ndk ---"
if [[ -d "/opt/homebrew/share/android-commandlinetools" ]]; then
  # shellcheck disable=SC2009
  if ! ps aux | grep -E '(qemu-system|android.*emulator)' | grep -v grep >/dev/null 2>&1; then
    for android_sub in /opt/homebrew/share/android-commandlinetools/system-images /opt/homebrew/share/android-commandlinetools/emulator /opt/homebrew/share/android-commandlinetools/ndk; do
      [[ -d "$android_sub" && ! -L "$android_sub" ]] || continue
      clean_dir_contents "Android SDK ($(basename "$android_sub"))" "$android_sub" false rebuildable
    done
  else
    log "Android SDK: active emulator detected, skipping"
  fi
fi

echo
if [[ "$DRY_RUN" == true ]]; then
  log "=== DRY-RUN complete — no files deleted ==="
else
  log "=== Cleanup complete — total freed: $(fmt_kb "$TOTAL_FREED_KB") ==="
fi
