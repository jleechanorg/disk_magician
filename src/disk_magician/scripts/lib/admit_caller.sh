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

_ADMIT_CALLER_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"

admit_gate() {
    local cls="$1" est="$2" producer="$3" dest="$4" source="$5" rc try cmd
    if [[ -n "${DISK_MAGICIAN_ADMIT_BIN:-}" ]]; then cmd=("$DISK_MAGICIAN_ADMIT_BIN")
    else cmd=(python3 "$_ADMIT_CALLER_DIR/../disk_budget.py"); fi
    if [[ ! -f "${cmd[${#cmd[@]}-1]}" ]]; then
        echo "admission_degraded:caller admit missing" >&2
        return 0
    fi
    for try in 1 2; do
        if "${cmd[@]}" --class "$cls" --est-gb "$est" --producer "$producer" \
            --dest "$dest" --source "$source" "${@:6}" >/dev/null; then
            rc=0
        else
            rc=$?
        fi
        [[ "$rc" == 76 && "$try" == 1 ]] || break
        echo "disk-admission: queued class=$cls, retrying once" >&2
        sleep "${DISK_MAGICIAN_ADMIT_RETRY_S:-600}"
    done
    case "$rc" in
        0) return 0 ;;
        10) echo "disk-admission: warn class=$cls" >&2; return 0 ;;
        75|76) echo "disk-admission: refused class=$cls rc=$rc" >&2; return 75 ;;
        *) echo "admission_degraded:caller rc=$rc" >&2; return 0 ;;
    esac
}
