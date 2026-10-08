# Disk-fill prevention and automatic periodic cleanup via launchd

Date: 2026-09-23
Status: Design (planning only — no implementation in this document)

## Problem

The disk refills every 7–10 days (+103 GiB in the 7 days ending 2026-09-22,
~15 GiB/day, against ~150 GiB of headroom). The producers are 0–7-day agent
artifacts that no existing sweeper enumerates:

| Producer | Size | Root | Existing coverage |
|---|---|---|---|
| `$TMPDIR` agent scratch (mktemp from `/advice`, PR-review, completion runs) | 28.2 GiB, ~3.8k dirs born 09-15..09-22 | `/var/folders/.../T` | `cleanup_tmp.sh` only walks `/private/tmp` (bead d45) |
| `~/.claude/state` per-task full repo clones (incl. `node_modules`) | 34.1 GiB, +15.6 GiB since 09-15 | `~/.claude/state` | No reclaim path at all (bead isw) |
| Chrome/Aside `code_sign_clone` per-relaunch copies | 27 GiB (15 clones since 09-18 reboot) | `$DARWIN_USER_TEMP_DIR/../X/*.code_sign_clone` | `cleanup_code_sign_clones.sh` exists but is **not on any launchd schedule** (bead jui) |
| New worldarchitect.ai worktrees | 9.3 GiB | various | Covered by 7-day-floor `cleanup_worktrees.sh`, but only after 7 days |
| Diffuse Library caches | ~11 GiB | various | Tier 1/5 dev-cache sweeps, partial |
| Colima VM RAM pressure driving host swap onto macOS's own `/System/Volumes/VM` system volume (24 GiB Colima VM RAM on 48 GiB host — clarification: this is host-side `vm.swapusage`/`/System/Volumes/VM`, not swap measured inside the Colima Linux guest itself) | 35 GiB (fixed manually 09-22, bead 8to) | `~/.colima/_lima` (VM RAM config); `/System/Volumes/VM` (host swap volume) | Detected manually; no recurring detection |

Existing sweepers are age-gated (24h/7d) and root-limited by design (correct
safety posture — see repo `CLAUDE.md` worktree 7-day rule and never-delete
list) but that same design means a routine `clean` run found **0 eligible
bytes at 99% full**, because the actual growth is concentrated in roots and
age bands the fleet doesn't look at yet. The published ledger
(`~/.disk_magician_backup/ledger/topdown-5g.json`) has been stale since
2026-08-30 (beads 4y6, zyn), so this was invisible until a manual audit.

## Non-goals

- Touching never-delete paths: `~/.codex/sessions*`, `~/.codex/state*.sqlite`,
  `~/.codex/log`, `~/.claude/projects`.
- Weakening the 7-day worktree recency floor (`scripts/lib/worktree_recency.sh`).
- Re-deriving the root-cause numbers above (cited from the 2026-09-22/23
  investigation, not re-measured here).
- Editing `~/.codex/AGENTS.md` (shared policy — requires the semantic-signoff
  gate it defines itself) or `~/.claude/settings.json` (global user config)
  from within this design's own Task list — both are scoped as their own
  beads (`disk_magician-codex-agents-md-scratch-policy-2gp`,
  `disk_magician-claude-settings-stop-hook-wiring-if9`), approved by the
  user 2026-09-24 ("finish all") and executed via those beads' own
  contracts, not as numbered Tasks in the implementation plan.
- Rearchitecting the ledger/ frontier-BFS coverage system (zyn/4y6) — treated
  as a parallel, already-tracked effort; this design only adds a
  lightweight freshness alert so detection isn't blind in the meantime.

## Current state (must sequence on top of, not duplicate)

**Round-4 update (2026-09-24, verified live via `gh pr list --state all
--json number,state`): all 8 PRs below (#69–#76) are now MERGED to
`origin/main`.** The round-3 `mergeStateStatus` snapshot immediately below
is preserved for provenance only. A round-4 dependency independent of
these merges: `scripts/lib/scratch_budget.sh` as merged in #71 was
rejected by both reviewers over four safety gaps and was re-hardened on
local branch `fix/scratch-safety-hardening` by a sibling lane. **Round-5
update (2026-09-25): merged as PR #78** (`fix: mandatory sandbox guard,
preserve unmeasurable mtime, du arithmetic`, merge commit
`27df9d93b77dc5d89ea035bb2a10cd4357a554a5`) — confirmed live via `gh pr
list --state merged --head fix/scratch-safety-hardening --json
number,mergedAt,mergeCommit`. B4b's dependency (below) is now satisfied;
re-verify live before executing rather than trusting this note, in case
`origin/main` moves again.

Seven draft PRs were open as of 2026-09-23. `gh pr list`'s `mergeable`
field (conflict-free check only) reported `MERGEABLE` for all seven, but
the more accurate `mergeStateStatus` (includes required-check state)
reported **#69, #70, #73 CLEAN; #71, #72, #74, #75 BLOCKED**, verified live
2026-09-23 during
`/advice` review. #73 (bead cse, the version-monotonicity gate fix) was
the unblocking dependency — main was red for any version-bumping PR until
#73 merged, which was every PR in this plan except #69/#70/#73/#75. Actual
land order (round-4, confirmed via `gh pr list --state all --json
number,mergedAt`): #73 and #75 merged first (2026-09-23 19:05), then #72,
#74 (19:11–19:17), then #70, #69, #71 (19:21–19:33), then follow-up #76.
All 8 are merged.

| PR | Bead | Adds | Status (2026-09-24) |
|---|---|---|---|
| #73 | cse | `check_version_monotonic.py` first-parent scan fix | MERGED |
| #69 | — | `plutil -extract` corruption fix + 30d disk-recurrence report | MERGED |
| #75 | 949 | Fix flaky `test_git_unsaved_work_protection` | MERGED |
| #70 | jui | `cleanup_code_sign_clones.sh` reclaims per-launch **children**, not just top-level clones | MERGED |
| #71 | d45/ka4 | `scripts/lib/scratch_roots.sh` (bash-array registry) + `scripts/lib/scratch_budget.sh` (size-budget+age eviction), wires `$TMPDIR` into `cleanup_tmp.sh` and `pressure_sweep.sh` | MERGED — round-4 dependency note above: `scratch_budget.sh`'s eviction logic needed re-hardening on `fix/scratch-safety-hardening` before Task 4b could enable it; **round-5 (2026-09-25): merged as PR #78** (`27df9d93b77dc5d89ea035bb2a10cd4357a554a5`) — gate satisfied |
| #74 | isw | `scripts/cleanup_claude_state.sh` (gated `~/.claude/state` sweeper), wires into `disk_audit.sh` | MERGED |
| #72 | 8to | `config/sweeper_roots.txt` (flat-text registry) + `scripts/check_uncovered_roots.py/.sh` + Colima swap/VM volume tracking in `disk_snapshot.sh` | MERGED |
| #76 | — | `check_version_monotonic.py` follow-up (cse), stops reading named branch tips | MERGED |

Two of these (#71, #72) each introduce a **separate root registry** —
`scratch_roots.sh` (bash array, consumed by `cleanup_tmp.sh`/`pressure_sweep.sh`)
and `config/sweeper_roots.txt` (flat text, consumed by `check_uncovered_roots.py`).
Neither PR depends on or knows about the other. This design's job is to (a)
land all seven as-is without touching their branches, (b) schedule what they
build but haven't scheduled yet, (c) unify the two registries in a follow-up
PR once both are on `main`, and (d) close the specific gaps neither PR
covers: producer-side prevention, the code-sign-clone launchd schedule, the
`~/.claude/state` launchd schedule, and the deploy step.

Existing launchd fleet (16 jobs; confirmed live via `check_launchd_fleet.sh`
job list and `launchd/*.plist*`):

- `com.jleechanorg.disk-magician-pressure-sweep` — **every 30 min**
  (`StartInterval=1800`), runs when `df` free < `DISK_MAGICIAN_PRESSURE_THRESHOLD_GB`
  (default 40 GiB) OR Colima/`/private/tmp` exceed their own ceilings; today
  runs `cleanup_tmp.sh --clean --large` then `cleanup_colima.sh --clean`.
- `com.jleechanorg.disk-magician-tmp-scratch` — every hour (`StartInterval=3600`).
- `com.jleechanorg.disk-magician-worktree-hygiene`, `-drilldown`,
  `-frontier-nightly`, `-frontier-root`, `-observer`, `-downloads-evidence` —
  repo-root scripts, calendar/interval per template.
- `com.disk-magician.colima-prune` — `StartInterval=604800` (7d) **plus**
  `RunAtLoad`, because the interval alone rarely accumulates 7 continuous
  days of uptime on a machine that reboots roughly every 2 days (documented
  in the plist itself). Pre-existing, orthogonal issue — not fixed here (see
  Q5 below).
- `com.disk-magician.worktree-venvs`, `-hermes-vacuum`, `-playwright-dedup`,
  `-cursor-logs-watchdog`, `-fsevents-projects`, `-sweeper-health` — Tier
  5/6 and watchdog jobs.

None of these currently invoke `cleanup_code_sign_clones.sh` or (pre-#74)
`cleanup_claude_state.sh`. Per repo `CLAUDE.md`, the 35-min snapshot job runs
the **uv-tool-packaged** copy from `src/disk_magician/`, not repo-root
scripts directly — any change here needs `scripts/sync_package_tree.sh` and
a version bump before it is live in that path.

## Design

### A. Prevention at the producer

**A1. Unified managed-scratch root.** All new ad hoc scratch creation
(`/advice`, PR-review runs, completion runs) should allocate under
`/private/tmp/agent-scratch/<runtime>/<run-id>/` instead of a bare
`mktemp -d` scattered across `$TMPDIR`. Ship a helper library,
`scripts/lib/agent_scratch.sh`, exposing:

```
agent_scratch_create <runtime> <run-id>   # mkdir -p, echoes path
agent_scratch_trap_cleanup <path>          # trap 'rm -rf "<path>"' EXIT INT TERM
```

This is additive (existing `$TMPDIR` coverage from #71 still sweeps
anything outside the new root by age/budget) and gives one namespaced
subtree that a Stop hook (A3) or an explicit `rm -rf` can target precisely,
without touching unrelated `$TMPDIR` entries left by other tools. Register
`/private/tmp/agent-scratch` as an entry in the unified root registry (see
B4) so `scratch_budget.sh`'s size-budget eviction also covers it as a
first-class root, not just as a subdirectory of the generic `$TMPDIR` scan.

**A1b. At least one real producer migration in this repo (round-3
`/advice` finding).** A1 alone ships a helper nothing calls — that is not
prevention, only infrastructure. `scripts/disk_diagnostic.sh` (this
repo's own `mktemp -d -t disk_diagnostic.XXXXXX` + bare `trap ... EXIT`)
is migrated to `agent_scratch_create`/`agent_scratch_trap_cleanup` as this
plan's first concrete migrated producer (Task 8 in the implementation
plan). This does not fix the dominant $TMPDIR volume by itself (that is
B4b's eviction-budget fix) — it proves the managed-root pattern actually
gets adopted by a real caller, not just documented. The `/advice`/verifier-lane
spawning producer is addressed by A2 below (redesigned and approved
2026-09-24 — no longer cross-repo or approval-gated; see A2's own text).

**A2. Verifier/review lanes: worktree instead of full clone (redesigned
2026-09-24, approved).** The `~/.claude/state` growth (+15.6 GiB) was
`git clone` of full repos including `node_modules` per codex/agy verifier
lane. The original framing — "orchestration code that lives outside this
repo (Hermes agent-orchestrator / Claude Code session tooling), so
disk_magician cannot implement this change itself" — was wrong: there is
no separate owning orchestrator repo; the clones are produced by ad hoc
interactive Claude Code/Codex sessions spawning verifier lanes. Round-4
scope (user-approved 2026-09-24, "finish all"):
  - Ship `scripts/lib/agent_worktree.sh` (`agent_worktree_create <label>
    <ref> <repo>`) in this repo — an in-repo helper any such session can
    call instead of `git clone`. **Round-4b correction (2026-09-24,
    independent Codex + Opus review both flagged the same defect):** the
    first draft of this helper reused `agent_scratch_create` (A1) so
    checkouts landed inside `/private/tmp/agent-scratch/...` — but that
    root is subject to B4's size-budget eviction and A3's Stop hook, and
    neither is worktree-aware, so a worktree with unpushed work could be
    deleted well inside the repo `CLAUDE.md` "Worktree 7-day rule (hard)"'s
    protected window. Fixed (round-4b): the helper stopped reusing
    `agent_scratch_create`. **Round-4c correction (2026-09-24, second-round
    Opus re-review): the round-4b default,
    `/private/tmp/agent-worktrees/<label>-$$-$(date +%s)`, was still
    unsafe** — `/private/tmp` itself is scanned one level deep by
    `cleanup_tmp.sh --large`, which runs in production today via
    `pressure_sweep.sh` (no dependency on bead i2o) and would
    archive-then-purge a top-level `agent-worktrees` container after ~4h of
    no file changes anywhere under it (confirmed live: `PRIVATE_TMP_ROOT`
    resolves to literal `/private/tmp`; `agent-worktrees` matches neither
    the `wt_*|worktree_*` unsaved-work guard nor
    `DEFAULT_PROTECTED_TMP_ROOTS`). Fixed: the default moved one more level
    away, to `/private/var/tmp/agent-worktrees`. **Round-6 correction
    (2026-09-25, independent Codex + Opus team-lead-requested closure
    round, both flagged the same gap):** confirmed live via `grep -rn
    '/private/var/tmp' scripts/*.sh scripts/lib/*.sh config/
    launchd/*.template` returning zero *literal path* matches, but that is
    not proof of categorical immunity — `scripts/worktree_hygiene.sh`
    discovers a repo's worktrees via `git -C <repo> worktree list`, which
    is indifferent to the worktree's physical parent directory, so a
    worktree this helper creates against a repo `worktree_hygiene.sh`
    already scans (its own auto-discovery always includes
    `~/projects/worldarchitect.ai`) WOULD be found there regardless of
    living under `/private/var/tmp`. Two things keep this safe today: (1)
    that discovery only applies when the *calling repo* is one
    `worktree_hygiene.sh` scans — disk_magician itself is not, since it
    lives outside `~/projects/`; (2) its own launchd job runs
    report-only (`--skip-push --skip-gh`, no `--execute`) today, so even a
    discovered worktree is not currently auto-deleted through that path.
    Both are properties of the *existing* sweeper's current config, not
    something this bead pair changes or should rely on remaining true
    forever — restated accurately: this root has no sweeper of its own
    and is not registered with `scratch_budget.sh` or the Stop hook, but a
    *repo-discovery-based* sweeper (`worktree_hygiene.sh`) could
    legitimately reach a worktree here in the future depending on which
    repo it's created against and that job's own execute-mode
    configuration — which is actually fine, since that sweeper already
    enforces the correct 7-day floor via `worktree_recency.sh`, unlike the
    B4/Stop-hook risk this whole redesign exists to avoid. Cleanup of this
    root for repos `worktree_hygiene.sh` doesn't already scan is
    explicitly out of scope for this bead pair — a follow-up bead would
    extend its `CLAUDE_WORKTREE_REPOS`/discovery config to cover them.

    **Root-ownership hardening (round-6 addition, both reviewers
    independently flagged this):** `/private/var/tmp` is
    world-writable-sticky (`drwxrwxrwt root:wheel`), so a plain `mkdir -p`
    on a predictable child path does not prove this session created or
    owns it — another local actor could pre-create `agent-worktrees` as a
    directory owned by someone else, or as a symlink into a swept
    location, before this helper first runs. `agent_worktree_create` must
    reject (not silently proceed into) an existing `$AGENT_WORKTREE_ROOT`
    that is a symlink or not owned by the current user, checked with `[[
    -L ]]`/`[[ -O ]]` immediately after `mkdir -p` — see the updated bead
    contracts (`9n1` test case, `2nw` implementation) for the exact
    checks.
    Bead `disk_magician-orchestrator-worktree-not-clone-2nw`, TDD pair
    `disk_magician-9n1`.
  - Document the pattern in `findings_wiki/` as a cross-repo finding
    (bead `disk_magician-findings-verifier-worktree-doc-vct`).
  - The separate, still-gated piece: a machine-wide policy instruction
    telling sessions to actually call the helper instead of `git clone` —
    that is Q8/A3's policy-edit scope (bead
    `disk_magician-codex-agents-md-scratch-policy-2gp`), approved for
    execution but still subject to `~/.codex/AGENTS.md`'s own
    semantic-signoff gate. Do not conflate the two: shipping the helper
    needs no cross-repo approval; telling every session to prefer it does
    require the policy file's own gate.

**A3. Claude Code Stop/SessionEnd hook (wiring approved 2026-09-24).** Ship
the hook *script* in this repo (`scripts/agent_scratch_cleanup_hook.sh` —
removes only `/private/tmp/agent-scratch/<runtime>/<this-session-run-id>/`,
never a bare `rm -rf $TMPDIR`). Wiring it into `~/.claude/settings.json` —
global user config outside disk_magician's ownership boundary (see
`update-config` skill scope and the global MCP-registration-ownership
norm this mirrors) — was originally approval-gated; the user approved
execution 2026-09-24 ("finish all"). Bead
`disk_magician-claude-settings-stop-hook-wiring-if9` performs the
registration (backing up the file first, since it is live shared config).

**A4. Chrome code-sign clones and worktree proliferation as producers.**
Neither has a producer-side fix available: Chrome regenerates
`code_sign_clone` on every relaunch by design (macOS Gatekeeper behavior,
not something disk_magician can suppress without the existing
`disable_code_sign_clone_wrapper.sh`/`disable_code_sign_clone_lsenvironment.sh`
experiments, which are already in-repo and out of scope to re-litigate
here), and worktree creation is driven by other repos' AO/dispatch workflows.
Both are therefore **cleanup-side only** in this plan — see B2 and B3.

### B. Automatic periodic cleanup via launchd

Per the explicit instruction to prefer extending `pressure-sweep`/`tmp-scratch`
over new jobs, and to avoid duplicating the fleet's existing 16 jobs:

**B1. Code-sign-clone reclaim schedule (closes bead jui's "no scheduled
job" gap).** Add a step 3 to `pressure_sweep.sh` (threshold-triggered, runs
already every 30 min when free < 40 GiB) invoking
`cleanup_code_sign_clones.sh --clean` after the existing `cleanup_tmp.sh`
and `cleanup_colima.sh` steps, using the file's own established pattern —
`run_step_timeout` wrapping `env CODE_SIGN_CLONES_APPROVED=1
"$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" "$clean_flag"`, logged to
`$LOG_FILE`, failure-continues rather than aborting the sweep (mirrors
steps 1/2 exactly; the script silently no-ops without the `_APPROVED=1`
env var, confirmed at `scripts/cleanup_code_sign_clones.sh:40`). Do **not**
also add it to a second job — one destructive trigger path keeps the
safety reasoning single-threaded. Caveat accepted: since pressure-sweep
only fires under the 40 GiB threshold, this reclaims code-sign clones
reactively (crisis-triggered), not on a routine low-pressure cadence —
acceptable because the script's own lsof/age gates make it safe to run
this way, and a routine-cadence addition can be revisited later without
architecture change.

**B2. `~/.claude/state` sweeper schedule (closes bead isw's scheduling
gap, on top of PR #74's script).** The `tmp-scratch` job's plist
(`launchd/com.jleechanorg.disk-magician-tmp-scratch.plist.template`)
invokes `scripts/cleanup_tmp.sh --clean --large` **directly** as its
`ProgramArguments` — there is no wrapper script to extend, and embedding
the state sweep inside `cleanup_tmp.sh` itself would be wrong: that same
script is also invoked by `pressure_sweep.sh` step 1, which would then
silently sweep `~/.claude/state` every 30 minutes instead of hourly and
outside this task's intended trigger. Instead: create
`scripts/tmp_scratch_sweep.sh`, a thin wrapper that runs
`cleanup_tmp.sh --clean --large` then
`env CLAUDE_STATE_APPROVED=1 cleanup_claude_state.sh --clean` (confirmed
env var name from PR #74's diff), each logged and failure-continuing per
the pressure_sweep.sh pattern. Point the `tmp-scratch` plist template's
`ProgramArguments` at the new wrapper and reinstall via
`scripts/install_launchd_sweepers.sh` (never `plutil -extract` in place —
the canonical template+installer path sidesteps the pinned plist-corruption
hazard from PR #69). This is a plist **template** content change (in git,
reviewed, applied only through the installer), not an in-place `plutil`
edit — the two are not the same hazard class.

**B3. Worktree hygiene.** Already covered by the existing
`worktree-hygiene` daily job calling `cleanup_worktrees.sh` — no change
needed; confirm post-merge that it also exercises the size delta from the
25 new worldarchitect.ai worktrees once they cross the 7-day floor (nothing
to schedule differently, this is a "let the existing gate do its job"
verification step in the plan, not new code).

**B4. Register `$DARWIN_USER_TEMP_DIR` once genuinely covered (superseded
design, round-3 `/advice` correction).** The earlier draft of this section
proposed rewriting `scripts/lib/scratch_roots.sh` into a
`config/sweeper_roots.txt`-backed loader. Reading PR #71's actual shipped
code shows `scratch_roots.sh` is three small hardcoded shell functions
(`scratch_roots_get_private_tmp`/`_tmp`/`_user_tmp`), not an editable
array — a full loader rewrite is a materially larger, riskier change than
the real gap needs. The real, minimal fix: append one entry to
`config/sweeper_roots.txt` — `$DARWIN_USER_TEMP_DIR` → `cleanup_tmp.sh
(scratch_roots.sh + pressure_sweep.sh budget eviction)` — once that root
is genuinely fully covered (see B4b/B4c below), not before. Also add
`/private/tmp/agent-scratch` (A1) as its own new entry once A1 ships.

**"Covered" means reactive, not continuous (round-3 `/advice` clarification).**
Budget eviction only runs when `pressure_sweep.sh`'s own trigger fires
(free space < 40 GiB, or the Colima/`/private/tmp` proactive-sweep
ceilings) — not on a fixed low-pressure cadence. This is the same
semantic already accepted for B1 (code-sign clones) and for every other
entry already in `config/sweeper_roots.txt` (e.g. `/private/tmp` itself is
only actively swept under the same trigger). "Covered" in this registry
has always meant "has an owning sweeper that reclaims it under pressure,"
not "actively empty at all times" — registering `$DARWIN_USER_TEMP_DIR`
under this same, already-uniform policy is not a new or inconsistent
claim.

**B4b. Enable PR #71's scratch-budget eviction (round-3 `/advice`
finding).** PR #71 ships `DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB`
**disabled by default** (`0`) — merging #71 alone does not fix this plan's
#1 root-cause producer ($TMPDIR, 28.2 GiB). Set it to `15` (GiB) in the
`pressure-sweep` plist template's `EnvironmentVariables`. **Rationale:**
leaves ~13 GiB of headroom below the observed 28.2 GiB peak for legitimate
in-flight scratch; PR #71's own 2-hour floor already protects anything
younger than that regardless of the budget value, so 15 GiB only ever
evicts scratch that is both stale and large. **Rollback:** revert the
value to `0` in the template and reinstall via
`scripts/install_launchd_sweepers.sh` — eviction stops on the next fire,
with no data-loss risk from the rollback step itself. Must not run before
B4c closes. **Round-4 gate (added 2026-09-24, SATISFIED 2026-09-25 —
round-5):** must also not run before local branch
`fix/scratch-safety-hardening` merges to `origin/main`. Both reviewers
rejected `scratch_budget.sh` as shipped in #71 over four additional safety
gaps (missing sandboxed/enforced-mode distinction, unmeasurable candidates
deleted instead of preserved, `SKIP_LSOF` usable in production,
`path_size_kb` miscomputation), fixed on that branch and merged as PR #78
(`27df9d93b77dc5d89ea035bb2a10cd4357a554a5`, 2026-09-25). Verify via `env
-u GH_TOKEN -u GITHUB_TOKEN gh pr list --state merged --head
fix/scratch-safety-hardening --json number` returning a non-empty array
before enabling (re-check live rather than trusting this note) — not
`git log --oneline | grep`, which is unreliable here: this repo
squash-merges, so merged commit subjects on `origin/main`
are PR titles, never branch names.

**B4c. Close the `TemporaryItems` eviction-filter gap (round-3 `/advice`
finding).** `scratch_budget_evict_root()` (PR #71,
`scripts/lib/scratch_budget.sh`) excludes top-level
`com.apple.*|system-*|PowerlogHelperd*|_disk_magician_archive*` basenames
and separately consults a project-name allowlist
(`is_protected_root`/`is_protected_tmp_path`: `worldarchitect.ai
worldai_claw wa-missions`). Neither protects a literal top-level
`TemporaryItems` directory under `DARWIN_USER_TEMP_DIR` — confirmed by
reading the live merged code. Add `TemporaryItems` to the exclusion
case-statement before B4b is allowed to enable eviction in production.

**B5. Colima trim cadence (VM-volume swap, bead 8to).** The recurring
detection need (not the one-time 20 GiB fix already applied 2026-09-22) is
covered by PR #72's `disk_snapshot.sh` swap/VM-volume tracking — no new
launchd job required; the existing `colima-prune` job's own
`StartInterval` accumulation bug (documented in its plist: resets on every
per-user launchd reload, and this Mac reboots roughly every 2 days, so a 7d
interval rarely accumulates) is a **pre-existing, orthogonal** issue about
VM disk *shrink correctness*, not about host disk *fill prevention* — file
it as a separate low-priority bead, not fixed in this plan.

**B6. Fail-closed / lsof / deletion-log invariants.** Every new invocation
added above (B1, B2) reuses each script's own existing safety rails
(`safety_lib.sh` lsof-in-use check, dry-run default, `*_APPROVED=1`
env-gate). Deletion logging: `cleanup_tmp.sh`/`cleanup_colima.sh` log each
deletion via `log "Removing: $path (...)"`/`log "DRY RUN: would remove:
..."` to `$LOG_FILE` (confirmed at `scripts/cleanup_tmp.sh:166,168,411,413`)
— **not** via `retain_evidence.py`/`snapshot_commit.sh`, which is a
separate mechanism used only by the snapshot-ledger commit flow
(`scripts/snapshot_commit.sh:64`). Correcting the earlier draft's
citation: B1/B2 inherit the `$LOG_FILE` logging pattern, not a
`retain_evidence.py` receipt. No new safety mechanism is introduced — B1/B2
are pure scheduling additions to already-reviewed scripts (#70, #74).

### C. Detection

**C1. Uncovered-root alert.** PR #72's `check_uncovered_roots.py/.sh`
already computes the delta between `df`-measured used space and the sum of
registered-root sizes. Schedule it as an additional step in the existing
`drilldown` job (daily, repo-root script — matches its existing
"explain-the-residual" purpose) rather than a new job. Alert threshold:
reuse the existing `residual_gb` alerting convention in
`disk_usage_alert.sh` (already in PR #72's scope) — fire when uncovered
residual exceeds 10 GiB, matching the repo `CLAUDE.md` "System Residual"
invariant (`residual > 10 GiB` triggers `check_system_residual.sh`).

**C2. Swap tracking.** Covered by PR #72's `disk_snapshot.sh` change —
confirmed live: `get_swap_stats()` reads host `sysctl vm.swapusage`,
`get_vm_volume_used_kb()` reads host `df -k /System/Volumes/VM`
(`scripts/disk_snapshot.sh:199-227`). Both are host-side macOS
measurements, not something read from inside the Colima Linux guest —
correlated with the guest's RAM pressure (bead 8to), not the guest's own
virtual disk. Runs on the existing 35-min snapshot cadence (uv-tool-packaged
path). No new job.

**C3. Ledger freshness gap (zyn/4y6) — explicitly deferred.** The full
frontier-BFS ledger rearchitecture (bead 4y6: provision a root-owned
full-attribution snapshot runner; bead zyn: publish a partial ledger when
coverage is incomplete) is **not** part of this plan — it's a larger,
already-tracked effort. This plan's only dependency on it is C1/C2 above,
which work independently of ledger freshness (they read live `df` +
registry, not the ledger). To avoid detection staying blind if the ledger
stays stale, add one cheap check: extend `sweeper_health_check.sh` (already
runs on a schedule per the `sweeper-health` job) with a ledger-age check
—commit age of `~/.disk_magician_backup/ledger/topdown-5g.json` >48h — and
surface it as a WARN line in its existing output. This is a 5-line addition
to an existing health check, not a new detection subsystem.

### D. Deploy path

Corrected from the earlier draft: **none of B1/B2/C1/C3 need a uv-tool
reinstall.** Per repo `CLAUDE.md`, only the 35-min snapshot job
(`com.jleechanorg.disk-magician`) runs the uv-tool-packaged copy; the
`pressure-sweep`, `tmp-scratch`, `drilldown`, and `sweeper-health` jobs all
invoke repo-root scripts **directly** via `@REPO_ROOT@` substitution
(confirmed live in each job's plist `ProgramArguments`) — every script this
plan touches (`pressure_sweep.sh`, the new `tmp_scratch_sweep.sh`,
`residual_drilldown.sh`, `sweeper_health_check.sh`) is in that
directly-invoked set. A merge to `main` is live for these the moment
`launchd` next fires — no separate deploy step.

What CI already gates per-PR (`ci.yml`: "Verify package-tree
synchronization" runs `sync_package_tree.sh --check`; "Verify pyproject
version monotonicity" runs `check_version_monotonic.py`) means each PR
in this plan must already carry its own `sync_package_tree.sh` (no
`--check`) run and its own `pyproject.toml` version bump **before** it can
merge — there is no separate end-of-plan sync/bump step to perform.

Deploy path is therefore just a post-merge confirmation, run once after all
PRs in this plan land:

1. `bash scripts/check_launchd_fleet.sh` — confirm all jobs still loaded
   (repo `CLAUDE.md` Step -1 invariant; run this both **before** starting
   Task 1 as a pre-flight and again here as a regression check).
2. Confirm the repo-root scripts on disk at `@REPO_ROOT@` match
   `origin/main` HEAD (`git -C <repo-root> fetch && git -C <repo-root>
   status` — should be clean and up to date; this repo root *is* what
   launchd executes for the affected jobs, so "deployed" here means
   "checked out at the right commit," not "reinstalled").
3. If a future change to this plan's scope ever touches
   `disk_snapshot.sh`/`disk_audit.sh` (the 35-min snapshot job's script
   set), re-apply the full uv-tool dance (`sync_package_tree.sh`, version
   bump, `uv tool install --force --reinstall`, grep the **installed**
   copy per the 2026-07-11 stale-deploy incident) for that change
   specifically — not needed for B1/B2/C1/C3 as scoped here.

## Assumptions and Recommended Defaults

| # | Question | Auto-picked answer | Rationale |
|---|---|---|---|
| Q1 | Where does the new managed-scratch root live? | `/private/tmp/agent-scratch/<runtime>/<run-id>` | `$TMPDIR`/`/private/tmp` is already the largest single producer (28.2 GiB); a namespaced subtree lets budget eviction and a future Stop hook target precisely, without re-scoping unrelated `$TMPDIR` content |
| Q2 | Unify `scratch_roots.sh` (bash array) vs `config/sweeper_roots.txt` (flat text) — now or later? | Later, as its own PR strictly after #71 and #72 both merge; `sweeper_roots.txt` becomes the source of truth | Editing either in-flight branch risks merge conflicts on already-reviewed PRs; both shapes are simple enough to unify mechanically post-merge |
| Q3 | New launchd job for code-sign-clone reclaim, or extend an existing one? | Extend `pressure_sweep.sh` (step 3), pure script-body addition | Explicit instruction to prefer extending pressure-sweep/tmp-scratch; keeps one destructive-trigger owner; no plist change needed since pressure_sweep.sh's own body already owns its step sequence |
| Q4 | New launchd job for `~/.claude/state`, or extend? | Extend the hourly `tmp-scratch` cadence, via a new thin wrapper script (`tmp_scratch_sweep.sh`) since the plist invokes `cleanup_tmp.sh` directly today | Same "ephemeral per-task artifact" cadence class as the existing `$TMPDIR` sweep; a wrapper (not embedding in `cleanup_tmp.sh`) avoids double-triggering the state sweep from `pressure_sweep.sh`'s own separate call to `cleanup_tmp.sh` |
| Q5 | Fix the `colima-prune` `StartInterval` accumulation bug as part of this plan? | No — file as a separate low-priority bead | It's about VM-image shrink correctness (reboot resets the interval countdown), orthogonal to host-disk-fill prevention; the VM-volume swap issue itself (bead 8to) is already fixed manually and gets recurring *detection* via C2, which doesn't depend on this bug |
| Q6 | Implement the cross-repo "worktree instead of full clone" producer fix here? | **Round-4 update (2026-09-24): APPROVED by the user ("finish all") and redesigned.** The original framing was wrong — there is no separate "owning orchestrator repo"; the `~/.claude/state` growth is produced by ad hoc interactive Claude Code/Codex sessions, not a discrete automation codebase. Ship `scripts/lib/agent_worktree.sh` in this repo instead (bead `disk_magician-orchestrator-worktree-not-clone-2nw`, TDD pair `disk_magician-9n1`) | disk_magician owns and can ship the in-repo helper directly, no cross-repo approval needed; the machine-wide policy instruction to actually call it remains Q8 (separate, still policy-gated) |
| Q7 | Wire the Stop/SessionEnd hook into `~/.claude/settings.json` here? | Ship the hook script in this repo unconditionally (unchanged). **Round-4 update (2026-09-24): the settings.json wiring itself is now APPROVED by the user ("finish all")** — bead `disk_magician-claude-settings-stop-hook-wiring-if9` executes the registration, backing up the file first | `~/.claude/settings.json` is global user config outside this repo's ownership; mirrors the existing MCP-registration ownership norm; user approval satisfies that ownership gate for this specific edit |
| Q8 | Edit `~/.codex/AGENTS.md` to add an agent scratch-root policy rule? | **Round-4 update (2026-09-24): APPROVED by the user ("finish all")** — bead `disk_magician-codex-agents-md-scratch-policy-2gp` executes the edit | Shared policy file still requires its own semantic-signoff + behavioral-canary gate per its own text (user approval does not substitute for that content-quality gate) — the bead's Steps run the pre/post-edit canary from `~/.codex/AGENTS.md` itself before landing the change |
| Q9 | Address the ledger-freshness gap (zyn/4y6) fully in this plan? | No — explicitly deferred; add a 5-line ledger-age WARN to the existing `sweeper_health_check.sh` instead | Full rearchitecture is a separate, already-tracked, larger effort; C1/C2 detection doesn't depend on ledger freshness anyway |
| Q10 | When to bump `pyproject.toml` version and deploy? | Per-PR bump, deploy sequenced last after all merges, verified against the deployed uv-tool tree | Matches repo `CLAUDE.md` deploy invariant; per-PR bumps keep each PR independently deployable rather than batching risk into one final step |

## Implementation Preconditions

**Round-4 update (2026-09-24): the user approved all three items below
("finish all"), recorded live.** None is blocked on approval anymore; each
retains its own remaining precondition, listed below.

- **A2 (redesigned to an in-repo `agent_worktree.sh` helper, no longer
  cross-repo)**: precondition is its own TDD pair (bead `disk_magician-9n1`)
  and bead `disk_magician-agent-scratch-helper-impl-ned` (T5-IMPL) closing
  first — no external approval precondition remains.
- **A3 wiring (`~/.claude/settings.json` hook registration)**: no approval
  precondition remains; precondition is Task 6's hook script (bead
  `disk_magician-agent-scratch-cleanup-hook-impl-o4z`) closing first, since
  the wiring bead registers that script.
- **Q8 AGENTS.md bead**: user approval does not substitute for
  `~/.codex/AGENTS.md`'s own semantic-signoff gate — that procedure
  (explicit pre/post-edit behavioral canary, quoted verbatim in the bead)
  remains a precondition and is not something this plan or the user's
  approval can pre-satisfy.

## Risks / Rollback

- B1/B2 add destructive steps to already-scheduled, already-running jobs
  (`pressure-sweep`, `tmp-scratch`). B1 is a pure script-body addition to
  `pressure_sweep.sh` — no plist change, trivial rollback (revert the added
  step). B2 **does** change a plist template's `ProgramArguments` (pointing
  it at the new `tmp_scratch_sweep.sh` wrapper instead of `cleanup_tmp.sh`
  directly) — this is applied only through the canonical
  template-file-in-git + `scripts/install_launchd_sweepers.sh` path, never
  an in-place `plutil -extract`, so the pinned plist-corruption hazard
  (PR #69) is not re-triggered; rollback is reverting the template's
  `ProgramArguments` and re-running the installer. `check_launchd_fleet.sh`
  + `sweeper-health` continue to cover both jobs' liveness unchanged.
- B4 (superseded design, round-3 correction) is now a single append to
  `config/sweeper_roots.txt` plus one new test method on the real,
  committed registry file (not a synthetic per-test fixture) — see B4's
  own text above; the earlier two-file loader-rewrite risk this bullet
  described no longer applies. B4b (enable eviction) and B4c
  (TemporaryItems filter fix) carry their own risk: B4b is explicitly
  gated on B4c closing first, so the worst case (eviction enabled before
  the filter gap closes) has no path through the dependency graph;
  rollback for B4b is reverting the plist's budget value to `0` and
  reinstalling. **Round-4 addition (2026-09-24), satisfied 2026-09-25:**
  B4b was also gated on local branch `fix/scratch-safety-hardening`
  merging (four additional safety gaps both reviewers found in
  `scratch_budget.sh` as shipped — see B4b's own text); merged as PR #78.
  Same rollback applies if that gate is ever bypassed
  in error.
- A2's redesigned `agent_worktree.sh` helper (round-4b/4c, 2026-09-24)
  deliberately does not reuse A1's `agent_scratch_create`/managed-scratch
  root, precisely to avoid a worst case where B4's own eviction or A3's
  Stop hook deletes a worktree with unpushed work inside the repo
  `CLAUDE.md` 7-day protection window — and deliberately does not default
  to anywhere under `/private/tmp` at all (round-4c: `cleanup_tmp.sh
  --large` itself, independent of B4/A3, scans one level deep there) — see
  A2's own text for the fix (`/private/var/tmp/agent-worktrees`) and its
  round-6 correction (no destructive sweeper in this repo currently
  reaches that root by path or by repo-scoped `git worktree list`
  discovery for disk_magician itself, but a future change to
  `worktree_hygiene.sh`'s scan config or execute-mode could legitimately
  reach a worktree there for OTHER calling repos — which is safe, not a
  regression, since that sweeper already enforces the 7-day floor
  correctly). Also added: root-ownership/symlink rejection in
  `agent_worktree_create` (round-6, both reviewers independently flagged
  the world-writable-sticky `/private/var/tmp` parent). Rollback: none
  needed for either addition, since nothing added by B1-B4/A3 in this plan
  touches that root, and the ownership check is a pure additional
  rejection case with no existing-caller behavior change.
