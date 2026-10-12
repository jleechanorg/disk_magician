# Disk-fill durable control: diskm budget governor with owner-lifecycle leases

- **Date:** 2026-10-11 (revision 8, 2026-10-12: closes `/web-advice` round 6. Gemini approved rounds 2–6; ChatGPT and Perplexity accepted the v1 scope (ledger deferred, best-effort admission under a hard floor) and raised narrower blockers; Opus `/advice` and `/secondo` approved round 1)
- **Status:** Design, auto-approved under `/superpowers-quick`. Budget numbers are **pilot values** until the pilot week (§7.4) validates them.
- **Base:** origin/main `7837d36` (v0.2.198; #153 merged 2026-10-12T00:35Z)
- **Related code on main (PR #148, merged 2026-10-11T13:01Z):** `scripts/lib/worktree_lease.sh` (`lease_owner_state`: pid + `start_epoch` from `ps -o lstart`), `scripts/worktree_reap.sh` (nominate/remove, `adopt`, `verdict_for`), `scripts/worktree_new.sh` (`wtn_admit`), `scripts/worktree_remove_hook.sh` (`wrh_removal_verdict` / `wrh_remove_now` / `wrh_live_cwd_reason`), `scripts/lib/worktree_merged_pr.sh`, `launchd/com.jleechanorg.disk-magician-worktree-reap.plist.template`. The owner-exit rule text lives in bead `7u9t`'s first comment.
- **Open PRs this depends on:** #150 (Colima stopped-VM guard, stale lima lock), #151 (`diskm cleanup-codex-documents`), #152 (`cleanup_tmp.sh` descends into active tmp containers under `--large`). #151 and #152 add or widen unattended delete paths, so each merges only after C14 (plan Task 11) with C14 called in its new delete path. #153 (shared rebuildable-ignored allowlist, `scripts/lib/worktree_ignored.sh`) is merged.
- **Beads:** `7u9t`, `oyt4`, `67xj`, `d45`, `i2o`, `4y6`.
- **Plan:** `docs/superpowers/plans/2026-10-11-disk-fill-durable-control.md`

**Revision 8 changes (round 6).** `advice_own_copy_ok` runs C14's repository content checks before its `rmtree`. A manifest proves only "unchanged"; non-git content is disposable only when a published remote copy was verified present at publish time. Quarantine deletion is two-phase with the rename as commit point and a resumable, inventory-checked delete. The D1 marker is read after a bounded `git fetch origin main`. Estimates are frozen per pilot epoch (calibration goes to a pending file). CI admission carries job id + workspace and stays out of the filesystem births SLO. C14 runs in shadow on existing sweeper paths until each class's shadow data allows enforcement. One absolute tick deadline drives every phase; zone and emergency come before reconciliation. The unpushed-commit check for a linked worktree is scoped to the candidate's own refs and reflogs.

History: r7 added upload manifests, the `/advice` guard, per-call marker recheck, pilot epochs, cooperative stop and identity-checked quarantine; r6 dropped the reservation ledger (§12) and required positive provenance for all non-git content; r5 bound reservations to writer process groups; r4 added `removal_activation_ok` and pilot validity rules.

## 1. Why

At the time of writing, `df` shows **7.2 GiB free** (21:10Z) and 33.4 GiB free (22:10Z). The data volume's usable capacity is **about 895 GiB** (`df` used + available; the 926 GiB container size includes about 31 GiB held by other APFS volumes). The user has asked "stop the disk constantly filling" on 09-23, 10-03, 10-04, 10-05, 10-06, 10-08, 10-09, 10-10 and 10-11. In 30 days the repo produced five designs and about 80 merged PRs (#67–#149). None lowered the used-space trough.

### 1.1 30-day retrospective: what the data shows

All figures are from `~/.disk_magician_state/disk_observer.jsonl{,.1,.2}`: 12,878 df-only samples covering 10-02 to 10-11.

Daily min / max used (GiB): 10-03 754/885, 10-04 759/881, 10-05 838/875, 10-06 798/888, 10-07 763/836–851, 10-08 826/895, 10-09 805/894, 10-10 831/885, 10-11 839/893.

Free space was below 8 GiB in **605 of 12,878 samples**, on 8 of the 10 days. The daily trough rose from 754 to 839 GiB in a week. Intraday swings were 54–131 GiB. Four reclaim events gave back about 40–63 GiB each and refilled within hours to about 2 days (median refill half-life about 1 hour; about 2 hours for drops of 38 GiB or more).

### 1.2 Verified root causes (survived adversarial refutation)

**RC1: open loop. Nothing limits creation, so standing stock = creation rate × retention.**

- **Births** under `~/.worktrees`: 40, 49, 41, 61 and 35 per day for 10-07 to 10-11 (confirmed by three verifiers).
- **Surviving stock:** about 17–38 GiB/day of worktrees born that day are still on disk.
- **Producer-side PRs:** only #107 (standard root, no teardown) and #148 (lease + admission gate, live in nominate mode). Every other PR improved a sweeper.
- **Retention** is set by the 3-day `cleanup_worktrees.sh` floor and the 7-day general floor, and `cleanup_worktrees.sh` itself only runs with `WORKTREE_APPROVED=1`, which no plist sets (`main_sweeper.sh:389`).
- **Unverified model inputs:** the /private/tmp rate (about 21 GiB/day) and the 45–50 GiB/day producer total.

**RC8: symptom and metric. The volume runs 91–97% full, so swings are as large as the headroom.**

`pressure_sweep.sh` acts only below 40 GiB free with a fixed three-step list, so it holds the disk near 40 GiB instead of creating margin. A stopped Colima VM (stale lima lock since 10-08, bead `67xj`) could not fstrim, and nothing alerted. Adopted actions: alert on a rising trough and on a dead actuator; measure success by the df trough and minimum, never by "GiB reclaimed".

### 1.3 Refuted or demoted claims (kept as constraints)

| Claim | Verdict | What survives |
|---|---|---|
| RC2: age floors alone set the equilibrium | Refuted (about 53 GiB inside the floors; refill in hours) | Owner-exit release (T1) for provably safe items only |
| RC3: agents cannot tear down | Refuted as stated; the remove hook keeps dirty/unpushed/ignored/<7 d items | Session-exit release (C8). `protect-worktrees.sh` is **not** loosened |
| RC4: receipts report success from exit code | Refuted; the gap is null `df_delta` on main_sweeper, pressure_sweep, tmp_scratch_sweep | `df_delta_bytes` on governor receipts (C10); liveness alerts (C12) |
| RC5: no plist sets any approval | Refuted; four plists do. Worktree removal and claude-state remain permanent dry-runs | Standing-decision record (C11) for exactly those gates |
| RC6: measurement crowded out producer work | Refuted (~25% of PRs) | Count df_delta only, never du |
| RC7: 7-day deploy lag; RC9: no closure criterion | Refuted (19 installed versions 10-07..10-11); RC9 refuted as a byte cause | Bead closes on two consecutive weekly checks (§9) |

### 1.4 What failed in the 30-day record

About 78 PRs added or fixed sweepers; each reclaim lasted hours; approval env vars (`WORKTREE_APPROVED`, `CLAUDE_STATE_APPROVED`) that no scheduled job sets; 30–60 minute control cadence against a 1–2 hour refill half-life; one 600 s step timeout blocked every later step; "Installed" trusted as "running" (fleet flapping, plutil corruption, Colima down 3 days, main_sweeper erroring 64/64); du counted as reclaim (`code_sign_clone` reported 104 GiB; deleting it freed about 0 on APFS).

## 2. Goals

1. Close the loop at creation. Every governed producer calls `diskm admit` before writing; admission decides on projected free (fresh `df` free minus the request, less a concurrency margin), plus per-class byte budgets where a class can be measured reliably. v1 admission is **best-effort**: it holds no reservation, so it has no finite bound on bytes written by producers it already admitted (§7.1).
2. Bound what admission cannot see. Producers outside admission are detected by the birth audit; admitted births are counted from the admission event log. BLACK/FLOOR refusal stops new governed writes; it is a best-effort backstop, not a guaranteed floor (§7.6).
3. Shorten retention where it is provably safe and already sanctioned: owner-exit release (D1) and the existing 3-day `cleanup_worktrees.sh` rule, each behind one final per-artifact check that requires positive provenance.
4. Make the controller observe itself. A dead actuator, blind admission, a stale tick, a starved actuator, material bypass or a rising trough is the first line of `diskm status`.
5. Measure success by df: the 7-day minimum free, samples under 15 GiB free, and the daily used trough.

## 3. Non-goals

- Replacing existing actuators or schedules. `main_sweeper` (including `snapshot_commit.sh`, every tier and the health phase) and `pressure-sweep` **stay installed and unchanged**. Revisit after 14 days of governor receipts.
- A reservation ledger in v1 (deferred, §12).
- Moving `/advice` reviewer copies to linked worktrees (dropped, §6).
- Full attribution (bead `4y6`); reducing `~/.codex/sessions*` or `~/.claude/projects` (never-delete); Linux portability beyond what scripts already support.

## 4. Anti-goals (must not happen)

- Another sweeper tier, or a "GiB reclaimed" report without `df_delta_bytes`.
- Approval gates no scheduled job can satisfy; expiring standing decisions.
- A deletion justified by age or location alone, a new deletion rule not named in a recorded decision and in `CLAUDE.md`, or any removal that skips `artifact_removal_verdict` (sole exclusion: the guarded `/advice` own-copy teardown, §11).
- Admission that goes blind because du is slow, or a claim that v1 admission prevents concurrent oversubscription (it does not; §7.1).
- Claiming the loop is closed while bypass births exceed the §7.5 SLO.
- Treating lease TTL expiry, quiet time or a session-end event as proof that an owner is dead.
- Loosening `~/.claude/hooks/protect-worktrees.sh`, or giving agents removal authority.
- Recency proxies, ad-hoc cleanup scripts, never-delete paths, keyword/heuristic classification (classes come from a fixed governed-root table; the hook does literal syntax matching).
- Auto-pausing CI runners without D4.

## 5. Constraints

- **One entry point.** New `diskm` subcommands in `src/disk_magician/disk_magician.sh` and `disk_magician.sh`, synced by `scripts/sync_package_tree.sh`.
- **One removal gate.** Every removal first calls `artifact_removal_verdict` (C14) immediately before the destructive call; existing sweeper paths run it in `shadow` until enforced per class (§7.2), new paths enforce (sole exclusion: `/advice` deleting its own copy behind C14's content checks, §11). Worktrees are then removed by `wrh_remove_now` (byte-verified, #120) in quarantine mode; non-git roots by `quarantine_remove` (two-phase, C14).
- **Recency** only through `scripts/lib/worktree_recency.sh`, fail closed. **Owner liveness** only through `lease_owner_state` (pid + `start_epoch`); `unknown`/`unreadable` = alive = keep.
- **Locks.** `govern.lock` (one tick at a time; an overlapping tick exits `skipped_tick_lock`). `state.lock`, one `fcntl.flock` (Python; macOS has no `flock(1)`) taken by **every** writer of `budget.json` and `admission/events.jsonl`: each `diskm admit` decision, the tick's and the daily job's read-merge-replace, and event-log rotation. Each holder rereads current state inside the lock and never holds it across du, `git fetch` or an actuator. Actuators keep their own locks; a held lock yields `skipped_lock`, never a wait.
- **Timeouts** via Python `subprocess` timeouts (no `timeout(1)` on macOS).
- **Deploy.** Version bump, `tools/deploy_uv_tool.sh` from clean origin/main, verify `deployed.json` plus a scheduled receipt.
- **PR size.** At most 150 production lines per PR, or the size-tiered gate.
- **Disk-full operation.** The tick and admission work at about 5 GiB free: state writes are atomic and under 64 KiB, a failed write keeps the previous file, an event-log append failure is recorded as `admission_degraded:log` and never changes the decision. Admission never runs du.

## 6. Approaches considered

1. **Budget governor (winner):** free-space zone + per-class budgets, `diskm admit` on projected free, 10-minute `govern` tick, df-verified receipts. Closes the loop; does not on its own shorten retention.
2. **Lifecycle-first:** leases on every kind, detached worktrees, session-exit release. Smaller footprint, but no setpoint.
3. **Policy and decisions:** decision record, parked set, trough alerts, 90-day expiry. Expiry rebuilds the babysitting.

**Chosen:** design 1, with grafts: leases on every kind (C3), session-exit release (C8), detached scratch for producers that need no isolation (C4, narrowed); the decision record (C11), the parked set and trough alerts. The 90-day expiry is dropped.

**Dropped after review:** converting `/advice` (`run_primary_pair.py`) to linked worktrees. It deliberately uses `git clone --no-local` with `origin` removed so full-permission reviewers cannot touch the user's refs, config, hooks or stash, and `shutil.rmtree`s each clone at the end behind `advice_own_copy_ok` (§11). Advice is governed by admission instead (C2, C7). **Dropped in r6:** the reservation ledger (§12).

## 7. Chosen design

### 7.1 Control model

```
projected   = df_free - est                                  # fresh df on every admit call
admit zone  = zone(projected - margin)                       # margin = concurrency_margin_gb, pilot default 10
tick zone   = zone(df_free)
zone(x)     = GREEN (>=100) | ORANGE (60..100) | RED (30..60) | BLACK (15..30) | FLOOR (<15)
class overage = class used_gb - budget_gb                    # only for classes with a fresh measurement
```

**Admission (C2).** `diskm admit --class C --est-gb N [--producer K] [--dest P] [--source S]` takes `state.lock`, reads `df` (5 s timeout), decides by the plan's policy table, appends one line to `admission/events.jsonl` (`admit_id, at, class, producer, source, est_bytes, dest, ci_job, decision, df_free_bytes`), and releases the lock. The lock orders decisions and the log; it does **not** account for admitted bytes that have not landed yet. **Honest limit: v1 admission is best-effort.** Callers admitted close together each see about the same `df`, and an admitted writer (a CI job, a long clone) keeps writing after its admission, so v1 has **no finite bound** on bytes from writers already admitted; an under-estimate adds to it. Three things limit, not bound, it: the margin; the **hard floor** (`projected < 15 GiB` → 75 for every governed class in every stage once D2 is recorded), which stops only *new* governed writes; and the BLACK response below. The pilot reports `admit_burst_bytes` = max Σ `est_bytes` admitted (0/10) in any 600 s window as a diagnostic only. Progress is gated on what df shows: D3 requires zero observer samples under 15 GiB free in a valid pilot (§7.4), whatever the margin was. The margin is a pilot epoch parameter: a change (`diskm budget set-margin`, recorded) starts a new pilot, and two consecutive valid epochs that breach the floor trigger §12 without waiting for D3.

**Exit-code channel.** `diskm admit` never runs a command: its rc is the decision alone (0 admit, 10 warn and proceed, 75 refuse, 76 queue with `retry_after_s`). A caller runs its command only after admit returns. A caller exits with its reserved code 75 only when admission refused and the command never started, and prints `disk-admission: refused class=<C> rc=<75|76>` on stderr first; every other caller exit is the command's own. A 76 retry happens once, only before the command has started.

**Emergency rows are stage-independent once D2 is recorded.** Admission zone FLOOR → 75, BLACK → 76 (`retry_after_s=600`) in every stage. Callers retry once after `retry_after_s`, then stop. A tick whose df zone is BLACK or FLOOR runs zone-trigger actuators first and, **only when C14 is active and in `enforce` mode on every pressure-sweep delete path** (`artifact_removal_verdict --self-test` passes from the deployed tree), kickstarts the existing pressure-sweep job (`launchctl kickstart gui/$UID/com.jleechanorg.disk-magician-pressure-sweep`; its own lock prevents overlap). Before that the tick records `kickstart_blocked:c14_missing` (or `:c14_shadow`) and pressure-sweep keeps its own unchanged schedule; the governor adds no destructive triggering before C14. BLACK/FLOOR refuses **new** governed writes only.

**Each 10-minute `diskm govern` tick**, under `govern.lock`, has **one absolute monotonic deadline** `D = start + 540 s`; every phase's budget is derived from `D − now`. In order: (1) reads df and writes the tick zone to `budget.json` (under `state.lock`) before anything else, handling BLACK/FLOOR as above (`floor_breach`, kickstart); (2) quarantine reconciliation (C14) with budget `min(120 s, D − now − 300 s)` and a resumable cursor: unfinished sidecars stay quarantined for the next tick, and a timeout never authorizes deletion; (3) measures **one** du class (round-robin, about hourly each, 60 s timeout, outside `state.lock`; on timeout the prior value stays and `stale_s` grows; skipped as `skipped_measure_lock` while the daily job holds `measure.lock`); (4) reads Colima from the observer's `colima.root_allocated_kb`; (5) runs the birth audit (C7, at most 120 s of du per tick); (6) runs act-mode actuators through the scheduler (C10) in the time left; (7) writes one receipt per actuator with `free_bytes_before`, `free_bytes_after` and `df_delta_bytes`.

**Daily measurement is its own job.** `diskm govern --daily-measure` (launchd, 03:00 local, `measure.lock`, 900 s) measures every du class (60 s) and every `df_delta_only` class (120 s, accounting only), carrying prior values forward on timeout and marking them `carried`. It merges into `budget.json` by rereading the file inside `state.lock`, so neither it nor the tick can overwrite the other's fields.

**Admission never goes blind on du; df failure is a recorded degraded mode.** `diskm admit` reads only class overage from `budget.json`; a class measurement older than 3 h drops that class's overage term. If `df` fails, admit decides on the last tick's `free_bytes` when ≤ 15 min old (`admission_degraded:stale_df`); otherwise it returns 10, never 0, and logs `admission_degraded:blind` with an alert, unless the last zone within 60 min was BLACK/FLOOR, in which case it refuses per the emergency rows. A caller that cannot run `diskm admit` or gets any other rc proceeds, logs `admission_degraded:caller` and prints one warning line. Degraded admissions count as bypass (§7.5).

**APFS copy-on-write.** A class whose du is unreliable is `measure: df_delta_only`: no overage term, `trigger: zone`, effect judged by receipt `df_delta_bytes`. Pilot default: `codex_documents`, `tmpdir_scratch`; the pilot moves any class whose du-reported reduction disagrees with the df delta by more than 50% on 3 or more runs.

### 7.2 Components

| # | Component | Reuses | Closes |
|---|---|---|---|
| C1 | **Budget config and `diskm budget status`.** `budgets` block in `config.json.template` / `safety.local.json`: per class `budget_gb`, `measure` (`du`, `observer`, `df_delta_only`), `trigger` (`overage`, `zone`), `act` (`always` or a decision id); `concurrency_margin_gb`. Shell reader `scripts/lib/disk_budget.sh`, Python twin `scripts/disk_budget.py`. `budget.json`: zone, `zone_at`, per-class `used_gb`/`budget_gb`/`measured_at`/`stale_s`, birth counts, `bypass`, `parked`. A stale value shows its age, never 0 | `resolve_config.py`, `scripts/lib/scratch_roots.sh` | RC8, RC1 |
| C2 | **`diskm admit`** per §7.1: decision only, one event line per call, `--dry-run` decides without logging a birth, `--probe` writes an `emergency_probe` receipt. **Estimates per producer:** the effective `admission/estimates.json` holds `est = max(default, 1.25 × p95` of the last 20 measured births) per producer key (`hook:git-clone:<remote>`, `hook:git-worktree-add:<repo>`, `hook:cp-R`, `worktree-new:<repo>`, `advice`, `ci`); measured births come from the birth audit's du of the admitted `dest`. Calibration writes only `estimates.pending.json`; the effective file changes only through `diskm budget promote-estimates` (recorded with its sha256 in `budget.json`), which starts a new pilot epoch when a pilot is active, so estimates are frozen within an epoch. `cp -R` also takes a bounded 5 s `du -sk` of the source when larger. `wtn_admit` delegates | `wtn_free_gb` | RC1 (rate) |
| C3 | **Lease every artifact kind.** Optional `kind` (worktree, clone, scratch, evidence) on leases, plus `producer` and `source` (git URL + SHA, published evidence URL, or a rebuildable-cache declaration) and an optional content manifest (path + sha256, or one tree hash). `diskm scratch-new <repo> <purpose> [--kind K] [--detach <sha>]` creates `~/.worktrees/<repo>/scratch-<purpose>-<ts>` after admit. `evidence-push` writes the **upload manifest** (relative path, sha256 and size of every file, hashed from the bytes it sent), then verifies the remote copy with one bounded (10 s) metadata read of the uploaded object (`gcloud storage objects describe` for GCS, `gh api gists/<id>` for a gist), and only on success marks the lease `published` with the URL/object name, generation or revision, and `verified_at`. A content manifest alone is an inventory: it proves content is unchanged, not that a copy exists | `worktree_lease.sh`, `worktree_new.sh`, `evidence_push.sh` | RC1 |
| C4 | **Narrow producer conversion.** Only producers that run no full-permission agent in the checkout, whose clones survive the run (C7 counts) and that write outputs outside the checkout move to `scratch-new --detach`. Candidates: gate-prep, split-gates. Excluded: `/advice` | `findings_wiki/2026-09-23-verifier-lanes-should-use-worktrees-not-clones.md` | RC1 |
| C5 | **Reuse first in `worktree-new`.** Claim a candidate with `lease_write_pending` (single owner); require C14 = `remove`, same repo, owner `dead`/`released`, idle ≥ 2 h measured. Record the old branch tip `T`; continue only if `git merge-base --is-ancestor T origin/main` or `T` equals the live `git ls-remote` tip. `git switch --detach` (same commit, no file change), then `git update-ref -d refs/heads/<old> T`: the delete is conditional on the ref still being `T`, so a branch that moved is kept. The pending lease records `<old>` and `T` before the detach. On any failure: if `<old>` was deleted, recreate it create-only (`git update-ref refs/heads/<old> T 0000…`, which fails if the name was recreated meanwhile); `git switch <old>`; restore the claim; create fresh. If that recovery fails, the candidate becomes `reuse_incomplete` (parked, not claimable) and alerts. Then `git switch -c <branch> <base>`; lease transferred; no `git clean` | lease lib, C14 | RC1 |
| C6 | **Admission hook (prevention for agent shells).** `hooks/disk-admission.sh` (PreToolUse Bash). Splits on `&&`, `;`, `\|\|`, `\|`; strips leading `VAR=value`; tracks `cd <dir>` and `git -C <dir>`; recognises `git worktree add <path>`, `git clone … <dest>`, `cp -R … <dest>` with a destination under a governed root, and calls `diskm admit --source hook` for each. 0/10 → **no permission decision** (the normal permission flow continues; 10 adds a `systemMessage`) and never `updatedInput`, so the command runs exactly as written with every Bash field (`description`, `timeout`, `run_in_background`, unknown fields) untouched and admission never auto-approves a command. 75/76 → `hookSpecificOutput.permissionDecision: "deny"` with the reuse or `retry_after_s` reason. Always exit 0 with JSON (a bare non-zero exit is a non-blocking error to Claude Code). Segments containing a newline, heredoc, `$(`, backticks, `eval` or a subshell are not parsed: the hook stays silent and counts `hook_unparsed`; those writes are covered only by detection (C7) | `diskm admit` | RC1 |
| C7 | **Birth audit and birth counting.** Admit events are **attempts** (each has an `admit_id`). A **birth** is one destination generation the audit sees: canonical `dest` (`realpath` of the parent + name) plus dev + inode at first sighting. It is admitted if a 0/10 attempt for that canonical `dest` was logged after the previous generation vanished and before this one was first seen; any number of attempts (hook plus producer, retries) count once; a recreation with no new attempt is a bypass birth; an attempt never sighted (failed command, stopped `&&` chain, tree gone within a tick) is `attempt_unconfirmed`, reported, never a birth. CI attempts are not filesystem births (below, C13). Each tick, every new unleased top-level entry under a governed root with no matching attempt is adopted with an owner-resolved lease and counted in `bypass{root}` births and bytes (du within the tick's 120 s audit budget, retried on the next 3 ticks). An unmeasured bypass entry is `bytes_unknown` and charged `max(class budget_gb, largest measured birth in that class this pilot)`; that value is documented as an **estimate**, not a bound. Adoption grants no removal authority. Governed roots: `/private/tmp/<repo>/*` (`/private/tmp/<repo>/evidence` is a container; its children are the entries), `$TMPDIR/*` (via `getconf DARWIN_USER_TEMP_DIR` when `TMPDIR` is unset), `~/Documents/Codex/<date>/*`, `~/.worktrees/*/*`. `$TMPDIR` entries not matching the fixed producer-prefix table (`advice-*`, `tmp*` clones with a `.git`) are `foreign`, counted, never adopted | `lease_resolve_owner`, `adopt` in `worktree_reap.sh` | RC1 |
| C8 | **Owner-lifecycle release.** SessionEnd/SubagentStop hook runs `diskm lease-release --owner-session $ID`; releases a lease only when `owner.session == $ID` and the owner pid is the ending runtime (same pid and `start_epoch`) or `dead`. Release deletes nothing. Skill contract: create through diskm, `git push -u origin HEAD` before exit (never force), publish evidence | `lease_release`, `lease_owner_state` | RC1 |
| C9 | **Ownership-ordered reclaim.** T1 and T3 (§7.3), each gated by C14 then `wrh_remove_now`. Everything else goes to `parked`, listed daily with sizes, never deleted | `worktree_reap.sh`, `cleanup_worktrees.sh` | RC1 |
| C10 | **`diskm govern` scheduler.** 10-minute tick, `govern.lock`, the tick's absolute deadline `D` (§7.1). Zone, reconciliation, measure and audit run first. At each dispatch `usable = D − now − 60` (60 s reserve for receipts) and `pending` = every eligible actuator not yet run this tick. Eligible actuators run serially, oldest `last_ran_at` first (BLACK: best 7-day df delta first, but one deferred 3 ticks goes first). If `usable < min_slice` the actuator is `deferred` and goes first next tick; else slice = `min(300, max(min_slice, usable / pending))`, where `min_slice = unit_budget + 40` and `unit_budget` is the class's longest unit (default 20 s; 100 s where C14 may run its 60 s fetch), so every slice's soft window fits one unit. **Stop is cooperative:** each actuator runs in its own session (`start_new_session=True`) with `--deadline-at <monotonic soft deadline, 40 s before slice end>` and `--cursor $STATE/cursor_<class>.json`, both parsed by every actuator through `scripts/lib/actuator_deadline.sh`, and starts no unit that cannot finish within `unit_budget` before the soft deadline. The cursor checkpoints enumeration (candidate list and next index, written after each chunk); an interrupted fetch, hash or verdict restarts, never resumes. A unit is one artifact: C14, then `quarantine_remove` (worktrees: `wrh_remove_now` in quarantine mode), crash-safe per C14. **Kill is a backstop:** SIGTERM to the group 10 s before slice end, SIGKILL at slice end, survivors `orphan_survivors`, `hard_stop` recorded; the interrupted unit is resumed by quarantine reconciliation (C14) at the next tick. `govern_sched.json` keeps per class `last_progress_at` (`df_delta_bytes > 0` or ≥ 1 removal) and `no_progress_ticks`: at 3, `reclaim_starved:<class>` and an exclusive 300 s slice next tick; at 6, the class's next-tier action (worktrees: parked top-10 in the alert; tmp_containers: `cleanup_tmp.sh --budget-gb`; colima: D8; others: alert only). Receipts carry `free_bytes_before/after`, `df_delta_bytes`, `removed_count`; a null delta is an error. Colima receipts add the guest `fstrim` bytes and `df_delta_bytes_lagged` (host df at the next tick), and colima progress uses the lagged value. `actuator_dead` = 3 non-positive deltas while over budget **and** zero removals | `job_receipt.py`, existing actuators | RC8 |
| C11 | **Standing-decision record.** `diskm policy approve <id> --phrase '<literal user text>' --from-transcript <session.jsonl>` writes `~/.config/disk-magician/standing_decisions.json` only if the phrase appears verbatim in a `type: user` message of that transcript **and** names the decision (`D<n>` or id); revocable, never expires. Procedural, not a security boundary. Recording activates nothing; removal uses `removal_activation_ok` (§7.3) | `safety_lib.sh` | RC5 |
| C12 | **Liveness and trough alerts** first in `diskm status` and `sweeper_health_check.sh`: govern tick > 30 min; `floor_breach`; `admission_degraded`; `activation_blocked`; `kickstart_blocked`; `quarantine_conflict`; `quarantine_partial_kept`; `exclusive_rename_unavailable`; `c14_shadow_keep_high`; `reuse_incomplete`; `hard_stop`; class stale > 3 h; `actuator_dead`; `actuator_starved`; `reclaim_starved`; `archive_overcap_kept`; `bypass_high`; `burst_over_margin` (`admit_burst_bytes` > margin); Colima stopped > 1 h; main_sweeper erroring twice running; 7-day trough > 15 GiB above the 30-day trough; parked > 20 GiB. "Healthy" means a recent valid receipt, not `launchctl list` | `check_launchd_fleet.sh`, `disk_observer.py` | RC8 |
| C13 | **CI backpressure.** The ezgha job-started hook (`scripts/ci_admit.sh`) calls `diskm admit --class colima --producer ci --source ci --ci-job <GITHUB_RUN_ID>.<GITHUB_RUN_ATTEMPT>.<GITHUB_JOB> --dest <GITHUB_WORKSPACE>`; every retry and duplicate hook call reuses that id, so a job counts once. A missing variable gives `ci-job unknown-<runner>-<ts>` plus `admission_degraded:ci_identity`, still counted. CI jobs are reported in a separate `ci_admission` metric (identified jobs admitted, refused, degraded); a CI event enters the births SLO only when its `--dest` is sighted by the audit under a governed host root, and then as that filesystem birth. 0/10 proceeds; 75 fails the job early with the admit message; 76 waits `retry_after_s` once, then fails. No completion hook: there is nothing to release. The governor prints a ready pause command in RED/BLACK; auto-pause needs D4 | `diskm admit` | RC8 |
| C14 | **`artifact_removal_verdict <path>`** (`scripts/lib/artifact_verdict.sh`), the one final check before any removal; prints `remove` or `kept:<reason>`, fail closed. It must **prove disposability**. See below | `wrh_removal_verdict`, `has_ignored_user_data`, `worktree_ignored.sh` | RC1 |

**C14 rules.**

- **Git content.** Before trusting remote-tracking refs, each repo runs one bounded `git fetch --prune` per remote per tick (`GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=/usr/bin/false`, 60 s timeout, result cached for the tick); failure or timeout → `kept:remote-unverified`. Then the commits the removal would destroy must all be on a remote, else `kept:not-pushed`. **Scope follows what is destroyed.** An independent repository (clone, nested repo, `/advice` copy) loses everything, so `git rev-list --all --reflog --not --remotes` must be empty (`--reflog` catches a commit kept only by a reflog after a reset or rebase; `--all` covers tags and `refs/stash`). A linked worktree loses only its own state, so the check is scoped to the candidate: `git rev-list <candidate HEAD> <its branch> $(git reflog show --format=%H <branch>) $(git -C <wt> reflog show --format=%H HEAD) <its refs/worktree/* and refs/bisect/*> --not --remotes` must be empty; other worktrees' commits and shared refs survive the removal and do not veto it. **Every** repository found (linked worktree, ordinary clone, nested repo, `/advice` copy) must show no staged or unstaged change to a tracked file or submodule (`git status --porcelain=v1 --untracked-files=all --ignore-submodules=none` has no line other than `??`/`!!`) and no index entry flagged assume-unchanged or skip-worktree (`git ls-files -v`), else `kept:dirty`; its untracked and ignored files go to the provenance rule below. A registered linked worktree also passes `wrh_removal_verdict` (clean incl. untracked, hidden state, ignored secrets, non-rebuildable ignored data, live cwd, AO, HEAD pushed by live `ls-remote`). Each nested repo under a non-worktree root (`find -name .git -prune`) gets the same checks.
- **All non-git content needs positive provenance**: every file outside git tracking (untracked, ignored, or in a non-git root) must be (a) listed, with matching sha256 and size, in the **upload manifest** of a published-evidence receipt whose remote copy was verified present at publish time (C3: URL/object, generation, `verified_at`). The manifest match proves the file is unchanged since publication; the verified publication is what makes it recoverable. A file added or changed after publication, a receipt without a manifest, or one without `verified_at` is unproven, and a lease or producer manifest without a verified publication proves nothing; or (b) an ignored path matching the shared rebuildable-ignored allowlist (`scripts/lib/worktree_ignored.sh`, #153), inside a repository that passed the git checks, with no secret-like file under it (the `wrh_removal_verdict` patterns). Anything else is `kept:unproven-content` and goes to `parked`, whatever its age, location or name. There is no age-only or location-only rule.
- **Every kind:** no live cwd, no open file, content mtime ≥ 60 min, not protected by `safety_check.sh`; a lease owner `alive`/`unknown`/`unreadable` keeps it unless the lease is `released` (C8). `os_clone` (code-sign clones) proves provenance by its existing frozen-identity match against the source app bundle plus its lsof recheck.
- **Quarantine: two-phase, crash-safe.** Non-worktree roots go through `quarantine_remove`; its sidecar `<root-parent>/.dm-quarantine/<id>.json` (original path, `lstat` device + inode, producer, lease/receipt id, `phase`) is fsynced before each phase change. **Phase 1, commit point:** `intent` is written, then the artifact is renamed into `.dm-quarantine/<id>` (atomic; only when `realpath` and `stat -f %d` show the same device, else `kept:cross-device`, never copy). The moved object's device + inode must equal the record (a path swapped before the rename fails here and is rolled back), then the verdict reruns with the recorded context plus current content and liveness. A `kept` result rolls back with `renamex_np(RENAME_EXCL)` only; a recreated original path or a missing exclusive call leaves it quarantined with `quarantine_conflict` / `exclusive_rename_unavailable` (never check-then-rename). **Phase 2, delete from quarantine only:** on `remove` the sidecar records an `lstat` inventory (relative path, type, size, mtime, inode) and `phase: deleting`; from then on there is no rollback, and deletion touches only `.dm-quarantine/<id>`. The sidecar is removed last. Linked worktrees use the same protocol: `wrh_remove_now` in quarantine mode renames the checkout into `.dm-quarantine` (phase 1), deletes from there, then runs `git worktree prune`. **Reconciliation per crash point:** (1) `intent`, original present, nothing in quarantine → drop the sidecar; (2) `intent`, object in quarantine with matching identity (crash between rename and phase write) → treat as `quarantined`; (3) `quarantined` → rerun the verdict, then roll back or enter phase 2; (4) `deleting`, partly deleted → delete the remaining entries that match the inventory; an entry not in it or changed is kept and the remainder stays quarantined with `quarantine_partial_kept`; (5) object gone → drop the sidecar (worktrees: `git worktree prune`). Identity mismatch or a missing or malformed sidecar → keep and alert. Rollback never claims to restore deleted files: phase 2 only starts after a `remove` verdict, so an interrupted delete loses only content already proved disposable. Kept quarantined artifacts are never auto-deleted, count in `parked` bytes, and stay recoverable with `diskm quarantine restore <id>` (identity-checked, `RENAME_EXCL`). Linked worktrees are claimed with `lease_write_pending` and rechecked just before `wrh_remove_now`.

**Delete-path coverage and shadow rollout.** C14 is wired into every path below **before the pilot starts** (§7.4), in one of two modes per class (`c14_mode` in the budgets block). **New or widened paths enforce from day one:** governor-run actuation, the pressure-sweep kickstart, T1, T3 and main_sweeper Tier 6 under D1b, #151, and #152's descent. **Existing sweeper paths start in `shadow`** so stricter C14 cannot cut today's reclaim before producers emit receipts: C14 runs, today's guards still decide, and each disagreement is logged to `c14_shadow.jsonl` (site, path, bytes, verdict). `diskm budget c14-enforce <class>` (recorded) flips a class only after 7 days of shadow data in which would-keep bytes are ≤ 20% of the bytes today's rules deleted; above that, `c14_shadow_keep_high` alerts and the fix is a producer receipt or publication for that class, never a looser verdict. `tests/test_removal_sites.sh` fails on any `rm -r`, `rmtree`, `find -delete`, `git worktree remove` or `wrh_remove_now` in these files not preceded by C14 on the same target variable in the same function, unless excluded below. Behavioural fixtures remain the primary evidence.

| Actuator | Delete path | Status |
|---|---|---|
| `worktree_reap.sh` | `wrh_remove_now` (T1) | C14 (Task 11) |
| `cleanup_worktrees.sh` | `git worktree remove` (T3); antigravity orphan `rm -r -f` (line 676) | C14 on both |
| `cleanup_tmp.sh` | `remove_path` (line 316); `scratch_budget_evict_root`; `purge_aged_archives` (lines 675, 705) | C14 on all three (shadow until enforced), #152's new descent enforcing; once enforced, the over-cap purge no longer bypasses activity guards (`archive_overcap_kept`) |
| `tmp_scratch_sweep.sh` | wraps `cleanup_tmp.sh` | covered via `cleanup_tmp.sh` |
| `cleanup_codex_documents.sh` (#151) | `git worktree remove` of nested worktrees, `rm -rf` of the task dir | C14 in the #151 PR, merged after Task 11; no `--clean` before that |
| `cleanup_code_sign_clones.sh` (pressure-sweep step 3) | `rm -rf` (line 256) | C14 kind `os_clone` |
| `/advice` `run_primary_pair.py` | `shutil.rmtree` of its own clone at run end | excluded from C14 by name in the lint; guarded by `advice_own_copy_ok`, which runs C14's repository content checks (§11) |
| `cleanup_colima.sh` | `docker … prune`, in-VM `fstrim` | excluded: no host artifact |
| `cleanup_codex_db.sh` | VACUUM | excluded: no artifact removal |
| `cleanup_claude_state.sh` | state entries | not in act mode until C14-wired and `claude_state_cleanup` recorded |

Class table (pilot defaults; actuators unchanged except that each removal site calls C14):

| Class | Root(s) | Control measure | Trigger | Actuator | Act |
|---|---|---|---|---|---|
| worktrees | `~/.worktrees/*/*` | du (round-robin) | overage | `worktree_reap.sh` (T1); `cleanup_worktrees.sh --clean` (T3) | nominate until D1; T3 until D1b |
| tmp_containers | `/private/tmp/<repo>/*` | du | overage | `cleanup_tmp.sh --clean` (with #152) | always |
| tmpdir_scratch | `$TMPDIR` | df_delta_only | zone | `tmp_scratch_sweep.sh` | always |
| codex_documents | `~/Documents/Codex` | df_delta_only | zone | `diskm cleanup-codex-documents --clean` (#151) | always, once #151 is deployed |
| claude_codex_state | `~/.claude/state`, `~/.codex` minus never-delete | du | overage | `cleanup_codex_db.sh`; `cleanup_claude_state.sh` (decision `claude_state_cleanup`) | split |
| colima | `~/.colima/_lima` | observer | overage | `cleanup_colima.sh` (fstrim; #150 guard) | always |

### 7.3 Reclaim tiers (C9)

Every tier requires C14 = `remove` immediately before the removal call, then not locked, not under an AO worktree dir, byte-verified removal.

| Tier | Additional condition | Needs |
|---|---|---|
| T1 | `lease_owner_state` = `dead` (no process with that pid, or pid reuse by start epoch) or `released` per C8; 30 min quiet measured; HEAD on origin (live `git ls-remote`) or merged | D1, after the `CLAUDE.md` amendment is merged |
| T3 | The existing 3-day rule in `cleanup_worktrees.sh`, run under the governor; a lease whose owner is `alive`/`unknown` vetoes it | D1b |
| parked | Anything else, incl. owner-null worktrees younger than 3 days, TTL-expired leases with a live owner, and every `kept:unproven-content` item | listed only (D7) |

**TTL only reports** (`expired_owner_alive` in `parked`). **Owner-null** worktrees are removable only by T3, which `CLAUDE.md` already sanctions; T2 stays dropped. **T1 is a policy change:** the `CLAUDE.md` amendment quoting D1 merges, and C14 is deployed, before `worktree_reap.sh` first runs in remove mode.

**Activation is enforced in code.** Every decision-gated removal site (`worktree_reap.sh` remove mode, main_sweeper Tier 6 and `govern` running `cleanup_worktrees.sh --clean`, `cleanup_claude_state.sh`) calls `removal_activation_ok <id>`, which returns 0 only when (1) `decision_approved <id>`; (2) `artifact_verdict.sh` is present and `artifact_removal_verdict --self-test` passes; (3) for D1, the call itself runs a bounded `git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main` (`GIT_TERMINAL_PROMPT=0`, 30 s timeout), then requires that `standing_decisions.json` records an `amendment_commit` that is an ancestor of the fetched commit **and** that the fetched commit's `CLAUDE.md` contains `policy:worktree_reap_remove`. A stale local `origin/main` is never trusted: fetch failure or timeout → `activation_blocked:policy_unverified`, nominate (fail closed). A revert yields `activation_blocked:amendment_reverted` and the site nominates from its next call; revoking D1 does the same at every site. Otherwise the site nominates and writes `activation_blocked:<missing>`. `WORKTREE_APPROVED=1` and marker-file paths are unchanged.

### 7.4 Budget model and pilot week

Usable `U = 895` GiB; pilot class budgets `S = 108` (35 + 15 + 10 + 3 + 15 + 30); minimum-free target `F = 30`.

- **Sizing aid, not a gate.** Budgets are sized with `B_est + S + W_est ≤ U − F`, where `B_est = df used − Σ class used` is base space outside governed classes and `W_est` = 1.25 × the largest daily swing of `B_est` over the pilot. Both are **estimates**: on APFS, du of clone-heavy classes double-counts shared blocks (the `code_sign_clone` case, §1.4), so `B_est` can be understated. They are reported, labelled `estimate`, and excluded from every pass/fail. A daily-measure snapshot with any `carried` value reports `B_est` as `incomplete`.
- **Pass/fail is df-only:** the §7.6 indicator, the §7.5 births SLO and the §9 metrics.

**Pilot start condition.** C14 is deployed on every §7.2 delete path (shadow on existing sweeper paths, enforcing on new ones); admission (C2) with its event log, `wtn_admit`, the hook (C6), `/advice`, evidence-producer and CI admission (C13), and the birth audit (C7) are deployed, each with a scheduled receipt or an event-log line; D2 is recorded; and a live emergency probe passed: `diskm admit --probe` with `--est-gb` chosen so `projected − margin` = 20 GiB returned 76 (if free is already below that, `--est-gb 1` must return the current zone's row: 76 in BLACK, 75 in FLOOR).

**Pilot week.** Govern runs in observe mode (emergency rows active) for 7 × 24 h from `pilot_start`.

- **Qualifying day:** observer samples ≥ 95% of expected, govern receipts ≥ 95% of expected ticks, every du class fresh (≤ 3 h) in ≥ 80% of ticks. At least 6 of 7 days must qualify.
- **Invalidation (rerun from a new `pilot_start`):** fewer than 6 qualifying days; a deploy that changes admission, audit, hook or measurement code (`deployed.json` hashes); a stage, D2, margin, budget or `estimates.json` change (the effective estimates are frozen at `pilot_start`; calibration accumulates in `estimates.pending.json` and applies only through `promote-estimates`, which starts a new epoch); the launchd fleet unhealthy for more than 2 h in total.
- **Reported, not invalidating:** `admit_burst_bytes` per day against the margin; `B_est`, `W_est`; unknown-size births by count; the §7.6 exposure split before and after any reclaim change that lands mid-pilot.

D3 records budgets and margin from the pilot. Enforcement may not pass `warn` before D3, and D3 needs a valid pilot with the §7.5 births SLO met and **`pilot_floor_ok`**: zero observer samples under 15 GiB free in the pilot week (observed overshoot against the floor; whether the margin was right is not an input). If it fails, the remedy is a new prevention point or a larger margin, either of which starts a new pilot epoch; two failed valid epochs in a row trigger §12. Each stage change has a tested rollback that keeps the emergency rows (`diskm budget set-stage`).

### 7.5 Coverage: prevention first, detection second

| Producer | Prevention point | Lands before pilot |
|---|---|---|
| `diskm worktree-new` | `wtn_admit` → `diskm admit` | yes |
| `diskm scratch-new` | admit before create | yes |
| Agent shell `git worktree add` / `git clone` / `cp -R` | PreToolUse hook (C6) | yes |
| `/advice` clones in `$TMPDIR` | `run_primary_pair.py` calls `diskm admit --class tmpdir_scratch --producer advice` once per run before its clone step | yes |
| Evidence bundles under `/private/tmp/<repo>/evidence` | evidence entry points use `scratch-new --kind evidence` | yes |
| CI jobs | ezgha job-started hook (C13) | yes |
| Anything else (subshells, `eval`, scripts, apps) | none: birth audit detects persistent entries | n/a |

**SLO metric.** Births per C7: filesystem-observed destination generations only. CI jobs are reported separately in `ci_admission` (C13) and enter this ratio only as an audited filesystem birth at their workspace, so admitted CI jobs cannot dilute filesystem bypass. Admitted = a birth matched to a 0/10 attempt; bypass = an unmatched audit birth or one whose only attempt was `admission_degraded:*`. **Bypass births ratio** = bypass births / all births, < 10% per pilot day and per week after; this is the certified SLO. `attempt_unconfirmed` events are reported and never enter the ratio, so failed commands and repeated attempts cannot dilute bypass. **Bypass bytes ratio** = bypass bytes / (bypass + admitted `est_bytes`) with `bytes_unknown` charged per C7; it is reported as an **estimate** and, when unknown-size births exceed 5% of births by count, as `estimate_unbounded`. **Coverage limit, stated:** an ungoverned producer that creates and deletes a tree between two ticks is neither admitted nor audited; it appears only in the df trace (§7.6, §9). The SLO therefore certifies births that persist ≥ one tick, not all disk writes. D3 cannot be recorded, and the loop is not called closed, while the births SLO fails; the top bypass roots become the next prevention points.

### 7.6 Floor breach: backstop, indicator and runbook

Admission stops new governed writes; it cannot stop an admitted writer mid-copy, a concurrent admitted burst landing after the same df reading, a bypassing producer, or a running CI job. The pilot reports an **empirical exposure indicator** (not a bound, not a certification):

```
r_peak      [B/s] = max over sliding 600 s windows of Δ(df used) / 600      # no subtraction of admitted or reserved bytes
T_detect    [s]   = 600 (tick) + observer sample interval
T_reclaim   [s]   = max observed zone-tick start → first receipt with df_delta_bytes > 0
exposure    [B]   = r_peak × (T_detect + T_reclaim) + admit_burst_bytes
floor_margin_ok   = exposure ≤ 15 GiB;  no positive reclaim receipt observed → margin_unknown (fails)
```

Bursts shorter than 600 s are averaged into their window, so `r_peak` can understate a short burst; the pilot reports `sample_interval_s` and the largest single-sample Δ beside it. Worked example: a 12 GiB rise in 600 s gives 0.02 GiB/s; with `T_detect` 660 s, `T_reclaim` 240 s and a 10 GiB admitted burst, exposure = 0.02 × 900 + 10 = 28 GiB → false. `floor_margin_ok` is reported, never a gate: "zero samples under 15 GiB" (`pilot_floor_ok`, §7.4; §9) is the empirical acceptance test.

When free < 15 GiB, the tick: (1) writes `floor_breach` first with the top growing roots from the audit, event log and observer; (2) runs every zone actuator, escalation ladder first, and kickstarts pressure-sweep if C14 is active; (3) prints the CI pause command (`launchctl bootout gui/$UID/<ezgha label>`) and Colima producer state, pausing CI only with D4; (4) records `tmutil listlocalsnapshots /`. Manual runbook printed by `diskm status`: identify the producer; ask the user before pausing CI runners; `colima stop && colima start`, then `colima ssh -- sudo fstrim -av`; list parked worktrees; never hand-`rm`.

## 8. Assumptions and recommended defaults (auto-picked)

| Question | Auto-picked default | Rationale |
|---|---|---|
| **r6-A: reservation ledger in v1?** | **No.** `diskm admit` decides from fresh df − est − margin under `state.lock`, which orders decisions only; admission is best-effort with no finite overshoot bound, limited by the margin, the 15 GiB hard floor and BLACK, and judged by the observed df floor; ledger deferred to §12 | Round 4's non-approvals were mostly ledger defects (repair, release, exit codes, compaction, exposure cancellation). Deleting the ledger removes them; the remaining risk is visible in the event log and has a v2 trigger |
| **r6-B: what makes content disposable?** | Positive provenance for all non-git content (upload-manifest match against a publication verified present at publish time, or the #153 rebuildable allowlist; a manifest alone proves only "unchanged"); tracked changes in every repository type kept; commits the removal destroys checked against remotes after a bounded fetch (whole repo: `--all --reflog`; linked worktree: its own HEAD, branch and reflogs), fetch failure keeps; branch delete via `update-ref -d <ref> <expected-sha>` | Location and age prove nothing about uniqueness (reviewer B2); reflogs hold real work after a reset (reviewer B1, reproduced); a check-then-delete races, a conditional ref update does not |
| **r6-C: remaining concrete fixes** | Kickstart pressure-sweep only once C14 is active; one `state.lock` for every `budget.json`/event-log writer; quarantine records provenance and never overwrites a recreated path; `B_est` excluded from pass/fail; births from the event log plus audit, unknown sizes charged a documented estimate; admit never runs a command (distinct rc channel); no release/CI-completion paths | Each closes one round-4 finding with less machinery than before |
| Setpoints | GREEN ≥ 100, ORANGE 60–100, RED 30–60, BLACK 15–30, FLOOR < 15 GiB; admission zone on `projected − margin` | Matches `F = 30`; the margin reduces same-tick bursts |
| Concurrency margin | 10 GiB pilot default; a pilot epoch parameter (a change restarts the pilot); `admit_burst_bytes` reported beside it | Progress is gated on the observed floor, not on the margin being right |
| Class budgets (GiB, pilot) | worktrees 35, tmp_containers 15, tmpdir_scratch 10, codex_documents 3, claude_codex_state 15, colima 30 (sum 108) | Sizing aid with estimates (§7.4); validated by df in the pilot |
| Admission when df fails or rc unknown | Last tick's free if ≤ 15 min old, else rc 10; `admission_degraded:*`, alert, counted as bypass | Never block all work on a measurement bug, never call it safe |
| Tick cadence and slices | 10 min, one absolute 540 s monotonic deadline for every phase; zone and emergency first, then bounded reconciliation, measure, audit, dispatch with a 60 s reserve; slice `min(300, max(min_slice, usable / pending))` with `min_slice = unit_budget + 40`; soft stop 40 s before slice end, kill only as backstop, rotation, checkpointed enumeration, escalation at 3 and 6 | Dispatch and reclaim both make progress inside the deadline |
| Reuse | Pending-lease claim, C14, idle 2 h, conditional `update-ref -d`, create-only restore at the recorded tip on failure | Recycling must not lose a branch |
| `/advice` teardown | Producer-own deletion behind `advice_own_copy_ok`, not C14 | The runner is the copy's live owner, so C14 would always keep it; the guard runs C14's repository content checks and keeps the copy on any failure |
| Decision provenance and expiry | Phrase naming the decision in a user message of the named transcript; revocable, no expiry | Honest about what a local file proves; expiry returns to babysitting |
| C14 on existing sweepers | `shadow` (log would-keep vs would-delete) until 7 days show ≤ 20% of bytes newly kept; new paths enforce at once | Stricter provenance must not cut reclaim before producers emit receipts |
| Enforcement rollout | observe 7 d (pilot) → warn → `refuse_red` after D3 → `refuse_orange` 7 d later; emergency rows from D2 | Day-one refusal at RED would block all work |

## 9. Success metrics

Measured from `disk_observer.jsonl` (df only); the snapshot ledger only at coverage ≥ 70%. v1 admission is best-effort (§7.1), so success is these df rows; no admission figure certifies anything. A weekly window counts only if the observer has ≥ 95% of expected samples; otherwise `insufficient_data`, no pass.

| Metric | Today | Target after 7 days of T1 + T3 remove mode |
|---|---|---|
| 7-day minimum of df free | about 0.3 GiB | ≥ 30 GiB |
| Samples with free < 15 GiB per week | 605+ | 0 |
| Daily used trough (7-day max of daily minimums) | 839 GiB and rising | ≤ 790 GiB, not rising |
| `govern_*` receipts with non-null `df_delta_bytes` | n/a | 100% |
| Bypass births ratio (bytes ratio reported as estimate) | unmeasured | < 10% |
| Govern ticks older than 30 min | n/a | 0 alerts per week |

`diskm budget status --weekly-check` evaluates these rows over a fixed calendar week (Monday 00:00 local, 7 × 24 h) and exits 0 only if all pass. The bead closes after passes on **two consecutive non-overlapping** weeks. Stretch target: 7-day minimum free ≥ 60 GiB after two weeks of data.

## 10. Implementation preconditions (user decisions)

| ID | Decision | Recommended default | Blocks |
|---|---|---|---|
| D1 | Owner-exit removal (T1) exception to the 7-day floor (§7.3 / bead `7u9t`); the `CLAUDE.md` amendment merges first | **Approve** | T1 remove mode |
| D1b | Run the existing 3-day `cleanup_worktrees.sh --clean` unattended (T3), behind C14 | **Approve** | T3 under govern and main_sweeper |
| D2 | Admission enforcement via `wtn_admit`, the hook, `/advice`, evidence producers, CI | **Emergency rows at once; other rows phased** per §8 | All refusals |
| D3 | Budgets and margin from a valid pilot, with the §7.5 births SLO and `pilot_floor_ok` | Record after pilot | enforcement beyond `warn` |
| D4 | CI backpressure | **Alert + pause command, no auto-pause** | C13 auto-pause |
| D5 | Push on exit (normal push only) | **Approve** | C8 skill contract |
| D6 | Edits outside this repo: hook install, `/advice` admit call, evidence-producer skill text, ezgha hook, gate producers, AGENTS.md, SessionEnd hook | **Approve** | C2 callers, C4, C6, C8, C13 |
| D7 | Parked set | **List daily, never delete** | none |
| D8 | Colima self-heal (clear stale lima lock, restart when stopped > 30 min with no lima process) | **Approve** | C12 auto-heal |
| — | `claude_state_cleanup` for `cleanup_claude_state.sh` | Ask separately | claude-state actuator only |

A decision counts only when recorded through `diskm policy approve` with the user's literal phrase, verified against the transcript (C11). A bead comment or agent report is not a decision.

## 11. Risks

- **Admitted writers overshoot.** Accepted in v1 (§7.1): best-effort, no finite bound; limited by the margin, the 15 GiB hard floor and BLACK; `admit_burst_bytes` and `burst_over_margin` are diagnostics; two consecutive valid pilot epochs that breach the floor trigger §12.
- **A bypassing or admitted producer writes faster than reclaim.** Not prevented; the §7.6 indicator, `floor_breach` and `bypass_high` name the root, which becomes a prevention point.
- **Estimates are wrong.** Per-producer calibration from audited births (C2), promoted only between pilot epochs; `cp -R` sizes its source; df catches landed bytes on the next admit.
- **Stricter C14 keeps much more.** Positive provenance and `--reflog` keep content today's sweepers delete, so tmp and codex-documents reclaim would drop until producers publish. Existing sweeper paths therefore run C14 in `shadow` until their class's 7-day would-keep share is ≤ 20% (§7.2); `c14_shadow_keep_high`, `reclaim_starved` and `parked_large` show the cost; the fix is a producer receipt or manifest, never a looser verdict.
- **Base space is larger than assumed.** `B_est` is an estimate only; budgets are judged by df in the pilot and D3 lowers them first.
- **Reuse hands an idle agent's worktree to a new owner.** Pending-lease claim, owner `dead`/`released`, C14, conditional branch delete.
- **Crashed `/advice` clones have no remote.** Disposable when the runner's `receipt.json` records source repo, resolved SHA, runner pid + `start_epoch` and an overlay manifest (path + sha256 of every file in `.advice-review-documents/`); the runner is dead; ≥ 2 h idle; `rev-list --all --reflog --not <sha>` empty; no tracked change (C14 git rule); the source still has the SHA (`git -C <source> cat-file -e <sha>^{commit}`, else `kept:source-missing`); and the overlay matches the manifest exactly (else `kept:overlay-unproven`). Missing receipt → `kept:check-failed`. **Normal teardown** is the runner deleting its own copy, not a C14 removal (C14 would keep it: the runner is its live owner). `advice_own_copy_ok` runs before the `rmtree` and requires: the receipt's pid + `start_epoch` are the running process; the source still has the SHA; `git rev-list --all --reflog --not <sha>` is empty; and the same repository content checks as C14 (`c14_repo_content_ok`, shared code): no staged, unstaged or submodule change to a tracked file, no assume-unchanged or skip-worktree entry, no untracked file outside the receipt-listed overlay, the overlay matching its manifest, and no ignored file outside the overlay unless it is on the #153 rebuildable allowlist with no secret-like file under it. Any failure keeps the copy (`advice_teardown_kept:<reason>`), and the crashed-clone rule above then keeps it too. Reviewer verdicts are captured from reviewer stdout before teardown; anything a reviewer leaves in the working tree keeps the copy.
- **The disk is too full to write state.** Writes under 64 KiB, atomic replace keeps the previous file, event-log append failure never changes a decision; the plan's stress test runs a tick at about 5 GiB free.

## 12. Deferred (v2): reservation ledger

Not in v1. Built if two consecutive valid pilot epochs breach the 15 GiB floor (§7.4), or production shows a `floor_breach` attributable to concurrent admitted writers. Acceptance criteria, taken from rounds 3–4:

1. A reservation is bound to the writer's process group/session, created before the command runs; wrapper death does not release it.
2. Release is a request: a bound reservation stays charged until its writer group and session are empty, including CI job descendants; any force-release is a separate, unsafe admin command.
3. Writes are admitted only through the wrapper, or direct reservations carry independently recoverable writer identity; an enforced maximum reservation size exists.
4. Losing ledger and journal keeps admission closed until every outstanding charge is bounded from durable evidence; an apparently empty process scan is not proof.
5. The admission result travels on a channel separate from the command's exit status (started, reservation id, decision, command rc); retry only when the command never started.
6. Journal append, ledger replace and compaction run under the same lock as reserve/bind/release, with crash tests after fsync-before-replace and replace-before-return.
7. No metric subtracts reservation changes from df changes.
