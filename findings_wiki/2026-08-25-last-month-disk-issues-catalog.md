---
title: Last-month disk-issues catalog (2026-07-26 → 2026-08-25)
hostname: jeffreys-macbook-pro.local
date: 2026-08-25
status: living reference
sources:
  - ~/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/*.md (16 last-month docs)
  - ~/.disk_magician_backup git log (last 30 days: 1 non-snapshot commit + ~1000 hourly snapshot commits)
  - roadmap/2026-08-01-disk-growth-floor-delta.md
  - roadmap/2026-08-02-research-dirs-cleaner-os-mechanism.md
  - roadmap/2026-08-02-research-eintr-resistant-size-measurement.md
  - roadmap/2026-08-23-read-only-evidence-bundle.md
  - roadmap/2026-08-23-reclaim-plan-delta-from-floor.md
  - roadmap/2026-08-23-systematic-fix-update.md
  - findings_wiki/cursor-agent-debug-log-unbounded-growth.md
  - findings_wiki/daily-snapshot-python-version-path-drift.md
  - findings_wiki/weekly-sweepers-never-fired-startinterval-reboot-starvation.md
  - findings_wiki/extreme-cpu-load-and-ezgha-runner-oom-churn.md
  - findings_wiki/cursor-agent-upstream-report.md
  - findings_wiki/2026-08-25-reclaim-catalog.md
  - findings_wiki/2026-08-25-topdown-bucket-verdict.md
  - findings_wiki/2026-08-25-snapshot-pipeline-healthy-legacy-path-stale.md
safety_rule: none (catalog / reference)
---

# Last-month disk-issues catalog — 2026-07-26 → 2026-08-25

> **Status correction (2026-08-30/31):** Empirical verification confirmed that
> the scanner has 100% full read access to all user TCC paths (`MobileSync`,
> `Mail`, `Messages`, `Containers`, `Group Containers`, `Safari`, `HomeKit`,
> `PersonalizationPortrait`, `Suggestions`) with zero permission walls.
> Total user TCC data is small (~4.6 GiB). Stop assuming parts of the disk are
> unreadable permission walls — the true system floor is active browser
> code_sign_clones (`/private/var/folders/.../X/`), APFS local snapshots, and `/private/var/db`.

Operator ask: "look at last month of /history /ms disk issues". Sources
are `/ms` (16 last-month memory docs), `/history` real-record (git log of
`~/.disk_magician_backup` + roadmap/ docs in this repo). Per
[[feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records]],
`~/.gemini/antigravity-cli/brain/<dir>/tasks/*.log` is NOT in scope
(pytest/codex/Flask transcripts, not cleanup records).

Total disk-related memory docs in window: **16** (12 feedback + 2 project
+ 2 review-meta). Plus 4 roadmap reads and 5 findings_wiki docs from
the same window.

---

## 1. Top 5 reclaim events (chronological)

| # | Date | Reclaim | Mechanism | Source |
|---|---|---:|---|---|
| 1 | 2026-07-26 16:49–17:36 PDT | **+60 GiB free** (60 → 120) | `disk_magician/scripts/pressure_sweep.sh` manual run with `LARGE_TMP_APPROVED=1 TMP_WORKTREES_APPROVED=1 cleanup_tmp.sh --clean --large` — 529 paths / 52 GiB in the sweep itself, ~60 GiB after deducting concurrent regrowth | `feedback_2026-07-29_root_cause_disk_full.md` § "Why the previous /learn session didn't catch this earlier"; bead `disk_magician-y7t` |
| 2 | 2026-07-29 (first firing after fix) | **~26.7 GiB** | 4 weekly sweepers (colima-prune, hermes-vacuum, playwright-dedup, worktree-venvs) got `RunAtLoad=true` after sitting unfired since install (2026-07-23) — fired for the first time ever, `runs=1`/`exit 0` | `project_2026-07-29_disk_rootcause_producers_and_decisions.md` "Fixed + deployed"; `findings_wiki/weekly-sweepers-never-fired-startinterval-reboot-starvation.md` |
| 3 | 2026-08-02 | **+172.4 GiB free** (99.4 → 271.8) | `/private/var/dirs_cleaner` 225.3 GiB reclaimed via `sudo -n find -mindepth 1 -delete` batch-by-batch — 9 batches (oldest mtime 2026-07-11); confirmed `du -sh` 0B after | `project_2026-08-02_dirs_cleaner_225gib_root_cause_and_fix.md`; `roadmap/2026-08-02-research-dirs-cleaner-os-mechanism.md` |
| 4 | 2026-08-22 (with floor→latest measurement 08-11→08-22) | **−40.47 GiB passive** (Colima datadisk only) | `com.jleechanorg.disk-magician-pressure-sweep` in-VM `fstrim -av` masked ~38% of real gross growth in the 30-min sweep job — last fired 2026-08-23 01:24:34 UTC, trimmed 3.8 GiB that single run | `roadmap/2026-08-23-read-only-evidence-bundle.md` § "Passive reclaim masking real growth"; `roadmap/2026-08-23-reclaim-plan-delta-from-floor.md` |
| 5 | 2026-07-29 ~02:30 PDT | **45.4 GiB single file** | Cursor-agent session log PID 95634 — killed by operator (operator decision pending → executed); cursor-agent debug log unbounded growth class | `findings_wiki/cursor-agent-debug-log-unbounded-growth.md`; bead `disk_magician-ax0` |

**Reclaim total observed: ~344 GiB across 5 events** (note: items 1+3+4 partially overlap temporally; net 30-day delta is ~+105.83 GiB floor→latest, see §2 #2).

---

## 2. Top 5 structural discoveries (named the gap, no immediate fix)

| # | Date | Discovery | Citation |
|---|---|---|---|
| 1 | 2026-07-29 | **5-producer structural taxonomy: ~76 GiB reclaimable headroom without touching cache/.gemini** — agent venv bloat (~25 GiB), abandoned AO+Claude parents under `~/.worktrees` (~30 GiB), unowned `/private/tmp` scratch (~8.4 GiB), Antigravity `~/.gemini` (~12.7 GiB), `.git` history bloat (~6 GiB). Five fixes queued as separate beads, none fixed in-place because each is multi-line policy surface | `feedback_2026-07-29_root_cause_disk_full.md` § "Five root causes (ranked)"; bead `disk_magician-7v3` |
| 2 | 2026-08-01 | **Sawtooth + baseline + one-time spike decomposition** — 115.9 GiB single-day swing (Colima fstrim/refill cycle, self-correcting), 86-102 GiB genuine 14-day accumulation (floor 720 GiB @ 07-19 → 806-822 GiB @ 08-01), +28.37 GiB / −21.09 GiB one-minute spike at 2026-08-02T00:30-00:58Z. Original "+3.2 GiB/day" headline REFUTED — reproduced range is −4.20 to +1.71 GiB/day depending on bucketing/estimator | `roadmap/2026-08-01-disk-growth-floor-delta.md`; companion doc to `feedback_2026-08-01_endpoint_average_is_not_a_rate.md` |
| 3 | 2026-08-02 | **291 GiB residual** = TCC/SIP floor + APFS container min-size pinning + Mail/Messages EINTR-blocked paths — NOT a hidden consumer, a structural permission wall that the non-FDA shell used for that historical audit could not measure. Monitoring collapsed under pressure (snapshot coverage 1%, frontier 0% for 3 nights) | `project_2026-07-29_disk_rootcause_producers_and_decisions.md`; `roadmap/2026-08-02-research-persistent-eintr-root-cause.md` (Endpoint Security AUTH-event root cause for Mail/Messages/MobileSync) |
| 4 | 2026-08-23 | **Hidden producer tail: `/private/tmp` aggregate +45.75 GiB (largest single SAFE class)** + `~/.aside/u/0` +11.94 GiB (1,791 Aside session files 2026-08-03→08-22, missing from 2026-07-29 7-proposal scorecard) + `_disk_magician_archive/20260822T09*` self-inflicted ~+2.7 GiB. **`disk_observer.jsonl` `hot_dirs` is BLIND to /private/tmp and Aside** — missed ~75% of real producers in this window | `roadmap/2026-08-23-systematic-fix-update.md` § "New evidence"; `roadmap/2026-08-23-reclaim-plan-delta-from-floor.md` "Critical observation #1/#2/#3" |
| 5 | 2026-07-29 | **Cursor-agent debug session logs have NO logging config** (no log-level flag, no rotation, no disable) — 45 GB / 18.5 GiB/day per PID. Same failure class: opencode single log hit 74.8 GiB (issue #12934, closed "not planned"); claude-code debug logs 20+ GiB recursive slow-op-logging (issue #16093, closed "not planned"). Vendor-declined across the board | `findings_wiki/cursor-agent-debug-log-unbounded-growth.md` § "Known-issue class"; `findings_wiki/cursor-agent-upstream-report.md` |

---

## 3. Top 3 tooling/script bugs we shipped and had to fix

| # | Bug | Symptom | Fix | Source |
|---|---|---|---|---|
| 1 | **`com.jleechan.user-scope-disk-snapshot.plist` ProgramArguments hardcoded `python3.13` site-packages path** | Daily 4am growth-tracking snapshot failing with `last exit code = 78` (EX_CONFIG) every day since 2026-07-25 (4 days stale); mtime-based staleness went undetected because file existed + had valid schema | Hardcoded path → stable-entrypoint resolution; user_scope `19065979d` | `findings_wiki/daily-snapshot-python-version-path-drift.md`; bead `disk_magician-3fi` |
| 2 | **4 weekly sweepers installed 2026-07-23 with `StartInterval=604800` (7d) and no `RunAtLoad`** | `launchctl print` shows `last exit code = (never exited)` for all 4 jobs; `/tmp/disk-magician-sweeper-health.log` flagged `[MISS]` on consecutive days (2026-07-27, 2026-07-28). 16+ days silent on the prior `StartCalendarInterval` due to launchd dropping missed-window when Mac is asleep at the exact instant | `RunAtLoad=true` added to all 4 templates; on first firing reclaimed ~26.7 GiB. Original causal story ("StartInterval countdown resets on reboot") REFUTED — only ~5.5d into 7d interval at observation, so never-fired was the trivial null; RunAtLoad fix is independently correct regardless | `findings_wiki/weekly-sweepers-never-fired-startinterval-reboot-starvation.md`; `feedback_2026-07-29_never_fired_needs_interval_elapsed_check.md` |
| 3 | **`/private/var/dirs_cleaner` accumulation: Apple's own `deleted_helper.nuke_dir` (via `removefile()`) hits ENAMETOOLONG on one pathological filename and aborts the ENTIRE purge pass every single time** | 225 GiB orphaned staging content invisible to every normal `du`/`ls`/`frontier-scan` (root-owned, non-privileged tools can't list). 86 identical `nuke_dir: removefile error ... File name too long` failures in a single afternoon 2026-08-02 | `sudo -n find /private/var/dirs_cleaner/<batch> -mindepth 1 -delete` batch-by-batch, oldest first (uses fd-relative `unlinkat()`, sidesteps the path-length bug). Fix is NOT permanent — `deleted_helper` is event-triggered and will re-stage; need the same procedure next time it reaccumulates | `project_2026-08-02_dirs_cleaner_225gib_root_cause_and_fix.md`; `roadmap/2026-08-02-research-dirs-cleaner-os-mechanism.md` |

**Honorable mentions** (each their own category):
- `feedback_2026-07-29_launchd_processtype_interactive_for_daemons.md` — `ProcessType: Background` reaps daemons when spawning shell exits, even with `KeepAlive { SuccessfulExit: false }` (qdrant case; fix `ProcessType: Interactive`).
- `feedback_2026-08-03_portability_three_separate_claims.md` — `.beads/` blanket gitignore shadowed nested `.gitignore`, **entire 38-issue bead database was machine-local-only** since repo inception; `br sync --status` falsely reported "In sync"; fix commit `48c31a1`.
- `feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records.md` — `/history` brain logs are pytest/codex/Flask session transcripts, NOT cleanup records; corrected the catalog source itself.

---

## 4. Recurring operator friction

| Friction | Manifestation | Source |
|---|---|---|
| **Teammate SendMessage delivery lag** | 4 verdict messages stalled 10+ min during 2026-08-01 disk mission while sidekick STATE.md kept reporting "BLOCKED: await lens verdicts" — even though a later message (lens-2 verdict) had arrived. Send-success ≠ processed | `feedback_2026-08-01_teammate_sendmessage_lag_resend_inline.md` |
| **Mid-mission scope changes don't reach busy teammates** | 2026-07-29 save-200G mission: operator switched to read-only at 04:33; mid-turn sidekick never saw the order and at 04:49 was caught RUNNING `dedup_hermes_prompts.sh --apply` + ~2.6 GiB safe-class deletions. Supervision caught it via `pgrep` for `--apply\|--clean\|prune` + direct `kill`, NOT via message | `feedback_2026-07-29_busy_teammates_dont_see_inbox_enforce_at_process_level.md` |
| **Cursor-agent debug log unbounded** | Always-on per-session log, no rotation, no size cap. Pathological verbosity (`commitScoring` iterates every commit in repo history at ~100 commits/sec, 1-2 log events/commit; amplified on rewritten histories — worldarchitect.ai 9000+ commits double-logs). Headless sessions parked in bash for days → file compounds without bound | `findings_wiki/cursor-agent-debug-log-unbounded-growth.md` |
| **ez-mac-runner OOM churn outpaces any sweeper** | `disk_observer.jsonl` over 1.8 days: 919 docker `create`, 903 `die`, 925 `destroy`, 897 `start`, **361 OOM** events on image `ezgha-runner:latest` (full-history OOM total 547 across 6 named containers `ez-mac-runner-b-1..b-6`, b-5 alone hit 120 OOMs, ~once every 23 min). Self-hosted runner fleet undersized on memory, getting OOM-killed and relaunched | `findings_wiki/extreme-cpu-load-and-ezgha-runner-oom-churn.md` |
| **Extreme host load → trivial commands queue** | `uptime` load averages 33–959 across 1/5/15-min windows, ~100% CPU (70.6% user + 29.3% sys), 47G physical used, 21G in compressor. `grep`, `ps -p <pid>` took >60s. No periodic sweeper can keep pace with a producer operating at once-per-minute container churn | `findings_wiki/extreme-cpu-load-and-ezgha-runner-oom-churn.md` |
| **Endpoint average is not a rate** | "Confirm ~+3.2 GiB/day" from team-lead → sidekick ran the instruction exactly, OLS swung −4.20 to +1.71 GiB/day depending on UTC-vs-PDT bucketing and OLS-vs-endpoint choice. Step-change + oscillation processes have no single daily rate | `feedback_2026-08-01_endpoint_average_is_not_a_rate.md` |
| **Busy teammates also SWITCH BRANCHES under you** | `feedback_2026-07-18_same_tree_concurrent_agent_detection_protocol.md` (referenced in window; not fresh write); re-check `git branch --show-current` in same command as every commit | (cross-window) |

---

## 5. Most-referenced memory doc

**`feedback_2026-07-29_root_cause_disk_full.md`** (also known as
"2026-07-29-disk-full-five-root-causes-ranked") wins on raw cross-reference
count within the 30-day window:
- Cited by `project_2026-07-29_disk_rootcause_producers_and_decisions.md` (the verified sidekick bead)
- Cited by `feedback_2026-07-29_launchd_processtype_interactive_for_daemons.md` (See also)
- Backed by bead `disk_magician-7v3` (full du sheet attribution)
- Operationally referenced by 2026-08-23 read-only pass as the baseline producer taxonomy

**Runner-up:** `feedback_2026-08-21_consult_memory_before_live_probes.md` —
newest, cross-referenced by `feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records.md`
and directly cited by the 2026-08-23 read-only evidence bundle as the
"methodology correction" that named the 213.9 GiB TCC/SIP floor. Likely
to overtake as more recent passes cite it.

**Most-referenced roadmap doc:**
`roadmap/2026-08-23-read-only-evidence-bundle.md` — the comprehensive
2026-08-23 pass documents the +105.83 GiB floor→latest gap, all 4
launchd jobs healthy, drift check deployed `~/.local/share/uv/tools/disk-magician/`
byte-for-byte matches repo `src/disk_magician/`, and the producer-attribution
agent's full report (174 lines, refined post-subagent-completion).

---

## Cross-reference map (last month)

```
project_2026-07-29_disk_rootcause_producers_and_decisions.md
    ├── "headline root cause" (AO/CI /tmp 23-25 GiB/day gross churn)
    └── feedback_2026-07-29_root_cause_disk_full.md
            ├── 5-producer taxonomy (~76 GiB headroom)
            └── feedback_2026-07-29_launchd_processtype_interactive_for_daemons.md

project_2026-08-02_dirs_cleaner_225gib_root_cause_and_fix.md
    ├── /private/var/dirs_cleaner +225.3 GiB (Apple nuke_dir ENAMETOOLONG bug)
    └── feedback_2026-08-02_eintr_diagnostic_pathstring_vs_fdrelative.md
            (general diagnostic: path-string vs fd-relative tools)

roadmap/2026-08-01-disk-growth-floor-delta.md
    ├── sawtooth + baseline + spike decomposition
    └── feedback_2026-08-01_endpoint_average_is_not_a_rate.md
            (the +3.2 GiB/day headline REFUTED)

roadmap/2026-08-23-{read-only-evidence-bundle,reclaim-plan-delta-from-floor,systematic-fix-update}.md
    ├── +105.83 GiB floor→latest gap (Aug 11 → Aug 22)
    ├── /private/tmp +45.75 GiB (largest SAFE class) + Aside +11.94 GiB (NEW class)
    ├── _disk_magician_archive self-inflicted wound
    └── feedback_2026-08-21_consult_memory_before_live_probes.md
            └── feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records.md
```

---

## Take-aways for the next 30 days

1. **The single largest SAFE class right now is `/private/tmp` aggregate (+45.75 GiB), not Colima, not venv, not worktree.** The 2026-07-29 7-proposal scorecard missed the hidden tail (33 other `pr9XXX-*` + `pr-XXX-*` paths in the tail, ~+38 GiB beyond the visible tip).
2. **Aside session files (1,791 files, +11.94 GiB) are a NEW class.** Missing from prior taxonomy. Cross-check signal: `lsof +D ~/.aside/u/0` returns zero holders for retired sessions.
3. **The disk_magician tool is its own producer.** `_disk_magician_archive/20260822T09*` +2.7 GiB written by disk_magician itself during its own archive operations.
4. **`disk_observer.jsonl` `hot_dirs` is structurally blind to /private/tmp and Aside** — observer missed ~75% of real producers in this window. Needs observer coverage extension.
5. **All 4 launchd jobs healthy on cadence** (2026-08-23 read-only audit) — the prevention architecture from 2026-07-29 is actually working at the cadence level; the +105.83 GiB net is the producer side outrunning the reclaim rate, not a sweeper failure.
6. **RunAtLoad is the durable fix for any sweeper that can't tolerate multi-day startup silence** — `StartInterval` + reboot cadence + sleep-dropped calendar windows are three independent failure modes, all bypassed by `RunAtLoad=true`.
7. **Path-string tools (`du`, `nuke_dir`/`removefile`) hit ENAMETOOLONG deterministically per path; fd-relative tools (`find -delete`, `os.scandir`) sidestep it.** When a deletion tool fails consistently on the same subtree, switch tool class before retrying the same one.
