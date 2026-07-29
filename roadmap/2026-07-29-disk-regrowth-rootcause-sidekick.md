# Disk regrowth root-cause report — 2026-07-29 sidekick pass

Mission: `disk_magician-7io` ("sidekick: root-cause-disk-keeps-filling").
State/log: `~/roadmap/disk_magician/sidekick/root-cause-disk-keeps-filling/STATE.md`.
Disk at spawn: `/System/Volumes/Data` 833 GiB used / 29 GiB avail (97%
capacity). This report follows the mandatory three-lane structure: (1)
top-down reconciliation with explicit unattributed residual, (2)
coverage-validated growth-rate deltas, (3) safety-gated quick wins listed
separately from the explanation.

## Executive summary

**Single most actionable finding, added by a parallel measurement lane
(`measure-topdown.md`) and confirmed live by this session:** one Cursor
CLI agent session log file —
`/private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/T/cursor-agent-logs-501/session-2026-07-27T03-00-48-477Z-95634-1.log`
— grew from 25.60 GiB (2026-07-28T11:23:50Z frontier-scan capture) to
**42.24 GiB / 45,519,296,373 bytes** (2026-07-29T08:56 UTC, this
session's direct `lsof`/`ls` check — 45.52 GB in decimal units, same
measurement, not a second data point), a confirmed **+16.6 GiB in 21.5
hours (~18.5 GiB/day average from a single file)** and observed still
actively growing by two independent watchers (this session's `mtime`
recheck, and a parallel session watching +28 KB per 20s directly).
`lsof` confirms it is open for writing right now by **PID 95634, full
command `~/.local/bin/agent --use-system-ca`, started 2026-07-26 20:00:47
local under parent `bash` PID 20665** — a live Cursor CLI agent session
running continuously for 2+ days with no log rotation. This is larger,
more precisely quantified, and more directly actionable than any other
single finding in this report — filed as bead `disk_magician-ax0` (P1).
**Not
acted on in this pass**: killing PID 95634 or truncating the log is an
irreversible, outward-facing action (may lose in-progress agent work)
requiring
explicit human authorization, not something a read-only root-cause
mission should do unilaterally.

**Trustworthy headline number:** whole-disk usage grew **+7.0 GiB/day net**
over the last 7.86 days (778 → 833 GiB used, from `df`-derived values in
`~/.disk_magician_backup` snapshot history — see Lane 2). This net figure
hides large sawtooth swings (reclaim events of -85, -28, and -27 GiB) on
top of a steadier upward creep, and a path-level ledger whose measurement
coverage has degraded in lockstep with disk pressure (down to 1.0%
coverage — 18 of 58 tracked paths — in the most recent snapshot). Do not
trust a single recent snapshot for "what's using disk right now"; this
report uses the 8-day union of snapshots plus independent live sampling
instead.

**The dominant currently-active producer, confirmed by two independent
measurement passes, is AO/CI `/private/tmp` scratch-worktree churn.** Its
8-day **net** rate is +4.97 GiB/day — on its own already roughly equal to
the sum of every other named producer in Lane 2's table combined, against
a +7.0 GiB/day whole-disk total — so it is the dominant producer on net
terms alone, without needing the more dramatic gross figure. That gross
figure is also real and matters for a different reason: production is
~23–25 GiB/day when unswept, and the most recent unswept climb hit
**+25.2 GiB/day sustained for 1.76 days** before the tracking key itself
timed out under load (true current size likely 65–75+ GiB, unmeasured) —
this is the number that explains *why* net looks moderate (periodic sweeps
partially offset it) while the disk still feels perpetually on the edge.
Critically, `host-disk-guardian.log` shows its CRITICAL-tier auto-clean
firing 3 times in 2 minutes at 0–6 GiB free (not a uniform threshold —
each firing caught a different, still-critical level) and processing
**zero** evidence bundles, scratchpads, or merged-PR worktrees each time —
every `/private/tmp/wa-pr-*` candidate is skipped for "no merged PR found"
or "uncommitted changes present," and a second, independent adversarial
check of `host-disk-guardian-launchd.log` found this same zero-success
pattern repeating across dozens of runs over multiple days, not just this
one 2-minute window. **The safety net is alive but has been structurally
unable to reclaim this path's occupants for days, not just momentarily**
— this is the answer to "why don't sweepers keep up," more directly than
any of the launchd-scheduling bugs below. See Lane 2.

Two structural launchd bugs were found and **fixed** in this pass:

1. **Disk-reclaim impact.** Four weekly reclaim sweepers (colima-prune,
   hermes-vacuum, playwright-dedup, worktree-venvs) had **never fired
   once** since install (2026-07-23) — not a symptom of running-late, a
   structural starvation: `StartInterval=604800` (7 days) resets on every
   per-user launchd reload, and this Mac only reboots every ~2 days, so
   the interval can never accumulate. Fixed with `RunAtLoad=true`;
   verified all 4 fired for the first time immediately after the fix.
2. **Telemetry impact only — no reclaim was lost to this one.** The daily
   growth-tracking snapshot job had been failing `EX_CONFIG` (exit 78)
   every day since 2026-07-25 because its `ProgramArguments` hardcoded a
   `python3.13` site-packages path that stopped existing after a
   `uv tool install --reinstall` bumped the interpreter to python3.14.
   This job only records state for the user_scope backup report — it does
   not reclaim anything itself, and this session's Lane 2 analysis used
   the unaffected `disk_observer.jsonl` series instead, so the outage was
   a diagnostic blind spot, not a disk-growth cause. Fixed by pointing at
   the stable uv-tool entrypoint instead of a version-pinned internal
   path.

A **third bug in the same "sweeper structurally cannot fire" class** was
found by measurement but not fixed: the residual-drilldown sweeper gates
on `residual_delta_gb` (snapshot-to-snapshot delta, ~0.4 GiB) instead of
the absolute `residual_gb` (400–824 GiB across this window), so it logs
"no-op" every ~40 minutes regardless of how catastrophic the absolute
unmeasured residual gets. Filed as bead `disk_magician-nea` (P1), not
fixed in this pass — see Lane 2.

Separately, one more currently-active issue was identified, plus one
observation whose disk-growth relevance did **not** survive adversarial
review as claimed:

- **Downgraded during adversarial review:** the `ez-mac-runner` self-hosted
  CI containers (image `ezgha-runner:latest`) genuinely are OOM-killed and
  relaunched at high frequency (container-lifecycle event counts
  independently re-verified almost exactly, see Lane 2) — but this
  report's earlier claim that this churn is "the single highest-leverage
  fix" for disk growth did **not** survive: the adjacent measured number
  (`colima`'s net rate) is **-0.90 GiB/day, i.e. shrinking** over the same
  window, which cuts against "OOM churn drives disk growth" as stated. The
  causal link between container OOM/restart churn and net disk growth was
  asserted, not established, in the original draft. What *is* established:
  high-frequency container churn is real and worth fixing for its own
  sake (CI reliability, container runtime overhead), just not
  demonstrated here as a disk-growth root cause. See Lane 2 for the
  corrected framing.
- Colima's sparse-disk trim/prune path is **currently broken**: the
  2026-07-29 `colima-prune` run hit an `input/output error` on a
  containerd blob during `docker image prune`, and the subsequent
  `fstrim -av` reclaimed **0 bytes** on the main volumes — independently
  corroborated by two separate measurement passes in this session (72.8
  GiB/day gross-up vs. 578.6 GiB gross-down churn over the 8-day window,
  net only -0.90 GiB/day because the trim isn't landing).

The system was also observed under extreme, unrelated CPU load during this
session (load average swinging 33–959) severe enough that trivial shell
commands took >60s to return — noted as a contributing/related
observation, not independently root-caused.

## Lane 1 — Top-down reconciliation (≥5 GiB granularity, explicit residual)

Source: `~/.disk_magician_state/frontier_last.json` (schema v2 frontier
BFS scan, captured 2026-07-28T11:23:50Z, 42.7 min wall-clock, 5,897
buckets capped at ≤5 GiB granularity each).

| Metric | Value |
|---|---|
| Disk total | 926.5 GiB |
| Disk used (at capture) | 823.7 GiB |
| Disk free (at capture) | 56.2 GiB |
| Measured (attributed) | 532.8 GiB (64.7% of used) |
| **Unattributed residual** | **291.0 GiB (35.3% of used)** |

For context: the 2026-07-22 root-cause pass measured 306.8 GiB attributed
of 852 GiB used (36% coverage, 545 GiB residual) and explicitly concluded
further residual-chasing was not productive with available introspection
(OS-protected/TCC/SIP paths, APFS purgeable/snapshot space). The residual
has shrunk from 545 → 291 GiB since then, but **mostly because the v2
frontier scan's measurement coverage improved (36% → 64.7%)**, not because
actual disk usage dropped much (852 → 823.7 GiB, a modest ~28 GiB
decrease). This report does not re-litigate that residual composition;
see `roadmap/2026-07-22-disk-regrowth-rootcause.md` §"Reclaimable residual"
for what was already ruled out.

**Update: one residual mechanism moved from "hypothesized" to
"confirmed."** A parallel measurement lane ran `diskutil apfs listSnapshots /`
directly and found **3 local APFS snapshots present** (all
`com.apple.os.update-*`, OS-update-prep snapshots, not user Time Machine
snapshots) — one of them (`com.apple.os.update-4B8ED9A3...`) is explicitly
flagged by `diskutil` itself: `NOTE: This snapshot limits the minimum size
of APFS Container disk3`. This means blocks referenced only by that
snapshot cannot be reclaimed by deleting files until the snapshot itself
is deleted — a real, `du`-invisible residual mechanism, not just a
plausible theory. The same lane also enumerated the specific TCC-protected
paths blocking full measurement without a Full Disk Access grant:
`~/Library/{Mail,Messages,Containers,Group Containers}`,
`~/Library/Application Support/MobileSync` (iPhone/iPad backups),
`.DocumentRevisions-V100`, `.Spotlight-V100`, and most of
`/private/var/{networkd,install,spool,...}` — none quantifiable without
`sudo`/Full Disk Access, all folded into the 291 GiB residual. It also
confirmed the frontier scan's own self-reported honesty: `disk_used_kb`
drifted by −2.76 GiB *during the scan's own 43-minute run* — a meaningful
fraction of "residual" is a genuinely moving target on this box, not a
fixed hidden pile.

Top attributed producers, aggregated to ~4 path levels under
`/System/Volumes/Data` (top 15 of 40+ collected, full list in mission
STATE.md):

| GiB | Path |
|---:|---|
| 50.88 | `~/projects/worldarchitect.ai` |
| 21.32 | `~/.codex/sessions` |
| 17.33 | `/private/var/folders/j0` |
| 16.46 | `~/Library/Application Support` |
| 12.93 | `~/.gemini/antigravity-cli` |
| 12.70 | `~/project_worldaiclaw/worldai_claw` |
| 11.27 | `~/Library/Developer` |
| 9.62 | `~/Library/Caches` |
| 9.27 | `~/.worktrees/worldarchitect` |
| 9.16 | `~/projects/user_scope` |
| 7.85 | `~/.claude/projects` |
| 5.75 | `~/.ao/data` |
| 5.64 | `~/.codex` (direct, excl. sessions) |
| 5.57 | `~/.colima/_lima` |
| 5.22 | `~/.nvm/versions` |

`~/projects/worldarchitect.ai` at 50.88 GiB (54.32 GiB by a second,
slightly different pass over the same frontier buckets — within the
scanner's own known accounting slack, see Addendum) is the single largest
attributed item. Broken down from the frontier scan's own sub-buckets:

- **42.20 GiB (78%) in `.claude/worktrees/*`** — 131 distinct (verified
  independently: 132 at re-count, off by one, negligible drift)
  agent/workflow worktrees (`agent-<hash>`, `wf_<id>`). Sampled 8 of 131 at
  random with the canonical `worktree_age_days` helper
  (`scripts/lib/worktree_recency.sh`, real content-mtime measurement, not
  a proxy): **all 8 measured exactly 2 days old** — well inside the
  mandatory 14-day protected window (an independent adversarial resample
  of 8 more got 7/8 at exactly 2 days, 1/8 at 0 days, corroborating the
  clustering). **For cleanup purposes this is correctly protected — not a
  safe reclaim target.**
  **Rate-derivation caveat added post-review:** the original draft divided
  standing stock by observed age to claim "~20 GiB/day of production."
  Adversarial review flagged that dividing stock by age only estimates a
  genuine *rate* if worktrees are created roughly continuously over time
  — but **all 8 samples landing on exactly the same age (2 days) is
  itself evidence against continuous arrival and more consistent with a
  single burst-creation event** (e.g., one mass agent-spawn ~2 days ago),
  which a true steady daily-production process would not produce (you'd
  expect a spread of ages, not uniformity). **Do not read "~20 GiB/day" as
  a demonstrated recurring rate** — the 42.2 GiB figure is solid (measured
  directly), but whether it recurs daily or was a one-time spike is
  unresolved by this sample. It still corroborates the historical "AO
  worktree churn" producer class qualitatively (worktree accumulation
  inside a project checkout, distinct from `/private/tmp`), just not as a
  quantified daily rate. Re-sample in a future pass — ideally with a
  larger sample checked for age *spread*, not just central tendency —
  once agent activity on this repo quiets down; if a meaningful fraction
  age past 14 days, the existing worktree-hygiene tooling can reclaim it
  then.
- 5.94 GiB in `.git/` (mostly the 4.70 GiB pack file — normal git
  history, not a leak).
- 3.27 GiB across other worktree-adjacent dirs (`worldarchitect.ai.worktrees`,
  `.worktrees`, `.git/worktrees`) — same 14-day protection applies, not
  independently sampled this pass.
- Remainder (~2-3 GiB) not broken down further — `venv/`, `.beads/`, and
  smaller items below the ≥5-item cutoff used here.

## Lane 2 — Coverage-validated growth-rate deltas

### Primary source (authoritative, 7.86-day window): `measure-deltas.md`

A parallel measurement teammate mined `~/.disk_magician_backup` git history
(266 parsed `disk_snapshot.json` blobs across 273 commits, 2026-07-21 04:52
→ 2026-07-29 01:23, READ-ONLY, no commits/gc/prune performed) — see
`~/roadmap/disk_magician/sidekick/root-cause-disk-keeps-filling/measure-deltas.md`
for full methodology and raw artifact paths.

**Whole-disk `df` trend (the only fully-trustworthy number in this
report):** 778 → 833 GiB used over 7.855 days = **+7.0 GiB/day net**, free
107 → 29 GiB, capacity 84% → 89% (peaked 93% mid-window). Not monotonic —
large sawtooth reclaim events are superimposed on the upward trend: -85
GiB in 78 minutes (2026-07-23), -28 GiB (2026-07-25→26), -21 GiB
(2026-07-24), -18 GiB (2026-07-26), -27 GiB (2026-07-28→29, immediately
preceding a coverage collapse).

**Coverage caveat — do not trust the most recent snapshot alone:**
`snapshot_coverage_pct` degrades in lockstep with disk pressure, exactly
as a prior finding predicted. It fell from 62.0% (77/77 paths, window
start, healthy) to **1.0% (18/58 paths) at window end** — the snapshot
that matters most for "what's using disk right now" has essentially
collapsed (`tmp_private`, `colima`, `codex_root`, `claude_root`, `hermes`,
`ao_sessions`, `worktrees_dot`, and 30+ others read `null`/timed out). The
824.5 GiB `residual_gb` in that final snapshot is not newly-discovered
dark matter — it's mostly the same paths that measured fine an hour
earlier, now timing out under load. The nightly frontier-BFS top-down scan
is worse still: it returned `measured_total_kb: 0` (0% coverage) for
**three consecutive nights** (2026-07-25, 26, 27) before one partial
success on 2026-07-28 (532.8 GiB measured, 290.9 GiB residual — the
figures used in Lane 1 above), which is now >21 hours stale with no
refresh since.

**Top identified producers, ranked by gross production (the real
root-cause ranking — net alone hides active-but-swept churn):**

| Producer | Net GiB/day | Gross-up GiB/day | Status |
|---|---:|---:|---|
| `tmp_private` (`/private/tmp`, AO/CI scratch worktrees) | +4.97 (8-day avg) | ~23–25 (most recent unswept climb: **+25.2 sustained 1.76 days**) | **ACTIVE, currently invisible to tracker (timed out last 4 snapshots)** |
| `colima` (sparse VM disk) | -0.90 | 72.76 (578.6 GiB gross-down over window) | Trim/prune **currently broken** (I/O error, 0 bytes trimmed) |
| `worktrees_dot` (`~/.worktrees`) | +1.47 | 2.94 | Steady grower, **not swept at all currently** |
| `gemini_root` (`~/.gemini`) | +1.30 | 1.47 | Growing, **no sweeper** |
| `library_developer` (Xcode/DerivedData-class) | +1.03 | 2.17 | Partial sweeps, net still climbing |
| `projects` (whole `~/projects`) | +0.50 | 7.21 (52.3 GiB gross-down) | Git checkout/rebase churn, mostly self-correcting via 14-day sweeper |
| `ao_home` | +0.88 | 1.25 | Monotonic, **zero observed reclaim** over the window |
| `ao_sessions` | +0.71 | 0.71 | Monotonic, **zero reclaim**, same AO family as above |

`library_messages` (27.25→0.45 GiB, one real step-change, likely a
one-time Messages-cache clear of uncertain provenance) and `pictures`
(13.7→0.0 GiB) are excluded from the table above: `pictures` is confirmed
**measurement noise**, not a real trend — it flaps repeatedly between
exactly 13.7 and 0.0 GiB with no intermediate values, a `du`/timeout
artifact under load. `hermes`/`hermes_prod` are the same physical
directory (symlink alias) — net -0.79 GiB/day, driven by the
`hermes-vacuum` fix's WAL checkpoint (which flushes the WAL but does not
shrink the 6,130.9 MB main `state.db` — a full guarded `VACUUM` has not
run, by design).

**Why the sweepers can't keep up with the #1 producer:**
`host-disk-guardian.log` (2026-07-29 00:46–00:48 local) shows the
CRITICAL-tier auto-clean firing 3 times in 2 minutes at 0/2/6 GiB free
(three separate, still-critical readings, not a single repeated value),
processing **0 evidence bundles, 0 scratchpads, 0 merged-PR worktrees**
every single time — every `/private/tmp/wa-pr-*` candidate is skipped
because it has "no merged PR found for this branch" or "uncommitted
changes present." An independent adversarial re-check of the fuller
`host-disk-guardian-launchd.log` (not just this 2-minute window) found the
same zero-success pattern repeating across dozens of runs spanning
2026-07-26 and 2026-07-27 — this has been a persistent, multi-day
structural failure, not a momentary backlog. The safety net is running,
on schedule, and structurally cannot touch the thing that's filling the
disk. This is a materially different (and more currently-relevant) answer
than the launchd-scheduling bugs fixed elsewhere in this report — those
bugs meant sweepers didn't *run*; this one means a sweeper runs perfectly
and still can't reclaim anything, because its own safety gate (no merged
PR / no uncommitted changes) is being tripped by every candidate.

**New prevention-gap bug found, not yet fixed:** `/tmp/disk-magician-drilldown.log`
shows the residual-drilldown sweeper firing every **4 hours** (run
interval 14,400s, 13 logged runs matching `launchctl print` — an earlier
draft of this report incorrectly said "~40 minutes"; corrected during
adversarial verification) and logging "residual 0.4 GB < threshold 10 GB
— no-op," even while `residual_gb` in the *same* snapshots is 400–824
GiB. Confirmed via direct source read
(`scripts/residual_drilldown.sh:108-121`): the primary code path reads
`residual_gb = data["residual_delta_gb"]` (the snapshot-to-snapshot
delta), while the *fallback* path (used only when the delta key is
absent) correctly computes the true absolute-residual formula
(`disk_used_gb * (100 - coverage_pct) / 100`) — proving this is a real
precedence/naming bug, not an intentional "only fire on rapid growth"
design choice. Filed as bead `disk_magician-nea`, **downgraded from P1 to
P2** during adversarial review: this is a diagnostic/observability-only
defect (the drilldown sweeper does not itself reclaim space) with no
established downstream harm, so P1 — reserved for production-impacting or
safety-relevant defects — was disproportionate.

### Secondary source (shorter window, independent data): `disk_observer.jsonl`

This session's own earlier pass over `~/.disk_magician_state/disk_observer.jsonl`
(2,631 records, 2026-07-27 05:24 → 2026-07-29 01:15, 1.83 days) is a
narrower window but an independent data source, and its findings are
consistent with the above: net -2.35 GiB/day but a **62 GiB peak-to-trough
swing in under 2 days** (802.6 → 864.5 GiB), steepest single-hour rise
+26.9 GiB. Docker event counts in one 21-hour climb window: **919
`create`, 903 `die`, 925 `destroy`, 897 `start`, 361 `oom`** — an
adversarial re-check independently reproduced these almost exactly (919/
903/925/897/359) plus the full-history OOM total (547, all on
`ezgha-runner:latest` across exactly 6 named containers), but corrected
the per-container range: actual is **68–120** OOMs per container in under
2 days (the original draft said 68–97, missing that one container,
`ez-mac-runner-b-5`, hit 120 — see
`findings_wiki/extreme-cpu-load-and-ezgha-runner-oom-churn.md`).
**Caveat added post-review:** this high event count is real, but this
report does **not** establish that it causally drives net disk growth —
`colima`'s own net rate over the 8-day window is -0.90 GiB/day
(shrinking), which argues against "OOM churn → disk growth" as a
load-bearing claim; treat the container-churn numbers as a CI-reliability
finding worth fixing in its own right, not a demonstrated root cause of
disk growth. This
data source also captured **direct before/after proof of the RunAtLoad
fix**: used space dropped from an 859.3 GiB peak to 832.6 GiB (-26.7 GiB)
in the window immediately following all 4 sweepers firing for the first
time ever.

Coverage caveat: the daily growth-tracking snapshot
(`~/projects/user_scope/backup/Mac/disk_snapshot.json`) was stale
2026-07-25 → 2026-07-29 due to the `EX_CONFIG` bug (Lane fix #2 above), so
this secondary source leans on `disk_observer.jsonl` (fine-grained,
unaffected by that specific bug) rather than the daily snapshot series.

### Live producer sampling (a third source, minute-scale, `measure-liverate.md`)

A third parallel lane caught the disk red-handed with t0→t3 sampling
(~20 minutes, 2026-07-29 01:37–01:57) across prime-suspect paths. Key
findings that add texture beyond the 8-day and 1.8-day analyses above:

- **The disk oscillates on minute scales, not just day scales.** t0→t1
  (493s): a **-11.42 GiB reclaim**. t1→t3 (723s): **+2.18 GiB regrowth**
  (+248.9 GiB/day extrapolated-instantaneous — clearly a burst, not a
  sustained rate). Available free space moved 29.1 → 39.6 → 38.1 → 37.5
  GiB across the 20-minute session.
- **The -11.42 GiB reclaim was NOT the pressure-sweep job**, contrary to
  the obvious hypothesis. `disk-magician-pressure-sweep.log` shows that
  job fired 10+ minutes *before* this window and reclaimed almost
  nothing: `cleanup_tmp.sh` **timed out (rc=124)**, `cleanup_colima.sh
  --clean` freed **0 bytes** (same containerd I/O error documented
  above). This is a *third* independent confirmation that the disk
  pressure-sweep's own sub-cleaners are currently failing, not just
  colima-prune. The actual -11.42 GiB reclaim mechanism is
  **unidentified** — leading candidates are APFS purgeable/snapshot
  thinning triggered by crossing the <30 GiB-free threshold, or a
  concurrent agent/session in this same multi-lane investigation clearing
  `/private/tmp`/`~/Library/Caches` (no `rm` process was caught alive at
  check time). Flagged as an open question, not resolved this pass.
- **`~/Library/Caches` is the single most volatile path measured this
  session** — it shrank fastest in the reclaim burst (-6.61 GiB in 8.2
  min) and regrew fastest afterward (+0.52 GiB in 14.2 min, +53 GiB/day
  instantaneous). No specific app was attributable (most per-app Caches
  subdirs are SIP/permission-blocked); recommend a Full-Disk-Access
  follow-up pass to attribute which app's cache is churning this hard.
- **11 worktree directories under `~/projects/` vanished mid-`du`-walk**
  (a genuine TOCTOU race — "No such file or directory" mid-read). No
  `rm`/`git worktree remove` process was caught alive afterward. Most
  likely explanation: one of ~22 active AO/wa tmux sessions or ~30
  concurrent `claude --session-id` worker processes self-cleaning its own
  finished scratch worktree — **this reads as normal AO-worker lifecycle
  behavior, not a repeat of the still-unresolved 2026-07-26
  "who-deleted-the-worktrees" mystery** (`disk_magician-y7t`) — flagged
  for completeness, not escalated, since a live process census would be
  needed to confirm and none was performed this pass.
- **Colima's real (non-sparse) block usage was checked directly and
  ruled OUT of this specific regrowth burst**: `stat -f "%b"` on both the
  diffdisk (1.11 GiB real) and datadisk (7.14 GiB real) showed **zero
  byte growth** across a 3-minute sub-window, despite `ls`-apparent sizes
  staying pinned at the sparse 20/100 GiB ceiling the whole session and
  mtimes updating (heartbeat/fsync writes, not net growth). Colima
  remains the most likely *long-term* suspect per prior project history,
  but was not the driver of this particular short burst.
- **New, unverified lead:** a CoreSimulator device process
  (`~/Library/Developer/CoreSimulator/Devices/EFE037C1-.../`, 2.95 GiB
  single snapshot) started exactly at 01:52:15 PDT, inside the
  regrowth window, at 26% CPU — the top candidate to explain the ~1.43
  GiB of the t1→t3 regrowth left unattributed by `/private/tmp` +
  `~/Library/Caches` alone. No before/after delta was captured, so this
  is a lead for a future pass, not a confirmed producer.

## Lane 3 — Safety-gated quick wins (reported separately — NOT the root-cause explanation)

These are recommendations, not actions taken in this pass, and require
`scripts/safety_check.sh` + the worktree 14-day rule before any deletion:

0. **HIGHEST PRIORITY: the runaway cursor-agent log (42.24 GiB, growing
   ~18.5 GiB/day, PID 95634 confirmed still writing).** See Executive
   Summary and bead `disk_magician-ax0`. Recommended action for the human
   operator: check whether PID 95634's Cursor agent session is still
   doing useful work; if not, kill it and truncate/delete the log; if it
   is, at minimum rotate the log now (the file is a `-rw-------` regular
   file under `/private/var/folders/...`, not a worktree, so the 14-day
   worktree rule doesn't apply, but killing a live process is still an
   irreversible action outside this mission's read-only mandate — not
   done in this pass).
1. **`ez-gh-actions` runner memory limit.** Raise the per-container memory
   limit (or reduce concurrent runner count) for `ezgha-runner:latest` to
   stop the high-frequency OOM-cycle per runner. Worth fixing for CI
   reliability regardless of disk impact — adversarial review found the
   disk-growth causal link asserted, not established (see Lane 2), so
   this is no longer framed as "the highest-leverage disk fix"; the
   `/private/tmp` scratch-worktree churn in item 2 of the Executive
   Summary is the better-evidenced target for that. Out of
   `disk_magician`'s scope to change directly; file/track in
   `ez-gh-actions`.
2. **`~/projects/worldarchitect.ai` (50.88 GiB) — mostly NOT currently
   reclaimable.** Broken down in Lane 1 above: 42.20 GiB is 131 active
   `.claude/worktrees/*` agent worktrees, sampled and measured at 2 days
   old (well inside the 14-day floor) — this is in-flight work, not a
   quick win today. Re-run the sample (or a full census) with
   `scripts/lib/worktree_recency.sh` in a future pass once agent activity
   on this repo quiets down; anything that ages past 14 days becomes a
   real reclaim target for the existing worktree-hygiene tooling.
3. **`colima-prune` I/O error — now corroborated, still not root-caused.**
   Two independent measurement passes this session confirm `docker image
   prune -af` is currently failing with an `input/output error` on the
   containerd blob store, and `fstrim -av` is reclaiming 0 bytes on the
   main volumes — this is very likely the documented "Colima sparse disk
   wedges under host disk pressure" gotcha (host has been at 93-97%+
   throughout this session), but a definitive root-cause confirmation
   (e.g. via `colima ssh -- dmesg` or an explicit stop/start/fstrim cycle)
   was not performed this pass — worth doing once host free space is more
   comfortable, since attempting the guest-VM restart cycle while the
   host itself is critically low on space carries its own risk.
4. **`disk_magician-w7m`** (new bead, P2): confirm or refute the
   overlapping `cleanup_worktree_venvs.sh` PIDs observed right after the
   `RunAtLoad` fix; add a flock-style lock if it reproduces under normal
   (non-extreme-load) conditions.
5. **`disk_magician-nea`** (new bead, P1): fix the residual-drilldown
   sweeper's gate to check absolute `residual_gb` instead of
   `residual_delta_gb` — see Lane 2. Low-risk, mechanical fix (change a
   threshold comparison), but out of this pass's time budget to implement
   and verify safely.
6. **`host-disk-guardian`'s emergency-tier candidate filter is too
   strict for a real emergency.** At 2-6 GiB free, the guardian correctly
   refuses to touch `/private/tmp/wa-pr-*` worktrees with uncommitted
   changes or no merged PR — appropriate caution under normal pressure,
   but it means the CRITICAL tier has no actual fallback when literally
   every candidate fails that check (observed live: 3 consecutive
   CRITICAL-tier runs, 0 reclaims each). Recommend a genuinely
   last-resort tier (e.g. archive-not-delete uncommitted scratch worktrees
   to a separate volume/quota once free space crosses a harder floor like
   1-2 GiB) rather than silently no-op'ing at the point of actual
   emergency. Design change, not a quick win — flagging for a dedicated
   follow-up, not implemented this pass.

## Fixes landed this session (durable, committed)

- `disk_magician` repo: `launchd/com.disk-magician.{colima-prune,
  hermes-vacuum,playwright-dedup,worktree-venvs}.plist` +
  `src/disk_magician/launchd/` packaged copies — added `RunAtLoad=true`.
  Installed live via `scripts/install_launchd_sweepers.sh`.
- `user_scope` repo: `dotfiles/launchd/com.jleechan.user-scope-disk-snapshot.plist`
  — `ProgramArguments` now uses the stable `~/.local/bin/disk-magician`
  entrypoint instead of a `python3.13`-pinned internal path; also fixed a
  latent `projects_other` → `projects` path-drift bug in the same
  template. Live plist updated and reloaded to match.
- `findings_wiki/`: 3 new docs — see file list below.
- Bead `disk_magician-w7m` opened for the unconfirmed overlapping-sweeper
  follow-up.

## Addendum — cross-referenced with /history + /ms recall (integrated post-write)

The main session ran parallel `/history` and `/ms` sweeps
(`recall-history.md`, `recall-ms.md`, same STATE.md directory) and forwarded
them. Key items that change or extend the picture above:

- **UPDATE (superseded by direct measurement, see Lane 2): AO `/tmp`
  scratch-worktree churn is CONFIRMED still live today.** The recall
  originally cited historical rates up to ~97 GiB/day for this producer
  (root-caused to `scripts/cleanup_tmp.sh:50`'s permanent protected-root
  allowlist plus a `TMP_WORKTREES_APPROVED` gate no automated path ever
  sets — `2026-07-22-disk-regrowth-rootcause.md` §2-3). Rather than rely
  on that historical figure or the bead IDs below, this session's Lane 2
  measurement directly confirms the mechanism is still active *right now*:
  `tmp_private` shows a +25.2 GiB/day sustained unswept climb as of
  2026-07-28, and `host-disk-guardian.log` shows its CRITICAL-tier cleaner
  firing 3x with 0 reclaims each time because every candidate fails the
  "no merged PR" / "no uncommitted changes" safety check. This is now the
  Executive Summary's headline finding, not an open question.
- **`backup-home.sh` duplicate `/tmp` writes — RULED OUT as a current
  major producer, corroborated by two independent checks.** Read
  `~/projects/user_scope/scripts/backup-home.sh` directly: it uses
  `SECURE_TEMP="$(mktemp -d)"` with `trap cleanup EXIT`
  (`cleanup() { rm -rf "$SECURE_TEMP"; }`) and a second nested trap for its
  per-target snapshot temp dir — no unbounded `/tmp` accumulation pattern
  found. A second, independent direct check (main session) confirmed the
  same conclusion with additional specifics: the historical leak variant
  was purged 2026-07-15; the current `org.jleechan.user-scope-backup` job
  (runs every 2h) commits config-scoped snapshots only (6 files / 9
  insertions in its most recent run), and the `user_scope` repo itself is
  9.2 GiB total — nowhere near a ~40 GiB/day signature. `launchctl print`
  shows it ran most recently at 2026-07-29 01:05; its log shows normal
  git-commit/push cycles, not runaway `/tmp` growth. Two minor anomalies
  noted but not chased further: the 01:05 run's `dropbox` leg reported
  `TIMEOUT` in its own log, and `launchctl list` shows this job's last
  exit code as `-9` (SIGKILL) from a prior run — worth a follow-up if
  either recurs, but neither indicates the historical duplicate-writes
  bug is still present.
- **Both `jleechan-dqiz` and `bd-m8w` remain unlocatable** as open (or at
  all) across `disk_magician`, `worldarchitect.ai`, and `user_scope` beads
  databases checked (100+ `.beads/` directories exist across
  `~/projects/*` worktrees; not exhaustively searched). Given the live
  reproduction above supersedes the need for the bead-ID reconciliation
  for root-cause purposes, this is noted but not pursued further this
  pass.
- **`disk_magician-1f9` (P0, open):** whole-root AO `.gemini` symlink
  corruption (an unattended alias script materialized onto a real AO PR).
  Code fix already implemented (branch `fix/agy-dedup-alias-contract`,
  disk_magician PR #49) — open only pending merge + existing-alias
  migration/rollback verification, not a fresh finding for this report.
- **Frontier-scanner accounting caveat applies to this report's own Lane 1
  numbers.** Beads `jleechan-df3k`/`jleechan-rvqz` (open) track a known
  defect where the scanner's displayed ≥5 GiB buckets and its
  `measured_total_kb` are computed from different bases and don't always
  reconcile. Checked against this session's own `frontier_last.json`:
  `granularity_bucket_total_kb` (525.6 GiB) undershoots `measured_total_kb`
  (532.8 GiB, the figure used above) by **~7.2 GiB** — the same defect
  class, smaller magnitude than the 55.7 GiB overage that reopened `rvqz`,
  but present. Treat the 291.0 GiB residual figure as accurate to within
  roughly this margin, not as a fully closed accounting equation.
- **Growth-rate telemetry gap worth verifying:** the regrowth-prevention
  series' "part C" (linear regression of KB/day per top-level dir) was
  described as shipped 2026-07-06, but the recall found no roadmap doc
  confirming a currently-running dashboard/output path for it. This
  session's Lane 2 numbers came from ad hoc analysis of
  `disk_observer.jsonl`, not from that telemetry — if part C is actually
  live somewhere, it should be the canonical source going forward instead
  of one-off analysis.
- **35-min snapshot's own blind spot on its largest trees:** per
  `2026-07-22-disk-regrowth-rootcause.md` §3.6/§4.4 (not independently
  re-verified this session), `du` timeouts on the 5 largest monitored
  trees (`projects`, `root_library`, `worktrees_dot`, `tmp_private`,
  `library_containers`) get recorded as literal `0` rather than "stale,"
  which would make those trees appear to shrink to zero in naive
  day-over-day diffs while `disk_used_gb` keeps climbing. Not confirmed
  fixed; worth checking before trusting the 35-min snapshot series for
  delta attribution on exactly the trees that matter most.

## Adversarial verification (3-lens, refute-by-default, ≥2/3 survive)

Run 2026-07-29 as a fresh, independent read-only pass by three anonymous
Sonnet subagents against this report's specific numeric/causal claims,
each assigned one lens and instructed to REFUTE BY DEFAULT: (1) **evidence
lens** — does the cited primary evidence actually exist and say what's
claimed; (2) **design/causal lens** — does the proposed mechanism actually
explain the symptom, checked against plausible alternative explanations;
(3) **severity/framing lens** — does the claimed magnitude/urgency match
what the evidence supports. All three independently re-read primary
sources (logs, JSON, git history, live `launchctl`/source code) rather
than trusting this report's own prose. The specific numeric corrections
and framing fixes found by this pass have already been applied above (OOM
per-container range 68→120 not 97, drilldown cadence 4h not 40min,
drilldown priority P1→P2, host-disk-guardian free-space figures,
ez-mac-runner causal-link walkback, worldarchitect.ai rate-derivation
caveat, exec-summary net-vs-gross framing, telemetry-vs-reclaim framing).

| Claim | Evidence lens | Design lens | Severity lens | Verdict (≥2/3) |
|---|---|---|---|---|
| A. 4 sweepers never fired, StartInterval reboot-starvation, fixed w/ RunAtLoad | SURVIVES | SURVIVES | SURVIVES | **SURVIVES (3/3)** |
| B. Daily snapshot EX_CONFIG since 07-25, python3.13 path drift, fixed | SURVIVES | SURVIVES | REFUTED (telemetry framed as "reclaim automation") | **SURVIVES (2/3)**, framing corrected |
| C. AO `/tmp` scratch churn is dominant active producer, guardian structurally blocked | SURVIVES (minor figure fix) | SURVIVES (found even stronger multi-day evidence) | PARTIALLY SURVIVES (gross-vs-net framing) | **SURVIVES (2/3 + partial)**, framing corrected |
| D. Colima trim/prune currently broken (I/O error, 0 bytes trimmed) | SURVIVES | PARTIALLY SURVIVES (causal mechanism not independently confirmed this session) | SURVIVES | **SURVIVES (2/3)**, already hedged correctly in Lane 3 |
| E. ez-mac-runner OOM churn is "single highest-leverage" disk fix | PARTIALLY SURVIVES (counts ~right, range wrong) | REFUTED (causal link to disk growth unestablished; colima net is shrinking) | REFUTED (superlative unsupported, competes with claim C) | **REFUTED (majority)**, substantially reframed |
| F. worldarchitect.ai `.claude/worktrees` ~20 GiB/day production rate | SURVIVES (stock/age/count reproduced) | REFUTED (uniform 2-day age implies single burst, not continuous rate — invalidates the daily-rate math) | SURVIVES (already hedged as estimate) | **Facts SURVIVE, rate-framing REFUTED** — corrected to remove the daily-rate claim |
| G. Whole-disk +7.0 GiB/day net over 7.86 days, "only fully trustworthy number" | SURVIVES (exact reproduction from raw git history) | SURVIVES | SURVIVES | **SURVIVES (3/3)** |
| H. Drilldown sweeper gates on delta not absolute residual, never fires | PARTIALLY SURVIVES (cadence wrong: 4h not 40min) | SURVIVES (confirmed via source code, not a design choice) | REFUTED (P1 disproportionate for a diagnostic-only gap) | **SURVIVES (2/3)**, cadence and priority corrected |

**Net result:** 6 of 8 claims survive with the underlying finding intact
(some with corrected numbers/framing); claim E's core "disk-growth root
cause" framing did not survive and has been walked back to "CI-reliability
finding, disk-growth link unestablished"; claim F's underlying facts
(size, count, age-clustering) survive but the derived "~20 GiB/day" rate
claim did not and has been removed in favor of an explicit
burst-vs-continuous-rate caveat. No claim was found to be evidence-fabricated
or based on primary sources that don't exist — all corrections were
framing, precision, or over-generalization issues, not fabrication.

## Durable artifacts

- This report: `roadmap/2026-07-29-disk-regrowth-rootcause-sidekick.md`
- `findings_wiki/weekly-sweepers-never-fired-startinterval-reboot-starvation.md`
- `findings_wiki/daily-snapshot-python-version-path-drift.md`
- `findings_wiki/extreme-cpu-load-and-ezgha-runner-oom-churn.md`
- Mission state: `~/roadmap/disk_magician/sidekick/root-cause-disk-keeps-filling/STATE.md`
- Bead: `disk_magician-7io` (mission), `disk_magician-w7m` (follow-up)
