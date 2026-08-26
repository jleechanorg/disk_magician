#!/usr/bin/env bash
# disable_code_sign_clone_lsenvironment.sh — disable Chromium's MacAppCodeSignClone
# feature via Info.plist LSEnvironment (NOT binary rename + symlink).
#
# Why this approach: the previous `disable_code_sign_clone_wrapper.sh` renamed the
# app's main binary to `.real` and symlinked the original name to a wrapper script.
# That approach BROKE macOS code-sign validation:
#   - runningboardd rejected Google Chrome.real as tampered (Killed: 9)
#   - spctl rejected the entire .app bundle (RBSRequestErrorDomain Code=5)
#   - codesign reported "code object is not signed at all" on the symlink target
#   - macOS Launch Services refused to launch Chrome until .real was renamed back
#
# The CORRECT approach for code-signed Chromium apps is Info.plist LSEnvironment:
# Chromium reads CHROMIUM_USER_FLAGS from the bundle's environment at launch. This
# passes the kill-switch flag through macOS's normal Launch Services path WITHOUT
# touching the binary tree, so code-sign validation stays intact.
#
# Targets: Chrome (Aside/CodexBar are no-go per findings 2026-08-25 — their main
# process does not honor argv flags; only cleanup_code_sign_clones.sh works there).
#
# Side-effects doc: findings_wiki/2026-08-25-codesign-clone-killswitch-side-effects.md
# Attribution:     findings_wiki/2026-08-25-code-sign-clone-attribution.md

set -euo pipefail

DRY_RUN=true
LOG_PREFIX="[disable_code_sign_clone_lsenv]"

TARGETS=(
  "com.google.Chrome|/Applications/Google Chrome.app|Google Chrome"
  # Aside + CodexBar are listed for visibility but the kill switch is unreachable
  # through argv (per side-effects doc). Only Chrome actually honors the flag.
  # "at.studio.AsideBrowser|/Applications/Aside.app|Aside"
  # "com.openai.codex|/Applications/CodexBar.app|CodexBar"
)

FLAGS=(
  "--disable-features=MacAppCodeSignClone"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--apply] [--dry-run] [--revert] [-h|--help]

Disable Chromium's MacAppCodeSignClone via Info.plist LSEnvironment.
Safe for code-signed apps (no binary rename, no symlink, no code-sign breakage).

Options:
  --apply     Add LSEnvironment key to target apps' Info.plist
  --dry-run   Preview what would change (default)
  --revert    Remove LSEnvironment key (restores default launch behavior)
  -h, --help  Show this help
EOF
}

log() { echo "${LOG_PREFIX} $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

set_lsenv() {
  local plist="$1" key="$2" value="$3"
  /usr/libexec/PlistBuddy -c "Delete :LSEnvironment:$key" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :LSEnvironment:$key string \"$value\"" "$plist" \
    || { log "  ERROR: failed to set $key in $plist"; return 1; }
}

remove_lsenv() {
  local plist="$1"
  if /usr/libexec/PlistBuddy -c "Print :LSEnvironment" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$plist" \
      || { log "  ERROR: failed to remove LSEnvironment from $plist"; return 1; }
    log "  REVERTED: removed LSEnvironment from $plist"
  else
    log "  no LSEnvironment key present in $plist (nothing to revert)"
  fi
}

# Build CHROMIUM_USER_FLAGS value from FLAGS array (space-separated)
build_flags_value() {
  local IFS=' '
  echo "${FLAGS[*]}"
}

main() {
  local action=""
  case "${1:-}" in
    --apply)   DRY_RUN=false; action=apply ;;
    --dry-run) DRY_RUN=true ;;
    --revert)  DRY_RUN=false; action=revert ;;
    -h|--help) usage; exit 0 ;;
    "")        DRY_RUN=true ;;
    *)         echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac

  log "Mode: $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY/$action)"

  local flags_value
  flags_value=$(build_flags_value)

  for target in "${TARGETS[@]}"; do
    IFS='|' read -r bundle_id app_path exe_name <<<"$target"
    local plist="${app_path}/Contents/Info.plist"

    if [[ ! -f "$plist" ]]; then
      log "SKIP $bundle_id — Info.plist not found at $plist"
      continue
    fi

    log "Target: $bundle_id"
    log "  app:    $app_path"
    log "  plist:  $plist"

    if [[ "$action" == "revert" ]]; then
      if [[ "$DRY_RUN" == false ]]; then
        remove_lsenv "$plist"
      else
        log "  DRY: would remove :LSEnvironment from $plist"
      fi
      continue
    fi

    # Apply
    if [[ "$DRY_RUN" == true ]]; then
      log "  DRY: would add :LSEnvironment:CHROMIUM_USER_FLAGS = \"$flags_value\""
      log "  DRY: would touch $plist mtime (LaunchServices watches)"
    else
      # Ensure LSEnvironment dict exists
      if ! /usr/libexec/PlistBuddy -c "Print :LSEnvironment" "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$plist" \
          || { log "  ERROR: failed to create LSEnvironment dict"; continue; }
      fi
      set_lsenv "$plist" "CHROMIUM_USER_FLAGS" "$flags_value" || continue
      log "  APPLIED — next launch will pass --disable-features=MacAppCodeSignClone via env"
    fi
  done

  log "Done."
  if [[ "$DRY_RUN" == true ]]; then
    log "Re-run with --apply after reviewing findings_wiki/2026-08-25-codesign-clone-killswitch-side-effects.md"
  else
    log "Re-register apps with LaunchServices:"
    log "  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Google\\ Chrome.app"
    log "Then quit and re-launch Chrome to pick up the new env."
  fi
}

main "${1:-}"
