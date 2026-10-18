#!/usr/bin/env bash
# worktree_hygiene.sh — repeatable IDENTIFY -> TRIAGE -> CLASSIFY worktree
# cleanup, formalizing the manual sweep run 2026-07-16 (bead jleechan-ue9w).
#
# 1) IDENTIFY: worktrees under each --repos entry whose most-recent file
#    mtime (excluding .git/, node_modules/, venv/, __pycache__/) is older
#    than --min-age days, AND with no live tmux pane currently sitting in
#    them (worktree_has_live_tmux_pane -- any session, not just a specific
#    naming convention; jleechan-dqiz hard gate).
# 2) TRIAGE per candidate: uncommitted/untracked status, `git push origin
#    HEAD:<branch>` preservation (never --force; non-FF retries to a
#    backup/<branch>-<date> ref), `gh pr list` PR coverage, ahead-count and
#    merge-base vs the repo's main ref.
# 3) CLASSIFY: SAFE (zero-ahead or merged-PR-and-clean) vs NEEDS-REVIEW
#    (open PR, detached-unpushed, untracked, large diff, no merge-base,
#    unpushed-ahead, or generically dirty).
#
# Defaults to dry-run. --execute requires WORKTREE_APPROVED=1. Deletions use
# `git worktree remove --force`, never raw `rm -rf` (that leaves dangling
# worktree metadata in the main repo's .git).
#
# NEEDS-REVIEW candidates are NOT auto-filed as beads here — this script only
# classifies and reports; routing NEEDS-REVIEW output to an agent for
# bead-worthiness judgment is a deliberate separate step (that's a judgment
# call, not a deterministic git-state check, so it does not belong in bash).
set -euo pipefail
# Never let a repo-configured fsmonitor command run from this sweep (status,
# ls-files, diff all invoke it). Functions that also disable hooks extend this.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/worktree_repo_discovery.sh
source "$SCRIPT_DIR/lib/worktree_repo_discovery.sh"
# shellcheck source=lib/worktree_recency.sh
source "$SCRIPT_DIR/lib/worktree_recency.sh"
# shellcheck source=scripts/lib/worktree_ignored.sh
source "$SCRIPT_DIR/lib/worktree_ignored.sh"
# shellcheck source=lib/lsof_linux.sh
source "$SCRIPT_DIR/lib/lsof_linux.sh"
# shellcheck source=scripts/safety_lib.sh
source "$SCRIPT_DIR/safety_lib.sh"

EXECUTE=false
MIN_AGE_DAYS="${WORKTREE_MIN_AGE_DAYS:-7}"
REPOS=()
SKIP_PUSH=false
SKIP_GH=false
PRESERVE_WIP=false
PUSH_WIP=false
MAX_CANDIDATES=0
# A raw `git rev-list --count main..HEAD` ahead-count above this is not
# trusted as a real commit count -- a history rewrite (rebase --onto,
# filter-branch, force-pushed main) can make an unrelated worktree report
# 9000+ false "ahead" commits (memory
# feedback_2026-07-18_git_ahead_count_false_positive_on_rewritten_history).
# Candidates above the cap are classified suspect-history-rewrite instead of
# unpushed-ahead; see classify_candidate.
WORKTREE_AHEAD_SANITY_CAP="${WORKTREE_AHEAD_SANITY_CAP:-500}"
# Non-numeric cap would crash bash arithmetic under set -u (the string gets
# evaluated as a variable name); fall back to the default instead.
[[ "$WORKTREE_AHEAD_SANITY_CAP" =~ ^[0-9]+$ ]] || WORKTREE_AHEAD_SANITY_CAP=500

usage() {
    cat <<EOF
Usage: $(basename "$0") [--execute] [--min-age N] [--days N] [--repos p1,p2,...] [--skip-push|--no-push] [--skip-gh] [--preserve-wip] [--push-wip] [--max-candidates N] [-h|--help]

Repeatable worktree-hygiene sweep: IDENTIFY -> TRIAGE -> CLASSIFY -> (optionally) DELETE.

Options:
  --execute     Actually delete SAFE-classified worktrees via
                'git worktree remove --force' (default: dry-run/report-only).
                Requires WORKTREE_APPROVED=1 in the environment.
  --min-age N   Minimum worktree age in days for candidacy (default: 7).
  --days N      Alias for --min-age N.
  --repos LIST  Comma-separated main repo paths to scan (default:
                CLAUDE_WORKTREE_REPOS env override, else auto-discover --
                same logic as cleanup_worktrees.sh).
  --skip-push   Skip the 'git push origin HEAD:<branch>' preservation step
                during triage and WIP publication (alias: --no-push).
                Locally preserved WIP stays in its worktree when push is skipped.
  --skip-gh     Skip the 'gh pr list' lookup during triage (offline/test
                runs). pr_state="unknown".
  --preserve-wip
                Opt-in. NEEDS-REVIEW worktrees whose only reason is dirty,
                untracked, or detached-unpushed are committed (git add -A,
                ignored files excluded) onto a LOCAL branch
                wip/worktree-hygiene/<YYYYMMDD>/<name> and then, with --push-wip, removed with
                'git worktree remove' (no --force) only after normal push
                and exact remote-ref verification. Failed/disabled push keeps
                the worktree and local WIP branch. Skipped
                when a live process cwd is inside, the worktree is locked,
                a merge/rebase/cherry-pick is in progress, or an ignored
                secret-ish file (.env, *.pem, *.key, ...) would be lost.
                Dry-run prints WOULD-PRESERVE-WIP only. Manifest:
                \${DISK_MAGICIAN_STATE_DIR:-~/.disk_magician_state}/worktree_hygiene_wip_manifest.txt
  --push-wip   Publish WIP refs by normal push and verify exact remote HEAD
                before removal. Without this flag local WIP is kept in place.
  --max-candidates N
                Cap the number of age-qualifying candidates triaged per
                repo per run (0 = unlimited, default). On a registry with
                many more candidates than N, the oldest N (by mtime) are
                processed and the rest are reported as skipped -- this run
                degrades gracefully instead of hanging on an unexpectedly
                large registry. Re-run to work through the remainder.
  -h, --help    Show this help.

Environment:
  WORKTREE_APPROVED=1      Required for --execute deletions.
  CLAUDE_WORKTREE_REPOS    Comma-separated repo paths (same as --repos).
  WORKTREE_AHEAD_SANITY_CAP
                           Above this raw ahead-count, don't trust it as a
                           real commit count (history-rewrite false
                           positive) -- classify suspect-history-rewrite
                           instead of unpushed-ahead (default: 500).
EOF
}

# ---------------------------------------------------------------------------
# Sourceable functions (safe to `source` this file without running main).
# ---------------------------------------------------------------------------

# identify_candidates <repo_path> <min_age_days>
# Echoes newline-separated worktree paths (excluding the main worktree)
# whose most-recent non-ignored file mtime is older than min_age_days.
identify_candidates() {
    local repo_path="$1" min_age_days="$2"
    local repo_abs main_wt_abs
    repo_abs=$(cd "$repo_path" 2>/dev/null && pwd -P) || return 0
    main_wt_abs="$repo_abs"

    local porcelain
    porcelain="$(git -C "$repo_abs" worktree list --porcelain 2>/dev/null)" || return 0

    local path=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" ]]; then
            path=""
            continue
        fi
        case "$line" in
            worktree\ *)
                path="${line#worktree }"
                if [[ "$path" != "$main_wt_abs" && -d "$path" ]]; then
                    # Recency now comes from scripts/lib/worktree_recency.sh
                    # (sourced at the top of this file), which keeps the
                    # perf work that was done here -- `-prune` on excluded
                    # dirs rather than `-not -path` (the dominant cost,
                    # jleechan-q912), and `-exec stat ... +` batching -- and
                    # fixes two safety defects the local copy had:
                    #
                    #  1. `sort -rn | head -1` under `set -o pipefail`:
                    #     head closing the pipe early raises SIGPIPE in
                    #     sort, so a healthy scan can yield an EMPTY result.
                    #     The helper uses a single-pass awk max instead,
                    #     which consumes all of stdin and never triggers it.
                    #  2. the empty-result fallback used `stat -f '%m'
                    #     "$path"` -- the worktree root's own mtime, which
                    #     only moves when a top-level entry is added or
                    #     removed. Editing files deep in the tree all week
                    #     leaves it untouched, so the fallback for "I could
                    #     not measure this" was the most stale-biased number
                    #     available: the safety check failed OPEN, marking
                    #     active worktrees deletable. The helper fails
                    #     CLOSED (unknown -> age 0 -> preserved).
                    local age_days
                    age_days=$(worktree_age_days "$path")
                    if (( age_days >= min_age_days )); then
                        echo "$path"
                    fi
                fi
                ;;
        esac
    done <<<"$porcelain"
}

# redact_url <url>
# Strips embedded credentials from a git remote URL.
redact_url() {
    local url="$1"
    # https://TOKEN@host/... or https://user:TOKEN@host/... -> https://host/...
    echo "$url" | sed -E 's#^(https?://)[^/@]+@#\1#'
}

# classify_candidate <uncommitted_count> <untracked_present:0|1> <push_status> <pr_state> <ahead_count> <has_merge_base:0|1> <suspect_rewrite:0|1>
# Echoes exactly one line: SAFE|<reason> or NEEDS-REVIEW|<reason>
classify_candidate() {
    local uncommitted_count="$1" untracked_present="$2" push_status="$3" \
          pr_state="$4" ahead_count="$5" has_merge_base="$6" suspect_rewrite="${7:-0}"

    # Fail-safe: an ahead_count above WORKTREE_AHEAD_SANITY_CAP is not a
    # trustworthy commit count (history-rewrite artifact), so it can never
    # produce a SAFE verdict on its own -- not even via a merged PR, since
    # the "merged" match itself could be against rewritten history. This
    # check must run before every other branch below, including the
    # zero-ahead fast path (which ahead_count > cap already precludes).
    if (( suspect_rewrite == 1 )); then
        if [[ "$pr_state" == "merged" ]]; then
            echo "NEEDS-REVIEW|merged-pr-suspect-rewrite"
        else
            echo "NEEDS-REVIEW|suspect-history-rewrite"
        fi
        return 0
    fi

    if (( ahead_count == 0 && uncommitted_count == 0 && untracked_present == 0 )); then
        echo "SAFE|zero-ahead"
        return 0
    fi
    if [[ "$pr_state" == "merged" && "$uncommitted_count" -eq 0 && "$untracked_present" -eq 0 ]]; then
        echo "SAFE|merged-pr-clean"
        return 0
    fi
    if [[ "$pr_state" == "merged-differing-head" ]]; then
        echo "NEEDS-REVIEW|merged-pr-diff-head"
        return 0
    fi
    if [[ "$pr_state" == "open" ]]; then
        echo "NEEDS-REVIEW|open-pr"
        return 0
    fi
    if [[ "$push_status" == "rejected-nonff" ]]; then
        echo "NEEDS-REVIEW|detached-unpushed"
        return 0
    fi
    if (( untracked_present == 1 )); then
        echo "NEEDS-REVIEW|untracked"
        return 0
    fi
    if (( uncommitted_count > 50 )); then
        echo "NEEDS-REVIEW|large-diff"
        return 0
    fi
    if (( has_merge_base == 0 )); then
        echo "NEEDS-REVIEW|no-merge-base"
        return 0
    fi
    if (( ahead_count > 0 )) && [[ "$push_status" == "no-remote" || "$push_status" == "skipped" || "$push_status" == "skipped-detached" ]]; then
        echo "NEEDS-REVIEW|unpushed-ahead"
        return 0
    fi
    echo "NEEDS-REVIEW|dirty"
}

# resolve_main_ref <repo_path>
# Echoes the best available "main" ref (origin/main preferred, else main).
resolve_main_ref() {
    local repo="$1"
    if git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
        echo "origin/main"
        return 0
    fi
    if git -C "$repo" rev-parse --verify --quiet main >/dev/null 2>&1; then
        echo "main"
        return 0
    fi
    return 1
}

# query_pr_state <repo_path> <wt_path> <branch> — echoes the gh PR state for
# branch: open|merged|merged-differing-head|closed|none|unknown.
query_pr_state() {
    local repo_path="$1" wt_path="$2" branch="$3" pr_state
    pr_state="unknown"
    if [[ "${SKIP_GH:-false}" == true ]]; then
        pr_state="unknown"
    else
        local origin_url owner_repo
        origin_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)"
        if [[ -n "$origin_url" ]]; then
            local safe_url
            safe_url="$(redact_url "$origin_url")"
            owner_repo="$(echo "$safe_url" | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##; s#\.git$##')"
            if [[ -n "$owner_repo" ]] && command -v gh >/dev/null 2>&1; then
                local pr_json gh_rc=0
                # env -u: a stale GH_TOKEN/GITHUB_TOKEN override breaks gh
                # even when the stored keychain credential is valid.
                pr_json="$(env -u GH_TOKEN -u GITHUB_TOKEN timeout 10s gh pr list --repo "$owner_repo" --head "$branch" --state all \
                    --json number,state,title,headRefOid 2>/dev/null)" || gh_rc=$?
                if [[ "$gh_rc" -eq 0 && -n "$pr_json" && "$pr_json" != "[]" ]]; then
                    local local_head
                    local_head="$(git -C "$wt_path" rev-parse HEAD 2>/dev/null || true)"
                    if command -v python3 >/dev/null 2>&1; then
                        pr_state="$(python3 -c '
import json, sys
try:
    prs = json.loads(sys.argv[1])
    local_head = sys.argv[2].strip()
    if not isinstance(prs, list) or not local_head:
        print("unknown")
        sys.exit(0)
    has_open = any(isinstance(p, dict) and (p.get("state") or "").upper() == "OPEN" for p in prs)
    merged_prs = [p for p in prs if isinstance(p, dict) and (p.get("state") or "").upper() == "MERGED"]
    if has_open:
        print("open")
    elif merged_prs:
        matching = any(p.get("headRefOid") and p.get("headRefOid") == local_head for p in merged_prs)
        if matching:
            print("merged")
        else:
            print("merged-differing-head")
    elif any(isinstance(p, dict) and (p.get("state") or "").upper() == "CLOSED" for p in prs):
        print("closed")
    else:
        print("none")
except Exception:
    print("unknown")
' "$pr_json" "$local_head" 2>/dev/null || echo "unknown")"
                    else
                        pr_state="unknown"
                    fi
                elif [[ "$gh_rc" -eq 0 && "$pr_json" == "[]" ]]; then
                    pr_state="none"
                else
                    pr_state="unknown"
                fi
            else
                pr_state="unknown"
            fi
        else
            pr_state="unknown"
        fi
    fi
    echo "$pr_state"
}

# triage_candidate <repo_path> <wt_path> <branch>
# Echoes: <uncommitted_count>|<untracked_present>|<push_status>|<pr_state>|<ahead_count>|<has_merge_base>|<suspect_rewrite>
triage_candidate() {
    local repo_path="$1" wt_path="$2" branch="$3"

    local status_porcelain uncommitted_count untracked_present status_rc=0
    status_porcelain="$(git --no-optional-locks -C "$wt_path" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)" || status_rc=$?
    if [[ "$status_rc" -ne 0 ]]; then
        uncommitted_count=999
        untracked_present=1
    elif [[ -z "$status_porcelain" ]]; then
        uncommitted_count=0
        untracked_present=0
    else
        uncommitted_count=$(printf '%s\n' "$status_porcelain" | grep -c . || true)
        untracked_present=0
        if printf '%s\n' "$status_porcelain" | grep -qE '^\?\?'; then
            untracked_present=1
        fi
    fi

    # Compute ahead-count / merge-base BEFORE any network call -- both are
    # cheap local git operations. Per classify_candidate's contract, the
    # SAFE branches require uncommitted==0 AND untracked==0, and
    # SAFE|zero-ahead fires whenever ahead==0 regardless of push/PR state.
    # So push+gh can only ever change the verdict for the single remaining
    # case: locally clean AND ahead>0 (a merged/closed PR could flip that
    # to SAFE). Every other case is a guaranteed NEEDS-REVIEW no matter
    # what push/gh would report, so skip the real network calls entirely
    # (jleechan-q912 -- sequential push+gh across 300+ candidates hangs).
    local ahead_count=0 has_merge_base=1
    local main_ref
    if main_ref="$(resolve_main_ref "$repo_path")"; then
        if git -C "$wt_path" merge-base "$main_ref" HEAD >/dev/null 2>&1; then
            has_merge_base=1
            ahead_count="$(git -C "$wt_path" rev-list --count "${main_ref}..HEAD" 2>/dev/null || echo 0)"
        else
            has_merge_base=0
            ahead_count="$(git -C "$wt_path" rev-list --count HEAD 2>/dev/null || echo 0)"
            (( ahead_count == 0 )) && ahead_count=999
        fi
    else
        has_merge_base=0
        ahead_count="$(git -C "$wt_path" rev-list --count HEAD 2>/dev/null || echo 0)"
        (( ahead_count == 0 )) && ahead_count=999
    fi

    local needs_network=1
    if (( uncommitted_count > 0 || untracked_present == 1 )); then
        needs_network=0
    elif (( ahead_count == 0 )); then
        needs_network=0
    fi

    # A suspect (history-rewrite) ahead_count can never yield SAFE (see
    # classify_candidate), but we still attempt a gh PR-list fallback below
    # so the reason can distinguish merged-pr-suspect-rewrite from a plain
    # suspect-history-rewrite. Skip the push step for suspect candidates --
    # pushing a branch whose local history was rewritten against a huge
    # bogus ahead-count is unnecessary risk for a verdict that is NEEDS-
    # REVIEW either way.
    local suspect_rewrite=0
    if (( ahead_count > WORKTREE_AHEAD_SANITY_CAP )); then
        suspect_rewrite=1
    fi

    local push_status pr_state
    if (( needs_network == 0 )); then
        push_status="skipped-not-needed"
        pr_state="unknown"
    else
        push_status="no-remote"
        if (( suspect_rewrite == 1 )); then
            push_status="skipped-suspect-rewrite"
        elif ! git -C "$wt_path" symbolic-ref -q HEAD >/dev/null 2>&1; then
            # A detached HEAD has no branch to push; pushing HEAD:detached
            # would mint a bogus remote branch (then backup/detached-<date>).
            push_status="skipped-detached"
        elif [[ "${SKIP_PUSH:-false}" == true || "${EXECUTE:-false}" != true \
            || ( "${PRESERVE_WIP:-false}" == true && "${PUSH_WIP:-false}" != true ) ]]; then
            push_status="skipped"
        else
            if git -C "$wt_path" remote get-url origin >/dev/null 2>&1; then
                if publish_wip_ref "$wt_path" "$branch" >/dev/null; then
                    push_status="pushed"
                else
                    push_status="rejected-nonff"
                fi
            else
                push_status="no-remote"
            fi
        fi

        pr_state="$(query_pr_state "$repo_path" "$wt_path" "$branch")"
    fi

    echo "${uncommitted_count}|${untracked_present}|${push_status}|${pr_state}|${ahead_count}|${has_merge_base}|${suspect_rewrite}"
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

# worktree_has_live_tmux_pane <wt_path> — true if any live tmux pane's cwd
# is inside wt_path (equal to it, or a descendant path). Hard safety gate
# requested for jleechan-dqiz: never touch a worktree a human/agent tmux
# session (e.g. an "orch-*" AO session, but checked generally -- any live
# pane, not just that one naming convention) is actively sitting in, even
# if it otherwise looks old/clean/pushed. Fails open (no match) if tmux
# isn't installed or no server is running -- nothing to protect against.
worktree_has_live_tmux_pane() {
    local wt_path="$1"
    command -v tmux >/dev/null 2>&1 || return 1
    local pane_cwd
    while IFS= read -r pane_cwd; do
        [[ -n "$pane_cwd" ]] || continue
        [[ "$pane_cwd" == "$wt_path" || "$pane_cwd" == "$wt_path"/* ]] && return 0
    done < <(tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null || true)
    return 1
}

ledger_line() {
    local action="$1" path="$2" reason="${3:-}"
    if [[ -n "$reason" ]]; then
        printf '  LEDGER %-17s %-14s %s | %s\n' "worktree-hygiene" "$action" "$path" "$reason"
    else
        printf '  LEDGER %-17s %-14s %s\n' "worktree-hygiene" "$action" "$path"
    fi
}

branch_for_worktree() {
    local repo_path="$1" wt_path="$2"
    # `|| true`: awk's own `exit` after a match closes its end of the pipe
    # while `git worktree list --porcelain` may still be writing output for
    # later worktrees (this function is called once per candidate against a
    # registry that can have 300+ entries) -- git then receives SIGPIPE, and
    # under this script's `set -o pipefail` the pipeline exits 141, tripping
    # `set -e` and aborting the whole run partway through, non-deterministically
    # (crash point depends on which worktree's awk match races git's buffering).
    # awk has already printed the matched branch name before git is signaled,
    # so the guard only suppresses the spurious failure status, not real output.
    git -C "$repo_path" worktree list --porcelain 2>/dev/null | awk -v p="$wt_path" '
        $1 == "worktree" { cur = $2 }
        cur == p && $1 == "branch" { sub(/^refs\/heads\//, "", $2); print $2; exit }
        cur == p && $1 == "detached" { print "detached"; exit }
    ' || true
}

# ---------------------------------------------------------------------------
# --preserve-wip: lossless local-branch preservation, then non-forced remove
# ---------------------------------------------------------------------------

# preserve_wip_reason_eligible <reason> — only these NEEDS-REVIEW reasons are
# fully captured by a local commit. open-pr, large-diff, suspect rewrites etc.
# stay with a human.
preserve_wip_reason_eligible() {
    case "$1" in
        dirty|untracked|detached-unpushed|unpushed-ahead) return 0 ;;
    esac
    return 1
}

# worktree_has_live_cwd <wt_path> — true if any process's cwd is inside it.
# Fails closed: no lsof, an incomplete scan, or a live process whose cwd cannot
# be inspected all count as "live" so the caller never removes an occupied tree.
worktree_has_live_cwd() {
    local wt="$1" wt_real cwd out err errf rc=0
    command -v lsof >/dev/null 2>&1 || return 0
    wt_real="$(cd "$wt" 2>/dev/null && pwd -P)" || return 0
    errf="$(mktemp "${TMPDIR:-/tmp}/dm-hyg-lsof.XXXXXX")" || return 0
    out="$(lsof -n -P -d cwd -Fn 2>"$errf")" || rc=$?
    err="$(cat "$errf" 2>/dev/null || true)"
    rm -f "$errf"
    # Unexpected stderr means the scan may have missed a user. (The Linux mount
    # warnings are expected and cleared by lsof_stderr_incomplete.)
    if declare -F lsof_stderr_incomplete >/dev/null 2>&1; then
        lsof_stderr_incomplete "$err" && return 0
    elif [[ -n "$err" ]]; then
        return 0
    fi
    (( rc <= 1 )) || return 0   # 0 = matches, 1 = none; anything else is unexpected
    while IFS= read -r cwd; do
        cwd="${cwd#n}"
        # An uninspectable pid could hold any cwd, including this worktree.
        if [[ "$cwd" =~ ^/proc/[0-9]+/cwd\ \(readlink:\ Permission\ denied\)$ ]]; then
            if declare -F lsof_denied_ignorable >/dev/null 2>&1; then
                lsof_denied_ignorable "$cwd" || return 0
            else
                return 0
            fi
            continue
        fi
        [[ "$cwd" == "$wt" || "$cwd" == "$wt"/* || "$cwd" == "$wt_real" || "$cwd" == "$wt_real"/* ]] && return 0
    done <<<"$out"
    return 1
}

# preserve_wip_blocker <repo_abs> <wt_path> — echoes a skip reason and
# returns 0 when the worktree must NOT be auto-preserved; returns 1 if clear.
preserve_wip_blocker() {
    local repo_abs="$1" wt="$2" gitdir f
    local -x GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
             GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false
    gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { echo "no-gitdir"; return 0; }
    if [[ -e "$gitdir/locked" ]]; then
        echo "locked"; return 0
    fi
    for f in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
        if [[ -e "$gitdir/$f" ]]; then
            echo "in-progress-op:$f"; return 0
        fi
    done
    if [[ -n "$(git -C "$wt" ls-files --unmerged 2>/dev/null)" ]]; then
        echo "in-progress-op:unmerged-paths"; return 0
    fi
    git -C "$wt" rev-parse --verify -q HEAD >/dev/null 2>&1 || { echo "unborn-head"; return 0; }
    if worktree_has_live_tmux_pane "$wt" || worktree_has_live_cwd "$wt"; then
        echo "live-cwd"; return 0
    fi
    # Edits to skip-worktree (S) or assume-unchanged (lowercase tag) entries
    # are invisible to both `git add -A` and `git status`, so they would be
    # lost on removal: refuse. Fail closed if the listing fails.
    local flagged frc=0
    flagged="$(git -C "$wt" ls-files -v 2>/dev/null | awk '!f && /^(S|[a-z]) /{print substr($0,3); f=1}')" || frc=$?
    if [[ "$frc" -ne 0 ]]; then
        echo "index-flag-scan-failed"; return 0
    fi
    if [[ -n "$flagged" ]]; then
        echo "index-flagged:$flagged"; return 0
    fi
    # A path staged and then edited again (MM/AM/...) holds index content that
    # matches neither HEAD nor disk; `git add -A` (and the failure-path index
    # reset) would drop that staged version: refuse. Fail closed on error.
    local partial prc=0
    partial="$(git --no-optional-locks -C "$wt" status --porcelain --untracked-files=no --ignore-submodules=none 2>/dev/null \
        | awk '!f && substr($0,1,2)!="??" && substr($0,1,1)!=" " && substr($0,2,1)!=" "{print substr($0,4); f=1}')" || prc=$?
    if [[ "$prc" -ne 0 ]]; then
        echo "partial-staging-scan-failed"; return 0
    fi
    if [[ -n "$partial" ]]; then
        echo "partially-staged:$partial"; return 0
    fi
    # On a case-insensitive filesystem a case-only rename is invisible to
    # `git add -A` (core.ignorecase) and to the byte check, so the new name
    # would be lost: refuse when a case-sensitive scan sees different
    # untracked names than the configured one.
    local ci_others cs_others
    ci_others="$(git -C "$wt" ls-files -z --others --exclude-standard 2>/dev/null | tr '\0' '\n')" || { echo "case-scan-failed"; return 0; }
    cs_others="$(git -C "$wt" -c core.ignorecase=false ls-files -z --others --exclude-standard 2>/dev/null | tr '\0' '\n')" || { echo "case-scan-failed"; return 0; }
    if [[ "$ci_others" != "$cs_others" ]]; then
        echo "case-only-rename"; return 0
    fi
    # Ignored files are not captured by `git add -A`; refuse to silently
    # drop anything that looks like a credential. Nested git repos (ignored
    # or not) are listed as `dir/` and never descended into, so their
    # contents and local commits would be lost: refuse those too. Fail
    # closed if the listing itself fails.
    local listing rc=0 name base
    listing="$(git -C "$wt" ls-files -z --others 2>/dev/null | tr '\0' '\n')" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "ignored-scan-failed"; return 0
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ "$name" == */ ]]; then
            echo "nested-repo:$name"; return 0
        fi
        # Only ignored, known-rebuildable outputs bypass credential-name matching.
        if git -C "$wt" check-ignore -q -- "$name" \
            && ignored_entry_rebuildable "$wt" "$name"; then
            continue
        fi
        base="${name##*/}"
        # Compiled bytecode (e.g. __pycache__/clock_skew_credentials.*.pyc) is
        # regenerated from its source; its name is not a credential.
        case "$name" in __pycache__/*.py[co]|*/__pycache__/*.py[co]) continue ;; esac
        case "$base" in
            .env|.env.*|.envrc|*.pem|*.key|*.keystore|id_rsa*|id_ed25519*|*credentials*|secrets*|service-account*.json|.netrc|*.p12)
                echo "ignored-secret:$name"; return 0 ;;
        esac
    done <<<"$listing"
    # Fail closed on ignored content: `git add -A` never captures ignored
    # files, so any ignored path that is not a known rebuildable output would
    # be lost on removal. Allowlist only regenerable dirs/files.
    local ign irc=0 ipath ibase
    ign="$(git -C "$wt" ls-files -z --others --ignored --exclude-standard --directory 2>/dev/null | tr '\0' '\n')" || irc=$?
    if [[ "$irc" -ne 0 ]]; then
        echo "ignored-scan-failed"; return 0
    fi
    local icomp igen
    while IFS= read -r ipath; do
        [[ -n "$ipath" ]] || continue
        # Tool-owned state that only points back at the main checkout or is
        # regenerated on demand (husky hook shims, beads worktree redirect and
        # write locks).
        case "$ipath" in
            .husky/_/*|*/.husky/_/*|.beads/redirect) continue ;;
            .beads/.br-db-write-*.lock) [[ "${ipath#.beads/}" == */* ]] || continue ;;
        esac
        # Caches that write their own `*` .gitignore (ruff, pytest, mypy) are
        # listed file by file; accept paths under them. Other allowlisted
        # names only count when git lists the whole directory as ignored.
        igen=false
        IFS='/' read -ra icomp <<<"${ipath%/}"
        for ibase in "${icomp[@]}"; do
            case "$ibase" in .ruff_cache|.pytest_cache|.mypy_cache) igen=true; break ;; esac
        done
        "$igen" && continue
        ibase="${ipath%/}"; ibase="${ibase##*/}"
        case "$ibase" in
            .nox|.parcel-cache|*.pyo) ;;
            *) ignored_entry_rebuildable "$wt" "$ipath" leaf || {
                case "/$ipath" in
                    */evidence/*|*/docs/evidence/*) echo "ignored-evidence:$ipath" ;;
                    *) echo "ignored-file:$ipath" ;;
                esac
                return 0
            } ;;
        esac
    done <<<"$ign"
    return 1
}

# wip_branch_name <wt_path> — first free wip/worktree-hygiene/<date>/<name>[-N].
wip_branch_name() {
    local wt="$1" base candidate n=2
    base="$(basename "$wt" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^[.-]+//; s/\.lock$//; s/[.]+$//')"
    [[ -n "$base" ]] || base="worktree"
    base="wip/worktree-hygiene/$(date +%Y%m%d)/$base"
    git check-ref-format --branch "$base" >/dev/null 2>&1 || base="wip/worktree-hygiene/$(date +%Y%m%d)/worktree"
    candidate="$base"
    while git -C "$wt" show-ref --verify --quiet "refs/heads/$candidate"; do
        candidate="${base}-${n}"
        n=$(( n + 1 ))
    done
    echo "$candidate"
}

# wip_restore_head <wt> <branch> <orig_ref> <orig_sha> [keep] — after a failed
# preservation, point HEAD back at the original branch (or detached SHA) and
# reset only the index; the working tree is never touched. The wip branch is
# dropped (the worktree still holds all content) unless `keep` is passed.
wip_restore_head() {
    local wt="$1" branch="$2" orig_ref="$3" orig_sha="$4" keep="${5:-}" wip_sha
    if [[ -n "$orig_ref" ]] && git -C "$wt" show-ref --verify --quiet "$orig_ref" 2>/dev/null; then
        git -C "$wt" symbolic-ref HEAD "$orig_ref" 2>/dev/null
    else
        git -C "$wt" update-ref --no-deref HEAD "$orig_sha" 2>/dev/null
    fi || { ledger_line "WIP-FAILED" "$wt" "could not restore HEAD; left on $branch"; return 1; }
    git -C "$wt" reset -q 2>/dev/null || ledger_line "WIP-FAILED" "$wt" "index reset failed after HEAD restore"
    if [[ "$keep" == keep ]]; then
        ledger_line "WIP-RESTORED" "$wt" "HEAD back on ${orig_ref:-$orig_sha}; staging reset; wip branch $branch kept"
        return 0
    fi
    # HEAD is back and the worktree still holds all content, so the (possibly
    # partial) wip branch is redundant: drop it rather than leave a stale ref.
    wip_sha="$(git -C "$wt" rev-parse --verify -q "refs/heads/$branch" 2>/dev/null || true)"
    [[ -n "$wip_sha" ]] && { git -C "$wt" branch -q -D "$branch" 2>/dev/null || true; }
    ledger_line "WIP-RESTORED" "$wt" "HEAD back on ${orig_ref:-$orig_sha}; staging reset; wip branch dropped"
}

# worktree_bytes_mismatch <wt> — clean/eol filters can make on-disk bytes
# differ from what git stores while `git status` (which reads through the same
# filters) reports clean -- for new files and for edits to tracked files alike.
# Byte-verify EVERY tracked regular file on disk against its index and HEAD
# blobs (one batched pass); committed symlinks/gitlinks and paths under a
# genuine git-lfs filter are exempt (they round-trip). Echoes the first
# mismatching path or a failure reason; echoes nothing when every byte matches.
worktree_bytes_mismatch() {
    local wt="$1" vlist vlfs="" lfs_clean lfs_proc
    local -x GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
             GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false
    vlist="$(git -C "$wt" ls-files -s -z 2>/dev/null | tr '\0' '\n' \
        | awk '$1=="100644"||$1=="100755"{idx=$2; sub(/^[^\t]*\t/,""); print idx "\t" $0}')" || { echo "ls-files-failed"; return 0; }
    [[ -n "$vlist" ]] || return 0
    # Only a real git-lfs driver earns the exemption; any other command
    # registered under the name "lfs" is byte-verified like every filter.
    lfs_clean="$(git -C "$wt" config --get filter.lfs.clean 2>/dev/null || true)"
    lfs_proc="$(git -C "$wt" config --get filter.lfs.process 2>/dev/null || true)"
    if [[ ( "$lfs_clean" == git-lfs || "$lfs_clean" == "git-lfs "* ) \
          && ( -z "$lfs_proc" || "$lfs_proc" == git-lfs || "$lfs_proc" == "git-lfs "* ) ]]; then
        vlfs="$(printf '%s\n' "$vlist" | cut -f2- | git -C "$wt" check-attr --stdin filter 2>/dev/null \
            | awk -F': filter: ' '$2=="lfs"{print $1}')"
    fi
    # Drop LFS paths in one pass (a per-file lookup is O(n) processes).
    if [[ -n "$vlfs" ]]; then
        vlist="$(printf '%s\n' "$vlist" | awk -F'\t' -v lfs="$vlfs" \
            'BEGIN{n=split(lfs,a,"\n"); for(i=1;i<=n;i++) skip[a[i]]=1} !($2 in skip)')"
        [[ -n "$vlist" ]] || return 0
    fi
    printf '%s\n' "$vlist" | while IFS=$'\t' read -r vidx vp; do
            [[ -L "$wt/$vp" ]] && { echo "symlink:$vp"; continue; }
            [[ -f "$wt/$vp" ]] || { echo "missing:$vp"; continue; }
            printf '%s\t%s\n' "$vidx" "$vp"
        done | {
            entries="$(cat)"
            [[ -n "$entries" ]] || exit 0
            if grep -qE '^(missing|symlink):' <<<"$entries"; then grep -m1 -E '^(missing|symlink):' <<<"$entries"; exit 0; fi
            idx_blobs="$(printf '%s\n' "$entries" | cut -f1)"
            paths="$(printf '%s\n' "$entries" | cut -f2-)"
            disk="$(printf '%s\n' "$paths" | git -C "$wt" hash-object --no-filters --stdin-paths 2>/dev/null)" || { echo "hash-failed"; exit 0; }
            blobs="$(printf '%s\n' "$paths" | sed 's/^/HEAD:/' | git -C "$wt" cat-file --batch-check='%(objectname)' 2>/dev/null)" || { echo "blob-lookup-failed"; exit 0; }
            paste -d'\t' <(printf '%s\n' "$paths") <(printf '%s\n' "$disk") <(printf '%s\n' "$idx_blobs") <(printf '%s\n' "$blobs") \
                | awk -F'\t' '!f && ($2!=$3 || $2!=$4){print $1; f=1}'
        }
}

preserve_wip_raw_bytes_dirty() {
    worktree_bytes_mismatch "$@"
}

# A normal push runs the repository's configured hooks. Backup fallback is
# permitted only for Git's explicit non-fast-forward/fetch-first rejection.
publish_wip_ref() {
    local wt="$1" ref="$2" sha remote_sha err backup
    local -x GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false
    sha="$(git -C "$wt" rev-parse "${3:-HEAD}")" || return 1
    # Publication is opt-in, but credential safety still fails closed. Scan
    # reachable history because an older unpushed commit can contain secrets.
    command -v gitleaks >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 || return 1
    timeout 90 gitleaks git "$wt" --log-opts="$sha" --redact --no-banner >/dev/null 2>&1 || return 1
    err="$(mktemp)" || return 1
    if ! timeout 90 git -C "$wt" push origin "$sha:refs/heads/$ref" >"$err" 2>&1; then
        if ! grep -Eq '\[rejected\].*\((non-fast-forward|fetch first)\)' "$err"; then
            rm -f "$err"
            return 1
        fi
        backup="backup/$ref-$(date +%Y%m%d)"
        if ! timeout 90 git -C "$wt" push origin "$sha:refs/heads/$backup" >"$err" 2>&1; then
            rm -f "$err"
            return 1
        fi
        ref="$backup"
    fi
    rm -f "$err"
    remote_sha="$(timeout 90 git -C "$wt" ls-remote --exit-code origin "refs/heads/$ref" | awk '{print $1}')" || return 1
    [[ "$remote_sha" == "$sha" ]] || return 1
    PUBLISHED_WIP_REF="$ref"
    pushed_count=$(( ${pushed_count:-0} + 1 ))
    ledger_line "VERIFIED-WIP" "$wt" "$ref $sha"
}

# Normal publication hooks can change local state; all removal preconditions
# must still hold for the exact preserved commit after those hooks have run.
wip_post_publication_blocker() {
    local repo_abs="$1" wt="$2" branch="$3" sha="$4" orig_sha="${5:-}" value blocker
    value="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)" || { echo "head-unreadable"; return 0; }
    [[ "$value" == "$sha" ]] || { echo "head-changed"; return 0; }
    if [[ -n "$orig_sha" ]] && ! git -C "$wt" merge-base --is-ancestor "$orig_sha" "$sha" 2>/dev/null; then
        echo "orig-sha-not-ancestor"; return 0
    fi
    value="$(git -C "$wt" symbolic-ref -q HEAD 2>/dev/null)" || { echo "head-detached"; return 0; }
    [[ "$value" == "refs/heads/$branch" ]] || { echo "branch-changed"; return 0; }
    value="$(git -C "$wt" rev-parse --verify "refs/heads/$branch" 2>/dev/null)" || { echo "ref-unreadable"; return 0; }
    [[ "$value" == "$sha" ]] || { echo "ref-changed"; return 0; }
    if blocker="$(preserve_wip_blocker "$repo_abs" "$wt")"; then
        echo "$blocker"; return 0
    fi
    value="$(git --no-optional-locks -C "$wt" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)" || { echo "status-unreadable"; return 0; }
    [[ -z "$value" ]] || { echo "working-state-changed"; return 0; }
    value="$(worktree_bytes_mismatch "$wt")" || { echo "byte-check-failed"; return 0; }
    [[ -z "$value" ]] || { echo "preserved-bytes-changed:$value"; return 0; }
    if worktree_is_recently_active "$wt" "$MIN_AGE_DAYS"; then
        echo "recently-active"; return 0
    fi
    return 1
}

# preserve_wip_and_remove <repo_abs> <wt_path> [pre_wip_sha] — commit all
# non-ignored WIP to a new local branch; optional verified publication precedes
# non-forced removal. Returns 0 if removed, 1 if preserved-but-kept or failed.
preserve_wip_and_remove() {
    local repo_abs="$1" wt="$2" pre_wip_sha="${3:-}" branch name email sha orig_ref orig_sha
    # Never run the repo's hooks (post-checkout, post-commit, post-index-change,
    # reference-transaction, ...) from an automated sweep: every git call here
    # and in wip_restore_head inherits core.hooksPath=/dev/null via the env.
    # core.fsmonitor=false likewise keeps a repo-configured monitor command
    # from running.
    local -x GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
             GIT_CONFIG_KEY_1=core.fsmonitor GIT_CONFIG_VALUE_1=false
    branch="$(wip_branch_name "$wt")"
    orig_ref="$(git -C "$wt" symbolic-ref -q HEAD 2>/dev/null || true)"
    orig_sha="$(git -C "$wt" rev-parse --verify -q HEAD 2>/dev/null || true)"
    if [[ -n "$pre_wip_sha" ]]; then
        if [[ -n "$orig_sha" && "$orig_sha" != "$pre_wip_sha" ]]; then
            ledger_line "WIP-FAILED" "$wt" "HEAD changed before preservation ($pre_wip_sha -> $orig_sha); kept"
            return 1
        fi
        orig_sha="$pre_wip_sha"
    fi
    [[ -n "$orig_sha" ]] || {
        ledger_line "WIP-FAILED" "$wt" "cannot resolve HEAD; kept"; return 1; }
    name="$(git -C "$wt" config user.name 2>/dev/null || true)"
    email="$(git -C "$wt" config user.email 2>/dev/null || true)"
    [[ -n "$name" ]] || name="worktree-hygiene"
    [[ -n "$email" ]] || email="worktree-hygiene@localhost"

    if ! git -C "$wt" checkout -q -b "$branch" "$orig_sha" 2>/dev/null; then
        ledger_line "WIP-FAILED" "$wt" "could not create $branch; kept"
        return 1
    fi
    if ! git -C "$wt" add -A 2>/dev/null; then
        ledger_line "WIP-FAILED" "$wt" "git add -A failed on $branch; kept"
        wip_restore_head "$wt" "$branch" "$orig_ref" "$orig_sha"
        return 1
    fi
    if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
        if ! GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
             GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
             git -C "$wt" -c commit.gpgsign=false commit -q --no-verify \
                 -m "wip: preserved by worktree-hygiene before removal ($wt)" >/dev/null 2>&1; then
            ledger_line "WIP-FAILED" "$wt" "commit failed on $branch; kept"
            wip_restore_head "$wt" "$branch" "$orig_ref" "$orig_sha"
            return 1
        fi
    fi
    local vbad
    vbad="$(worktree_bytes_mismatch "$wt")"
    if [[ -n "$vbad" ]]; then
        ledger_line "WIP-FAILED" "$wt" "committed bytes differ from disk for $vbad (filter/eol); kept"
        wip_restore_head "$wt" "$branch" "$orig_ref" "$orig_sha"
        return 1
    fi
    if [[ -n "$(git -C "$wt" status --porcelain --untracked-files=all --ignore-submodules=none 2>/dev/null)" ]] \
       || ! sha="$(git -C "$wt" rev-parse --verify -q "refs/heads/$branch")" \
       || ! git -C "$wt" merge-base --is-ancestor "$orig_sha" "$sha" 2>/dev/null; then
        ledger_line "WIP-FAILED" "$wt" "tree not clean after commit on $branch; kept"
        wip_restore_head "$wt" "$branch" "$orig_ref" "$orig_sha"
        return 1
    fi

    local_wip_count=$(( ${local_wip_count:-0} + 1 ))
    ledger_line "PRESERVED-WIP" "$wt -> $branch $sha"
    local state_dir="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}"
    mkdir -p "$state_dir" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\tlocal\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wt" "$branch" "$sha" \
        >>"$state_dir/worktree_hygiene_wip_manifest.txt" \
        || echo "WARN: could not append wip manifest in $state_dir"

    if [[ "$SKIP_PUSH" == true || "$PUSH_WIP" != true ]]; then
        ledger_line "WIP-KEPT" "$wt" "$branch $sha; push disabled; worktree retained"
        return 1
    fi
    if ! publish_wip_ref "$wt" "$branch" "$sha"; then
        ledger_line "WIP-KEPT" "$wt" "$branch $sha; remote backup unverified; worktree retained"
        return 1
    fi

    printf '%s\t%s\t%s\t%s\tremote-verified:%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wt" "$branch" "$sha" "$PUBLISHED_WIP_REF" >>"$state_dir/worktree_hygiene_wip_manifest.txt" || return 1

    local post_blocker
    if post_blocker="$(wip_post_publication_blocker "$repo_abs" "$wt" "$branch" "$sha" "$orig_sha")"; then
        ledger_line "WIP-KEPT" "$wt" "$branch $sha; post-publication revalidation: $post_blocker; retained"
        return 1
    fi

    if git -C "$repo_abs" worktree remove "$wt" 2>/dev/null; then
        ledger_line "DELETE" "$wt" "preserved on $branch"
        return 0
    fi
    # Removal refused (e.g. the worktree holds a submodule): put HEAD and the
    # index back so the user is not left on the wip branch; the wip branch
    # keeps the committed copy.
    ledger_line "REMOVE-REFUSED" "$wt" "git worktree remove refused; kept (branch $branch remains)"
    wip_restore_head "$wt" "$branch" "$orig_ref" "$orig_sha" keep
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

hygiene_finish() {
    local rc="$1" state="${DISK_MAGICIAN_STATE_DIR:-$HOME/.disk_magician_state}" persist_rc=0
    [[ "$HYGIENE_STATUS" != running ]] || HYGIENE_STATUS=failed
    [[ ${#REPOS[@]} -eq 0 ]] || HYGIENE_ALL_REPOS="$(printf '%s\n' "${REPOS[@]}")"
    echo "Worktree-hygiene status: $HYGIENE_STATUS; partial=$([[ $HYGIENE_STATUS == completed ]] && echo false || echo true); removed=$removed_count failed=$failed_count; checkpoint=$state/worktree_hygiene_summary.json"
    echo "Worktree-hygiene counters: safe=$safe_count needs-review=$review_count preserved=$preserved_count wip-actions=$wip_count removed=$removed_count failed=$failed_count pushed=$pushed_count local-wip=$local_wip_count"
    echo "Worktree-hygiene resume: phase=${HYGIENE_PHASE:-unknown} unfinished-repo=${HYGIENE_REPO:-none} candidate=${HYGIENE_CURRENT:-none}"
    printf 'Known repositories:\n%s\nScanned repositories:\n%s\n' "${HYGIENE_ALL_REPOS:-none}" "${HYGIENE_SCANNED_REPOS:-none}"
    if [[ "${HYGIENE_PHASE:-unknown}" == discovery ]]; then
        echo "Discovery incomplete: repository inventory is partial; unknown repositories have not been claimed scanned."
    fi
    python3 - "$state" "$HYGIENE_STATUS" "$rc" "$safe_count" "$review_count" \
        "$preserved_count" "$wip_count" "$removed_count" "$failed_count" "$HYGIENE_CURRENT" "$HYGIENE_COMPLETED" "$HYGIENE_ALL_REPOS" "$HYGIENE_SCANNED_REPOS" "$HYGIENE_REPO" "$pushed_count" "$EXECUTE" "$local_wip_count" "${HYGIENE_PHASE:-unknown}" <<'PYTHON' || persist_rc=$?
import datetime, json, os, pathlib, sys, tempfile
state = pathlib.Path(sys.argv[1]); state.mkdir(parents=True, exist_ok=True)
keys = ["safe", "needs_review", "preserved", "wip_removed", "removed", "failed"]
data = {"status": sys.argv[2], "exit_status": int(sys.argv[3]),
        "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "counters": dict(zip(keys, map(int, sys.argv[4:10]))),
        "current_candidate": sys.argv[10] or None,
        "completed_candidates": sys.argv[11].splitlines(),
        "partial": sys.argv[2] != "completed",
        "discovered_repos": [os.path.realpath(p) for p in sys.argv[12].splitlines()],
        "scanned_repos": sys.argv[13].splitlines(),
        "unfinished_repo": sys.argv[14] or None,
        "skipped_repos": sorted({os.path.realpath(p) for p in sys.argv[12].splitlines()} - set(sys.argv[13].splitlines())),
        "pushed_refs_count": int(sys.argv[15]),
        "mode": "execute" if sys.argv[16] == "true" else "dry_run",
        "locally_preserved_wip_count": int(sys.argv[17]),
        "phase": sys.argv[18],
        "discovery_complete": sys.argv[18] in ("scan", "completed"),
        "resume": "Re-run the same command; all safety and publication gates are rechecked."}
if sys.argv[16] != "true":
    data["counters"]["would_preserve_wip"] = data["counters"]["wip_removed"]
    data["counters"]["wip_removed"] = 0
fd, name = tempfile.mkstemp(dir=state, prefix=".hygiene-summary-")
with os.fdopen(fd, "w") as stream:
    json.dump(data, stream, indent=2)
os.replace(name, state / "worktree_hygiene_summary.json")
PYTHON
    if [[ "$persist_rc" -ne 0 ]]; then
        echo "WARN: failed to persist resume state in $state (exit $persist_rc); human partial summary remains available" >&2
    fi
    [[ "$rc" -eq 0 ]] || return "$rc"
    return "$persist_rc"
}

main() {
    safe_count=0 review_count=0 preserved_count=0 wip_count=0 removed_count=0 failed_count=0 pushed_count=0 local_wip_count=0
    HYGIENE_ALL_REPOS="" HYGIENE_SCANNED_REPOS="" HYGIENE_REPO=""
    HYGIENE_STATUS=running HYGIENE_CURRENT="" HYGIENE_COMPLETED=""
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            --execute) EXECUTE=true ;;
            --min-age|--days)
                [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
                MIN_AGE_DAYS="$2"
                shift
                ;;
            --repos)
                [[ $# -ge 2 ]] || { echo "--repos requires a value" >&2; exit 2; }
                IFS=',' read -ra REPOS <<<"$2"
                shift
                ;;
            --skip-push|--no-push) SKIP_PUSH=true ;;
            --skip-gh) SKIP_GH=true ;;
            --preserve-wip) PRESERVE_WIP=true ;;
            --push-wip) PUSH_WIP=true ;;
            --max-candidates)
                [[ $# -ge 2 ]] || { echo "--max-candidates requires a value" >&2; exit 2; }
                MAX_CANDIDATES="$2"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
        shift
    done

    if [[ "$EXECUTE" == true && "${WORKTREE_APPROVED:-0}" != 1 ]]; then
        echo "Refusing to delete worktrees: set WORKTREE_APPROVED=1 after explicit approval."
        exit 0
    fi
    trap 'HYGIENE_STATUS=interrupted; exit 130' INT
    trap 'HYGIENE_STATUS=interrupted; exit 143' TERM
    trap 'hygiene_finish "$?"' EXIT
    HYGIENE_PHASE=configuration
    # Staleness floor: read from safety.local.json (safety_min_stale_days), with a
    # hardcoded baseline floor of 7 days. CLAUDE.md invariant: the configured floor
    # may only RAISE the floor, never lower it below 7.
    local staleness_floor
    staleness_floor=$(safety_min_stale_days 2>/dev/null || echo 7)
    if [[ "$staleness_floor" =~ ^[0-9]+$ ]]; then
        staleness_floor=$((10#$staleness_floor))
    else
        staleness_floor=7
    fi
    [[ "$staleness_floor" -lt 7 ]] && staleness_floor=7

    # Hard floor: staleness_floor days, may only be raised (env, CLI, or config), never
    # lowered (CLAUDE.md invariant). Without this clamp, --min-age 0 would
    # let every dormant worktree qualify for deletion regardless of age.
    # Normalize via 10# BEFORE clamping: bash's `-lt`/`(( ))` parse a
    # leading-zero numeral like "08" as octal (invalid digit -> arithmetic
    # error), which would otherwise propagate as a fail-open crash into
    # every downstream comparison, not just this clamp (found live by both
    # /advice reviewers).
    if [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]]; then
        MIN_AGE_DAYS=$((10#$MIN_AGE_DAYS))
    else
        MIN_AGE_DAYS="$staleness_floor"
    fi
    [[ "$MIN_AGE_DAYS" -lt "$staleness_floor" ]] && MIN_AGE_DAYS="$staleness_floor"

    if [[ ${#REPOS[@]} -eq 0 ]]; then
        HYGIENE_PHASE=discovery
        while IFS= read -r repo; do
            [[ -n "$repo" ]] && REPOS+=("$repo")
        done < <(discover_worktree_repos "${CLAUDE_WORKTREE_REPOS:-}")
    fi

    if [[ "$EXECUTE" == true ]]; then
        echo "=== WORKTREE HYGIENE ==="
    else
        echo "=== WORKTREE HYGIENE (DRY-RUN) ==="
    fi


    [[ ${#REPOS[@]} -eq 0 ]] || HYGIENE_ALL_REPOS="$(printf '%s\n' "${REPOS[@]}")"
    HYGIENE_PHASE=scan
    for repo in "${REPOS[@]}"; do
        [[ -d "$repo" ]] || continue
        local repo_abs
        repo_abs=$(cd "$repo" 2>/dev/null && pwd -P) || continue

        echo ""
        HYGIENE_REPO="$repo_abs"
        echo "--- ${repo_abs} ---"

        local all_candidates candidates capped=false
        all_candidates="$(identify_candidates "$repo_abs" "$MIN_AGE_DAYS" || true)"
        candidates="$all_candidates"

        if [[ "$MAX_CANDIDATES" -gt 0 ]]; then
            local candidate_count
            candidate_count=$(printf '%s\n' "$all_candidates" | grep -c . || true)
            if (( candidate_count > MAX_CANDIDATES )); then
                local skipped=$(( candidate_count - MAX_CANDIDATES ))
                echo "  NOTE: ${candidate_count} candidates found, capping to" \
                     "${MAX_CANDIDATES} (--max-candidates); ${skipped} will be" \
                     "left for a subsequent run instead of hanging this one."
                candidates="$(printf '%s\n' "$all_candidates" | head -n "$MAX_CANDIDATES")"
                capped=true
            fi
        fi

        local porcelain all_paths=()
        porcelain="$(git -C "$repo_abs" worktree list --porcelain 2>/dev/null || true)"
        while IFS= read -r line; do
            case "$line" in
                worktree\ *) all_paths+=("${line#worktree }") ;;
            esac
        done <<<"$porcelain"

        # Bash 3.2 (macOS system /bin/bash, still first-in-PATH in some
        # invocation contexts) treats `"${arr[@]}"` on a zero-element array
        # as an unbound variable under `set -u` and aborts the whole script
        # -- unlike bash 4+/5 where it correctly expands to nothing. Found
        # live 2026-07-22 (jleechan-dqiz): a discovered repo path
        # (~/.openclaw, itself a stale/dead worktree-registry entry with no
        # .git of its own) produced empty porcelain/all_paths and crashed
        # the entire multi-repo pass here. Guarding the loop entry sidesteps
        # the bash-3.2 trap without changing behavior for the normal case.
        [[ ${#all_paths[@]} -eq 0 ]] && continue

        for wt_path in "${all_paths[@]}"; do
            [[ "$wt_path" == "$repo_abs" ]] && continue
            [[ -d "$wt_path" ]] || continue

            if ! grep -qxF "$wt_path" <<<"$candidates"; then
                if [[ "$capped" == true ]] && grep -qxF "$wt_path" <<<"$all_candidates"; then
                    ledger_line "PRESERVE" "$wt_path" "capped, re-run to process"
                else
                    ledger_line "PRESERVE" "$wt_path" "young"
                fi
                preserved_count=$(( preserved_count + 1 ))
                continue
            fi

            if worktree_has_live_tmux_pane "$wt_path"; then
                ledger_line "PRESERVE" "$wt_path" "live-tmux-session"
                preserved_count=$(( preserved_count + 1 ))
                continue
            fi

            HYGIENE_CURRENT="$wt_path"
            local branch
            branch="$(branch_for_worktree "$repo_abs" "$wt_path")"
            [[ -n "$branch" ]] || branch="detached"

            local record
            record="$(triage_candidate "$repo_abs" "$wt_path" "$branch")"

            [[ "$record" != *'|pushed|'* ]] || pushed_count=$((pushed_count + 1))
            IFS='|' read -r uncommitted_count untracked_present push_status pr_state ahead_count has_merge_base suspect_rewrite <<<"$record"

            local verdict
            verdict="$(classify_candidate "$uncommitted_count" "$untracked_present" \
                "$push_status" "$pr_state" "$ahead_count" "$has_merge_base" "$suspect_rewrite")"

            local class="${verdict%%|*}" reason="${verdict#*|}"

            # A lossy clean filter can hide an edit from `git status`; never
            # SAFE-remove a worktree whose on-disk bytes differ from index/HEAD.
            if [[ "$class" == "SAFE" ]]; then
                local hidden
                hidden="$(preserve_wip_raw_bytes_dirty "$wt_path")" || hidden="byte-check-failed"
                if [[ -n "$hidden" ]]; then
                    class="NEEDS-REVIEW"
                    reason="hidden-filtered-change:$hidden"
                fi
            fi

            if [[ "$class" == "SAFE" ]]; then
                if [[ "$EXECUTE" == true ]]; then
                    local pre_remove_hidden
                    pre_remove_hidden="$(preserve_wip_raw_bytes_dirty "$wt_path")" || pre_remove_hidden="byte-check-failed"
                    if [[ -n "$pre_remove_hidden" ]]; then
                        ledger_line "NEEDS-REVIEW" "$wt_path" "hidden-filtered-change:$pre_remove_hidden"
                        review_count=$(( review_count + 1 ))
                    else
                        ledger_line "SAFE" "$wt_path" "$reason"
                        safe_count=$(( safe_count + 1 ))
                        git -C "$repo_abs" worktree unlock "$wt_path" 2>/dev/null || true
                        if git -C "$repo_abs" worktree remove --force --force "$wt_path"; then
                            ledger_line "DELETE" "$wt_path" ""
                            removed_count=$((removed_count + 1))
                        else
                            failed_count=$((failed_count + 1))
                            echo "WARN: failed to remove $wt_path"
                        fi
                    fi
                else
                    ledger_line "SAFE" "$wt_path" "$reason"
                    safe_count=$(( safe_count + 1 ))
                fi
            elif [[ "$PRESERVE_WIP" == true ]] && preserve_wip_reason_eligible "$reason"; then
                # classify_candidate reports only the first matching reason, so
                # `untracked`/`detached-unpushed` can mask large-diff,
                # no-merge-base, or an open PR (triage skips gh on dirty trees).
                local blocker="" wip_pr_state="$pr_state" pre_wip_sha=""
                pre_wip_sha="$(git -C "$wt_path" rev-parse --verify -q HEAD 2>/dev/null || true)"
                if (( uncommitted_count > 50 )); then
                    blocker="large-diff"
                elif (( has_merge_base == 0 )); then
                    blocker="no-merge-base"
                elif [[ "$wip_pr_state" == "unknown" && "$SKIP_GH" != true && "$branch" != "detached" ]]; then
                    wip_pr_state="$(query_pr_state "$repo_abs" "$wt_path" "$branch")"
                fi
                if [[ -z "$blocker" && "$wip_pr_state" == "open" ]]; then
                    blocker="open-pr"
                fi
                if [[ -n "$blocker" ]] || blocker="$(preserve_wip_blocker "$repo_abs" "$wt_path")"; then
                    ledger_line "NEEDS-REVIEW" "$wt_path" "$reason; preserve-wip skipped: $blocker"
                    case "$blocker" in
                        ignored-evidence:*) ledger_line "DECISION-REQUIRED" "$wt_path" "$blocker; retained; review ignored evidence explicitly before preservation" ;;
                    esac
                    review_count=$(( review_count + 1 ))
                elif [[ "$EXECUTE" == true ]]; then
                    if preserve_wip_and_remove "$repo_abs" "$wt_path" "$pre_wip_sha"; then
                        wip_count=$(( wip_count + 1 ))
                        removed_count=$((removed_count + 1))
                    else
                        review_count=$(( review_count + 1 ))
                    fi
                else
                    ledger_line "WOULD-PRESERVE-WIP" "$wt_path" "$reason"
                    wip_count=$(( wip_count + 1 ))
                fi
            else
                ledger_line "NEEDS-REVIEW" "$wt_path" "$reason"
                review_count=$(( review_count + 1 ))
            fi
            HYGIENE_COMPLETED="${HYGIENE_COMPLETED}${wt_path}"$'\n'
            HYGIENE_CURRENT=""
        done
        HYGIENE_SCANNED_REPOS="${HYGIENE_SCANNED_REPOS}${repo_abs}"$'\n'
        HYGIENE_REPO=""
    done
    HYGIENE_PHASE=completed
    HYGIENE_STATUS=completed

    echo ""
    echo "Worktree-hygiene: ${safe_count} safe, ${review_count} needs-review, ${preserved_count} preserved (protected or capped)."
    if [[ "$PRESERVE_WIP" == true ]]; then
        if [[ "$EXECUTE" == true ]]; then
            echo "Preserve-wip: ${wip_count} preserved to local wip/ branches, published and removed."
        else
            if [[ "$PUSH_WIP" == true && "$SKIP_PUSH" != true ]]; then
                echo "Preserve-wip: ${wip_count} would be preserved, verified remotely and removed."
            else
                echo "Preserve-wip: ${wip_count} would be preserved locally and kept (publication disabled)."
            fi
        fi
    fi
    echo "Note: NEEDS-REVIEW candidates are NOT auto-filed as beads by this script."
    echo "Route them to an agent (or manual triage) to judge bead-worthiness -- that's"
    echo "a judgment call, not a deterministic git-state check."
    if [[ "$EXECUTE" == false && "$safe_count" -gt 0 ]]; then
        echo "Run with --execute and WORKTREE_APPROVED=1 to delete the SAFE set."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
