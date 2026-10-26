# shellcheck shell=bash
# admit_caller.sh — the caller side of `diskm admit` (spec §7.1 exit-code
# channel). Source it, then gate the command:
#
#   admit_gate <class> <est-gb> <producer> <dest> <source> [admit args…] || exit 75
#
# rc 0 = run the command; 75 = refused, the command must not start (the
# `disk-admission: refused` line is already on stderr). Admit rc 10 warns and
# proceeds; 76 retries once after DISK_MAGICIAN_ADMIT_RETRY_S (default 600 s,
# spec retry_after_s) and refuses if not cleared; a missing admit or any other
# rc is admission_degraded:caller and proceeds like 10 (counted as bypass).
# DISK_MAGICIAN_ADMIT_BIN replaces the admit command (test hook).
#
# Estimate resolution: an empty or `-` <est-gb> omits `--est-gb` and lets the
# admit side resolve the calibrated producer estimate (spec C2); a numeric
# value is an explicit caller override and is always passed through.

_ADMIT_CALLER_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

# admit_available — rc 0 when the admit command actually exists. Callers use
# this to decide whether the shared admission gate or the legacy fallback owns
# the decision (plan Task 4: legacy thresholds remain only when admit is
# missing).
admit_available() {
    local file
    if [[ -n "${DISK_MAGICIAN_ADMIT_BIN:-}" ]]; then file="$DISK_MAGICIAN_ADMIT_BIN"
    else file="$_ADMIT_CALLER_DIR/../disk_budget.py"; fi
    [[ -f "$file" ]]
}

# admit_class_for <abs-path> — the governed class a birth at <path> is charged to (the host roots
# hooks/disk-admission.sh governs); prints nothing when <path> is on no governed root.
admit_class_for() {
    case "$1" in
        "$HOME/.worktrees/"?*) echo worktrees ;;
        "$HOME/Documents/Codex/"?*) echo codex_documents ;;
        /tmp/?*|/private/tmp/?*) echo tmp_containers ;;
        *) if [[ -n "${TMPDIR:-}" && ( "$1" == "${TMPDIR%/}/"?* || "$1" == "/private${TMPDIR%/}/"?* ) ]]; then
               echo tmpdir_scratch
           fi ;;
    esac
}

# admit_is_configured_volume_path <abs-path> — true when the path resolves
# beneath the configured quota-volume mountpoint. The volume configuration is
# the authority; this deliberately does not infer a mount from a fixed path.
admit_is_configured_volume_path() {
    python3 - "$_ADMIT_CALLER_DIR" "$1" <<'PY'
import json, os, pathlib, sys
try:
    sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
    import resolve_config
    config_path = resolve_config.resolve()
    if not config_path:
        raise ValueError("configuration unavailable")
    data = json.loads(pathlib.Path(config_path).read_text())
    mount = data["volumes"]["classes"]["scratch"]["mountpoint"]
    if not isinstance(mount, str) or not pathlib.Path(mount).is_absolute():
        raise ValueError("invalid quota mountpoint")
    pathlib.Path(os.path.realpath(sys.argv[2])).relative_to(pathlib.Path(os.path.realpath(os.path.expanduser(mount))))
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(1)
PY
}

admit_gate() {
    local cls="$1" est="$2" producer="$3" dest="$4" source="$5" rc try cmd output line
    ADMIT_ID=""
    local -a est_arg=()
    if [[ -n "$est" && "$est" != - ]]; then est_arg=(--est-gb "$est"); fi
    if [[ -n "${DISK_MAGICIAN_ADMIT_BIN:-}" ]]; then cmd=("$DISK_MAGICIAN_ADMIT_BIN")
    else cmd=(python3 "$_ADMIT_CALLER_DIR/../disk_budget.py"); fi
    if [[ ! -f "${cmd[${#cmd[@]}-1]}" ]]; then
        echo "admission_degraded:caller admit missing" >&2
        return 0
    fi
    for try in 1 2; do
        if output="$("${cmd[@]}" --class "$cls" ${est_arg[@]+"${est_arg[@]}"} --producer "$producer" \
            --dest "$dest" --source "$source" "${@:6}")"; then
            rc=0
        else
            rc=$?
        fi
        [[ "$rc" == 76 && "$try" == 1 ]] || break
        echo "disk-admission: queued class=$cls, retrying once" >&2
        sleep "${DISK_MAGICIAN_ADMIT_RETRY_S:-600}"
    done
    if [[ "$rc" == 0 || "$rc" == 10 ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^admit_id=([a-f0-9-]+)$ ]] && ADMIT_ID="${BASH_REMATCH[1]}"
        done <<< "$output"
    fi
    case "$rc" in
        0) return 0 ;;
        10) echo "disk-admission: warn class=$cls" >&2; return 0 ;;
        75|76) echo "disk-admission: refused class=$cls rc=$rc" >&2; return 75 ;;
        *) echo "admission_degraded:caller rc=$rc" >&2; return 0 ;;
    esac
}

# Confirm only the successful creator's exact admission attempt.
admit_confirm_created() {
    [[ -n "${ADMIT_ID:-}" ]] || return 0
    local cmd
    if [[ -n "${DISK_MAGICIAN_ADMIT_BIN:-}" ]]; then cmd=("$DISK_MAGICIAN_ADMIT_BIN")
    else cmd=(python3 "$_ADMIT_CALLER_DIR/../disk_budget.py"); fi
    "${cmd[@]}" --confirm "$ADMIT_ID" >/dev/null ||
        echo 'admission_degraded:confirm' >&2
    ADMIT_ID=""
}
