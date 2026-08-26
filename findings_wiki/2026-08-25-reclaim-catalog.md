# Successful Reclaims Catalog — compiled from /ms + git history

**Compiled:** 2026-08-25
**Source 1 (real /history):** `~/.claude/projects/-Users-jleechan-projects-other-disk-magician/memory/*.md` (47+ docs)
**Source 2 (git ledger):** `~/.disk_magician_backup` (1243+ snapshot commits)
**Source 3 (brain logs):** SKIPPED per `feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records.md` — work transcripts, not cleanup records

## Reclaim events from /ms memory docs (chronological)

| Date | Reclaim | Source / Action | Memory doc |
|---|---:|---|---|
| 2026-07-20 | 126.0 GB | hardening-arc-v0241-reclaim108 | `project_2026-07-20_hardening_arc_v0241_reclaim108` |
| 2026-07-22 | 545.0 GB | disk-swarm-2026-07-22-rootcause-and-codex-5-defect | `project_2026-07-22_disk_swarm_rootcause_and_codex_5defects` |
| 2026-07-23 | 106.0 GB | ao_respawner_blocks_disk_reclaim_2026-07-23 | `feedback_2026-07-23_ao_respawner_blocks_disk_reclaim` |
| 2026-07-24 | 25.0 GB | manifest-claim-without-durable-path-is-unverifiabl | `feedback_2026-07-24_manifest_claim_without_durable_path` |
| 2026-07-27 | 52.0 GB | history-must-cover-agy-cursor-codex-not-just-claud | `feedback_2026-07-27_history_must_cover_agy_cursor` |
| 2026-07-29 | 200.0 GB | busy-teammates-dont-see-inbox-enforce-at-process-l | `feedback_2026-07-29_busy_teammates_dont_see_inbox_enforce_at_process_level` |
| 2026-07-29 | 60.0 GB | 2026-07-29-disk-full-five-root-causes-ranked | `feedback_2026-07-29_root_cause_disk_full` |
| 2026-07-29 | 833.0 GB | disk-rootcause-2026-07-29-producers-and-decisions | `project_2026-07-29_disk_rootcause_producers_and_decisions` |
| 2026-08-01 | 762.0 GB | endpoint-average-is-not-a-rate | `feedback_2026-08-01_endpoint_average_is_not_a_rate` |
| 2026-08-02 | 225.0 GB | eintr-path-string-vs-fd-relative-diagnostic | `feedback_2026-08-02_eintr_diagnostic_pathstring_vs_fdrelative` |
| 2026-08-02 | 271.8 GB | dirs-cleaner-225gib-root-cause-and-fix | `project_2026-08-02_dirs_cleaner_225gib_root_cause_and_fix` |
| 2026-08-03 | 225.0 GB | portability-three-separate-claims | `feedback_2026-08-03_portability_three_separate_claims` |
| 2026-08-21 | 537.0 GB | consult-memory-before-live-probes | `feedback_2026-08-21_consult_memory_before_live_probes` |
| 2026-08-25 | 20.0 GB | brain-logs-are-work-transcripts-not-cleanup-record | `feedback_2026-08-25_brain_logs_are_work_transcripts_not_cleanup_records` |
| unknown | 472.0 GB | MEMORY | `MEMORY` |

## Top reclaim events cited in memory docs: 28 docs with GB/GiB mentions


## Per-day reclaim velocity (rough, from memory docs)

| Period | Avg daily reclaim | Source |
|---|---:|---|
| 2026-06-13 (3-tier) | ~5 GiB/day (15.5 GB total) | `feedback_2026-06-14_disk_cleanup_three_tier.md` |
| 2026-07-12 (4 leaks) | ~10 GiB/day (40 GB /tmp accident) | `project_2026-07-12_disk_four_leak_classes_prevention.md` |
| 2026-07-15 (swing) | fd-release + colima trim | `project_2026-07-15_disk_swing_mechanisms_confirmed.md` |
| 2026-07-17 (colima fix) | ~16 GiB freed via fstrim | `project_2026-07-17_colima_regrowth_shlock_bug_and_dk2d_retention.md` |
| 2026-07-20 (hardening) | 108 GiB reclaim | `project_2026-07-20_hardening_arc_v0241_reclaim108.md` |
| 2026-07-22 (swarm) | 12 GB orphaned + VACUUM | `project_2026-07-22_disk_swarm_rootcause_and_codex_5defects.md` |
| 2026-07-23 (AO respawner) | held 100-106 GiB steady | `feedback_2026-07-23_ao_respawner_blocks_disk_reclaim.md` |
| 2026-07-29 (root cause) | 76 GiB headroom | `feedback_2026-07-29_root_cause_disk_full.md` |
| 2026-08-02 (dirs_cleaner) | 225 GiB root cause + fix | `project_2026-08-02_dirs_cleaner_225gib_root_cause_and_fix.md` |
| **Today (2026-08-25)** | ~29 GiB this session | Aside + /tmp PR scratch + Lane A pattern-extend + APFS |

## Top recurring cleanup commands (from history)

```bash
# Always safe (built-in safety gates, no env var needed):
./scripts/cleanup_antigravity_brain.sh --clean --days 14
./scripts/cleanup_dev_caches.sh --clean
./scripts/cleanup_tmp.sh --clean
./scripts/cleanup_pr_scratch.sh --clean --min-age-hours 6 --pattern {wa-*,agy_*,wt-*,ttv-*,worldai-*}
./scripts/prune_aside_sessions.py --clean --max-age-days 14
./scripts/cleanup_llm_inspector.sh --clean

# Need env var or app closure (operator OK):
# CODE_SIGN_CLONES_APPROVED=1 ./scripts/cleanup_code_sign_clones.sh --clean
# ./scripts/cleanup_colima.sh --clean  # preserves active containers
# WORKTREE_APPROVED=1 ./scripts/cleanup_worktrees.sh --clean  # 14-day gated
# AGENT_ARTIFACTS_APPROVED=1 ./scripts/cleanup_agent_artifacts.sh --clean

# Bulk driver:
disk-magician clean --clean  # safe targets; --clean for non-dry-run
disk-magician snapshot       # refresh ledger before cleanup
```
