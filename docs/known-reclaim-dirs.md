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

### C. Rooted cleaned roots, last 7 days (2026-10-13..2026-10-20)

Per-run suffixes and per-PR names collapsed (`N` = digits). GiB are `du`-style as logged or claimed, not `df` deltas. Source tag: `log` = deletion log, `claimed` = agent transcript claim (not re-measured), `memory` = memory note, `unmeasured` = no size. Registered = the root matches `config/sweeper_roots.txt` (yes / partial / no). Deletion log: 434.5 GiB across 2,985 rooted paths (top 40 below); plus ~24 GiB claimed outside the log.

| Path (rooted) | Class | GiB removed (source) | Removals | First / last (UTC) | Removed by | Regrows? | Provenance | Registered |
|---|---|---|---:|---|---|---|---|---|
| `/private/tmp/_disk_magician_archive/*` | reclaim (tool staging) | 79.23 GiB (log) | 166 | 10-13T04:17 / 10-18T17:48 | cleanup_tmp.sh(166) | n/a: own staging dir (archive then purge); origin roots in the moved… | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/*advice* (review inputs/checkouts)` | reclaim | 50.92 GiB (log ; moved-to-archive 4.13) | 2008 | 10-13T00:27 / 10-20T17:10 | cleanup_task_scratch.sh(1868), cleanup_pr_scratch.sh(102),… | yes: removed in 55 distinct hours on 8 of 8 days (10-13T00:27..10-20T… | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/*dd* (Xcode DerivedData builds)` | reclaim | 34.90 GiB (log) | 8 | 10-18T08:50 / 10-19T02:57 | cleanup_xcode.sh(8) | likely: removed on 2 days, 3 hours (10-18T08:50..10-19T02:57) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/Library/Developer/CoreSimulator` | reclaim | 32.77 GiB (log) | 25 | 10-18T16:04 / 10-19T04:20 | cleanup_xcode.sh(25) | yes (memory 10-20 + log): simulator devices recreated; deleted in 2 b… | log: ~/Library/Logs/disk-magician-deletions.log | partial |
| `/private/tmp/pr<N>* (PR scratch)` | reclaim | 32.69 GiB (log ; moved-to-archive 22.94) | 7088 | 10-13T00:27 / 10-20T17:12 | cleanup_task_scratch.sh(4599), cleanup_pr_scratch.sh(2441),… | yes: removed in 96 distinct hours on 8 of 8 days (10-13T00:27..10-20T… | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/worldai_frontend` | reclaim | 31.38 GiB (log) | 11 | 10-18T15:56 / 10-20T08:11 | cleanup_xcode.sh(10), cleanup_tmp.sh(1) | yes: iOS DerivedData/evidence refilled 10-20 GiB/h (memory 10-20; ses… | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/var/folders/*/T/tmp.*` | reclaim | 26.57 GiB (log) | 1707 | 10-13T02:51 / 10-20T17:19 | cleanup_task_scratch.sh(960), cleanup_tmp.sh(746), cleanup_… | yes: removed in 28 distinct hours on 8 of 8 days (10-13T02:51..10-20T… | log: ~/Library/Logs/disk-magician-deletions.log | partial |
| `~/*dd* (Xcode DerivedData builds)` | reclaim | 25.15 GiB (log) | 6 | 10-18T03:26 / 10-19T22:36 | cleanup_xcode.sh(6) | likely: removed on 2 days, 3 hours (10-18T03:26..10-19T22:36) | log: ~/Library/Logs/disk-magician-deletions.log | partial |
| `/private/tmp/worldai* (WA scratch)` | reclaim | 22.52 GiB (log ; moved-to-archive 10.21) | 1799 | 10-13T04:16 / 10-20T17:14 | cleanup_task_scratch.sh(1786), cleanup_tmp.sh(28) | yes: removed in 18 distinct hours on 8 of 8 days (10-13T04:16..10-20T… | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/var/folders/*/T/*advice* (review inputs/checkouts)` | reclaim | 20.05 GiB (log) | 35 | 10-13T04:16 / 10-20T17:15 | cleanup_tmp.sh(18), cleanup_task_scratch.sh(17) | yes: removed in 12 distinct hours on 6 of 8 days (10-13T04:16..10-20T… | log: ~/Library/Logs/disk-magician-deletions.log | partial |
| `/private/tmp/scene/native-trace*` | reclaim | 16.07 GiB (log ; moved-to-archive 2.38) | 235 | 10-18T17:10 / 10-20T17:12 | cleanup_task_scratch.sh(235), cleanup_tmp.sh(2) | likely: removed on 3 days, 3 hours (10-18T17:10..10-20T17:12) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `com.apple.CoreSimulator.SimRuntime.iOS-18-6 (3BB1E565-0C51-4787-A9EE-617A6AA40B36)` | reclaim | 8.23 GiB (log) | 1 | 10-19T04:20 / 10-19T04:20 | cleanup_xcode.sh(1) | unknown: single event | log: ~/Library/Logs/disk-magician-deletions.log | n/a |
| `/private/tmp/wf*/wa-* scratch` | reclaim | 7.00 GiB (log ; moved-to-archive 12.34) | 112 | 10-13T09:35 / 10-19T23:34 | cleanup_task_scratch.sh(105), cleanup_tmp.sh(40) | yes: removed in 18 distinct hours on 7 of 8 days (10-13T09:35..10-19T… | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/ipad-prN-acceptance` | reclaim | 6.87 GiB (log) | 2 | 10-18T16:47 / 10-18T16:57 | cleanup_xcode.sh(2) | unknown: single-day burst (2 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/worldai_claw` | reclaim | 4.47 GiB (log ; moved-to-archive 13.39) | 1 | 10-18T03:51 / 10-18T17:31 | cleanup_tmp.sh(4), cleanup_xcode.sh(1) | yes: 16.1 GiB removed 10-15T23:58 (ad hoc), re-removed 10-18 (log) =… | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/frozen-*` | reclaim | 3.62 GiB (log ; moved-to-archive 0.61) | 160 | 10-14T05:04 / 10-19T23:04 | cleanup_task_scratch.sh(159), cleanup_tmp.sh(3) | likely: removed on 3 days, 5 hours (10-14T05:04..10-19T23:04) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/` | reclaim | 2.37 GiB (log) | 4 | 10-18T19:57 / 10-18T19:57 | cleanup_pr_scratch.sh(4) | unknown: single-day burst (4 removals) | log: ~/Library/Logs/disk-magician-deletions.log | partial |
| `/private/tmp/world-sim-delta-review` | reclaim | 2.30 GiB (log) | 1 | 10-14T10:21 / 10-14T10:21 | cleanup_tmp.sh(1) | unknown: single event | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/verif-H` | reclaim | 1.60 GiB (log) | 1 | 10-14T05:04 / 10-14T05:04 | cleanup_tmp.sh(1) | unknown: single event | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/rvN` | reclaim | 1.40 GiB (log) | 184 | 10-19T23:26 / 10-20T00:04 | cleanup_task_scratch.sh(184) | likely: removed on 2 days, 2 hours (10-19T23:26..10-20T00:04) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/worldarchitect.ai/*advice* (review inputs/checkouts)` | reclaim | 1.37 GiB (log ; moved-to-archive 5.71) | 46 | 10-15T04:29 / 10-19T06:21 | cleanup_task_scratch.sh(46), cleanup_tmp.sh(5) | likely: removed on 3 days, 3 hours (10-15T04:29..10-19T06:21) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/projects/worldarchitect.ai` | needs-decision (non-scratch… | 1.00 GiB (log) | 33 | 10-18T20:09 / 10-19T00:36 | cleanup_dev_caches.sh(33) | likely: removed on 2 days, 2 hours (10-18T20:09..10-19T00:36) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/worldarchitect.ai/pr<N>* (PR scratch)` | reclaim | 0.87 GiB (log ; moved-to-archive 3.95) | 488 | 10-15T04:28 / 10-19T06:25 | cleanup_task_scratch.sh(488), cleanup_tmp.sh(11) | likely: removed on 3 days, 3 hours (10-15T04:28..10-19T06:25) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/disk_magician` | reclaim | 0.73 GiB (log) | 23 | 10-13T03:38 / 10-13T07:38 | cleanup_tmp.sh(23) | unknown: single-day burst (23 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/Library/Logs/dark-factory` | reclaim | 0.73 GiB (log) | 33 | 10-18T19:59 / 10-18T20:00 | cleanup_supervisor_logs.sh(33) | unknown: single-day burst (33 removals) | log: ~/Library/Logs/disk-magician-deletions.log | partial |
| `~/Documents/Codex/2026-10-12` | needs-decision (non-scratch… | 0.72 GiB (log) | 1 | 10-18T08:05 / 10-18T08:05 | cleanup_pr_scratch.sh(1) | unknown: single event | log: ~/Library/Logs/disk-magician-deletions.log | no |
| `~/projects/prN-followup` | reclaim | 0.69 GiB (log) | 3 | 10-19T04:29 / 10-19T04:29 | cleanup_task_scratch.sh(3) | unknown: single-day burst (3 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/projects/cursor-ready` | needs-decision (non-scratch… | 0.64 GiB (log) | 2 | 10-19T04:36 / 10-19T04:36 | cleanup_task_scratch.sh(2) | unknown: single-day burst (2 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/projects/ready-final-review` | needs-decision (non-scratch… | 0.64 GiB (log) | 2 | 10-19T04:40 / 10-19T04:40 | cleanup_task_scratch.sh(2) | unknown: single-day burst (2 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/world-sim-dN-startup` | reclaim | 0.62 GiB (log) | 2 | 10-13T23:35 / 10-13T23:35 | cleanup_tmp.sh(2) | unknown: single-day burst (2 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/dN-mixed-red-provenance` | reclaim | 0.62 GiB (log) | 2 | 10-14T00:38 / 10-14T00:43 | cleanup_tmp.sh(2) | unknown: single-day burst (2 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/world-sim-dN-red` | reclaim | 0.61 GiB (log) | 2 | 10-14T06:08 / 10-14T06:09 | cleanup_tmp.sh(2) | unknown: single-day burst (2 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/fmt-diag-H-yYRT` | reclaim | 0.60 GiB (log) | 1 | 10-18T15:56 / 10-18T15:56 | cleanup_tmp.sh(1) | unknown: single event | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/projects/worktree_*` | reclaim | 0.55 GiB (log) | 94 | 10-18T20:09 / 10-19T13:14 | cleanup_dev_caches.sh(94) | likely: removed on 2 days, 3 hours (10-18T20:09..10-19T13:14) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/projects/dispatch-async-review` | needs-decision (non-scratch… | 0.52 GiB (log) | 3 | 10-19T04:28 / 10-19T04:28 | cleanup_task_scratch.sh(3) | unknown: single-day burst (3 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/projects/hooks-final-er` | needs-decision (non-scratch… | 0.52 GiB (log) | 3 | 10-19T04:29 / 10-19T04:29 | cleanup_task_scratch.sh(3) | unknown: single-day burst (3 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `/private/tmp/verifN-H` | reclaim | 0.49 GiB (log) | 1 | 10-14T10:21 / 10-14T10:21 | cleanup_tmp.sh(1) | unknown: single event | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/projects/retention-advice-roundN-y_lrnfvv` | needs-decision (non-scratch… | 0.41 GiB (log) | 2 | 10-19T04:29 / 10-19T04:29 | cleanup_task_scratch.sh(2) | unknown: single-day burst (2 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/projects/retention-advice` | needs-decision (non-scratch… | 0.41 GiB (log) | 3 | 10-19T04:40 / 10-19T04:41 | cleanup_task_scratch.sh(3) | unknown: single-day burst (3 removals) | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| `~/.claude/state/same-turn-audit-implementation-0k3a79lj` | protected? (agent state; ve… | 0.40 GiB (log) | 1 | 10-14T06:49 / 10-14T06:49 | cleanup_claude_state.sh(1) | unknown: single event | log: ~/Library/Logs/disk-magician-deletions.log | yes |
| long tail: 2945 other roots (each below 0.37 GiB) | reclaim | 10.81 GiB (log) | 7851 | 10-13 / 10-20 | cleanup_task_scratch/cleanup_tmp/cleanup_pr_scratch | unknown (aggregated) | log | n/a |
| `/private/tmp/worldai_claw/*` (58 evidence dirs) | reclaim | 16.1 GiB (transcript claim; df free 17.0 -> 31.5 GiB, mixed with other activity) | 58 | 10-15T23:58 | Claude session fb8dbc20 (disk_magician lane, Opus 5.5); not… | yes: recreated and re-removed 10-18 by cleanup_tmp/xcode (log, 4.5 Gi… | `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-work… | yes |
| `~/.worktrees/*` reaper first pass | reclaim (3-day floor) | ~7 GiB (transcript claim, session 97820ec6 ts 10-20T07:23; not df-verified) | 59 removed, 110 kept (memory) | 10-20 | Claude session 97820ec6 (Sonnet 5.5) via cleanup_worktrees.… | yes: ~/.worktrees measured 117 GiB at 10-20T09:46, same as before rem… | `/Users/jleechan/.claude/projects/-Users-jleechan-projects-other-work… | yes |
| git worktree removals by worktree-remove-hook (114 rows, no sizes): `~/.worktrees/worldar… | reclaim | unmeasured (no size in guard log) | 114 | 10-13 (6), 10-15 (2), 10-19 (… | worktree-remove-hook (worktree_guard.log); several "kept:"… | yes: spicy-search/worldai_frontend/worldarchitect.ai worktrees recrea… | ~/.disk_magician_state/worktree_guard.log | yes |
| dependency strip in dormant worktrees (node_modules/target/caches) | reclaim | 0.92 GiB (transcript claim: 7 dirs, 943 MB) | 7 | 10-20 | Claude 97820ec6 via cleanup_worktree_deps.sh | unknown | session 97820ec6 ts 2026-10-20T07:23 | n/a |
| `/private/tmp` + `$TMPDIR` agent self-cleanup: ~628 distinct path families from `rm -rf`… | reclaim | unmeasured (commands carry no sizes) | 966 matching commands | 10-13 .. 10-20 | Claude, Codex and Pi agent sessions removing their own scra… | yes: same families recur every day in logs and transcripts | scan of ~/.claude/projects, ~/.codex/sessions, ~/.pi/agent/sessions (… | yes |
| iOS simulators (`xcrun simctl delete <udid>`) by agents | reclaim | unmeasured (logged simctl-delete batch is in the log table) | 29 commands (Claude) | 10-18 mostly | Claude subagents (agent-a209a8, agent-a30bab, agent-ab92e3)… | yes (memory 10-20: simulator devices refill) | e.g. session 325141e4 ts 2026-10-18T05:26; agent transcripts under ~/… | n/a |
| `/private/tmp/_disk_magician_archive` (~21.7 GB) observed gone | reclaim (tool staging) | 21.7 GB (transcript claim by another lane, ts 10-18T05:57; matches purge_archiv… | - | 10-18 | disk_magician sweepers (cleanup_tmp.sh purge_archive); that… | n/a | session 325141e4 (worldai-ios worktree) ts 2026-10-18T05:57; also lan… | yes |
| Colima VM `fstrim -av` | reclaim (host sparse disk) | unmeasured in window (fstrim commands present: Claude 4, Pi 7; 10-15T22:03 sess… | 11 commands | 10-15 .. 10-20 | Claude fb8dbc20, Pi sessions | yes: memory 10-06/10-08: CI runners re-pull the 15.5 GB ezgha image a… | session fb8dbc20 ts 2026-10-15T22:03; memory project_2026-10-08_*.md,… | n/a |
| `/private/tmp/worldai_frontend` (iOS agent DerivedData + evidence) | reclaim | memory only (qualitative): "producers refill ~10-20 GiB/h"; session 97820ec6 me… | - | 10-18 .. 10-20 | agents (iOS builds); cleanup_xcode.sh removes | yes (strongest producer) | ~/.claude/projects/-Users-jleechan-projects-other-disk-magician/memor… | yes |
| Chrome `code_sign_clone` dirs under `/private/var/folders/*/X` | protected-by-phantom (APFS… | 0 real GiB (memory 2026-10-06: 104 GiB `du`, 73 clones deleted, df +0.3 GiB); 1… | - | outside window (10-06) | n/a | n/a | memory dir above; do not count du sizes as reclaim; feedback_2026-10-… | n/a |
| `~/projects` worktrees with unmerged work (182 ahead, 49 untracked, 44 dirty at 10-08) | needs-decision | not removed; ~7.8 GB of 17 worktrees wrongly removed 10-08 (outside window, fix… | - | outside window | user approval needed for push-then-remove | unknown | memory dir above; project_2026-10-08_floor_deltas_colima_producer_and… | yes |
| `~/.worktrees/disk_magician` / `central-deletion-logging` branch docs/known-reclaim-dirs.… | info | earlier generated table from the same log (to 10-20 17:07): worldai_frontend 54… | - | 10-13..10-20 | branch feat/central-deletion-logging (unmerged) | - | git show feat/central-deletion-logging:docs/known-reclaim-dirs.md; br… | yes |

### D. Regrows fast (producers)

| # | Root | Evidence |
|---|---|---|
| 1 | `/private/tmp/worldai_frontend` (iOS DerivedData + evidence) | ~19 GiB/h measured 2026-10-20T08:13; ~20 GiB per 20 min at 17:24; 31.4 GiB removed in log |
| 2 | `~/.worktrees/*` | 117 GiB before and after the 10-20 reap (59 removed); 41 + 66 hook removals on 10-19 / 10-20 |
| 3 | `/private/tmp/pr<N>*` PR scratch | 32.7 GiB removed; removed in 96 distinct hours on 8 of 8 days |
| 4 | `/private/tmp/*advice*` review checkouts | 50.9 GiB removed; 55 distinct hours, 8 of 8 days |
| 5 | `$TMPDIR/tmp.*` | 26.6 GiB removed; 28 hours, 8 of 8 days |

Next: CoreSimulator devices (32.8 GiB) and `worldai_claw` (recreated within ~2.5 days). `/private/tmp/_disk_magician_archive` (79.2 GiB) is the tool's own staging target, not a producer. Cleanup alone cannot reach 100 GiB free; the producers need admission control.

### E. Caveats

- Log sizes are `du` upper bounds, not `df` deltas. The one df-verified figure: free space 24.9 -> 106 GiB (+81) on 10-20, offset by producers writing ~10-19 GiB/h.
- DerivedData and worktree clones can be APFS phantoms (2026-10-06 note); Chrome `code_sign_clone` `du` sizes are phantom.
- The log undercounts worktree reaps: 8 `removed-worktree` rows vs 114 hook removals and a claimed 59-worktree reap.
- Claimed sizes (16.1 worldai_claw, ~7 worktree reap, 0.9 deps) were not re-measured. 966 agent `rm`/prune commands carry no sizes.
- Source coverage: Claude and Cursor `/history` helpers returned zero hits (unverified); Codex, agy, pi and hermes partial; Claude/Pi transcripts scanned directly, Codex scan partial, agy and Cursor transcripts not scanned. jeff-ubuntu cleanups are excluded.

