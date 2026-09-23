# shellcheck shell=bash
# scratch_roots.sh — single source of truth for "where does agent/PR scratch
# live" across the scratch sweepers (cleanup_tmp.sh, cleanup_pr_scratch.sh).
#
# Bead disk_magician-d45: age-only sweepers never touched the 0-24h scratch
# that agents create under the macOS per-user temp dir
# ($(getconf DARWIN_USER_TEMP_DIR), e.g. /var/folders/xx/.../T which is a
# symlink chain to /private/var/folders/...) because cleanup_pr_scratch.sh
# only ever scanned /private/tmp and /tmp. cleanup_tmp.sh already resolved
# DARWIN_USER_TEMP_DIR inline; this file centralizes that logic so the next
# root only needs to be added once.
#
# Source this file, then call:
#   scratch_roots_get           prints one root per line (may repeat)
#   scratch_roots_get_unique    same, deduplicated, order preserved
#
# FAIL-CLOSED CONTRACT: if DARWIN_USER_TEMP_DIR cannot be resolved (getconf
# fails, the dir doesn't exist, or `cd + pwd -P` canonicalization fails) that
# root is silently SKIPPED for this run — never guessed at, never left
# uncanonicalized (an uncanonicalized /var/... path would fail every
# is_protected_tmp_path / safety_lib prefix match that expects the
# /private/var/... form, per safety_lib.sh's own DATA_PREFIX normalization).

# scratch_roots_get_user_tmp — prints the canonicalized macOS per-user temp
# dir (DARWIN_USER_TEMP_DIR), or nothing if it can't be resolved. Exposed
# separately (not just inline in scratch_roots_get) because callers besides
# the root-list loop (e.g. cleanup_tmp.sh's --opencode-dylibs branch) need
# this exact value on its own, not just as one line among several.
scratch_roots_get_user_tmp() {
  # DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE is a test-only injection
  # point so fixtures don't need to shim the `getconf` binary on PATH.
  local raw
  raw="${DISK_MAGICIAN_DARWIN_USER_TEMP_DIR_OVERRIDE:-}"
  if [[ -z "$raw" ]]; then
    raw="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
  fi
  if [[ -n "$raw" && -d "$raw" ]]; then
    local canon
    if canon="$(cd "$raw" 2>/dev/null && pwd -P)" && [[ -n "$canon" ]]; then
      echo "$canon"
    fi
  fi
}

# scratch_roots_get_private_tmp / scratch_roots_get_tmp — the two static
# scratch roots, each with a test-only override env var (same pattern as
# DARWIN_USER_TEMP_DIR above). Production (env unset) behavior is unchanged:
# literal /private/tmp and /tmp. Added for bead disk_magician-ka4: before
# this, cleanup_tmp.sh's --large branch hardcoded `find /private/tmp`
# directly with no override, so no test could confine it to a fixture
# without PATH-shimming `find` itself.
scratch_roots_get_private_tmp() {
  local root="${DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE:-/private/tmp}"
  [[ -d "$root" ]] && echo "$root"
}

scratch_roots_get_tmp() {
  local root="${DISK_MAGICIAN_TMP_ROOT_OVERRIDE:-/tmp}"
  [[ -d "$root" ]] && echo "$root"
}

# scratch_roots_get — one canonical root per line.
scratch_roots_get() {
  scratch_roots_get_private_tmp
  scratch_roots_get_tmp
  scratch_roots_get_user_tmp
}

# scratch_roots_get_unique — scratch_roots_get, deduplicated (order-preserving).
scratch_roots_get_unique() {
  scratch_roots_get | awk '!seen[$0]++'
}
