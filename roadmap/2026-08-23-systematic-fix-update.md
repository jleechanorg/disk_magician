# Systematic-fix prevention architecture — 2026-08-23 update

**Companion docs:**
- `roadmap/2026-07-29-systematic-fix-architecture-sidekick.md` (prior 7-proposal scorecard)
- `roadmap/2026-07-29-disk-regrowth-rootcause-sidekick.md` (prior root cause, adv-verified 2x)
- `roadmap/2026-08-23-reclaim-plan-delta-from-floor.md` (this pass's reclaim plan)
- `findings_wiki/cursor-agent-debug-log-unbounded-growth.md` (the largest single-file producer)
- `findings_wiki/daily-snapshot-python-version-path-drift.md`
- `findings_wiki/weekly-sweepers-never-fired-startinterval-reboot-starvation.md`
- `findings_wiki/extreme-cpu-load-and-ezgha-runner-oom-churn.md`

**Resumption bead:** `disk_magician-xxv`
**Date:** 2026-08-23
**Mode:** READ-ONLY proposal only

## What this update is

The 2026-07-29 systematic-fix sidekick produced a 7-proposal scorecard
with adversarial challenges, a synthesis ("make destructive decisions
depend on more than one signal, at least one of which the
decision-maker cannot self-report"), and 4 layered target architectures.

This pass takes the synthesis as a starting point and asks the next
question: **given that 4 layers and the synthesis have been live for
~25 days while the disk still climbed +105.83 GiB (Aug 11 → Aug 22),
what specifically is missing in the implementation, and what is the
smallest first PR that exercises the spine?**

## Evidence the prior synthesis is still right (Aug 11 → Aug 22)

The +105.83 GiB gap occurred with all of these nominally live:
- 30-min snapshot job (fired; recent run_exit=0)
- 30-min observer (fired continuously)
- 30-min pressure-sweep (fired; logged 2026-08-23 01:24:34 UTC trimming
  3.8 GiB from Colima sparse disk)
- Frontier-nightly + drilldown sweepers (idle but loaded)
- 14-day worktree recency rule (multiple worktree aged-and-pruned
  entries in the shrinker table; working as designed)
- Residual-drilldown sweeper (loaded, but per `disk_magician-nea` the
  variable bug was fixed in `144845a` post-prior-plan)

The failure mode is still: **a single-signal destructive decision was
trusted and was wrong, and the cross-check the synthesis called for has
not yet been implemented.** Specifically, the largest single-file
producer in the +105.83 GiB gap is `Library/Application Support/Cursor`
(+2.19 GiB) — the unbounded cursor-agent log that the
2026-07-29 plan called out as bead `disk_magician-ax0` (operator-killed
in 02:36 PDT). The 5-GiB ledger shows it has already re-grown from
0.16 GiB (post-kill) to 2.40 GiB (today) — **the same failure mode has
recurred in the 25 days since, with the same single-signal trust gap.**

### New evidence this pass surfaced (commit e957a8a, 2026-08-22)

The cursor log L2 truncate-in-place watchdog (`scripts/watchdog_cursor_logs.sh`
+ plist template `com.disk-magician.cursor-logs-watchdog.plist.template`)
was **committed** in commit `e957a8a` (bead `disk_magician-rvf`), but is
**NOT installed** in `~/Library/LaunchAgents/` (verified by `ls` — the
two new plists, `cursor-logs-watchdog` and `fsevents-projects`, exist
as templates in `src/disk_magician/launchd/` but were never run through
`scripts/install_launchd_sweepers.sh`). This is itself a deployment
gap: the L1 env-var (`CURSOR_AGENT_DISABLE_DEBUG_LOG=1` in `~/.bashrc`)
plus the L2 size-gated watchdog script exist, but the watchdog has
never actually run on this host. The 5-GiB ledger's `Library/Application
Support/Cursor` growth from 0.16 GiB → 2.40 GiB over 11 days is direct
evidence that L1 alone is insufficient for sessions launched outside
the user's sourced shell (launchd, other users, detached tmux).

This shifts the "first PR" framing from "build the L2 layer" (already
done) to "install the L2 layer and verify it fires" — see Concrete
First PR section below.

## Method (this pass)

Brainstormed four architecturally distinct approaches via the in-session
Explore agent (read-only, full report at `/tmp/dm_audit_prevention_arch.md`,
2,246 words). Each approach was adversarially challenged against real
prior failures cited from memory files and the two sidekick reports. The
hybrid below was chosen based on the synthesis, not on a vote or an
average.

## Approaches considered

| # | Approach | Verdict | Why |
|---|---|---|---|
| A | Producer-side quota/budget gates | **REJECTED as standalone; viable as pre-filter only** | Doesn't reclaim any existing byte (the 88 GiB free ceiling is already breached); bypass risk identical to the 2026-07-29 proposal 1 critique; `host-disk-guardian` already attempted "block on threshold" and reclaims zero |
| B | Predictive pressure scoring (24h-ahead) | **VIABLE as trigger layer** | Real prior failure: 2026-08-01 linear-trend report was wrong because it missed sawtooth-with-positive-drift — pure linear forecaster would do the same; *but* a forecaster fed by per-class counters (worktree count, /tmp GiB, colima GiB, hermes GiB) and publishing its own accuracy to the ledger can be made self-correcting |
| C | APFS snapshot-anchored reclaim | **EXCLUDED — measured prior failure** | 2026-07-30 research update proved APFS local snapshots on this box sit on `disk3s1` (System, sealed), contribute <1 GiB to Data volume accounting; deleting them reclaims essentially nothing measurable in `df` |
| D | Root-cause-classified two-signal handlers (5 classes) | **SURVIVES as spine** | Directly fixes the "every layer trusts one signal" anti-pattern; the 5 classes (scratch_worktree, agent_log, apple_dirs_cleaner, colima, residual_unattributed) each have an externally-verified cross-check available today. **REVISED this pass to add a 6th class:** `class=aside_session` — the producer-attribution agent surfaced `/Users/jleechan/.aside/u/0` +11.94 GiB over 11 days (1,791 files, 2026-08-03→08-22), which is TOOL-OWNED-but-prunable. Signals: (a) Aside session mtime ≥ 30d AND (b) external cross-check via the browser process tree (`lsof +D ~/.aside/u/0` returns zero holders for retired sessions). This was MISSED from the 2026-07-29 7-proposal scorecard — a coverage gap. |

## Recommendation (hybrid)

**D as spine + B as 24h-ahead trigger + A as coarse pre-filter on the
top-3 producer classes.** C is dropped based on measured prior failure.

| Axis | Score | Reason |
|---|---:|---|
| Cost | Medium | **6** handlers + 1 forecaster + 1 budget shim (added `aside_session` class per this pass's attribution); reuses AO mailbox, frontier scanner, sweeper-health |
| Blast radius | Low | Two-signal rule means every destructive decision can be vetoed by either signal being absent |
| Time-to-effect | Fast Day-1 on `class=apple_dirs_cleaner`, `class=agent_log`, and `class=aside_session` (all three already have external cross-checks available — `lsof` and `log show`); 3-7 days for the others |
| Gaming resistance | High | Cross-check is external; producer cannot mark itself "safe to delete" |
| Observability | High | Each handler emits `(class, signal_a, signal_b, decision, reason)` to the daily ledger |

**Coverage gap surfaced by this pass:** the standard `disk_observer.jsonl`
`hot_dirs` signal is **blind to /private/tmp and Aside** — the
producer-attribution agent found the `disk_observer` missed ~75% of the
real producer set this window. The 5-GiB ledger (path-explicit) caught
them, but the observer's top-level-dir-only sampling did not. This is
itself a follow-up: `class=aside_session` and a `class=private_tmp_scratch`
handler would close the observer blind spot.

## Concrete first PR — `dm-prevent-v0.3.0-install-class-1: deploy the L2 cursor watchdog`

**Scope (smallest first PR that exercises the D-spine safely,
re-scoped after discovering the L2 layer is committed-but-not-deployed).**

- No new script — `scripts/watchdog_cursor_logs.sh` (commit `e957a8a`) is
  the L2 handler.
- Install via `bash scripts/install_launchd_sweepers.sh` with the new
  plist; verify plist lands in `~/Library/LaunchAgents/com.disk-magician.cursor-logs-watchdog.plist`.
- First run via `launchctl kickstart -k gui/$(id -u)/com.disk-magician.cursor-logs-watchdog`,
  capture stdout/stderr to confirm the script runs cleanly (no false-positive
  truncate on a 0-byte file; exit code 0).
- Run `--dry-run` once, compare its list of "would-truncate" files to the
  5-GiB ledger's `Library/Application Support/Cursor` reading; sanity check.
- Then `RunAtLoad=true` + hourly cadence from the template — the 2 GiB
  threshold is conservative given this box's 88 GiB free ceiling.
- Observe for 7 days: count dry-run `would_truncate` events; verify the
  ledger's `Library/Application Support/Cursor` reading stays below
  2.5 GiB envelope.
- Follow-up PR: add a second signal (the **two-signal rule**) — `lsof`
  zero-holders as a cross-check before truncation, so a headless
  writer that genuinely holds the file is not truncated mid-write
  (the copytruncate pattern handles this today, but an explicit
  two-signal gate makes the safety property auditable, not just
  emergent).

**Why this PR first.** It is the smallest unit of the D-spine that
exercises an *existing* L2 handler end-to-end in production, has
measurable dry-run evidence in the ledger within 7 days, and converts
the "single-signal trust" gap into a measured cross-check. No code
change is required, only the install + dry-run verification — meaning
the PR is a config + ops change, reviewable in 30 minutes, and
revertible by `launchctl bootout` + `rm <plist>`.

## Explicitly rejected mechanisms (carried over from 2026-07-29)

- Symlinking a tool-owned mutable scratch root into a central spool —
  violates this repo's own "never replace mutable state root" rule
- Self-reported liveness in a registry — `telemetry believes itself`
  trap, fixed by the two-signal rule
- Pure `find -size +5G` walk as a "hot dir probe" — same hang class as
  the 2026-07-23 `docker system df` wedge
- APFS snapshot-anchored reclaim — measured <1 GiB on System volume
  per 2026-07-30 research update

## Open follow-ups (proposed beads, not opened this session)

- `disk_magician-<new>: dm-prevent-v0.3.0-install-class-1 — deploy the L2 cursor watchdog` (the first PR above; install-only, no code change)
- `disk_magician-<new>: dm-prevent-v0.3.0-install-fsevents — deploy the new fsevents projects watcher` (sister plist also un-deployed per `e957a8a`)
- `disk_magician-<new>: dm-prevent-v0.3.0-class-1 — agent_log two-signal clearability` (the second-signal upgrade over the deployed L1+L2)
- `disk_magician-<new>: dm-prevent-v0.3.0-class-2 — apple_dirs_cleaner two-signal clearability` (signals: `log show` deleted_helper error count + batch mtime ≥48h)
- `disk_magician-<new>: dm-prevent-v0.3.0-class-3 — colima two-signal clearability` (signals: `colima status == Stopped` + sparse-disk 6h unchanged)
- `disk_magician-<new>: dm-prevent-v0.3.0-class-4 — scratch_worktree two-signal clearability` (signals: `worktree_age_days ≥ 14` + AO mailbox `merged|abandoned`)
- `disk_magician-<new>: dm-prevent-v0.3.0-class-5 — residual_unattributed two-signal clearability` (signals: frontier-scan coverage ≥70% + two EINTR-retried measurements agree within 5%)
- `disk_magician-<new>: dm-prevent-v0.3.0-class-6 — aside_session two-signal clearability` (**NEW this pass**; signals: Aside session mtime ≥ 30d + `lsof +D ~/.aside/u/0` zero holders)
- `disk_magician-<new>: dm-prevent-v0.3.0-class-7 — private_tmp_scratch two-signal clearability` (**NEW this pass**; signals: file mtime ≥ 7d + cross-check that the owning pr-analyzer / AO scratch process has exited)
- `disk_magician-<new>: dm-prevent-v0.3.0-observer-blindspot — extend hot_dirs stream to include /private/tmp + ~/.aside/u/0` (**NEW this pass**; the standard `disk_observer.jsonl` missed ~75% of real producer set this window)
- `disk_magician-<new>: dm-prevent-v0.3.0-self-inflicted — investigate `_disk_magician_archive/20260822T09*` self-write to /private/tmp` (**NEW this pass**; disk_magician itself wrote ~+2.7 GiB during archive ops — TTL/redirect investigation)
- `disk_magician-<new>: dm-prevent-v0.3.0-forecaster — Approach B predictive trigger` (consumes class-1 7-day dataset)

## Verification

- Floor+latest anchors: `python3 /tmp/ledger_floor.py` (read-only)
- Live launchd health: `disk_observer.jsonl` last entry (read-only)
- Existing 2026-07-29 scorecard: `roadmap/2026-07-29-systematic-fix-architecture-sidekick.md`
- Prior root-cause: `roadmap/2026-07-29-disk-regrowth-rootcause-sidekick.md` (adv-verified 2x)
- This pass's brainstorm report: `/tmp/dm_audit_prevention_arch.md`
