---
title: ez-mac-runner OOM churn + extreme CPU load outpaces any periodic sweeper
hostname: jeffreys-macbook-pro.local
date: 2026-07-29
status: active
paths:
  - ~/projects_other/ez-gh-actions
  - ~/.colima
  - ~/.disk_magician_state/disk_observer.jsonl
safety_rule: none (workload/config finding, not a deletion-safety rule)
---

## What

Two related, currently-active symptoms found while investigating why disk
usage swings so hard even with sweepers running:

1. **Container churn.** `~/.disk_magician_state/disk_observer.jsonl`
   (per-few-minute samples) logged, over roughly the last 1.8 days: 919
   docker `create` events, 903 `die`, 925 `destroy`, 897 `start`, and 361
   `oom` events — averaging one container lifecycle roughly every 1.4
   minutes. All 551 OOM events across the full observer history are on
   image `ezgha-runner:latest`, spread across 6 named containers
   (`ez-mac-runner-b-1` through `b-6`), each individually OOM-killed
   68–97 times in under 2 days — i.e. roughly once every 30–40 minutes
   per runner. This is the self-hosted GitHub Actions runner fleet
   (`~/projects_other/ez-gh-actions`, 3.45 GiB on disk per the top-down
   scan) undersized on memory for its workload, getting OOM-killed,
   and immediately relaunched.
2. **Extreme host load.** Sampled twice during this session: `uptime`
   load averages swinging 33–959 across the 1/5/15-min windows, ~100%
   CPU (70.6% user + 29.3% sys), 47G physical memory used with 21G in the
   compressor. At this load, trivial commands (`grep`, `ps -p <pid>`) took
   longer than 60s to return in this session — not merely slow, genuinely
   queued behind CPU contention.

Colima's `root_allocated_kb` (the VM's sparse disk allocation) swung
between roughly 2.7 GiB and 41.6 GiB across the same window, consistent
with rapid image-layer/container-writable-layer churn growing the sparse
disk faster than the periodic in-VM `fstrim` (documented elsewhere as
requiring `colima stop && colima start` + `colima ssh -- sudo fstrim -av`
when the host wedges) can shrink it back down.

## Why it matters

This is a rate-mismatch problem, not a missing-sweeper problem: even a
correctly-firing periodic prune/trim job runs on the order of once per
reboot or once per interval-minutes, while this producer is creating and
destroying containers on the order of once per minute with a ~39% OOM
rate. No periodic sweeper design can keep pace with a producer operating
two-plus orders of magnitude faster than the sweeper's own cadence — the
fix has to be at the producer (right-size the runner's memory limit so it
stops OOM-cycling) rather than at the sweeper (cannot be swept fast
enough to matter). This is very likely a first-order contributor to the
volatile ~60 GiB peak-to-trough swings seen in `disk_observer.jsonl` over
under 2 days (802.6 GiB min to 864.5 GiB max), independent of the two
launchd scheduling bugs fixed in the same mission.

## Guards / governance

None yet — this is a workload/CI-config concern in the `ez-gh-actions`
repo (memory limit / concurrency setting for the `ezgha-runner` container
definition), outside `disk_magician`'s direct scope to fix. Reported here
as a root-cause finding and quick-win candidate, not fixed in this
mission: reducing the OOM rate (raising the per-runner memory limit or
capping concurrent runner count to fit available RAM) should be evaluated
in `ez-gh-actions`, not by adding another disk-side prune job.

The extreme host load is noted as a contributing/related observation, not
independently root-caused in this pass — plausible confounder or
consequence of the same runner churn (6 concurrently-OOMing containers
respawning is exactly the kind of load that could produce a load average
in the hundreds), but not adversarially verified as causal in this
session. Flag for a dedicated follow-up if it recurs outside of active
runner churn.

## History

- 2026-07-29 — sidekick mission (`disk_magician-7io`) found this while
  computing per-window growth rates from `disk_observer.jsonl` for the
  coverage-validated-delta lane; not fixed, reported as a quick-win
  candidate for a separate `ez-gh-actions` follow-up.
