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
# literal /private/tmp and /tmp; a missing root (e.g. /private/tmp on Linux)
# prints nothing and still returns 0 so `set -e` callers survive. Added for bead disk_magician-ka4: before
# this, cleanup_tmp.sh's --large branch hardcoded `find /private/tmp`
# directly with no override, so no test could confine it to a fixture
# without PATH-shimming `find` itself.
scratch_roots_get_private_tmp() {
  local root="${DISK_MAGICIAN_PRIVATE_TMP_ROOT_OVERRIDE:-}"
  if [[ -z "$root" ]]; then
    # Platform-aware default (bead disk_magician-ty62). /private/tmp is the
    # macOS canonical path (/tmp is a symlink to it there), but Linux has no
    # /private/tmp at all — so the old hardcoded default made cleanup_tmp's
    # --large scan resolve to nothing and skip with "private-tmp root is
    # unavailable", silently disabling the aggressive tier on every Linux host.
    # Try the candidates in order and use the first that exists.
    local cand
    local -a cands=()
    IFS=':' read -r -a cands <<<"${DISK_MAGICIAN_PRIVATE_TMP_CANDIDATES:-/private/tmp:/tmp}"
    for cand in "${cands[@]}"; do
      if [[ -n "$cand" && -d "$cand" ]]; then root="$cand"; break; fi
    done
  fi
  if [[ -n "$root" && -d "$root" ]]; then echo "$root"; fi
}

scratch_roots_get_tmp() {
  local root="${DISK_MAGICIAN_TMP_ROOT_OVERRIDE:-/tmp}"
  if [[ -d "$root" ]]; then echo "$root"; fi
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

# Mounted quota volumes are a separate C14 domain, never ordinary tmp roots.
scratch_roots_get_volumes() {
  local cfg="${1:-${DISK_MAGICIAN_CONFIG:-}}" root
  if [[ -z "$cfg" ]]; then cfg="$(python3 "$(dirname "${BASH_SOURCE[0]}")/../resolve_config.py" 2>/dev/null)" || return 0; fi
  [[ -f "$cfg" ]] || return 0
  while IFS= read -r root; do
    [[ -n "$root" && -d "$root" ]] || continue
    (cd "$root" 2>/dev/null && pwd -P)
  done < <(python3 - "$cfg" <<'PYVOLUMES'
import json,sys
try:
 d=json.load(open(sys.argv[1]))
 for c in (d.get("volumes",{}).get("classes",{}) or {}).values():
  p=c.get("mountpoint") if isinstance(c,dict) else None
  if isinstance(p,str) and p: print(p)
except Exception: pass
PYVOLUMES
  )
}

# scratch_roots_protected [config.json] — never-touch tmp root basenames, one per
# line: DISK_MAGICIAN_PROTECTED_TMP_ROOTS (space-separated), else the config's
# "protected_tmp_roots", else the defaults cleanup_tmp.sh uses.
scratch_roots_protected() {
  local r out=()
  if [[ -n "${DISK_MAGICIAN_PROTECTED_TMP_ROOTS:-}" ]]; then
    read -r -a out <<<"$DISK_MAGICIAN_PROTECTED_TMP_ROOTS"
  elif [[ -f "${1:-}" ]]; then
    while IFS= read -r r; do [[ -n "$r" ]] && out+=("$r"); done < <(python3 -c 'import json,sys
for r in json.load(open(sys.argv[1])).get("protected_tmp_roots") or []: print(r)' "$1" 2>/dev/null)
  fi
  [[ ${#out[@]} -gt 0 ]] || out=(worldarchitect.ai worldai_claw wa-missions)
  printf '%s\n' "${out[@]}"
}

# scratch_roots_protected_paths [config.json] — the concrete protected roots,
# one canonical path per line: each configured protected basename joined onto
# each real scratch root. A basename is only protected as a TOP-LEVEL entry of
# a configured scratch root, never as an arbitrary path component, so
# ~/.worktrees/worldarchitect.ai/foo is not protected while
# /private/tmp/worldarchitect.ai/foo is. Aliases (/tmp -> /private/tmp) and
# symlinked scratch roots are canonicalized here so both spellings match.
scratch_roots_protected_paths() {
  local root root_canon base
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    root_canon="$(cd "$root" 2>/dev/null && pwd -P)" || root_canon="$root"
    [[ -n "$root_canon" ]] || continue
    while IFS= read -r base; do
      [[ -n "$base" ]] || continue
      printf '%s/%s\n' "${root_canon%/}" "$base"
    done < <(scratch_roots_protected "${1:-}")
  done < <(scratch_roots_get_unique)
}

# scratch_roots_is_protected_path <path> [config.json] — rc 0 when <path> is a
# configured protected root or a descendant of one, using the anchored table
# above. Fail closed: an unresolvable path is compared in its raw form, never
# silently dropped.
scratch_roots_is_protected_path() {
  local p="$1" cfg="${2:-}" canon prot
  canon="$(cd "$p" 2>/dev/null && pwd -P)" || canon="$p"
  [[ -n "$canon" ]] || canon="$p"
  while IFS= read -r prot; do
    [[ -n "$prot" ]] || continue
    [[ "$canon" == "$prot" || "$canon" == "$prot"/* ]] && return 0
  done < <(scratch_roots_protected_paths "$cfg")
  return 1
}
