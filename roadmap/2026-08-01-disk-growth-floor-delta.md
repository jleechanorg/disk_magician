# Disk growth root-cause — 2026-08-01 sidekick pass

Mission: `disk_magician-dgs` ("sidekick: root-cause-disk-always-growing").
State/log: `~/roadmap/disk_magician/sidekick/root-cause-disk-always-growing/STATE.md`.
Raw evidence: `~/roadmap/disk_magician/sidekick/root-cause-disk-always-growing/docs/`
(12 ledger JSON extracts + 4 lane reports). Four anonymous sonnet subagent
lanes ran in parallel; every non-trivial claim below was independently
re-verified by this session (bead status checks, direct code reads, live
`df`/`uptime`/`grep -n` probes) before being included — refute-by-default,
survives only with a citation.

## Headline finding: the mission's own premise partially does not hold

**The disk is not in sustained net growth right now.** `disk_observer.jsonl`
(11,554 samples, 2026-07-24→08-02) shows the 7-day trend is **-3.93 GiB/day**
and the last-48h trend is **-13.43 GiB/day** — both net *shrinking*, not
growing. What actually explains the "always growing" feeling is a
**sawtooth oscillation with dangerous amplitude**: single-day swings up to
**115.9 GiB peak-to-trough** (2026-07-31: 748.69→864.62 GiB used), with
free space independently confirmed by `host-disk-guardian.log` bouncing
21 GiB → 98 GiB → 56 GiB → 98 GiB → 80 GiB inside single 2-3 hour windows
on 2026-08-01/02. The mandatory floor-and-gap number below is correct as
computed, but **do not read it as a daily growth rate** — see step 1.

## Step 1 — Floor and gap (ledger-mandated, computed first)

Per repo CLAUDE.md: floor = lowest `df`-derived `disk_used_kb` in the most
recent ~14 daily snapshots of `~/.disk_magician_backup/ledger/topdown-5g.json`.

| date (captured_at, UTC) | disk_used_kb | disk_used GiB |
|---|---:|---:|
| 2026-07-21T11:21:21Z | 816,834,172 | 778.99 |
| 2026-07-22T11:26:33Z | 868,550,792 | 828.31 |
| 2026-07-23T10:49:35Z | 894,052,008 | 852.63 |
| 2026-07-24T10:49:10Z | 844,083,864 | 804.98 |
| 2026-07-25T11:26:10Z | 870,897,352 | 830.55 |
| 2026-07-26T11:26:06Z | 898,201,500 | 856.59 |
| 2026-07-27T11:26:08Z | 878,795,836 | 838.09 |
| 2026-07-28T11:23:50Z | 863,745,196 | 823.73 |
| 2026-07-29T10:55:39Z | 861,880,804 | 821.95 |
| 2026-07-30T11:25:29Z | 875,696,540 | 835.13 |
| **2026-07-31T11:26:08Z** | **799,093,672** | **762.08 (FLOOR)** |
| 2026-08-01T11:26:06Z | 835,097,676 | 796.41 |

**Floor = 762.08 GiB on 2026-07-31T11:26:08Z.** Live `df -k
/System/Volumes/Data` at report time (2026-08-01T17:54 PDT / 2026-08-02
T00:54Z) reads **862,674,740 KB used = 822.53 GiB, 45,290,576 KB free =
43.19 GiB, 96% capacity.** Gap = 822.53 − 762.08 = **60.45 GiB over ~13.5
hours.** Naively annualized that is an alarming ~107 GiB/day — **this is
the wrong read** (see headline finding): the floor snapshot landed at a
trough of the daily sawtooth and the live reading landed near a peak of
the *same* oscillation (2026-08-01's own observed range is 762.23-836.95
GiB, which brackets both numbers). The 7-day and 48h trend lines (net
-3.93 and -13.43 GiB/day) are the trustworthy growth-rate figures, not
this single floor-to-instant delta.

## Step 2 — Per-path ≥5 GiB bucket delta table (ledger-only)

Coverage in the ledger is **badly intermittent**: of the 12 daily
snapshots above, only 5 (07-23, 07-24, 07-28, 07-29, 07-30) have any
`granularity_buckets`; the other 7 — including **both** days since the
988f4c7 EINTR fix (07-31, 08-01) — show `residual_kb == disk_used_kb`,
i.e. **0% measured coverage that day.** Using the earliest and latest
snapshots that actually have bucket data (07-23 → 07-30, an 8-day span),
and filtering to any path ≥5 GiB in either snapshot:

| path | 07-23 GiB | 07-30 GiB | Δ GiB |
|---|---:|---:|---:|
| `~/Library/CloudStorage/Dropbox/conversation-backups/codex_conv*` | 12.22 | 0.00 | **-12.22** |
| `~/.codex` | 6.38 | 5.65 | -0.74 |

That is the **entire** ≥5 GiB delta table the ledger can produce — two
paths, both shrinking, net -12.95 GiB. **The ledger's per-path buckets do
not explain the growth side of the gap at all**; the unmeasured residual
(258-291 GiB across the covered days) dominates by two orders of
magnitude over anything the buckets can attribute. This is itself the
most important structural finding: coverage is too sparse and too
intermittent to root-cause growth from the ledger alone, which is why
Step 3's live spot-checks (disk_observer.jsonl, host-disk-guardian.log,
direct `du`) carried almost the entire explanatory weight in this pass.

## Step 3 — Ranked live producers (measured rates, cross-verified)

1. **Nothing is currently the dominant net producer.** Net 7-day/48h
   trend is shrinking (-3.93 / -13.43 GiB/day); the visible "growth" is
   intra-day amplitude, not accumulation.
2. **`/private/tmp` AO/CI scratch churn — reversed from the 2026-07-29
   finding.** Then: +23-25 GiB/day gross, +4.97 GiB/day net, dominant
   producer. Now: **total measured size is 4.0 GiB** (`du -d 1 -h`
   completed in seconds, no stall). The largest live items are all
   dated 2026-08-01 (today) with clean git worktrees on active branches
   — genuine in-progress agent work, not cruft. Not currently dominant.
3. **host-disk-guardian's auto-clean is still functionally inert on real
   targets — unchanged regression from 2026-07-29.** `runs=540`,
   interval 900s, healthy and firing. Full log (2,721 lines,
   2026-07-23→08-02) parsed: 102 CRITICAL-tier events, all in one burst
   2026-07-31T00:18-17:24, every single one only deleted tiny
   `/private/tmp/claude-501/<hash>/*` scratchpad state (12 total across
   the whole log). Every `wa-pr*`/`wa-tier-wt`/`wa-stateupdates`
   candidate in the same runs was **skipped** (242 skip lines: "no
   merged PR found" / "uncommitted changes present") — **zero** real
   worktree/evidence-bundle reclaims anywhere in the log. The safety net
   is alive but still cannot touch the paths that would matter.
4. **Colima — shrinking, not a driver.** Real on-disk usage (`du -sh`,
   not apparent/sparse size): datadisk 28 GiB + diffdisk 1.2 GiB = 29.2
   GiB real, against a 120 GiB configured cap. Continues the prior
   -0.90 GiB/day shrink trend. `docker system df`: 15.3 GB images+
   containers, consistent.
5. **The 4 RunAtLoad-fixed weekly sweepers (colima-prune, hermes-vacuum,
   playwright-dedup, worktree-venvs) are holding, not regressed.** Each
   shows `runs=1, last exit=0` via `launchctl print`. `StartInterval` is
   7 days and the fix landed 2026-07-29, so the next natural fire isn't
   due until ~2026-08-05 — `runs=1` is the *expected* state right now,
   not evidence the fix stopped working.
6. **Frontier-nightly scan coverage collapsed to zero on both days since
   the 988f4c7 EINTR fix — a NEW, more severe bug, not the one the fix
   targeted.** See Step 4.

## Step 4 — Did 988f4c7 (EINTR fix) actually help? No usable evidence either way, and it's sitting on top of a worse bug.

`~/.disk_magician_state/frontier_last.json` (captured 2026-08-01T11:26:06Z,
`schema_version: 2`, confirming the new code is what ran) shows:
`warnings: ["one-pass gdu inventory rejected; falling back to frontier:
inventory_timeout"]`, then `nodes_processed: 0`, `granularity_buckets: []`,
and all 18 top-level children (`/System/Volumes/Data/Users`, `/private`,
`/Library`, `/Applications`, etc.) landed in `frontier_unfinished` with
`reason: "time_budget_exhausted"` at `depth: 1` — the scanner did not
finish enumerating even the *first level* of any top-level directory in
its full 45-minute budget. This is a **total stall**, not the
partial-coverage EINTR problem 988f4c7 was written to fix.

**Root cause (verified by direct code read, `src/disk_magician/scripts/
disk_frontier_scan.py`, current HEAD):**
- `run_one_pass_inventory()` (L912-917) hands its single `gdu` subprocess
  the **entire remaining wall-clock cap** (2700s) as its own timeout, with
  **zero time reserved** for the per-node BFS fallback if `gdu` fails.
- Even the last *successful* run (2026-07-30) consumed 2662.9/2700.0s
  (98.6% of budget) — essentially no margin already existed.
- When `gdu` itself times out (`subprocess.TimeoutExpired` → L286-295 →
  `inventory_timeout`), control falls to the BFS fallback at L1188, whose
  first loop iteration checks `elapsed() > wall_clock_cap` (L1208) — since
  the timed-out `gdu` call already consumed the entire cap, this is
  **true on the very first check**, so all 18 level-1 children are marked
  `time_budget_exhausted` **before `process_node()` runs even once.**
  That is the exact, complete mechanism for `nodes_processed=0`.
- This budget-allocation design predates 988f4c7 (shipped in an earlier
  commit `12a7e9b "inventory disk in one pass"`). 988f4c7's actual diff
  (verified via `git show --stat`: 90 insertions/30 deletions, one file)
  only adds EINTR retry to `list_children()`'s `os.scandir` call — it does
  **not** touch `run_gdu_inventory`/`run_one_pass_inventory` at all.
- Byte-for-byte comparison of the 07-31 and 08-01 frontier-log JSON blocks
  (`~/Library/Logs/disk-magician-frontier.log`) shows **identical**
  structural failure (same `elapsed_s≈2700.1-2700.2`, same 18-entry
  unfinished list, same warning text) — only disk-usage counters differ.
  **The stall broke the same night 988f4c7 merged and has not changed
  since** — not "worked briefly, then regressed."
- **Verdict: the timing correlation with 988f4c7 is real (07-31 was the
  first nightly run after the merge) but not proven causal.** The more
  defensible explanation is the pre-existing ~1.4% budget margin plus
  ordinary day-to-day variance (the box is independently confirmed under
  severe load right now: `uptime` → load averages 52.93/87.88/286.10,
  `top -l 1` → ~91% combined CPU busy — consistent with, not proof of,
  tipping a marginal scan over the edge). **Net effect either way: the
  EINTR fix's claimed 30-60 GiB coverage unlock is unverifiable from the
  ledger, because the scanner has produced zero coverage on every day
  since the fix landed.**
- **Separate, real finding:** the uv-tool-packaged deploy
  (`~/.local/share/uv/tools/disk-magician/.../disk_frontier_scan.py`) is
  **stale** — pinned via `uv-receipt.toml` to commit `fdb41ae2` (2026-07-26),
  3 commits and 5 days behind HEAD, missing the EINTR fix entirely.
  This does **not** cause the current stall (the frontier-nightly launchd
  job runs the repo-root script directly per its plist, not the uv-tool
  copy) but confirms "commit is not deploy" is still live for this
  package and will matter the next time someone assumes the packaged
  scanner has the fix.
- **Recommended fix direction (not implemented — read-only mission):**
  reserve a fixed fraction of `wall_clock_cap` for the one-pass `gdu`
  timeout (e.g. `wall_clock_cap * 0.7`), so a failed one-pass attempt
  always leaves real time for the per-node BFS fallback instead of an
  all-or-nothing single shot.

## Deferred-item re-check (mission-mandated)

- **`disk_magician-ax0` (P1, runaway cursor-agent log PID 95634) — the
  mission brief's "AWAITING OPERATOR DECISION" framing is STALE.**
  Independently verified via `br show disk_magician-ax0`: status
  **CLOSED 2026-07-29**. The operator killed PID 95634 and truncated the
  log same-day (~02:30-02:39 PDT), 43 GB freed. Re-measurement confirms
  the kill is durable: `ps -p 95634` → no such process; `lsof` on the
  exact log path → file does not exist; the `cursor-agent-logs-501/`
  directory now contains 34 small files (max 187.9 KB, newest 07-31) —
  no recurrence. Prevention (verified still active today):
  `CURSOR_AGENT_DISABLE_DEBUG_LOG=1` in `~/.bashrc:1697`, and
  `attributeCommitsToAgent=false`/`attributePRsToAgent=false` in
  `~/.cursor/cli-config.json` (disables the `commitScoring` infinite-loop
  root cause). Follow-up watchdog work remains open at `disk_magician-rvf`.
- **`disk_magician-nea` (P2, residual_drilldown gating on delta instead
  of absolute) — CLOSED 2026-07-29, fix commit `144845a` confirmed live.**
  Note: the repo working tree has a further **uncommitted** diff to
  `residual_drilldown.sh` (+17/-8) that reorders the gate to prefer
  `residual_gb` first, then a `100-coverage_pct` derivation, then
  `residual_delta_gb` as last resort. This is legitimate in-progress
  follow-on work, unrelated to the frontier-stall bug above — left
  untouched per instructions not to clobber other agents' work.
- **`disk_magician-w7m` (P2, overlapping `cleanup_worktree_venvs.sh`
  invocations) — still OPEN, not re-verified in this pass.** Lane B
  confirmed the 4 RunAtLoad-fixed sweepers show `runs=1, exit 0` with no
  second fire yet due (interval 7d, not due until ~08-05), but did not
  specifically check for overlapping/concurrent PIDs of the venv
  cleanup script. Left open for a future pass once a second natural
  fire has occurred to observe.

## Quick wins (safety-gated inventory, reported separately — NOT executed)

Per repo policy this mission is READ-ONLY; the following is an inventory
only, ranked by size, for a human operator to act on:

| Candidate | Size | Verdict | Why not actioned now |
|---|---:|---|---|
| `~/.colima` | 29 GiB | Not a delete candidate | Operational reclaim only (`colima stop/start` + in-VM `fstrim`); already down sharply from a prior ~186 GiB reading |
| `~/.worktrees` large children | 7.7 GiB total | Blocked by 14-day rule | Already shrank from 34.87 GiB (07-29) to 7.7 GiB via another sweeper; closest child is 9 days old, needs 5 more days |
| `venv.bak.20260703-*` ×3 | ~2.17 GiB | Blocked by 14-day rule | Parent worktree touched 5 days ago — CLAUDE.md protects the whole worktree, not just the `.bak` rename date |
| `/private/tmp/ambientfix` | 1.7 GiB | Not safe | Active branch, 4 days old |
| `/private/tmp` PR/AO scratch (6 dirs) | ~1.9 GiB | Not safe | All touched today (2026-08-01) or within 1-4 days, clean git worktrees — live agent work |
| `~/.cursor` | 1.8 GiB | Needs decision | Real chat history + workspace cache, no obvious safe-delete subset |

**No item is safe to delete today.** The only concrete near-term win,
once the 14-day floor clears in 2-9 days, is re-running
`scripts/worktree_hygiene.sh` scoped per-repo — worth ~9.9 GiB
(`~/.worktrees` + `venv.bak` dirs combined). Note also:
`safety.local.json` does not exist on this machine (only the gitignored
template) — every `safety_check.sh` call defaults to "OK" because no
machine-local rule fires; the 14-day-rule and never-delete-list checks
above were cross-checked manually against
`scripts/lib/worktree_recency.sh` instead of trusting that default.

## What this pass changes about the prevention-gap picture

The 8+ prevention layers deployed across 2026-07-11 through 2026-07-30
(RunAtLoad fixes, EINTR retry, absolute-residual gating, cursor debug-log
env var, etc.) are **holding** where they were designed to hold (sweepers
fire, cursor log hasn't recurred, Colima shrinking). The gap this pass
surfaces is different in kind from prior passes: it is not "a sweeper
never fires" but **"the frontier scanner's own timeout budget has ~1.4%
margin and, once it trips, fails totally (0 buckets) instead of
partially"** — a fragility in the measurement layer itself, not the
reclaim layer. That fragility is why 5 of the last 6 daily ledger
snapshots have no per-path data at all, which in turn is why Step 2's
delta table above is so thin. Fixing the budget-allocation bug (Step 4's
recommended direction) is the highest-leverage next step for restoring
*measurement* reliability; it is separate from, and does not itself
reclaim, any disk space.

## Provenance

- Lane reports: `docs/lane-A-frontier-stall.md`, `docs/lane-B-producer-
  liveness.md`, `docs/lane-C-cursor-log-ax0.md`, `docs/lane-D-quickwins.md`
  under the sidekick STATE dir.
- Raw ledger extracts: `docs/ledger-<sha>.json` ×12 (2026-07-21→08-01),
  same STATE dir.
- Bead: `disk_magician-dgs` (this mission). Related beads verified this
  pass: `disk_magician-ax0` (CLOSED), `disk_magician-nea` (CLOSED),
  `disk_magician-w7m` (OPEN, unverified this pass), `disk_magician-rvf`
  (OPEN, follow-up watchdog).
- Prior reports: `roadmap/2026-07-29-disk-regrowth-rootcause-sidekick.md`,
  `roadmap/research-residual-296gib-20260730-update1.md`.
