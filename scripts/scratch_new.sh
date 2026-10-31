#!/usr/bin/env bash
# scratch_new.sh — `diskm scratch-new <repo-path> <purpose> [--kind scratch|evidence|build]
# [--detach <sha>] [--est-gb N]` (spec C3): admit, create ~/.worktrees/<repo>/
# scratch-<purpose>-<UTC ts> (a detached worktree with --detach) or, for evidence,
# $EVIDENCE_TMP_ROOT/<repo>/evidence/<purpose>-<UTC ts>, lease it, print the path.
# Exit 2 bad args or path outside its root, 75 admission refused (nothing created).
_SN_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# shellcheck source=scripts/worktree_new.sh
source "$_SN_DIR/worktree_new.sh"

# sn_admit <class> <est> <dest> <producer> — caller contract: 0/10 proceed, 75
# refuse, 76 retry once then refuse, any other rc proceeds as degraded (bypass).
# DISK_MAGICIAN_ADMIT_BIN replaces `diskm admit` in tests.
sn_admit() {
    if [[ "${5:-}" == required ]]; then
        admit_gate_required "$1" "$2" "$4" "$3" scratch-new
    else
        admit_gate "$1" "$2" "$4" "$3" scratch-new
    fi
}

sn_main() {
    local -a pos=()
    local -a lease_owner_args=()
    local -a producer_owner_list=()
    local kind=scratch sha="" est="" owner_pid="" producer_owner="" producer_pid="" producer_pids="${DISK_MAGICIAN_SCRATCH_PRODUCER_PIDS:-${DISK_MAGICIAN_SCRATCH_PRODUCER_PID:-}}" runner_owner="" runner_pid="" repo name path root cls=worktrees src="" volume_bin="${DISK_MAGICIAN_DISKM_BIN:-}" volume_rc quota_volume=0 admit_mode=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kind) kind="${2:-}"; shift 2 || return 2 ;;
            --detach) sha="${2:-}"; shift 2 || return 2 ;;
            --est-gb) est="${2:-}"; shift 2 || return 2 ;;
            --owner-pid) owner_pid="${2:-}"; shift 2 || return 2 ;;
            -*) echo "scratch-new: unknown option: $1" >&2; return 2 ;;
            *) pos+=("$1"); shift ;;
        esac
    done
    [[ ${#pos[@]} -eq 2 && "${pos[1]}" =~ ^[a-z0-9-]{1,40}$ && ( -z "$est" || "$est" =~ ^[0-9]+(\.[0-9]+)?$ ) ]] &&
        [[ "$kind" == scratch || ( ( "$kind" == evidence || "$kind" == build ) && -z "$sha" ) ]] ||
        { echo "usage: diskm scratch-new <repo-path> <purpose ^[a-z0-9-]{1,40}\$> [--kind scratch|evidence|build] [--detach <sha>] [--est-gb N] [--owner-pid PID]" >&2; return 2; }
    repo="$(wtn_main_repo "${pos[0]}")" || { echo "scratch-new: not a git repo: ${pos[0]}" >&2; return 2; }
    name="$(wtn_repo_name "$repo")"
    if [[ "$kind" == evidence || "$kind" == build ]]; then
        cls=tmp_containers
        if [[ -z "$volume_bin" ]]; then volume_bin="$_SN_DIR/../disk_magician.sh"; fi
        root="$("$volume_bin" volume path scratch 2>/dev/null)"; volume_rc=$?
        case "$volume_rc" in
            0) quota_volume=1; path="${root%/}/$name/$kind/${pos[1]}-$(date -u +%Y%m%dT%H%M%SZ)" ;;
            3)
                root="$EVIDENCE_TMP_ROOT"
                path="${root%/}/$name/$kind/${pos[1]}-$(date -u +%Y%m%dT%H%M%SZ)"
                ;;
            75) echo "scratch-new: scratch volume unavailable" >&2; return 75 ;;
            *) echo "scratch-new: volume path check failed ($volume_rc)" >&2; return 75 ;;
        esac
    else
        root="$STANDARD_WORKTREE_ROOT" path="$(standard_worktree_path "$name" "scratch-${pos[1]}-$(date -u +%Y%m%dT%H%M%SZ)")" || return 2
    fi
    [[ "$(_layout_resolve "$path")" == "$(_layout_resolve "${root%/}")/"* ]] ||
        { echo "scratch-new: $path resolves outside $root" >&2; return 2; }
    if [[ -n "$sha" ]]; then
        sha="$(git -C "$repo" rev-parse -q --verify "$sha^{commit}")" || { echo "scratch-new: unknown commit" >&2; return 1; }
        src="git:$(git -C "$repo" remote get-url origin 2>/dev/null || echo "$repo")@$sha"
    fi
    [[ -n "$producer_pids" ]] || producer_pids="$PPID"
    IFS=, read -r -a producer_pid_list <<<"$producer_pids"
    for producer_pid in "${producer_pid_list[@]}"; do
        producer_owner="$(lease_resolve_process_owner "$producer_pid")" || { echo "scratch-new: producer identity unavailable" >&2; return 75; }
        producer_owner_list+=("$producer_owner")
        lease_owner_args+=(--owner-pid "$producer_pid")
    done
    if runner_owner="$(lease_resolve_runner_worker "$$" 2>/dev/null)"; then
        runner_pid="$(cut -f1 <<<"$runner_owner")"
        lease_owner_args+=(--owner-pid "$runner_pid")
    elif [[ "${GITHUB_ACTIONS:-}" == true || -n "${GITHUB_RUN_ID:-}" ]]; then
        echo "scratch-new: CI worker identity unavailable" >&2
        return 75
    fi
    if [[ -n "$owner_pid" ]]; then
        lease_resolve_process_owner "$owner_pid" >/dev/null || { echo "scratch-new: owner identity unavailable: pid=$owner_pid" >&2; return 75; }
        lease_owner_args+=(--owner-pid "$owner_pid")
    fi
    [[ "$quota_volume" == 1 ]] && admit_mode=required
    sn_admit "$cls" "$est" "$path" "scratch-new:$name" "$admit_mode" || return $?
    if [[ "$kind" == evidence || "$kind" == build ]]; then
        local parent="$(dirname "$path")"
        mkdir -p "$parent" || return 1
        python3 - "$parent/.dm-quarantine" <<'PYQUARANTINEDIR'
import os, stat, sys
p=sys.argv[1]
try:
    os.mkdir(p, 0o700)
except FileExistsError:
    pass
try:
    st=os.lstat(p)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid(): raise SystemExit(1)
    os.chmod(p, 0o700)
    st=os.lstat(p)
    if stat.S_IMODE(st.st_mode) != 0o700 or st.st_uid != os.getuid(): raise SystemExit(1)
except Exception:
    raise SystemExit(1)
PYQUARANTINEDIR
        [[ $? -eq 0 ]] || { echo "scratch-new: quarantine directory unavailable" >&2; return 1; }
    else
        mkdir -p "$(dirname "$path")" || return 1
    fi
    mkdir -m 700 "$path" || return 1
    if [[ -n "$sha" ]] && ! wtn_timeout "${WTN_ADD_TIMEOUT:-30}" git -C "$repo" worktree add --detach "$path" "$sha" >&2; then
        wtn_registered "$repo" "$path" || wtn_unclaim "$path"
        return 1
    fi
    admit_confirm_created
    if ! declare -F lease_write >/dev/null 2>&1 || ! lease_write "$path" "$repo" "" scratch-new --kind "$kind" \
        --producer scratch-new ${src:+--source "$src"} "${lease_owner_args[@]}" >/dev/null 2>&1; then
        echo "scratch-new: lease write failed: $path${LEASE_REGISTRATION_FAILURE:+ ($LEASE_REGISTRATION_FAILURE)}" >&2
        return 1
    fi
    for i in "${!producer_pid_list[@]}"; do
        producer_pid="${producer_pid_list[$i]}"
        [[ "$(lease_resolve_process_owner "$producer_pid" 2>/dev/null)" == "${producer_owner_list[$i]}" ]] || {
            echo "scratch-new: producer identity changed before path handoff" >&2
            return 75
        }
    done
    if [[ -n "$runner_pid" && "$(lease_resolve_runner_worker "$$" 2>/dev/null)" != "$runner_owner" ]]; then
        echo "scratch-new: CI worker identity changed before path handoff" >&2
        return 75
    fi
    printf '%s\n' "$path"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sn_main "$@"
    exit $?
fi
