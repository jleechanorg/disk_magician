# Disk-fill durable control: diskm budget governor with owner-lifecycle leases

- **Date:** 2026-10-11 (revision 2, after the Opus `/advice` review and `/secondo`)
- **Status:** Design, auto-approved under `/superpowers-quick`. Budget numbers are **pilot values** until the pilot week (§7.4) validates them.
- **Base:** origin/main `688fff6` (v0.2.197, deployed 2026-10-11T20:43Z per `~/.disk_magician_state/deployed.json`)
- **Related code on main (PR #148, merged 2026-10-11T13:01Z):** `scripts/lib/worktree_lease.sh`, `scripts/worktree_reap.sh` (nominate/remove, `adopt`, `verdict_for`), `scripts/worktree_new.sh` (`wtn_admit`), `scripts/worktree_remove_hook.sh` (`wrh_removal_verdict` / `wrh_remove_now`), `scripts/lib/worktree_merged_pr.sh`, `launchd/com.jleechanorg.disk-magician-worktree-reap.plist.template`. The 10-10 lease design doc was never pushed (branch `docs/worktree-lease-design` is absent on origin); the owner-exit rule text lives in bead `7u9t`'s first comment.
- **Open PRs this depends on:** #150 (Colima stopped-VM guard, stale lima lock), #151 (`diskm cleanup-codex-documents`), #152 (`cleanup_tmp.sh` descends into active tmp containers under `--large`), #153 (`worktree_hygiene.sh` shared rebuildable-ignored allowlist).
- **Beads:** `7u9t`, `oyt4`, `67xj`, `d45`, `i2o`, `4y6`.
- **Plan:** `docs/superpowers/plans/2026-10-11-disk-fill-durable-control.md`

## 1. Why

At the time of writing, `df` shows **7.2 GiB free** (21:10Z) and 33.4 GiB free (22:10Z). The data volume's usable capacity is **about 895 GiB** (`df` used + available; the 926 GiB container size includes about 31 GiB held by other APFS volumes). The user has asked "stop the disk constantly filling" on 09-23, 10-03, 10-04, 10-05, 10-06, 10-08, 10-09, 10-10 and 10-11. In 30 days the repo produced five designs and about 80 merged PRs (#67–#149). None lowered the used-space trough.

### 1.1 30-day retrospective: what the data shows

All figures are from `~/.disk_magician_state/disk_observer.jsonl{,.1,.2}`: 12,878 df-only samples covering 10-02 to 10-11.

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
- Four reclaim events gave back about 40–63 GiB each and refilled within hours to about 2 days (median refill half-life about 1 hour; about 2 hours for drops of 38 GiB or more).

### 1.2 Verified root causes (survived adversarial refutation)

**RC1: open loop. Nothing limits creation, so standing stock = creation rate × retention.**

- **Births** under `~/.worktrees`: 40, 49, 41, 61 and 35 per day for 10-07 to 10-11 (confirmed by three verifiers).
- **Surviving stock:** about 17–38 GiB/day of worktrees born that day are still on disk.
- **Producer-side PRs:** only #107 (standard root, no teardown) and #148 (lease + admission gate, live in nominate mode). Every other PR improved a sweeper.
- **Retention** is set by the 3-day `cleanup_worktrees.sh` floor and the 7-day general floor, and `cleanup_worktrees.sh` itself only runs with `WORKTREE_APPROVED=1`, which no plist sets (`main_sweeper.sh:389`).
- **Unverified model inputs:** the /private/tmp rate (about 21 GiB/day) and the 45–50 GiB/day producer total.

**RC8: symptom and metric. The volume runs 91–97% full, so swings are as large as the headroom.**

- `pressure_sweep.sh` acts only below 40 GiB free with a fixed three-step list, so it holds the disk near 40 GiB instead of creating margin.
- A stopped Colima VM (stale lima lock since 10-08, bead `67xj`) could not fstrim, and nothing alerted.
- Adopted actions: alert on a rising trough and on a dead actuator; measure success by the df trough and minimum, never by "GiB reclaimed".

### 1.3 Refuted or demoted claims (kept as constraints)

| Claim | Verdict | What survives |
|---|---|---|
| RC2: age floors alone set the equilibrium | Refuted (about 53 GiB inside the floors; refill in hours) | Owner-exit release (T1) for provably safe items only |
| RC3: agents cannot tear down | Refuted as stated; the remove hook keeps dirty/unpushed/ignored/<7 d items | Session-exit release (C8). `protect-worktrees.sh` is **not** loosened |
| RC4: receipts report success from exit code | Refuted; the gap is null `df_delta` on main_sweeper, pressure_sweep, tmp_scratch_sweep | `df_delta_bytes` on governor receipts (C10); liveness alerts (C12) |
| RC5: no plist sets any approval | Refuted; four plists do. Worktree removal and claude-state remain permanent dry-runs | Standing-decision record (C11) for exactly those gates |
| RC6: measurement crowded out producer work | Refuted (~25% of PRs) | Count df_delta only, never du |
| RC7: about 7-day deploy lag | Refuted (19 installed versions 10-07..10-11) | None |
| RC9: no closure criterion | Refuted as a byte cause | Bead closes on two consecutive weekly checks (§9) |

### 1.4 What failed in the 30-day record

- About 78 PRs added or fixed sweepers; each reclaim lasted hours.
- Approval env vars (`WORKTREE_APPROVED`, `CLAUDE_STATE_APPROVED`) that no scheduled job sets.
- 30–60 minute control cadence against a 1–2 hour refill half-life; one 600 s step timeout blocked every later step.
- "Installed" trusted as "running" (fleet flapping, plutil corruption, Colima down 3 days, main_sweeper erroring 64/64).
- du counted as reclaim (`code_sign_clone` reported 104 GiB; deleting it freed about 0 on APFS).

## 2. Goals

1. Close the loop. Creation is admitted against a free-space zone computed from df on every call, plus per-class byte budgets where a class can be measured reliably.
2. Shorten retention where it is provably safe and already sanctioned: owner-exit release (D1) and activation of the existing 3-day `cleanup_worktrees.sh` rule.
3. Make the controller observe itself. A dead actuator, a blind admission, a stale tick or a rising trough is the first line of `diskm status`.
4. Measure success by df: the 7-day minimum free, samples under 15 GiB free, and the daily used trough.

## 3. Non-goals

- Replacing existing actuators or schedules. `main_sweeper` (including `snapshot_commit.sh`, every tier, and the health phase) and `pressure-sweep` **stay installed and unchanged**. The governor adds overage-driven triggering on top. Retiring either job is out of scope; revisit after 14 days of governor receipts.
- Moving `/advice` reviewer copies to linked worktrees (dropped, §6).
- Fixing full attribution (bead `4y6`).
- Reducing `~/.codex/sessions*` or `~/.claude/projects` (never-delete).
- Linux portability beyond what scripts already support.

## 4. Anti-goals (must not happen)

- Another sweeper tier, or a "GiB reclaimed" report without `df_delta_bytes`.
- Approval gates no scheduled job can satisfy; expiring standing decisions.
- Any new deletion rule that is not named in a recorded decision and in `CLAUDE.md`.
- Admission that goes blind because du is slow.
- Loosening `~/.claude/hooks/protect-worktrees.sh`, or giving agents removal authority.
- Recency proxies, ad-hoc cleanup scripts, never-delete paths, keyword/heuristic classification (classes come from a fixed governed-root path table; the hook does literal syntax matching).
- Auto-pausing CI runners without D4.

## 5. Constraints

- **One entry point.** New `diskm` subcommands in `src/disk_magician/disk_magician.sh` and `disk_magician.sh`, synced by `scripts/sync_package_tree.sh`.
- **One removal path.** Worktrees via `wrh_removal_verdict` / `wrh_remove_now` with byte-verified removal (#120); other scratch via `scratch_budget_evict_root` (`scripts/lib/scratch_budget.sh`, lsof recheck per delete).
- **Recency** only through `scripts/lib/worktree_recency.sh`, fail closed. **Leases** from `scripts/lib/worktree_lease.sh`; unknown owner = alive = keep.
- **Locks.** The governor takes each actuator's existing lock (`scratch_lock_acquire` in `cleanup_tmp.sh`, etc.). A held lock yields a `skipped_lock` receipt, never a wait, so it coexists with main_sweeper and pressure-sweep.
- **Deploy.** Version bump, `tools/deploy_uv_tool.sh` from clean origin/main, verify `deployed.json` plus a scheduled receipt.
- **PR size.** At most 150 production lines per PR, or the size-tiered gate.
- **Disk-full operation.** The tick and admission must work at about 5 GiB free: state writes are atomic, small (under 64 KiB), and a failed write keeps the previous file. Admission never runs du.

## 6. Approaches considered

| Rank | Design | Core idea | Strength | Weakness |
|---|---|---|---|---|
| 1 (winner) | **Budget governor** | Free-space zone + per-class budgets, `diskm admit`, 10-minute `govern` tick, df-verified receipts | Closes the loop; one controller; measurable | Does not on its own shorten retention |
| 2 | **Lifecycle-first** | Leases on every kind, detached worktrees instead of clones, session-exit release | Smaller per-item footprint for producers whose clones survive | No setpoint; burst still fills the disk |
| 3 | **Policy and decisions** | Decision record, parked set, trough alerts, 90-day expiry | Fixes "approval nobody can give" | Expiry rebuilds the babysitting |

**Chosen:** design 1, with grafts: from design 2, leases on every kind (C3), session-exit release (C8), and detached scratch for producers that need no isolation (C4, narrowed); from design 3, the decision record (C11), the parked set and trough alerts. The 90-day expiry is dropped.

**Dropped after review:** converting `/advice` (`run_primary_pair.py`) to linked worktrees. It deliberately uses `git clone --no-local` with `origin` removed so full-permission reviewers cannot touch the user's refs, config, hooks or stash, and it `shutil.rmtree`s each clone when the run ends. A linked worktree would share all of that and, because each copy gets an untracked `.advice-review-documents/`, the reaper would keep it as `kept:dirty`. Advice is governed by admission instead (C2, C7).

## 7. Chosen design

### 7.1 Control model

```
zone = from df free, recomputed on every tick AND on every admit call:
       GREEN (>=100) | ORANGE (60..100) | RED (30..60) | BLACK (<30) ; hard floor 15
class overage = class used_gb - budget_gb   (only for classes with a fresh measurement)
```

Each 10-minute `diskm govern` tick:

1. Reads df and writes the zone to `budget.json` **before** any class measurement.
2. Measures **one** du-measured class (round-robin, so each class is re-measured about hourly) with `timeout 60 du -skx`. On timeout the class keeps its prior value and its `stale_s` grows.
3. Reads cheap sources for the other classes: Colima from the observer's `colima.root_allocated_kb` (already collected each observer run).
4. Runs the birth audit (C7).
5. Runs actuators for classes in act mode: over-budget classes by overage, plus every class whose `trigger` is `zone` when the zone is RED or BLACK. In BLACK, the actuators with the best df-delta history in the last 7 days run first.
6. Writes one receipt per actuator with `free_bytes_before`, `free_bytes_after` and `df_delta_bytes`.

**Admission never goes blind on du.** `diskm admit` runs one `df` itself (milliseconds) to get the zone, and reads only class overage from `budget.json`. A class measurement older than 3 hours drops that class's overage term (the ORANGE over-budget rule weakens to the plain ORANGE rule); the zone rules still apply. Admission is blind, and fails open with an `admission_blind` receipt and alert, only when `df` itself fails.

**APFS copy-on-write.** A class whose du is unreliable is configured `measure: df_delta_only`. It has no overage term, its actuator runs on `trigger: zone`, and its effect is judged only by receipt `df_delta_bytes`. Pilot default: `codex_documents` and `tmpdir_scratch` are df-delta-only; the pilot week (§7.4) moves any class whose du-reported reduction disagrees with the df delta by more than 50% on 3 or more runs.

### 7.2 Components

| # | Component | Reuses | Closes |
|---|---|---|---|
| C1 | **Budget config and `diskm budget status`.** `budgets` block in `config.json.template` / `safety.local.json`: per class `budget_gb`, `measure` (`du`, `observer`, `df_delta_only`), `trigger` (`overage`, `zone`), `act` (`always` or a decision id). Shell reader `scripts/lib/disk_budget.sh`, Python twin `scripts/disk_budget.py`. Writes `budget.json`: zone, `zone_at`, per-class `used_gb`/`budget_gb`/`measured_at`/`stale_s`, birth rate, `bypass`, `parked`. A stale value shows its age and is never shown as 0 | `resolve_config.py`, `scripts/lib/scratch_roots.sh` | RC8, RC1 |
| C2 | **`diskm admit --class C --est-gb N`.** Exit 0 admit, 10 warn, 75 refuse, 76 queue (`retry_after_s`). Zone from live df; overage from `budget.json` if fresh. `wtn_admit` delegates to it and keeps rc 75. The `/advice` runner calls it once per run (class `tmpdir_scratch`, `--est-gb` = 2 × source checkout size) before creating clones, and stops with a clear message on 75 or after one 76 retry | `wtn_free_gb` | RC1 (rate) |
| C3 | **Lease every artifact kind.** Optional `kind` (worktree, clone, scratch, evidence) on leases. New `diskm scratch-new <repo> <purpose> [--kind K] [--detach <sha>]` creating `~/.worktrees/<repo>/scratch-<purpose>-<ts>`. `evidence-push` marks evidence leases published | `worktree_lease.sh`, `worktree_new.sh`, `evidence_push.sh` | RC1 |
| C4 | **Narrow producer conversion.** Only producers that run no full-permission agent in the checkout and whose clones survive the run (shown by C7 adoption counts) move to `scratch-new --detach`, and only if they write outputs outside the checkout so it stays clean at release. Candidates: gate-prep, split-gates. Excluded: `/advice` (`run_primary_pair.py`, advice-src-*) | `findings_wiki/2026-09-23-verifier-lanes-should-use-worktrees-not-clones.md` | RC1 |
| C5 | **Reuse first in `worktree-new`.** Recycle only when: same repo, owner dead or released, clean including untracked, no assume-unchanged/skip-worktree, **no ignored secret-like file and no non-rebuildable ignored data** (same checks as `wrh_removal_verdict`), HEAD on origin, idle ≥ 2 h measured, no live cwd, not locked, not AO. Recycle = `git switch --detach` then `-c <branch>`; lease transferred; nothing deleted | lease lib, `worktree_recency.sh`, `scripts/lib/worktree_ignored.sh` | RC1 |
| C6 | **Admission hook (best effort).** `hooks/disk-admission.sh` (PreToolUse Bash). Splits the command on `&&`, `;`, `\|\|`, `\|`; strips leading `VAR=value` assignments; tracks a preceding `cd <dir>` segment; recognises `git [-C <dir>] worktree add <path>`, `git [-C <dir>] clone … <dest>` and `cp -R … <dest>` with a destination under a governed root. Calls `diskm admit`; denies on 75/76 with a reuse message. It is **not** the completeness mechanism: the birth audit (C7) is | `diskm admit` | RC1 |
| C7 | **Birth audit (authoritative coverage).** Each tick, every new unleased top-level entry under a governed root is adopted with an owner-resolved lease and charged to its class; `bypass{root}` increments. Governed roots: `/private/tmp/<repo>/*`, **`$TMPDIR/*`** (where `/advice` clones live; resolved via `getconf DARWIN_USER_TEMP_DIR`), `~/Documents/Codex/<date>/*`, `~/.worktrees/*/*`. SLO: bypass under 10% of births | `lease_resolve_owner`, `adopt` in `worktree_reap.sh` | RC1 |
| C8 | **Owner-lifecycle release.** SessionEnd/SubagentStop hook runs `diskm lease-release --owner-session $ID`. Skill contract: create through diskm, `git push -u origin HEAD` before exit (never force), publish evidence. Agents gain no removal authority | `lease_release` | RC1 |
| C9 | **Ownership-ordered reclaim.** T1 and T3 (§7.3), all through `wrh_removal_verdict` / `wrh_remove_now`. Everything else goes to `parked`, listed daily with sizes, never deleted | `worktree_reap.sh`, `cleanup_worktrees.sh` | RC1 |
| C10 | **`diskm govern`.** 10-minute launchd tick. Act mode is **per class** (`act` in C1). Each actuator has a 300 s deadline and its own existing lock. Governor receipts (job `govern_<class>`) carry `free_bytes_before`, `free_bytes_after`, `df_delta_bytes` (the keys `worktree_reap.sh` already writes); a null delta is an error. Zero or negative delta on 3 runs while over budget raises `actuator_dead` | `job_receipt.py`, existing actuators | RC8 |
| C11 | **Standing-decision record.** `diskm policy approve <id> --phrase '<literal user text>'` writes `~/.config/disk-magician/standing_decisions.json`; revocable, **never expires**. `decision_approved <id>` replaces unset env approvals | `safety_lib.sh` | RC5 |
| C12 | **Liveness and trough alerts** first in `diskm status` and `sweeper_health_check.sh`: govern tick older than 30 min; `admission_blind`; class stale > 3 h; `actuator_dead`; Colima stopped > 1 h; main_sweeper erroring twice running; 7-day trough > 15 GiB above the 30-day trough; parked > 20 GiB | `check_launchd_fleet.sh`, `disk_observer.py` | RC8 |
| C13 | **CI backpressure.** In RED/BLACK the ezgha pre-job hook calls `diskm admit --class ci --est-gb 20`; the governor prints a ready pause command. Auto-pause needs D4 | `diskm admit` | RC8 |

Class table (pilot defaults; actuators unchanged):

| Class | Root(s) | Measure | Trigger | Actuator | Act |
|---|---|---|---|---|---|
| worktrees | `~/.worktrees/*/*` | du (round-robin) | overage | `worktree_reap.sh` (T1); `cleanup_worktrees.sh --clean` (T3) | nominate until D1; T3 until D1b |
| tmp_containers | `/private/tmp/<repo>/*` | du | overage | `cleanup_tmp.sh --clean` (as changed by #152) | always (runs unattended today) |
| tmpdir_scratch | `$TMPDIR` | df_delta_only | zone | `tmp_scratch_sweep.sh` | always |
| codex_documents | `~/Documents/Codex` | df_delta_only | zone | `diskm cleanup-codex-documents --clean` (#151) | always, once #151 is deployed |
| claude_codex_state | `~/.claude/state`, `~/.codex` minus never-delete | du | overage | `cleanup_codex_db.sh` (always); `cleanup_claude_state.sh` (decision `claude_state_cleanup`) | split as shown |
| colima | `~/.colima/_lima` | observer | overage | `cleanup_colima.sh` (fstrim; #150 guard) | always |

### 7.3 Reclaim tiers (C9)

Every tier requires **all** of: clean including untracked files; no assume-unchanged or skip-worktree entries; no secret-like ignored file; **no non-rebuildable ignored data** (anything outside the rebuildable allowlist in `scripts/lib/worktree_ignored.sh`, which #153 makes `worktree_hygiene.sh` share); no live cwd inside; not locked; not under an AO worktree dir; byte-verified removal.

| Tier | Additional condition | Needs |
|---|---|---|
| T1 | Lease owner ended per bead `7u9t`: dead pid+lstart with 30 min quiet, or released / 24 h TTL expired with 6 h quiet; HEAD on origin (live `git ls-remote` equal) or merged | D1 |
| T3 | The existing 3-day rule in `cleanup_worktrees.sh` (merged or HEAD-on-origin, hidden-state, AO and live-cwd gates), run under the governor | D1b |
| parked | Anything else, including owner-null worktrees younger than 3 days | listed only (D7) |

**Owner-null 24 h tier (T2) is dropped.** It would delete human-created worktrees that never had a lease after one idle day, which is a new exception to the 7-day floor and contradicts "unknown owner = keep". The safer choice is T3: owner-null worktrees become removable only under the 3-day rule `CLAUDE.md` already sanctions for `cleanup_worktrees.sh`. T3 needs no policy change, only a recorded decision (D1b) because no plist sets `WORKTREE_APPROVED`.

**T1 is a policy change.** `CLAUDE.md` names `cleanup_worktrees.sh` as the sole exception to the 7-day floor. The PR that lets `worktree_reap.sh` run in remove mode from a standing decision must also amend `CLAUDE.md` with the T1 wording above, quoting D1.

### 7.4 Budget model and pilot week

Arithmetic (all GiB): usable `U = 895`; base outside governed classes `B ≈ 715` (assumption); pilot class budgets sum `S = 108` (35 + 15 + 10 + 3 + 15 + 30); minimum-free target `F = 30` (the RED/BLACK boundary).

- Admission must hold `B + S + W ≤ U − F`, where `W` is the intraday swing not covered by governed classes. With the pilot values, `W ≤ 895 − 715 − 108 − 30 = 42`.
- At the caps with no ungoverned swing, used is 823 and free is 72 (ORANGE). With typical governed stock (about 41), used is about 756 and free about 139 (GREEN).
- The observed 54–131 GiB swing is mostly governed-class bursts today; admission bounds the governed part at `S − typical ≈ 67`. Whether the remainder fits in `W ≤ 42` is the pilot's main question.

The previous revision's "free ≥ 80 GiB" target was inconsistent (715 + 121 left 59 free at the caps) and is withdrawn.

**Pilot week (secondo condition 2).** Govern runs 7 days in observe mode with alerts on. It records per-class used, `B = used − Σ class used` per sample, `W` = daily max − min of `B`, du-versus-df agreement per class, and births per day. D3 is recorded with numbers that satisfy the inequality using the measured 95th-percentile `W`; if they cannot, D3 lowers class budgets first. Enforcement may not pass `warn` before D3.

## 8. Assumptions and recommended defaults (auto-picked)

| Question | Auto-picked default | Rationale |
|---|---|---|
| Setpoints | GREEN ≥ 100, ORANGE 60–100, RED 30–60, BLACK < 30, floor 15 GiB free | Matches `F = 30`; floor gives last-resort margin |
| Class budgets (GiB, pilot) | worktrees 35, tmp_containers 15, tmpdir_scratch 10, codex_documents 3, claude_codex_state 15, colima 30 (sum 108) | Satisfies §7.4 with `W ≤ 42`; validated in the pilot week |
| Zone source | Live df on every tick and every admit | Admission cannot go blind on du |
| Class measurement | One du class per tick (≈ hourly each), `timeout 60`; Colima from observer; df-delta-only for CoW-prone classes | du stalls past 60 s on this host |
| Class staleness | 3 h drops the class's overage term only | Weakens ORANGE rule, never the zone rules |
| Admission when df fails | Fail open + `admission_blind` receipt + alert | Never block all work on a measurement bug |
| Tick cadence | 10 min; 300 s per actuator | Under the 1–2 h refill half-life |
| Act mode | Per class; only worktree removal is decision-gated | Today's unattended actuators keep running |
| main_sweeper / pressure-sweep | Unchanged and installed | Snapshot ledger and all tiers keep running |
| `/advice` | Keep isolated `clone --no-local` + `rmtree`; admit once per run; `$TMPDIR` governed | Isolation is deliberate |
| Owner-null worktrees | T3 3-day rule only (no T2) | Safer; no new policy exception |
| Reuse idle threshold | 2 h, plus ignored-data checks | Recycling deletes nothing but must not leak secrets |
| Hook coverage | Best effort; birth audit is authoritative | Shell syntax cannot be matched completely |
| Decision expiry | None (revocable) | Expiry silently returns to nominate mode |
| Parked items | List daily, never delete | Unpushed or dirty work is user data |
| Receipt metric | `df_delta_bytes` required for `govern_*` jobs | APFS clones make du unreliable |
| Enforcement rollout | observe 7 d (pilot) → warn → `refuse_red` after D3 → `refuse_orange` 7 d later | Day-one refusal at 7 GiB free would block all work |

## 9. Success metrics

Measured from `disk_observer.jsonl` (df only); the snapshot ledger only at coverage ≥ 70%.

| Metric | Today | Target after 7 days of T1 + T3 remove mode |
|---|---|---|
| 7-day minimum of df free | about 0.3 GiB | ≥ 30 GiB |
| Samples with free < 15 GiB per week | 605+ | 0 |
| Daily used trough (7-day max of daily minimums) | 839 GiB and rising | ≤ 790 GiB (free ≥ 105), not rising |
| Receipts for `govern_*` with non-null `df_delta_bytes` | n/a | 100% |
| Bypass births | unmeasured | < 10% |
| Govern ticks older than 30 min | n/a | 0 alerts per week |

`diskm budget status --weekly-check` evaluates exactly these six rows and exits 0 only if all pass. The workstream bead closes after **two consecutive** passing weekly checks. Stretch target, not a closure criterion: 7-day minimum free ≥ 60 GiB after D3 is re-tuned with two weeks of data.

## 10. Implementation preconditions (user decisions)

| ID | Decision | Recommended default | Blocks |
|---|---|---|---|
| D1 | Owner-exit removal (T1) exception to the 7-day floor, wording as in §7.3 / bead `7u9t`, with the `CLAUDE.md` amendment in the same PR | **Approve** | Stage 0 reap, T1 remove mode |
| D1b | Run the existing 3-day `cleanup_worktrees.sh --clean` unattended (T3) | **Approve** | T3 under govern and main_sweeper |
| D2 | Admission enforcement via `wtn_admit` and the hook | **Phased** per §8 | C2/C6 refuse modes |
| D3 | Budget numbers from the pilot week, satisfying §7.4 | Record after pilot | enforcement beyond `warn` |
| D4 | CI backpressure | **Alert + pause command, no auto-pause** | C13 auto-pause |
| D5 | Push on exit (normal push only) | **Approve** | C8 skill contract |
| D6 | Edits outside this repo: `/advice` admit call, gate producers, skill text, AGENTS.md, SessionEnd hook | **Approve** | C2 (advice), C4, C6, C8 |
| D7 | Parked set | **List daily, never delete** | none |
| D8 | Colima self-heal (clear stale lima lock, restart when stopped > 30 min with no lima process) | **Approve** | C12 auto-heal (alert ships regardless) |
| — | `claude_state_cleanup` decision for `cleanup_claude_state.sh` | Ask separately | claude-state actuator only |

A decision counts only when recorded through `diskm policy approve` with the user's literal phrase, written after the user said it. A bead comment or an agent report is not a decision.

## 11. Risks

- **A bug makes df fail and admission fails open.** Mitigation: `admission_blind` alert on the first occurrence.
- **The base `B` is larger than assumed.** Mitigation: the pilot measures it; D3 lowers budgets first.
- **Governor and existing jobs run the same actuator.** Mitigation: the actuator's own lock; the loser records `skipped_lock`.
- **Reuse hands an idle agent's worktree to a new owner.** Mitigation: owner dead or released, clean, pushed, no ignored secret or non-rebuildable data; lease transferred.
- **Detached scratch shares the object store with the main repo.** Mitigation: C4 is limited to producers that run no agent in the checkout; `git worktree add` registers HEAD as a reachability root; `scripts/set_gc_worktree_prune.sh` governs prune expiry.
- **The disk is too full to write state.** Mitigation: writes under 64 KiB, atomic replace keeps the previous file on ENOSPC, and the plan's stress test runs a tick at about 5 GiB free and on a full image.
