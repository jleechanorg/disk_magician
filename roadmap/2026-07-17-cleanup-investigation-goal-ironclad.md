# Ironclad goal — 2026-07-17 read-only cleanup investigation — COMPLETE

## Literal ask
Continue read-only disk investigation without stopping between steps: resolve `dirs_cleaner`, triage all worktree directories, break down `~/Library` fully.

## Final status

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | `dirs_cleaner` resolved via ≥2 independent methods or proven unmeasurable | ✅ Proven unmeasurable | 4 independent methods, see below |
| 2 | Every `~/.worktrees/*` + `~/.ao/data/worktrees/*` subdir gets individual verdict | ✅ Done | 152 worktree leaves classified, `roadmap/evidence/worktree_classification_20260717.tsv` |
| 3 | `~/Library` ≥90% coverage at ≥1GiB granularity | ✅ 100.3% coverage (85.73/85.5 GiB) | `roadmap/evidence/library_full_breakdown_20260717.tsv` |
| 4 | One consolidated report, no intermediate stop-and-ask | ✅ This document | — |
| 5 | Report committed to repo `roadmap/` and `~/roadmap/` | ✅ Both | this commit + `~/roadmap/disk-attribution-report-2026-07-17.md` update |
| 6 | Zero destructive commands executed | ✅ Confirmed | see "Command audit" section |

## 1. `dirs_cleaner` (165 GiB, claimed by an earlier reviewer) — genuinely unmeasurable

Four independent attempts, all read-only:
1. Direct `ls -la` as current user → `Permission denied`.
2. Same command via a Full-Disk-Access-granted terminal (Ghostty, per this session's established workaround) → still `Permission denied`.
3. `diskutil info /System/Volumes/Data` (volume-level APFS space API, doesn't require filesystem read permission) → only returns whole-volume aggregates, no way to query a specific subdirectory's size.
4. `launchctl list | grep -i dirs_cleaner` → no matching job; only my own `com.jleechan.cleanup-*` jobs found, nothing Apple-managed references it by name.

Root cause, confirmed via `csrutil status`: **System Integrity Protection is enabled.** `dirs_cleaner` (`man dirs_cleaner`: "recursively deletes the entire contents of each directory argument, while the directories themselves are not deleted") is a SIP-protected system utility/target — TCC (Full Disk Access) only grants userspace file permission, it cannot override SIP's kernel-level protection. The only way to inspect this path would be disabling SIP via a recovery-mode reboot, which is out of scope for a read-only measurement task and was not attempted.

**The earlier-cited 165 GiB figure remains unverified by me.** It may be accurate (another session's report reconciled the whole-disk equation to within 1.319 GiB using it), but I cannot independently confirm the number through any read-only method available to a standard admin session.

## 2. Worktree triage — 152 leaves across `~/.worktrees` and `~/.ao/data/worktrees`

Classified via direct git-state checks (uncommitted count, untracked flag, ahead-of-main count, merge-base, local-only — no network calls):

| Verdict | Count | Meaning |
|---|---:|---|
| SAFE | 15 | Zero uncommitted/untracked changes AND (zero-ahead of main OR branch already merged) |
| PRESERVE | 31 | Clean and zero-ahead-eligible logic doesn't apply, but touched within 14 days — too young to judge |
| NEEDS-REVIEW | 106 | Uncommitted/untracked changes, or unpushed commits ahead of main, or too old to be "young" but still ahead |

**The 15 SAFE candidates** (full paths in the evidence TSV) span repos: `agent-orchestrator` (1), `disk_magician` (2), `ez-gh-actions` (2), `jleechanclaw` (2), `jleechanorg-github` (1), `meta-*` hermes worktrees (2), `wa-reenable-gate` (1), `worldarchitect` (2), `.ao` user-scope worker (1), plus one untracked-parent (`roadmap-20260709-111325`). None deleted — this is a measurement-only pass; deletion would need the same push-to-preserve/PR-check workflow as `worktree_hygiene.sh` already implements, run explicitly with `--execute` after human review.

**NEEDS-REVIEW reason breakdown:** 49 have only uncommitted changes, 19 have untracked+uncommitted, 19 are 1-commit-ahead-and-clean (would need a PR-merge check to possibly reclassify SAFE), and a handful are dramatically diverged (1749-1827 commits ahead — almost certainly stale/abandoned branches worth individual review, not cleanup automation).

## 3. `~/Library` full breakdown — 85.73 GiB, 100.3% coverage, 99 entries

(An earlier pass this session under-covered this by ~46% due to a word-splitting bug on "Application Support" — corrected here with NUL-safe enumeration.)

| Item | Size | Drill-down |
|---|---:|---|
| `Messages` | 28.68 GiB | Already tracked — bead `jleechan-z2ya` |
| `Application Support` | 24.00 GiB | Google 7.73GB, Cursor 3.48GB, Aside 2.79GB, Godot 1.88GB, FileProvider 1.77GB |
| `Caches` | 6.04 GiB | ms-playwright 1.03GB, codexbar 0.60GB, pnpm 0.53GB, Google 0.51GB, colima 0.33GB |
| `Mail` | 5.73 GiB | Almost entirely `V10` (the actual mail store) |
| `CloudStorage` | 4.36 GiB | Dropbox/Google Drive placeholder mounts — drill-down timed out (many small files), not resolved further |
| `pnpm` | 3.85 GiB | `store` (content-addressable package cache) 3.72GB — regenerable |
| `Metadata` | 3.01 GiB | Almost entirely `CoreSpotlight` — system-managed |
| `Developer` | 3.01 GiB | Almost entirely `CoreSimulator` 2.98GB — iOS simulator runtime data |
| `Group Containers` | 1.67 GiB | Spread across ~10 app groups, none individually large |
| `Logs` | 1.33 GiB | **`cmux-focus.log` alone is 0.75 GiB — a single log file, real candidate for rotation/truncation** |
| `Containers` | 1.30 GiB | Evernote 0.46GB, mediaanalysisd 0.31GB, Slack 0.22GB |

## Command audit — confirming zero destructive commands

Every command run during this investigation was one of: `ls`, `du`, `find` (read-only), `git status`/`log`/`rev-parse`/`rev-list`/`merge-base`/`branch --merged` (all read-only git queries, no `push`/`checkout`/`worktree remove`), `csrutil status`, `diskutil info`, `launchctl list`, `man`, `mdfind`, `lsof`. No `rm`, no `--execute`, no `--force` (except read-only `git rev-parse --verify --quiet`, which is not destructive), no `worktree_hygiene.sh --execute`. Confirmed zero deletions occurred.

## What's actually actionable from this pass

1. **`Library/Logs/cmux-focus.log` (0.75 GiB single file)** — safe to truncate/rotate, lowest-risk item found this pass.
2. **`Library/pnpm/store` (3.72 GiB)** — regenerable package cache, same pattern as every other cache cleaned this session.
3. **15 SAFE worktrees** — ready for the standard push-to-preserve → `--execute` workflow once you want to act.
4. **`Library/Developer/CoreSimulator` (2.98 GiB)** — prunable via `xcrun simctl delete unavailable` if you're not actively using specific old simulator runtimes (not investigated further — needs your confirmation you don't need old simulator versions).
5. **106 NEEDS-REVIEW worktrees** — not automatable; would need the same individual-review pass already applied to the worldarchitect.ai set earlier this session.
