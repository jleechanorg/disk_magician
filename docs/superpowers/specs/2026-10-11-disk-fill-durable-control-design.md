# Disk-fill durable control: diskm budget governor with owner-lifecycle leases

- **Date:** 2026-10-11 (revision 3, after the Opus `/advice` review, `/secondo`, and `/web-advice` ChatGPT + Gemini, both NOT APPROVED on revision 2)
- **Status:** Design, auto-approved under `/superpowers-quick`. Budget numbers are **pilot values** until the pilot week (§7.4) validates them.
- **Base:** origin/main `688fff6` (v0.2.197, deployed 2026-10-11T20:43Z per `~/.disk_magician_state/deployed.json`)
- **Related code on main (PR #148, merged 2026-10-11T13:01Z):** `scripts/lib/worktree_lease.sh` (`lease_owner_state`: pid + `start_epoch` from `ps -o lstart`), `scripts/worktree_reap.sh` (nominate/remove, `adopt`, `verdict_for`), `scripts/worktree_new.sh` (`wtn_admit`), `scripts/worktree_remove_hook.sh` (`wrh_removal_verdict` / `wrh_remove_now` / `wrh_live_cwd_reason`), `scripts/lib/worktree_merged_pr.sh`, `launchd/com.jleechanorg.disk-magician-worktree-reap.plist.template`. The 10-10 lease design doc was never pushed (branch `docs/worktree-lease-design` is absent on origin); the owner-exit rule text lives in bead `7u9t`'s first comment.
- **Open PRs this depends on:** #150 (Colima stopped-VM guard, stale lima lock), #151 (`diskm cleanup-codex-documents`), #152 (`cleanup_tmp.sh` descends into active tmp containers under `--large`), #153 (`worktree_hygiene.sh` shared rebuildable-ignored allowlist).
- **Beads:** `7u9t`, `oyt4`, `67xj`, `d45`, `i2o`, `4y6`.
- **Plan:** `docs/superpowers/plans/2026-10-11-disk-fill-durable-control.md`

**Revision 3 changes.** Admission reserves `--est-gb` bytes in an flock'd ledger and decides on projected free (§7.1). The birth audit is stated as detection; prevention moves earlier (hook, `/advice`, evidence producers before the pilot), and BLACK/floor is a stage-independent emergency (§7.1, §7.5). The pilot starts only after admission, hook and audit are live, measures every term, and sizes `W` from the maximum swing plus margin (§7.4). Owner death is pid + start epoch only; TTL reports (§7.3). One final per-artifact check, `artifact_removal_verdict`, precedes every removal (C14). The `CLAUDE.md` amendment precedes the first T1 removal; the governor tick has a time-sliced, rotating scheduler (C10).

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

1. Close the loop at creation. Every governed producer reserves its estimated bytes before writing; admission decides on projected free (`df` free minus active reservations minus the request), plus per-class byte budgets where a class can be measured reliably.
2. Bound what admission cannot see. Producers outside admission are detected by the birth audit and counted in births and bytes; the BLACK emergency and the 15 GiB hard floor are the guarantee, not the pilot's `W`.
3. Shorten retention where it is provably safe and already sanctioned: owner-exit release (D1) and activation of the existing 3-day `cleanup_worktrees.sh` rule, each behind one final per-artifact check.
4. Make the controller observe itself. A dead actuator, a blind admission, a stale tick, a starved actuator, material bypass or a rising trough is the first line of `diskm status`.
5. Measure success by df: the 7-day minimum free, samples under 15 GiB free, and the daily used trough.

## 3. Non-goals

- Replacing existing actuators or schedules. `main_sweeper` (including `snapshot_commit.sh`, every tier, and the health phase) and `pressure-sweep` **stay installed and unchanged**. The governor adds overage-driven triggering on top and may kickstart `pressure-sweep` early in BLACK. Retiring either job is out of scope; revisit after 14 days of governor receipts.
- Moving `/advice` reviewer copies to linked worktrees (dropped, §6).
- Fixing full attribution (bead `4y6`).
- Reducing `~/.codex/sessions*` or `~/.claude/projects` (never-delete).
- Linux portability beyond what scripts already support.

## 4. Anti-goals (must not happen)

- Another sweeper tier, or a "GiB reclaimed" report without `df_delta_bytes`.
- Approval gates no scheduled job can satisfy; expiring standing decisions.
- Any new deletion rule that is not named in a recorded decision and in `CLAUDE.md`, or any removal that skips `artifact_removal_verdict`.
- Admission that goes blind because du is slow, or that admits concurrent requests whose sum exceeds the space it computed.
- Claiming the loop is closed while bypass births or bytes exceed the §7.5 SLO.
- Treating lease TTL expiry, quiet time or a session-end event as proof that an owner is dead.
- Loosening `~/.claude/hooks/protect-worktrees.sh`, or giving agents removal authority.
- Recency proxies, ad-hoc cleanup scripts, never-delete paths, keyword/heuristic classification (classes come from a fixed governed-root path table; the hook does literal syntax matching).
- Auto-pausing CI runners without D4.

## 5. Constraints

- **One entry point.** New `diskm` subcommands in `src/disk_magician/disk_magician.sh` and `disk_magician.sh`, synced by `scripts/sync_package_tree.sh`.
- **One removal gate.** Every removal (T1, T3, scratch eviction, recycling) first calls `artifact_removal_verdict` (C14) immediately before the destructive call. Worktrees are then removed by `wrh_remove_now` (byte-verified, #120); non-git scratch by `scratch_budget_evict_root` (lsof recheck per delete).
- **Recency** only through `scripts/lib/worktree_recency.sh`, fail closed. **Owner liveness** only through `lease_owner_state` (pid + `start_epoch`); `unknown`/`unreadable` = alive = keep.
- **Locks.** One global `govern.lock` per tick (an overlapping tick exits `skipped_tick_lock`). The governor takes each actuator's existing lock; a held lock yields `skipped_lock`, never a wait, so it coexists with main_sweeper and pressure-sweep. The reservation ledger uses `fcntl.flock` from Python (macOS has no `flock(1)`).
- **Timeouts** via Python `subprocess` timeouts (macOS has no `timeout(1)` without coreutils).
- **Deploy.** Version bump, `tools/deploy_uv_tool.sh` from clean origin/main, verify `deployed.json` plus a scheduled receipt.
- **PR size.** At most 150 production lines per PR, or the size-tiered gate.
- **Disk-full operation.** The tick and admission must work at about 5 GiB free: state writes are atomic, small (under 64 KiB), and a failed write keeps the previous file. Admission never runs du.

## 6. Approaches considered

| Rank | Design | Core idea | Strength | Weakness |
|---|---|---|---|---|
| 1 (winner) | **Budget governor** | Free-space zone + per-class budgets, `diskm admit` with reservations, 10-minute `govern` tick, df-verified receipts | Closes the loop; one controller; measurable | Does not on its own shorten retention |
| 2 | **Lifecycle-first** | Leases on every kind, detached worktrees instead of clones, session-exit release | Smaller per-item footprint for producers whose clones survive | No setpoint; burst still fills the disk |
| 3 | **Policy and decisions** | Decision record, parked set, trough alerts, 90-day expiry | Fixes "approval nobody can give" | Expiry rebuilds the babysitting |

**Chosen:** design 1, with grafts: from design 2, leases on every kind (C3), session-exit release (C8), and detached scratch for producers that need no isolation (C4, narrowed); from design 3, the decision record (C11), the parked set and trough alerts. The 90-day expiry is dropped.

**Dropped after review:** converting `/advice` (`run_primary_pair.py`) to linked worktrees. It deliberately uses `git clone --no-local` with `origin` removed so full-permission reviewers cannot touch the user's refs, config, hooks or stash, and it `shutil.rmtree`s each clone when the run ends. A linked worktree would share all of that and, because each copy gets an untracked `.advice-review-documents/`, the reaper would keep it as `kept:dirty`. Advice is governed by admission instead (C2, C7).

## 7. Chosen design

### 7.1 Control model

```
reserved      = sum(est_bytes of active reservations)           # flock'd ledger, C2
projected     = df_free - reserved - est                        # per admit call
zone(x)       = GREEN (>=100) | ORANGE (60..100) | RED (30..60) | BLACK (15..30) | FLOOR (<15)
tick zone     = zone(df_free);  admission zone = zone(projected)
class overage = class used_gb - budget_gb   (only for classes with a fresh measurement)
```

**Reservations (C2).** `~/.disk_magician_state/admission/reservations.json`, read-modify-written under `fcntl.flock` on `reservations.lock`. Entry: `{id, class, owner, pid, start_epoch, est_bytes, start_at, expires_at}`. An admit (rc 0 or 10) appends its entry inside the same lock that computed `projected`, so N concurrent callers are serialized and the k-th sees the first k−1. Refusals (75, 76) reserve nothing. An entry is dropped when: the caller runs `diskm admit --release <id>` (callers release in an EXIT trap after creation completes, when the bytes are on disk and in df); `expires_at` passes (default 30 min, `--ttl-min` max 240); or its pid is dead by pid + `start_epoch`. A corrupt ledger is moved aside, an `admission_ledger_reset` alert fires, and the ledger restarts empty (bounded by the 30-minute TTL). While a reservation is active its bytes may be counted twice (once in df as they land, once reserved); that errs toward refusing.

**Emergency rows are stage-independent once D2 is recorded.** Admission zone FLOOR → 75 for every governed class in every stage; BLACK → 76 (`retry_after_s=600`) in every stage. Callers treat 76 as "do not create now": retry once after `retry_after_s`, then stop. A tick whose df zone is BLACK or FLOOR kickstarts the existing pressure-sweep job (`launchctl kickstart gui/$UID/com.jleechanorg.disk-magician-pressure-sweep`; its own lock prevents overlap) and runs zone-trigger actuators first. A producer that bypasses admission is therefore bounded by its write rate over at most one 10-minute tick before every admitted producer stops and reclaim starts; the 15 GiB floor is the margin for that burst.

Each 10-minute `diskm govern` tick, under `govern.lock`:

1. Reads df, writes the tick zone to `budget.json` **before** any class measurement, and handles BLACK/FLOOR as above.
2. Measures **one** du-measured class (round-robin, about hourly each) with a 60 s timeout. On timeout the class keeps its prior value and its `stale_s` grows. Once a day (first tick after 03:00 local) it also measures each `df_delta_only` class with a 120 s timeout for accounting only (§7.4), carrying the prior value forward on timeout.
3. Reads cheap sources for the other classes: Colima from the observer's `colima.root_allocated_kb`.
4. Runs the birth audit (C7).
5. Runs actuators for classes in act mode through the scheduler (C10).
6. Writes one receipt per actuator with `free_bytes_before`, `free_bytes_after` and `df_delta_bytes`.

**Admission never goes blind on du.** `diskm admit` runs one `df` itself and reads only class overage from `budget.json`. A class measurement older than 3 hours drops that class's overage term; the zone rules still apply. Admission fails open with an `admission_blind` receipt and alert only when `df` itself fails. Any caller that gets an exit code other than 0, 10, 75, 76 (or cannot run `diskm admit`) follows the same rule: proceed, write `admission_blind`, print one warning line.

**APFS copy-on-write.** A class whose du is unreliable is `measure: df_delta_only` for control: no overage term, actuator on `trigger: zone`, effect judged by receipt `df_delta_bytes`. Its daily du feeds only the pilot's `B` arithmetic. Pilot default: `codex_documents` and `tmpdir_scratch`; the pilot moves any class whose du-reported reduction disagrees with the df delta by more than 50% on 3 or more runs.

### 7.2 Components

| # | Component | Reuses | Closes |
|---|---|---|---|
| C1 | **Budget config and `diskm budget status`.** `budgets` block in `config.json.template` / `safety.local.json`: per class `budget_gb`, `measure` (`du`, `observer`, `df_delta_only`), `trigger` (`overage`, `zone`), `act` (`always` or a decision id). Shell reader `scripts/lib/disk_budget.sh`, Python twin `scripts/disk_budget.py`. Writes `budget.json`: zone, `zone_at`, per-class `used_gb`/`budget_gb`/`measured_at`/`stale_s`, reserved bytes, birth rate, `bypass` (births and bytes), `parked`. A stale value shows its age and is never shown as 0 | `resolve_config.py`, `scripts/lib/scratch_roots.sh` | RC8, RC1 |
| C2 | **`diskm admit --class C --est-gb N [--owner S] [--ttl-min M]`** prints `reservation_id` on 0/10. Exit 0 admit, 10 warn (proceed), 75 refuse, 76 queue (`retry_after_s`). Decides on `zone(projected)` and fresh overage (§7.1, plan policy table). `diskm admit --release <id>` frees it. `wtn_admit` delegates and keeps rc 75 | `wtn_free_gb`, `lease_owner_state` | RC1 (rate) |
| C3 | **Lease every artifact kind.** Optional `kind` (worktree, clone, scratch, evidence) on leases. New `diskm scratch-new <repo> <purpose> [--kind K] [--detach <sha>]` creating `~/.worktrees/<repo>/scratch-<purpose>-<ts>`, admitted first. `evidence-push` marks evidence leases `published` after a successful upload receipt | `worktree_lease.sh`, `worktree_new.sh`, `evidence_push.sh` | RC1 |
| C4 | **Narrow producer conversion.** Only producers that run no full-permission agent in the checkout and whose clones survive the run (shown by C7 adoption counts) move to `scratch-new --detach`, and only if they write outputs outside the checkout. Candidates: gate-prep, split-gates. Excluded: `/advice` | `findings_wiki/2026-09-23-verifier-lanes-should-use-worktrees-not-clones.md` | RC1 |
| C5 | **Reuse first in `worktree-new`.** Claim a candidate with `lease_write_pending` (single owner), then require `artifact_removal_verdict` = `remove` (C14) plus same repo, owner `dead`/`released`, idle ≥ 2 h measured. Old local branch: if `git branch --merged origin/main` lists it or its tip equals the live `git ls-remote` tip, delete it with `git branch -d` (never `-D`) after switching away; otherwise refuse to recycle and create fresh. Recycle = `git switch --detach`, `git switch -c <branch> <base>`; lease transferred; no `git clean` | lease lib, C14 | RC1 |
| C6 | **Admission hook (prevention for agent shells).** `hooks/disk-admission.sh` (PreToolUse Bash). Splits on `&&`, `;`, `\|\|`, `\|`; strips leading `VAR=value`; tracks `cd <dir>` and `git -C <dir>`; recognises `git worktree add <path>`, `git clone … <dest>`, `cp -R … <dest>` with a destination under a governed root. rc 0 allow; 10 allow with a warning message; 75 deny with reuse message; 76 deny with `retry_after_s`. Forms it cannot parse are covered only by detection (C7) | `diskm admit` | RC1 |
| C7 | **Birth audit (detection, not prevention).** Each tick, every new unleased top-level entry under a governed root is adopted with an owner-resolved lease, charged to its class, and counted in `bypass{root}` births and bytes (bounded 30 s du at adoption; timeout counts as `bytes_unknown`). Adoption is accounting only: it grants no removal authority beyond the class actuator's own rules plus C14. Governed roots: `/private/tmp/<repo>/*`, `$TMPDIR/*` (resolved via `getconf DARWIN_USER_TEMP_DIR`, also when `TMPDIR` is unset), `~/Documents/Codex/<date>/*`, `~/.worktrees/*/*`. `$TMPDIR` entries not matching a producer prefix from the fixed table (`advice-*`, `tmp*` clones with a `.git`) are counted as `foreign` and never adopted | `lease_resolve_owner`, `adopt` in `worktree_reap.sh` | RC1 |
| C8 | **Owner-lifecycle release.** SessionEnd/SubagentStop hook runs `diskm lease-release --owner-session $ID`. It releases a lease only when `owner.session == $ID` and the owner pid is the ending runtime (same pid and `start_epoch`) or `dead`; a lease owned by any other live pid is left and reported. Release deletes nothing. Skill contract: create through diskm, `git push -u origin HEAD` before exit (never force), publish evidence. Agents gain no removal authority | `lease_release`, `lease_owner_state` | RC1 |
| C9 | **Ownership-ordered reclaim.** T1 and T3 (§7.3), each gated by C14 then `wrh_remove_now`. Everything else goes to `parked`, listed daily with sizes, never deleted | `worktree_reap.sh`, `cleanup_worktrees.sh` | RC1 |
| C10 | **`diskm govern` scheduler.** 10-minute launchd tick, global `govern.lock`, 540 s tick budget. Eligible actuators run serially in order of oldest `last_ran_at` (BLACK: best 7-day df delta first, but any actuator deferred 3 ticks running goes first). Each gets a slice `min(300, remaining / actuators_left)`, floor 60 s; one that cannot get 60 s is recorded `deferred` and goes first next tick. An actuator killed at its slice records `timeout` and keeps its carry-over position. Receipts (`govern_<class>`) carry `free_bytes_before`, `free_bytes_after`, `df_delta_bytes`; a null delta is an error. `df_delta_bytes` is net volume change, so `actuator_dead` needs 3 non-positive deltas while over budget **and** the actuator's own receipt reporting zero candidates removed | `job_receipt.py`, existing actuators | RC8 |
| C11 | **Standing-decision record.** `diskm policy approve <id> --phrase '<literal user text>' --from-transcript <session.jsonl>` writes `~/.config/disk-magician/standing_decisions.json` only if the phrase appears verbatim in a `type: user` message (not a tool result) of that transcript; revocable, **never expires**. This is a procedural record, not a security boundary: any process running as the user can write the file. `decision_approved <id>` replaces unset env approvals | `safety_lib.sh` | RC5 |
| C12 | **Liveness and trough alerts** first in `diskm status` and `sweeper_health_check.sh`: govern tick older than 30 min; `admission_blind`; `admission_ledger_reset`; class stale > 3 h; `actuator_dead`; `actuator_starved` (deferred or timed out 3 ticks running); `bypass_high` (§7.5 SLO missed over 24 h); Colima stopped > 1 h; main_sweeper erroring twice running; 7-day trough > 15 GiB above the 30-day trough; parked > 20 GiB. "Healthy" means a recent valid receipt with progress, not `launchctl list` | `check_launchd_fleet.sh`, `disk_observer.py` | RC8 |
| C13 | **CI backpressure.** The ezgha pre-job hook calls `diskm admit --class colima --est-gb 20` (CI writes land in the Colima disk, so it charges that class; no separate CI budget). 10 proceeds with a log line; 75 fails the job early with the admit message; 76 waits `retry_after_s` once, then fails. The governor prints a ready pause command in RED/BLACK; auto-pause needs D4 | `diskm admit` | RC8 |
| C14 | **`artifact_removal_verdict <path>`** (`scripts/lib/artifact_verdict.sh`), the one final check before any removal; prints `remove` or `kept:<reason>`, fail closed. Registered linked worktree: `wrh_removal_verdict` (clean incl. untracked, hidden state, ignored secrets, non-rebuildable ignored data, live cwd, AO, HEAD pushed) plus the branch `wrh_remove_now` would delete must be contained in a remote ref. Standalone git repo (a clone, including one nested anywhere inside a scratch dir): the same status/hidden/ignored checks and `git rev-list --all --not --remotes` empty (covers local branches, tags and stash). Non-git scratch: no live cwd (`wrh_live_cwd_reason`) and no open file inside (lsof), content mtime older than 60 min, and no lease of kind `evidence` without `published`. Every kind: not protected (`safety_check.sh`), and an owner state of `unknown`/`unreadable` keeps it | `wrh_removal_verdict`, `has_ignored_user_data`, `scratch_budget.sh` | RC1 |

Class table (pilot defaults; actuators unchanged except that each removal site calls C14):

| Class | Root(s) | Control measure | Accounting measure | Trigger | Actuator | Act |
|---|---|---|---|---|---|---|
| worktrees | `~/.worktrees/*/*` | du (round-robin) | same | overage | `worktree_reap.sh` (T1); `cleanup_worktrees.sh --clean` (T3) | nominate until D1; T3 until D1b |
| tmp_containers | `/private/tmp/<repo>/*` | du | same | overage | `cleanup_tmp.sh --clean` (as changed by #152) | always (runs unattended today) |
| tmpdir_scratch | `$TMPDIR` | df_delta_only | daily du | zone | `tmp_scratch_sweep.sh` | always |
| codex_documents | `~/Documents/Codex` | df_delta_only | daily du | zone | `diskm cleanup-codex-documents --clean` (#151) | always, once #151 is deployed |
| claude_codex_state | `~/.claude/state`, `~/.codex` minus never-delete | du | same | overage | `cleanup_codex_db.sh` (always); `cleanup_claude_state.sh` (decision `claude_state_cleanup`) | split as shown |
| colima | `~/.colima/_lima` | observer | same | overage | `cleanup_colima.sh` (fstrim; #150 guard) | always |

### 7.3 Reclaim tiers (C9)

Every tier requires C14 = `remove`, evaluated immediately before the removal call, then not locked, not under an AO worktree dir, byte-verified removal.

| Tier | Additional condition | Needs |
|---|---|---|
| T1 | `lease_owner_state` = `dead` (no process with that pid, or a process whose start epoch differs: pid reuse) or `released` per C8; 30 min quiet measured; HEAD on origin (live `git ls-remote` equal) or merged | D1, after the `CLAUDE.md` amendment is merged |
| T3 | The existing 3-day rule in `cleanup_worktrees.sh` (merged or HEAD-on-origin, hidden-state, AO and live-cwd gates), run under the governor; a lease whose owner is `alive`/`unknown` vetoes it | D1b |
| parked | Anything else, including owner-null worktrees younger than 3 days and leases whose TTL expired while the owner is alive | listed only (D7) |

**TTL only reports.** A lease past its TTL with a live owner (including a suspended `SIGSTOP` process) shows as `expired_owner_alive` in `parked` and status; it is never a removal condition. `unknown` (ps failure) and `unreadable` mean alive.

**Owner-null is an explicit, already-sanctioned exception.** "Unknown owner = keep" covers leases we cannot evaluate. A worktree with no lease at all becomes removable only by T3, the 3-day rule `CLAUDE.md` already sanctions for `cleanup_worktrees.sh`; T3 now also passes C14. The owner-null 24 h tier (T2) stays dropped.

**T1 is a policy change and is sequenced after it.** `CLAUDE.md` names `cleanup_worktrees.sh` as the sole exception to the 7-day floor. The `CLAUDE.md` amendment quoting D1 merges, and C14 is deployed, before `worktree_reap.sh` runs in remove mode for the first time. Stage 0 no longer reaps.

### 7.4 Budget model and pilot week

Arithmetic (all GiB): usable `U = 895`; base outside governed classes `B ≈ 715` (assumption); pilot class budgets sum `S = 108` (35 + 15 + 10 + 3 + 15 + 30); minimum-free target `F = 30` (BLACK boundary).

- Budgets must satisfy `B + S + W ≤ U − F`, where `W` is ungoverned intraday swing. With the pilot values, `W ≤ 42`.
- At the caps with no ungoverned swing, used is 823 and free is 72 (ORANGE). With typical governed stock (about 41), free is about 139 (GREEN).
- The inequality sizes budgets; it is not the safety guarantee. The guarantee is the stage-independent BLACK/FLOOR response (§7.1): admitted work stops at 30 GiB projected free and everything stops at 15.

**Pilot start condition.** The pilot begins only when admission with reservations (C2), `wtn_admit`, the hook (C6), `/advice` and evidence-producer admission, and the birth audit (C7) are deployed and each has a scheduled receipt. Otherwise births it should measure are invisible.

**Pilot week.** Govern runs 7 days in observe mode (emergency rows active per D2). Every term has a source: per-class used from du/observer, and for `df_delta_only` classes the daily du carried forward (samples where any class value is older than 26 h are excluded from `B`, and the exclusion count is reported); `B = used − Σ class used` per observer sample; APFS purgeable space and local snapshots are inside `B` and named as such. `W` = the **maximum** intraday swing of `B` observed over the pilot × 1.25, never a percentile. D3 records budgets satisfying the inequality with that `W`; if they cannot, D3 lowers class budgets first. Enforcement may not pass `warn` before D3.

### 7.5 Coverage: prevention first, detection second

| Producer | Prevention point | Lands before pilot |
|---|---|---|
| `diskm worktree-new` | `wtn_admit` → `diskm admit` | yes |
| `diskm scratch-new` | admit before create | yes |
| Agent shell `git worktree add` / `git clone` / `cp -R` | PreToolUse hook (C6) | yes |
| `/advice` clones in `$TMPDIR` | `run_primary_pair.py` admits once per run (`--est-gb` = 2 × source checkout size) | yes |
| Evidence bundles under `/private/tmp/<repo>/evidence` | evidence capture entry points admit (`tmp_containers`) | yes |
| CI jobs | ezgha pre-job hook (C13) | no (after act mode) |
| Anything else (subshells, `eval`, scripts, apps) | none: birth audit detects | n/a |

SLO over each pilot day and each week after: bypass births < 10% of births **and** bypass bytes < 10% of adopted plus admitted bytes (`bytes_unknown` counts as bypass). D3 cannot be recorded, and the loop is not called closed, while the SLO fails; the top bypass roots become the next prevention points.

## 8. Assumptions and recommended defaults (auto-picked)

| Question | Auto-picked default | Rationale |
|---|---|---|
| Setpoints | GREEN ≥ 100, ORANGE 60–100, RED 30–60, BLACK 15–30, FLOOR < 15 GiB | Matches `F = 30`; floor is the bypass-burst margin |
| Admission input | `projected = df_free − reserved − est`, under `fcntl.flock` | Concurrent requests cannot oversubscribe |
| Reservation lifetime | Until caller release; else 30 min TTL (max 240) or owner pid dead | Covers creation, not lifetime stock |
| Emergency rows | BLACK → 76, FLOOR → 75, every stage, once D2 recorded; BLACK tick kickstarts pressure-sweep | Bounds bypass to one tick + floor |
| Class budgets (GiB, pilot) | worktrees 35, tmp_containers 15, tmpdir_scratch 10, codex_documents 3, claude_codex_state 15, colima 30 (sum 108) | Satisfies §7.4 with `W ≤ 42`; validated in the pilot |
| Zone source | Live df on every tick and every admit | Admission cannot go blind on du |
| Class measurement | One du class per tick (60 s); daily du (120 s) for `df_delta_only` accounting; Colima from observer | du stalls past 60 s on this host |
| `W` | Max observed pilot swing × 1.25 | Percentiles are not a bound |
| Admission when df fails or rc unknown | Fail open + `admission_blind` receipt + alert | Never block all work on a measurement bug |
| Tick cadence and slices | 10 min, 540 s budget, slice `min(300, remaining/left)`, floor 60 s, rotation by oldest run | No actuator starves another |
| Owner liveness | pid + `start_epoch`; TTL and quiet only report | TTL cannot prove death |
| Final check | `artifact_removal_verdict` before every removal | One contract for all artifact kinds |
| Act mode | Per class; only worktree removal is decision-gated | Today's unattended actuators keep running |
| main_sweeper / pressure-sweep | Unchanged and installed | Snapshot ledger and all tiers keep running |
| `/advice` | Keep isolated `clone --no-local` + `rmtree`; admit once per run; `$TMPDIR` governed | Isolation is deliberate |
| Owner-null worktrees | T3 3-day rule only (no T2) | Already sanctioned |
| Reuse | Pending-lease claim, C14, idle 2 h; old branch deleted with `-d` only if merged or pushed, else no recycle | Recycling must not lose a branch |
| Decision provenance | Phrase verified in a user message of the named transcript; procedural, not a boundary | Honest about what a local file can prove |
| Decision expiry | None (revocable) | Expiry silently returns to nominate mode |
| Parked items | List daily, never delete | Unpushed or dirty work is user data |
| Enforcement rollout | observe 7 d (pilot) → warn → `refuse_red` after D3 → `refuse_orange` 7 d later; emergency rows from D2 | Day-one refusal at RED would block all work |

## 9. Success metrics

Measured from `disk_observer.jsonl` (df only); the snapshot ledger only at coverage ≥ 70%. A weekly window counts only if the observer has at least 95% of its expected samples; otherwise the check reports `insufficient_data` and does not pass.

| Metric | Today | Target after 7 days of T1 + T3 remove mode |
|---|---|---|
| 7-day minimum of df free | about 0.3 GiB | ≥ 30 GiB |
| Samples with free < 15 GiB per week | 605+ | 0 |
| Daily used trough (7-day max of daily minimums) | 839 GiB and rising | ≤ 790 GiB (free ≥ 105), not rising |
| Receipts for `govern_*` with non-null `df_delta_bytes` | n/a | 100% |
| Bypass births and bypass bytes | unmeasured | each < 10% |
| Govern ticks older than 30 min | n/a | 0 alerts per week |

`diskm budget status --weekly-check` evaluates exactly these six rows over the trailing 7 × 24 h window ending at the check time and exits 0 only if all pass. The workstream bead closes after **two consecutive** passing weekly checks. Stretch target, not a closure criterion: 7-day minimum free ≥ 60 GiB after D3 is re-tuned with two weeks of data.

## 10. Implementation preconditions (user decisions)

| ID | Decision | Recommended default | Blocks |
|---|---|---|---|
| D1 | Owner-exit removal (T1) exception to the 7-day floor, wording as in §7.3 / bead `7u9t`; the `CLAUDE.md` amendment merges before the first T1 removal | **Approve** | T1 remove mode |
| D1b | Run the existing 3-day `cleanup_worktrees.sh --clean` unattended (T3), behind C14 | **Approve** | T3 under govern and main_sweeper |
| D2 | Admission enforcement via `wtn_admit`, the hook, `/advice`, evidence producers | **Emergency rows at once; other rows phased** per §8 | All refusals |
| D3 | Budget numbers from the pilot week, satisfying §7.4 with the measured `W` and the §7.5 SLO | Record after pilot | enforcement beyond `warn` |
| D4 | CI backpressure | **Alert + pause command, no auto-pause** | C13 auto-pause |
| D5 | Push on exit (normal push only) | **Approve** | C8 skill contract |
| D6 | Edits outside this repo: hook install, `/advice` admit call, evidence-producer admit call, gate producers, skill text, AGENTS.md, SessionEnd hook | **Approve** | C2 callers, C4, C6, C8 |
| D7 | Parked set | **List daily, never delete** | none |
| D8 | Colima self-heal (clear stale lima lock, restart when stopped > 30 min with no lima process) | **Approve** | C12 auto-heal (alert ships regardless) |
| — | `claude_state_cleanup` decision for `cleanup_claude_state.sh` | Ask separately | claude-state actuator only |

A decision counts only when recorded through `diskm policy approve` with the user's literal phrase, written after the user said it, verified against the transcript (C11). A bead comment or an agent report is not a decision.

## 11. Risks

- **A bug makes df fail and admission fails open.** Mitigation: `admission_blind` alert on the first occurrence; the tick's BLACK/FLOOR response does not depend on admission.
- **A bypassing producer writes faster than one tick of reclaim.** Mitigation: the 15 GiB floor margin, `bypass_high` alert naming the root, and that root becomes a prevention point.
- **Estimates are wrong.** A low `--est-gb` under-reserves. Mitigation: reservations are short; df catches the real bytes on the next admit; receipts compare est to the class's df delta in the pilot.
- **The base `B` is larger than assumed.** Mitigation: the pilot measures it; D3 lowers budgets first.
- **Governor and existing jobs run the same actuator.** Mitigation: the actuator's own lock; the loser records `skipped_lock`.
- **Reuse hands an idle agent's worktree to a new owner.** Mitigation: pending-lease claim, owner `dead`/`released` by pid + start epoch, C14, branch kept unless merged or pushed.
- **Crashed `/advice` clones have no remote** (the runner removes origin). C14 handles them with a disposable-copy rule. A clone under an `advice-primary-pair-*` root whose runner `receipt.json` records the source repo and resolved SHA is removable when all of the following hold: no runner process is alive (pid plus start epoch from the receipt), it is ≥ 2h idle, and C14's other checks pass. The other checks are no live cwd or open files, and no ignored secrets beyond the runner's own `.advice-review-documents/` overlay. The clone also needs no commit, tag or stash outside the recorded source SHA (`rev-list --all --not <sha>` empty). Everything in it then already exists in the source repo, so nothing unique is lost. A missing or unreadable receipt gives `kept:check-failed`.
- **Detached scratch shares the object store with the main repo.** Mitigation: C4 is limited to producers that run no agent in the checkout; `git worktree add` registers HEAD as a reachability root; `scripts/set_gc_worktree_prune.sh` governs prune expiry.
- **The disk is too full to write state.** Mitigation: writes under 64 KiB, atomic replace keeps the previous file on ENOSPC, and the plan's stress test runs a tick at about 5 GiB free and on a full image.
