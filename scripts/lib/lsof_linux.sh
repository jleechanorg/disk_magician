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

# lsof_drop_foreign_denied: filter `-Fn` records on stdin. A
# "n/proc/<pid>/cwd (readlink: Permission denied)" line is dropped when the
# process has exited (no cwd left) or belongs to another uid. Own non-dumpable
# processes (sshd session, sd-pam) are kept so callers fail closed, unless
# DISK_MAGICIAN_UNSCANNABLE_CWD_APPROVED=1 records an explicit human approval;
# those are reported on stderr either way.
lsof_drop_foreign_denied() {
  local me line pid owner
  me="$(id -u)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^n/proc/([0-9]+)/cwd\ \(readlink:\ Permission\ denied\)$ ]]; then
      pid="${BASH_REMATCH[1]}"
      [[ -e "/proc/$pid" ]] || continue
      owner="$(stat -c %u "/proc/$pid" 2>/dev/null || true)"
      [[ "$owner" =~ ^[0-9]+$ && "$owner" != "$me" ]] && continue
      if [[ "$owner" == "$me" ]]; then
        echo "lsof: own process $pid hides its cwd: $(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" >&2
        [[ "${DISK_MAGICIAN_UNSCANNABLE_CWD_APPROVED:-}" == 1 ]] && continue
      fi
    fi
    printf '%s\n' "$line"
  done
}
