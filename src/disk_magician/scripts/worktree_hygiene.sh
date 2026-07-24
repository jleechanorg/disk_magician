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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/worktree_repo_discovery.sh
source "$SCRIPT_DIR/lib/worktree_repo_discovery.sh"

EXECUTE=false
MIN_AGE_DAYS=14
REPOS=()
SKIP_PUSH=false
SKIP_GH=false
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
Usage: $(basename "$0") [--execute] [--min-age N] [--repos p1,p2,...] [--skip-push] [--skip-gh] [--max-candidates N] [-h|--help]

Repeatable worktree-hygiene sweep: IDENTIFY -> TRIAGE -> CLASSIFY -> (optionally) DELETE.

Options:
  --execute     Actually delete SAFE-classified worktrees via
                'git worktree remove --force' (default: dry-run/report-only).
                Requires WORKTREE_APPROVED=1 in the environment.
  --min-age N   Minimum worktree age in days for candidacy (default: 14).
  --repos LIST  Comma-separated main repo paths to scan (default:
                CLAUDE_WORKTREE_REPOS env override, else auto-discover --
                same logic as cleanup_worktrees.sh).
  --skip-push   Skip the 'git push origin HEAD:<branch>' preservation step
                during triage (offline/test runs). push_status="skipped".
  --skip-gh     Skip the 'gh pr list' lookup during triage (offline/test
                runs). pr_state="unknown".
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

    local now
    now=$(date +%s)

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
                    local latest_mtime
                    # Three stacked perf/correctness fixes for the same
                    # underlying hang (jleechan-q912), each independently
                    # confirmed against the real 340+ worktree
                    # worldarchitect.ai registry:
                    #  1. `-prune` on excluded dirs instead of `-not -path`
                    #     -- `-not -path` still descends into every
                    #     excluded dir (e.g. a venv/ with tens of thousands
                    #     of site-packages files) and filters results
                    #     afterward; `-prune` stops descent entirely. This
                    #     was the dominant cost (47s of syscall/kernel time
                    #     alone, even after fix #2 below).
                    #  2. `-exec stat ... +` batches many files per stat
                    #     invocation instead of spawning one process per
                    #     file (`\;`).
                    #  3. `|| true` guards against a real pre-existing bug:
                    #     under this script's `set -o pipefail`, `head -1`
                    #     closing the pipe early can make `sort` receive
                    #     SIGPIPE and the whole pipeline exit 141, which --
                    #     unguarded -- trips `set -e` and aborts
                    #     identify_candidates silently (zero output, no
                    #     error surfaced) partway through a large registry.
                    #     Confirmed present in the previously-committed
                    #     script too, independent of fixes #1/#2.
                    latest_mtime=$(find "$path" \
                        \( -name '.git' -o -name 'node_modules' \
                           -o -name 'venv' -o -name '__pycache__' \) -prune \
                        -o -type f -exec stat -f '%m' {} + 2>/dev/null \
                        | sort -rn | head -1) || true
                    if [[ -z "$latest_mtime" ]]; then
                        latest_mtime=$(stat -f '%m' "$path" 2>/dev/null || echo "$now")
                    fi
                    local age_days=$(( (now - latest_mtime) / 86400 ))
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
    if (( ahead_count > 0 )) && [[ "$push_status" == "no-remote" || "$push_status" == "skipped" ]]; then
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

# triage_candidate <repo_path> <wt_path> <branch>
# Echoes: <uncommitted_count>|<untracked_present>|<push_status>|<pr_state>|<ahead_count>|<has_merge_base>|<suspect_rewrite>
triage_candidate() {
    local repo_path="$1" wt_path="$2" branch="$3"

    local status_porcelain uncommitted_count untracked_present
    status_porcelain="$(git -C "$wt_path" status --porcelain 2>/dev/null || true)"
    if [[ -z "$status_porcelain" ]]; then
        uncommitted_count=0
    else
        uncommitted_count=$(printf '%s\n' "$status_porcelain" | grep -c . || true)
    fi
    untracked_present=0
    if printf '%s\n' "$status_porcelain" | grep -qE '^\?\?'; then
        untracked_present=1
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
        fi
    else
        has_merge_base=0
        ahead_count="$(git -C "$wt_path" rev-list --count HEAD 2>/dev/null || echo 0)"
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
        elif [[ "${SKIP_PUSH:-false}" == true ]]; then
            push_status="skipped"
        else
            if git -C "$wt_path" remote get-url origin >/dev/null 2>&1; then
                local push_rc
                git -C "$wt_path" push origin "HEAD:${branch}" >/dev/null 2>&1
                push_rc=$?
                if [[ $push_rc -eq 0 ]]; then
                    push_status="pushed"
                else
                    # Non-fast-forward (or any) rejection: retry to a dated
                    # backup ref instead of forcing the original branch.
                    local backup_ref
                    backup_ref="backup/${branch}-$(date +%Y%m%d)"
                    if git -C "$wt_path" push origin "HEAD:${backup_ref}" >/dev/null 2>&1; then
                        push_status="pushed"
                    else
                        push_status="rejected-nonff"
                    fi
                fi
            else
                push_status="no-remote"
            fi
        fi

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
                    local pr_json
                    # env -u: a stale GH_TOKEN/GITHUB_TOKEN override breaks gh
                    # even when the stored keychain credential is valid.
                    pr_json="$(env -u GH_TOKEN -u GITHUB_TOKEN gh pr list --repo "$owner_repo" --head "$branch" --state all \
                        --json number,state,title 2>/dev/null || true)"
                    if [[ -n "$pr_json" && "$pr_json" != "[]" ]]; then
                        if echo "$pr_json" | grep -qi '"state":"OPEN"'; then
                            pr_state="open"
                        elif echo "$pr_json" | grep -qi '"state":"MERGED"'; then
                            pr_state="merged"
                        elif echo "$pr_json" | grep -qi '"state":"CLOSED"'; then
                            pr_state="closed"
                        else
                            pr_state="none"
                        fi
                    else
                        pr_state="none"
                    fi
                else
                    pr_state="unknown"
                fi
            else
                pr_state="unknown"
            fi
        fi
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
# Main
# ---------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "${1:-}" in
            --execute) EXECUTE=true ;;
            --min-age)
                [[ $# -ge 2 ]] || { echo "--min-age requires a value" >&2; exit 2; }
                MIN_AGE_DAYS="$2"
                shift
                ;;
            --repos)
                [[ $# -ge 2 ]] || { echo "--repos requires a value" >&2; exit 2; }
                IFS=',' read -ra REPOS <<<"$2"
                shift
                ;;
            --skip-push) SKIP_PUSH=true ;;
            --skip-gh) SKIP_GH=true ;;
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

    if [[ ${#REPOS[@]} -eq 0 ]]; then
        while IFS= read -r repo; do
            [[ -n "$repo" ]] && REPOS+=("$repo")
        done < <(discover_worktree_repos "${CLAUDE_WORKTREE_REPOS:-}")
    fi

    if [[ "$EXECUTE" == true ]]; then
        echo "=== WORKTREE HYGIENE ==="
        if [[ "${WORKTREE_APPROVED:-0}" != "1" ]]; then
            echo "Refusing to delete worktrees: set WORKTREE_APPROVED=1 after explicit approval."
            exit 0
        fi
    else
        echo "=== WORKTREE HYGIENE (DRY-RUN) ==="
    fi

    local safe_count=0 review_count=0 preserved_count=0

    for repo in "${REPOS[@]}"; do
        [[ -d "$repo" ]] || continue
        local repo_abs
        repo_abs=$(cd "$repo" 2>/dev/null && pwd -P) || continue

        echo ""
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

            local branch
            branch="$(branch_for_worktree "$repo_abs" "$wt_path")"
            [[ -n "$branch" ]] || branch="detached"

            local record
            record="$(triage_candidate "$repo_abs" "$wt_path" "$branch")"

            IFS='|' read -r uncommitted_count untracked_present push_status pr_state ahead_count has_merge_base suspect_rewrite <<<"$record"

            local verdict
            verdict="$(classify_candidate "$uncommitted_count" "$untracked_present" \
                "$push_status" "$pr_state" "$ahead_count" "$has_merge_base" "$suspect_rewrite")"

            local class="${verdict%%|*}" reason="${verdict#*|}"

            if [[ "$class" == "SAFE" ]]; then
                ledger_line "SAFE" "$wt_path" "$reason"
                safe_count=$(( safe_count + 1 ))
                if [[ "$EXECUTE" == true ]]; then
                    ledger_line "DELETE" "$wt_path" ""
                    git -C "$repo_abs" worktree remove --force "$wt_path"
                fi
            else
                ledger_line "NEEDS-REVIEW" "$wt_path" "$reason"
                review_count=$(( review_count + 1 ))
            fi
        done
    done

    echo ""
    echo "Worktree-hygiene: ${safe_count} safe, ${review_count} needs-review, ${preserved_count} preserved (young)."
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
