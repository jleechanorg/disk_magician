---
title: Weekly launchd sweepers never fired — StartInterval starved by reboot cadence
hostname: jeffreys-macbook-pro.local
date: 2026-07-29
status: mitigated
paths:
  - ~/Library/LaunchAgents/com.disk-magician.colima-prune.plist
  - ~/Library/LaunchAgents/com.disk-magician.hermes-vacuum.plist
  - ~/Library/LaunchAgents/com.disk-magician.playwright-dedup.plist
  - ~/Library/LaunchAgents/com.disk-magician.worktree-venvs.plist
  - disk_magician repo: launchd/com.disk-magician.*.plist, src/disk_magician/launchd/com.disk-magician.*.plist
safety_rule: none (launchd scheduling bug, not a deletion-safety rule)
---

## What

Four weekly disk-reclaim sweepers — `colima-prune`, `hermes-vacuum`,
`playwright-dedup`, `worktree-venvs` — were installed 2026-07-23 with
`StartInterval=604800` (7 days) and no `RunAtLoad`. Six days later
(2026-07-29), `launchctl print gui/<uid>/<label>` showed
`last exit code = (never exited)` for all four: they had literally never
run once since install. Independently corroborated by
`/tmp/disk-magician-sweeper-health.log`, which flagged the same 4 jobs as
`[MISS]` ("log file does not exist") on both its 2026-07-27 and 2026-07-28
runs.

The 2026-07-23 install itself was already a fix for a *different* failure
mode: the original plists used `StartCalendarInterval` (Sunday 04:15) and
never fired for 16+ days because launchd drops a missed calendar window
when the Mac is asleep at the exact scheduled instant, instead of queuing a
catch-up run (see the retained comment in
`launchd/com.disk-magician.playwright-dedup.plist`). Switching to
`StartInterval` was meant to route around that.

It didn't work, for an unrelated reason: `StartInterval`'s countdown is
per-bootstrap-session state and resets on every launchd reload — which
happens at every login/reboot for a per-user `LaunchAgent`. `last reboot`
showed only 2 reboots since wtmp began 2026-07-20 (Jul 24 21:34, Jul 26
18:48). Every continuous-uptime window since the Jul-23 install (1.27
days, 1.9 days, 2.3+ days as of Jul 29) fell short of the 7-day
threshold. On a machine that reboots roughly every ~2 days, a
7-day-interval `LaunchAgent` can structurally never accumulate enough
continuous uptime to fire — independent of whether the interval mechanism
is calendar- or duration-based.

## Why it matters

These 4 jobs are the disk-reclaim sweepers for Colima Docker prune, Hermes
SQLite WAL checkpointing, the Playwright browser-cache dedup symlink farm,
and dormant worktree venv stripping. With all 4 silently dead for 6+ days
(and, per the same starvation logic, silently dead since whenever they were
first introduced under either scheduling mechanism), their reclaim volume
was zero — directly consistent with the recurring "sweepers don't keep up
with growth" pattern this mission was spawned to root-cause. This is a
different, deeper bug than the one the 2026-07-22 root-cause pass
addressed, not a regression of it.

## Guards / governance

Fixed 2026-07-29: added `RunAtLoad=true` to all 4 templates (both
`launchd/` and the `src/disk_magician/launchd/` packaged copy) and
reinstalled via `scripts/install_launchd_sweepers.sh`. All 4 scripts were
verified idempotent/safe for frequent invocation before making this change:
`playwright-dedup` is explicitly documented idempotent; `hermes-vacuum`'s
default (wired) path is a WAL checkpoint only (no risky full `VACUUM`,
which is separately guarded and not on this plist); `cleanup_colima.sh`
uses standard `docker prune` semantics; `cleanup_worktree_venvs.sh` has its
own real 14-day recency gate via `scripts/lib/worktree_recency.sh` and
just no-ops early. `RunAtLoad` gives a real backstop cadence (~every
reboot, ~2 days on this box) instead of a theoretical 7-day cadence that
never accumulates. Verified all 4 fired for the first time ever
immediately after the fix (`hermes-vacuum` and `playwright-dedup`
completed with exit 0; `colima-prune` completed but logged one
`input/output error` on a containerd blob prune — possibly related to the
known Colima sparse-disk-wedge-under-pressure issue, not yet root-caused,
see follow-up).

Open follow-up: `worktree-venvs` was observed with 2-3 overlapping PIDs
running concurrently right after the `RunAtLoad` fix (script has no
flock/mkdir-lock, unlike `disk_snapshot.sh`'s). Cause not confirmed — the
box was also under extreme, unrelated CPU load at the time (see
`extreme-cpu-load-and-ezgha-runner-oom-churn.md`), which may have produced
a false read (queued harness commands finishing late). Tracked in
`disk_magician-w7m`: re-check under normal load, add a lock if it
reproduces.

## History

- 2026-07-22 — original root-cause pass found `StartCalendarInterval`
  jobs never firing due to sleep-drops-missed-window; fixed by switching to
  `StartInterval=604800`.
- 2026-07-23 — new `StartInterval` plists installed; still starved, this
  time by reboot-resets-the-countdown, not diagnosed at install time.
- 2026-07-29 — sidekick mission (`disk_magician-7io`) found the still-zero
  run count via `launchctl print` + sweeper-health.log corroboration; fixed
  with `RunAtLoad=true`; verified all 4 jobs fired for the first time.
