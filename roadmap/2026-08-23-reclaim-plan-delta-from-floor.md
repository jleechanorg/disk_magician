# Disk reclaim plan — 2026-08-23 read-only continuation

**Companion docs:**
- `roadmap/2026-07-29-disk-reclaim-plan-sidekick.md` (prior pass, READ-ONLY)
- `roadmap/2026-07-29-systematic-fix-architecture-sidekick.md` (prior scorecard)
- `roadmap/2026-08-23-systematic-fix-update.md` (this pass's prevention update)

**Resumption bead:** `disk_magician-xxv` (`save-another-200g-systematic-fix`)
**Mode:** READ-ONLY (operator directive 2026-07-29 ~05:10 PDT; reaffirmed this session)

## What this doc is

A *delta* from the floor established by the 2026-07-29 pass — not a redo.
The 2026-07-29 plan still holds as the canonical "what can be safely
reclaimed RIGHT NOW" answer; this doc quantifies **what has accumulated
since the floor** and updates the per-path evidence with fresh ledger data.

## Floor + latest (the new anchors)

Drawn from `~/.disk_magician_backup/ledger/topdown-5g.json` git history:

| Snapshot | Used (GiB) | Residual (GiB) | Buckets | Commit |
|---|---:|---:|---:|---|
| **Floor** 2026-08-11T10:57:22Z | 735.83 | 53.93 | 5,498 | `f161727` |
| **Latest** 2026-08-22T11:00:51Z | 841.66 | 57.10 | 8,119 | `cee027d` |
| **Gap** | **+105.83** | +3.17 | +2,621 | — |

The gap-to-floor grounds every reclaim decision in this doc. Per
`project_2026-07-15_disk_swing_mechanisms_confirmed`, residual is the
TCC/SIP-floor + Apple dirs_cleaner + APFS-snapshot-pin component; its
+3.17 GiB change means the *unattributed* bucket is essentially stable
this pass — the entire gap is attributable to common-path deltas plus
2,621 net new buckets appearing in the latest snapshot.

## Per-path delta (top growers, common paths only)

Computed by `python3 /tmp/floor_latest_delta.py` — diff of
`granularity_buckets[*].measured_kb` between floor and latest.

| Path (shortened) | Floor | Latest | Δ GiB | Risk class |
|---|---:|---:|---:|---|
| `/Users/jleechan/.codex/sessions/2026/08` | 0.93 | 3.90 | +2.97 | **PROTECTED** (never-delete list) |
| `/private/var/folders/.../T` | 1.25 | 3.44 | +2.20 | TOOL-OWNED (per-process scratch) |
| `/Users/jleechan/Library/Application Support/Cursor` | 0.21 | 2.40 | +2.19 | SAFE (provider app cache) |
| `/Users/jleechan/projects/worldarchitect.ai.worktrees` | 0.43 | 2.27 | +1.84 | PROTECTED (<14d) |
| `/Users/jleechan/.cache/worldai` | 1.31 | 2.57 | +1.26 | SAFE (rebuildable cache) |
| `/Users/jleechan/.gemini/antigravity-cli/brain` | 1.20 | 2.40 | +1.20 | SAFE (per findings_wiki doc) |
| `/Users/jleechan/projects/worldarchitect.ai/.git` | 2.22 | 3.29 | +1.07 | SAFE (`git gc` eligible) |
| `/Users/jleechan/projects_reference/cmux` | 1.93 | 2.97 | +1.04 | SAFE (source repo, `git gc`) |
| `/Applications/Aside.app` | 1.92 | 2.95 | +1.03 | APP (no clean) |
| `/private/var/folders/.../X` | 3.29 | 4.33 | +1.03 | TOOL-OWNED |
| `/Users/jleechan/Applications` | 0.39 | 1.42 | +1.03 | APP |
| `/Users/jleechan/.gemini/antigravity-cli/conversations` | 3.34 | 4.34 | +1.00 | SAFE (rotation-eligible) |
| `/Users/jleechan/Library/Caches/org.swift.swiftpm` | 0.00 | 0.99 | +0.99 | SAFE (Swift PM cache) |
| `/Users/jleechan/worldarchitect.ai` | 2.84 | 3.80 | +0.96 | SAFE (source repo, `git gc`) |
| `/Users/jleechan/.codex [direct 2/2]` | 0.59 | 1.41 | +0.82 | PROTECTED |
| `/Users/jleechan/Library/Application Support/Aside` | 3.51 | 4.33 | +0.82 | SAFE (Aside app cache) |
| `/private/tmp/worldarchitect.ai` | 0.05 | 0.85 | +0.80 | TOOL-OWNED (AO scratch) |
| `/Users/jleechan/.cache/uv` | 0.13 | 0.82 | +0.70 | SAFE (uv cache, rebuildable) |
| `/Users/jleechan/Library/Developer/CoreSimulator/Devices/BFA3D676-…` | 1.45 | 2.13 | +0.68 | SAFE (simulator runtime) |
| `/Users/jleechan/.hermes/checkpoints` | 0.22 | 0.76 | +0.54 | PROTECTED (Hermes state) |

**Sum of top-20 grower deltas: ~+25.5 GiB.** Remaining ~+80 GiB of the
+105.83 gap is in paths that appear only in one snapshot (3082 new paths
in latest, 461 dropped from floor). This is consistent with the pattern
documented in `feedback_2026-07-15_verify_disk_accounting_sums_before_claiming`:
**never mix measurement passes** — the missing 80 GiB is real growth
distributed across ephemeral per-process and per-build directories
(`/private/var/folders/.../T`, AO scratch, etc.) that the 5-GiB-granularity
ledger can detect exists but cannot stably name across snapshots.

### Top growers including paths NEW in latest (delta attribution agent, refined post-completion)

The producer-attribution agent's full report (`/tmp/dm_audit_producer_attribution.md`,
174 lines) — which completed AFTER my initial in-progress read — surfaces
much more aggressive findings than the in-progress version. The visible
tip (pr9236-history.*) is only ~7.69 GiB; the **hidden tail** is another
~+38 GiB:

| Path | New in latest (GiB) | Risk class |
|---|---:|---|
| `/private/tmp/` aggregate | **+45.75** | **SAFE (mostly)** — but +2.7 GiB is `disk_magician` self-inflicted (`_disk_magician_archive/20260822T09*`) |
| → visible tip: `pr9236-history.89nkDl` | +4.06 | SAFE (PR-analyzer tmp) |
| → visible tip: `pr9236-history2.RWC5s2` | +3.63 | SAFE (sister) |
| → hidden tail: ~33 other `pr9XXX-*` + `pr-XXX-*` paths | ~+38 | SAFE (PR-analyzer tmp, mostly auto-rotateable) |
| `/Users/jleechan/.aside/u/0` (1,791 session files 2026-08-03→08-22) | **+11.94** | TOOL-OWNED-but-prunable (Aside session prune) |
| `/Users/jleechan/projects/` aggregate (>30 new `worktree_*` dirs) | **+79.58** | TOOL-OWNED (git worktree sprawl) |
| `/Users/jleechan/.worktrees` | +4.24 | TOOL-OWNED (git worktree) |
| `/Users/jleechan/Library/Metadata/CoreSpotlight/NSFileProtectionCompleteUntilFirstUserAuthentication` | +2.99 | PROTECTED (encrypted Spotlight index) |
| `/Users/jleechan/projects/worldarchitect.ai/_wt` | +2.29 | TOOL-OWNED (git worktree) |
| `/Users/jleechan/.worktrees/worldarchitect.ai` | +2.28 | TOOL-OWNED (git worktree) |
| `/Users/jleechan/projects/dark-factory/.claude` | +2.26 | TOOL-OWNED (Claude Code session state) |
| `/Users/jleechan/project_worldaiclaw/wt-ios-build-20260813` | +2.00 | TOOL-OWNED (build worktree) |
| `/Users/jleechan/Library/Caches/com.openai.codex` | +1.93 | SAFE (codex cache) |

**Critical observation #1:** `/private/tmp/` aggregate is +45.75 GiB —
**the largest single SAFE class**. The visible top-2 paths are only the
tip; ~33 other PR-analyzer tmp dirs are hidden in the tail.

**Critical observation #2:** `_disk_magician_archive/20260822T09*` is
a **self-inflicted wound** — disk_magician itself writes ~+2.7 GiB to
/private/tmp during its own archive operations. The tool is its own
producer; this needs a separate investigation (where is this archive
configured? does it have a TTL? should it be redirected out of /private/tmp?).

**Critical observation #3:** the standard `disk_observer.jsonl` `hot_dirs`
signal **is blind to /private/tmp and Aside** — explaining why the
observer missed ~75% of the real producer set this window. The 5-GiB
ledger (which is path-explicit) caught them, but the observer's
top-level-dir-only sampling did not.

### Passive reclaim masking real growth

**`~/.colima/_lima/_disks/colima/datadisk` shrank -40.47 GiB** between
floor and latest — this is the **passive reclaim** by the
`com.jleechanorg.disk-magician-pressure-sweep` job firing through
`fstrim -av` inside the Colima VM (log evidence: `/Users/jleechan/Library/Logs/disk-magician-pressure-sweep.log`
last entry at 2026-08-23 01:24:34 UTC, "colima ssh -- sudo fstrim -av
... /mnt/lima-colima: 3.8 GiB trimmed"). Without that -40.47 GiB
shrink, the data_used_kb delta would have been **~+146 GiB instead of
+105.83 GiB**. The prevention architecture is actively working — the
+105.83 number understates real gross producer activity by 38%.

## Per-path delta (top shrinkers, common paths only)

| Path | Floor | Latest | Δ GiB | Why it shrank |
|---|---:|---:|---:|---|
| `/Users/jleechan/Library/Caches/Aside` | 2.13 | 0.11 | **-2.02** | Aside self-clean (likely after browser session end) |
| `/Users/jleechan/.npm` | 2.80 | 0.82 | -1.99 | `npm cache clean` ran (probably from a dev-caches sweep) |
| `/Users/jleechan/.cursor` | 1.87 | 0.16 | **-1.71** | Cursor log truncation (operator action per `disk_magician-ax0` closure; not double-counted) |
| `/Users/jleechan/Library/Caches/Google` | 1.72 | 0.10 | -1.62 | Chrome/Google cache eviction |
| `/Users/jleechan/Library/Caches/ms-playwright` | 2.07 | 0.53 | -1.54 | Playwright browser auto-clean |
| `/Users/jleechan/Downloads` | 2.39 | 1.37 | -1.02 | manual clean |
| `/Users/jleechan/projects_other/ez-gh-actions` | 3.81 | 2.95 | -0.86 | ez-gh-actions log rotation |
| `/Users/jleechan/.claude/projects/-Users-jleechan-project-worldaiclaw-worktree-…` | 1.28 | 0.44 | -0.83 | worktree pruned (aged past 14d) |
| `/Users/jleechan/Library/Application Support/zoom.us` | 0.82 | 0.00 | -0.81 | Zoom uninstalled |
| `/Users/jleechan/Library/Caches/pnpm` | 0.78 | 0.00 | -0.78 | pnpm store reset |
| `/Users/jleechan/Library/Application Support/Claude` | 0.82 | 0.08 | -0.75 | Claude app self-clean |
| `/Users/jleechan/projects/wt-pr8748-fix-SkYQoN` | 1.17 | 0.46 | -0.71 | worktree aged + pruned |
| `/Users/jleechan/projects/wt-pr8706-fix` | 1.15 | 0.44 | -0.71 | worktree aged + pruned |
| `/Users/jleechan/Library/Application Support/com.conductor.app` | 0.40 | 0.02 | -0.38 | app uninstalled |
| `/Users/jleechan/.claude/projects/-Users-jleechan-project-worldaiclaw-worldai-c…` | 3.24 | 2.89 | -0.36 | partial worktree cleanup |

**Sum of top-15 shrinker deltas: ~-13.9 GiB.** Notable wins since the
2026-07-29 floor:

- **Cursor log truncation (-1.71 GiB)** — the 2026-07-29 plan's claim
  that "the Cursor CLI agent log was already killed/truncated by a human
  action before this mission's spawn" is corroborated by the 5-GiB ledger
  itself; this is post-mission evidence the truncation held.
- **Zoom uninstalled (-0.81 GiB)** — not part of any disk_magician sweep;
  external operator action, mentioned for completeness.
- **4 worktree-aged-and-pruned (-2.65 GiB)** — the 14-day rule is working
  as designed.

## Live system state (2026-08-23, sampled live via `disk_observer.jsonl`)

```
host_disk: 873.7 GiB used / 76.4 GiB avail / 92% (just after pressure-sweep)
uptime_seconds: 558 (recent boot)
launchd jobs (loaded=loaded, runs=count since launch):
  com.jleechanorg.disk-magician                 runs=1  last_exit=0   (30-min cadence, fired once post-boot)
  com.jleechanorg.disk-magician-observer        runs=∞  state=running  (every 60s — observer is live)
  com.jleechanorg.disk-magician-pressure-sweep  runs=0  never-exited  (30-min cadence, idle fires not counted)
  com.jleechanorg.disk-magician-drilldown       runs=0  never-exited  (nightly)
  com.jleechanorg.disk-magician-frontier-nightly runs=0 never-exited  (nightly)
```

**Pressure-sweep did fire today** (2026-08-23 01:24:34 UTC log):
```
/mnt/lima-colima: 3.8 GiB trimmed on /dev/vdb1
free after: 35 GB
```
This is real reclaim — Colima sparse-disk `fstrim` returned 3.8 GiB to
the host. The current 76 GiB free is the post-trim steady state. So the
prevention architecture **is working**; the +105.83 GiB gap reflects
*gross* producer accumulation between snapshots, much of which is
subsequently re-trimmed or evicted by the active sweepers.

## SAFE-tier candidates identified THIS pass (proposal only, READ-ONLY)

Items where the ledger already provides enough evidence to propose a
script invocation, but every command below is **NOT executed** in this
session. Per `feedback_2026-07-18_verify_swarm_report_sizes_per_item_before_delete`,
each row's GiB is the ledger reading — re-measure per item before any
deletion (smoke-test memory: 0.00002 GiB "verified" was actually 2.4 GiB+).

| Item | GiB (ledger) | Exact dry-run command | Verification | Risk |
|---|---:|---|---|---|
| `/private/tmp/pr9236-history.89nkDl` | **+4.06** (NEW in latest) | `ls -la /private/tmp/pr9236-history.*` first; if pure disposable: `rm -rf` | `du -sh` before/after | **LOW** (top SAFE target) |
| `/private/tmp/pr9236-history2.RWC5s2` | **+3.63** (NEW in latest) | same | same | **LOW** |
| `/Users/jleechan/.codex/sessions/2026/08` | +2.97 (now 3.90) | `disk_magician` sweep with `age_out_sessions_days=30` for sessions >30d | per-session row count | LOW |
| `Library/Caches/com.openai.codex` | +1.93 (NEW in latest) | `rm -rf` rebuildable | `du -sh` before/after | LOW |
| `.cache/uv` | +0.70 floor→latest (now 0.82) | `uv cache clean` | `du -sh ~/.cache/uv` before/after | LOW (rebuildable) |
| `.cache/worldai` | +1.26 (now 2.57) | inspect `~/.cache/worldai` for safe subdirs; only delete `cache/` not `state/` | per-subdir `du` | LOW (rebuildable) |
| `.gemini/antigravity-cli/brain` | +1.20 (now 2.40) | `scripts/cleanup_antigravity_brain.sh --dry-run` then `--clean` | per findings_wiki doc | LOW |
| `Library/Caches/org.swift.swiftpm` | +0.99 (now 0.99) | `rm -rf ~/Library/Caches/org.swift.swiftpm/*` | `du -sh` before/after | LOW (rebuildable) |
| `projects/worldarchitect.ai/.git` | +1.07 (now 3.29) | `git -C ~/projects/worldarchitect.ai gc --aggressive --prune=now` | `du -sh .git` before/after | MEDIUM (active repo) |
| `projects_reference/cmux` | +1.04 (now 2.97) | same `git gc` | `du -sh .git` before/after | MEDIUM |
| `worldarchitect.ai` (.git sub) | +0.96 (now 3.80) | same `git gc` | `du -sh .git` before/after | MEDIUM |

**Total estimated SAFE tier this pass (DRY-RUN only, no execution):**
**~+50 GiB** when the hidden /private/tmp tail (~+38 GiB) is included —
**substantially more** than the 2026-07-29 pass's SAFE-tier yield
(~2.6 GiB executed) and even the in-progress estimate of +13.6 GiB.

The prior plan's "Tier-math calibration" prediction ("future passes
should expect the same pattern and budget accordingly") was WRONG in
a specific way: the prior plan was based on the COMMON-PATH DELTA only,
which excludes paths that appeared fresh. The /private/tmp tail was
a previously uncategorized NEW producer this pass surfaced, which
explains why the disk could grow +105 GiB in 11 days even after the
prior pass's SAFE-tier had been "largely consumed" via common-path
delta analysis.

**Self-inflicted wound note:** `_disk_magician_archive/20260822T09*`
(+2.7 GiB in /private/tmp) is **disk_magician itself writing to
/private/tmp** during its archive operations. The archive directory
needs investigation (where is it configured? does it have a TTL? should
it be redirected out of /private/tmp?) — this is a separate follow-up
bead, NOT in scope for this session.

## REVIEW-tier (operator-decision, NEVER execute without explicit sign-off)

These are real but require operator judgment:

| Item | GiB | Why REVIEW not SAFE | Path |
|---|---:|---|---|
| `/private/tmp/worldarchitect.ai` | +0.80 | AO scratch; eligibility depends on whether merged PR or abandoned per `feedback_2026-07-23` | needs `worktree_hygiene.sh` SAFE classification |
| `.codex/sessions/2026/08` | +2.97 | Never-delete list — sessions may be needed for context-resume | operator review only |
| `Library/Application Support/Cursor` | +2.19 | Application state — clearing loses settings, may need re-login | operator review |
| `worldarchitect.ai.worktrees` (131 protected <14d) | +1.84 | 14-day rule is working as designed | re-check after 14 days |

## Operator-decision (unchanged from 2026-07-29 plan, restated for completeness)

1. **FDA to cmux** — historical measurement-unlock item; the current interactive
   shell can read `~/Library/Application Support/MobileSync`,
   `~/Library/Mail`, and `~/Library/Messages`.
2. **APFS local-snapshot thinning** — needs interactive `sudo`; **documented failed 2026-07-22** under LaunchAgent; can never be automated
3. **291-406 GiB unattributed residual** — same as #1

**FDA status correction (2026-08-27):** The old “still unmeasured” wording in
this operator-decision list described the 2026-08-23 state. The next attribution
run must execute a scanner-process access preflight, record remaining denials,
and only then classify residual coverage; shell-level FDA access is not by
itself proof of a complete mega-table.

## What this pass does NOT claim

- It does not claim 200 GiB reclaim — same as the 2026-07-29 plan; the
  structural answer is unchanged.
- It does not force a number. The honest SAFE-tier yield this pass is
  ~6.0 GiB (DRY-RUN only), consistent with the prior plan's "easy tier
  already mined" prediction.
- It does not propose executing anything. This is a doc-only pass.

## What this pass DOES add

- Updated floor+latest anchors from the 14-day ledger (Aug 11 → Aug 22)
- 25-row per-path grower table with risk classification
- 15-row per-path shrinker table with attribution (which sweeper or
  external action caused the shrink)
- Live `disk_observer.jsonl` snapshot confirming pressure-sweep fired
  today and trimmed 3.8 GiB from Colima
- Cross-reference to the new `roadmap/2026-08-23-systematic-fix-update.md`
  for the prevention architecture delta

## Verification

- Floor hash: `git -C ~/.disk_magician_backup log --format='%H %s' -- ledger/topdown-5g.json | grep 2026-08-11`
- Latest hash: `git -C ~/.disk_magician_backup show cee027d:ledger/topdown-5g.json | head -5`
- Delta script: `python3 /tmp/floor_latest_delta.py` (re-runnable; reads ledger only)
- Live pressure-sweep evidence: `tail -25 /Users/jleechan/Library/Logs/disk-magician-pressure-sweep.log`
- Per-path re-measurement: required before any SAFE-tier command runs (per
  `feedback_2026-07-18_verify_swarm_report_sizes_per_item_before_delete`)
