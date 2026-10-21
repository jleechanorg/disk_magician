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

## Directory ledger (2026-10-20)

Class: reclaim = a registered sweeper owns it; needs-decision = report-only, operator must decide; protected = never-delete list; uncovered = no owner. Owners come from `config/sweeper_roots.txt` (longest-prefix match; `decision:` routes are report-only). Registry additions: PR rows under `recorded-cleaned 2026-10-20` in that file.

### A. Uncovered / needs-decision / protected rows >= 5 GiB (routine dry-run audit)

| Path | GiB (size) | Class | Owner script | Source / date |
|---|---:|---|---|---|
| `/Applications` | 30.4 | uncovered | none | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/.codex/thread_history_1.sqlite` | 17.7 | uncovered | none | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/Library/Application Support` | 15.0 | needs-decision | none | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/Library/Application Support/Google/Chrome` | 3.5 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/Library/Application Support/Aside` | 2.8 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/Library/Developer/CoreSimulator/Devices` | 11.8 | needs-decision | decision:cleanup_xcode.sh | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/projects_other` | 10.0 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `/opt/homebrew/Cellar` | 8.2 | uncovered | none | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/Pictures/Photos Library.photoslibrary/resources/derivatives` | 7.4 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/Documents/Codex/2026-10-03` | 7.0 | needs-decision | decision:cleanup_codex_documents.sh | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/.config` | 6.5 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `/opt/homebrew/lib` | 6.1 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/.local/share` | 5.9 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/Library/CloudStorage/Dropbox/conversation-backups/codex_conversations/2026/10` | 5.6 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/Pictures/Photos Library.photoslibrary/database` | 5.5 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `/Library/Developer` | 5.3 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/.nvm/versions/node/v22.22.0/lib/node_modules` | 5.2 | needs-decision | decision:check_uncovered_roots.py | `clean --routine --dry-run` audit, 2026-10-20 |
| `/private/var/db` | 5.0 | uncovered | none | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/.codex/sessions` | 49.4 | protected | none | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/.claude/projects` | 15.3 | protected | none | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/projects_reference` | 12.9 | protected | none | `clean --routine --dry-run` audit, 2026-10-20 |
| `~/.hermes/state.db` | 11.6 | protected | none | `clean --routine --dry-run` audit, 2026-10-20 |

### B. Growth vs floor, rows >= 1 GiB

Growth is `current - floor` per path (ledger floor 780.87 GiB used at 2026-10-14; observer floor 707.5 transient at 2026-10-18, typical daily min 812.1, current 823.5). Growth is a delta, not a size; APFS clones and sparse files can overstate it.

| Path | GiB (growth) | Class | Owner script | Source / date |
|---|---:|---|---|---|
| `~/.colima/_lima/_disks/colima/datadisk` | +16.58 | reclaim | cleanup_colima.sh | 7d floor delta, 2026-10-20 |
| `/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/af14d04fa4f5b29c2471951b01491c6403eab68f.asset/AssetData/Restore/iOSSimulatorRuntime_Cryptex.dmg` | +9.87 | uncovered | none | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/evidence/pr120-native-build.Cb4tKE` | +4.92 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/projects/worldarchitect.ai` | +4.85 | reclaim | cleanup_worktree_venvs.sh | 7d floor delta, 2026-10-20 |
| `~/Documents/Codex/2026-10-15` | +4.84 | needs-decision | decision:cleanup_codex_documents.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/pi-subagents-uid-501` | +4.82 | reclaim | cleanup_tmp.sh / cleanup_pr_scratch.sh | 7d floor delta, 2026-10-20 |
| `~/project_worldai_frontend` | +4.52 | uncovered | none | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/dd_localturn/Build` | +4.46 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/bgcont-dd/Build` | +4.41 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/.gemini` | +4.10 | uncovered | none | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldarchitect.ai/zfc-pr10641-advice-20261020/agy-233fc0c5-clone` | +3.96 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `/Applications/Xcode-26.6.app` | +3.75 | uncovered | none | 7d floor delta, 2026-10-20 |
| `~/.worktrees/worldai_frontend/push-ledger-20261019` | +3.45 | reclaim | cleanup_worktrees.sh | 7d floor delta, 2026-10-20 |
| `~/.worktrees/worldai_frontend/ios-turn-parse-build39-20261019-gpt6sol` | +3.45 | reclaim | cleanup_worktrees.sh | 7d floor delta, 2026-10-20 |
| `~/.worktrees/worldai_frontend/social-challenge-29` | +3.43 | reclaim | cleanup_worktrees.sh | 7d floor delta, 2026-10-20 |
| `/private/var/db/diagnostics` | +3.35 | uncovered | none | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldarchitect.ai/zfc-pr10641-advice-20261020/agy-fec38a92-clone` | +3.23 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/.worktrees/spicy-search` | +2.94 | reclaim | cleanup_worktrees.sh | 7d floor delta, 2026-10-20 |
| `~/Library/Developer/CoreSimulator/Devices/59D6E2CF-A54C-4936-9009-88D16E6068EB` | +2.75 | needs-decision | decision:cleanup_xcode.sh | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/proof-dd` | +2.64 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/Library/Developer/CoreSimulator/Devices/0CE58B36-9089-4B82-BA07-5BBF86C7B224` | +2.63 | needs-decision | decision:cleanup_xcode.sh | 7d floor delta, 2026-10-20 |
| `~/.codex/sessions/2026/10/15` | +2.59 | protected | none | 7d floor delta, 2026-10-20 |
| `~/.codex/thread_history_1.sqlite` | +2.53 | uncovered | none | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/real-apns-tap-dd` | +2.51 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/Library/Developer/CoreSimulator/Devices/2326D2EB-18DC-47FF-A3C1-1ED2E8EF7B7B` | +2.48 | needs-decision | decision:cleanup_xcode.sh | 7d floor delta, 2026-10-20 |
| `~/.codex/sessions/2026/10/18` | +2.44 | protected | none | 7d floor delta, 2026-10-20 |
| `~/Library/Developer/CoreSimulator/Devices/2E246071-0F01-4702-8FCA-2A96D13C8D9B` | +2.41 | needs-decision | decision:cleanup_xcode.sh | 7d floor delta, 2026-10-20 |
| `/.Spotlight-V100/Store-V2/A9B6D64F-0DDE-47EB-BFAC-3D18D5D5BDD7/14.indexPositions` | +2.30 | uncovered | none | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.6Yr9VNzEsd` | +2.24 | reclaim | cleanup_tmp.sh / cleanup_pr_scratch.sh | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai-json42.79hE47` | +2.22 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `/opt/homebrew/share` | +1.91 | uncovered | none | 7d floor delta, 2026-10-20 |
| `~/.hermes/state.db` | +1.88 | protected | none | 7d floor delta, 2026-10-20 |
| `~/wf_pr76cap` | +1.87 | uncovered | none | 7d floor delta, 2026-10-20 |
| `/System/Library/AssetsV2/com_apple_MobileAsset_MacSoftwareUpdate` | +1.86 | uncovered | none | 7d floor delta, 2026-10-20 |
| `~/.config/dot-headless-chrome-u0` | +1.78 | needs-decision | decision:check_uncovered_roots.py | 7d floor delta, 2026-10-20 |
| `~/Library/Developer/CoreSimulator/Devices/EBCC5AA3-0399-433F-A1DC-22234573B052` | +1.74 | needs-decision | decision:cleanup_xcode.sh | 7d floor delta, 2026-10-20 |
| `~/.config/gcloud` | +1.59 | needs-decision | decision:check_uncovered_roots.py | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/evidence/local-turn-notification/native/v5` | +1.57 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/.codex/sessions/2026/10/19` | +1.53 | protected | none | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-lfklm7k0` | +1.52 | reclaim | cleanup_tmp.sh / cleanup_pr_scratch.sh | 7d floor delta, 2026-10-20 |
| `~/.local/share/cursor-agent` | +1.51 | needs-decision | decision:check_uncovered_roots.py | 7d floor delta, 2026-10-20 |
| `~/projects/spicy-search` | +1.43 | reclaim | cleanup_worktree_venvs.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.01bI8b` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.02CfUN` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.0s5riP` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.1jTMHC` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.2FlpL7` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.3RHoCb` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.5LJ9YE` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.5NPhi9` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.6Ka77s` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.6R0SUZ` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.6YixM6` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.6i0ziX` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.6vEcFX` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.73LcN3` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.7hwWKs` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.7qvlEz` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.7snMhE` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.8UNf9e` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.8uxHGH` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.9cFhUA` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.AgSusq` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.AgcIfG` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.AhKT1Z` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.BUifVY` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.C09mN0` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.CAt5mp` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.CX9fgm` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.DxZpXs` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.ENetoZ` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Esxfep` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Ex7Mhq` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.FeQ1Oj` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.FmHKh8` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.H0hJ84` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Hjepn4` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.HzmL5O` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Jey4D3` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.L6zYVu` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.MT41rf` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.MUIXpR` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Mhnz9L` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.MiCJ8x` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.NEjoLp` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.NHB0My` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.NLBMs9` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.NtA85f` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.OCsW5p` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.OQ96SP` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.OYcZBB` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.PPhHxR` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Pd6D5w` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.PpxqP9` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Q5RUoa` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.QNCKEt` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.QztPGr` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.RGK77B` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.SoE6bJ` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.VPJZKa` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Wo9bo8` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Wwvhm1` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.XFPgNK` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.YPyWCB` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Z7K482` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Zg64qd` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.ao86dA` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.d0D7L9` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.ddHOeo` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.fiQNXs` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.gCpjic` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.gQP7Xm` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.gvkWTW` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.ipJmf9` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.iucqW3` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.jB5j9t` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.jo15vy` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.kVpeNz` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.lRyPOi` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.mGiWHZ` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.mqx6YH` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.msjWRw` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.n22qjF` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.nFZuCg` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.oqPk2v` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.ppTWfe` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.qaLT47` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.rVA1DI` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.sUUawP` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.skKJIf` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.swsNSP` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.sxnLtx` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.v3tl6W` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.yDrW5j` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.yHrrtH` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.yqCncb` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.zEsiKU` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.zLZYWs` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.zmtkGs` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.6SmJgb` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.8hczWJ` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.Euwrw0` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.GWWuDk` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.GzxAIl` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.R85QZn` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.YxgLIH` | +1.41 | reclaim | cleanup_code_sign_clones.sh | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai-testflight-local.gfwBKw` | +1.40 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/.codex/sessions/2026/10/16` | +1.28 | protected | none | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/bgcont-dd/ModuleCache.noindex` | +1.26 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/dd_localturn/ModuleCache.noindex` | +1.26 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/wc-wt` | +1.23 | reclaim | cleanup_worktree_venvs.sh | 7d floor delta, 2026-10-20 |
| `~/actions-runner` | +1.17 | uncovered | none | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/local-notif-scripts` | +1.16 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/evidence/p0-push` | +1.14 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/wf_frontend_build` | +1.07 | uncovered | none | 7d floor delta, 2026-10-20 |
| `~/.worktrees/worldarchitect.ai/pr10389-acceptance` | +1.07 | reclaim | cleanup_worktrees.sh | 7d floor delta, 2026-10-20 |
| `/private/tmp/worldai_frontend/evidence/local-turn-notification/native/v6` | +1.04 | reclaim | cleanup_tmp.sh | 7d floor delta, 2026-10-20 |
| `~/.local/share/uv` | +1.03 | needs-decision | decision:check_uncovered_roots.py | 7d floor delta, 2026-10-20 |

### C. Deleted parent paths, last 7 days

Every distinct parent of a removed path in `~/Library/Logs/disk-magician-deletions.log` from 2026-10-13 to 2026-10-20: 563 parents, 214.3 GiB removed. `du -sk` at deletion time; APFS clones can overstate. Owner is the script that logged the removal. Class is `reclaim` because a script already removed it; `Registered` shows whether the parent also matches `config/sweeper_roots.txt`.

| Parent path | GiB removed | Deletions | Class | Owner script | Registered |
|---|---:|---:|---|---|---|
| `/private/tmp` | 56.18 | 2459 | reclaim | `cleanup_pr_scratch.sh`, `cleanup_tmp.sh`, `cleanup_xcode.sh` | yes |
| `/private/tmp/worldai_frontend` | 46.76 | 13 | reclaim | `cleanup_tmp.sh`, `cleanup_xcode.sh` | yes |
| `~` | 25.15 | 6 | reclaim | `cleanup_xcode.sh` | no |
| `/private/tmp/worldai_frontend/dd` | 7.53 | 3 | reclaim | `cleanup_xcode.sh` | yes |
| `/private/tmp/ipad-m5-build-20261019` | 7.52 | 3 | reclaim | `cleanup_xcode.sh` | yes |
| `/private/tmp/ipad-pr41-acceptance` | 6.86 | 2 | reclaim | `cleanup_xcode.sh` | yes |
| `/private/tmp/worldarchitect-advice-input.Rk4L6Y` | 6.24 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/pr63-accept` | 4.89 | 1 | reclaim | `cleanup_xcode.sh` | yes |
| `/private/tmp/advice-901` | 4.49 | 4 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/worldai_claw/appstore` | 4.47 | 1 | reclaim | `cleanup_xcode.sh` | yes |
| `/private/tmp/pr10350-advice-clone.NPBy` | 3.34 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-delta-review.QvJQce` | 2.30 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T` | 2.09 | 42 | reclaim | `cleanup_pr_scratch.sh`, `cleanup_tmp.sh`, `cleanup_xcode.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-7fiokghm` | 1.89 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `~/.local/state` | 1.69 | 2 | reclaim | `cleanup_pr_scratch.sh` | no |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.hb3b8jP1Wg` | 1.65 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.23vNts9itT` | 1.65 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.KBOFswxbhO` | 1.65 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.M8KgG5ryUb` | 1.64 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.KpvXFmp4fB` | 1.63 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.nlI4Pixtre` | 1.63 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.iaDRZILkfl` | 1.63 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.Dq9HMpA0kL` | 1.63 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/pr10464-advice.MSlAPq` | 1.60 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-1y9vkw5y` | 1.54 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-8fbruzex` | 1.53 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-sot6liv2` | 1.53 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/levelup-frozen-advice-source-ui84h0cq` | 1.15 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m1a-advice-source` | 0.99 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/pr10534-advice-source.ED8udM` | 0.98 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/worldarchitect.ai/.beads/.br_recovery/schema-migrations` | 0.95 | 25 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/advice-primary-pair-ryyjyyve` | 0.93 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/.peekaboo/snapshots` | 0.79 | 2346 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/Documents/Codex` | 0.73 | 10 | reclaim | `cleanup_pr_scratch.sh` | yes |
| `~/Library/Logs/dark-factory` | 0.73 | 33 | reclaim | `cleanup_supervisor_logs.sh` | yes |
| `~/.local/state/worldarchitect-evidence` | 0.68 | 2 | reclaim | `cleanup_pr_scratch.sh` | yes |
| `/private/tmp/fmt-diag-1a9ea7e3-yYRT` | 0.61 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-lvjoyouw` | 0.46 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-8m1irqot` | 0.45 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/levelup-middle-verify-bd2knxrk` | 0.33 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/levelup-candidate-verifier-f81xtout` | 0.33 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/push-viewport-a5ad-helper` | 0.32 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/eas-cli-nodejs` | 0.32 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/d5-mixed-red-provenance.KLViYm` | 0.31 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/p4-advice-isolated.3x62R2` | 0.30 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m1b-advice-input.Qf4hFvIg` | 0.30 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/advice-pr10418-input.l9j4KU` | 0.30 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/advice-pr10418-input.IZnBc6` | 0.29 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/spicy-search` | 0.23 | 6 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/worktree_exp_not_saving_coder/.beads/.br_recovery` | 0.12 | 24 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/worktree_arcanum/.beads/.br_recovery/schema-migrations` | 0.10 | 2 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/wt-pr9599-review-comments/.beads/.br_recovery/schema-migrations` | 0.10 | 3 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/worldarchitect.ai/.beads/.br_recovery` | 0.05 | 8 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/ratchet-verify2.Fu8SRI` | 0.03 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/worktree_arcanum/.beads/.br_recovery` | 0.03 | 10 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/worktree_openrouter-welcome-implementation/.beads/.br_recovery` | 0.03 | 10 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/worktree_lvl_redesign_again/.beads/.br_recovery` | 0.03 | 10 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/worktree_level_cross_2stage/.beads/.br_recovery` | 0.03 | 10 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/worktree_ui_redesign/.beads/.br_recovery` | 0.03 | 10 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/worktree_world_sim/.beads/.br_recovery` | 0.03 | 10 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/ratchet-verify.mp99Nn` | 0.03 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/worktree_ez_merge/.beads/.br_recovery/schema-migrations` | 0.03 | 1 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/pr10350-gist-publish-2gSUeK` | 0.03 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/worktree_fable_bulk_restored/.beads/.br_recovery/schema-migrations` | 0.03 | 1 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/worldarchitect.ai.er-9758.vBWCA7` | 0.03 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/worktree_ci_trim/.beads/.br_recovery/schema-migrations` | 0.03 | 1 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/pr10350-flat-gist-cDODsA` | 0.02 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/worktree_pr8856_evidence_b82_clean/.beads/.br_recovery/schema-migrations` | 0.02 | 1 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/worktree_pr8856_evidence_clean/.beads/.br_recovery/schema-migrations` | 0.02 | 1 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects_other/ez-gh-actions/.beads/.br_recovery/schema-migrations` | 0.02 | 3 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/gv` | 0.01 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/jleechan-skills-pr381-recursive/.beads/.br_recovery/schema-migrations` | 0.01 | 8 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects_other/jleechan-skills/.beads/.br_recovery/schema-migrations` | 0.01 | 6 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects_other/disk_magician/.beads/.br_recovery/schema-migrations` | 0.01 | 3 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/world-sim-m1a-media-gist.9qvbbMrm` | 0.01 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m1a-gist-verify.mF9PUm5E` | 0.01 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.OIVidPVvPM` | 0.01 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects_other/beads/.beads/.br_recovery/schema-migrations` | 0.01 | 2 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/world-sim-m2a-full-cs.D3KiYg` | 0.01 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/worktree_harness_stability/.beads/.br_recovery/schema-migrations` | 0.01 | 3 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects_other/claude-commands/.beads/.br_recovery/schema-migrations` | 0.01 | 4 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/world-sim-m1a-oldgist.Ya6ShgqD` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/q3b1-gists.TBL1KI` | 0.00 | 4 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects_other/worktree_web_advice/.beads/.br_recovery/schema-migrations` | 0.00 | 2 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects_other/worktree_misc_skills/.beads/.br_recovery/schema-migrations` | 0.00 | 2 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/world-sim-m1a-gist-verify.2Pt0frOS` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/advice-gist` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m1a-gist-fix.j6l3PZWp` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m1a-gist-verify.UR5AtaIW` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/dm-worktree-new.pC0R3C` | 0.00 | 5 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/wsa-final` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-early-actual-er-close-vjwbu7jx` | 0.00 | 4 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/d4-er-review.oHsNJd` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects/jleechan-skills/.beads/.br_recovery/schema-migrations` | 0.00 | 3 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects_other/ai_universe_frontend/.beads/.br_recovery/schema-migrations` | 0.00 | 2 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp36fi9tik` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/er_gist` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/dm-worktree-new.jERbVW` | 0.00 | 5 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/pr10350-gist-transport-uie5_p4y` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/dm-worktree-new.gPUW9S` | 0.00 | 5 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpuwo35jmu` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/worldarchitect.ai-er10445.xROQdD` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/cleanup_wt_fastpath.XXXXXX.5BPMMEUQH3` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/cleanup_wt_fastpath.XXXXXX.fuqMYO8TOi` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-i4-proof-closure-qku28v_4` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/worldarchitect.ai-er10443.3NzsJhPT` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/dm-worktree-new.0XKice` | 0.00 | 5 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/d5-er-review.XhdDhE` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-d5-review-publish.U43Z4K` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-d4-final-review.UXVteDOd` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-d4-current-gist.u74BarM9` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects_other/bp-telemetry-apps/.beads/.br_recovery` | 0.00 | 13 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/world-sim-m2a-gist-verify.iHLKWn` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects_other/jleechan-skills/.beads/.br_recovery` | 0.00 | 14 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects_other/claw-code/.beads/.br_recovery` | 0.00 | 13 | reclaim | `cleanup_dev_caches.sh` | yes |
| `/private/tmp/world-sim-m2a-advice-gist.TpsDbj` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m1b-gist-verify.cTF6s0` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.d6PGfK` | 0.00 | 4 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.fLP7GW` | 0.00 | 4 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.vFrYE6` | 0.00 | 4 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.fgns0a` | 0.00 | 4 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.7VlvEn` | 0.00 | 4 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m1b-gistclone.9Z352U` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-evidence-review` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m1b-er-review.YTVxRvDV` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.Ftpbw7tTx8` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.KhnkwRiIeh` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.8A3mtL33FU` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.GyrXKSlxTg` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/er10350_gist.j0hE` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/er-10408-68Lxsh` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.fnO8vM` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-d9-gist-readback.J2ZCzw` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.1rBlGO` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.yxtLIq` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.q2pcCV` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.UrQvEl` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.cmy1vs` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.WrSoJA` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.XNC1iD` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.OQ0UyS` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.fBcWVK` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.RszMXl` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.T6Mcjj` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.WeUnVD` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.s0woML` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.FLPAhf` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.eDIV2F` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.G0hedfqLC1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m2a-closure-gist.0vh475` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/worldarchitect.ai-er10443-gitrevs-9ZRysP` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.zrLkKh` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.GWm7ZN` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.127PBG` | 0.00 | 3 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.vEAeto` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.vc5hfe` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.w3JMqR` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.ta4IPi` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.Rq977o` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.ggh7Vg` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.AyILDn` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.ewgQMs` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.gVlNAS` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.IX49Rp` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.EYYi04` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.gkLD8R` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.fdoEoR` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.s53bId` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.QnPmQ6` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.cMOQRQ` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.zWedi4` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.ti7s8H` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.Ridz6C` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.IwY1Cw` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.cpBHdG` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.bKI0ay` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.sOjQLZ` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.oyvna0` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.L0JCOg` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.BSOgNh` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.ZuFD8i` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.hJODKG` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.e73Nvi` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.rheRg2` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.IalC5E` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.VH0YiI` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.ZxiazD` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.gJQb7R` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.nCzz1m` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/worldsim-policy.Co4YJz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpwiki2izp` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpxfgkyk8o` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpw9cakybs` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpa21wt9km` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-i1-extraction-jfc_hhga` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpifeqr_34` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpuvfi5sn4` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp8neldmyd` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp1ud_lqdn` | 0.00 | 2 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpm7aw9sx4` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmptav_tmqk` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpmiv2pnav` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpzcb8ia_5` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp0bb96lkv` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp6vj7e8qj` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpsgdb0qc9` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpk1jeifvw` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpn49w5ri1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpzfs62w5w` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp2fe0osew` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpoesyqdis` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp0y6fhk83` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp37kn7kub` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpl1fgmo0b` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpkd0tveni` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp6umhain1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp14yz6kyl` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp2dpf8449` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp743i87lm` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpm4j8azfj` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp8w_adfe8` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpxz3havi0` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp3f5ntqrk` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp22nu910j` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp_d4mny83` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpe055pt27` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpmnat_9ot` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpd73vcjor` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpzyptq2wa` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp7qocpxam` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpujyoklze` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpc9b4za7f` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmptikpo_ni` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp_tjjlbnz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpg4_9gedw` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpgp4xzcdt` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp8cz3rt48` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpdwi6dh81` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp4y2u6_qw` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpivawvx6g` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpak0ij7p9` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp5cx16wds` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpxjl0lz_q` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpmto5tkg1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp5u1vq53j` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp5ori_zdc` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpr1nojhe2` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp9nfwjw01` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpibtvkdzk` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpx8155_yp` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpaop7i0zz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpsl77b4_s` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpxexreuaj` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp3u806bqi` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpzlsd3cy_` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp52yrc1yd` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpq1dmq93e` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpk6tc856z` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpi1wl9yr8` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp5qjf3gxk` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpzrqa2k62` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpulfdfdfy` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpwlh2enzg` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp3uh7720p` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmphi7ic4c7` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpe__md74l` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpva124omi` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpzz77uqr2` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpsc_rffs2` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp1_k7lsgh` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp2c6vuynb` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmplpcfz6tz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp.AHwF9vVByx` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpptgby3lz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpiok5w3yb` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpjsivr087` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpnzojwml2` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpmz_41geh` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmptt8h2q2v` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpl9f7k6ve` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpudbpy1vc` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp3siyaylh` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmphcge23da` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp8m986cgd` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpdqfmgsyp` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpe4y3la4y` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpn7cye3r4` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpn_wj6ahu` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpbzp01f3y` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmps5l6zrl5` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpvyfflfwu` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp8mtl94j2` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpsh02nq2c` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpllfmc6yh` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmplqr2h1tb` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp5bftqv6m` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpbe_fpkx1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp60c35qjs` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpettt55aa` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpl4hmww_4` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpkz50l6gw` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpq1dudv7m` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmph8v445go` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmptb8wcwz2` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpyo_1_lqc` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp9u8yhsd0` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpe6_sfqpz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/god-correction-plan-eeogwhow` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpchvzz8ez` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpo6jyq69e` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpopoi5b8q` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpfnscj_vr` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpnlxflwdl` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp87nccc0k` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpiy6h1fm3` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmprf4a1_p0` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp2kg4nuuf` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpit3dyj3x` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpf9mqxiz4` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp7sy5kb71` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpjesqsxwj` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpuypvke4t` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpdr06pkvy` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmprc4lldhp` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpcwwp5e5z` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpez8o8hl_` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpl8athfgb` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpkcw2dsxi` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpi3mikyz1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpc33vg_jj` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpopgovh4q` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpzqek4av0` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpbkcudgs_` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpwgu82wxr` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpw8hhl1v6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp1486hp3q` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpyfslizhl` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpb0r2egf6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpi0bp6d2d` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp67x5zpa7` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpy8yeoi1z` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpvo_pysh2` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpeq2nhnfg` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpyugxbe6q` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpy0qyq9bv` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp2mv8m7wu` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpcsumq6r9` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpptpdxc4a` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpn2b9l71h` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmplzdmaplt` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp7bpefpwd` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpc91_z7v2` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpitcn0vw1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpwaggtrju` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpm0jdo97n` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp5k20steu` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmppcs6nkap` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpg7_1bny8` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp7nhti1yb` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmppvz4u3mu` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/worldarchitect.ai-er10515.Zu97a7` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmphjcdo2zo` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpz_1qogxn` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpvod1utu8` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp4i_a51cn` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpaa6v80bi` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmps4e1lprq` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpn4d18t0n` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp9j67j00p` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp87aee7fx` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp7b2y9w5j` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp057adglb` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpfsgt5rw7` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpqmbhxue6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpwsllz9w6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpf00l0di8` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.B6WowK` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.PNPUUd` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.U3tGcy` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.xPHWtF` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.NwT1hd` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmprtsbm316` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp2rj49krw` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpr_0ssqvb` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp01qbey6z` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpur8e3iwm` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpjy1ocjlo` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpwwzl9t8g` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpiktd0v6y` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpa8jt9vrc` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpzbeyfl3j` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpu8x82lto` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp6ozruapc` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpb9rr0s8m` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpgappb15p` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp6_2rsfai` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmprg0ewqwh` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpsfe9u1xz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpbm8uwono` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpr3t6gqry` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp9znf218a` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp0dp_j2vr` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/mt6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpdzz7bu_6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp9gt2201p` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpwrxibnoy` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpwrmvqdna` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp_8vj091k` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/mt5` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpk88zsp9t` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/mt4` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/pushtest` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmppalvl1z1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpws4umu19` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpv2x0k5rz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp1mw78rea` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmps9rt4dic` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpglog30cg` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp9lp9t9j_` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpit38p2ij` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp7i6fcoqa` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp_jm0kh15` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpca721f4o` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpoyvamt7z` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpixebrztm` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpylocy_y5` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpqavj8y76` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpnmzl8oun` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpa8t2jcer` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpwkfm32_i` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpli5m1bwg` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp6j9fifrz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpyr4k50gy` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp__5w44qc` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp27vqfr07` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp542j30r6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp6b_w3va7` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpcr2kehjz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp6f6_p01x` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpbqq0c03y` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp_czqp9ds` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpfcww6084` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpsn2f3h5h` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp6ht4yh0w` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpokl4i2by` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpbng122yd` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp1_d1quys` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp9y0wwsi8` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpc9cgyol6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpr8abfyek` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp57crwplx` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp3xwiik84` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpt4kci_o1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpclcl8ixx` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp7pleqd4e` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpv3clztad` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpmccbpopr` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpwdqfpwdv` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpcug14k49` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp3azpa19v` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpbs8zy8gx` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpy7n4jbtw` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmprrpjhjem` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpc8lrhzga` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmphja7a6cv` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpw39b_2r2` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp0lkhljzq` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpec5md3fo` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmplp4tkww3` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp1svu9e_s` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.8sWFwY` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/c14-selftest.6qkF7f` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp1tbxoplv` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/dm184` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpc7nj6bcz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-i256fvu4` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/world-sim-m1-thermo-adjudication.2DnbHX` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp1jwvge3p` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp8tzvhq6v` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpovdp5ar_` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpsu142d04` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmptlltbl4v` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp23zdkqwu` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpg8i57t3z` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpmcs9f4cp` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/advice-fetch-test.Y25xfW` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp22703s4q` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpoaonra0m` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpwrk2fpwk` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp6367wd5j` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp0eb803mv` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmptlc9xpxx` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpaux24s0t` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpwbuat4q4` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmplw708tti` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpbypw75ju` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpg0xnsnw6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpaa4r4sns` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp1pcq3i9u` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp_oz7c9pv` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpt7ro01bv` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpnvsud_yz` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp2ckbv3r6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpc9p6kccu` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpwu3wavum` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmplh493u9b` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp91ds4z19` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpos2cx279` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmprgqzxlh4` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpnbjhvz0r` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp38ovh6q4` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpi0sk7sth` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpqwaeh029` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpqa8g81iy` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpn4szd032` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp73sz184g` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpue52kk6k` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpix7ek4nk` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmp12jwbhtk` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmploez3zuf` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpbj2pp5wt` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/tmp/tmpbkcsvdf9` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-gg8ivcsj` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpwtryfmay` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpkmmy3uk_` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmprkxnhb1s` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpjl7ijy0t` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp6pikoa9u` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpqxh98dkv` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp3467w46y` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpbed32wj5` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpbx2euds7` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpnf4edrq5` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpc0vvp957` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpdp87ph9e` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpvxd1_uae` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpymwukm6l` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmphl0gee_d` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp7d1ut0md` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpw7qi0c7k` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpzta0eygj` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/advice-primary-pair-mggny2te` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp0bpu4c3d` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpghet24vd` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp97vsh9d6` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpvxfm0lbi` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpy3arr2ts` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpkx1yar7d` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp5nqewlkk` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp2j8c8n7_` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpyl_mfoa1` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp9nstozmg` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp1bufctjr` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpckrvz97m` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpxn04e0zp` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpf9v2h6q7` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpi46qyr98` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmp559mivlq` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpolxzq9bi` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/tmpd0wcp685` | 0.00 | 1 | reclaim | `cleanup_tmp.sh` | yes |
| `~/projects_other/claude-commands/.beads/.br_recovery` | 0.00 | 10 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects_other/disk_magician/.beads/.br_recovery` | 0.00 | 4 | reclaim | `cleanup_dev_caches.sh` | yes |
| `~/projects/jleechan-skills/.beads/.br_recovery` | 0.00 | 2 | reclaim | `cleanup_dev_caches.sh` | yes |
