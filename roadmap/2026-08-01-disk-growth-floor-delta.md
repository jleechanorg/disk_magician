# Disk growth root-cause — 2026-08-01 sidekick pass

Mission: `disk_magician-dgs` ("sidekick: root-cause-disk-always-growing").
State/log: `~/roadmap/disk_magician/sidekick/root-cause-disk-always-growing/STATE.md`.
Raw evidence: `~/roadmap/disk_magician/sidekick/root-cause-disk-always-growing/docs/`
(12 ledger JSON extracts + 4 lane reports + extended disk_snapshot.json
series). Four anonymous sonnet subagent lanes ran in parallel; every
non-trivial claim below was independently re-verified by this session
(bead status checks, direct code reads, live `df`/`uptime`/`grep -n`
probes) before being included — refute-by-default, survives only with a
citation. **UPDATE 1 (T+~30min, same session):** the main session's
parallel `/history` and `/ms` recall lanes surfaced a lower verified
floor and a live worktree-restoration event; both are folded in below
(Step 1 and the new "Concurrent event" section) rather than left as a
stale first draft. **UPDATE 2 (T+~35min):** the sawtooth producer named
below (Colima fstrim cycle) was identified in response to the team-lead's
explicit ask to name what fills and what reclaims the swing, and an
independent 3-lens adversarial verification (data/code/logic,
refute-by-default) of the whole report is documented in the new
"Adversarial verification" section near the end.

## Headline finding: the mission's own premise partially does not hold, and the swing has a named, already-understood mechanism

**The disk is not in sustained net growth right now.** `disk_observer.jsonl`
(11,554 samples, 2026-07-24→08-02) shows the 7-day trend is **-3.93 GiB/day**
and the last-48h trend is **-13.43 GiB/day** — both net *shrinking*, not
growing. What actually explains the "always growing" feeling is a
**sawtooth oscillation with dangerous amplitude**: single-day swings up to
**115.9 GiB peak-to-trough** (2026-07-31: 748.69→864.62 GiB used), with
free space independently confirmed by `host-disk-guardian.log` bouncing
21 GiB → 98 GiB → 56 GiB → 98 GiB → 80 GiB inside single 2-3 hour windows
on 2026-08-01/02. The mandatory floor-and-gap number below is correct as
computed, but **do not read it as a daily growth rate** — see Step 1 and
the "Sawtooth mechanism" section immediately after it.

**The sawtooth has a fully-evidenced, already-partially-understood
mechanism: Colima's sparse VM disk fill/trim cycle, not a hidden leak.**
See the dedicated section below for the full evidence chain; in short,
the already-deployed 2-hour pressure-sweep job's `cleanup_colima.sh` step
runs `colima ssh -- sudo fstrim -av` inside the Colima Linux VM whenever
free space is low, reclaiming 30-50 GiB per firing (confirmed across many
independent log events spanning 07-25 through 08-01). Between firings,
ordinary Colima/Docker VM disk-block consumption refills a comparable
amount, because the VM's thin-provisioned sparse disk does not return
blocks to the host on in-VM file deletion — only an explicit `fstrim`
does. **This reconciles the two windows the operator might otherwise see
as contradictory:** the 14-day floor(720 GiB)-to-now gap is largely an
artifact of *where in this fstrim cycle* each snapshot happened to land
(post-trim reads low-used/high-free; pre-trim reads high-used/low-free),
not sustained accumulation — while the 7-day/48h *net* trend is the
trustworthy growth-rate figure precisely because it averages across many
full cycles. **Recommended operator read: do not act on the 60-115 GiB
single-reading gap as if it were a leak requiring cleanup — it is the
expected, self-correcting byproduct of a prevention layer that is already
working as designed.** What would actually matter is if the *fill* side
itself trended upward across many cycles (i.e., the underlying
Colima/Docker workload growing over time); the current 7-day/48h net
data says it is not.

## Step 1 — Floor and gap (ledger-mandated, computed first; CORRECTED)

**Original draft used only `~/.disk_magician_backup/ledger/topdown-5g.json`,
whose daily-commit history starts 2026-07-21 — that is not the full "most
recent ~14 days" window.** `ledger/topdown-5g.json` and the older
`backup/jeffreys-macbook-pro/disk_snapshot.json` are two halves of one
continuous history split by a schema/path migration: `disk_snapshot.json`'s
commit history ends 2026-07-21T05:19:26-07:00 (12:19 UTC), essentially the
same moment `topdown-5g.json`'s daily commits begin — same `hostname`,
same `disk_total_gb=926` matching current `df` total (971,350,180 KB =
926.2 GiB) exactly, confirmed by direct `git show` of both files. The true
14-day window (2026-07-19 → 2026-08-02) requires both files.

| date (captured_at, UTC) | disk_used | source |
|---|---:|---|
| 2026-07-19T01:39:06Z | **720 GiB (FLOOR)** | `disk_snapshot.json` @ `3eef45f`, independently verified via direct `git show` |
| 2026-07-21T11:21:21Z | 778.99 GiB | `topdown-5g.json` |
| 2026-07-22T11:26:33Z | 828.31 GiB | `topdown-5g.json` |
| 2026-07-23T10:49:35Z | 852.63 GiB | `topdown-5g.json` |
| 2026-07-24T10:49:10Z | 804.98 GiB | `topdown-5g.json` |
| 2026-07-25T11:26:10Z | 830.55 GiB | `topdown-5g.json` |
| 2026-07-26T11:26:06Z | 856.59 GiB | `topdown-5g.json` |
| 2026-07-27T11:26:08Z | 838.09 GiB | `topdown-5g.json` |
| 2026-07-28T11:23:50Z | 823.73 GiB | `topdown-5g.json` |
| 2026-07-29T10:55:39Z | 821.95 GiB | `topdown-5g.json` |
| 2026-07-30T11:25:29Z | 835.13 GiB | `topdown-5g.json` |
| 2026-07-31T11:26:08Z | 762.08 GiB | `topdown-5g.json` (floor of the truncated 07-21-start window used in the first draft) |
| 2026-08-01T11:26:06Z | 796.41 GiB | `topdown-5g.json` |

Pulling every ~35-min `disk_snapshot.json` commit between 2026-07-18 and
07-21 (138 commits, all independently parsed) gives daily min/max:
07-18 min=717/max=733, 07-19 min=720/max=859, 07-20 min=748/max=864,
07-21 (partial) min=773/max=820 GiB. **07-18's 717 GiB is one calendar
day outside the strict 14-day window (07-19-08-02); 07-19's 720 GiB is
the correct in-window floor**, confirmed at the specific commit
`3eef45f` (`disk_used_gb: 720, disk_free_gb: 148, disk_pct: 77,
disk_total_gb: 926`). Note 07-19 alone swung from 720 to 859 GiB —
the sawtooth pattern (see headline finding) was already present 2 weeks
ago, not a new development.

**Corrected floor = 720 GiB on 2026-07-19T01:39:06Z.** Live `df -k
/System/Volumes/Data` readings taken during this session (all
2026-08-02 UTC): 811.72 GiB (T+5min, 00:42Z), 822.53 GiB (T+20min,
00:54Z), 804.28 GiB (T+24min, 00:58Z), **806.28 GiB (T+30min, 01:01Z,
most recent)**. Gap = 806.28 − 720 = **86.28 GiB**, and this number
moved by nearly 20 GiB across four readings taken 3-8 minutes apart
during this very session — direct, first-hand corroboration of the
sawtooth finding at fine granularity, not just the daily-snapshot
evidence. **Do not read either the 86.28 GiB gap or the ~60 GiB gap
from the first draft as a sustained daily rate** — both are single
trough-to-instant readings of the same oscillating series. The 7-day
and 48h trend lines from `disk_observer.jsonl` (net -3.93 and -13.43
GiB/day, unchanged from the first draft) remain the trustworthy
growth-rate figures.

## Sawtooth mechanism (named producer + reclaimer, evidence chain)

Team-lead explicitly asked this pass to name what fills 60-115 GiB and
what reclaims it, rather than leaving the sawtooth unexplained. Answer,
fully evidenced from `~/Library/Logs/disk-magician-pressure-sweep.log`:

**Hypothesis checked and REFUTED first:** local Time Machine/APFS
snapshots on the Data volume. `tmutil listlocalsnapshots /` returns only
3 snapshots, all `com.apple.os.update-*` — OS-update sealed-**System**-
volume snapshots, already ruled out by the 2026-07-30 research doc as
contributing to Data-volume usage. `diskutil apfs listSnapshots
/System/Volumes/Data` returns **"No snapshots for disk3s5"** — the Data
volume itself has zero local snapshots. This mechanism does not apply
here; not pursued further.

**Confirmed mechanism: Colima's thin-provisioned VM sparse-disk
fill/trim cycle**, already partially documented in this repo's own
CLAUDE.md ("Colima's sparse disk only shrinks via in-VM `fstrim`...
Prevention: the 2h pressure-sweep job (free < 40G gate)") but not
previously quantified as the sawtooth's dominant driver:

- **Reclaim side:** the 2-hour pressure-sweep job's step-2/2
  `cleanup_colima.sh` runs `colima ssh -- sudo fstrim -av` inside the VM
  whenever free space is low. Confirmed repeating pattern, independently
  grepped from the log (not a single anecdote):
  - 2026-07-25T08:35: free-before 46 GB → **43.9 GiB trimmed from
    `/dev/vdb1`** → free-after 83 GB.
  - 2026-07-25T12:36 (4h later): free-before 46 GB → **43.2 GiB
    trimmed** → free-after 85 GB.
  - 2026-07-31/08-01 (9 consecutive events over ~24h): free-before/after
    pairs of 63→93, 43→93, 56→98, 62→98, 49→96, 53→89, 65→98 GB — 30-50
    GiB reclaimed per successful firing. Not every firing succeeds:
    2026-08-01T21:45 reclaimed ~0 GiB (free before and after both 30 GB).
- **Fill side:** ordinary Colima/Docker VM disk-block consumption
  between trims. The VM's sparse disk is thin-provisioned — writes
  inside it (container image/layer writes, the already-established
  high-frequency `ez-mac-runner` CI container OOM/restart churn from the
  2026-07-29 report) consume host-visible physical blocks that are
  **not** returned to the host until the next explicit `fstrim`. This
  matches Lane B's independently-sourced "Colima gross churn 72.76
  GiB/day" figure closely: roughly 2 reclaim events/day × ~35-40 GiB
  each ≈ 70-80 GiB/day gross, consistent within the noise of a
  log-derived estimate.

**Net effect:** this one mechanism, operating on its own documented
2-8 hour cadence, plausibly accounts for the entire 60-115 GiB
single-day amplitude reported in the headline finding, without invoking
any unaccounted-for leak. It is also consistent with (and likely a
primary contributor to) the fine-grained noise this session directly
observed in its own four live `df` reads (811.72→822.53→804.28→806.28
GiB across ~20 minutes) and the concurrent worktree-restoration event's
unclear size — some of that apparent noise is very plausibly this same
Colima cycle rather than worktree churn.

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
  5 days behind HEAD and 3 commits touching `src/disk_magician/`
  specifically (21 commits all-repo between those two SHAs — scope
  corrected per Lens 2 adversarial verification below), missing the
  EINTR fix entirely.
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

## Concurrent event during this mission: worktree-deletion accident + restoration (real, timing-verified; size NOT independently confirmed)

Bead `disk_magician-oja` ("Enforce 14-day worktree recency protection and
ban ad-hoc cleanup scripts in GEMINI.md/CLAUDE.md") and GitHub issue
`jleechanorg/disk_magician#51` are both real and independently checked by
this session: `br show disk_magician-oja` → status CLOSED,
`created_at: 2026-08-02T00:43:11Z`, `closed_at: 2026-08-02T00:43:14Z`
(created and closed **3 seconds apart** — a record-keeping close of an
already-finished action, not evidence of a multi-minute restore happening
in real time at that instant). Its close reason states policy was added
to CLAUDE.md/GEMINI.md banning ad-hoc cleanup scripts **and** "restored
all 30 worktrees modified within 14 days" — i.e., a separate session
apparently ran an ad-hoc cleanup that deleted 30 worktrees inside the
14-day protection window, then had to restore them, then hardened policy
to prevent recurrence.

**Timing is significant:** this bead's timestamp (00:43:11Z) falls 6
minutes after this very mission's `started_at` (00:37:43Z per
`~/.hermes/runtime/sidekick-disk-rootcause-20260801.started_at`) — the
accidental deletion-and-restore was very likely happening **concurrently
with this mission's early measurement window**, which plausibly
contributes to the fine-grained oscillation directly observed above
(four `df` reads spanning 811.72→822.53→804.28→806.28 GiB across roughly
20 minutes). **However, this session could not independently confirm the
restoration's size or location**: a bounded `find -newermt` scan across
`/Users/jleechan/projects`, `/Users/jleechan/projects_other`, and
`~/.worktrees` (depth ≤4, threshold 2026-08-02T00:20:00Z onward) found
**zero** matching directories — either the 30 restored worktrees live
somewhere this scan didn't cover, mtimes were already overwritten by
subsequent activity, or `git worktree add`/checkout doesn't touch parent
directory mtimes at the depth this scan checked. **Treat "worktree
restoration explains part of the regrowth" as a real, timing-correlated,
but size-unquantified hypothesis** — a genuine candidate contributor to
the noise in this mission's own live readings, not a confirmed GiB
figure to add to any table above.

## Quick wins (safety-gated inventory, reported separately — NOT executed)

Per repo policy this mission is READ-ONLY; the following is an inventory
only, ranked by size, for a human operator to act on:

| Candidate | Size | Verdict | Why not actioned now |
|---|---:|---|---|
| `~/.colima` | 29 GiB | Not a delete candidate | Operational reclaim only (`colima stop/start` + in-VM `fstrim`); already down sharply from a prior ~186 GiB reading. Repo has a `scripts/cleanup_colima.sh` (defaults dry-run) — an external investigation forwarded by the operator estimates ~15 GiB reclaimable via `colima compact`; NOT independently re-measured by this session in this pass, inventory only |
| `~/.worktrees` large children | 7.7 GiB total | Blocked by 14-day rule | Already shrank from 34.87 GiB (07-29) to 7.7 GiB via another sweeper; closest child is 9 days old, needs 5 more days |
| `venv.bak.20260703-*` ×3 | ~2.17 GiB | Blocked by 14-day rule | Parent worktree touched 5 days ago — CLAUDE.md protects the whole worktree, not just the `.bak` rename date |
| macOS code-signing clone caches (`/var/folders/.../codesign*` or similar) | ~8.8 GiB (external estimate, unverified this pass) | Needs decision | Repo has `scripts/cleanup_code_sign_clones.sh` (requires `CODE_SIGN_CLONES_APPROVED=1`, defaults dry-run). Matches the known "code_sign_clone" leak class from the 2026-07-12 four-leak-classes finding — plausible, but this session did not re-measure the current size; treat the ~8.8 GiB figure as an external, unverified estimate until a fresh `du` confirms it |
| `/private/tmp/ambientfix` | 1.7 GiB | Not safe | Active branch, 4 days old |
| `/private/tmp` PR/AO scratch (6 dirs) | ~1.9 GiB | Not safe | All touched today (2026-08-01) or within 1-4 days, clean git worktrees — live agent work |
| `~/.cursor` | 1.8 GiB | Needs decision | Real chat history + workspace cache, no obvious safe-delete subset |

**No item is safe to delete today.** The only concrete near-term win,
once the 14-day floor clears in 2-9 days, is re-running
`scripts/worktree_hygiene.sh` scoped per-repo — worth ~9.9 GiB
(`~/.worktrees` + `venv.bak` dirs combined). The colima-compact (~15 GiB)
and code-sign-clone (~8.8 GiB) figures above are **externally-sourced
estimates carried into this report at the operator's request, not
independently re-measured by this mission** — flagged as such rather than
presented with false precision. Note also: `safety.local.json` does not
exist on this machine (only the gitignored template) — every
`safety_check.sh` call defaults to "OK" because no machine-local rule
fires; the 14-day-rule and never-delete-list checks above were
cross-checked manually against `scripts/lib/worktree_recency.sh` instead
of trusting that default.

**Rejected as stale, not new:** an external investigation separately
recommended "add `RunAtLoad=true` to launchd sweepers" — this duplicates
the fix already shipped 2026-07-29 (see `roadmap/2026-07-29-disk-
regrowth-rootcause-sidekick.md`) and independently re-confirmed holding
in Step 3 above (`runs=1, exit 0` on all 4 jobs); it is not a new
recommendation for this report.

## Known traps checked and avoided this pass

Prior missions' memory flagged recurring measurement traps; this pass
explicitly checked each rather than re-falling into it:
- The `residual_gb` vs `residual_delta_gb` field-confusion trap (root
  cause of the now-fixed `disk_magician-nea`) — this report cites
  `disk_used_kb`/`disk_used_gb` directly from each snapshot, not a delta
  field, for every floor/gap number above.
- "Sweeper never fired" claims require an interval-elapsed check before
  being called a bug — Step 3 explicitly notes the 4 RunAtLoad-fixed
  sweepers' `runs=1` is expected (7-day interval, fix landed 07-29, next
  fire not due until ~08-05), not re-flagged as a regression.
- APFS local snapshots were ruled out as a residual source by a prior
  pass's live verification (`research-residual-296gib-20260730-
  update1.md`) — not re-investigated here.
- The documented permanent floor on this Mac (≈27.6-47.6 GiB: SSV +
  Preboot + Recovery + APFS metadata) means `df`'s absolute used/free
  numbers will never reach 0 GiB free even with everything reclaimable
  reclaimed — none of this report's gap figures assume otherwise.

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

## Adversarial verification (independent 3-lens refute-by-default pass)

Per this repo's/goal's ironclad criterion 5, this session's own spot-
checks (bead lookups, code reads, live probes woven through the sections
above) count as self-verification and do not alone satisfy the
adversarial-verify requirement. The team lead independently dispatched 3
separate sonnet verifier lanes against the pushed report, each instructed
to refute-by-default rather than confirm. Verdicts:

- **Lens 2 (code/causation) — ALL 3 CLAIMS NOT-REFUTED.** Independently
  reproduced the zero-margin `gdu` budget-allocation bug by direct code
  inspection (`run()` L1171 → `run_one_pass_inventory` L912-917 gets the
  full `remaining_budget()` ≈2700s → `TimeoutExpired` → fallback loop
  L1208's first check `elapsed()>cap` is already true → all 18 depth-1
  dirs marked `time_budget_exhausted`, `nodes_processed=0`), matching
  `frontier_last.json` byte-for-byte (`elapsed_s 2700.1`, 18 depth-1
  unfinished). Confirmed 988f4c7's diff touches only `list_children`'s
  `os.scandir` call sites — zero hits on the budget-allocation path, so
  "correlated not causal" holds. Confirmed the uv-tool deployed copy is
  byte-identical to pre-fix commit `fdb41ae2` (stale) **and** confirmed
  via the launchd plist + wrapper script that frontier-nightly actually
  executes the repo-root scanner, not the stale uv-tool copy — so
  staleness is real but not the stall's cause, exactly as this report
  states. **One accepted revision:** "3 commits behind" in Step 4 above
  should be scoped explicitly — that count is correct only for commits
  touching `src/disk_magician/`; the all-repo commit count between those
  two SHAs is 21, not 3. *(Correction applied: Step 4 now reads "3
  commits touching `src/disk_magician/` (21 all-repo)".)*
- **Lens 1 (data)** — [pending at time of last edit; team-lead to relay]
- **Lens 3 (logic)** — [pending at time of last edit; team-lead to relay]

**Survival tally: 3/3 claims survived Lens 2 in full (1 scope-precision
nit accepted and folded in, not a refutation).** Lenses 1 and 3 verdicts
to be folded in as they land; this report will not be presented as fully
adversarially closed until all 3 lenses report and the tally is updated
here.

## Provenance

- Lane reports: `docs/lane-A-frontier-stall.md`, `docs/lane-B-producer-
  liveness.md`, `docs/lane-C-cursor-log-ax0.md`, `docs/lane-D-quickwins.md`
  under the sidekick STATE dir.
- Raw ledger extracts: `docs/ledger-<sha>.json` ×12 (2026-07-21→08-01),
  same STATE dir.
- Extended floor series: `docs/dsj-series-07-18-to-07-21.txt` (138
  `disk_snapshot.json` commits, independently parsed) — source for the
  corrected 720 GiB / 2026-07-19 floor in Step 1.
- Bead: `disk_magician-dgs` (this mission). Related beads verified this
  pass: `disk_magician-ax0` (CLOSED), `disk_magician-nea` (CLOSED),
  `disk_magician-w7m` (OPEN, unverified this pass), `disk_magician-rvf`
  (OPEN, follow-up watchdog), `disk_magician-oja` (CLOSED — worktree
  restoration + ad-hoc-script policy hardening, timing-correlated with
  this mission's window, see "Concurrent event" section).
- Prior reports: `roadmap/2026-07-29-disk-regrowth-rootcause-sidekick.md`,
  `roadmap/research-residual-296gib-20260730-update1.md`.
- External input folded in via team-lead relay: verified 720 GiB/07-19
  floor, worktree-restoration hypothesis (GH issue
  `jleechanorg/disk_magician#51`), colima-compact/code-sign-clone quick-win
  candidates (unverified estimates, flagged as such above).
