# Scratch eviction: lease-ranked, host-pressure-triggered (design + implementation plan)

Status: DRAFT — pending independent review (/advice) and pending
`roadmap/2026-10-28-lru-scratch-eviction-research.md` (primary-source research, in progress).
Author date: 2026-10-28. Host evidence: Jeff-Ubuntu (Linux) + jeffreys-macbook-pro (macOS).

## 1. Problem

A quota-bounded scratch volume exists on both hosts. It is not self-managing in the
sense the operator expects: space is not reclaimed because it is *cold*, it is
reclaimed only when a *quota percentage* crosses a line, and the age sweeps that do
run free nothing because the contents are all recent.

Measured on 2026-10-28 (all figures from `df`, `du`, `diskm` receipts, and systemd/launchd logs):

| Fact | Linux | macOS |
|---|---|---|
| Scratch backing | sparse ext4 image `~/.local/share/disk-magician/volumes/scratch.ext4`, `/dev/loop24`, 200 GiB apparent / 121 GiB allocated | `/dev/disk3s7`, APFS container `disk3`, APFS shares container free space |
| Scratch resident | 119 GiB of 196 GiB (61%) | 160 GiB of 200 GiB (81%) |
| Host disk | 808 GiB of 884 used (97%) | container free 43.1 GB |
| Entries older than 7 days | cold outlier only (`relocated-tmp`, 32 GiB, 1 day old) | 0 |
| What reclaims today | `diskm-scratch-reclaim.timer` hourly → `volume reclaim --clean`; logs `skipped:below-trigger:48`; trigger is 90% of quota, target 80% | `com.jleechanorg.disk-magician-tmp-scratch` → `diskm tmp-scratch-sweep`, 16 runs, exit 0; `pressure-sweep` |
| Access-recency signal | **none** — mount options `rw,nosuid,nodev,noatime` | mtime only |

Three defects follow from those rows:

1. **Wrong trigger.** Reclamation is gated on the scratch volume's own quota, not on
   host free space. The host is the constrained resource. Observed: host at 97% used
   while the reclaim job reports `below-trigger` and does nothing.
2. **Wrong predicate.** Every implemented predicate is either create/modify age
   (mtime) or quota percentage. Neither answers "which bytes are least valuable right
   now". With `noatime` there is no read-recency signal at all, and directory mtime is
   a known-bad activity proxy (this repo already bans it for worktrees).
3. **Duplicated, divergent machinery.** Linux has a quota trim and no sweepers; macOS
   has sweepers and no quota trim. `pressure-sweep` overlaps both. The nightly
   `clean --routine` tier stack is a third path, and on Linux the nightly unit exited
   `status=141` at ~19 s on Oct-27 and Oct-28. **Cause unconfirmed:** a dry-run of
   `clean --routine` completes exit 0, 16/16 categories, and a minimal
   `set -euo pipefail` + `sort | head -20` repro does not fail, so the earlier
   `scripts/disk_audit.sh:423` attribution was wrong. Reproduce under the unit's own
   wrapper/redirect context before changing that line.

The operator-visible cost is maintenance: three schedulers per host, two divergent
scheduler systems, a dry-run-only nightly job, and manual `rm -rf /tmp` by agents as
the de facto reclaimer (no deletion-log entries accompany the observed 231 → 75 GiB
drops in `/tmp`).

## 2. What already exists and must be reused

`diskm` already records everything an LRU policy needs; the policy just never reads it.

- `diskm scratch-new <repo> <purpose> --kind build|evidence [--owner-pid PID]`
  performs admission and **registers a producer lease**.
- Lease registry: `~/.disk_magician_state/worktree_leases/*.json`.
- Admission event log: `~/.disk_magician_state/admission/events.jsonl` with
  `admit`/`admit_confirm` records carrying `dest`, `dev`, `inode`, `est_bytes`,
  `class`, `producer`, and timestamps.
- Admission budget/estimates: `admission/births.json`, `estimates.pending.json`.
- Ballast reserve: `<scratch>/.diskm-ballast` (64 MiB).

So the design is not "add an LRU cache". It is **rank by the lease and admission
records already written at allocation time, and trigger on host pressure instead of
volume quota**.

## 3. Design

### 3.1 Policy statement

> Under host free-space pressure, evict scratch artifacts in order of least
> recent *lease* activity, stopping as soon as the pressure watermark is satisfied,
> never evicting an artifact that has a live producer, an unexpired lease, or a
> recency floor younger than `min_idle_minutes`.

### 3.2 Signals (in rank order)

1. **Unreferenced** — artifact has no lease record and no live PID holding a cwd or
   open file inside it. This class is by definition abandoned and is evicted first.
   (`relocated-tmp` was this: 32 GiB, no owner.)
2. **Expired lease idle time** — lease exists, owner PID is dead or lease expired;
   rank by `now - last_touch` descending.
3. **Live-lease idle, over floor** — lease valid, owner alive, but idle beyond the
   floor; evicted only if (1) and (2) are exhausted and the watermark is unmet.
4. **Never** — live lease inside the floor, live cwd/open file, `needs_decision`,
   never-delete glob, the ballast file, or unmeasurable recency (fail closed).

`last_touch` is the one new datum: written by `scratch-new` at allocation and refreshed
by an explicit `diskm scratch-touch <path>` that producers call when they begin work in
an existing allocation. Absent any touch, `last_touch = created_at`. This is deliberately
*not* a filesystem atime (unavailable: `noatime`) and *not* a directory mtime
(known-bad proxy).

### 3.3 Trigger

Primary: **host free-space watermark**, evaluated from `statvfs` on the filesystem that
backs the scratch volume (the parent of the sparse image, or the APFS container), not
on the mounted scratch volume. Two levels:

- `pressure_low` (e.g. host free < 40 GiB or used > 90%): evict to satisfy.
- `pressure_critical` (e.g. host free < 10 GiB): evict to satisfy, ignore the
  `min_idle_minutes` floor for class 1 (unreferenced) only.

Secondary: volume quota at 90% (existing behaviour, retained as a backstop).

Rationale: the current quota-percentage trigger is structurally blind to the host, and
that blindness is what produced "97% host used, reclaim below-trigger".

### 3.4 Budget and floor

- Evict only until the watermark is satisfied; never a full-volume sweep.
- Hard floors: ballast preserved (existing), `min_idle_minutes` (default 60), and at
  least the most recent N artifacts retained so a burst-handed producer is never the
  first victim.
- Every eviction goes through the existing removal primitive (`quarantine_remove`) so
  the deletion log stays the reclaim list.

### 3.5 One engine, two hosts

The policy is host-independent; only the "return freed blocks" mechanism differs:

- Linux: after entries are removed, `fstrim` the loop-mounted ext4 (the mount has no
  `discard` option, so nothing is returned otherwise). Trimming is a *consequence* of
  deletion, never a substitute for it.
- macOS: APFS returns space on unlink; no trim step.

This replaces, rather than adds to: Linux `volume reclaim` quota trigger, macOS
`tmp-scratch-sweep`, the `/tmp` portion of `pressure-sweep`, and the tmp tier of
`clean --routine`.

### 3.6 Why this is less maintenance, not more

One policy, one implementation, one scheduler per host, driven by the resource that
actually runs out. The three current predicates (quota %, mtime age, routine dry-run)
collapse into one ranked deletion with a single documented floor. Scheduler health is
checked by one predicate — "did the evictor run and did the watermark hold" — which is
host-neutral, replacing `sweeper-health`'s macOS-only `~/Library/LaunchAgents` scan
(which reports `Found 0 plist(s)` → FAIL on Linux).

## 4. Non-goals

- Not an LRU over individual files. Bazel/ccache-style per-object LRU requires a cache
  index and content-addressed keys; scratch artifacts are opaque directories owned by
  producers, so the eviction unit is the allocation, and the recency unit is its lease.
- Not a change to admission (fail-closed at quota stays).
- Not a replacement for the 7-day worktree floor, which is a separate contract.

## 5. Implementation plan (TDD, staged)

Each stage ships independently and is verifiable by `df`, not by `du` proxies.

**Stage 1 — ranking engine, dry-run only.**
`diskm scratch-evict --dry-run [--json]`. Reads lease registry + admission events,
classifies every top-level entry under the scratch root into classes 1–4 above, prints
ranked candidates with reasons and a would-free total. No deletion path.
Tests: fixture scratch root + synthetic lease files covering each class, an expired
lease with a dead PID, an unreadable registry (must fail closed → class 4), and a
`noatime` mount to prove no atime is consulted.

**Stage 2 — pressure trigger + budget.**
Watermark evaluation against the backing filesystem, `--target-free-gb`,
`--min-idle-minutes`, `--max-evictions`. `--clean` requires an explicit watermark
argument; with no argument it refuses rather than guessing. Every removal goes through
`quarantine_remove` and appears in the deletion log.
Tests: watermark already satisfied → zero evictions and a non-success outcome that
says `below-watermark` (not the current ambiguous `success_noop`); critical pressure
evicts class 1 only; live-cwd artifact is never selected.

**Stage 3 — one scheduler per host.**
Linux: `diskm-scratch-evict.timer` (hourly) → `diskm scratch-evict --clean --target-free-gb <config>`.
macOS: one launchd job with the same command. `diskm setup --scratch` installs the
correct one and the health check verifies it, on both hosts.
Tests: installer writes the right unit/plist per platform; a unit test asserts the
template carries the watermark argument.

**Stage 4 — retire the duplicates.**
Remove the Linux quota-trigger unit, `tmp-scratch-sweep`, and the `/tmp` tier of
`pressure-sweep`; keep `clean --routine` for caches/worktrees only. Fix
`scripts/disk_audit.sh:423` only after reproducing the unit's exit 141 under the
wrapper/redirect context; a dry-run currently passes 16/16 categories at exit 0.
Tests: the nightly unit exits 0 in a simulated run; no remaining reference to a retired
job is left in `diskm status` output.

**Stage 5 — health that is host-neutral.**
Replace the plist-directory scan with a receipt-based check: last successful evict run
age, watermark state at that run, and current watermark. Emit `OK|STALE|NEVER` with the
last receipt path. Tests: Linux and macOS fixtures produce the same verdict shape.

## 6. Success criteria (measured, not asserted)

1. Host free space never stays below the `pressure_low` watermark for more than one
   evict interval, over a 7-day window, on both hosts.
2. Scratch resident bytes stay under quota without operator intervention.
3. Zero unlogged `rm -rf` of scratch or `/tmp` by agents: every reclaim appears in the
   deletion log.
4. Every scheduled job on both hosts shows a receipt inside its own interval.

## 7. Risks and mitigations

- **Deleting a live working set.** Mitigated by live-PID/cwd checks, lease validity,
  and a 60-minute floor. Unmeasurable → protect.
- **The `secret-like` filename gate blocks every repo checkout** (`.env.example`,
  `*credentials*.py`), so class-1 clone artifacts cannot be evicted at all until the
  gate distinguishes templates/fixtures from real secrets. This is a prerequisite for
  criterion 2, and is the single largest measured blocker today (`kept:secret-like`
  for all 293 candidates, `c14_kept_bytes=secret-like:13610481409`).
- **Orphaned global lease lock stalls all removals** for up to
  `LEASE_REUSE_LOCK_TTL_SEC`=3600 s after any holder dies. Mitigation: recover dead-PID
  locks in seconds (still requiring the dead-PID proof), or scope the lock per volume.
- **APFS shared container**: on macOS the volume does not add capacity, so eviction
  must be driven by container free space, which is exactly the Stage 2 watermark.

## 8. Open questions for review

1. Is lease-recency (allocation ownership) the correct recency unit, or should the
   engine prefer a cheaper proxy (e.g. newest-file mtime within an artifact) where no
   lease exists — accepting the known unreliability of mtime?
2. Should host-watermark pressure ever override the `min_idle_minutes` floor for
   non-class-1 artifacts, or is refusing admission the correct behaviour at that point?
3. Is retiring the age-based sweeps defensible, given they are the only mechanism that
   currently has a track record (macOS, 16 runs, exit 0) even though they free nothing
   on today's data?
