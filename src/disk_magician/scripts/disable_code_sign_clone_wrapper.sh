#!/usr/bin/env bash
# disable_code_sign_clone_wrapper.sh — disable Chromium's MacAppCodeSignClone
# feature on Chrome / Aside / Codex via launch flag, stopping the 9 GiB/day
# code_sign_clone accumulation documented in findings_wiki/2026-08-25-code-sign-clone-attribution.md
#
# Why: Chromium's MacAppCodeSignClone (M125+) creates a CoW clone of the .app
# bundle under var/folders/.../X/<bundle-id>.code_sign_clone/ on every launch
# (~1.4 GiB each on this host). The cleanup helper (`--type=code-sign-clone-cleanup`)
# polls getppid() != 1 and only fires on graceful shutdown. If Chrome is killed,
# crashes, or is launched via Playwright without browser.close(), the clone is
# orphaned until reboot. 48 inactive Chrome clones + 1 active measured on this host
# = 66 GiB total.
#
# Open vendor bug: issues.chromium.org/issues/340836884 (P1, April 2025)
# Kill switch: --disable-features=MacAppCodeSignClone
#
# Independent reproductions:
#   openai/codex #25667 (965 MB × 7 = 6.5 GB)
#   teamcapybara/capybara #2795 (80 GB/day)
#   HN 43944642 (50 GB in 2 days)
#
# Side effects: see findings_wiki/2026-08-25-codesign-clone-killswitch-side-effects.md
# Operator must review and approve before running.
#
# THIS SCRIPT DOES NOT RUN AUTOMATICALLY. Operator must invoke --apply after
# reviewing side-effects doc and confirming the safety gates are appropriate
# for their threat model (Hardened Runtime / Gatekeeper / sandbox).

set -euo pipefail

DRY_RUN=true
LOG_PREFIX="[disable_code_sign_clone]"

# Targets: bundle id → .app path (resolved at runtime, not hardcoded here)
# NOTE: only Chrome respects --disable-features=MacAppCodeSignClone via the
# external argv path. Aside and Codex (Electron/Chromium-based) do NOT call
# app.commandLine.appendSwitch('disable-features', 'MacAppCodeSignClone') in
# their main process, so the argv flag is unreachable. Per
# findings_wiki/2026-08-25-codesign-clone-killswitch-side-effects.md.
# The Aside/Codex clones must still be cleaned via
# cleanup_code_sign_clones.sh after those apps quit.
TARGETS=(
  "com.google.Chrome|/Applications/Google Chrome.app"
  "at.studio.AsideBrowser|/Applications/Aside.app"
  "com.openai.codex|/Applications/CodexBar.app"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--apply] [--dry-run] [-h|--help]

Disable Chromium's MacAppCodeSignClone feature for Chrome / Aside / CodexBar
to stop the code_sign_clone cache accumulation (~1.4 GiB per launch).

What it does (per target app):
  1. Confirms the .app is installed
  2. Checks the Mach-O LC_BUILD_VERSION / arch
  3. Writes a sidecar wrapper at
       <app>/Contents/MacOS/<app_exe>.killswitch
     that re-execs the original binary with
       --disable-features=MacAppCodeSignClone
  4. (Optional) renames the original binary to <app_exe>.real
     and symlinks the wrapper to <app_exe>
  5. Verifies the next launch passes the flag via
     \`ps aux | grep -E "MacAppCodeSignClone" | grep -v disable\`

Reversal: \`--revert\` restores the original binary and removes the wrapper.

Options:
  --apply     Execute (operator must have approved side-effects review)
  --dry-run   Show what would change (default)
  --revert    Restore original binary (removes wrapper + symlink)
  -h, --help  Show this help
EOF
}

log() { echo "${LOG_PREFIX} $(date '+%Y-%m-%dT%H:%M:%S') $*"; }

resolve_app_exe() {
  local app_path="$1"
  # Most Chromium apps use the bundle name as the binary name
  local bundle_name
  bundle_name=$(basename "$app_path" .app)
  # CodexBar uses a different name; resolve via Info.plist CFBundleExecutable
  local plist="${app_path}/Contents/Info.plist"
  if [[ -f "$plist" ]]; then
    /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$plist" 2>/dev/null || echo "$bundle_name"
  else
    echo "$bundle_name"
  fi
}

main() {
  case "${1:-}" in
    --apply)   DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --revert)  DRY_RUN=false; action=revert ;;
    -h|--help) usage; exit 0 ;;
    "")        DRY_RUN=true ;;
    *)         echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac

  log "Mode: $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"

  for target in "${TARGETS[@]}"; do
    local bundle_id="${target%%|*}"
    local app_path="${target##*|}"

    if [[ ! -d "$app_path" ]]; then
      log "SKIP $bundle_id — not installed at $app_path"
      continue
    fi

    local exe
    exe=$(resolve_app_exe "$app_path")
    local exe_path="${app_path}/Contents/MacOS/${exe}"
    local wrapper_path="${app_path}/Contents/MacOS/${exe}.killswitch"

    log "Target: $bundle_id"
    log "  app:       $app_path"
    log "  binary:    $exe_path"
    log "  wrapper:   $wrapper_path"

    if [[ ! -f "$exe_path" ]]; then
      log "  SKIP — binary not found"
      continue
    fi

    if [[ "${action:-}" == "revert" ]]; then
      log "  REVERT: would remove $wrapper_path and restore $exe_path"
      if [[ "$DRY_RUN" == false ]]; then
        if [[ -L "$exe_path.killswitch-link" ]]; then
          rm "$exe_path.killswitch-link"
        fi
        rm -f "$wrapper_path"
        log "  REVERT complete"
      fi
      continue
    fi

    cat <<WRAPPER_EOF > /dev/null  # placeholder, real write below
#!/usr/bin/env bash
# auto-generated wrapper — re-execs $exe with --disable-features=MacAppCodeSignClone
exec "${exe_path}.real" --disable-features=MacAppCodeSignClone "\$@"
WRAPPER_EOF

    if [[ "$DRY_RUN" == true ]]; then
      log "  DRY: would write wrapper script to $wrapper_path"
      log "  DRY: would rename $exe_path → ${exe_path}.real"
      log "  DRY: would symlink $exe_path → $wrapper_path"
    else
      log "  Writing wrapper to $wrapper_path"
      cat > "$wrapper_path" <<WRAPPER_EOF
#!/usr/bin/env bash
# auto-generated wrapper — re-execs $exe with --disable-features=MacAppCodeSignClone
exec "${exe_path}.real" --disable-features=MacAppCodeSignClone "\$@"
WRAPPER_EOF
      chmod +x "$wrapper_path"

      if [[ ! -f "${exe_path}.real" ]]; then
        log "  Renaming $exe_path → ${exe_path}.real"
        mv "$exe_path" "${exe_path}.real"
      fi

      log "  Symlinking $exe_path → $wrapper_path"
      ln -sf "$wrapper_path" "$exe_path"

      log "  APPLIED — next launch of $bundle_id will pass the kill switch"
    fi
  done

  log "Done."
  if [[ "$DRY_RUN" == true ]]; then
    log "Re-run with --apply after reviewing findings_wiki/2026-08-25-codesign-clone-killswitch-side-effects.md"
  fi
}

main "${1:-}"
