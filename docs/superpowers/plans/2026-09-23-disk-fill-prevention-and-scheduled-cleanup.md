# Disk-fill prevention and automatic periodic cleanup via launchd — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the scheduling and prevention gaps identified in the
2026-09-22/23 disk-fill root cause (+103 GiB/7 days) by scheduling the
already-built-but-unscheduled sweepers (code-sign clones, `~/.claude/state`),
adding a namespaced agent-scratch root with a cleanup hook, registering
`$DARWIN_USER_TEMP_DIR` in the single surviving root registry (no
registry-unification rewrite needed — see Task 4), and adding a
ledger-freshness alert. **No uv-tool package deploy step is needed for any
Task in this plan** — see the Sequencing gate and Task 7: every script this
plan touches is invoked directly from the repo root by launchd, not from the
uv-tool-packaged copy (the one exception, Task 8's `disk_diagnostic.sh`
migration, documents its own separate uv-tool re-verification step).

**Architecture:** Every destructive addition is a single new step appended
to an *already-scheduled, already-safety-gated* launchd job
(`pressure_sweep.sh` or the `tmp-scratch` job), reusing each target script's
existing dry-run/lsof/`*_APPROVED=1` rails — no new plist, no new safety
mechanism. Both PRs that once shipped separate in-flight root registries
(`scratch_roots.sh`, `config/sweeper_roots.txt`) are merged as of 2026-09-24;
no registry-unification rewrite is needed (see Task 4's "superseded design"
correction) — `config/sweeper_roots.txt` is the one this plan registers new
roots in. Cross-repo and global-config producer-side changes (the settings.json
Stop-hook wiring, the AGENTS.md policy rule, the worktree-not-clone helper)
were approval-gated as of 2026-09-23; the user approved all three 2026-09-24
("finish all") — they are executed via their own beads (see the plan's final
"Out of scope, except where the user has since approved execution" section),
not as numbered Tasks here.

**Tech Stack:** bash (POSIX-ish, macOS `stat`/`date` dialect per repo
convention), Python 3 (`check_uncovered_roots.py`), `launchd`/`launchctl`,
`bats`/plain-bash test harness (`tests/test_*.sh` pattern already used
throughout this repo).

**Full design reference:**
`docs/superpowers/specs/2026-09-23-disk-fill-prevention-and-scheduled-cleanup-design.md`

---

## Sequencing gate

**Round-4 update (2026-09-24, verified live via `gh pr list --state all`):
all 8 PRs in this plan's dependency table (#69–#76) are now MERGED to
`origin/main`.** The round-3 `mergeStateStatus` snapshot below (2026-09-23:
#69/#70/#73 CLEAN, #71/#72/#74/#75 BLOCKED on bead `cse`'s
version-monotonicity gate until #73 merged) is preserved for provenance
only — every PR-merge dependency in this plan (Tasks 1–5, 8) is therefore
already satisfied. A dependency that was *not* satisfied as of 2026-09-24
and was **not** a merged PR: `scripts/lib/scratch_budget.sh` as shipped in
#71 was rejected by both reviewers over four safety gaps (missing
sandboxed/enforced-mode distinction, unmeasurable candidates deleted
instead of preserved, `SKIP_LSOF` usable in production, `path_size_kb`
miscomputation). **Round-5 update (2026-09-25): fixed and merged as PR
#78** (`27df9d93b77dc5d89ea035bb2a10cd4357a554a5`) — **Task 4b's gate is
now satisfied.** Verify via `env -u GH_TOKEN -u GITHUB_TOKEN gh pr list
--state merged --head fix/scratch-safety-hardening --json number`
returning a non-empty array before starting Task 4b (re-check live rather
than trusting this note) — not `git log --oneline | grep`, which is
unreliable here: this repo squash-merges, so merged commit subjects on
`origin/main` are PR titles, never branch names.

Tasks 1–3 below (B1, B2, C1/C3) each depended on the specific PR that built
the script they extend (Task 1 → #70, Task 2 → #74, Task 3 → #72) — all
merged, so Tasks 1–3 can start immediately. Task 4c (TemporaryItems filter
fix) depended on #71 merged — merged, can start immediately. Task 4b
(enable scratch-budget eviction) depends on Task 4c closed **and** the
lane-A `fix/scratch-safety-hardening` PR merged (see above — satisfied as
of PR #78, 2026-09-25). Task 4
(register DARWIN_USER_TEMP_DIR as covered) depended on #72 merged (satisfied)
and depends on Task 4b closed. Task 5 (A1 helper) depended on #72 merged
(satisfied; it registers an entry in `config/sweeper_roots.txt`, which
exists as of #72) AND Task 4's own edit to that file closing first
(same-file sequencing) — this corrects the earlier draft's "no PR
dependency" claim, which was wrong: Task 5 edited that file directly.
Task 6 (A3 hook script) has no PR dependency and can start immediately; it
calls Task 5's helper, so it still needs Task 5 done first, just not gated
on a specific PR beyond that. Task 8 (producer migration) depends on Task
5 closed (it calls `agent_scratch_create`) and has no PR dependency beyond
that. Task 7 (deploy) is strictly last, and per Task 7's revised scope
below is much smaller than originally drafted.

**Per-task CI gates (applies to every task's commit step, not just Task
7; round-3 `/advice` correction — no task bumps `pyproject.toml`):**
`ci.yml` runs `sync_package_tree.sh --check` and
`check_version_monotonic.py` on every PR. Any task that adds/modifies a
repo-root script must run `bash scripts/sync_package_tree.sh` (no
`--check`) **as part of that task's own commit**, or CI's package-tree
sync gate fails that PR. `check_version_monotonic.py`'s gate is `current
version >= every historical version` (confirmed by reading its source) —
an unchanged version trivially satisfies it, so **no task in this plan
bumps `pyproject.toml`**, and none needs to: per Task 7, none of these
scripts are served from the uv-tool-packaged copy either, so there is no
deploy-cache-invalidation reason to bump it. The earlier draft of this
note (superseded) said the opposite; do not follow it.

---

### Task 1: Schedule code-sign-clone reclaim in pressure_sweep.sh (closes bead jui's scheduling gap)

**Depends on:** PR #70 merged (extends `cleanup_code_sign_clones.sh` to
reclaim per-launch children).

**Files:**
- Modify: `scripts/pressure_sweep.sh` (add step 3 after the existing
  `cleanup_colima.sh` step)
- Modify: `src/disk_magician/scripts/pressure_sweep.sh` — do not hand-edit;
  run `bash scripts/sync_package_tree.sh` as part of this task's own commit
  after editing the repo-root copy (CI's "Verify package-tree
  synchronization" gate fails the PR otherwise — see `ci.yml`)
- Test: `tests/test_pressure_sweep.sh` (extend existing file; do not
  create a new test file — it already exercises steps 1/2)

**Step 1: Write the failing test**

Add a case to `tests/test_pressure_sweep.sh` that stubs `df` to report free
space under threshold, stubs `cleanup_code_sign_clones.sh` with a script
that (a) writes a marker file AND (b) asserts
`[[ "${CODE_SIGN_CLONES_APPROVED:-0}" == "1" ]]` (failing loudly if unset),
runs `pressure_sweep.sh --clean` in the existing sandboxed test harness
(mirrors how the file already stubs `cleanup_tmp.sh`/`cleanup_colima.sh`),
and asserts the marker file exists and pressure_sweep exits 0. Asserting
the env var, not just call presence, is required — a stub that only checks
"was I called" would pass even if the real script's own approval gate made
the step a no-op in production (the failure mode the `/advice` review
caught in the original draft).

**Step 2: Run test to verify it fails**

Run: `bash tests/test_pressure_sweep.sh`
Expected: FAIL — code-sign step never invoked, marker file absent.

**Step 3: Write minimal implementation**

In `scripts/pressure_sweep.sh`, immediately after the existing
`# ────────── STEP 2: cleanup_colima.sh ──────────` block, add a step 3
that mirrors steps 1/2's exact structure — `run_step_timeout`, `$REPO_ROOT`
(confirmed live: `REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"` at
`scripts/pressure_sweep.sh:30`, already in scope at this point in the file
and already the variable steps 1/2 use — not `$SCRIPT_DIR`), explicit
env-gate, and failure-continue:

```bash
# ────────── STEP 3: cleanup_code_sign_clones.sh ──────────
before_gb="$(free_gb)"
log "pressure_sweep: step 3/3 cleanup_code_sign_clones.sh ${clean_flag} — free before: ${before_gb} GB"
if [[ "$DRY_RUN" != true ]]; then
  codesign_step=(env CODE_SIGN_CLONES_APPROVED=1 "$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" "$clean_flag")
else
  codesign_step=("$REPO_ROOT/scripts/cleanup_code_sign_clones.sh" "$clean_flag")
fi
if run_step_timeout "${codesign_step[@]}" >> "$LOG_FILE" 2>&1; then
  after_gb="$(free_gb)"
  log "pressure_sweep: step 3/3 cleanup_code_sign_clones.sh done — free after: ${after_gb} GB"
else
  rc=$?
  log "pressure_sweep: step 3/3 cleanup_code_sign_clones.sh FAILED or timed out (rc=${rc})."
fi
```

The `CODE_SIGN_CLONES_APPROVED=1` env var is **required** —
`scripts/cleanup_code_sign_clones.sh:40` refuses to delete anything
without it and exits 0, so omitting this makes the whole step a silent
no-op that would still pass a marker-file test that doesn't check for
actual deletion. Update the script's header "steps" comment count
(`1/2` → `1/3`, `2/2` → `2/3`) at all three step headers. Do not add step 3
to the existing `SWEEP_MODE` colima-only/tmp-only skip conditionals
(confirmed live: `colima-only` skips at `scripts/pressure_sweep.sh:228`,
`tmp-only` skips at `scripts/pressure_sweep.sh:254` — both gate steps 1/2
only; step 3 targets code-sign clones, which relate to neither mode, so it
runs unconditionally in both).

**Step 4: Run test to verify it passes**

Run: `bash tests/test_pressure_sweep.sh`
Expected: PASS.

**Step 5: Run full existing suite for this script**

Run: `bash tests/test_cleanup_safety.sh && bash tests/test_pressure_sweep.sh`
Expected: PASS (no regression to existing steps 1/2 assertions).

**Step 6: Commit**

Separate commits: test file change, then implementation change (per repo's
TDD-separate-commits convention referenced in the task brief).

---

### Task 2: New tmp_scratch_sweep.sh wrapper + repoint the tmp-scratch plist (closes bead isw's scheduling gap)

**Depends on:** PR #74 merged (`cleanup_claude_state.sh` built + wired into
`disk_audit.sh`, with its own 7-day mtime floor and
`CLAUDE_STATE_APPROVED=1` gate).

**Confirmed live (do not re-derive):** the `tmp-scratch` job's
`ProgramArguments` invokes `@BASH@ @REPO_ROOT@/scripts/cleanup_tmp.sh
--clean --large` **directly** — there is no existing wrapper. Do not embed
the state sweep inside `cleanup_tmp.sh` itself: `pressure_sweep.sh` step 1
also calls `cleanup_tmp.sh` directly, so embedding there would additionally
trigger the state sweep every 30 minutes from pressure-sweep, not just
hourly from tmp-scratch as intended.

**Files:**
- Create: `scripts/tmp_scratch_sweep.sh`
- Create: `src/disk_magician/scripts/tmp_scratch_sweep.sh` — do not
  hand-create; run `bash scripts/sync_package_tree.sh` as part of this
  task's own commit (same CI gate as Task 1)
- Modify: `launchd/com.jleechanorg.disk-magician-tmp-scratch.plist.template`
  (`ProgramArguments` → point at `tmp_scratch_sweep.sh` instead of
  `cleanup_tmp.sh` directly; drop the now-redundant `--clean --large` args
  from the plist since the wrapper owns them internally)
- Test: `tests/test_tmp_scratch_sweep.sh` (new)

**Step 1: Write the failing test**

`tests/test_tmp_scratch_sweep.sh`: stub `cleanup_tmp.sh` and
`cleanup_claude_state.sh` with scripts that write ordered marker files
(`$TMP/1_tmp_called`, `$TMP/2_state_called`) and assert their respective
approval env vars (`LARGE_TMP_APPROVED` — confirmed live at
`scripts/cleanup_tmp.sh:180` — and `CLAUDE_STATE_APPROVED`) are set to `1`. Run
`scripts/tmp_scratch_sweep.sh --clean`. Assert both marker files exist, in
order, and the wrapper exits 0 even if one step fails (failure-continue,
matching `pressure_sweep.sh`'s pattern) — add a second test case where the
`cleanup_tmp.sh` stub exits 1 and assert the `cleanup_claude_state.sh` stub
still runs.

**Step 2: Run test to verify it fails**

Expected: FAIL — `scripts/tmp_scratch_sweep.sh` does not exist.

**Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# tmp_scratch_sweep.sh — hourly tmp-scratch job entry point.
# Wraps cleanup_tmp.sh (--large) then cleanup_claude_state.sh, each with
# its own explicit *_APPROVED=1 gate, failure-continuing between steps.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
clean_flag="${1:---dry-run}"

if [[ "$clean_flag" == "--clean" ]]; then
  env LARGE_TMP_APPROVED=1 \
    "$SCRIPT_DIR/cleanup_tmp.sh" --clean --large || true
  env CLAUDE_STATE_APPROVED=1 \
    "$SCRIPT_DIR/cleanup_claude_state.sh" --clean || true
else
  "$SCRIPT_DIR/cleanup_tmp.sh" --dry-run --large || true
  "$SCRIPT_DIR/cleanup_claude_state.sh" --dry-run || true
fi
```

Deliberately **not** `TMP_WORKTREES_APPROVED=1` here (round-2 `/advice`
correction) — the CURRENT `tmp-scratch` plist's `EnvironmentVariables`
only grants `LARGE_TMP_APPROVED`, not `TMP_WORKTREES_APPROVED`; adding the
latter in this wrapper would silently expand what the hourly job deletes
beyond current production behavior. This mirrors the "Do not" rule already
stated for this task above — the two must not contradict each other.

**Step 4: Run test to verify it passes**

Run: `bash tests/test_tmp_scratch_sweep.sh`
Expected: PASS.

**Step 5: Repoint the plist template**

Edit `launchd/com.jleechanorg.disk-magician-tmp-scratch.plist.template`'s
`ProgramArguments` array to `@BASH@`, `@REPO_ROOT@/scripts/tmp_scratch_sweep.sh`,
`--clean`. Reinstall via
`bash scripts/install_launchd_sweepers.sh com.jleechanorg.disk-magician-tmp-scratch.plist.template`
— **never** hand-edit the installed plist or use `plutil -extract` without
`-o -` on it (pinned corruption hazard, PR #69).

**Step 6: Verify the installed job**

Run: `bash scripts/check_launchd_fleet.sh` — confirm the `tmp-scratch` job
is still loaded and its manifest reflects the new `ProgramArguments`.

**Step 7: Commit** (test, then implementation — plist template change can
be its own commit or bundled with the wrapper script, since they're one
logical unit; do not bundle the `install_launchd_sweepers.sh` *invocation*
into a commit — that's a local operational step, not a file change).

---

### Task 3: Uncovered-root alert in drilldown + ledger-freshness WARN in sweeper_health_check

**Depends on:** PR #72 merged (`check_uncovered_roots.py/.sh` built).

**Files:**
- Modify: `scripts/residual_drilldown.sh` (add a step invoking
  `check_uncovered_roots.sh`, threshold 10 GiB per repo `CLAUDE.md` System
  Residual invariant)
- Modify: `scripts/sweeper_health_check.sh` (add ledger-age check)
- Test: `tests/test_check_uncovered_roots.py` (extend; assert
  `residual_drilldown.sh` invocation surfaces the alert) and a new
  assertion block appended to `tests/test_sweeper_health.sh` (confirmed live
  via `grep -rl sweeper_health_check tests/`)

**Step 1: Write the failing test for the ledger-age WARN**

Stub `~/.disk_magician_backup/ledger/topdown-5g.json`'s git commit
timestamp (via a fake git repo fixture, matching how existing sweeper
health tests fixture state) to be >48h old, run
`sweeper_health_check.sh`, assert a line matching `WARN.*ledger.*stale`
(or equivalent) appears in output.

**Step 2: Run test to verify it fails**

Expected: FAIL — no such WARN line exists yet.

**Step 3: Implement**

In `sweeper_health_check.sh`, add a ~5-line check: read the ledger file's
last commit timestamp by calling `scripts/check_ledger_freshness.sh`
(confirmed live: it already computes `published_age_hours` from `git log`
against `ledger/topdown-5g.json` and prints `STALE`/`OK` with that value —
call the script and parse its output rather than re-deriving the git
plumbing), compare to `now - 48h`,
emit `WARN` if stale. Do not invent a second freshness-check implementation
— `scripts/check_ledger_freshness.sh` already exists; wire a call to it.

**Step 4: Run test to verify it passes**

Expected: PASS.

**Step 5: Write the failing test for the drilldown uncovered-root step**

Assert `residual_drilldown.sh` invokes `check_uncovered_roots.sh` and that
a residual > 10 GiB (fixture) produces a non-zero-severity line in its
output, matching the existing `check_system_residual.sh` alert convention.

**Step 6: Run test to verify it fails, implement, verify it passes**

Add the invocation to `residual_drilldown.sh` following its existing
step-append pattern (same style as Task 1/2 — append, don't restructure).

**Step 7: Commit** (tests, then implementation, per script — two commits
per script, four total, or one commit per Step-pair; follow whichever
granularity the repo's recent commit history in this plan's area uses).

---

### Task 4: Register DARWIN_USER_TEMP_DIR as covered, once genuinely covered (superseded design — round-2/3 `/advice` correction)

**Superseded from the earlier draft below `----`.** Reading PR #71's actual
shipped code (not just its file list) showed `scripts/lib/scratch_roots.sh`
is three small hardcoded shell functions (`scratch_roots_get_private_tmp`,
`scratch_roots_get_tmp`, `scratch_roots_get_user_tmp`), not an editable
array — rewriting it into a `config/sweeper_roots.txt` loader (the original
Task 4 below) would be a materially larger, riskier change than the actual
gap needs. `config/sweeper_roots.txt`'s own header comment (PR #72)
explicitly documents `$DARWIN_USER_TEMP_DIR` as "uncovered today ... by
design," because only a narrow `ao-<sid>` glob under it was covered before
PR #71. The real, minimal fix:

**Files:**
- Modify: `config/sweeper_roots.txt` — append one entry:
  `$DARWIN_USER_TEMP_DIR<TAB>cleanup_tmp.sh (scratch_roots.sh +
  pressure_sweep.sh budget eviction)<TAB>bead disk_magician-d45/8to`
- Test: extend `tests/test_check_uncovered_roots.py` with one new method
  asserting a large DARWIN_USER_TEMP_DIR-rooted fixture path is no longer
  flagged `uncovered` once run against the **real, committed**
  `config/sweeper_roots.txt` (not a synthetic per-test registry — the
  synthetic-registry version of this test would trivially pass without
  proving the real file was actually updated).

**Depends on:** PR #72 merged (the registry file must exist), AND the new
Task "T4b" below (enable scratch-budget eviction) must close first —
registering this root as "covered" before eviction is actually enabled in
production would be a false coverage claim, exactly the anti-pattern
`config/sweeper_roots.txt`'s own comments warn against. AND the new Task
"T4c" below (close the `TemporaryItems` eviction-filter gap) must close
before Task "T4b" is allowed to enable eviction — see T4c.

**Test-first steps:** write the new test method against the real registry
file (expect FAIL — the entry isn't there yet), then add the one registry
line (expect PASS). See the micro-plan's bead table for the exact test
method text (`test_darwin_tmp_covered_by_real_registry`) and both beads'
full ironclad contracts.

### Task 4b (new): Enable PR #71's scratch-budget eviction (round-3 `/advice` finding)

PR #71 ships `DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB` **disabled by
default** (`0`). Merging #71 alone does not fix the plan's #1 root-cause
producer ($TMPDIR, 28.2 GiB) — nobody turns the eviction on. Set it to
`15` (GiB) in `launchd/com.jleechanorg.disk-magician-pressure-sweep.plist.template`'s
`EnvironmentVariables` dict. **Rationale for 15 GiB:** leaves ~13 GiB of
headroom below the observed 28.2 GiB peak for legitimate in-flight scratch
from active agent runs (PR #71's own 2-hour floor already protects
anything younger than that regardless of the budget value, so 15 GiB only
ever evicts scratch that is BOTH stale AND large). **Rollback:** set the
value back to `0` in the plist template and reinstall via
`scripts/install_launchd_sweepers.sh` — eviction stops immediately on the
next fire, no data-loss risk from the rollback itself (dry-run/threshold
logic is unchanged, only the trigger value reverts). **Depends on:** PR #71
merged (beads `d45`/`ka4`) — the earlier draft of this task only depended
on `cse`+`8to`, which would let it run before the feature it enables even
existed; fixed. **Also depends on Task 4c below** — do not enable eviction
before the `TemporaryItems` filter gap is closed. **Round-4 gate (added
2026-09-24, SATISFIED 2026-09-25 — round-5, do not skip the re-check
below):** additionally depended on local branch
`fix/scratch-safety-hardening` merging to `origin/main`. Both reviewers
rejected `scripts/lib/scratch_budget.sh` as shipped in #71 over four
safety gaps (missing sandboxed/enforced-mode distinction, unmeasurable
candidates deleted instead of preserved, `SKIP_LSOF` usable in production,
`path_size_kb` miscomputation); fixed on that branch and merged as PR #78
(`27df9d93b77dc5d89ea035bb2a10cd4357a554a5`, 2026-09-25). Enabling a 15
GiB production eviction budget before that branch's fixes merged would
have run the unhardened eviction path live — no longer applicable, but
verify via `env -u GH_TOKEN -u GITHUB_TOKEN gh pr list --state merged
--head fix/scratch-safety-hardening --json number` returning a non-empty
array (re-check live rather than trusting this note; not `git log
--oneline | grep`, unreliable under this repo's squash-merge convention)
before starting this task.

### Task 4c (new): Close the TemporaryItems eviction-filter gap (round-3 `/advice` finding)

`scratch_budget_evict_root()` in `scripts/lib/scratch_budget.sh` (PR #71)
excludes top-level `com.apple.*|system-*|PowerlogHelperd*|_disk_magician_archive*`
basenames from eviction, and separately consults `is_protected_root`/
`is_protected_tmp_path` (a project-name allowlist: `worldarchitect.ai
worldai_claw wa-missions`). Neither protects a literal top-level
`TemporaryItems` directory under `DARWIN_USER_TEMP_DIR` — confirmed by
reading the live merged code, not assumed. Add `TemporaryItems` to the
exclusion case-statement (one line). **This must close before Task 4b
enables eviction in production** — see the micro-plan for the full
stub-harness-based test (extends PR #71's own `tests/test_scratch_budget.sh`
using its existing `run_budget` helper, proving `TemporaryItems` survives
eviction even as the oldest/largest candidate).

---

### Task 5: agent-scratch managed root helper + findings_wiki entry

**Depends on:** PR #72 merged / bead `8to` closed (this task adds a
`config/sweeper_roots.txt` entry — corrected from the earlier draft's "no
PR dependency" claim, which was wrong, since that file doesn't exist until
#72 lands; round-3 `/advice` correction: attached this dependency directly
to both T5-TEST and T5-IMPL beads, not just transitively). Task 4's own
entry to that same file must land first (same-file sequencing). Task 6 and
Task 8 are this helper's callers, satisfying the repo's "automation
scripts need callers" rule (Task 8, added round-3, is the first real
migrated producer — see below).

**Files:**
- Create: `scripts/lib/agent_scratch.sh`
- Create: `findings_wiki/2026-09-23-verifier-lanes-should-use-worktrees-not-clones.md`
  (git-tracked in the machine fork per repo `CLAUDE.md` findings_wiki rules)
- Test: `tests/test_agent_scratch.sh`
- Modify: `config/sweeper_roots.txt` — add an
  `/private/tmp/agent-scratch` entry using the tab-separated
  `<root_pattern>\t<owning_script>\t<note>` schema #72 actually merged
  (confirmed live in `config/sweeper_roots.txt`'s own header comment) —
  re-read the file immediately before editing per Task 4 Step 1's same
  caution, since a sibling lane may have appended entries since this plan
  was drafted

**Step 1: Write the failing test**

Use a `mktemp -d` sandbox for `AGENT_SCRATCH_ROOT` — never exercise the
real `/private/tmp/agent-scratch` from a test, matching this repo's
existing test-isolation convention for destructive scripts:

```bash
# tests/test_agent_scratch.sh
FAKE_ROOT="$(mktemp -d)"
export AGENT_SCRATCH_ROOT="$FAKE_ROOT"
source scripts/lib/agent_scratch.sh

path=$(agent_scratch_create "testruntime" "run123")
[[ -d "$path" ]] || fail "scratch dir not created"
[[ "$path" == "$FAKE_ROOT/testruntime/run123" ]] || fail "wrong path shape"

# Input validation: reject empty and path-traversal components.
agent_scratch_create "" "run123" 2>/dev/null && fail "empty runtime accepted"
agent_scratch_create "testruntime" "../escape" 2>/dev/null && fail "traversal accepted"
agent_scratch_create "testruntime" "/abs" 2>/dev/null && fail "absolute run-id accepted"

# Trap cleanup must not clobber a caller's existing EXIT trap.
(
  trap 'echo caller-trap-ran > "$FAKE_ROOT/caller_trap_marker"' EXIT
  agent_scratch_trap_cleanup "$path"
  exit 0
)
[[ -f "$FAKE_ROOT/caller_trap_marker" ]] || fail "caller's own EXIT trap was overwritten, not chained"
[[ -d "$path" ]] && fail "trap cleanup did not remove dir on subshell exit"

# Round-3 /advice hardening: containment check + per-signal trap preservation.
path2=$(agent_scratch_create "testruntime" "run789")
(
  trap 'echo exit-trap-ran > "$FAKE_ROOT/exit_marker"' EXIT
  trap 'echo int-trap-ran > "$FAKE_ROOT/int_marker"' INT
  agent_scratch_trap_cleanup "$path2"
  kill -INT $$
)
[[ -f "$FAKE_ROOT/int_marker" ]] || fail "caller's own INT trap was lost (not preserved independently of EXIT)"

outside_dir="$(mktemp -d)"
(AGENT_SCRATCH_ROOT="$FAKE_ROOT" agent_scratch_trap_cleanup "$outside_dir" 2>/dev/null) && fail "accepted a path outside AGENT_SCRATCH_ROOT"
[[ -d "$outside_dir" ]] || fail "outside-root dir was deleted"
rm -rf "$outside_dir"
(AGENT_SCRATCH_ROOT="$FAKE_ROOT" agent_scratch_trap_cleanup "$FAKE_ROOT" 2>/dev/null) && fail "accepted AGENT_SCRATCH_ROOT itself"
mkdir -p "$FAKE_ROOT/bareruntime"
(AGENT_SCRATCH_ROOT="$FAKE_ROOT" agent_scratch_trap_cleanup "$FAKE_ROOT/bareruntime" 2>/dev/null) && fail "accepted a bare <runtime> dir (one segment below root)"

rm -rf "$FAKE_ROOT"
```

(See the bead description for `disk_magician-agent-scratch-helper-test-lj8`
(T5-TEST) via `br show` for the exact, currently-persisted full test file —
this snippet is illustrative; the bead text is canonical if the two ever
diverge again.)

**Step 2: Run test to verify it fails**

Expected: FAIL — `scripts/lib/agent_scratch.sh` does not exist.

**Step 3: Write minimal implementation**

```bash
#!/usr/bin/env bash
# agent_scratch.sh — managed scratch root for agent runtimes (runtime/run-id namespaced).
AGENT_SCRATCH_ROOT="${AGENT_SCRATCH_ROOT:-/private/tmp/agent-scratch}"

_agent_scratch_valid_component() {
  # Reject empty, path-traversal, and absolute-path components.
  local c="$1"
  [[ -n "$c" && "$c" != *".."* && "$c" != /* && "$c" != *"/"* ]]
}

agent_scratch_create() {
  local runtime="$1" run_id="$2"
  _agent_scratch_valid_component "$runtime" || { echo "agent_scratch_create: invalid runtime" >&2; return 1; }
  _agent_scratch_valid_component "$run_id" || { echo "agent_scratch_create: invalid run-id" >&2; return 1; }
  local path="${AGENT_SCRATCH_ROOT}/${runtime}/${run_id}"
  mkdir -p "$path"
  echo "$path"
}

agent_scratch_trap_cleanup() {
  # Containment check (round-3 /advice hardening): refuse to arm cleanup
  # unless the caller-supplied path canonicalizes (symlinks resolved) to a
  # genuine leaf strictly under AGENT_SCRATCH_ROOT/<runtime>/ — at least
  # two path segments below the canonicalized root, never the root itself
  # and never a bare <runtime> directory. Stops both a symlink escape and
  # an accidental "delete a whole runtime's scratch" call.
  local path="$1" canon_root canon_path
  canon_root="$(cd "$AGENT_SCRATCH_ROOT" 2>/dev/null && pwd -P)" || {
    echo "agent_scratch_trap_cleanup: AGENT_SCRATCH_ROOT does not exist, refusing: $AGENT_SCRATCH_ROOT" >&2
    return 1
  }
  if [[ ! -d "$path" ]]; then
    echo "agent_scratch_trap_cleanup: path does not exist, refusing: $path" >&2
    return 1
  fi
  canon_path="$(cd "$path" 2>/dev/null && pwd -P)" || {
    echo "agent_scratch_trap_cleanup: cannot canonicalize path, refusing: $path" >&2
    return 1
  }
  case "$canon_path" in
    "$canon_root"/*/*) ;;
    *)
      echo "agent_scratch_trap_cleanup: refusing — $canon_path is not a leaf strictly under $canon_root/<runtime>/" >&2
      return 1
      ;;
  esac

  # Preserve each of EXIT/INT/TERM's own pre-existing handler individually
  # — a single combined trap string using only EXIT's prior handler text
  # would silently drop a caller's own INT/TERM handlers.
  # Escape embedded single quotes in canon_path (round-3 /advice
  # hardening — a filename containing "'" would otherwise break out of
  # the quoted rm -rf argument when interpolated into the trap string;
  # verified: /tmp/weird'name/leaf round-trips correctly through this).
  local sig existing escaped_path
  escaped_path="${canon_path//\'/\'\\\'\'}"
  for sig in EXIT INT TERM; do
    existing="$(trap -p "$sig" | sed -E "s/^trap -- '(.*)' (SIG)?${sig}\$/\1/")"
    if [[ "$sig" == "EXIT" ]]; then
      trap "rm -rf '${escaped_path}'; ${existing}" "$sig"
    else
      # INT/TERM (round-3 /advice hardening): after cleanup + any prior
      # handler, re-raise the signal against ourselves with default
      # disposition restored, so the process actually terminates as the
      # caller expects on Ctrl-C/kill instead of silently continuing past
      # the now-deleted directory.
      trap "rm -rf '${escaped_path}'; ${existing:+${existing}; }trap - ${sig}; kill -s ${sig} \$BASHPID" "$sig"
    fi
  done
}
```

**Step 4: Run test to verify it passes**

Run: `bash tests/test_agent_scratch.sh`
Expected: PASS.

**Step 5: Write the findings_wiki entry** (knowledge doc, not code) covering:
the `~/.claude/state` +15.6 GiB finding, why it happened (ad hoc full
clones by verifier lanes), and the recommended `git worktree add` +
shared-cache pattern — cross-linked to bead isw and this plan's Task 4/A2.

**Step 6: Commit** (test + implementation together is acceptable here since
this is a pure new-file addition with no risk to existing behavior — no
separate-commit requirement for net-new files per repo convention; findings
commit kept **separate** from the code commit per repo `CLAUDE.md`
findings_wiki rule).

---

### Task 6: Stop-hook cleanup script (script only — no settings.json wiring)

**Files:**
- Create: `scripts/agent_scratch_cleanup_hook.sh`
- Test: `tests/test_agent_scratch_cleanup_hook.sh`

**Step 1: Write the failing test**

Assert the script, given `AGENT_SCRATCH_RUNTIME`/`AGENT_SCRATCH_RUN_ID` env
vars (or equivalent identifying args), removes only
`/private/tmp/agent-scratch/<runtime>/<run-id>` and asserts it refuses to
run (exits non-zero, no deletion) when either var is unset or when the
resolved path is exactly `/private/tmp/agent-scratch` (i.e., it must never
`rm -rf` the whole managed root, only a leaf run directory) — mirrors this
repo's fail-closed pattern for destructive scripts.

**Step 2: Run test to verify it fails**

Expected: FAIL — script does not exist.

**Step 3: Implement**

Minimal script sourcing `scripts/lib/agent_scratch.sh`, resolving the exact
leaf path, refusing on empty/root-level path, then `rm -rf` only that leaf.

**Step 4: Run test to verify it passes**

Run: `bash tests/test_agent_scratch_cleanup_hook.sh`
Expected: PASS.

**Step 5: Commit.**

**Explicitly not in scope for this task:** editing
`~/.claude/settings.json` to register this as a Stop/SessionEnd hook — that
is bead `disk_magician-claude-settings-stop-hook-wiring-if9`'s own scope
(approved for execution 2026-09-24, still a separate bead from this one,
gated on this task's script existing).

---

### Task 8 (new): Migrate a real producer to agent_scratch_create (round-3 `/advice` finding — spec A1b)

Task 5/6 alone ship an unused helper plus a cleanup hook nothing calls
during normal operation — not real prevention. `scripts/disk_diagnostic.sh`
is this plan's first concrete migrated producer: it currently allocates
its working directory via a bare `mktemp -d -t disk_diagnostic.XXXXXX` +
`trap 'rm -rf "$WORK"' EXIT`. Migrate it to `agent_scratch_create
"disk_diagnostic" "$$-$(date +%s)"` + `agent_scratch_trap_cleanup "$WORK"`.

**Depends on:** Task 5 closed (calls its helper). No PR dependency beyond
that.

**Files:**
- Modify: `scripts/disk_diagnostic.sh` (5-line block at the top of the
  file, immediately after `SCRIPT_DIR=...`)
- Modify: `src/disk_magician/scripts/disk_diagnostic.sh` (generated by
  `sync_package_tree.sh`, not hand-edited)
- Test: new `tests/test_disk_diagnostic_scratch.sh`

**Step 1: Write the failing test.** Assert `scripts/disk_diagnostic.sh` no
longer contains the literal string `mktemp -d -t disk_diagnostic`, and
does contain `agent_scratch_create "disk_diagnostic"` and
`agent_scratch_trap_cleanup`.

**Step 2: Run test to verify it fails.** Expected: FAIL, both new
assertions — the migration hasn't happened yet.

**Step 3: Migrate.** Replace the `SCRIPT_DIR=...` / `WORK=$(mktemp ...)` /
`trap ... EXIT` block with the sourced-helper version (source
`scripts/lib/agent_scratch.sh` first, then call `agent_scratch_create` and
`agent_scratch_trap_cleanup`).

**Step 4: Run test to verify it passes; run the existing regression
suite.** `bash tests/test_disk_diagnostic_scratch.sh` and the pre-existing
`bash tests/test_disk_audit_topdown.sh` (this repo's own broader coverage
of `disk_diagnostic.sh`'s behavior, unmodified by this task) must both
pass.

**Step 5: `sync_package_tree.sh`, commit** (test, then implementation).

**Deploy note (round-3 `/advice` finding — the one exception to "no
uv-tool deploy needed" in Task 7 below):** `scripts/disk_diagnostic.sh` is
reachable via `disk_magician.sh`'s CLI dispatcher
(`"$SCRIPT_DIR/scripts/disk_diagnostic.sh" "$@"`), and `disk_magician.sh`
itself is in `sync_package_tree.sh`'s `PATTERNS` set — meaning the
installed `disk-magician` CLI a human operator runs manually serves the
**packaged** copy, unlike every other script this plan touches (which
only launchd invokes directly from the repo root). Task 7's post-merge
step therefore also bumps `pyproject.toml` and runs `uv tool install
--force --reinstall` specifically for this task's change — see Task 7.

---

### Task 7: Post-merge confirmation (strictly last — no uv-tool deploy needed EXCEPT for Task 8, round-3 correction)

**Depends on:** All prior tasks' PRs merged to `main`.

**Corrected from the earlier draft:** every script Tasks 1–3 touch
(`pressure_sweep.sh`, `tmp_scratch_sweep.sh`, `residual_drilldown.sh`,
`sweeper_health_check.sh`) is invoked by its launchd job **directly** from
the repo root via `@REPO_ROOT@` substitution (confirmed live in each job's
plist `ProgramArguments`), not from the uv-tool-packaged copy under
`src/disk_magician/`. Only the separate 35-min snapshot job
(`com.jleechanorg.disk-magician`) runs the packaged copy, and this plan
does not touch anything in its script set (`disk_snapshot.sh`,
`disk_audit.sh`, etc. — those are PR #72/#74's own scope, already merged
by this point). **Exception (round-3 `/advice` finding): Task 8's
`scripts/disk_diagnostic.sh` IS reachable via the packaged copy** — via
`disk_magician.sh`'s CLI dispatcher, and `disk_magician.sh` itself is in
`sync_package_tree.sh`'s `PATTERNS` set. Step 5 below handles this one
exception; it is the only script in this plan that needs the uv-tool
dance. A merge to `main` is therefore live for this plan's
**script-body** changes (T1's `pressure_sweep.sh` edit, T3a's
`sweeper_health_check.sh` edit, T3b's `residual_drilldown.sh` edit) the
moment `launchd` next fires each job — **no `sync_package_tree.sh`
/version-bump/`uv tool install --reinstall` step is needed for those.**
Each task's own PR must already carry its own `sync_package_tree.sh` run
to pass CI's "Verify package-tree synchronization" gate (`ci.yml`) — that
happens per-PR in Tasks 1–6, not as a separate
end-of-plan step.

**Correction (round-2 `/advice`): this does NOT apply to the two plist
template changes** (T2's `tmp-scratch` `ProgramArguments` repoint, T4b's
`pressure-sweep` `DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB=15`). `launchd`
runs the **installed** copy under `~/Library/LaunchAgents/`, not the
git-tracked template — a `main` merge alone does not update it. Without an
explicit reinstall, T2 and T4b's plist edits never take effect in
production even though their own bead tests pass and their PRs merge
green. This IS a required post-merge deploy step, added as Step 2 below.

**Files:** none new — verification commands only.

**Step 1:** `bash scripts/check_launchd_fleet.sh` — confirm all jobs are
loaded (repo `CLAUDE.md` Step -1 invariant). Run this **both before
starting Task 1** as a pre-flight baseline and again here as the
post-merge regression check.

**Step 2 (new):** Reinstall the two changed plists via the canonical
template+installer path — never `plutil -extract` in place (pinned
corruption hazard, PR #69):
```
bash scripts/install_launchd_sweepers.sh \
  com.jleechanorg.disk-magician-tmp-scratch.plist.template \
  com.jleechanorg.disk-magician-pressure-sweep.plist.template
```
Then re-run `bash scripts/check_launchd_fleet.sh` and confirm both jobs'
manifests reflect the new `ProgramArguments`/`EnvironmentVariables`
(`launchctl print gui/$(id -u)/com.jleechanorg.disk-magician-tmp-scratch`
and the `-pressure-sweep` equivalent, grep for `tmp_scratch_sweep.sh` and
`DISK_MAGICIAN_PRESSURE_SCRATCH_BUDGET_GB` respectively).

**Step 3:** Confirm the repo root that launchd's `@REPO_ROOT@` resolves to
is checked out at the merged `main` HEAD:
```
git -C <repo-root-launchd-points-at> fetch origin main
git -C <repo-root-launchd-points-at> status
```
Expected: clean, up to date with `origin/main` — this repo root *is* what
`pressure_sweep.sh`/`tmp_scratch_sweep.sh`/etc. execute, so "deployed"
here means "checked out at the right commit," not "reinstalled."

**Step 4:** If a future, separate change to this plan's scope ever touches
`disk_snapshot.sh`/`disk_audit.sh` (the 35-min snapshot job's uv-tool-packaged
script set), re-apply the full uv-tool dance for that change specifically
— same mechanics as Step 5 below, applied to a different script.

**Step 5 (new, round-3 — Task 8's deploy):** Bump `version` in
`pyproject.toml` (read the current value fresh with `grep -m1 '^version'
pyproject.toml` — do not assume `0.2.100`), then
`uv tool install --force --reinstall .` from repo root, then confirm the
**installed** copy reflects Task 8's migration:
```
find "$(uv tool dir 2>/dev/null)/disk-magician" -name disk_diagnostic.sh \
  -exec grep -l 'agent_scratch_create "disk_diagnostic"' {} \;
```
Expected: at least one match — per the repo's documented 2026-07-11
stale-deploy incident, verify the deployed tree, not the repo.

---

## Out of scope, except where the user has since approved execution

**Round-4 update (2026-09-24):** the user approved all three items below
("finish all") — they are no longer refusal-gated. Each is tracked as its
own executable, ironclad-contracted bead under the epic rather than as a
numbered Task in this plan, because each targets a file outside this
repo's own tree (or, for A2, was redesigned into an in-repo helper plus a
still-gated policy edit — see below) and therefore needs its own
independent-verifier proof separate from this plan's repo-root test suite.

- **A2 (redesigned 2026-09-24):** the original framing — "cross-repo
  worktree-instead-of-clone change in the orchestrator repo(s)" — was
  wrong: there is no separate orchestrator repo; the `~/.claude/state`
  full-clone growth (bead `isw`) is produced by ad hoc interactive Claude
  Code/Codex sessions, not a discrete automation codebase disk_magician
  lacks write access to. Approved, redesigned scope: ship
  `scripts/lib/agent_worktree.sh` in this repo (bead
  `disk_magician-orchestrator-worktree-not-clone-2nw`, TDD pair
  `disk_magician-9n1`) — an in-repo helper any such session can call
  instead of `git clone`. The companion machine-wide policy instruction
  telling sessions to actually call it is Q8 below (kept separate; do not
  conflate the helper and the policy edit).
- **A3 wiring:** `~/.claude/settings.json` Stop-hook registration — bead
  `disk_magician-claude-settings-stop-hook-wiring-if9`. Approved; wires
  Task 6's hook script (already in scope as a Task 6 deliverable) into the
  global config this repo doesn't own.
- **Q8:** `~/.codex/AGENTS.md` agent-scratch policy-rule edit — bead
  `disk_magician-codex-agents-md-scratch-policy-2gp`. Approved for
  execution, but still gated on `~/.codex/AGENTS.md`'s own semantic-signoff
  + behavioral-canary procedure (a content-quality/safety gate independent
  of user authorization — see the bead's Steps for the required pre/post
  canary).
- **Q5:** `colima-prune` `StartInterval` accumulation bug fix — genuinely
  out of scope (VM-image shrink correctness, orthogonal to host-disk-fill
  prevention); not approved or requested; tracked as its own low-priority
  bead, not part of this plan.
- **zyn/4y6:** full ledger/frontier-BFS rearchitecture — genuinely out of
  scope (separate, already-tracked, larger effort); not approved or
  requested; this plan's only touch point is Task 3's 5-line
  ledger-freshness WARN.
