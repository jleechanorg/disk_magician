#!/usr/bin/env bash
# cleanup_dev_caches.sh — Cleanup dev tool caches that rebuild automatically.
#
# Defaults to actually deleting (use --dry-run to preview).
set -euo pipefail

# shellcheck source=scripts/safety_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/safety_lib.sh"

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
  local label="$1" path="$2" recreate="${3:-false}"

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

  find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

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
clean_dir_contents "uv cache" "$HOME/.cache/uv" false

# 3. ~/.cache/pre-commit/
log "=== Section 3: ~/.cache/pre-commit/ ==="
clean_dir_contents "pre-commit cache" "$HOME/.cache/pre-commit" false

# 3b. Rebuildable user caches (user-approved 2026-10-08: "any caches"). Apps that
# are running (cmux, Aside, Chrome, Cursor) are left to their needs_decision gates.
log "=== Section 3b: rebuildable user caches ==="
for approved_cache in \
  "worldai:$HOME/.cache/worldai" \
  "swiftpm:$HOME/Library/Caches/org.swift.swiftpm" \
  "ms-playwright:$HOME/Library/Caches/ms-playwright" \
  "CocoaPods:$HOME/Library/Caches/CocoaPods" \
  "granola updater:$HOME/Library/Caches/@granolaelectron-updater" \
  "codex sparkle updater:$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle" \
  "bun install cache:$HOME/.bun/install/cache" \
  "speech model cache:/private/var/tmp/SpeechModelCache" \
  "ezgha recovery target:$HOME/.cache/ezgha-recovery-target-20261004" \
  "gradle caches:$HOME/.gradle/caches" \
  "npm _npx:$HOME/.npm/_npx" \
  "cargo registry cache:$HOME/.cargo/registry/cache" \
  "cargo registry src:$HOME/.cargo/registry/src"; do
  clean_dir_contents "${approved_cache%%:*}" "${approved_cache#*:}" false
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
      if [[ "$DRY_RUN" == true ]]; then
        log "opencode $subdir/: [dry-run] would delete $entry"
      else
        log "opencode $subdir/: deleting $entry"
        if ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
          echo "SAFETY-SKIP "$entry" ($_safety_reason)"
        else
          rm -rf "$entry"
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
for CURSOR_VERSIONS_DIR in \
  "$HOME/.local/share/cursor-agent/versions" \
  "$HOME/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/share/cursor-agent/versions"; do
if [[ ! -d "$CURSOR_VERSIONS_DIR" ]]; then
  log "cursor-agent versions: directory not found ($CURSOR_VERSIONS_DIR), skipping"
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
  CURSOR_BIN_SYMLINK="$(dirname "$(dirname "$(dirname "$CURSOR_VERSIONS_DIR")")")/bin/agent"
  for agent_link in "$HOME/.local/bin/agent" "$CURSOR_BIN_SYMLINK"; do
    if [[ -L "$agent_link" ]]; then
      if ! resolved_target="$(resolve_existing_path "$agent_link")"; then
        log "cursor-agent versions: SAFETY-SKIP active agent target could not be resolved ($agent_link)"
        CURSOR_VERSION_CLEANUP_BLOCKED=true
      else
        ACTIVE_AGENT_TARGET="$resolved_target"
      fi
    fi
  done

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
      if [[ "$DRY_RUN" == true ]]; then
        log "cursor-agent versions: [dry-run] would delete $entry"
      else
        log "cursor-agent versions: deleting $entry"
        if ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
          echo "SAFETY-SKIP "$entry" ($_safety_reason)"
        else
          rm -rf "$entry"
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
done

# 6. ~/.npm/_cacache
log "=== Section 6: ~/.npm/_cacache ==="
clean_dir_contents "npm _cacache" "$HOME/.npm/_cacache" false

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
  "$HOME/Library/Caches/go-build"; do
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
    found_old_entry=true
    if [[ "$DRY_RUN" == true ]]; then
      log "$dev_cache_label: [dry-run] would delete $entry"
    else
      log "$dev_cache_label: deleting $entry"
      if ! _safety_reason="$(safety_gate "$entry" 2>/dev/null)"; then
        echo "SAFETY-SKIP "$entry" ($_safety_reason)"
      else
        rm -rf "$entry"
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
  clean_dir_contents "dev bazel cache" "$DEV_BAZEL_CACHE" false
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
  clean_dir_contents "clang module cache" "$clang_cache" false
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
      if rm -rf "$entry" 2>/dev/null; then
        peek_deleted=$(( peek_deleted + 1 ))
        peek_freed_kb=$(( peek_freed_kb + kb ))
        deletion_log "cleanup_dev_caches.sh" "remove" "$kb" "$entry"
      else
        echo "SKIP (rm failed): $entry"
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
    if [[ "$(basename "$item")" == "schema-migrations" ]]; then
      continue
    fi
    br_candidates+=("$item")
  done < <(find "$rec_dir" -mindepth 1 -maxdepth 1 -mtime +7 -print0 2>/dev/null || true)

  if [[ -d "$rec_dir/schema-migrations" ]]; then
    while IFS= read -r -d '' sm_item; do
      [[ -e "$sm_item" ]] || continue
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
      if rm -rf "$candidate" 2>/dev/null; then
        br_deleted=$(( br_deleted + 1 ))
        br_freed_kb=$(( br_freed_kb + kb ))
        deletion_log "cleanup_dev_caches.sh" "remove" "$kb" "$candidate"
      else
        echo "SKIP (rm failed): $candidate"
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

echo
if [[ "$DRY_RUN" == true ]]; then
  log "=== DRY-RUN complete — no files deleted ==="
else
  log "=== Cleanup complete — total freed: $(fmt_kb "$TOTAL_FREED_KB") ==="
fi
