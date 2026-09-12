# Disk recurrence — root cause + automation plan (2026-09-11)

Evidence bundle: `roadmap/2026-09-11-disk-recurrence-evidence.md`

## 0. Post-swarm live verification (2026-09-11 17:20–17:40 PDT) — corrections that change the plan

- **Fleet "mass corruption" root cause is now pinned and reproduced.** The 4 plists reported corrupt in §1.5 (`disk-magician`, `frontier-root`, `pressure-sweep`, `sweeper-health`) all carried mtime 12:32:41 — the minute the investigating session ran `plutil -extract StandardOutPath raw <plist>` / `plutil -extract ProgramArguments json <plist>` to read their log paths. `plutil -extract` **without `-o -` overwrites the input file with the extracted value** (reproduced on a temp copy: valid → `Unexpected character [ at line 1`). The 16/16 result at 12:2x was true; the session itself corrupted them. This is the mechanism memory had called "not pinned down" for the 08-31 and 09-06 events and the "flapping" (inspect → corrupt → auto-repair reinstall → inspect again). Corrupt originals quarantined at `~/.disk_magician_state/quarantine/plists-20260911T172046/`; fleet repaired to 16/16; `check_launchd_fleet.sh` now names this cause when a plist starts with `[`/`{`; `cleanup_apfs_snapshots.sh:69-70` fixed to pass `-o -`; rule added to `CLAUDE.md` Step -1 and `findings_wiki/2026-09-11-plutil-extract-in-place-rewrite-corrupts-plists.md`. Plan component A ("corruption forensics") is therefore done; B's hash manifest remains worthwhile as a tripwire.
- `~/roadmap/.../gemini-memory` self-collapsed 161.5 → 2.5 GiB (verified); `$TMPDIR/T` is 63.3 GiB (up from 48.8); df 796 used / 95 free. The two orphaned `run_local_server.sh` MCP servers (ports 8104/8108, PIDs 3842/47420) are still alive — left running pending operator decision (they belong to a worldarchitect.ai study, not this repo).
- `frontier-root` remains broken by path drift (`/usr/local/libexec/disk-magician/` absent) — bead `disk_magician-4y6`, needs one `sudo` run.

## 1. Answer in 10 lines

1. The disk fills in a 3–6 day sawtooth (+60–100 GiB/reset) because every reclaim gate — worktree 7d floor, `cleanup_tmp.sh` 24h/4h — is age-based, while several dominant producers are created and consumed inside 0–2 days, structurally below every floor.
2. The two biggest single buckets found this session (`~/roadmap/.../gemini-memory` study dir, 161.5 GiB peak; `/private/var/folders/*/T` agent scratch, 48.8–65 GiB) are not age-gate misses at all — they are **coverage gaps**: neither path is enrolled in any sweeper's path list or the ledger's hot-dir/monitored-dir config, so no script is even eligible to see them, let alone age-gate them.
3. `~/roadmap` and `~/projects` (199.3 GiB, the single largest bucket on disk) are both absent from `config.json.template` monitored_dirs and `disk_observer.py` DEFAULT_HOT_DIRS.
4. The one fast-cadence reclaim path that does run every 30 min, `pressure_sweep.sh`'s `cleanup_tmp.sh` step, reliably times out: a per-candidate system-wide `lsof +D` scan blows the 600s step budget (78 distinct `rc=124` events across 45 days, ~7–14% of runs depending on denominator).
5. The fleet that is supposed to watch all of this is intermittently dead: 4 of 16 launchd plists (including the sweeper-health watchdog itself and pressure-sweep's own trigger) were found INVALID PLIST today, a single mass-corruption event, not gradual drift.
6. There is no operator-facing channel for any of this: the watchdog's own notify path shells out to `cmux`, which isn't on launchd's PATH, so the alert dies silently even when the watchdog is alive; `disk_usage_alert.sh`'s repo copy has no launchd job at all (a separately-deployed, better copy exists but is unwired into this repo and currently silenced by an operator flag).
7. A secondary, self-inflicted flap: 4 weekly sweepers log to `/tmp/disk-magician-*.log`, and macOS's own `tmp_cleaner` daemon deletes any `/tmp` file idle >3 days — so a weekly-cadence log is wiped before its next write, producing a daily false MISS → auto-repair bootout/bootstrap cycle.
8. Two claims were killed on re-verification: the 20s-measurement-cap/frozen-ledger "cascade" conflates two unrelated scripts (the real ledger freeze is an already-tracked bead, `disk_magician-4y6`, about a broken root-privileged scanner, not the 20s cap); and "no producer-side budget" was over-scoped as a growth driver when it is really an already-confirmed absence of a *detection* mechanism.
9. What changes: (a) repair + hash-verify + redundantly-scheduled fleet health so plists can't silently rot again, (b) wire the alert channel that already exists instead of rebuilding one, (c) publish a clearly-labeled partial ledger instead of freezing on strict completeness, (d) close the `~/roadmap`/`~/projects` visibility gap, (e) fix the `lsof` scan so the 30-min reclaim path actually completes, (f) add birth-time-based newborn-bytes attribution so the next anonymous spike gets an owner within ~15 GiB instead of being found retroactively by a human `du`.
10. None of this loosens the 7-day worktree floor, the never-delete list, or adds any new deletion authority — every fix is detection, reliability, or reclaiming space an existing script already owns.

## 2. 30-day timeline (evidence bundle §B, cleanup events annotated)

| Date | Event | GiB | Note |
|---|---|---|---|
| 2026-07-26 | Manual/operator reset | +60 | Pre-window catalog entry (outside strict trailing-30d from 09-11, but part of the cited sawtooth pattern) |
| 2026-07-29 | Manual/operator reset | +27 | Root-cause session same week: AO/pair /tmp churn 23–25 GiB/day headline (see memory `project_2026-07-29_disk_rootcause_producers_and_decisions.md`) |
| 2026-08-02 | Manual/operator reset | +172 | Coincides with `dirs_cleaner` 225 GiB ENAMETOOLONG root cause + fix (memory `project_2026-08-02_dirs_cleaner_225gib_root_cause_and_fix.md`) |
| 2026-08-25 | Manual/operator reset | +98 | Automated pressure-sweep log shows it contributed ~33.06 GiB of this reset (not purely manual, per verifier re-check) |
| 2026-08-30/31 | Snapshot launchd plist loses its `<dict>` wrapper | — | Silent 6-day gap in snapshot coverage (memory `project_2026-09-05_snapshot_launchd_plist_corruption_and_history_diff_gate.md`); automated pressure-sweep contributed ~66.41 GiB same window |
| 2026-08-31 | Manual/operator reset | +102 | Ledger last successfully published at `topdown-5g.json` commit `a8f629e` — frozen here for 11+ days as of 09-11 |
| 2026-09-06 | 16 launchd jobs found silently unloaded / actively flapping | — | Prior incident, mechanism not durably fixed (memory `feedback_2026-09-06_disk_root_cause_llm_capability_vs_harness_gap.md`) |
| 2026-09-09→09-10 | 801→853 GiB jump | ~52 | Driven by the gemini-memory study-dir spike (below) |
| 2026-09-10 | `gemini-3.8-flash` memory-prompt study harness writes 161.5–166.3 GiB into `~/roadmap` uncapped | 166.3 (peak) | Self-collapsed to 2.4 GiB within ~13h via its own export/retry churn; 2 orphaned MCP server processes (ports 8104/8108) remained alive 1d12h+ |
| 2026-09-11 10:52Z | Frontier-nightly scan surfaces the 161.5 GiB bucket | — | The only detector that caught it; not the broken root-privileged `frontier-root` job |
| 2026-09-11 11:32Z (18:32Z) | `pressure_sweep.sh` step 1 `cleanup_tmp.sh` times out | rc=124 | Predates same-day fix commit `4aa5c8a` (13:04:08 -07:00) |
| 2026-09-11 12:32:41 | 4 launchd plists (`disk-magician`, `-frontier-root`, `-pressure-sweep`, `sweeper-health`) found corrupt, same mtime | — | Single mass-rewrite event; watchdog and pressure-sweep trigger both disabled simultaneously |
| 2026-09-11 13:04:08 | Commit `4aa5c8a` (PR #67) tightens `LARGE_TMP_ACTIVE_HOURS` override to 4h under pressure | — | Narrows but does not close the 0–2d blind spot |
| 2026-09-12 00:07:40Z | Fresh 18.0 GiB/29.8min step event with every `hot_dirs_kb` null | 18.0 | Post-dates the evidence bundle; shows the anonymous-growth class recurring, contradicting the killed "no producer-side budget" verdict's "one-off" framing |

## 3. Confirmed root causes and automation gaps

### 3.1 Age gates are blind to 0–2 day growth (mechanism confirmed; framing corrected)
- **Mechanism**: `scripts/lib/worktree_recency.sh:107` hard 7d floor; `scripts/cleanup_tmp.sh:30` `LARGE_TMP_ACTIVE_HOURS` default 24h (tightened to 4h under pressure by `pressure_sweep.sh:217-222`, commit `4aa5c8a`).
- **Live evidence**: 161.5 GiB gemini-memory dir @1d and 48.8 GiB `/private/var/folders` scratch @0-2d sit below every gate; `cleanup_pr_scratch.sh` floor corrected to 48h (not 6h as first stated).
- **GiB**: 225 claimed, but verifiers split this — ~93% of the cited total (gemini-memory + var/folders) is a **coverage gap**, not an age-gate gap; only ~15–30 GiB of genuine `/private/tmp` churn is actually age-gate-limited.
- **Recurring**: yes (documented 45 days earlier in `feedback_2026-07-29_root_cause_disk_full.md`).
- **Correction from verifiers**: retitle as two separate findings — zero-coverage paths (roadmap, var/folders) vs. the one genuinely age-gated class (`/private/tmp`), whose 2026-09-11 failure was actually a timeout (§3.4), not the mtime floor.

### 3.2 `~/roadmap` gemini-memory study harness — unbounded, untracked, orphaned processes
- **Mechanism**: `run_study_worker.py` drives 5 model arms, each spawning its own MCP server, writing raw captures/grading exports straight to `~/roadmap` (not `$TMPDIR`) with no cap or TTL. `config.json.template` has zero `roadmap` matches; `disk_observer.py:41-51` DEFAULT_HOT_DIRS omits `~/roadmap` and `~/projects`.
- **Live evidence**: peaked 161.5–166.3 GiB (2026-09-11T10:52Z frontier scan), self-collapsed to 2.4G within ~13h; 2 orphaned processes (ports 8104/8108, three levels removed from a true `ppid=1` ancestor `run_local_server.sh`) still alive 1d12h+.
- **GiB**: 166.3, one-time spike (not proven recurring — only 2 study dirs exist total, both dated 09-10).
- **Recurring/new**: one-off ad hoc research run per verifiers, but the **coverage blind spot itself** is structural and would hide any repeat.
- **Correction**: detection gap is real (missing from disk_observer's fast/real-time layer), but was NOT zero-coverage-forever — the ~24h-cadence frontier-nightly scan is what actually found it, so classify as a latency gap (up to 24h), not total blindness.

### 3.3 No operator-facing alert channel
- **Mechanism**: `sweeper_health_check.sh:240` gates notify on `command -v cmux`, which resolves only to a dev-fork `.app` path absent from launchd's default PATH (`launchctl getenv PATH` confirmed no cmux); `disk_usage_alert.sh:157-176` only echoes WARNING to stderr and exits 1, with **zero** launchd/cron job referencing it at all.
- **Live evidence**: today's `check_launchd_fleet.sh` run shows 4/16 INVALID PLIST including `sweeper-health` itself, contradicting the same-day roadmap doc's "16/16."
- **GiB**: not a space metric — 74 (gap-to-floor) was misattributed to this claim by one lane; treat as unrelated.
- **Correction (material)**: a *separately deployed*, better copy at `~/Library/Application Support/user-scope/bin/disk_usage_alert.sh` already has working Slack + SMTP egress and fires hourly — it is just deliberately silenced by an operator flag and not reconciled back into this repo. Do not rebuild; wire and reconcile.

### 3.4 `cleanup_tmp.sh`'s `lsof` scan times out, gating the only 30-min reclaim path
- **Mechanism**: `has_open_files()` (`cleanup_tmp.sh:243-279`) shells a full system-wide `lsof +w +D` per candidate ≥100MB, called inside the per-dir loop; `TMP_DIRS=("/private/tmp" "/tmp")` doubly iterates the same tree (`/tmp` is a symlink). `pressure_sweep.sh:37` `STEP_TIMEOUT=600`.
- **Live evidence**: exact `rc=124` at 2026-09-11T18:32:04Z reproduced in logs; 78 distinct timeout events across 45 days (rate estimate disputed: ~7% vs ~13.7% depending on which log/denominator).
- **GiB**: 45 claimed, but disputed down to ~2.6 GiB (the archive-purge step's own ceiling) by one verifier, since most large `/private/tmp` entries (AO worktrees, the still-growing `leveling-fix-20260907` dir) are correctly gated by genuine open-file/recent-activity safety checks regardless of scan speed.
- **Recurring**: yes, untracked, unfixed as of this session.
- **Correction**: scope the fix to reliability (let the scan finish so *whatever* it's allowed to purge, purges), not to a specific GiB promise — the real space lever is capping AO/pair worktree size at spawn time.

### 3.5 macOS `tmp_cleaner` wipes weekly sweeper logs, driving daily auto-repair flapping
- **Mechanism**: 4 weekly plists (`colima-prune`, `hermes-vacuum`, `playwright-dedup`, `worktree-venvs`) log to `/tmp/disk-magician-<name>.log`; `/usr/libexec/tmp_cleaner` (root LaunchDaemon, midnight) deletes any `/tmp` file idle >3 days (`daily_clean_tmps_days=3`, confirmed via embedded strings). A 7-day-cadence log sits idle ~4 of every 7 days and is wiped before its next write.
- **Live evidence**: `/tmp/disk-magician-sweeper-health.log` shows all 4 sweepers OK 09-08→09-10, then simultaneously MISS at 09-11 09:00:02, followed by an auto-repair `bootout`+`bootstrap` cycle (`install_launchd_sweepers.sh:133-134`) that itself fails again minutes later.
- **GiB**: ~0 — this is a reliability/noise defect (spurious daily unload/reload of 4 jobs, lost debugging history), not a space consumer. One verifier's `gib_impact:30` was rejected as unsupported.
- **Recurring**: yes, untracked (`br search` for sweeper/flap/tmp_cleaner = 0 hits), and distinct from the sub-minute 2026-09-06 mass-flap incident, which remains unexplained.

## 4. Killed claims and why

- **"20s measurement cap cascades into frozen ledger + unsound floor method"** — the 20s cap (`disk_snapshot.sh`) and the frozen `topdown-5g.json` ledger are produced by two *different* scripts (`disk_snapshot.sh`'s monitored_dirs scan vs. `disk_frontier_scan.py`'s independent timeout tiers); the real ledger freeze is already tracked as bead `disk_magician-4y6` (broken root-privileged scanner, EACCES on Spotlight/.fseventsd), not the 20s cap. Real, unaddressed 20s-cap bug exists but doesn't cause this specific symptom.
- **"Automation's reclaim share is ~0% of 400-460 GiB"** — the cited 459 GiB sums resets outside the true trailing-30-day window (only 08-25 +98 and 08-31 +102 actually fall inside it), and the automated pressure-sweep log shows real non-trivial contributions on both those dates (33.06 GiB and 66.41 GiB respectively) — the "0%" framing is a 1-2 day-old regression generalized to the whole month.
- **"No producer-side budget/alarm"** — mechanism (no per-producer quota anywhere in the repo) is real and one verifier correctly confirmed it, but two others disputed materiality using a since-stale anchor (the 161.5 GiB dir had already self-collapsed). Per the critic, this was likely mis-killed: a fresh 18.0 GiB anonymous spike recurred 2026-09-12T00:07:40Z, after the evidence bundle, undermining the "one-off" argument. Carried forward into the innovation instead of being dropped outright.
- **"frontier-root job never run / only detector broken"** — false: a separate, healthy `frontier-nightly` job (confirmed `last exit code = 0`) is what actually found the 161.5 GiB dir; the broken root-only job only covers a narrow, already-quantified (~4.6 GiB) set of EACCES-walled system paths, and the "mis-tracked" claim was itself wrong — bead `disk_magician-4y6` already covers this exact issue.

## 5. Unified automation plan

Spine: detection-first (fleet forensics/repair → ledger/visibility → reclaim reliability). Full component table, sequencing, and explicit cuts:

```
[See synthesis input verbatim — reproduced below for a self-contained record]
```

### Components

| Name | What | Where | Effort h | GiB/wk | Risk |
|---|---|---|---|---|---|
| A. Corruption forensics before repair | Quarantine byte-copies of the 4 corrupt plists; audit `plutil -extract` call sites for missing `-o` (found: `cleanup_apfs_snapshots.sh:69-70` lacks it); add a test banning in-place plist rewrite | `scripts/cleanup_apfs_snapshots.sh:69-70`, new test | 3 | 0 | low |
| B. Repair + hash manifest + registered-AND-valid check | Reinstall via `install_launchd_sweepers.sh`; record sha256 per plist; cross-check `launchctl print` against on-disk `plutil -lint` | `install_launchd_sweepers.sh`, `sweeper_health_check.sh:165-177` | 3 | 0 | low |
| C. Redundant fleet check on a second schedule | Run `check_launchd_fleet.sh` from the 4h drilldown job (not only sweeper-health, which can't detect its own death) | drilldown template, `check_launchd_fleet.sh:108` | 2 | 0 | low |
| D. Sweeper logs off `/tmp` | Point StandardOutPath/StandardErrorPath at `~/Library/Logs/` for the 5 weekly-cadence jobs | launchd plist templates | 1 | 0 | low |
| E. Wire (not rebuild) the alert channel | Reconcile the deployed 377-line `disk_usage_alert.sh` (working Slack+SMTP) into the repo; add one LaunchAgent; replace `command -v cmux` with an absolute-path egress | new LaunchAgent, `scripts/disk_usage_alert.sh`, `sweeper_health_check.sh:239-244` | 2 | 0 | med |
| F. Publish a partial ledger as a distinct artifact | Add `ledger/topdown-5g.partial.json` for ≥97%-measured cases with unmeasured roots named inline; keep the strict gate as sole writer of the canonical file | `render_topdown_ledger.py` | 4 | 0 (detection) | med |
| G. `disk_magician.sh growth-top10` | Wrapper over existing `history_diff.py` + `resolve_state_repo_path.py`; collapses CLAUDE.md's manual floor-and-buckets ritual into one command | new wrapper | 2 | 0 (detection) | low |
| H. Close `~/roadmap` and `~/projects` visibility gaps | Add both to `config.json.template` monitored_dirs and `disk_observer.py` DEFAULT_HOT_DIRS; make the 8s `du` timeout per-key config-driven for the chronically-null keys | `config.json.template`, `disk_observer.py:41-54,118` | 3 | 0 (detection) | med |
| I. One `lsof` scan, one tree | Replace per-candidate `lsof +w +D` with one upfront `lsof +D /private/tmp` filtered in-memory; collapse `TMP_DIRS` to one path; fail closed on any gap | `cleanup_tmp.sh:145,243-281,360,629` | 5 | 8-10 | med |
| J. Cross-repo bead: fix the producer at source | `trap 'pkill -P $$' EXIT` on `run_local_server.sh`/`mcp_dual_background.sh`; redirect raw study output to `$TMPDIR`, copy only summaries to `~/roadmap` | worldarchitect.ai bead | 3 | one-time 166 GiB | low |

### Sequencing

- **PR1 (~11h): A, B, C, D, E — "the fleet is real again."** Must land first: the watchdog and pressure-sweep trigger are corrupt on disk right now and surviving only in launchd's in-memory cache; any later fix yields zero if the next reboot/bootout drops them. Order: forensics (A) before repair overwrites the evidence → repair+verify (B, C) → stop the false-MISS flap (D) → give the alarm somewhere to go (E).
- **PR2 (~9h): F, G, H — "the ledger is fresh and queryable."**
- **PR3 (~5h + 3h coordination): I, plus file J in parallel.** Landed last because it changes a safety-gate implementation and needs PR1's fleet to prove `STEP_TIMEOUT=600` holds on a real cadence.

### Operator: before → after

**No longer has to**: watch free space personally; run the CLAUDE.md Step 1/2 floor-and-buckets ritual by hand (→ `growth-top10`); notice ledger staleness manually (→ F alerts on it); re-run `install_launchd_sweepers.sh` after every corruption event (→ C); re-litigate "installed ≠ running" (→ B's registered-AND-valid check).

**Still has to**: set `WORKTREE_APPROVED=1` for Tier 6 work; adjudicate `needs_decision` paths in `safety.local.json`; act on an alert whose Tier 1–5 auto-remediation didn't recover enough; bump `pyproject.toml` + `uv tool install --force --reinstall` for src-tree changes; land the cross-repo harness fix (J); **run `sudo` once to unblock bead `disk_magician-4y6`'s root-privileged scanner install** (critic-added — no component in A–J touches this, and it remains the one manual, non-headless step blocking full ledger completeness).

### Deliberately NOT done

- Design 3's emergency 0–2d fast lane over `/private/var/folders`/`/private/tmp` — cut: the pressure gate (free<20G) is idle today (93 GiB available vs 40G threshold), its eligibility proof (name allowlist + `has_open_files`) would miss genuine AO scratch between writes, and it ships with a mandated week of human review that adds operator burden rather than removing it.
- No loosening of the 7-day worktree floor; no new age-derivation code (`worktree_age_days`/`worktree_is_recently_active` remain the only sanctioned path).
- Never-delete list untouched.
- Design 1's write-time quota + 15-min launchd job + quarantine pipeline on `~/roadmap/**/evidence/**` — cut: `~/roadmap` measures ~7.3 GiB today: the 166 GiB event was a one-time spike that self-collapsed in hours; a 15-min deleter aimed at a directory a live harness is actively writing, on top of a fleet that can't currently keep 16 plists intact, is net-negative. Replaced by H (visibility) + J (fix at the producer).
- No Slack/SMTP rebuild — the working implementation already exists; PR1 wires and reconciles it.
- The strict ledger gate is not loosened in place — a partial artifact gets its own filename (F), so a degraded floor can never silently masquerade as the canonical one.
- No ad-hoc cleanup scripts anywhere in this plan.

## 6. /innov — chosen innovation

**Birth-cohort attribution**: read APFS `st_birthtime` (`find -newerBt`) per configured root, in `scripts/newborn_cohort.py`, to attribute newborn bytes to an owner via a 5-rung lookup table (`.dm-own` manifest → config prefix → uid/gid → `UNKNOWN`), correcting for APFS clone double-counting by using `stat -f %b` (allocated blocks) rather than inode grouping (verified: `cp -c` clones get distinct inodes sharing blocks). Feeds a `newborn_by_owner` field into `disk_observer.py`'s existing step-event record, computed only when a step event fires (zero steady-state cost). Surfaces inside `check-launchd-fleet`'s already-mandatory Step -1 output — no new alert egress.

**Why chosen over the alternatives**: it is the only candidate that can see both incidents in this bundle — a git-worktree-exclusion rule (candidate 2) would structurally blind itself to `~/roadmap` (which *is* a git worktree); a cooperative-hook approach (candidate 3) needs producer buy-in this session's culprit (`run_study_worker.py`) never had, and is contractually incapable of changing any outcome (grant-only). Birth-time is retroactive: the filesystem has already stamped it on every inode since day one, so it needs zero producer cooperation.

**Falsification-first build step (first 48h)**: run a bounded `find -newerBt` probe against the *currently unattributed* 18.0 GiB/29.8min step event (2026-09-12T00:07:40Z, every `hot_dirs_kb` null) across `/private/tmp`, `/private/var/folders`, `~/roadmap`, `~/.cache`; sum `%b*512` grouped by 6-component path prefix. Success bar stated up front: top rows must account for a material fraction of the recorded delta, and at least one must sit under a root whose `hot_dirs_kb` was null. If newborn bytes are negligible, kill the idea (~1h sunk).

**Explicit limits carried into the PR description**: detection/attribution only — it does not delete, throttle, or cap, and must not be sold as stopping the sawtooth. Named risk: `-newerBt` still walks every inode (O(inodes)), and fires exactly when I/O is most contended — if it starts returning `partial` on every root during real incidents, it has inherited the same failure mode as the 8s `du` timeout it was built to escape; mitigate by logging per-root wall time and treating a rising partial rate as a kill signal from day one.

## 7. Critic gaps and how the plan absorbs them

- **`~/projects` (199.3 GiB, largest bucket on disk) had no owner in the original plan.** Absorbed: §5 component H now explicitly adds `~/projects` alongside `~/roadmap` to both `config.json.template` and `DEFAULT_HOT_DIRS`. Open question (not yet resolved): whether Tier 6 (`cleanup_worktree_venvs.sh`/`cleanup_worktrees.sh`) already owns the `worldarchitect.ai` (30.6 GiB, 0d) and `worktree_cache_full_redesign` (12.6 GiB, 4d) subtrees under it, pending the 7-day floor, or is untouched by design — flagged as a follow-up to verify before PR2 lands, not resolved here.
- **Component C's redundant watchdog (drilldown job) has no proven immunity to the same mass-corruption mechanism.** Absorbed as a named residual risk in §5/PR1: no component in A–J adds a true out-of-band heartbeat (cron, or a staleness check triggered by a mechanism other than launchd itself). Recommended follow-up, not yet scheduled: add one heartbeat check outside launchd's own scheduling.
- **"No producer-side budget/alarm" was likely mis-killed** — the critic's re-read of the verifier reasons shows the confirming lane actually confirmed absence-of-mechanism, and a fresh 18.0 GiB anonymous spike recurred after the evidence bundle closed, undercutting the "one-off, immaterial" argument used to kill it. Absorbed: carried forward as the explicit justification for the birth-cohort innovation (§6) rather than left dropped, since attribution is the safer answer to this gap than a write-time quota (which was independently cut in §5 for unrelated reasons).
- **§4's "still has to" list omitted the one permanently-blocked manual step.** Absorbed: added "run `sudo` once to unblock bead `disk_magician-4y6`" to §5's operator "still has to" list above.

## 8. Immediate next actions (today) vs PR sequence

**Today (no PR needed, read-only/manual):**
- Run `sudo -v` once and complete `install_root_frontier_runner.sh` interactively to unblock bead `disk_magician-4y6` (the actual ledger-completeness blocker).
- Manually re-run `bash scripts/install_launchd_sweepers.sh` to restore the 4 corrupt plists as a stopgap (PR1 makes this unnecessary going forward, but the fleet needs to be alive before then).
- Kill the 2 orphaned MCP server processes on ports 8104/8108 (`run_local_server.sh` ancestors, ppid=1) left over from the gemini-memory study.

**PR sequence (this repo):**
1. PR1 — components A, B, C, D, E (fleet forensics, repair, redundant check, log relocation, wired alert).
2. PR2 — components F, G, H (partial ledger artifact, `growth-top10` wrapper, `~/roadmap`+`~/projects` visibility).
3. PR3 — component I (single `lsof` scan, one tree), plus file bead J against worldarchitect.ai.

## 9. Provenance

- Evidence bundle: `roadmap/2026-09-11-disk-recurrence-evidence.md`
- Workflow phases: 5 miners → 10 claims × 3 verifiers each → 3 designs → 2 judges → 3 innovations × 2 challengers → 1 critic
- This report synthesizes the CONFIRMED claims (5 survived triple-verification), KILLED claims (4, with per-lane reasons preserved above), the judge-selected SYNTHESIS plan, the challenger-selected INNOVATION, and the CRITIC's 4 gap findings, as supplied to this report-writing pass.
