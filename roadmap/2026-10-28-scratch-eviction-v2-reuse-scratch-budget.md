# Scratch eviction v2: wire the existing budget evictor to the volume

Supersedes `2026-10-28-scratch-lru-eviction-design.md` (rejected NOT APPROVED by two
independent reviewers, `DOCUMENTS sha256:7fe45ff9accf6b70b440d2f98dfb5142363ea1c6547d8415a190f9d6f1375a16`).
Date: 2026-10-28. Hosts: Jeff-Ubuntu (Linux), jeffreys-macbook-pro (macOS).

## 0. What changed from v1

v1 proposed a new LRU engine keyed on a producer `scratch-touch` protocol. That was
wrong on three counts, all now verified against the repo's own source:

1. **The engine already exists, and is better than what v1 described.**
   `scripts/lib/scratch_budget.sh` (`scratch_budget_evict_root <root> <budget_kb> <floor_minutes>`)
   already implements size-budget eviction, oldest-first by **real content mtime**
   (explicitly not a directory-mtime proxy), a hard floor clamped to ≥60 minutes,
   `has_open_files()` rechecked immediately before *every* deletion, and
   `is_protected_root`/repo/worktree/`safety_gate` exclusions. Its header cites the
   pathology verbatim (bead `disk_magician-d45`: age-only sweepers never touch 0–24 h
   scratch, where the growth lives; `dcz`: lsof-recheck requirement).
2. **The volume evictor already ranks correctly but is gated shut.** `scripts/volume_reclaim.sh`
   skips unless `used*100 >= quota*90` (line 35), stops at `<= quota*80` (line 95), and
   only considers entries whose newest content mtime is older than `172800` s = **48 h**
   (line 102). Ordering is already oldest-content-mtime-first (line 103). So the
   ordering, the floor machinery and the safety rechecks are sound; the **trigger and
   the 48 h gate** are what make it do nothing.
3. **There is no trim step in the volume path at all.** `fstrim` appears only for
   Colima's in-VM datadisk (`cleanup_colima.sh`, `main_sweeper.sh`, `pressure_sweep.sh`).
   A v1 assumption that deletion "trims to 80%" was wrong: the 80% is a target measured
   *inside* the volume. Deleting inside the ext4 image returns **zero** blocks to the
   host, because the mount carries `rw,nosuid,nodev,noatime` with no `discard`.

Consequence: the repair is four parameter changes plus one privileged step, not a new
subsystem. That is also the answer to "why does this need so much maintenance" — three
of the four predicates in play are gates that disable working code.

## 1. Measured situation (unchanged from v1, re-verified)

| | Linux | macOS |
|---|---|---|
| Scratch backing | sparse ext4 image, `/dev/loop24`, 200 GiB apparent / 121 GiB allocated, same disk as `/` | `/dev/disk3s7`, APFS container `disk3`, shares container free space |
| Resident | 119 GiB of 196 GiB (61%) | 160 GiB of 200 GiB (81%) |
| Host | 808/884 GiB (97%) | container free 43.1 GB |
| Oldest content | 0 entries older than 48 h go through; cold outlier `relocated-tmp` 32 GiB is 1 day old | 0 entries older than 7 days |
| Current reclaim | hourly `volume reclaim --clean` → `skipped:below-trigger:48` | `tmp-scratch-sweep`, 16 runs, exit 0, frees nothing |

## 2. Design

### 2.1 One engine, two roots

Keep `scratch_budget.sh` as the only eviction engine. It is already wired to `/tmp`
(`cleanup_tmp.sh`, `cleanup_pr_scratch.sh`). Add the scratch volume root as a second
caller. Do **not** write a second engine and do **not** retire the `/tmp` caller — v1
proposed retiring `/tmp` cleanup, which both reviewers rejected as leaving the largest
measured grower unmanaged.

### 2.2 Trigger: size budget, with host pressure as a modifier

- Primary: a **size budget** per root (volume: e.g. 60% of quota = 120 GiB; `/tmp`:
  configured budget). Exceeding the budget starts eviction; eviction stops when back
  under it. This replaces the 90%-of-quota trip.
- Modifier: **host free-space watermark**. When the host backing filesystem is under
  pressure, lower the effective budget (evict more aggressively) — but the watermark
  may never bypass the floor, the open-file check, or any protection. If protected
  artifacts are all that remain, the run reports `watermark-unreachable` and names the
  largest protected class; it does not force deletion. This is the reviewers' required
  correction: pressure is a budget input, not an authority.
- Attribution: the run records *both* volume-resident bytes and host free bytes before
  and after. A run that frees volume bytes without moving host free bytes is reported
  as `no-host-effect` rather than success — that is precisely the failure mode v1 hid.

### 2.3 Recency: last write, and say so

Ordering remains oldest **content** mtime first. This is least-recently-*written*, not
least-recently-used, and the docs must state that instead of claiming LRU. The residual
hazard both reviewers raised — a written-once artifact that is still wanted versus one
that is abandoned — is unknowable without a use signal, and `noatime` means the
filesystem has none. It is bounded by: the open-file recheck immediately before each
deletion, the ≥60-minute floor, repo/worktree protection, and `safety_gate`. No
`scratch-touch` protocol is introduced; both reviewers established it would not be
called by compilers, test runners, or subagents, and would silently degrade to FIFO.

### 2.4 Floor: 48 h → 2 h

Demote the volume's 48 h gate to a 2 h default (never below the engine's 60-minute
clamp). Today's data shows why: 0 entries are older than 48 h, so the gate matches
nothing while 119 GiB accumulates. A 2 h floor still protects an in-flight build and
makes the evictor responsive to the 0–24 h window where the growth actually is.

### 2.5 Trim is a separate, privileged step

After a deletion batch, return blocks to the host. This requires `CAP_SYS_ADMIN`
(`FITRIM` ioctl on the loop device), so it cannot run from an unprivileged user timer;
the repo already has the privileged-installation pattern in
`diskm install-root-frontier-runner`. On macOS there is no trim: APFS returns space on
unlink, and the check is container free space.

Verification is by **host `df` delta**, never by `fstrim` exit status: fstrim exiting 0
proves neither that data was unlinked, nor that ext4 freed the blocks, nor that the
sparse file shrank.

### 2.6 Prerequisite: the secret-like gate

`quarantine_remove` currently returns `kept:secret-like` for every repo checkout
(`.env.example`, `.env.template`, `*credentials*.py`), which is why 293 of 293
candidates were kept and 0 bytes freed. Until the gate distinguishes templates and
fixtures from real secret material, eviction of clone artifacts is impossible and every
success criterion below is unreachable. This is a prerequisite stage, not a risk note.

## 3. Implementation plan

**Stage 0 — unblock the gate.** Add template/fixture exemption to the secret-like
predicate (explicit allowlist of `.env.example`, `.env.template`, `*.example`,
`*credentials*template*`, test fixtures), with tests asserting a real `.env` and a real
`*.pem` still block. Verify on the live 293-candidate set: dry-run must move from
`kept:secret-like 293/293` to a non-zero removable count.

**Stage 1 — volume caller, dry-run.** Add the volume root as a `scratch_budget_evict_root`
caller with a budget and a 2 h floor, `--dry-run` only. Tests: entries matching each
protection class; a dir with an open fd is never selected; floor honoured below the
clamp; budget satisfied → zero candidates.

**Stage 2 — host attribution.** Record host free bytes before/after and emit
`below-budget` / `no-host-effect` / `watermark-unreachable` / `evicted` as distinct
outcomes. Tests: fixture runs producing each outcome, including a run where the volume
shrinks and host free does not.

**Stage 3 — privileged trim.** Root helper performing `fstrim` on the loop mount,
invoked after a batch that actually deleted. Receipt records fstrim rc **and** measured
host `df` delta. Test: deletion of N GiB inside the volume produces a positive host
delta; a no-op batch produces no trim.

**Stage 4 — scheduler, shadow first.** One scheduler per host pointing at the same
command. Run in shadow for 7 days (evict nothing, record what it would evict and the
projected host delta) before enabling. Then retire the 90%-quota unit
(`diskm-scratch-reclaim.timer`) as a *gate*, leaving manual `diskm volume reclaim` as an
escape hatch. Keep `tmp-scratch-sweep`, `pressure-sweep` and the nightly routine stack;
they cover different roots, and v1's proposal to retire them was rejected.

**Stage 5 — health.** One host-neutral predicate: age of last successful evict receipt
and whether the watermark held. Replaces `sweeper-health`'s macOS-only
`~/Library/LaunchAgents` scan, which reports `Found 0 plist(s)` → FAIL on Linux.

## 4. Success criteria (measured by host `df` and receipts)

1. Host free space recovers within one evict interval after crossing the watermark, on
   both hosts, over 7 days.
2. Volume stays under the size budget without operator action.
3. Every reclaim appears in the deletion log (zero unlogged agent `rm -rf`).
4. No run reports `evicted` without a positive host `df` delta.

## 5. Open risks

- Content-mtime ordering can still evict a wanted-but-idle artifact; bounded by the
  floor and open-file check, not eliminated.
- APFS shares container free space, so on macOS the evictor must read container free
  space (not the volume's own numbers) to have any effect on the host.
- The orphaned global lease lock (`LEASE_REUSE_LOCK_TTL_SEC` = 3600 s) fail-closes all
  removals after any holder dies; any automatic evictor needs dead-PID recovery in
  seconds, or the evictor silently no-ops for an hour at a time.

## 6. Evidence gaps

`roadmap/2026-10-28-lru-scratch-eviction-research.md` was produced **without web
access** — the research agent had no search/fetch tools, so every external claim is
marked `[U] unverified this run`. Its local half (mount options, `volume_reclaim.sh`
gates, `scratch_budget.sh` behaviour, absence of any trim step) was verified directly
against the repository and `/proc/mounts`. Kernel-level claims about `FITRIM`,
`CAP_SYS_ADMIN`, and APFS semantics in this document are therefore **unverified against
primary sources** and must be confirmed before Stage 3 ships.
