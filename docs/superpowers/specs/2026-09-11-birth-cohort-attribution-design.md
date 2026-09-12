# Birth-Cohort Attribution — Design Spec (disk_magician-6wd)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement the paired plan doc, if a plan exists. This spec's verdict is REFUTED — see §5. The paired plan is a 1-step bead-closure, not an implementation plan.

**Bead:** `disk_magician-6wd` — `/innov "birth-cohort attribution"`
**Source:** `roadmap/2026-09-11-disk-recurrence-rootcause-and-automation.md` §6 (chosen innovation) and §7 (critic gap #3, which carried the idea forward as "the explicit justification for the birth-cohort innovation").
**Verdict: REFUTED.** The mandatory falsification probe found 0 GiB of the target 18.0 GiB step-event delta attributable to newborn files in the 4 roots it is safe to probe. No implementation was designed; see the paired plan doc for the 1-step bead closure.

---

## 1. Background

§6 of the rootcause report proposed: read APFS `st_birthtime` (`find -newerBt`) per configured root, attribute newborn bytes to an owner via a 5-rung lookup (`.dm-own` manifest → config prefix → uid/gid → `UNKNOWN`), and feed a `newborn_by_owner` field into `disk_observer.py`'s step-event record — computed only when a step event fires (zero steady-state cost). The stated reason for choosing it over two other `/innov` candidates: it needs zero producer cooperation (birth time is already stamped by the filesystem) and it is the only candidate that can see incidents in directories that are also git worktrees (e.g. `~/roadmap`), where a worktree-exclusion rule would blind itself.

§6 also mandated a falsification-first build step, reproduced verbatim as this design's opening task:

> run a bounded `find -newerBt` probe against the *currently unattributed* 18.0 GiB/29.8min step event (2026-09-12T00:07:40Z, every `hot_dirs_kb` null) across `/private/tmp`, `/private/var/folders`, `~/roadmap`, `~/.cache`; sum `%b*512` grouped by 6-component path prefix. Success bar stated up front: top rows must account for a material fraction of the recorded delta, and at least one must sit under a root whose `hot_dirs_kb` was null. If newborn bytes are negligible, kill the idea (~1h sunk).

This design lane ran that probe under a safety-bounded scope (§2) before doing any further design work, per the dispatch instructions: *"If the probe refutes the idea, the spec must say so and the plan must be a 1-step 'close bead as refuted' plan — do not invent a rescue."*

## 2. The target step event

Read from `~/.disk_magician_state/step_events.jsonl` (9,454 records total; the record whose `epoch` exactly matches the bead's cited timestamp):

```json
{
  "delta_kb": 18903728,
  "direction": "grew",
  "epoch": 1789171660,
  "hot_dirs_kb": {
    ".aside": null, ".cache": null, ".codex": null, ".gemini": null,
    ".hermes": 11538028, ".ollama": 267896, ".openclaw": 1892,
    "/private/tmp": null, "/private/var/folders": null,
    "Library/Application Support/Aside": null,
    "Library/Application Support/Cursor": null,
    "Library/Caches": null
  },
  "schema_version": 1,
  "timestamp": "2026-09-12T00:07:40Z",
  "tool": "disk_observer_step_event",
  "window_seconds": 1788
}
```

- `delta_kb` = 18,903,728 KB = 18.03 GiB, `direction: grew` — matches the bead's "18.0 GiB" citation exactly (epoch diff to the cited timestamp = 0.0s).
- `window_seconds` = 1788s = 29.8 min — matches the bead's "29.8 min" citation exactly.
- Window: **start = `2026-09-11T23:37:52Z`** (`epoch - window_seconds`), **end = `2026-09-12T00:07:40Z`** (the record's own `epoch`).
- Every candidate hot dir that could plausibly hold the 18 GiB (`.aside`, `.cache`, `.codex`, `.gemini`, `/private/tmp`, `/private/var/folders`, both Cursor/Aside app-support paths, `Library/Caches`) is `null` — i.e. `du -sk` timed out or the path didn't resolve at collection time. The three non-null keys (`.hermes`, `.ollama`, `.openclaw`) are small (≤11.5M KB) and not the delta's source. This is the exact "anonymous growth" pattern §6 built the innovation to catch.

## 3. Falsification probe — method

Scope was constrained by the dispatching lane to 4 roots for safety (no probe over `~/projects`, `~/roadmap` as a whole, `/`, or `~`):

- `/private/tmp`
- `/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T` (this host's `$TMPDIR`, the concrete instance of the null `/private/var/folders` hot-dir key)
- `~/.cache`
- `~/roadmap/worldarchitect.ai/evidence` (bounded subtree of `~/roadmap`, not the whole git worktree)

Command run per root, `timeout 120`-wrapped:

```bash
timeout 120 find "$root" -xdev -newerBt "2026-09-11 23:37:52" ! -newerBt "2026-09-12 00:07:40" \
  -type f -print0 | xargs -0 stat -f '%b %N'
```

`-xdev` bounds each walk to one filesystem; the birthtime window is exactly the step event's [start, end).

## 4. Probe results

| Root | rc | wall time | files with birthtime in window | bytes attributed (`%b`×512) | total files under root (context) |
|---|---|---|---|---|---|
| `/private/tmp` | 0 | 27s | **0** | 0 | 913,707 |
| `/private/var/folders/j0/.../T` | 0 | 80s | **0** | 0 | 1,680,843 |
| `~/.cache` | 0 | 3s | **0** | 0 | 42,513 |
| `~/roadmap/worldarchitect.ai/evidence` | 0 | 1s | **0** | 0 | 18,430 |
| **Total** | — | 111s | **0** | **0 GiB (0% of 18.0 GiB delta)** | 2,655,493 |

No timeout fired on any root (all `rc=0`, well under the 120s budget). `stderr` on the two large roots held ~36 lines each, all `Permission denied` / `Operation not permitted` on macOS-daemon-owned `TemporaryItems` subdirectories (e.g. `com.apple.appleaccountd`, `com.apple.replayd`) — not user/agent scratch space, and not large enough to plausibly hide 18 GiB even if fully counted. `~/.cache` and the roadmap evidence subtree produced no stderr at all.

**Validity control (was the filter even working?):** re-ran `-newerBt` against `/private/tmp` with a 24-hour window instead of the 30-minute one: **68,104 matches**. This confirms the birthtime filter is live and the roots are under heavy, continuous file-creation churn (900K–1.68M files each) — the zero-count result in the 30-minute window is a real negative, not a broken query or an empty/unpopulated directory.

**Verdict against the stated success bar:** "top rows must account for a material fraction (≥30%) of the recorded delta, and at least one must sit under a root whose `hot_dirs_kb` was null." Actual: 0% of the delta accounted for, in 0 rows, across all 4 candidate roots — including the two that are exactly the null `/private/tmp` and `/private/var/folders` hot-dir keys named in the step event. **This is a clean, well-powered refutation, not an inconclusive result.**

## 5. What this means

**§6's core hypothesis is refuted for this event, and the refutation is severe: not "small fraction," but exactly zero.** Two explanations are consistent with the data and worth naming for the bead-closure record (not as a rescue — see below):

1. **The growth is somewhere the probe didn't look.** The 4 roots above are a safety-bounded subset of the null `hot_dirs_kb` keys; `.aside`, `.codex`, `.gemini`, `Library/Caches`, and both app-support Cursor/Aside paths were also null in this event and were *not* probed (excluded by the dispatching lane for scope/safety reasons, not because they were ruled out).
2. **Birth-cohort attribution has a structural blind spot even where it is safe to run:** `find -newerBt` only sees **new files**. A disk-usage step event can equally be produced by an **existing file growing** — an appended log, a truncated-and-rewritten sqlite WAL, a sparse file being extended, a Colima/Docker raw disk image — none of which touch `st_birthtime`. This is a limitation of the *method*, independent of scope, and would still apply even with an unrestricted probe.

Per the dispatching instructions, neither of these is a rescue to design here — closing the bead as refuted is the correct action, and any follow-up (widening scope, or a companion "grown-file" detector) is a separate, future bead if someone chooses to open one.

## 6. Secondary finding: the clone-correction claim in §6 does not hold

§6 asserted the design would correct "for APFS clone double-counting by using `stat -f %b` (allocated blocks) rather than inode grouping (verified: `cp -c` clones get distinct inodes sharing blocks)." This was tested directly, independent of the primary probe's outcome, because it is a load-bearing technical claim for any future attempt at this idea:

```
$ dd if=/dev/urandom of=orig.bin bs=1m count=10
$ cp -c orig.bin clone.bin          # APFS clonefile()
$ stat -f '%i %b blocks (%z bytes apparent)' orig.bin clone.bin
2062055536 20480 blocks (10485760 bytes apparent)   # orig
2062055537 20480 blocks (10485760 bytes apparent)   # clone
$ du -sk orig.bin clone.bin .
10240   orig.bin
10240   clone.bin
20480   .                                            # directory total: NOT deduped
```

**Result: `stat -f %b` does not correct clone double-counting — it exhibits it.** The clone gets a distinct inode (as the roadmap doc correctly noted) *and* independently reports the full 10,240 KB of allocated blocks, identical to the original. Summing `%b` over both files — which is exactly what a naive newborn-bytes sum would do if a clone operation happened to fall inside the birth window — reports 20 MB of "newborn" allocation for an operation that added roughly 0 bytes to real physical disk usage (APFS clones share the underlying extents until one side is later modified; `du`/`stat` cannot see that sharing without deeper `fclonefileat`/extent-map inspection). This is the identical failure mode CLAUDE.md already documents for `du` on Xcode DerivedData / dirs_cleaner cases.

This does not change §5's REFUTED verdict — it is an independent design defect that would need fixing before this idea could ever be safely built, and is recorded here so a future attempt doesn't repeat the "verified" claim without re-checking it.

## 7. Assumptions and Recommended Defaults

Only one fork existed before the mandatory kill point, and it was scope, not design:

- **Fork: probe scope.** *Question:* probe only the 4 lead-specified bounded roots, or ask to widen to the remaining null hot-dirs (`.aside`, `.codex`, `.gemini`, `Library/Caches`, Cursor/Aside app-support) first, in case the 4-root probe came back inconclusive? *Recommended default (applied):* run exactly the 4 specified roots first, since the dispatching lane explicitly bounded scope for safety and the falsification gate only requires a single well-powered negative or positive result to decide. *Rationale:* the result was unambiguous (0 of 4, not "some of 4"), so no re-ask was needed — widening scope now would be exactly the "invent a rescue" move the dispatch explicitly forbade after a refutation.

No further design forks (attribution algorithm, `.dm-own` manifest format, config schema, `disk_observer.py` hook placement, owner-lookup rungs, JSON output shape, unit-test design) were reached, because §6's own falsification gate fires before any of that work, and it fired negative.

## 8. File list touched by this design lane

- `docs/superpowers/specs/2026-09-11-birth-cohort-attribution-design.md` (this file, created)
- `docs/superpowers/plans/2026-09-11-birth-cohort-attribution.md` (created — 1-step bead-closure plan)

No source files (`scripts/newborn_cohort.py`, `disk_observer.py`, `config.json.template`) were created or modified, per §5's "do not invent a rescue" instruction and because this design never reached the implementation-design stage.
