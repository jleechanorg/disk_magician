# shellcheck shell=bash
# lsof_linux.sh — Linux-aware interpretation of `lsof -d cwd` for live-cwd gates.
#
# On Linux an unprivileged lsof always (1) warns that it cannot stat() some
# mounts (tracefs, snapd namespaces) and (2) reports other users' processes as
# "/proc/<pid>/cwd (readlink: Permission denied)". Neither hides a cwd this
# user could be removing, so treating them as an incomplete scan blocks every
# cleanup forever. Everything else still fails closed.

# lsof_stderr_incomplete <stderr text>: rc 0 when any line is not a mount-stat
# warning or its "Output information may be incomplete." trailer.
lsof_stderr_incomplete() {
  [[ -n "$1" ]] || return 1
  grep -qvE "^lsof: WARNING: can't stat\(\) [^ ]+ file system |^ +Output information may be incomplete\.$" <<<"$1"
}

# lsof_drop_foreign_denied: filter `-Fn` records on stdin, dropping hidden-cwd
# records that lsof_denied_ignorable clears; the rest stay so callers fail closed.
lsof_drop_foreign_denied() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^n(/proc/[0-9]+/cwd\ \(readlink:\ Permission\ denied\))$ ]]; then
      lsof_denied_ignorable "${BASH_REMATCH[1]}" && continue
    fi
    printf '%s\n' "$line"
  done
}

# lsof_denied_ignorable "/proc/<pid>/cwd (readlink: Permission denied)": rc 0
# when that hidden cwd cannot be this user's live use: the process exited,
# belongs to another uid, or is an own process approved via
# DISK_MAGICIAN_UNSCANNABLE_CWD_APPROVED=1. Own processes are reported on stderr.
lsof_denied_ignorable() {
  local pid owner
  [[ "$1" =~ ^/proc/([0-9]+)/cwd\ \(readlink:\ Permission\ denied\)$ ]] || return 1
  pid="${BASH_REMATCH[1]}"
  [[ -e "/proc/$pid" ]] || return 0
  owner="$(stat -c %u "/proc/$pid" 2>/dev/null || true)"
  [[ "$owner" =~ ^[0-9]+$ ]] || return 1
  [[ "$owner" != "$(id -u)" ]] && return 0
  echo "lsof: own process $pid hides its cwd: $(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" >&2
  [[ "${DISK_MAGICIAN_UNSCANNABLE_CWD_APPROVED:-}" == 1 ]]
}
