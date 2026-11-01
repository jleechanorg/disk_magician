# disk_magician — agent instructions

## One operational entry point — `diskm` (hard)

Drive all disk operations through the Disk Magician CLI: diagnosis, history,
status, cleanup, safety checks, and scheduled maintenance. Reuse an existing
subcommand first. If a capability is missing, extend the same CLI and test its
dispatch, safety gates, and outcomes; never invent an ad-hoc runner, parallel
workflow, or separately operated script. Existing scripts are implementation
helpers behind the CLI, not additional interfaces agents must discover.

The desired public name is `diskm`. The current packaged executable is
`disk-magician` (`disk_magician.cli:main`); use that verified entry point until
`diskm` is registered as another name for the same implementation. Do not add
a second dispatcher or a shell-only alias that scheduled jobs cannot use.
New operational commands and scheduler integrations must use this shared
dispatch. Migrate legacy direct-script schedules with behavior and safety
checks; their current existence is not permission to add more. Build, package,
and isolated test harnesses may call internal files directly.

## Fast-Path Execution Protocol — `<10s` Zero-`du` Triage -> Parallel `flash` Cleanup (hard)

When the user invokes `/diskm`, asks why disk space is low, or requests a disk cleanup, **start working within 10 seconds** without launching a 15-minute `diskm audit` whole-disk `du` walk first:

1. **Step 1 (`<10s` Zero-`du` Triage — run in parallel in a single turn)**:
   - `df -h /System/Volumes/Data /Volumes/diskm-scratch /System/Volumes/VM` (macOS) or `df -h / ~/Scratch` (Linux)
   - `diskm check-launchd-fleet` (macOS fleet liveness)
   - `diskm reclaim-ledger --read-existing` (instant pre-computed per-host reclaim ledger; never `--stdout` first)
   - `diskm history growth-top10 --days 7` (instant 7-day floor + top-10 growing buckets from git-backed snapshot history)
2. **Step 2 (Immediate Parallel `flash` Subagent Cleanup)**:
   - Do **not** run all 22 categories serially in one foreground shell when reclaiming large space (`100–300+ GiB`), and do **not** start with `cleanup_dev_caches.sh` (which walks `~/Library/Caches` while holding `.owner-mutation.reuse-lock`).
   - Instead, dispatch **parallel `flash` subagents** across non-contending high-yield lanes:
     - **Lane A (Scratch Volume, 20–150+ GiB)**: `diskm scratch-prune --clean` (`scripts/cleanup_scratch_top_level.sh --clean`)
     - **Lane B (Worktree Slimming -> Deps -> Dormant Worktrees, 30–180+ GiB)**:
       1. `WORKTREE_APPROVED=1 diskm slim-worktrees --clean` (`scripts/slim_worktree_checkouts.sh --clean`)
       2. `WORKTREE_APPROVED=1 diskm cleanup-worktree-deps --clean` (`scripts/cleanup_worktree_deps.sh --clean`)
       3. `WORKTREE_APPROVED=1 diskm cleanup-worktrees --clean` (`scripts/cleanup_worktrees.sh --clean`; shard across `--repos` when >200 worktrees)
       4. `WORKTREE_APPROVED=1 diskm cleanup-worktree-venvs --clean`
     - **Lane C (Containers, Browser Clones & Cloud Caches, 20–80+ GiB)**:
       - `diskm cleanup-colima --clean`, `diskm cleanup-xcode --clean`, `diskm prune-aside-sessions --clean`
       - `CODE_SIGN_CLONES_APPROVED=1 diskm cleanup-code-sign-clones --clean`
       - `FILEPROVIDER_EVICT_APPROVED=1 diskm evict-fileprovider --clean`
     - **Lane D (Agent State & SQLite Vacuum, 5–20 GiB)**:
       - `diskm vacuum-hermes-state --clean`, `diskm cleanup-codex-db --clean`, `diskm cleanup-antigravity-brain --clean`, `diskm cleanup-tmp --clean`
3. **Step 3 (Zero-Reclaim / Silent-Preservation Diagnostic Rule)**:
   - Never report *"canonical stack is exhausted"* when free space is still below target. If a cleaner exits `0` with `0 B` reclaimed, inspect the skip breakdown (`kept:lease-busy`, `ao-owned-or-unknown`, `kept:admin-unknown`, `kept:recent-activity`, `dirty-or-untracked`) and verify `~/.disk_magician_state/worktree_leases/.owner-mutation.reuse-lock` is not wedged before concluding nothing is reclaimable.

## Agent Scratch placement (Mac and Linux) — optional quota-bounded Scratch volume

Single source of truth: `.agents/skills/scratch-space/SKILL.md` (`~/.claude/skills/scratch-space/SKILL.md`).
For disposable build output, test fixtures, ad-hoc helper files, and evidence on both macOS and Linux, resolve paths through `diskm` and standard scratch environment variables:
- **Repo build & evidence directories**: Allocate via `diskm scratch-new <repo-path> <purpose> --kind build` (or `--kind evidence`).
- **Ad-hoc helper files, logs & ephemeral scripts**: Resolve via `diskm scratch-dir [subpath]` (or `~/.claude/skills/scratch-space/scripts/scratch-dir.sh [subpath]`).
- **Default environment variables**: Pre-exported in shells and agent environments: `DISKM_SCRATCH` (host Scratch volume root), `CLAUDE_CODE_TMPDIR` (`${DISKM_SCRATCH}/tmp`), `PYTEST_DEBUG_TEMPROOT`, and `BASH_ENV`.
- **Dedicated Scratch volumes**:
  - **macOS**: `/Volumes/diskm-scratch` (APFS quota-bounded volume, default/recommended 200 GiB).
  - **Linux**: `~/Scratch` / `/home/<user>/Scratch` (sparse `ext4` quota-bounded volume mounted via `fuse2fs` or `native` loop mount, default/recommended 200 GiB).

Before allocation, `diskm` checks `diskm volume path scratch` (using `~/.config/disk-magician/config.json`
by default or `DISK_MAGICIAN_CONFIG`), falling back to `/tmp/<repo>/...` when no
Scratch volume is provisioned. Let `scratch-new` perform admission and register
the producer lease; add `--owner-pid PID` for the actual long-lived producer when
needed. Consumers and detached children must retain their own existing producer
leases.

Users and operators setting up a workstation or CI host are encouraged to
optionally partition/provision a dedicated Scratch volume via
`diskm setup --scratch [--quota-gb 200]` (or interactively during `diskm setup`).
This isolates disposable agent and CI artifacts so they cannot exhaust host free
space. Scratch volumes are automatically trimmed from 70% down to 50% usage
while strictly preserving a 64 MiB `.diskm-ballast` emergency reserve and
48-hour recency, live-PID, and active-lease protections.

Use the returned artifact directory rather than inventing paths under
`/Volumes/diskm-scratch` or `~/Scratch`. A registered but unavailable, full or
mismatched volume refuses new work; report that result without writing beneath an
unmounted mountpoint or silently routing the same request to host temp. This opt-in
is the exception to the general `/tmp` scratch-location rule, not an exception to
admission, lease, identity or deletion safety.

Git worktrees still use `~/.worktrees` through `diskm worktree-new`; tool profiles,
transcripts, credentials and mutable state stay in their existing homes. Durable
human-readable reports stay in `~/roadmap`; publish evidence that must survive
reclaim through the established evidence path. Do not remap global `TMPDIR`,
replace `/tmp`, move existing user data or treat Scratch as durable storage.

## Lightweight PR Workflow (/prw) — Internal Tool Contract

Because `disk_magician` is an internal host-maintenance tool, it opts into a **lightweight `/prw` contract** (per `~/.claude/skills/pr-workflow-manager/SKILL.md` § "One operational contract"):
- **No multi-stage title/label ceremony**: Do not use `[Stage 1]`..`[Stage 5]` title prefixes or multi-reviewer `/advice`, `/web-advice`, or `/er` quorum waits unless explicitly requested by the user.
- **Required Lightweight `/prw` Gates**:
  1. **Package Sync & Version Bump**: Run `bash ./disk_magician.sh sync-package-tree --check` and `bash scripts/check_version_bump.sh origin/main` (or `./disk_magician.sh check-version`) whenever packaged code/scripts/config change.
  2. **Targeted Validation & `/green`**: Run the targeted unit/shell tests covering the changed files locally, ensure `mergeable == MERGEABLE`, and verify GitHub Actions (`Test and lint` + `Evidence Gate`, or a documented local-equivalent receipt if CI is queued/running >10 minutes per `~/.claude/skills/pr-green-definition/SKILL.md`).
  3. **Evidence Gate (`Claim class: tooling` or `documentation-only`)**: Include an `## Evidence` section in the PR body that passes `python3 .github/scripts/validate_evidence.py` (`**Claim class:** tooling` or `documentation-only`, `**Verdict:** PASS`, `**Commands and results:**`, `**What this proves:**`, `**What this does not prove:**`). Use `Claim class: production` (with gist + head SHA) only when claiming a live production state change.
  4. **Code Standards (`/cs`)**: Run the 4-lane `/cs` check (`Ponytail`, `ZFC`, `ZFC leveling`, `Root-cause-first`) only when a PR adds `>150` production lines.

## Investigation methodology — fleet, existing ledger, floor/buckets, bounded audit

Disk-fill investigations in this repo MUST follow a fixed pre-analysis
sequence (added 2026-07-30 after four "200 GiB does not exist" misses that
underestimated cumulative-reservoir growth):

-1. **Verify disk_magician's own launchd fleet is alive BEFORE trusting any
    floor/history number.** Run `./disk_magician.sh check-launchd-fleet`
    (also runs automatically as the first section of `audit`/`clean`).
    Root cause (2026-09-06): up to 16 of this repo's launchd jobs — including
    the `sweeper-health` watchdog whose entire purpose is to catch exactly
    this — were found silently unloaded for 6+ days (mass event, zero visible
    error; a malformed plist missing its `<dict>` wrapper is invisible even
    to `launchctl list`). This has recurred under at least 3 different root
    mechanisms (2026-07-22 shlock bug, 2026-07-29 interval-elapsed
    false-negative, 2026-09-06 mass plist corruption). On 2026-09-06 the fleet
    was also observed **actively flapping** — jobs transitioning
    loaded/unloaded within tens of seconds to minutes of a fresh
    `install_launchd_sweepers.sh` run, with plists confirmed valid throughout
    and `sfltool dumpbtm` showing "enabled, allowed" disposition (i.e. macOS
    Background Task Management is not the one disabling them). The exact
    external trigger was NOT pinned down in that session — repair is not
    durable; if the disk-fill pattern recurs shortly after a repair, re-run
    `check-launchd-fleet` rather than assuming one clean run means it stays
    clean. **Pinned 2026-09-11:** the corruption mechanism is
    `plutil -extract <key> <fmt> <plist>` run WITHOUT `-o -` — plutil then
    overwrites the plist with the extracted value (first byte becomes `[`/`{`),
    and the auto-repair reinstall is what makes it look like flapping. Agents
    inspecting a live plist MUST use `plutil -extract <key> raw -o - <plist>`
    or `plutil -p <plist>`; never the bare form. If the fleet flips
    healthy→corrupt inside a session, compare plist mtimes to your own
    commands first
    (`findings_wiki/2026-09-11-plutil-extract-in-place-rewrite-corrupts-plists.md`).
    **Do not assume "installed" means
    "running."** If the fleet check reports anything unhealthy, say so as the
    PRIMARY finding before any accounting — a floor computed from a dead
    collector is not a floor, and the underlying automation gap is the actual
    answer to "why do I have to keep re-explaining this," not a symptom to
    route around. Repair: `bash scripts/install_launchd_sweepers.sh`.

0. **Consult prior memory files before live probes & recognize full disk readability.**
   Empirical verification on 2026-08-30/31 confirmed that **ALL user-data and TCC
   paths (`MobileSync`, `Mail`, `Messages`, `Containers`, `Group Containers`, `Safari`,
   `HomeKit`, `PersonalizationPortrait`, `Suggestions`) ARE 100% READABLE AND ACCESSIBLE**
   to the scanner with zero permission walls (total user TCC data is ~4.6 GiB).
   **Stop assuming parts of the disk are unreadable or that a 200+ GiB "TCC permission wall"
   exists.** The system residual floor consists of active browser code_sign_clones
   (`/private/var/folders/.../X/`), APFS local snapshots (`com.apple.os.update-...`),
   and system daemon state (`/private/var/db`). Measure directly with bounded timeouts.

0b. **Read the existing per-host reclaim ledger** (`diskm reclaim-ledger --read-existing`)
    before any deeper live probe. The existing state resolver selects the Mac
    configured `~/.disk_magician_backup` or Linux XDG state root; do not hardcode
    a different host's path. This reads `<state-repo>/reclaim/known-reclaim-dirs.md`
    without regenerating history or writing state. `--stdout` regenerates a preview
    and is NOT the cheap read-first path. Missing/unreadable/stale reports are
    explicit evidence gaps, never evidence of no growth; diagnosis may continue.
    `audit` prints fleet health and this report synchronously before its scanners.
    Check current CPU/RAM/I/O and the existing resource gate before starting the
    bounded deeper audit; defer heavy scans when the host is saturated. The report
    it lists this machine's cleaned roots, fast regrowers, growth vs floor and
    uncovered rows, with a stale-ledger banner. Machine-specific paths and sizes
    belong there, never in repo docs. It is a report over `monitored_dirs`
    (`config/config.json`, the one list of directories to check), not a second
    list: add roots it flags as not-monitored to `monitored_dirs`.

1. **Find the last-week floor** before proposing anything. The floor is
   the **lowest `df used` in the most recent ~14 daily snapshots** (NOT
   proxies, NOT a single fresh `du`, NOT current df). Pull it from the
   git-backed ledger in `~/.disk_magician_backup/ledger/topdown-5g.json`
   via `git -C ~/.disk_magician_backup log -- ledger/topdown-5g.json | head`
   then `git show <sha>:ledger/topdown-5g.json`. State the floor date +
   value and the gap (current used − floor used) before any other
   measurement. **The gap-to-floor grounds every proposal.**
   **Coverage gate (hard):** never treat `disk_snapshot.json`'s
   `disk_used_gb` as a floor when `snapshot_coverage_pct` (or
   `snapshot_metadata.coverage_pct`) is **< 70%** — low-coverage mins
   are bogus (e.g. 714 GiB at 5.5% coverage). Prefer the ledger floor when
   `ledger/topdown-5g.json` has a commit within **48h**; if the ledger is
   older, say so and do not invent bucket deltas from stale ledger HEAD.
   Live snapshot path:
   `~/.disk_magician_backup/snapshots/disk_snapshot.json` (legacy
   `backup/<host>/` is frozen — bead `disk_magician-q9x`).

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

## Proactive floor deltas — unprompted on every disk turn (hard)

Whenever the disk is the subject (status, "how's the disk", cleanup, a
free-space alert, an investigation), do this **without being asked**, then act:

1. Compute the **7d and 30d floors** (lowest used) and report `current − floor`
   for each, plus per-path deltas where buckets exist.
2. Act on the actionable deltas through `diskm` scripts within the safety
   guidelines, and report what was reclaimed (measured by `df`, not `du`).
   Ask only before a delete that falls outside the guidelines.
3. **Never stop at "no valid floor".** If `diskm history diff --days N` reports no
   valid ledger, fall back, label the source, and keep going:
   - used-space floor: daily minimum of `host_disk.used_kb` in
     `~/.disk_magician_state/disk_observer.jsonl{,.1,.2}` (df-only; report the
     earliest date it covers if that is shorter than N days);
   - bucket deltas: committed snapshots in
     `git -C ~/.disk_magician_backup log -- snapshots/disk_snapshot.json`, only
     where `snapshot_coverage_pct >= 70`.
   A missing or invalid ledger is itself a finding: say so first and name the
   fix (the root frontier run must reach `mode=complete`).
4. A daily minimum can be a transient dip (a purge in flight); report the
   minimum and the typical daily minimum, not the minimum alone.
5. Check the producer rate before grinding reclaim: if free space falls faster
   than you reclaim (Colima datadisk allocation is the usual one), stop the
   producer first (ask before pausing CI runners) rather than loop.

## 6-tier routine cleanup stack — unified safe maintenance

When cleaning or recommending disk cleanups on this workstation, execute the canonical 6-tier stack via `./disk_magician.sh clean` (or `--routine`), or fan out the tiers in parallel across `flash` subagents for large reclaims. Do not guess, write ad-hoc scripts, or require user steering to identify the primary high-yield cleanup targets:

1. **Tier 1: Scratch Volume, Developer Caches & Temp (Safe, 10–150+ GiB)**:
   - Scripts: `cleanup_scratch_top_level.sh` (`scratch-prune`), `cleanup_tmp.sh`, `cleanup_pr_scratch.sh`, `cleanup_llm_inspector.sh`, `cleanup_dev_caches.sh`
   - Targets: top-level and `tmp/` Scratch entries older than 48h floor (preserving `.diskm-ballast`, live PIDs, and active leases), `/private/tmp` ephemera, and compiler/npm/cargo/test caches (`cleanup_dev_caches.sh` runs last so its `~/Library/Caches` walk does not hold `.owner-mutation.reuse-lock` ahead of fast cleaners).
2. **Tier 2: Xcode & Simulator Caches (Safe, 10–50+ GiB)**:
   - Script: `cleanup_xcode.sh`
   - Targets: rebuildable `~/Library/Developer/Xcode/DerivedData` and CoreSimulator temp/caches.
3. **Tier 3: Container VM & Docker Disk Reclaim (Safe, 20–80+ GiB)**:
   - Script: `cleanup_colima.sh`
   - Targets: Colima VM Docker prune (unused images/containers) + in-VM `fstrim -av` to shrink the host sparse disk (`~/.colima/_lima`).
4. **Tier 4: Browser Sessions, Code-Sign Clones & Cloud Caches (Safe / Gated, 10–60+ GiB)**:
   - Scripts: `prune_aside_sessions.sh`, `cleanup_code_sign_clones.sh` (requires `CODE_SIGN_CLONES_APPROVED=1`), `evict_fileprovider.sh` (requires `FILEPROVIDER_EVICT_APPROVED=1`)
   - Targets: stale Aside browser sessions (`~/.aside/u/*/sessions/` >7d/14d) with static asset hardlink deduplication, dead macOS `code_sign_clone` bundles in `/private/var/folders/.../X`, and evictable local CloudStorage FileProvider caches (`~/Library/CloudStorage/*`).
5. **Tier 5: Agent State Compaction, SQLite Vacuum & Rotated Logs (Safe, 5–20 GiB)**:
   - Scripts: `cleanup_antigravity_brain.sh`, `cleanup_codex_db.sh`, `vacuum_hermes_state.sh`, `cleanup_codex_documents.sh`, `cleanup_supervisor_logs.sh`, `cleanup_uv_cache.sh`
   - Targets: losslessly compacts completed Antigravity task logs and transcripts (>=7d), vacuums `~/.codex` and `~/.hermes/state.db` SQLite databases, prunes dormant Codex task documents (>=7d), prunes stale rotated supervisor logs, and prunes orphaned uv-tool build wheels.
6. **Tier 6: Worktree Slimming, Dependency Stripping, Dormant Worktrees & Venvs (Safety-Gated, 30–180+ GiB)**:
   - Scripts (run in order): `slim_worktree_checkouts.sh` (`slim-worktrees`), `cleanup_worktree_deps.sh` (`cleanup-worktree-deps`), `cleanup_worktrees.sh` (`cleanup-worktrees`), `cleanup_worktree_venvs.sh` (`cleanup-worktree-venvs`), `cleanup_claude_state.sh`
   - Targets: converts dormant worktrees (>=7d) to sparse root-only checkouts (`slim-worktrees`), strips rebuildable `node_modules`/`target`/`.mypy_cache` (>=3d), removes merged/pushed/detached-on-origin dormant worktrees (>=3d), and strips `.venv`/`venv` (>=7d).
   - **GATING**: Requires `WORKTREE_APPROVED=1` in environment to execute `--clean`. Strictly enforces recency, live-cwd, C14 lease, hidden-state, and AO ownership (`C` container vs `P` project `worktreeDir`) gates.

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
approval, merge gates, `WORKTREE_APPROVED` for young worktrees.

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

**Amended 2026-10-08 (user decision):** `scripts/cleanup_worktrees.sh` now uses a
3-day floor for ALL worktrees (`safety_worktree_floor_days`; the
`worktree_min_stale_days` config key may only raise it). Every other condition
below is unchanged (clean, no unpushed commits, not live-cwd, not locked, not
AO-owned, merged or gh-verified). The venv strip, Claude-state and hygiene
scripts keep the 7-day floor. Read "7 days" below as 7 for those scripts and 3
for `cleanup_worktrees.sh` and `cleanup_worktree_deps.sh` (dependency dirs only:
`node_modules`, `target`, `.mypy_cache`). Those two read `worktree_min_stale_days`
(default 3), not `min_stale_days`, so a machine-local `min_stale_days: 7` does not
raise their floor; set `worktree_min_stale_days` to do that. For
`cleanup_worktrees.sh`, every removal candidate at any age runs the hidden-state
(secret files, assume-unchanged) and AO/live-cwd gates. `cleanup_worktree_deps.sh`
only strips rebuildable dependency dirs and does not run the hidden-state check;
it relies on fail-closed recency, live-cwd, AO and `safety_gate` checks.
`cleanup_worktrees.sh` also treats a clean worktree as removable when its branch tip is
already on `origin` (live `git ls-remote` equals HEAD; any failure keeps it preserved), since
the branch ref and the remote copy both survive. A clean DETACHED worktree is removable
the same way when its HEAD is an ancestor of a tip origin advertises live (`ls-remote`
heads and PR heads, never stale remote-tracking refs; failure or timeout keeps it);
the ledger and deletion-log lines carry `reason=detached-on-origin`.

**A git worktree touched within the last 7 days is PROTECTED.** No script,
sweeper, launchd job, or agent in this repo may delete, archive, strip
(including its `venv/`), or `git worktree remove` it — regardless of merged
PR, clean status, zero-ahead, or disk pressure. 7 days is a floor, not a
target; `safety_min_stale_days` may raise it, never lower it.

**Sole exception (bead `disk_magician-plf`, user-directed):** in
`scripts/cleanup_worktrees.sh` only, and only while its own floor is the
default 7 days, a worktree that canonical `worktree_is_recently_active` reports
as not active within 3 days may be ELIGIBLE when ALL hold: `git status
--porcelain --untracked-files=normal --ignore-submodules=none` is empty (no
tracked changes, no untracked files; `normal` reports an untracked directory as
one `??` entry, which gives the same empty/non-empty answer as `all`);
no index entry is assume-unchanged or skip-worktree; no ignored secret-like
file exists (case-insensitive `.env*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`,
`id_rsa*`/`id_ed25519*`/`id_ecdsa*`/`id_dsa*`, `.npmrc`, `.netrc`, `*credentials*`, `secrets*`); HEAD is an ancestor of
main or matches a gh-verified MERGED PR head (bead `ueh`); no live process has
a cwd inside it; it is not locked; and it is not under an AO worktreeDir
(`*ao/data/worktrees/*` or the AO config, which, if present, must be readable). Any
unknown keeps it protected. `DISK_MAGICIAN_MERGED_WORKTREE_MIN_DAYS` may
raise the 3, clamped to [3,7]; nothing else may lower the 7-day floor, apart from the override below.

**Sole override to the floor (user decision 2026-10-20, "remove the overly strict
gate"):** `scripts/worktree_remove_hook.sh` (and nothing else) accepts the env-only
opt-in `DISK_MAGICIAN_REMOVE_HOOK_RECENCY=days:N` (N >= 7) or `minutes:N` (N >= 60).
Anything lower or malformed falls back to the default `days:7`. It applies only to a
clean, pushed, non-live-cwd, non-AO linked worktree, and the owner-null lease relax in
`artifact_removal_verdict` requires clean + pushed + non-AO + idle >= max(caller
floor, 60 min), failing closed on an unreadable AO config. An active override is
written to `worktree_guard.log` and to the deletion-log line (`recency=<spec>`).
No config file, flag, or other script may lower the floor this way, apart from the
second override below.

**Second override (user decision 2026-10-22, "do worktrees not modified last 12hr"):**
`scripts/cleanup_worktrees.sh` (and nothing else besides the hook above) accepts the
env-only opt-in `DISK_MAGICIAN_WORKTREE_FLOOR_HOURS=N` (N >= 12), which lowers its
non-AO recency floor to N hours via `worktree_is_recently_active_minutes`. Lower or
malformed values (including `6` and zero-padded) fall back to the day floor; AO
worktrees keep 7 days. Every other gate still applies at any age: clean, no hidden
index state or ignored secrets, HEAD on main / gh-verified merged / live `origin` tip,
no live cwd, not locked, not AO-owned, unmeasurable recency preserved. An active
override is written to `worktree_guard.log` (audit-first; an unwritable log keeps the
day floor), the ledger line, and the deletion-log line (`recency=hours:N`).

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

## Machine-specific state repo — where the ledger lives (read this first in any disk investigation)

Every machine keeps its own **git repo** of measured state. It is separate from this
code repo, has its own remote (`jleechanorg/disk-magician-state-<host>`), and is the
only place the per-host ledger, snapshots and config copy exist.

| | |
|---|---|
| Find it | `./disk_magician.sh state status` → prints path, commit count, remote |
| For scripts | `python3 scripts/resolve_state_repo_path.py` (prints the winning path) |
| Linux (XDG default) | `$XDG_STATE_HOME/disk-magician` → `~/.local/state/disk-magician` |
| Mac (grandfathered) | `~/.disk_magician_backup` |
| Identity | `MACHINE` (hostname, created, tool) at the repo root |
| Remote lifecycle | `diskm state remote <url>` (set), `diskm state push` (publish) |

Precedence (design: `roadmap/2026-07-21-generic-split-state-repo-design.md`):
`DISK_MAGICIAN_STATE_REPO` env → `state_repo_path` key in the winning config →
XDG default.

### What diskm reads from it

| Path | Read by | Contents |
|---|---|---|
| `reclaim/known-reclaim-dirs.md` | humans + any investigation | **the ledger**: cleaned roots (C), fast regrowers (D), growth vs floor (B), uncovered/needs-decision (A). Regenerate with `diskm reclaim-ledger` (`--stdout` previews) |
| `snapshots/disk_snapshot.json` | `diskm history`, `disk_status.py`, floor math | 2-hourly used/free + per-`monitored_dirs` sizes; coverage-gated (≥70%) |
| `ledger/topdown-5g.json` | `diskm history diff`, `growth-top10`, ledger freshness | ≥5 GiB buckets from a **complete** `diskm frontier` run; empty until one succeeds |
| `config/config.json` | config chain fallback | copy — see the trap below |

### Trap: the state repo's config copy is overwritten every snapshot

`scripts/snapshot_commit.sh` (`cp "$CFG" "$STATE_DIR/config/config.json"`) refreshes
that copy from the **winning config** on every run. Editing the state-repo copy
therefore silently reverts within two hours (observed 2026-10-22: eight
`monitored_dirs` additions were lost this way).

The winner is chosen by `scripts/resolve_config.py` —
`DISK_MAGICIAN_CONFIG` → `~/.config/disk-magician/config.json` → state repo →
`config.json`/`config.json.template`. **Add monitored directories to the winning
file** (on this host `~/.config/disk-magician/config.json`), and `monitored_dirs` is
the one list the reclaim ledger reports over — the ledger's job is to flag growers
that are missing from it.



**Skill (single source of truth):** `~/.claude/skills/fix-completion-deploy/SKILL.md` — durable fix promotion, origin-main verification, tracked templates, and deployed-revision proof.

1. The 30-min snapshot launchd job (`com.jleechanorg.disk-magician`) runs the
   **uv-tool-packaged copy** at
   `~/.local/share/uv/tools/disk-magician/.../disk_magician/`, built from
   `src/disk_magician/` — NOT the repo root files.
2. The snapshot, frontier-nightly, pressure-sweep, tmp-scratch, Claude-state,
   Codex-vacuum, and residual-drilldown templates use the installed `diskm`
   entry point. Other
   jobs still use **repo-root scripts** (`@REPO_ROOT@` substitution); inspect
   `diskm status --json` for their actual installed paths.

After changing root scripts: run `scripts/sync_package_tree.sh` (use
`--check` in review), **bump the version in pyproject.toml** (uv caches
wheels by version), then run `tools/deploy_uv_tool.sh` from a clean checkout
exactly matching `origin/main`. The guard checks both CLI names and package
hashes before atomically publishing `~/.disk_magician_state/deployed.json`.
Verify the deployed tree and scheduled receipts before claiming production behavior
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
- **Deletion log is the reclaim list.** Every deletion path must log to
  `~/Library/Logs/disk-magician-deletions.log` via `deletion_log`; before any
  disk investigation or cleanup, read this machine's reclaim ledger
  (`diskm reclaim-ledger --read-existing`; regenerate separately only when needed
  with `diskm reclaim-ledger`; reading guide `docs/known-reclaim-dirs.md`) and the last
  7 days of that log: those directories are the known growers; re-clean them
  first. Log from a removal primitive (`quarantine_remove`, `wrh_remove_now`,
  `strip_dir`, `rm_logged`), not per script; a caller that already logs the
  same path sets `DM_DELETION_LOGGED=1` on that one call.
  `tests/test_deletion_log_coverage.sh` and T18 in `tests/test_removal_sites.sh`
  fail when a deleter has no logging route.

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
