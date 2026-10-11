# Disk-fill durable control: diskm budget governor with owner-lifecycle leases

- **Date:** 2026-10-11
- **Status:** Design, auto-approved under `/superpowers-quick`. `/advice` and `/web-advice` are run by the parent workflow.
- **Base:** origin/main `688fff6` (v0.2.197 deployed 2026-10-11T20:43Z)
- **Related:** worktree lease teardown design `docs/superpowers/specs/2026-10-10-worktree-lease-teardown-design.md` (on branch `docs/worktree-lease-design`, implemented by PR #148). Open PRs #150 (Colima stale lock) and #151 (Codex Documents cleanup). Beads `7u9t`, `oyt4`, `67xj`, `d45`, `i2o`, `4y6`.
- **Plan:** `docs/superpowers/plans/2026-10-11-disk-fill-durable-control.md`

## 1. Why

At the time of writing, `df` shows **7.2 GiB free of 926 GiB (100%)**. The user has asked "stop the disk constantly filling" on 09-23, 10-03, 10-04, 10-05, 10-06, 10-08, 10-09, 10-10 and 10-11, and twice within 22 hours (10-10 23:01 and 10-11 21:10). In 30 days the repo produced five designs (09-11, 09-23, 10-03, 10-05, 10-10) and about 80 merged PRs (#67–#149). None of this lowered the used-space trough.

### 1.1 30-day retrospective: what the data shows

All figures are from `~/.disk_magician_state/disk_observer.jsonl{,.1,.2}`: 12,878 df-only samples covering 10-02 to 10-11. Snapshot-ledger figures are used only where snapshot coverage is at least 70%.

| Day | Min used (GiB) | Max used (GiB) |
|---|---|---|
| 10-03 | 754 | 885 |
| 10-04 | 759 | 881 |
| 10-05 | 838 | 875 |
| 10-06 | 798 | 888 |
| 10-07 | 763 | 836–851 |
| 10-08 | 826 | 895 |
| 10-09 | 805 | 894 |
| 10-10 | 831 | 885 |
| 10-11 | 839 | 893 |

- Free space was below 8 GiB in **605 of 12,878 samples**, on 8 of the 10 days.
- The daily trough rose from 754 to 839 GiB in a week. Intraday swings were 54–131 GiB.
- Four reclaim events gave back +56.5 GiB (10-05), +63 (10-06), about +40–60 (10-10) and about +55 (10-11). Each refilled within hours to about 2 days. The median refill half-life was about 1 hour, and about 2 hours for drops of 38 GiB or more.

### 1.2 Verified root causes (survived adversarial refutation)

**RC1: open loop. Nothing limits creation, so standing stock = creation rate × retention.**

- **Births.** Counted by birth time under `~/.worktrees`: 40, 49, 41, 61 and 35 per day for 10-07 to 10-11. All three verifiers confirmed these counts.
- **Surviving stock.** A du of surviving worktrees by birth day gives about 17–38 GiB/day still on disk.
- **Producer-side PRs.** Only two PRs touched the producer side: #107 (standard root, 10-06, with no teardown) and #148 (lease plus admission gate, merged 10-11, live in nominate mode only). Every other PR improved a sweeper.
- **Retention.** Retention is set by the 3-day merged floor and the 7-day general floor. One verifier noted that retention is a co-equal lever: admission alone is not enough while the floors stay as they are.
- **Unverified.** The /private/tmp rate (about 21 GiB/day) and the 45–50 GiB/day producer total are not verified. They are used here as model inputs only.

**RC8: symptom and metric. The volume runs 91–97% full, so swings are as large as the headroom.**

- Headroom is about 30–45 GiB. Bursts are 15–25 GiB/h and the sustained drain is 2–8 GiB/h.
- `pressure_sweep.sh` acts only below 40 GiB free and runs a fixed step list, so it holds the disk near 40 GiB instead of creating margin.
- A stopped Colima VM (stale lima lock since 10-08, bead `67xj`) cannot fstrim, and nothing raised an alert.
- One verifier argued RC8 is a symptom, not a cause. This design accepts that and adopts its actionable parts: alert on a rising trough, alert on a dead actuator, and measure success as the df trough, never as "GiB reclaimed".

### 1.3 Refuted or demoted claims (kept as constraints, not as causes)

| Claim | Verdict | What survives into this design |
|---|---|---|
| RC2: age floors alone set the equilibrium (70–160 GiB protected) | Refuted. About 53 GiB was measured inside the floors, the troughs swung 754–839, and refill happens in hours, not days | Age floors are a contributor. Owner-lifecycle release (C8/C9) replaces blanket age floors only for provably safe items |
| RC3: agents cannot tear down | Refuted as stated. The remove hook does run, and it keeps items for dirty, unpushed, ignored-file or under-7-day reasons. No skill tears down `/private/tmp/<repo>/` scratch | Session-exit release (C8). `protect-worktrees.sh` is **not** loosened |
| RC4: receipts report success from exit code | Refuted. Receipts record error, timeout and blocked_safety honestly. The real gap is that `freed_bytes`/`df_delta` are null on main_sweeper, pressure_sweep and tmp_scratch_sweep, and nothing alerts on them | Receipts must carry `df_delta_bytes` (C10). Liveness alerts (C12) |
| RC5: no plist sets any approval | Refuted. `worktree-venvs`, `code-sign-clones`, `colima-prune` and `playwright-dedup` do bake in approvals. Worktree removal (hygiene, `cleanup_worktrees` under main_sweeper) and claude-state remain permanent dry-runs | Standing-decision record (C11) for exactly the gates that are never satisfied |
| RC6: measurement work crowded out producer work | Refuted. Measurement was about 25% of PRs, and the code_sign_clone phantom PRs were under 1% of lines | Rule: count df_delta only, never du (anti-goal) |
| RC7: about 7-day deploy lag | Refuted. Receipts show 19 installed versions between 10-07 and 10-11, redeployed every 1–4 hours | None. The fix-of-a-fix churn (#136→#145→#146→#149) is noted as a smell |
| RC9: process with no closure criterion | Refuted as a byte cause | Bead closure requires two consecutive weekly trough checks (section 9) |

### 1.4 What failed in the 30-day record

- **About 78 PRs added or fixed sweepers or measurement.** The trough still rose. A sweeper reclaim lasts hours.
- **Approval environment variables that no plist sets.** `WORKTREE_APPROVED` and `CLAUDE_STATE_APPROVED` are never set by a scheduled job, so hygiene and claude-state became permanent dry-runs.
- **Control cadence of 30–60 minutes against a refill half-life of 1–2 hours,** with a single-threshold sweep. One 600-second step timeout blocked every later step.
- **"Installed" was trusted as "running".** Examples: fleet flapping, plutil corruption, Colima down for 3 days, main_sweeper erroring on 64 of 64 runs.
- **du was counted as reclaim.** `code_sign_clone` reported 104 GiB, and deleting it freed about 0 (APFS copy-on-write).

## 2. Goals

1. Close the loop. Every governed producer class has a byte budget, and creation is admitted against a free-space setpoint.
2. Shorten retention where it is provably safe. An artifact whose owner has exited and that is clean and pushed is reclaimable without waiting 3–7 days.
3. Make the controller observe itself. A dead actuator, a blind admission, or a rising trough is the first line of `diskm status`.
4. Measure success by the df trough and by samples with less than 15 GiB free, not by GiB reclaimed.

## 3. Non-goals

- Replacing existing actuators (`cleanup_tmp.sh`, `cleanup_colima.sh`, `worktree_reap.sh`, and others). The governor schedules them; it does not rewrite them.
- Fixing the full-attribution ledger (bead `4y6`). The governor works from df plus per-class du with stale labels.
- Reducing `~/.codex/sessions*` or `~/.claude/projects`. These are on the never-delete list.
- Linux portability beyond what the existing scripts already support.

## 4. Anti-goals (must not happen)

- Another sweeper tier, or a report of "GiB reclaimed" without `df_delta_bytes`.
- Approval gates that no scheduled job can satisfy.
- Expiring standing decisions. Decaying back into nominate mode would silently refill the disk.
- Loosening `~/.claude/hooks/protect-worktrees.sh` or giving agents removal authority.
- Recency proxies (`stat .git`, `stat <wt>`), ad-hoc cleanup scripts, or touching never-delete paths.
- Keyword or heuristic classification of artifacts. Class assignment is by **governed root path** (a fixed table), and the hook does a literal command-syntax match. Neither is a semantic judgment.
- Auto-pausing CI runners without decision D4.

## 5. Constraints

- **One operational entry point.** Everything is added as `diskm` subcommands in `src/disk_magician/disk_magician.sh` plus `disk_magician.sh`, kept in sync by `scripts/sync_package_tree.sh`.
- **One removal path.** All removal goes through `wrh_removal_verdict` / `wrh_remove_now` (`scripts/worktree_remove_hook.sh`) with byte-verified removal (#120). Non-worktree scratch goes through `scratch_budget_evict_root` (`scripts/lib/scratch_budget.sh`), which rechecks lsof before each delete.
- **Recency.** Recency is measured only through `scripts/lib/worktree_recency.sh` and fails closed.
- **Leases.** Lease semantics come from `scripts/lib/worktree_lease.sh`. Unknown means owner alive, which means keep.
- **Deploy.** Version bump, `tools/deploy_uv_tool.sh` from a clean checkout of origin/main, and verify `deployed.json` plus a scheduled receipt.
- **PR size.** Each PR is at most 150 production lines, or it goes through the size-tiered gate.
- **Disk-full operation.** The governor must run when the disk is full. State writes are atomic and small (under 64 KiB). The admission hot path does no du.

## 6. Approaches considered

The swarm produced three designs. A judge panel ranked them (the brief records the ranking but not the numeric scores):

| Rank | Design | Core idea | Strength | Weakness |
|---|---|---|---|---|
| 1 (winner) | **Budget governor** | Per-class byte budgets, a free-space setpoint, `diskm admit`, a 10-minute `govern` tick, df-verified receipts | Closes the loop. One controller. Measurable | Does not on its own shorten retention, or fix clones at the producer |
| 2 | **Lifecycle-first** (design 1) | Leases on every artifact kind, detached shared-object worktrees instead of clones, session-exit release, push on exit | Largest per-item cut (about 0.3 vs 2.3 GiB). Removable on exit | No budget or setpoint, so a spawn burst still fills the disk |
| 3 | **Policy and decisions** (design 3) | Standing-decision record, park-never-delete set, trough-rise alerts, 90-day decision expiry | Fixes "approval nobody can give". Makes the trough visible | Expiry rebuilds the babysitting. Changes no byte rates |

**Chosen:** design 1 as the base. It takes these grafts:

- From design 2: detached worktrees (C3/C4), session-exit release, and push on exit (C8).
- From design 3: the decision record (C11), the parked set (in C9), and trough alerts (in C12). The **90-day expiry is dropped**.

## 7. Chosen design

### 7.1 Control model

```
error = target_free - df_free
zone  = GREEN (>=100) | ORANGE (60..100) | RED (30..60) | BLACK (<30) ; hard floor 15
```

On each 10-minute tick, `diskm govern` does the following:

1. Measures df, plus a per-class du of each governed root. The du is time-bounded, and its age is recorded.
2. Writes `budget.json` atomically.
3. Runs actuators for the classes over budget, largest overage first.
4. Writes one receipt per actuator, with a df delta.

Admission reads `budget.json` in O(1) at creation time.

### 7.2 Components

| # | Component | Reuses | Closes |
|---|---|---|---|
| C1 | **Budget config and `diskm budget status`.** A `budgets` block in `config.json.template` and `safety.local.json`. Shell reader in `scripts/lib/disk_budget.sh`; Python twin in `scripts/disk_budget.py`. Writes `~/.disk_magician_state/budget.json` holding the zone, per-class `used_gb`/`budget_gb`/`measured_at`, the 24h/7d birth rate, the time to the next zone, and the `parked` list. A stale measurement shows its age and is never reported as 0 | `resolve_config.py`, `scripts/lib/scratch_roots.sh` | RC8, RC1 |
| C2 | **`diskm admit --class C --est-gb N`.** Exit codes: 0 admit, 10 warn, 75 refuse, 76 queue (prints `retry_after_s`). The policy table is fixed. If the measurement is unavailable or stale (over 30 min), it fails **open** with an `admission_blind` receipt and an alert. `wtn_admit` in `scripts/worktree_new.sh` delegates to it and keeps rc 75 | `wtn_free_gb` | RC1 (rate) |
| C3 | **Lease every artifact kind.** Add a `kind` field (worktree, clone, scratch, evidence) to `lease_write`. New `diskm scratch-new <repo> <purpose> [--kind K] [--detach <sha>]`. `--detach` runs `git worktree add --detach` under `~/.worktrees/<repo>/scratch-<purpose>-<ts>`, sharing the object store. `evidence-push` sets `published=true` on evidence leases | `scripts/lib/worktree_lease.sh`, `scripts/worktree_new.sh`, `scripts/evidence_push.sh` | RC1 (rate and retention) |
| C4 | **Source conversions.** `/advice` `run_primary_pair.py`, the advice-src-*, split-gates and gate-prep producers move from full clones to `diskm scratch-new --detach` | the 09-23 finding `findings_wiki/2026-09-23-verifier-lanes-should-use-worktrees-not-clones.md` | RC1 (largest per-item cut) |
| C5 | **Reuse first in `worktree-new`.** Recycle a worktree when all hold: same repo, owner dead, clean, HEAD on origin, idle at least 2 h, no live cwd, not locked. Recycling is `git switch --detach` then `-c <branch>`, and the lease is transferred. Nothing is deleted | lease library, `worktree_recency.sh`, `wrh_live_cwd_reason` | RC1 (rate) |
| C6 | **Admission hook.** `hooks/disk-admission.sh` (template tracked here) matches the literal syntax `git worktree add`, `git clone` and `cp -R` into governed roots. It calls `diskm admit` and denies on 75/76 with a reuse message. `~/.codex/AGENTS.md` gets one sentence | `diskm admit` | RC1 (rate) |
| C7 | **Birth audit.** On each tick, any new unleased top-level entry under the governed roots is adopted as owner-resolved and charged to its class, and `bypass{root}` is incremented. Governed roots: `/private/tmp/<repo>/*`, `~/Documents/Codex/<date>/*`, `~/.worktrees/*/*`. SLO: bypass under 10% of births | `lease_resolve_owner`, the `adopt` step in `worktree_reap.sh` | RC1 (coverage) |
| C8 | **Owner-lifecycle release.** A SessionEnd/SubagentStop hook runs `diskm lease-release --owner-session $ID`, which marks leases `owner_exited`. The skill contract is: create through diskm, normal `git push -u origin HEAD` before exit (never a force-push), publish evidence. Agents gain no removal authority | `lease_release`, `lease_set_verdict` | RC1 (retention) |
| C9 | **Ownership-ordered reclaim.** T1, T2 and T3 below, all through `wrh_removal_verdict` / `wrh_remove_now`. Anything else goes to `parked` in `budget.json`: listed daily with sizes, never deleted | `worktree_reap.sh` `verdict_for`, `cleanup_worktrees.sh` | RC1 (retention) |
| C10 | **`diskm govern`.** A 10-minute launchd tick that replaces the pressure-sweep and main-sweeper triggers. Each actuator gets its own deadline and lock. Each receipt carries `start_free_bytes`, `end_free_bytes`, `df_delta_bytes` and `outcome`; a null `df_delta` is an error. An actuator with zero df delta on 3 runs while its class is over budget is demoted | `job_receipt.py`, `pressure_sweep.sh` steps, `main_sweeper.sh` tiers | RC8 |
| C11 | **Standing-decision record.** `diskm policy approve <id> --phrase '<literal user text>'` writes `~/.config/disk-magician/standing_decisions.json`. Decisions are revocable with `diskm policy revoke <id>` and **never expire**. Plists stop relying on unset `WORKTREE_APPROVED` / `CLAUDE_STATE_APPROVED` and read the record through `decision_approved <id>` | `safety_lib.sh` | the reason deleting steps never ran |
| C12 | **Liveness and trough alerts** in `sweeper_health_check.sh` and at the top of `diskm status`: govern tick older than 30 min; `admission_blind`; 3 non-reclaiming runs while over budget; Colima stopped more than 1 h; main_sweeper erroring twice in a row; 7-day trough more than 15 GiB above the 30-day trough; parked set over 20 GiB | `check_launchd_fleet.sh`, `disk_observer.py` | RC8 |
| C13 | **CI backpressure.** In RED/BLACK the ezgha pre-job hook calls `diskm admit --class ci --est-gb 20`, and the governor prints a ready-to-run pause command. Auto-pause requires D4 | `diskm admit` | RC8 (bursts) |

### 7.3 Reclaim tiers (C9)

Every tier requires **all** of the following:

- Clean, including untracked files.
- No assume-unchanged or skip-worktree entries.
- No secret-like ignored file.
- No live cwd inside it.
- Not locked.
- Not under an AO worktree dir.
- Byte-verified removal.

| Tier | Additional condition | Needs |
|---|---|---|
| T1 | Lease `owner_exited` or expired, owner dead, and HEAD on origin (live `git ls-remote` equal) or merged | D1 |
| T2 | Owner null, and 24 h of measured inactivity (`worktree_is_recently_active`, fail-closed), and HEAD on origin or merged | D1 |
| T3 | The existing 3-day merged/origin rule in `cleanup_worktrees.sh` | already live |
| parked | Anything else: dirty, ahead of origin, or unmeasurable | listed only (D7) |

T1 and T2 are the owner-exit exception to the 7-day floor that bead `7u9t` asks for. Without D1 they run in nominate mode.

### 7.4 Budget model (assumption to validate)

- **Base.** About 715 GiB outside the governed classes.
- **Governed stock.** Rate × TTL: about 41 GiB typical, 66 GiB at the caps.
- **Prediction.** Typical free space of about 170 GiB, with a floor of about 120 GiB at the caps.

The per-worktree size (0.33–0.83 GiB), the removable fraction, and the 7× clone saving are unmeasured. The first 7 days of C10 receipts confirm or revise them.

## 8. Assumptions and recommended defaults (auto-picked)

| Question | Auto-picked default | Rationale |
|---|---|---|
| Setpoints | target 100, warn 60, refuse 30, floor 15 GiB free | Today's free space is below refuse, so enforcement is phased (D2) |
| Class budgets (GiB) | worktrees 40, tmp_containers 15, tmpdir_scratch 8, codex_documents 3, claude_codex_state 20, colima 35 | Roughly 1–2 days of measured production per class |
| Tick cadence | 10 min, with a per-actuator deadline of 300 s | Under the 1–2 h refill half-life. Avoids the 600 s step blocking all others |
| Admission when blind | Fail open, with a receipt and an alert | Never block all agent work on a measurement bug |
| Staleness bound for `budget.json` | 30 min | Three missed ticks |
| Class assignment | Fixed governed-root path table | Zero Framework Cognition: no semantic classification |
| `scratch-new --detach` location | `~/.worktrees/<repo>/scratch-<purpose>-<ts>` | Reuses the standard root and lease adoption |
| T2 inactivity | 24 h measured | Same as the lease TTL in the 10-10 lease design |
| Reuse idle threshold | 2 h | Short enough to cut births. Recycling deletes nothing |
| Decision expiry | none (revocable) | Expiry silently returns to nominate mode |
| Parked items | List daily, never delete | Unpushed or dirty work is user data |
| Receipt metric | `df_delta_bytes` required, `freed_bytes` optional | APFS clones make du unreliable |
| Rollout of refusal | observe 3 d, then warn, then refuse in RED/BLACK, then ORANGE for over-budget classes after 7 d | Refusing on day one would block all work at 7 GiB free |

## 9. Success metrics

Measured from `disk_observer.jsonl` (df only). The snapshot ledger is used only at coverage of 70% or more.

| Metric | Today | Target after 7 days of remove mode |
|---|---|---|
| 7-day minimum of df free | about 0.3 GiB | ≥ 80 GiB |
| Samples with free < 15 GiB per week | 605+ | 0 |
| Daily used trough | 839 GiB and rising | ≤ 790 GiB, flat or falling |
| worktrees class | about 101 GiB | ≤ 40 GiB |
| Receipts with non-null `df_delta_bytes` | 0% (sweepers) | 100% |
| Bypass births | unmeasured | < 10% |
| Govern ticks older than 30 min | n/a | 0 alerts per week |

The workstream bead closes only after **two consecutive weekly checks** pass. The check is `diskm budget status --weekly-check`.

## 10. Implementation preconditions (user decisions)

| ID | Decision | Recommended default | Blocks |
|---|---|---|---|
| D1 | Remove mode plus the owner-exit exception to the 7-day floor, for T1/T2 only (bead `7u9t`) | **Approve** | Stage 0 removal, C9 T1/T2 |
| D2 | Admission enforcement through the PreToolUse hook | **Phased:** observe, then warn, then refuse in RED/BLACK; ORANGE after 7 days | C6 refuse mode |
| D3 | Budget numbers | As in section 8 | C1 enforcement values |
| D4 | CI backpressure in RED/BLACK | **Alert with a pause command.** No auto-pause | C13 auto-pause |
| D5 | Push on exit (normal push, never a force-push) | **Approve** | C8 skill contract |
| D6 | Edits outside this repo: advice runner, gate producers, skill teardown text, AGENTS.md, SessionEnd hook in settings.json | **Approve** | C4, C6, C8 |
| D7 | Parked set (182 ahead, 44 dirty as of 10-08) | **List daily, never delete** | none (default is safe) |
| D8 | Colima self-heal: clear a stale lima lock and restart when stopped more than 30 min with no lima process | **Approve** | C12 auto-heal (alert ships regardless) |

A decision counts only when it is recorded through `diskm policy approve` with the literal user phrase. A bead comment or an agent report is not a decision.

## 11. Risks

- **Fail-open admission hides a broken governor.** Mitigation: an `admission_blind` alert on the first occurrence.
- **Reuse recycles a worktree an idle agent still expected to own.** Mitigation: requires owner dead plus clean plus pushed, and transfers the lease. No content is lost because HEAD is on origin.
- **Detached worktrees share the object store, so `git gc` in the main repo could prune objects a detached scratch needs.** Mitigation: `git worktree add` registers HEAD as a reachability root. `scripts/set_gc_worktree_prune.sh` already governs prune expiry.
- **The disk is too full to run the govern tick.** Mitigation: state writes are under 64 KiB; actuators that free space run first in BLACK.
