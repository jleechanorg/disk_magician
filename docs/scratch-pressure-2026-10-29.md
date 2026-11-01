# Scratch pressure scheduling — source candidate, not host activation

Owner: cloud scratch-cleanup lane, branch
`feat/scratch-free-space-maintenance-20261029`, based on
`19f764bc3cd553cf8d3d9dc504de2d04f701afcc`. Existing PR286 and its held
worktrees are excluded. No host scheduler, mount, cleanup or settings operation
was performed by this change.

## Implemented policy

`diskm volume reclaim --available-floor --clean` is the existing C14 reclaim
path with a scheduling policy, not a new deletion implementation. Verify the
registered Scratch mount, then measure `statvfs.f_bavail * f_frsize` there.
Reclaim only below 53,687,091,200 available bytes; equality skips. Never infer
Scratch pressure from repository filesystem or quota-utilization percentage.
Recheck mount and availability before each C14 candidate and after each unit;
stop once the floor is recovered. Preserve the existing 48-hour artifact filter,
shared cleanup lock, lease serialization, protected paths, identity checks,
quarantine and deletion logging. A floor recovery does not waive these guards.
A pass that cannot safely find enough disposable space remains partial.

The new Mac `scratch-pressure` label runs every 1200 seconds. The existing
hourly `tmp-scratch` label and non-Scratch functions remain unchanged in cadence;
its nested Scratch reclaim also uses the floor policy. Linux's existing reclaim
timer uses `OnCalendar=*:0/20`; upgrades compare exact previous candidate
service/timer templates, preserve backups and reject drift. Both entrypoints use
`diskm`. Pressure dispatch requires a GNU timeout utility, fails closed if absent,
and bounds execution at 310 seconds (350-second systemd envelope including bounded recovery); C14 gets a
300-second cooperative deadline. No forced cleanup retry is introduced.

Receipts identify available-floor policy and before/after availability. Healthy
floor skips and failed probes receive terminal receipts; actual runs also update
reclaim history. The dispatcher terminalizes lock refusal as skipped_lock, not completed cleanup. Reserve restoration is only
attempted for a durable exact-volume release intent, including a prior interrupted
pass. The registry records that obligation before unlink under its existing lock;
verified restoration clears it. Recovery takes the shared cleanup lock (or
verifies the inherited owner lock), so it cannot clear an active pass's reserve
obligation. A typed insufficient-space result permits bounded C14 reclaim while
retaining the intent and forbidding a second release; restoration is retried
after the pass. Identity/corruption failures remain hard stops. Allocation checks actual verified
mount availability as well as quota headroom. Partial reserve writes record
the created file device/inode before content writes; only that exact regular,
single-link owned file is eligible for logged recovery. Unknown partial files,
including a crash before identity journal commit, are preserved with failure
rather than guessed safe to delete. ENOSPC/EDQUOT before or during a bound
allocation retains the recovery obligation and permits C14 to free space. Dispatch owns one receipt and a bounded timeout
finalizer, which attempts recovery and closes only its own unfinished receipt. Manual
quota reclaim and its native host FITRIM behavior are retained; scheduled floor
mode does not claim or perform host FITRIM.

## Still blocked / not accepted

Linux native `systemd-tmpfiles` three-day cleanup is **not implemented or enabled**.
A generic tmpfiles configuration would bypass C14's quarantine transaction and
producer lease lock. A dedicated namespace alone does not prove no live producer,
Git data, symlink substitution or open file. A safe implementation needs an
explicit producer/lease bridge and a C14-compatible native deletion contract;
no broad `/tmp`, Scratch root or user home cleanup rule is supplied here.

No live Mac/Linux execution, installed scheduler migration, native tmpfiles,
PR286 interruption fix, full-repository CI or release acceptance is claimed.
Installer state rollback outside exact old-candidate unit replacement
is not broadened here; operator activation remains separate and review-gated.

## Isolated evidence

- New available-space policy tests: initial RED (missing policy / hourly cadence),
  then GREEN; real shell cases include equality/above-floor no mutation, low
  available space despite low quota, and unavailable mount/probe.
- Existing volume suite plus focused recovery/timeout additions; old hourly/service migration test now exercises
  both exact historical units, rollback and concurrent drift.
- Actual isolated wheel bytes match canonical pressure helper/dispatch templates;
  missing build patterns reproduced RED before the packaging fix.
- Wrapper suite: 45 assertions preserving existing non-Scratch wrapper behavior.
- Real C14 reclaim suite covers removal, stop threshold, typed ENOSPC, reserve
  restoration, plus new floor-mode protected-path and live-producer lease cases.
- Baseline Linux regression test expected empty stdout despite its existing
  `skipped:non-native-scratch` FITRIM no-op output. Exact main baseline reproduced
  this failure; only that assertion was broadened to accept the known no-op,
  retaining deletion, ordering and target assertions.

Logs are retained in the task's cloud execution receipts. This document is not
permission to install or execute maintenance on either host.
