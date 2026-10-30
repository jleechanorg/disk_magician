# Nextsteps — disk_magician — 2026-10-29

Topic: scratch eviction that actually reclaims, and the gate that makes all reclaim impossible.

## Table of contents

- [Executive summary](#executive-summary)
- [Context](#context)
- [Bead index](#bead-index)
- [Work queue](#work-queue)
- [Timeline and parallel lanes](#timeline-and-parallel-lanes)
- [PR / merge state](#pr--merge-state)
- [Learnings pointer](#learnings-pointer)
- [Roadmap pointer](#roadmap-pointer)

## Executive summary

- **Outcome:** host recovered from 100% full (840 G used, 0 free) to **753 G used / 86 G free (90%)**. `/tmp` went 41 G → 899 M (34,689 entries).
- **What that was:** a user-authorized manual purge, not automation. **Nothing in this repo currently reclaims scratch automatically**, and the two things that would have were proven inert today.
- **Root cause (measured, not inferred):** `has_hidden_state` (`scripts/lib/worktree_ignored.sh`) does `git -C "$1" ls-files -v || return 0`; on a directory that is not a git repo the git call fails and the function reports "hidden state", so `artifact_verdict.sh:76` emits `kept:secret-like`. Agent scratch dirs are mostly not repos → unremovable by construction. 13 of 14 largest `/tmp` dirs are blocked this way.
- **Blocking decision (user-only):** should a non-repo directory fall through to the secret-glob scan instead of auto-blocking? Until answered, every sweep keeps reporting success while the disk fills.
- **Second defect:** the repo already owns the right engine (`scripts/lib/scratch_budget.sh`: size budget, oldest content-mtime first, ≥60-min floor, `has_open_files()` recheck before every unlink). It is wired to `/tmp` only; the volume uses a worse copy gated at 90% quota and 48 h.
- **Risk if nothing lands:** recurrence within days. Both hosts are moving the wrong way: Linux scratch 65% → 72%, Mac 81% → **92% (17 GiB free, above its trim trigger)**.
- **Design state:** v1 (`2026-10-28-scratch-lru-eviction-design.md`) was rejected NOT APPROVED by two independent reviewers. v2 (`2026-10-28-scratch-eviction-v2-reuse-scratch-budget.md`) is written, unreviewed.

## Context

Session on `jleechanorg/disk_magician`, branch `feat/scratch-space-skill` (its PR #278 is already MERGED, so the uncommitted work needs a fresh branch). Two hosts in scope: Jeff-Ubuntu (Linux, scratch = 200 GiB sparse ext4 loop image on the same physical disk as `/`) and jeffreys-macbook-pro (macOS, scratch = APFS volume sharing its container). Scope boundary: this block diagnosed and reclaimed; the durable fix is designed (v2) but not implemented, and one safety-semantics decision is reserved to the user.

## Bead index

`br` was unavailable for the entire session and no bead could be read, created, or updated:

```
Error: Sync conflict: engine recovery refused before opening: WAL contains frames that may
hold committed, uncheckpointed changes; close other database readers/writers and have the
owning SQLite engine complete a truncating checkpoint before retrying; do not delete or
replace the WAL or rebuild this database from JSONL
```

Consequently **no bead ids are asserted here** — inventing them would be unverifiable. Bead ids quoted elsewhere in this repo for this area, as found in source/doc comments (not re-verified this run because `br` is down):

- `disk_magician-d45` — quoted in `scripts/lib/scratch_budget.sh:5` (age-only sweepers never touch 0–24 h scratch)
- `disk_magician-dcz` — quoted in `scripts/lib/scratch_budget.sh:6` and `:154` (lsof-recheck requirement)
- `disk_magician-wgo` — quoted in `scripts/disk_audit.sh:594` (Colima prune/fstrim tier)

Action: once `br` opens, create the five work-queue beads below, then re-link this table.

## Work queue

1. **Decide the non-repo hidden-state semantics (blocking everything else).**
   Goal: a directory with no git repo evaluates the secret-glob scan and `safety_gate` instead of short-circuiting to blocked.
   Acceptance: tests assert a real `.env` / `*.key` / `id_rsa` in a *non-repo* dir still blocks; a non-repo dir with no secret-glob hits is eligible; existing `test_av_secret_like.sh` stays 143/143.
   Files: `scripts/lib/worktree_ignored.sh` (`has_hidden_state`), `tests/secret_name_table.tsv`, `tests/test_worktree_ignored_fail_closed.sh`.
   Blocker: **user decision** (loosens a fail-closed safety gate). Its pre-existing `non-UTF8 ignored secrets file not hidden` failure must be triaged in the same change.
2. **Land the already-made exemption on a fresh branch.**
   Goal: `c14_probe.py` + `secret_name_table.tsv` changes committed and PR'd (currently uncommitted on the merged branch).
   Acceptance: `pytest tests/test_c14_probe.py` 7/7, `tests/test_av_secret_like.sh` 143/143, package-tree sync check, version bump per repo rules.
   Files: `scripts/c14_probe.py`, `tests/secret_name_table.tsv`.
3. **Wire the volume to `scratch_budget_evict_root` — but first fix the candidate shape, which is the real cap.**
   Measured inventory of the volume (Oct-29): **118.0 GiB of 140.3 GiB (84.1%) is unleased/orphaned**, 22.3 GiB is leased with a **dead** owner, and **0.0 GiB** is leased with a live owner. All 93 Scratch lease records have dead owners, 86 are past `expires_at`, none were released. `relocated-tmp` alone is 31.5 GiB fully orphaned (its own `manifest.tsv` records 51 moves out of `/tmp`).
   Yet `volume_reclaim.sh` only considers depth-3 `<id>/(build|evidence)/<id>`-shaped dirs, so **any trigger/floor fix is capped at 24.82 GiB of the 141 GiB**, and the orphaned 118 GiB is structurally invisible. Widening or replacing that shape filter (rank by lease presence + content mtime, per `scratch_budget.sh`) is worth more than the trigger change.
   Acceptance: dry-run enumerates volume candidates with reasons; 2 h floor honoured; open-fd dir never selected.
   Files: `scripts/volume_reclaim.sh` (trigger at `:33-38`, 48 h gate at `:102`, outcome classification `:137-142`).
4. **Host-`df` attribution and honest outcomes.**
   Goal: every run reports host free bytes before/after and emits `below-budget` / `no-host-effect` / `watermark-unreachable` / `evicted`; a run that shrinks the volume without moving host `df` is not `success`.
   Files: `scripts/volume_reclaim.sh`.
5. **Privileged trim — ALREADY SHIPPED, do not rebuild.** `scripts/volume.py:1327` runs a raw `FITRIM` ioctl (`fcntl.ioctl(fd,0xc0185879,…)`), and PR #287 (`19f764bc`) shipped it to `main`. It demonstrably returns host space: Oct-29 17:00 `status=trimmed host_free_delta=6.90 GiB`, 18:00 `+8.90 GiB`, with `image_reclaimed` matching to within 225 KB (so loop discard **is** reaching the sparse file — the earlier claim that it needed `--allow-discards` was wrong). Trim correctly self-limits: it only fires under host pressure (host free < 80 GiB), which is why the 18:20/18:40/19:00 runs log `no-host-reclaim-pressure`. Any v2 must be **rebased on `19f764bc`** and must not re-add this stage.
6. **After 1–4: retire the 90% quota gate, keep the other sweeps.**
   Shadow for 7 days (record would-evict + projected host delta), then disable `diskm-scratch-reclaim.timer` as a *gate* only. Keep `tmp-scratch-sweep`, `pressure-sweep`, `clean --routine` — v1's proposal to retire them was rejected by both reviewers.
7. **Diagnose the nightly routine-clean exit 141 (cause NOT confirmed).**
   Measured: the systemd unit died `status=141` at ~19 s on both the Oct-27 and Oct-28 03:00 runs. But `./disk_magician.sh clean --routine` in dry-run **exits 0 and completes 16/16 categories today**, and a minimal `set -euo pipefail` + `sort | head -20` repro does **not** fail either. So my earlier attribution to `scripts/disk_audit.sh:423` is unproven — do not "fix" that line on this evidence.
   Next diagnostic: reproduce under the unit's own environment (wrapper `/bin/bash ~/.hermes/scripts/systemd-wrapper.sh`, which sources `~/.bash_profile`, with `StandardOutput=append:`), capturing `bash -x`; that wrapper/redirect context is the only known difference from the passing dry-run.
   Files: `systemd/disk-magician-routine-clean.service.template`, `/home/jleechan/.hermes/scripts/systemd-wrapper.sh`.
8. **Linux scheduler parity.**
   `tmp-scratch-sweep` and `pressure-sweep` have **no systemd units** on this host (only `disk-magician-snapshot`, `disk-magician-routine-clean`, `diskm-scratch-reclaim`). `diskm sweeper-health` scans `~/Library/LaunchAgents` → `Found 0 plist(s)` → FAIL on Linux.
9. **Re-review v2** once 1–2 are decided: Codex + AGY (Opus is out of weekly quota until Nov 2 7pm PT). v2 is not a validated design until that returns APPROVED.
10. **Close the deletion-log gap.** Today's ~40 G `/tmp` reclaim is absent from `~/Library/Logs/disk-magician-deletions.log`, so `diskm reclaim-ledger` will under-report this host's reclaim history. Also record the one casualty: `/tmp/RustDesk/cliprdr-server` fuse mountpoint lost its parent dir.
11. **Receipt writes fail under ENOSPC.** Oct-29 14:00 and 15:00 reclaim runs died with `[Errno 28] No space left on device` / `kept:receipt-begin-failed` — the job cannot record itself exactly when the disk is full, so a full disk yields no evidence at all. Receipt skeleton must be written to a preallocated or ballast-backed path.

## Timeline and parallel lanes

| Elapsed est. | Lane / owner | Scope (exclusive write) | Deliverable / proof |
|---|---|---|---|
| 0–20 m | A: gate semantics | `worktree_ignored.sh`, `secret_name_table.tsv`, fail-closed test | diff + tests; **blocked on user decision** |
| 0–20 m | B: commit/PR exemption | `c14_probe.py` + table, new branch from main | PR + pytest 7/7 + 143/143 |
| 20–60 m | C: volume wiring | `scripts/volume_reclaim.sh` | dry-run candidate list + 2 h floor test |
| 20–60 m | D: attribution | `scripts/volume_reclaim.sh` — **serialize with C** (same file) | receipt with host-`df` deltas |
| 0–15 m | E: nightly 141 triage | `systemd/*.template` + wrapper env | repro under unit context; cause confirmed or `unreproduced` |
| 60–90 m | F: v2 re-review | none (read-only) | 2 independent votes at doc SHA |
| later | G: trim | root helper + unit | positive host-`df` delta, or `UNAVAILABLE` |

- **Critical path:** A (user decision) → C → D → G. Everything except A can proceed now.
- **Concurrency ceiling:** measured box — 32 cores, load 4.4–8, 60 GB RAM, host free space was the binding resource at 86 G. Lanes A/B/E/F are light and can run together; C and D touch the same file and must be one writer.
- **Milestones (for future execution):** +20 m lanes A/B reported, +40 m C dry-run, +60 m hourly rollup, +90 m F verdicts, then repeat.

## PR / merge state

- https://github.com/jleechanorg/disk_magician/pull/278 — **MERGED** ("feat(scratch): add scratch-space skill and diskm scratch-dir resolver"). Branch `feat/scratch-space-skill` therefore needs a **fresh branch from `main`** for the uncommitted work; do not push onto this branch expecting PR #278 to pick it up.
- No open PR references any work-queue item.

## Learnings pointer

- `~/roadmap/learnings-2026-10.md` — section `2026-10-29 — Green receipts while the disk fills: verify the predicate, not the exit code` (three traps — wrong-gate misdiagnosis, fstrim proving nothing, `rm -rf /tmp` crossing fuse mounts — plus the corollary that design-first review saved the implementation).

## Roadmap pointer

- Appended `roadmap/activity/2026-10-29.md` and prepended its date link to `roadmap/README.md` → `## Recent activity (by day)`.
