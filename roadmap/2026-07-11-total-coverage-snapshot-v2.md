# Total-Coverage Snapshot v2 — frontier-BFS enumeration with named residual

**Date:** 2026-07-11 · **Origin:** /sidekick /swarm design session (3 design lanes + adversarial critic, session 6843df5e) · **Trigger:** +120 GB month-over-month growth of which ~90-115 GB happened in unmonitored space — invisible by construction to the hand-maintained allowlist.

## Problem

`disk_snapshot.sh` measures a fixed allowlist (~37 dirs, now 52 after the 2026-07-11 gap patch) with per-dir `du -sk` timeouts. Three structural failures observed this month:

1. **Allowlist blindness** — new big trees grow unattributed until a human investigates (~90-115 GB this month).
2. **Timeout nulls** — `du` must fully walk a subtree before printing anything, so depth-limited *printing* does not limit walk *cost* (empirical: `du -x -d1 /System/Volumes/Data` produced ZERO output in 120s). Under disk pressure the biggest trees null out exactly when needed (bead jleechan-wsbk).
3. **Coverage math is wrong** — `add_entry()` sums parent+child overlaps (claude_root+claude_projects, codex_root+codex_sessions, library_containers + its top-20 drilldown), inflating coverage_pct (disk_snapshot.sh:209-221, 259-282).

## Design (post-critic)

### Core: frontier-BFS exhaustive enumeration (load-bearing, keep)

Replace the allowlist as the *source of truth* (keep it as a naming/labeling layer):

1. **Level-1 enumeration is exhaustive and O(1):** `find <root> -mindepth 1 -maxdepth 1` — every child is either measured or explicitly on the unfinished frontier. Nothing can be silently absent.
2. **Frontier descent:** parallel `du -sk` over children (globally bounded worker pool, 8-12 max — measured 2.65x speedup at 6-way on this 14-core box). Any subtree not finishing within its per-node budget is subdivided into ITS children and re-queued with a smaller budget; final leaves that still time out are reported as **named unfinished frontier paths**.
3. **Residual is always named:** `residual = disk_used − Σ(deduped measured)` and every byte of it is attributable to (a) named unfinished frontier paths, (b) the purgeable/snapshot bucket, or (c) sibling volumes — never a silent gap.

### Critic-mandated correctness fixes (BLOCKERs, all live-verified)

- **Symlink dedup at every level:** `/etc`, `/tmp`, `/var` are symlinks to `/private/*` at the volume root — the same class of bug as the `~/.hermes_prod` triple-count. Resolve `realpath` per child, skip already-visited real paths (dedup trie keyed by real path). `du -P`, never follow.
- **Sibling APFS volumes:** 11 non-Data volumes exist in the container (VM, Preboot, Update, ...). Report per-volume `df` usage as explicit line items; a Data-rooted walk cannot see them.
- **Purgeable/TM-snapshot bucket:** active local Time Machine snapshots exist NOW; APFS purgeable space is structurally invisible to any tree walk. Add a `tmutil listlocalsnapshots` + purgeable-space line item so du-vs-df reconciliation closes.
- **Backpressure:** the scanner must never worsen the incident it measures. Single global worker pool; halve concurrency when 1-min loadavg > cores or free < 15 GB; hard wall-clock cap with graceful frontier report.
- **Coverage dedup trie first:** fix the parent/child double-count (prereq for any SLO on coverage_pct).

### Incrementality (simplified per critic — no always-on daemon)

- **CUT: always-on FSEvents watcher.** A crashed watcher = silent undercount, contradicting the core guarantee. Instead: **mtime-frontier heuristic in the polling cycle** — reuse cached sizes for subtrees whose recursive scan found no mtime newer than the last snapshot (cheap `find -newer` probe), full re-du for dirty ones; nightly full walk re-baselines everything.
- **Sparse-file watchlist (keep):** O(1) `stat -f %z` for Colima diffdisk / Docker.raw — guest writes don't reliably bump host dir mtimes, and these are proven top growers (~31.6 GB/hr observed).

### Control loop (gated per critic — no silent self-mutation)

- **Residual-growth alarm:** residual delta > X GB between snapshots → bounded drilldown burst on the named frontier paths → results written to `config.d/auto-candidates.json` as **proposals**, surfaced via the existing disk_usage_alert.sh escalation. A human (or explicitly authorized agent run) promotes candidates into config — no silent auto-add.
- **Timeout self-tuning:** budget = 2× last observed duration; two consecutive timeouts → auto-subdivide (this is just frontier-BFS behavior, free).
- **Coverage SLO:** warn (existing `low_coverage`) plus escalation after N consecutive sub-threshold snapshots.

## Migration

- JSON schema stays additive: keep `directories` map (allowlist keys preserved for the 673-commit history diff tooling), add `frontier_unfinished[]`, `sibling_volumes{}`, `purgeable_kb`, `residual_kb`. Existing history diffing keeps working.
- `discover` subcommand is superseded by the frontier scan (closes bead jleechan-jz5t's root problem rather than patching its timeout).
- Anchor: snapshot history reachability protected by `archive/pre-reset-20260711` (bead jleechan-xadi).

## Implementation order

1. Dedup trie + symlink realpath dedup in coverage math (prereq; extends bead jleechan-wsbk).
2. Frontier-BFS scanner as `scripts/disk_frontier_scan.sh` (or python), wired as the new `discover` + optional snapshot backend behind a flag.
3. Purgeable + sibling-volume line items in snapshot JSON.
4. Residual alarm + candidate proposals + SLO escalation.
5. Sparse-file stat watchlist.

Beads: see jleechan-wsbk (dedup prereq), jleechan-jz5t (superseded-by-frontier), + new implementation bead(s) filed 2026-07-11.

## Provenance

Design lanes: lane-design-topdown (frontier-BFS + parallel-du measurements), lane-design-events (FSEvents/attribution survey — daemon cut, burst-attribution retained as future work), lane-design-selfheal (residual control loop + overlap-bug discovery), lane-critic (15 findings: 4 BLOCKER / 6 MAJOR / 5 MINOR, live probes). Full lane transcripts: session STATE.md at /tmp/disk_magician/sidekick/snapshot-coverage-gaps-brainstorm/STATE.md (ephemeral) — durable summaries in this doc and the beads.
