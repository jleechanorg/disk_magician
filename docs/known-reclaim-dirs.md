# Known reclaim directories (last 7 days)

Generated 2026-10-20 17:07 UTC from `~/Library/Logs/disk-magician-deletions.log` and `~/.disk_magician_state/worktree_guard.log`. **Read this first** in any disk investigation or cleanup: these are the directories that grew, were cleaned, and will grow again. Re-clean them first, with the owning script (dry-run first, `--clean` to act). Sizes are `du -sk` at deletion time (APFS clones can overstate). Regenerate after cleanups; the long-term source of truth is the deletions log (see CLAUDE.md, 'Deletion log is the reclaim list').

## Cleaned roots by reclaimed size

| Root | GiB cleaned | Deletions | Owner script(s) | Last cleaned (UTC) |
|---|---:|---:|---|---|
| `/private/tmp/worldai_frontend` | 54.29 | 16 | `cleanup_xcode.sh` (15), `cleanup_tmp.sh` (1) | 2026-10-20T16:27 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T` | 24.89 | 353 | `cleanup_tmp.sh` (336), `cleanup_pr_scratch.sh` (16), `cleanup_xcode.sh` (1) | 2026-10-19T23:59 |
| `/private/tmp/worldai_claw` | 17.86 | 5 | `cleanup_tmp.sh` (4), `cleanup_xcode.sh` (1) | 2026-10-18T17:31 |
| `/private/tmp/worldarchitect.ai` | 12.02 | 24 | `cleanup_tmp.sh` (24) | 2026-10-18T03:50 |
| `/private/tmp/ipad-m5-build-20261019` | 7.52 | 3 | `cleanup_xcode.sh` (3) | 2026-10-20T03:57 |
| `/private/tmp/ipad-pr41-acceptance` | 6.86 | 2 | `cleanup_xcode.sh` (2) | 2026-10-18T16:57 |
| `/private/tmp/worldarchitect-advice-input.Rk4L6Y` | 6.24 | 1 | `cleanup_tmp.sh` (1) | 2026-10-14T05:45 |
| `/private/tmp/pr63_probe_dd` | 5.05 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T16:03 |
| `/private/tmp/pr98bg_dd` | 4.96 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T16:03 |
| `~/dd_pr115_rel` | 4.93 | 1 | `cleanup_xcode.sh` (1) | 2026-10-19T22:36 |
| `/private/tmp/pr98pn_dd` | 4.91 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T16:04 |
| `/private/tmp/dd_pr115_rel` | 4.91 | 1 | `cleanup_xcode.sh` (1) | 2026-10-19T02:57 |
| `~/dd_pr115_mock` | 4.90 | 1 | `cleanup_xcode.sh` (1) | 2026-10-19T22:35 |
| `/private/tmp/pr63-accept` | 4.89 | 1 | `cleanup_xcode.sh` (1) | 2026-10-19T02:54 |
| `/private/tmp/pr76_dd_rel` | 4.89 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T08:50 |
| `/private/tmp/pr63_dd_rel` | 4.89 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T08:50 |
| `~/wf_dd` | 4.89 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T03:26 |
| `~/wf_ipad_dd` | 4.88 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T03:26 |
| `~/wf_cache_dd` | 4.88 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T03:26 |
| `/private/tmp/pr98diag.NaIkXw` | 4.86 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T16:41 |
| `/private/tmp/advice-901` | 4.49 | 4 | `cleanup_tmp.sh` (4) | 2026-10-18T02:53 |
| `/private/tmp/pr10350-advclone.fWTk` | 3.36 | 1 | `cleanup_tmp.sh` (1) | 2026-10-15T10:15 |
| `/private/tmp/pr10350-advice-clone.NPBy` | 3.34 | 3 | `cleanup_tmp.sh` (2), `cleanup_pr_scratch.sh` (1) | 2026-10-17T00:46 |
| `/private/tmp/dd_pr115` | 2.65 | 1 | `cleanup_xcode.sh` (1) | 2026-10-19T02:52 |
| `/private/tmp/pr76_dd` | 2.64 | 1 | `cleanup_xcode.sh` (1) | 2026-10-18T08:50 |
| `/private/tmp/wa-10398-freeze2` | 2.42 | 1 | `cleanup_tmp.sh` (1) | 2026-10-18T15:56 |
| `/private/tmp/wa-10398-freeze` | 2.36 | 1 | `cleanup_tmp.sh` (1) | 2026-10-15T07:01 |
| `/private/tmp/p4-advice-input.rnqmeo8p` | 2.35 | 1 | `cleanup_tmp.sh` (1) | 2026-10-14T00:01 |
| `/private/tmp/world-sim-delta-review.QvJQce` | 2.30 | 1 | `cleanup_tmp.sh` (1) | 2026-10-14T10:21 |
| `/private/tmp/world-sim-m1-continuation-0huwy_8z` | 2.29 | 1 | `cleanup_tmp.sh` (1) | 2026-10-14T02:21 |
| `/private/tmp/dice61_native_68aebfbb` | 2.14 | 1 | `cleanup_tmp.sh` (1) | 2026-10-18T17:10 |
| `~/projects` | 1.67 | 143 | `cleanup_dev_caches.sh` (143) | 2026-10-19T13:14 |
| `/private/tmp/pr10350-plan-input-fBMgji` | 1.62 | 1 | `cleanup_tmp.sh` (1) | 2026-10-17T06:21 |
| `/private/tmp/pr10464-advice.MSlAPq` | 1.60 | 2 | `cleanup_tmp.sh` (1), `cleanup_pr_scratch.sh` (1) | 2026-10-16T23:09 |
| `/private/tmp/verif-1791938501` | 1.60 | 1 | `cleanup_tmp.sh` (1) | 2026-10-14T05:04 |
| `/private/tmp/world-sim-final-gates-NZo3rH` | 1.53 | 1 | `cleanup_tmp.sh` (1) | 2026-10-14T05:58 |
| `/private/tmp/advice-10407-frozen` | 1.52 | 1 | `cleanup_tmp.sh` (1) | 2026-10-14T23:54 |
| `/private/tmp/worldai-ci-reconcile.Ivd8l5` | 1.52 | 1 | `cleanup_tmp.sh` (1) | 2026-10-16T22:39 |
| `/private/tmp/advice-10439-frozen` | 1.51 | 1 | `cleanup_tmp.sh` (1) | 2026-10-15T05:56 |
| `/private/tmp/pr10350-review-input-xw0urx7l` | 1.23 | 1 | `cleanup_tmp.sh` (1) | 2026-10-18T02:52 |
| _2990 smaller roots_ | 78.21 | | | |

Total logged: **315.9 GiB** across 3030 roots (central log only).

## Worktree removals (not in the central log yet)

These were removed by `worktree_remove_hook.sh` and are recorded only in `worktree_guard.log` (no sizes). A fix to log them centrally is on branch `feat/central-deletion-logging`.

| Worktree group | Removed | Last (UTC) |
|---|---:|---|
| `~/.worktrees/worldarchitect.ai` | 36 | 2026-10-20T07:36 |
| `~/.worktrees/spicy-search` | 33 | 2026-10-20T09:23 |
| `~/.worktrees/worldai_frontend` | 19 | 2026-10-20T09:36 |
| `~/projects` | 8 | 2026-10-20T04:24 |
| `~/.worktrees/disk_magician` | 3 | 2026-10-19T03:02 |
| `/tmp/dm-wrh-test.rpsuwu` | 1 | 2026-10-13T18:56 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.CO1mfQeCtP` | 1 | 2026-10-13T18:56 |
| `/tmp/dm-wrh-test.JQW3Hk` | 1 | 2026-10-13T19:15 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.lDB9ezYVQB` | 1 | 2026-10-13T19:15 |
| `~/.hermes.worktrees` | 1 | 2026-10-19T06:08 |
| `~/worktrees` | 1 | 2026-10-19T06:08 |

## Re-clean commands (dry-run first)

| Target | Command |
|---|---|
| `/private/tmp` scratch (4 h idle tier) | `LARGE_TMP_APPROVED=1 LARGE_TMP_ACTIVE_HOURS=4 LARGE_TMP_ARCHIVE_RETENTION_HOURS=4 bash scripts/cleanup_tmp.sh --clean --large` (needs the scratch lock; the main sweeper often holds it) |
| Custom Xcode DerivedData (`/private/tmp/*/dd*`, `~/dd_*`, `~/wf_*_dd`) | `bash scripts/cleanup_xcode.sh --clean` |
| PR/task scratch | `bash scripts/cleanup_pr_scratch.sh --clean`, `bash scripts/cleanup_task_scratch.sh --clean` |
| Dev caches | `diskm cleanup-dev-caches --clean` |
| Eligible worktrees (3-day floor) | `WORKTREE_APPROVED=1 bash scripts/cleanup_worktrees.sh --clean` |
| Clean, remote-pushed worktrees idle 2 h | `DISK_MAGICIAN_REMOVE_HOOK_RECENCY=minutes:120` with `worktree_remove_hook.sh` (branch `feat/remove-hook-recency-override`; back up dirty ones first to `refs/wip/diskm/`) |
| Colima | `diskm cleanup-colima --clean` (nothing to trim when already compact) |

## Do not chase
- `/private/var/folders/*/*/X/com.google.Chrome.code_sign_clone` (about 157 GiB by `du`): APFS clone phantom, shares blocks with `/Applications`; deleting frees about nothing (findings_wiki/2026-10-17-codesign-clone-du-is-phantom-when-versions-match.md).
- `~/.codex/sessions*`, `~/.claude/projects`: never-delete list.
