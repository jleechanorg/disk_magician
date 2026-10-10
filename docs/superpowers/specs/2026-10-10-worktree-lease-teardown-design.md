# Worktree leases and owner-exit teardown — design

Date: 2026-10-10 · Status: design (planning only) · Owner repo: `disk_magician`
Related: [2026-10-05 standard worktree root](2026-10-05-standard-worktree-root-and-evidence-location-design.md),
[2026-09-23 disk-fill prevention](2026-09-23-disk-fill-prevention-and-scheduled-cleanup-design.md),
bead `disk_magician-oyt4`, [PR #146](https://github.com/jleechanorg/disk_magician/pull/146).

## 1. Why

On six of the eight days from 2026-10-03 to 2026-10-10, free space hit about 0.3 GiB. Each cleanup was refilled within hours. Measured 2026-10-10:

- **Dominant producer.** `~/.worktrees` grew by 87.4 GiB from 10-07 to 10-10 (snapshot commits `45ef4da` and `fc941aa`, coverage ≥70%).
  - 250 linked worktrees were created between 10-06 and 10-10, about 50/day: worldarchitect.ai 101, roadmap 59, worldai_claw 38, jleechan-skills 30.
  - Most are short-lived per-PR checkouts for review, evidence or verification (`rev-*`, `ev*`, `pr*-ev`, `deploy`, `ready`, `parity-*`).
- **Nothing tears them down.**
  - Agents create worktrees from shell commands (`git worktree add` steered by `diskm guard-worktree-add`, or `diskm worktree-new`). Those never fire Claude's `WorktreeRemove` event; only about 4 remove-hook invocations were logged on 10-10, against about 27 creations.
  - When the hook does fire, `wrh_main` keeps any worktree touched in the last 7 days (`worktree_is_recently_active "$real" 7`). A worktree is always recently active at the moment its task ends, so teardown cannot succeed by construction.
- **Sweeper result.** `cleanup_worktrees.sh` (3-day floor) classified 591 worktrees:

  | Verdict | Count |
  |---|---|
  | young | 196 |
  | ahead-of-main | 77 |
  | untracked | 51 |
  | dirty | 47 |
  | ignored-data | 42 |
  | eligible | 81 (~24.8 GB), after PR #146 removes the bytecode hidden-state false positive |

  At about 50 worktrees/day and 0.35 GiB each, the 3-day floor alone keeps about 50 GiB in flight, plus a long tail that never qualifies.

Every other prevention layer (pressure sweep, Colima trim, tmp sweeps) reacts after space is gone. The fix belongs at the point where a worktree's job ends.

## 2. Goals, non-goals, anti-goals

**Goals**
- G1. Every worktree created under `$STANDARD_WORKTREE_ROOT` has a recorded owner and lifetime: a lease.
- G2. When the owning agent process has exited and the worktree is safe to remove, it is removed within one reaper interval (≤30 min) without waiting for the 3- or 7-day floor. Safe means:
  - clean (no tracked changes or untracked files)
  - no hidden state
  - no non-rebuildable ignored data
  - HEAD contained in a remote-tracking ref
  - not locked, not a live cwd, not AO-owned
- G3. Steady-state `~/.worktrees` stays under 40 GiB at the current creation rate. This is measured by the observer and reported by `diskm status`.
- G4. `diskm worktree-new` refuses to create a worktree when free space is critically low, and tells the caller to reuse an existing one.
- G5. Every keep/remove decision is visible in `diskm status --json` with counts per reason.

**Non-goals**
- Changing the Colima/ezgha CI producer (beads `disk_magician-1u29`, `4dar`; pressure-sweep trim already exists).
- Ledger freshness and the root frontier runner (PR #127, separate precondition).
- Sharing `node_modules` or venvs across worktrees (`cleanup_worktree_deps.sh` already strips dormant ones).
- Moving agent scratch out of `~/projects` (bead `disk_magician-jj2`).

**Anti-goals** (failure even if disk improves)
- Losing any unpushed commit, uncommitted change, untracked file, ignored secret, or ignored user data.
- Removing a worktree that a live process uses as its cwd, or that belongs to a running agent.
- Any `--force` removal, or deleting a branch that is not a `worktree-*` branch.
- A second dispatcher or ad-hoc script outside `diskm` (repo CLAUDE.md "One operational entry point").

## 3. Constraints

- Repo CLAUDE.md "Worktree 7-day rule (hard)": a worktree touched within the protection window may not be removed by any script, sweeper or launchd job. G2 needs an explicit, narrow user-approved amendment (see §8, Implementation Preconditions). Until then the reaper runs only in `nominate` mode, which records verdicts and deletes nothing.
- Recency is measured, never proxied. Use `worktree_is_recently_active` / `worktree_age_days` from `scripts/lib/worktree_recency.sh`.
- Fail closed: an unknown owner state, unreadable lease, or failed probe means keep.
- Deploy path: repo-root scripts → `scripts/sync_package_tree.sh` → version bump → `tools/deploy_uv_tool.sh`. Launchd templates live in the repo and are installed by `scripts/install_launchd_sweepers.sh`.
- `plutil` must never be run as `-extract` without `-o -`.

## 4. Approaches considered

| Approach | Summary | Verdict |
|---|---|---|
| A. Lease + owner-exit reaper | Record the owner process (pid + start time) at creation. A launchd reaper applies the existing remove-hook safety checks once the owner has exited. | **Chosen.** Ties teardown to the real end of work, reuses the vetted `wrh_*` checks, and keeps multi-day tasks safe while their owner is alive. |
| B. Lower the sweeper floor to 1 day | Change `cleanup_worktrees.sh` only. | Rejected. It measures mtime, not ownership, so it would remove worktrees of long-running agents that pause for a day. It needs the same rule amendment for a blunter result. |
| C. Disk-budget LRU eviction | When `~/.worktrees` exceeds N GiB, evict the oldest clean, pushed worktrees. | Deferred as a backstop. Without ownership it can evict a live task's checkout. Revisit if A leaves the budget exceeded. |

## 5. Design

### D1. Lease record

Path: `~/.disk_magician_state/worktree_leases/<sha256(realpath)[:16]>.json`, written atomically (temp file plus `mv`).

```json
{"schema_version": 1, "path": "/Users/.../.worktrees/repo/name", "repo": "/Users/.../repo",
 "branch": "feat/x", "created_at": "2026-10-10T23:00:00Z",
 "owner": {"pid": 12345, "lstart": "Sat Oct 10 15:59:59 2026", "comm": "claude"},
 "creator": "worktree-new|worktree-create-hook|adopt", "state": "active",
 "ttl_hours": 24, "released_at": null,
 "last_verdict": null, "last_checked_at": null}
```

- **Owner** is the nearest ancestor of the creating process whose executable basename is in a fixed list of agent runtimes (`claude`, `codex`, `agy`, `cursor-agent`, `hermes`). This is a process-identity lookup, not a semantic judgment.
- If no ancestor matches (launchd or cron creators), `owner` is `null`. The lease is then never owner-reaped and falls back to the sweeper floor. A short-lived launching shell must never count as the owner, because it would look dead immediately.
- `lstart` guards against pid reuse. The owner counts as alive only when `ps -p <pid> -o lstart=` matches exactly.
- **Writers:**
  - `worktree_new.sh` after a successful `wtn_create`.
  - `worktree_create_hook.sh`.
  - `diskm guard-worktree-add` cannot write a lease because the worktree doesn't exist yet. Instead the reaper's adoption step (D2.1) records unleased worktrees with `owner: null`, and these fall back to the existing sweeper floor.

### D2. Reaper: `diskm worktree-reap`

`scripts/worktree_reap.sh`, dispatched by `disk_magician.sh` and the package CLI. Launchd job `com.jleechanorg.disk-magician-worktree-reap`, `StartInterval` 1800, from a repo template.

1. **Adopt.** For each registered linked worktree under `$STANDARD_WORKTREE_ROOT` that has no lease, write one with `owner: null, creator: "adopt"`. These are never reaped by owner exit and stay governed by `cleanup_worktrees.sh`.
2. **Owner check.** For each lease with a non-null owner, the owner has ended when any of these holds:
   - **dead:** pid absent, or `lstart` mismatch
   - **released:** `released_at` is set by `diskm worktree-release <path>`
   - **expired:** `created_at + ttl_hours` has passed
   An alive owner whose lease is neither released nor expired means record `state: active` and skip. If `ps` fails, the state is unknown, which means keep.

   The expiry trigger covers long-lived orchestrator sessions that spawn many `rev-*`/`ev*` worktrees and never exit. Expired and released leases use a longer quiet period, `REAP_EXPIRED_QUIET_MINUTES` (default 360), than dead ones. Every other safety check still applies, so a reaped clean, pushed worktree can always be recreated.
3. **Quiet period.** Require no content change for `REAP_QUIET_MINUTES` (default 30) via `worktree_is_recently_active` with minute granularity. Section 9 notes the helper extension this needs. This covers a sibling agent that adopted the worktree after the owner died.
4. **Remote freshness.** Before any verdict, run `git fetch --quiet --prune origin` once per owning repo, bounded to 60 s. If the fetch fails, every candidate in that repo gets `kept:remote-unverified`. This makes "HEAD on a remote-tracking ref" refer to current refs at one network call per repo, not per worktree.
5. **Safety.** Run `scripts/safety_check.sh <path>`; a non-zero result means `kept:safety-local`, so the `safety.local.json` `never_delete`, `protected_live_paths` and `needs_decision` rules gate the reaper too. Then call a new `wrh_removal_verdict <real>` extracted from `wrh_main`. It runs the same checks in the same order but with a caller-supplied recency floor, and prints `remove` or `kept:<reason>`:
   - registered linked worktree
   - live cwd
   - AO
   - recency (the caller passes the floor: the hook passes 7 days, the reaper passes its quiet period)
   - clean
   - hidden state
   - ignored user data
   - HEAD on a remote-tracking ref
6. **Mode.** `DISK_MAGICIAN_REAP_MODE`:
   - `nominate` (default): record `last_verdict` and remove nothing.
   - `remove`: on a `remove` verdict, run `git worktree remove` (never `--force`) and delete a `worktree-*` branch only when it is not checked out elsewhere (the same code as `wrh_main`), then delete the lease.
   `remove` is enabled only after the §8 precondition is met.
7. **Prune.** Delete leases whose path no longer exists.
8. Write a typed receipt (`receipts/worktree_reap.json`) through the existing receipt helper, with counts per verdict and the bytes freed (measured by `df` before and after).

`wrh_removal_verdict` is a pure extraction. Its `has_ignored_user_data` already allows the known-rebuildable dirs (`node_modules`, `venv`, `.venv`, `__pycache__`, caches) and keeps everything else. Its `wrh_live_cwd_reason` already treats an `lsof` failure as keep.

**`diskm worktree-release <path>`** sets `released_at` on the lease. Callers that know their work is done (review and evidence flows, `/advice` lanes) call it so the worktree is reaped after the expired quiet period instead of waiting for the TTL. It never deletes anything itself.

The remove hook keeps its current behavior by calling `wrh_removal_verdict` with a 7-day floor. That refactor is behavior-preserving and covered by the existing `tests/test_worktree_remove_hook.sh`.

### D3. Admission gate in `diskm worktree-new`

Before `wtn_create`:
- If free space is below `WORKTREE_ADMIT_REAP_GB` (default 25), run `worktree_reap.sh` once synchronously, bounded to 60 s.
- If free space is still below `WORKTREE_ADMIT_MIN_GB` (default 10), exit 75 with:
  `disk low (<N> GiB free): reuse an existing worktree (diskm worktree-list --repo <repo>) or run diskm clean`.
- `WORKTREE_ADMIT_MIN_GB=0` disables the gate.

`worktree_create_hook.sh` does not gate, because Claude needs a path or it errors. It writes the lease and logs a warning.

### D4. Status and alerting

`disk_status.py` adds a `worktrees` section:
- lease counts by state and `last_verdict`
- root size in GiB from the observer bucket
- creations/day over 7 days, from lease `created_at`

`status` becomes `degraded` when the root exceeds 60 GiB or when owner-dead `kept:*` leases exceed 100. `sweeper-health` includes the reaper receipt.

## 6. Assumptions and recommended defaults (auto-picked under /sq)

| # | Question | Auto-picked answer | Rationale |
|---|---|---|---|
| 1 | Where to store leases: inside the worktree or in a state dir? | State dir `~/.disk_magician_state/worktree_leases/` | A file inside the worktree would show up as untracked and make it "dirty". The state dir matches other receipts. |
| 2 | How to identify the owner? | Nearest agent-runtime ancestor pid plus `lstart`, else the session leader | pid reuse is real on a busy host; `lstart` makes the check exact. |
| 3 | Reaper or a session-end hook? | Launchd reaper | Codex, agy and Hermes have no shared session-end hook. A poller covers every runtime and crash exits. |
| 4 | Remove on owner exit inside the 7-day window? | Only after explicit user approval; default `nominate` | The repo CLAUDE.md rule is hard and user-owned (§8). |
| 5 | Quiet period after owner exit? | 30 min | Covers a handoff to a sibling agent; still reclaims within an hour. |
| 6 | Adopt worktrees created via raw `git worktree add`? | Adopt with `owner: null`; never owner-reaped | No reliable owner, so they stay under the existing floor (fail closed). |
| 7 | Admission thresholds? | Reap below 25 GiB, refuse below 10 GiB | The 10-04 to 10-09 ENOSPC failures happened at ≤2 GiB. 10 GiB leaves room for a clone plus test run. |
| 8 | Include LRU budget eviction now? | No, deferred (approach C) | Needs ownership to be safe. Revisit with D4 data. |
| 9 | Interval? | 30 min | Matches the pressure sweep cadence and bounds reclaim latency. |
| 10 | Should the reaper also strip deps from owner-dead dirty worktrees? | No | `cleanup_worktree_deps.sh` already owns that at 3 days. Keeps scope narrow. |
| 11 | Long-lived sessions that never exit (builder check) | Lease TTL 24 h plus `diskm worktree-release`; expired or released leases need 6 h quiet | Without it, G3 fails under orchestrator sessions. The 6 h quiet period protects a session that returns to the worktree. |
| 12 | Owner when no agent ancestor exists (builder check) | `owner: null`, never owner-reaped | A launchd or cron launching shell exits at once and would look dead. |
| 13 | Freshness of remote refs (builder check) | One bounded `git fetch` per repo per run; failure means keep | Stale refs risk deleting unpushed work; a per-worktree `ls-remote` costs ~590 calls. |
| 14 | Do `safety.local.json` rules gate the reaper? (builder check) | Yes, via `scripts/safety_check.sh` | Machine-local never-delete rules apply to every deleter. |
| 15 | Is `wrh_removal_verdict` stricter or looser than the hook? (builder check) | Pure extraction, identical checks | Keeps one definition of "safe to remove". |
| 16 | Stack the implementation on PR #146 or wait? (builder check) | Tasks 1–4 start on `main`; Task 5 waits for #146 and a rebase | Only the reaper depends on the hidden-state fix. |

## 7. What is left to the builder

- Exact JSON field order and log wording.
- Whether `worktree-list` is a new subcommand or an alias of an existing listing. It must stay inside `diskm`.
- Shared helper placement (`scripts/lib/worktree_lease.sh`).

## 8. Implementation Preconditions

- **P1 (user-only).** Approval to amend repo CLAUDE.md "Worktree 7-day rule (hard)" with a narrow exception. It covers a worktree with a lease whose owner has ended and that has been quiet for the required period:
  - owner exited (pid plus `lstart` mismatch): 30 min
  - lease released or past its 24 h TTL: 6 h
  If such a worktree also passes `safety_check.sh` and every `wrh_removal_verdict` check after a fresh fetch, `diskm worktree-reap` may remove it.
  - Until P1 is granted, the plan ships `nominate` mode only, and the plan steps that set `DISK_MAGICIAN_REAP_MODE=remove` stay conditional.
  - Nominate mode still delivers G1, G4 and G5, and measures exactly how much G2 would reclaim.
- **P2.** [PR #146](https://github.com/jleechanorg/disk_magician/pull/146) merged first. The reaper reuses `has_hidden_state`, and without that fix about 97% of candidates read `kept:hidden-state`.

## 9. Risks

- **Owner misattribution.** A worktree created by a short-lived wrapper subprocess whose agent parent is not in the runtime list would be attributed to the session leader. That is conservative, because the leader outlives the work.
- **Minute-granularity recency.** `worktree_is_recently_active` takes days today. The builder adds a minutes variant in the same helper, with the fail-closed unmeasurable-case test (pattern: `tests/test_worktree_recency.sh` case 5).
- **Concurrency.** The reaper takes an mkdir lock like the other sweepers. Lease writes are atomic.

## 10. Success measurement

- Within 7 days of `remove` mode: `~/.worktrees` ≤40 GiB at the observer's daily max, and zero ENOSPC events in agent transcripts.
- In nominate mode (the delivered scope unless P1 is granted): `diskm status --json .worktrees.verdicts.remove` gives projected reclaim in GiB. The ≤40 GiB target applies only after P1 enables `remove`.
