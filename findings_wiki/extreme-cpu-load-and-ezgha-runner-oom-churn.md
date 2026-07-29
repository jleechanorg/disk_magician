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
   minutes. An adversarial re-check independently reproduced these almost
   exactly (919/903/925/897/359) plus the full-history OOM total (547, all
   on image `ezgha-runner:latest`, spread across exactly 6 named
   containers `ez-mac-runner-b-1` through `b-6`). **Corrected per-container
   range** (an earlier draft said 68–97): actual range is **68–120** OOMs
   per container in under 2 days — `ez-mac-runner-b-5` alone hit 120,
   roughly once every 23 minutes. This is the self-hosted GitHub Actions
   runner fleet (`~/projects_other/ez-gh-actions`, 3.45 GiB on disk per
   the top-down scan) undersized on memory for its workload, getting
   OOM-killed, and immediately relaunched.
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

This is a real CI-reliability problem: container lifecycle churn on the
order of once per minute with a high OOM rate is not healthy, regardless
of disk impact, and no periodic sweeper design could keep pace with a
producer operating that fast if it *were* the disk driver.

**Adversarial review correction (2026-07-29):** an earlier draft of this
finding asserted this churn "drives disk growth" and called fixing it
"the single highest-leverage disk fix." That causal claim did **not**
survive adversarial review — the adjacent measured number (`colima`'s net
rate over the same 8-day window, from `measure-deltas.md`) is **-0.90
GiB/day, i.e. shrinking**, which argues against high container-churn
events translating into net disk growth (plausibly explained by Docker
OverlayFS layer reuse keeping the marginal cost of a restart low even at
high event counts). **Status downgraded:** worth fixing for CI
reliability; not a demonstrated disk-growth root cause. The confirmed
disk-growth root cause is AO/CI `/private/tmp` scratch-worktree churn
(see `weekly-sweepers-never-fired-startinterval-reboot-starvation.md` and
the main report's Lane 2).

## Guards / governance

None yet — this is a workload/CI-config concern in the `ez-gh-actions`
repo (memory limit / concurrency setting for the `ezgha-runner` container
definition), outside `disk_magician`'s direct scope to fix. Reported here
as a CI-reliability finding, not fixed in this mission and **not** a
disk-growth quick win (see correction above): reducing the OOM rate
(raising the per-runner memory limit or capping concurrent runner count
to fit available RAM) should be evaluated in `ez-gh-actions` for its own
sake, not as a disk-side fix.

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
