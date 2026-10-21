# Shared logic for the rsync/rm destructive-path shims. Sourced, not executed.
# GUARD_DRYRUN=1 prints "ALLOW|DENY <reason>" and exits 0/3 without running the real binary.

guard_resolve() {  # print absolute, symlink-resolved path (no existence needed)
  local p="$1"
  [[ "$p" == "~" ]] && p="$HOME"
  [[ "$p" == "~/"* ]] && p="$HOME/${p:2}"
  [[ "$p" != /* ]] && p="$PWD/$p"
  if command -v realpath >/dev/null 2>&1 && realpath -m / >/dev/null 2>&1; then
    realpath -m -- "$p"
  else
    /usr/bin/python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$p"
  fi
}

# Returns 0 if the resolved path is a protected root or too shallow to delete into/from.
guard_is_protected() {
  local r="$1" h d
  h="$(guard_resolve "${HOME:-/nonexistent-home}")"
  case "$r" in
    /|"$h"|/Users|/private|/private/tmp|/private/var|/tmp|/var|/opt|/usr|/System|/Library|/Applications|/bin|/sbin|/etc|/dev|/Volumes|/cores|/opt/homebrew)
      return 0 ;;
    /tmp/?*|/var/tmp/?*|/dev/shm/?*)
      return 1 ;;
  esac
  d="${r#/}"; d="${d//[^\/]/}"   # count of slashes after the leading one
  (( ${#d} < 2 )) && return 0     # depth < 3 components below root, e.g. /a or /a/b
  return 1
}

guard_decide() {  # $1=ALLOW|DENY  $2=tool  $3=reason ; honors dry-run, else deny exits 3
  if [[ "${GUARD_DRYRUN:-}" == 1 ]]; then
    echo "$1 $2: $3"; [[ "$1" == ALLOW ]] && exit 0 || exit 3
  fi
  if [[ "$1" == DENY ]]; then
    echo "BLOCKED by destructive-path guard ($2): $3" >&2
    echo "Use an explicit, scoped path (non-empty, depth >= 3 after symlink resolution)." >&2
    exit 3
  fi
}
