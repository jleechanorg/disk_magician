# Deploy Guard Design — record + surface what is actually live (disk_magician-tli)

## Goal

Close the gap that let PR #68's branch build (0.2.98,
`fix/harness-snapshot-floor-gate`) run in production for hours on
2026-09-11 while `main` was at 0.2.96 — without re-litigating fail-closed
logic that already exists and already works.

## Critical finding: the fail-closed guard already exists

`tools/deploy_uv_tool.sh` (added PR #31, `8651608`, 2026-07-26; smoke check
added PR #37, `7fbc2e7`) already does almost everything
`disk_magician-tli` asks for:

- `git fetch --quiet origin main`, then refuses a dirty tree
  (`git status --porcelain`) unconditionally.
- Refuses when `HEAD` != `origin/main` — **exactly** the PR #68 scenario —
  with a clear stderr message naming both SHAs.
- After install, re-verifies the installed version, diffs every file in
  the deployed package root byte-for-byte against `src/disk_magician/`
  (missing, extra, and mismatched files are all failures), and smoke-tests
  the installed entrypoint (`disk-magician --help`) before printing success.
- Is already covered by `tests/test_deploy_uv_tool.sh`, which already runs
  in CI (`tests/test_*.sh` glob in `.github/workflows/ci.yml:62`).

**So the branch build did not reach production because the guard failed to
fail closed — it reached production because nothing invoked the guard.**
`CLAUDE.md` § Deployment (the repo's own canonical, checked-in procedure)
currently instructs: *"...then `uv tool install --force --reinstall <repo
path>`"* — a bare command that bypasses `tools/deploy_uv_tool.sh` entirely.
Grepping the repo for `uv tool install` (outside `tests/` and
`tools/deploy_uv_tool.sh` itself) finds it recommended directly in three
more roadmap docs and in `CLAUDE.md`, and finds **zero** other reference to
`tools/deploy_uv_tool.sh` existing at all. An agent following the
documented procedure literally, in good faith, reproduces the incident.

This reframes the remaining work from "build a guard" to: (1) close the
two real capability gaps the bead names (a sanctioned branch-override, and
a durable deployed-state record other tooling can read), and (2) fix the
documentation so the existing guard is actually the path agents take.

## Assumptions and Recommended Defaults

- **Where should the deploy state live?** `~/.disk_magician_state/deployed.json`,
  overridable via `DISK_MAGICIAN_DEPLOYED_JSON`. Matches the existing
  convention of `DISK_MAGICIAN_FRONTIER_JSON` (`scripts/snapshot_commit.sh:14`)
  and the `~/.disk_magician_state/*.json` state files already in use
  (`frontier_last.json`, `discover_last.json`, `coverage_streak.json`).
  Recommended: yes, no other candidate location fits the repo's existing
  pattern.
- **Does `DEPLOY_FROM_BRANCH_APPROVED=1` also waive the dirty-tree check?**
  No. The bead and the incident are both about *which commit* got deployed,
  not about uncommitted local edits; there is no legitimate reason to
  deploy an uncommitted tree, branch or not. The override affects only the
  `HEAD` == `origin/main` comparison. Recommended: yes, keep dirty-tree
  refusal absolute and unconditional.
- **Should `check_launchd_fleet.sh` fail (exit 1) when the deployed SHA
  isn't `origin/main`?** No — only report it. The bead's acceptance
  criterion is "reports deployed version + SHA", not "fails on drift", and
  a `DEPLOY_FROM_BRANCH_APPROVED=1` deploy is by definition an intentional,
  already-approved state. `check_launchd_fleet.sh`'s own header states its
  contract is "Read-only; never modifies anything" and its exit code
  (0/1) already carries a distinct, load-bearing meaning — launchd fleet
  liveness — consumed by `disk_audit.sh`/`disk_magician.sh clean` as
  Step -1. Conflating "fleet is loaded" with "deployed code is fresh"
  would break that existing contract. Recommended: an unconditional
  read-only report line, no exit-code change.
- **File-scope deviation from the dispatch instructions.** The dispatch
  asked for the guard to live in *new files plus at most
  `sync_package_tree.sh`*, to stay disjoint from lane zyn
  (`disk_magician.sh`) and lane hyr (`check_launchd_fleet.sh`). That
  guidance predates discovering `tools/deploy_uv_tool.sh` already exists,
  is already tested, and is not owned by either lane. Reimplementing its
  ~40 lines of git/uv verification logic inside `sync_package_tree.sh`
  (a file whose own tests assume it only ever syncs files, never touches
  git remotes or `uv`) would duplicate proven logic and diverge from the
  passing test suite for no isolation benefit — `tools/deploy_uv_tool.sh`
  touches neither `disk_magician.sh` nor `check_launchd_fleet.sh`, so lane
  disjointness is preserved either way. **Recommended: edit
  `tools/deploy_uv_tool.sh` directly.** Flagging this explicitly for the
  integrator since it wasn't anticipated at dispatch time.
- **Version bump?** None needed. `tools/deploy_uv_tool.sh` is outside
  `scripts/sync_package_tree.sh`'s `PATTERNS` (not mirrored into
  `src/disk_magician/`) and outside `pyproject.toml`'s
  `tool.setuptools.package-data` list — it is a dev-only operator script,
  never shipped inside the uv-installed package. The fix takes effect on
  the *next* deploy regardless of `pyproject.toml`'s version.

## Options Considered

1. **New `scripts/deploy.sh` wrapper calling `tools/deploy_uv_tool.sh`.**
   Rejected — pure indirection; `tools/deploy_uv_tool.sh` is already the
   sanctioned entry point per its own test file's name and content, it is
   only undocumented, not misnamed or misplaced.
2. **Guard logic inside `scripts/sync_package_tree.sh`.** Rejected — that
   script's single responsibility is file synchronization
   (root → `src/disk_magician/`); its own test suite
   (`tests/test_package_sync.sh`) has no concept of git remotes, `uv`, or
   installed-package verification. Mixing concerns here would require a
   second, parallel test harness for behavior `tools/deploy_uv_tool.sh`
   already has covered.
3. **Extend `tools/deploy_uv_tool.sh` in place: add a branch-override env
   var, a deployed-state JSON write, and fix `CLAUDE.md` to route through
   it.** Selected. Minimal diff, reuses the existing fail-closed logic and
   its passing test harness, and directly targets the two real gaps
   (branch override; durable state) plus the actual root cause
   (undocumented / bypassed guard).

## Design

`tools/deploy_uv_tool.sh` gains:

1. **`DEPLOY_FROM_BRANCH_APPROVED=1`** — when the `HEAD` vs `origin/main`
   comparison fails, this env var, if set to `1`, converts the refusal
   into a loud stderr `WARNING` (naming the branch, the local SHA, and the
   `origin/main` SHA) and lets execution continue. It never silently
   changes behavior — the warning always fires whenever the override is
   the reason execution continued, both in `--check` and full-deploy mode.
2. **`~/.disk_magician_state/deployed.json`** — written only after every
   other check (dirty-tree, branch/HEAD, version match, file-diff, smoke
   test) has already passed, i.e. only on a fully successful, verified
   deploy. Contains `version`, `sha` (`HEAD`), `branch`
   (`git rev-parse --abbrev-ref HEAD`), `approved_from_branch` (bool, true
   only if the override was the reason `HEAD` diverged from
   `origin/main`), and `deployed_at` (UTC ISO-8601). Written via a small
   inline `python3 -c` block emitting `json.dump(...)` — the repo already
   shells out to `python3` elsewhere in this exact script (installed
   version check) and in `disk_snapshot.sh`/`snapshot_commit.sh` for other
   state JSON, and hand-built JSON string interpolation is one of this
   repo's own documented traps to avoid for anything with an
   unpredictable value (branch names can contain arbitrary characters).
3. **`CLAUDE.md` § Deployment** gets one paragraph rewritten (below) so
   the canonical, checked-in procedure names `tools/deploy_uv_tool.sh`
   instead of a bare `uv tool install`, and records the 2026-09-11
   recurrence next to the 2026-07-11 incident it already documents.
4. **`check_launchd_fleet.sh`** (owned by a separate lane) gets a
   read-only "Deployed: version=… sha=… branch=… approved_from_branch=…
   at=…" line appended to its existing summary output, sourced from the
   same `deployed.json`. Delivered here as an exact snippet for the
   integrator, not applied in this worktree.

### Exact `CLAUDE.md` § Deployment replacement paragraph

Replace the current paragraph:

> After changing root scripts: run `scripts/sync_package_tree.sh` (use
> `--check` in review), **bump the version in pyproject.toml** (uv caches
> wheels by version), then `uv tool install --force --reinstall <repo path>`.
> Verify the deployed tree, not the repo, before claiming production behavior
> (stale-deploy incident 2026-07-11: v2 code was committed for hours while
> production ran v1).

with:

> After changing root scripts: run `scripts/sync_package_tree.sh` (use
> `--check` in review), **bump the version in pyproject.toml** (uv caches
> wheels by version), commit and merge to `main`, then deploy with
> `tools/deploy_uv_tool.sh` — never a bare `uv tool install`. The script
> fails closed unless the source checkout is a clean `HEAD` exactly
> matching `origin/main` (set `DEPLOY_FROM_BRANCH_APPROVED=1` only for an
> intentional, explicitly-approved branch-testing deploy; it is recorded
> as such and is never silent), then verifies the installed version, diffs
> every deployed file against `src/disk_magician/`, and smoke-tests the
> installed entrypoint before reporting success. It records the deployed
> SHA/version/branch to `~/.disk_magician_state/deployed.json`
> (`check_launchd_fleet.sh` reports this line). Verify the deployed tree,
> not the repo, before claiming production behavior (stale-deploy incident
> 2026-07-11: v2 code was committed for hours while production ran v1;
> recurrence 2026-09-11: a PR branch build reached production because this
> section's own prior text told agents to run `uv tool install` directly,
> bypassing the guard — bead `disk_magician-tli`).

### `check_launchd_fleet.sh` integration snippet (for lane hyr, not applied here)

Place immediately after the existing `echo "  Fleet: $ok/$total loaded and valid."`
line and before the `if [[ $((missing + not_loaded + invalid)) -gt 0 ]]; then`
exit-code decision, so it never affects the script's exit code:

```bash
deployed_json="${DISK_MAGICIAN_DEPLOYED_JSON:-$HOME/.disk_magician_state/deployed.json}"
if [[ -f "$deployed_json" ]]; then
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  Deployed: version={d[\"version\"]} sha={d[\"sha\"][:12]} branch={d[\"branch\"]} approved_from_branch={d[\"approved_from_branch\"]} at={d[\"deployed_at\"]}")
' "$deployed_json" 2>/dev/null || echo "  Deployed: $deployed_json exists but is unreadable/malformed"
else
  echo "  Deployed: no record at $deployed_json (never deployed via tools/deploy_uv_tool.sh since this guard shipped)"
fi
```

## Error Handling and Evidence

- Dirty tree: unconditional refusal, unaffected by this change (regression
  covered by the existing "dirty source is refused" test case).
- `HEAD` != `origin/main`, no override: unconditional refusal, unchanged
  message plus the new hint to set `DEPLOY_FROM_BRANCH_APPROVED=1`
  (regression covered by the existing "branch-ahead source is refused"
  test case, restructured onto a realistically-named feature branch so
  the `branch` field in `deployed.json` is meaningfully exercised).
- `HEAD` != `origin/main`, override set: proceeds, prints `WARNING` on
  stderr, and — on a full (non-`--check`) deploy — writes
  `approved_from_branch: true` to `deployed.json` (new tests).
- Any successful full deploy (override or not) writes
  `deployed.json` with the exact `sha`/`version`/`branch` of the deployed
  commit (new tests, one per branch of the override).
- A failed deploy (stale deployed file mismatch, smoke failure, etc.)
  never writes `deployed.json` — the write is the last statement in the
  script, after every failure path has already `exit 1`ed (existing
  "installed-only stale package file is refused" test is unaffected and
  additionally asserts no `deployed.json` appears).
- Final evidence: `bash tests/test_deploy_uv_tool.sh` locally (all cases
  green), `bash scripts/sync_package_tree.sh --check` (must remain clean —
  `tools/` is intentionally outside its `PATTERNS`), and
  `shellcheck --severity=error --external-sources tools/deploy_uv_tool.sh`.
