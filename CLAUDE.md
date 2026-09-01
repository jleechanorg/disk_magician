# disk_magician — agent instructions

## Investigation methodology — always find the floor, always show the buckets

Disk-fill investigations in this repo MUST follow a fixed pre-analysis
sequence (added 2026-07-30 after four "200 GiB does not exist" misses that
underestimated cumulative-reservoir growth):

0. **Consult prior memory files before live probes & recognize full disk readability.**
   Empirical verification on 2026-08-30/31 confirmed that **ALL user-data and TCC
   paths (`MobileSync`, `Mail`, `Messages`, `Containers`, `Group Containers`, `Safari`,
   `HomeKit`, `PersonalizationPortrait`, `Suggestions`) ARE 100% READABLE AND ACCESSIBLE**
   to the scanner with zero permission walls (total user TCC data is ~4.6 GiB).
   **Stop assuming parts of the disk are unreadable or that a 200+ GiB "TCC permission wall"
   exists.** The system residual floor consists of active browser code_sign_clones
   (`/private/var/folders/.../X/`), APFS local snapshots (`com.apple.os.update-...`),
   and system daemon state (`/private/var/db`). Measure directly with bounded timeouts.

1. **Find the last-week floor** before proposing anything. The floor is
   the **lowest `df used` in the most recent ~14 daily snapshots** (NOT
   proxies, NOT a single fresh `du`, NOT current df). Pull it from the
   git-backed ledger in `~/.disk_magician_backup/ledger/topdown-5g.json`
   via `git -C ~/.disk_magician_backup log -- ledger/topdown-5g.json | head`
   then `git show <sha>:ledger/topdown-5g.json`. State the floor date +
   value and the gap (current used − floor used) before any other
   measurement. **The gap-to-floor grounds every proposal.**

2. **Pull per-directory granularity buckets** from that same ledger (the
   schema stores every ≥5 GiB entry it observed with `size_mb`). Do NOT
   run a fresh `du` sweep on the loaded disk — `du` repeatedly stalls
   >60s on this box under load, and a stalled du is a timed-out du.
   Compare the buckets at the floor snapshot vs the current snapshot
   and present the **per-path before/after delta table**. Every "x GiB"
   cited in the report must be from the ledger, not from a proxy.

3. **Then** supplement with cheap spot-checks only for items the ledger
   doesn't cover (small dirs, new dirs created after the last snapshot).
   Always re-measure per item before deletion (smoke-test memory:
   0.00002 GiB "verified" was actually 2.4 GiB+).

4. **System Residual & Mega-Table Invariant**: All disk breakdown reports
   must subdivide directory nodes >5 GiB down to child buckets $\le$5 GiB
   (or opaque leaves). When residual unaccounted space is >10 GiB, run
   `./scripts/check_system_residual.sh` to check system staging paths
   (`/private/var/dirs_cleaner`) and `deleted_helper` unified logs for
   `removefile error ENAMETOOLONG`. Clean via `./disk_magician.sh cleanup-dirs-cleaner --clean`.

The canonical read of this rule lives at
`~/.claude/CLAUDE.md` → "Disk diagnosis — three concurrent lanes"
(composition: whole-disk top-down + snapshot deltas + safety-gated quick
wins). The floor-and-buckets requirement above is the **specific
pre-analysis order** for this repo's investigations, on top of that.

## Cross-repo authority: dir switching is ALWAYS allowed from this repo

This repo's purpose is machine-wide disk maintenance — its work routinely
requires reading and fixing OTHER repos and system locations (`user_scope`
sweeper scripts, `~/.disk_magician_backup` snapshot history, launchd plists,
`~/Library/LaunchAgents`, other project trees being measured or cleaned).

**Standing authorization (user directive 2026-07-11):** sessions rooted here
do NOT need `APPROVE DIR SWITCH` to edit, commit, or push in other repos when
the work is disk-maintenance scoped (fixing a sweeper that lives elsewhere,
committing snapshot history, installing/repairing launchd jobs). All other
global safety rules still apply unchanged: never-delete list, force-push
approval, merge gates, `WORKTREE APPROVED` for young worktrees.

## Never-delete list (hard)

`~/.codex/sessions*`, `~/.codex/state*.sqlite`, `~/.codex/log`,
`~/.claude/projects`. Route ALL deletions through this repo's scripts so
their mtime/safety filters apply — no hand-`rm` of session/worktree state.

## Mutable state-root symlinks (hard)

Never replace a tool-owned mutable state root (for example `.gemini`, `.claude`,
or `.codex`) with a whole-directory symlink to another live state root. Dedup
only immutable leaves or explicit caches. Any exception must fail closed unless
it proves source and destination resolve to distinct physical paths and has an
integration test that runs the downstream writer/materializer, verifies the
canonical root is unchanged, and rejects self-referential links. A dry-run or
isolated dedup test alone is insufficient because the destructive behavior can
occur only when a second tool later writes through the alias.
## Strict ban on ad-hoc cleanup scripts (hard)

Agents MUST NEVER write, execute, or substitute ad-hoc or temporary cleanup scripts (e.g. inline bash in /tmp or python one-liners) to prune worktrees, caches, or user data. ALL worktree cleanup operations MUST use established canonical scripts (`scripts/cleanup_worktrees.sh` or `scripts/worktree_hygiene.sh`) that strictly enforce the 7-day recency protection gate (`mtime > 7 days`). Writing ad-hoc scripts bypasses safety gates and is strictly banned.

## Worktree 7-day rule (hard) — recency is measured, never proxied

**A git worktree touched within the last 7 days is PROTECTED.** No script,
sweeper, launchd job, or agent in this repo may delete, archive, strip
(including its `venv/`), or `git worktree remove` it — regardless of merged
PR, clean status, zero-ahead, or disk pressure. 7 days is a floor, not a
target; `safety_min_stale_days` may raise it, never lower it.

**Measure recency, never proxy it.** The only sanctioned implementation is
`worktree_age_days` / `worktree_is_recently_active` from
`scripts/lib/worktree_recency.sh`. New code calls it; it does not re-derive
age. Two proxies are specifically banned because both were shipped here and
both were measured wrong against the live 340-worktree worldarchitect.ai
registry on 2026-07-26 (2 of 30 sampled read 20.4 days old when their newest
file was 12.8 days old — inside the protected window):

- `stat <wt>/.git` — for a linked worktree that is a one-line `gitdir:`
  pointer written once by `git worktree add`. It measures creation age.
- `stat <wt>` — a directory mtime only moves when a *top-level* entry is
  added or removed. Editing files deep in the tree never touches it.

Conversely, git metadata does NOT count as activity: `git status` rewrites
the index, and this repo's own triage runs `git status` on every candidate,
so counting it would make each run exempt the worktrees the previous run
identified. Content mtime is the signal; commit/checkout/reset/rebase all
rewrite working-tree files, so real work always appears there.

**Fail closed.** Cannot measure it → treat as active → preserve. A sweeper
that cannot prove a worktree is old must not touch it. Any new "is this
stale?" check must have a test asserting the unmeasurable case is protected
(`tests/test_worktree_recency.sh` case 5 is the pattern).

**Deleting is not the only way to lose a worktree.** Removing it while its
branch still holds unpushed commits, or while a shell/agent has it as cwd,
is the same incident with extra steps — see the triage ladder in
`scripts/worktree_hygiene.sh` (`classify_candidate`), which is the canonical
SAFE/NEEDS-REVIEW judgment. `--execute` still requires `WORKTREE_APPROVED=1`.

## Deployment — commit is NOT deploy (two consumers, two paths)

**Skill (single source of truth):** `~/.claude/skills/fix-completion-deploy/SKILL.md` — durable fix promotion, origin-main verification, tracked templates, and deployed-revision proof.

1. The 35-min snapshot launchd job (`com.jleechanorg.disk-magician`) runs the
   **uv-tool-packaged copy** at
   `~/.local/share/uv/tools/disk-magician/.../disk_magician/`, built from
   `src/disk_magician/` — NOT the repo root files.
2. The drilldown / frontier-nightly / pressure-sweep launchd jobs run
   **repo-root scripts** directly (`@REPO_ROOT@` substitution).

After changing root scripts: run `scripts/sync_package_tree.sh` (use
`--check` in review), **bump the version in pyproject.toml** (uv caches
wheels by version), then `uv tool install --force --reinstall <repo path>`.
Verify the deployed tree, not the repo, before claiming production behavior
(stale-deploy incident 2026-07-11: v2 code was committed for hours while
production ran v1).

## Operational gotchas (learned the hard way — details in roadmap/ and beads)

- Snapshot mode holds an mkdir lock (`~/.disk_magician_state/snapshot.lock`);
  concurrent runs skip, they don't queue.
- `cleanup_tmp.sh` defaults to DRY-RUN; callers must pass `--clean`.
- Colima's sparse disk only shrinks via in-VM `fstrim`; when the HOST disk
  hits ~100% the guest wedges with I/O errors and can't trim — recover with
  `colima stop && colima start` then `colima ssh -- sudo fstrim -av`.
  Prevention: the 2h pressure-sweep job (free < 40G gate).
- Snapshot JSON is schema_version 2: coverage_pct is dedup-corrected
  (raw value preserved at `snapshot_metadata.coverage_pct_raw_v1`);
  `residual_gb`/`residual_delta_gb` track unmeasured space;
  `topdown_coverage` embeds the nightly frontier scan when
  `~/.disk_magician_state/frontier_last.json` is <36h old.
- Backup/history repo: `~/.disk_magician_backup` (host profile
  `backup/jeffreys-macbook-pro/`); full history is anchored by branch
  `archive/pre-reset-20260711` — do not `git gc --prune` there casually.
- `~/.hermes_prod` and `~/.openclaw.bak` are symlinks to `~/.hermes` —
  naive `du` over home-dir args triple-counts them.

## Design doc

`roadmap/2026-07-11-total-coverage-snapshot-v2.md` — frontier-BFS coverage
architecture, critic findings, implementation order. Beads track remaining
work (`br search disk`).

## Machine-local safety guidelines (safety.local.json)

Machine-specific safety rules live in a gitignored `safety.local.json`
(repo root or `~/.config/disk-magician/` — schema in
`safety.local.json.template`): never_delete globs, protected_live_paths
(dirs owned by running processes), needs_decision (paths awaiting a human
push-or-discard call), and min_stale_days. The cleanup scripts consult it
via `scripts/safety_lib.sh` and fail closed on unreadable rules. Before ANY
manual deletion, run `scripts/safety_check.sh <path>...`.

## Machine-local findings (findings_wiki/ — fork-tracked knowledge)

`findings_wiki/` holds one doc per durable machine finding (hotspots, traps,
root causes) — git-tracked in each machine's FORK, never upstream (upstream
carries only README + TEMPLATE; `scripts/findings_lint.sh --upstream` asserts
purity). At the START of any cleanup or measurement session, read the active
findings (`scripts/safety_check.sh --findings`). When you discover a new
hotspot/trap, add BOTH a findings_wiki doc (knowledge, fork commit) and a
safety.local.json rule when enforcement applies — cross-linked. Keep findings
commits separate from code commits so code can be cherry-picked upstream.
