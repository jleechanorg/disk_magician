# shellcheck shell=bash
# lsof_linux.sh — Linux-aware interpretation of `lsof -d cwd` for live-cwd gates.
#
# On Linux an unprivileged lsof always (1) warns that it cannot stat() some
# mounts (tracefs, snapd namespaces), which cannot hide a cwd, and (2) reports
# processes it cannot inspect as "/proc/<pid>/cwd (readlink: Permission
# denied)". (1) is ignored; (2) stays unknown unless the process exited or an
# operator explicitly approves uninspectable processes. Everything else still
# fails closed.

# lsof_stderr_incomplete <stderr text>: rc 0 when any line is not a mount-stat
# warning or its "Output information may be incomplete." trailer.
lsof_stderr_incomplete() {
  # rc 0 => the scan may be incomplete. Glob matching, not regex: the warning
  # contains an apostrophe, and mount paths may hold any character.
  local line trimmed fs warned=0
  [[ -n "$1" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      "lsof: WARNING: can"*" stat() "*" file system "*)
        fs="${line##* file system }"
        while [[ "$fs" == */ ]]; do fs="${fs%/}"; done
        [[ -z "$fs" ]] && fs="/"
        [[ "$fs" == "/" ]] && return 0
        warned=1
        continue ;;
    esac
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ "$trimmed" == "Output information may be incomplete." ]]; then
      (( warned )) && { warned=0; continue; }
      return 0
    fi
    return 0
  done <<<"$1"
  return 1
}

# lsof_denied_ignorable "/proc/<pid>/cwd (readlink: Permission denied)": rc 0
# when that hidden cwd cannot be this user's live use -- the process exited, it
# belongs to another uid, or nothing can be read from it at all. Without procfs
# nothing can be classified, so it fails closed. Set
# DISK_MAGICIAN_UNSCANNABLE_CWD_STRICT=1 to treat every live unreadable cwd as
# unknown instead (the paranoid reading).
lsof_denied_ignorable() {
  local pid owner
  [[ "$1" =~ ^/proc/([0-9]+)/cwd\ \(readlink:\ Permission\ denied\)$ ]] || return 1
  pid="${BASH_REMATCH[1]}"
  # Without procfs nothing can be classified, so fail closed.
  [[ -d /proc/self ]] || return 1
  # Exited: cannot hold anything.
  [[ -e "/proc/$pid" ]] || return 0
  # A foreign-uid process cannot read THIS user's live use, but it could still
  # hold a candidate; only the operator can waive that, so this stays unknown
  # unless they do. Approving uninspectable processes is the documented opt-in
  # for running cleanups on a box where an unprivileged lsof can never see them.
  owner="$(stat -c %u "/proc/$pid" 2>/dev/null || true)"
  if [[ "$owner" =~ ^[0-9]+$ ]] && [[ "$owner" != "$(id -u)" ]]; then
    echo "lsof: foreign process $pid hides its cwd" >&2
  else
    echo "lsof: own process $pid hides its cwd: $(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" >&2
  fi
  [[ "${DISK_MAGICIAN_UNSCANNABLE_CWD_APPROVED:-}" == 1 ]]
}

# ---------------------------------------------------------------------------
# Strict cwd-observation parser — ONE implementation for every live-cwd gate.
#
# `lsof -d cwd -Fn` emits one block per process: `p<pid>`, `fcwd`, `n<cwd>`.
# A block can be incomplete (no `n` record), repeat a field, or carry a
# diagnostic instead of a path ("/proc/12/cwd (readlink: Permission denied)",
# "/mnt/x (stat: Permission denied)"). Every consumer must treat any of those as
# "cannot prove idle"; silently skipping a record is what let an occupied
# worktree look idle. Use these functions instead of re-parsing lsof output.

# lsof_cwd_blocks <output>: emit "pid|status|value" per process block.
#   status = ok         -> value is the raw `n` record
#            incomplete -> block lacked `fcwd` and/or `n`
#            bad        -> repeated field, stray record, or empty pid
# Always exits 0; malformed input shows up as a non-ok status, never as silence.
lsof_cwd_blocks() {
    local out
    out="$(cat)"
    if ! grep -q '^p' <<<"$out"; then
        # No pid records: output is not `-Fpn` and its block boundaries are
        # unknowable, so it cannot establish idle.
        printf -- '-|nopid|\n'
        return 0
    fi
    awk '
        function emit() {
            if (bad) print pid "|bad|"
            else if (!f && !n) print pid "|nofd|"     # resolved below: fails closed
            else if (f && !n) print pid "|incomplete|"
            else print pid "|ok|" val                  # `p`+`n` (-Fpn) or `p`+`f`+`n`
        }
        /^p/ {
            if (started) emit()
            started = 1; bad = 0; f = 0; n = 0; val = ""
            pid = substr($0, 2); if (pid == "") bad = 1
            next
        }
        /^f/ { if (!started) { pre = 1; next } if (f) bad = 1; f = 1; next }
        /^n/ {
            if (!started) { pre = 1; next }
            if (n) bad = 1
            n = 1; val = substr($0, 2); next
        }
        { if (!started) pre = 1; else bad = 1 }
        END { if (started) emit(); if (pre) print "-|bad|" }
    ' <<<"$out"
}

# lsof_cwd_value_verdict <n-record value>: echoes resolved | ignorable | unknown.
#   resolved  -> an absolute path this user could match against
#   ignorable -> an uninspectable record proven harmless (exited, foreign uid,
#                or an unreadable /proc cwd; see lsof_denied_ignorable)
#   unknown   -> anything else; the caller must fail closed
lsof_cwd_value_verdict() {
    local cwd="$1"
    if [[ "$cwd" =~ \([A-Za-z]+:\ .*\)$ ]]; then
        if lsof_denied_ignorable "$cwd" 2>/dev/null; then echo ignorable
        else echo unknown
        fi
        return 0
    fi
    [[ "$cwd" == /* ]] || { echo unknown; return 0; }
    echo resolved
}

# lsof_collect_cwds <output> <stderr> <rc>: rc 0 and LSOF_CWDS = newline-separated
# resolved absolute cwds (at least one). rc 1 and LSOF_CWD_REASON = short cause.
# Never returns an empty-yet-successful observation.
lsof_collect_cwds() {
    local out="$1" err="$2" rc="$3" blocks pid status val verdict cwds=""
    LSOF_CWDS=""; LSOF_CWD_REASON=""
    if [[ "${rc:-1}" -ne 0 ]]; then LSOF_CWD_REASON="lsof-exit-${rc:-1}"; return 1; fi
    if lsof_stderr_incomplete "$err"; then LSOF_CWD_REASON="stderr-incomplete"; return 1; fi
    if ! blocks="$(lsof_cwd_blocks <<<"$out")"; then LSOF_CWD_REASON="unparseable"; return 1; fi
    while IFS='|' read -r pid status val; do
        # An empty pid is a malformed block (or a record before any `p`); skipping
        # it would hide the very record that makes the scan incomplete.
        [[ -n "$pid" ]] || { LSOF_CWD_REASON="empty-pid"; return 1; }
        if [[ "$status" != ok ]]; then LSOF_CWD_REASON="block-$status"; return 1; fi
        verdict="$(lsof_cwd_value_verdict "$val")"
        case "$verdict" in
            resolved) cwds+="$val"$'\n' ;;
            ignorable) : ;;
            *) LSOF_CWD_REASON="unresolvable-cwd"; return 1 ;;
        esac
    done <<<"$blocks"
    if [[ -z "$cwds" ]]; then LSOF_CWD_REASON="no-resolved-cwd"; return 1; fi
    LSOF_CWDS="${cwds%$'\n'}"
    return 0
}

# lsof_snapshot_cwds: run lsof once and populate LSOF_CWDS / LSOF_CWD_REASON.
# rc 0 = complete observation, rc 1 = cannot prove idle.
lsof_snapshot_cwds() {
    local bin errf rc=0 out err
    LSOF_CWDS=""; LSOF_CWD_REASON=""
    bin="$(command -v lsof 2>/dev/null || echo /usr/sbin/lsof)"
    [[ -x "$bin" ]] || { LSOF_CWD_REASON="lsof-unavailable"; return 1; }
    errf="$(mktemp "${TMPDIR:-/tmp}/dm-lsof-err.XXXXXX" 2>/dev/null)" || { LSOF_CWD_REASON="stderr-capture-failed"; return 1; }
    [[ -f "$errf" ]] || { LSOF_CWD_REASON="stderr-capture-failed"; return 1; }
    out="$("$bin" -d cwd -Fpn 2>"$errf")" || rc=$?
    if ! err="$(cat "$errf" 2>/dev/null)"; then
        rm -f "$errf"; LSOF_CWD_REASON="stderr-read-failed"; return 1
    fi
    rm -f "$errf"
    lsof_collect_cwds "$out" "$err" "$rc"
}

# cwd_list_has_path <candidate> <newline-separated cwds>: rc 0 when the candidate
# (or its physical path) is one of the observed cwds or lives beneath one.
cwd_list_has_path() {
    local candidate="$1" cwds="$2" real cwd
    [[ -n "$candidate" ]] || return 1
    real="$(cd "$candidate" 2>/dev/null && pwd -P || printf '%s' "$candidate")"
    while IFS= read -r cwd; do
        [[ -n "$cwd" ]] || continue
        [[ "$cwd" == "$candidate" || "$cwd" == "$candidate"/* || "$cwd" == "$real" || "$cwd" == "$real"/* ]] && return 0
    done <<<"$cwds"
    return 1
}
