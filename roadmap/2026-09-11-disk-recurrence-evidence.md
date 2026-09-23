# Disk-recurrence evidence bundle — 2026-09-11 (live, pre-swarm)

All numbers measured 2026-09-11 ~12:30 PDT unless dated. Host: jeffreys-macbook-pro, Data volume 926 GiB.

## A. Fleet liveness (Step -1)
- `./disk_magician.sh check-launchd-fleet` → 16/16 loaded and valid.
- `launchctl list` last-exit: sweeper-health=1, pressure-sweep=1, frontier-root=2, colima(homebrew)=1; rest 0.
- Snapshot job commits to `~/.disk_magician_backup` every ~35 min (last 53268ce 2026-09-11T19:22Z). Collector alive.

## B. 30-day df trend (min `disk_used_gb` per day, from snapshot history)
```
08-10 726 | 08-11 726 | 08-12 762 | 08-13 823 | 08-14 813 | 08-15 761 | 08-16 824 | 08-17 838
08-18 815 | 08-19 834 | 08-20 844 | 08-21 845 | 08-22 828 | 08-23 826 | 08-24 851 | 08-25 819
08-26 757 | 08-27 819 | 08-28 810 | 08-29 814 | 08-30 794 | 08-31 780 | 09-01 767 | (09-02..04 no snapshots: plist corruption)
09-05 756 | 09-06 749 | 09-07 753 | 09-08 768 | 09-09 801 | 09-10 853 | 09-11 823 (free 66)
```
Shape: sawtooth, +60–100 GiB per 3–6 days, every reset is a manual/operator-driven cleanup (catalog: 07-26 +60, 07-29 +27, 08-02 +172, 08-25 +98, 08-31 +102). Floor (lowest of last 14 daily) = 749 GiB on 09-06; gap now = +74 GiB.

## C. Measurement layer is blind to where growth lives
- Latest snapshot: coverage 19.6%, residual 661 GiB, `measurement_status: partial`, measured 61/75 paths, `measurement_path_max_seconds: 20`, budget 1500s.
- `timeout_keys` (never sized): gemini_root, library_caches, library_app_support, library_containers, nvm, projects_other, projects_reference, repos, worktrees_dot, tmp_private, private_var, opt, library_mail, **projects**.
- Fresh bounded `du -sk` on those same paths finished in <90s each (except ~/projects, ~200s): the disk is not the problem; the 20s per-path cap is.
- `ledger/topdown-5g.json` last modified Aug 31 04:02; `topdown-5g.status.json` = `partial / coverage_incomplete` (17 reachable roots, 11 measured, 3 unfinished).
- `frontier-root` job: `can't open file '/usr/local/libexec/disk-magician/disk_frontier_scan.py'` (path doesn't exist) — every run exit 2. Open bead disk_magician-4y6.
- `disk_observer` DEFAULT_HOT_DIRS = .codex .cache .aside .ollama .openclaw .hermes .gemini /private/tmp /private/var/folders Cursor Aside Library/Caches; step_events show `.gemini`, `/private/tmp`, `/private/var/folders`, `.cache` = null (timed out) on every day sampled. `~/roadmap` and `~/projects` are not hot dirs and not ledger keys.

## D. Where the bytes actually are (frontier nightly 2026-09-11T10:52Z, 66,777 buckets ≤5 GiB, sum 926 GiB; plus live du)
Aggregate by root (GiB): ~/projects 199.3 · ~/roadmap 166.3 · ~/Library 88.8 · /private/var 81.4 · /private/tmp 75.7 (30.3 live after sweep) · ~/.codex 51.6 (67.3 live) · /opt/homebrew 16.2 · ~/.gemini 16.2 · ~/.dark-factory 15.2 · ~/Pictures 14.2 · ~/projects_other 14.1 · ~/projects_reference 13.6 · ~/project_worldaiclaw 10.5 · ~/.claude 9.3 · ~/.worktrees 8.2

Drill-downs (live):
- **~/roadmap/worldarchitect.ai/evidence/gemini-memory/20260910-study-yxwrg0su = 161.5 GiB, mtime 1d** — ONE study dir, written 09-10 by an `advice-primary-pair-*-opus` agent session (cwd under TMPDIR). Largest single bucket on disk (~17%). 3 files git-tracked in ~/roadmap; rest untracked. Not in any hot-dir, ledger key, sweeper, or safety rule. Explains 09-09→09-10 jump (801→853).
- /private/var/folders/j0/.../T = 48.8 GiB: agent scratch trees (astra-resume 3.8, tmp.* 1.6 each ×N, agy_home_* 1.6 ×6, memory-study-arms 1.9) all 0–2d old. `X/com.google.Chrome.code_sign_clone` = 24.8 GiB (known finding; killswitch doc exists).
- /private/tmp: leveling-fix-20260907 14.9 GiB (0d), worldarchitect.ai 1.9, ~30 AO/pair worktrees ~0.4 GiB each all <1d. pressure_sweep step 1 `cleanup_tmp.sh` → rc=124 (timeout) on 2026-09-11T18:32Z; step 2 colima reclaimed 0.
- ~/projects: worldarchitect.ai 30.6 (0d), worktree_cache_full_redesign 12.6 (4d), user_scope 12.4, dark-factory 6.5, astra-home-trial 5.1, ~10 worktree_* dirs 1.2–2.1 GiB aged 3–27d.
- ~/.codex: sessions 48.8 + thread_history_1.sqlite 7.6 + logs_2.sqlite 5.3 + state_5.sqlite 2.6 = never-delete list; hot-dir series 49.0 (08-26) → 67.3 (09-11) = +1.2 GiB/day monotonic.
- ~/.gemini/antigravity-cli: brain 11.2, scratch 2.7, conversations 2.0.

## E. Sweeper/cleanup layer defects (live logs)
- sweeper-health 09-11: 4 MISS (colima-prune, hermes-vacuum, playwright-dedup, worktree-venvs: "log file does not exist") → auto-repair reinstalled all 4 → still FAIL. These 5 plists log to `/tmp/disk-magician-*.log`; macOS purges /tmp files unaccessed >3d and this repo's own cleanup_tmp runs there → weekly jobs' logs vanish before next run → health check MISS → daily reinstall (bootout/bootstrap) = the "flapping" observed 09-06.
- pressure-sweep (every 1800s, gate free<40G): cleanup_tmp.sh times out (rc=124); colima prune/fstrim frees 0 (VM is 4.1 GiB). The only 30-min reclaim path yields ~0.
- cleanup-docker (com.jleechan.cleanup-docker) errors in tail, last write 5d.
- Retention gates protect everything <24h (LARGE_TMP_ACTIVE_HOURS) / <7d (worktrees) — but growth is produced and consumed inside 0–2d, so mtime-gated sweepers can never touch the active producers.

## F. Open beads (br)
disk_magician-4y6 P1 provision root-owned full-attribution snapshot runner · -949 flaky test · -igc safety_min_stale_days never called · -m77 aside hardlink hazard · -x78 observer du before ledger cache · -qap (in_progress) cleanup_pr_scratch rm -rf abort · -6oh (in_progress) /wa review transport.

## G. Prior-30d memory/findings (already known, recurring)
- 2026-09-06 memory: "why do I keep re-explaining" answer = playbook never checked automation liveness (fixed: check_launchd_fleet as Step -1) + fleet flapping unresolved (cause not pinned).
- findings_wiki 08-25 catalog: 5 producer taxonomy (venvs, ~/.worktrees, /private/tmp, brain, .git); cursor-agent unbounded logs; weekly sweepers never fired (RunAtLoad); dirs_cleaner ENAMETOOLONG 225 GiB; /tmp aggregate +45 GiB hidden tail.
- 08-31 floor-delta doc: 104 GiB in 4 reservoirs (tmp archive 52, Cursor snapshots 28, openclaw backups 17, cargo target 7) — all one-time purges, guards = "periodic review"/"on demand" (i.e. human).
