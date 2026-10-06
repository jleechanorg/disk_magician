# One worktree root, evidence in /tmp or GCS — design

Date: 2026-10-05
Status: Design (approved via `/sq` auto-pick; implementation tracked in the plan)
Plan: `docs/superpowers/plans/2026-10-05-standard-worktree-root-and-evidence-location.md`

## Problem

Agents write two classes of disk-heavy output wherever they like, so the disk
refills faster than sweepers can find it (session 2026-10-05: a 66 GiB
worktree blind spot under `~/wc-wt` + `~/project_worldaiclaw` made every sweep
report zero).

Measured 2026-10-05 (read-only scout workflow `wf_6ad9e6d6-7e6`):

- **Worktrees:** ~780 registered linked worktrees across 30+ parent roots,
  plus 164 unregistered `.git`-file dirs (114 with a dead `gitdir`). Largest
  roots: `~/projects/worktree_*` (284), flat `~/projects/<name>` (172),
  `~/projects/<task>-<rand8>/` (~55), `~/project_worldaiclaw` (25), `~/wc-wt`
  (18), `<repo>/.claude/worktrees` (~20), `~/.mctrl/worktrees` (34, dead),
  `/private/tmp/*` (~55). `~/.worktrees` — the AO root — holds only ~30.
- **Creators:** Codex agents (`mktemp -d ~/projects/worktree_<slug>_XXXX` +
  `git worktree add`) are the dominant source. Others: skills with hard-coded
  paths (`superpowers-using-git-worktrees` in-repo `.worktrees`,
  `claude-code-claudem` `/tmp/claudem-*`, `headless` relative
  `headless_<ts>`, `factory-evolve` `../worktree-*`), Claude Code isolation
  (`<repo>/.claude/worktrees`), dark-factory review snapshots
  (`~/.dark-factory/review-snapshots`), Codex app (`~/.codex/worktrees`).
  AO `worktreeDir` values are already all under `~/.worktrees/`.
- **Evidence:** policy (`~/.codex/AGENTS.md` "Workspace and method
  fidelity") already says `/tmp`, but evidence lands in `~/dk2d_evidence`
  (3.3 GiB), other `~/*evidence*` dirs (~1.7 GiB), `~/Downloads`,
  `~/.codex/evidence-*`, and evidence dirs inside worktrees. Three skills
  (`testing-gap-close`, `pr-babysit`, `pre-cr-checklist`) still mandate
  in-repo `docs/evidence/pr-<N>/`, which WorldArchitect CI
  (`validate_pr_evidence.sh` Check 6) now *forbids*. No skill mentions GCS.
- **Enforcement:** none. No hook inspects `git worktree add`; the global git
  `post-checkout` hook is bypassed by repos with a local `core.hooksPath`
  (worldarchitect.ai uses husky). The Codex `path-deletion-guard.py`
  allowlist is `~/projects` + temp dirs, so Codex agents are *pushed toward*
  `~/projects` and cannot clean up under `~/.worktrees`.
- **Sweeper gaps:** `cleanup_worktrees.sh` discovery omits `~/.worktrees`
  and its path filter (`:378-387`) never matches `~/.worktrees/<repo>/<name>`;
  `cleanup_worktree_venvs.sh` roots omit it; `config/sweeper_roots.txt`
  does not register it.

## Goals

1. Every new git worktree on this machine is created under
   `~/.worktrees/` (recommended layout `~/.worktrees/<repo>/<name>`).
2. Every new evidence artifact is written under `/tmp/<repo>/evidence/...`
   (scratch) and, when it must outlive a reboot or review cycle, published to
   an unlisted gist (repos whose gate requires it) or
   `gs://wa-test-evidence/agent-evidence/<repo>/<slug>/`.
3. Violations are prevented at creation time where a hook surface exists,
   and reported by `diskm` everywhere else.
4. The standard root is swept by the existing 7-day-floor worktree sweepers.

## Non-goals

- Moving existing worktrees. `git worktree move` under a live agent cwd is the
  "lose a worktree with extra steps" incident class (repo `CLAUDE.md`). Legacy
  roots stay registered with the sweepers and age out under the 7-day rule.
- Auto-uploading or auto-deleting existing home-dir evidence. `diskm` reports
  it; `cleanup_downloads_evidence.sh` keeps its current retention.
- Weakening the 7-day recency floor, `WORKTREE_APPROVED=1`, or the never-delete
  list.
- Changing AO (its `worktreeDir` values already comply).

## Approaches considered

| Approach | Verdict |
|---|---|
| A. Policy text + skill edits only | Rejected: the dominant creator (Codex mktemp) ignores prose today; nothing catches regressions. |
| B. Capped APFS scratch volume for worktrees + evidence | Deferred: strongest cap, but needs `diskutil` volume creation and moving `~/.worktrees`; revisit if A+C+D does not bend growth. |
| **C. Creation-time hook guard + policy + skills + diskm report (chosen)** | Blocks the two runtimes that create most worktrees (Claude, Codex) at the tool layer, fixes the instructions that point elsewhere, and makes every bypass visible in `diskm`. |

## Design

### D1. The standard

- Worktree root: `$HOME/.worktrees`. Any path at or below
  `$HOME/.worktrees/<something>/` is compliant; `<repo>/<name>` is the
  recommended layout (`<repo>` = basename of the main checkout's toplevel).
- Evidence scratch root: `/tmp/<repo>/evidence/<slug>/`.
- Evidence durable store: unlisted gist where a repo gate requires it
  (WorldArchitect), else `gs://wa-test-evidence/agent-evidence/<repo>/<slug>/`.
- Single source of truth: `scripts/lib/layout_standard.sh` exports
  `STANDARD_WORKTREE_ROOT`, `EVIDENCE_TMP_ROOT`, `EVIDENCE_GCS_PREFIX`, and
  `standard_worktree_path <repo> <name>`; overridable by env for tests.

### D2. `diskm worktree-new` (creation helper)

`diskm worktree-new <repo-path> <branch> [--base <ref>] [--name <name>]` runs
`git -C <repo> worktree add -b <branch> ~/.worktrees/<repo>/<name> <base>`
(existing branch → no `-b`) and prints the absolute path. It replaces the
approved-but-unbuilt `agent_worktree.sh` helper (beads `2nw`/`9n1`), whose
`/private/var/tmp/agent-worktrees` default is superseded: a home-dir root
survives reboot, and `/private/var/tmp` is a second root, the opposite of
the goal.

### D3. Creation-time guard (Claude Code + Codex PreToolUse)

`diskm guard-worktree-add` reads the PreToolUse JSON on stdin. For shell
tools whose command contains `git … worktree add`, it resolves the target
path (relative to `tool_input.workdir`/`cwd`, after `cd` prefixes it can
parse) and:

- target under `$STANDARD_WORKTREE_ROOT` → allow (exit 0, no stdout);
- target elsewhere → deny with
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Worktrees go under ~/.worktrees/<repo>/<name>. Use: diskm worktree-new <repo> <branch>"}}`;
- target given via a variable assigned earlier in the same command
  (`WT=<literal>` or `WT=$(mktemp -d <template>)`) → resolve it (a `mktemp`
  template's directory prefix is literal) and judge it as above. This covers
  the dominant Codex pattern `WT=$(mktemp -d ~/projects/worktree_X_XXXX) &&
  git worktree add "$WT"`;
- target still not statically resolvable → allow and append a line to `~/.disk_magician_state/worktree_guard.log`.
  Fail-open here is deliberate: this is a placement guard, not a safety gate;
  a fail-closed guard would block every skill that builds paths in shell
  variables. `diskm layout-check` (D5) catches what slips through.
- any other command → allow immediately (pre-filter on the substring
  `worktree` before JSON parsing, for latency).

Registered in `~/.claude/settings.json` (PreToolUse, matcher `Bash`) and
`~/.codex/hooks.json` (PreToolUse, matcher `Bash`). Latency budget: p50
< 150 ms; if exceeded, register the packaged script path directly instead
of the `diskm` wrapper.

Claude Code's own isolation (`EnterWorktree`, `Agent isolation:'worktree'`,
`claude -w`) does not go through Bash. A `WorktreeCreate` hook
(`diskm worktree-create-hook`) creates the worktree under
`~/.worktrees/<repo>/<name>` and prints the path (contract in
Implementation Preconditions P1). `<repo>` is derived from
`git rev-parse --git-common-dir` so a `cwd` inside an existing worktree still
maps to the main repo. Because Claude's contract fails closed (any non-zero
exit or hang breaks every `isolation:"worktree"` agent), the hook never
fetches, wraps `git worktree add` in a 30 s timeout, uses a unique branch
(`worktree-<name>`, suffixed `-<n>` on collision), and honors
`DISK_MAGICIAN_WORKTREE_HOOK=off` by falling back to
`<repo>/.claude/worktrees/<name>`. It is registered only after a live canary
(plan Lane D step 3) passes.

### D4. Codex deletion guard alignment

Add `$HOME/.worktrees` to `DEFAULT_ALLOW_ROOTS` in
`~/.codex/hooks/path-deletion-guard.py` and change its block message to
"Move it under ~/.worktrees, ~/projects, or /tmp". Without this, D3 makes
Codex agents create worktrees they cannot remove.

### D5. `diskm layout-check` (report-only detector)

Reports, without deleting anything:

1. Linked worktrees (via `git worktree list --porcelain` over
   `discover_worktree_repos` plus the legacy roots) whose path is outside
   `$STANDARD_WORKTREE_ROOT`, grouped by parent root, with count and
   `worktree_age_days`.
2. Evidence-named directories outside `/tmp` and outside worktrees: top-level
   `~/*evidence*`, `~/dk2d_*`, `~/Downloads/*evidence*`,
   `~/.codex/evidence-*` (bounded `find -maxdepth 2`, `timeout`).
3. Guard-log bypasses from the last 7 days.

Output: human table and `--json`. Wired as a section of `diskm audit` and run
by the existing residual-drilldown launchd job (no new plist). Exit 0 always
(report), so it never fails a scheduled run.

### D6. Sweeper coverage of the standard root

- `cleanup_worktrees.sh`: add `find_repos_from_worktrees "$HOME/.worktrees"`
  and accept paths under `$STANDARD_WORKTREE_ROOT/` in the candidate filter,
  **except** paths under any AO `worktreeDir` from
  `~/.hermes/agent-orchestrator.yaml` (AO owns those session lifecycles) and
  any worktree that is the cwd of a live process (one `lsof -d cwd -Fn`
  snapshot per run, fail closed: if `lsof` fails, skip the whole standard
  root that run). Raised by `/advice` (Opus): without this, long-idle but
  still-claimed AO sessions would become force-removable.
  Keeps the uncommitted `~/wc-wt` / `~/project_worldaiclaw` lines.
- `cleanup_worktree_venvs.sh`: add `$HOME/.worktrees` to default roots.
- `config/sweeper_roots.txt`: register `$HOME/.worktrees` → `cleanup_worktrees.sh`.
- All deletion still goes through `worktree_age_days`, the 7-day clamp and
  `WORKTREE_APPROVED=1`. No new deletion logic.

### D7. Policy and skills

- `~/.codex/AGENTS.md` (shared by Claude + Codex), "Workspace and method
  fidelity": add one sentence — "Create git worktrees only under
  `~/.worktrees/<repo>/<name>` (use `diskm worktree-new`); write evidence to
  `/tmp/<repo>/evidence/...` and publish durable copies to an unlisted gist
  or `gs://wa-test-evidence/agent-evidence/<repo>/`, never into a repo tree
  or `$HOME`." This closes bead `2gp`. Subject to the file's semantic-signoff
  canary (agent still proceeds without asking; cites source).
- Skills: `superpowers-using-git-worktrees` (location step → standard root),
  `claude-code-claudem` (`/tmp/claudem-*` → standard root), `headless`
  (relative dir → standard root), `factory-evolve` (`../worktree-*` →
  standard root), `testing-gap-close` / `pr-babysit` / `pre-cr-checklist`
  (drop `docs/evidence/pr-<N>/`; publish to gist/GCS), `evidence-standards`
  (add the GCS durable-store option and `/tmp/<repo>/evidence` namespace).
- dark-factory `runner/review_snapshot.py:_default_snapshot_root` →
  `~/.worktrees/dark-factory-review-snapshots` (separate repo; PR delegated
  to `/dot`).

### D8. GCS durable store

Reuse `gs://wa-test-evidence` (exists, authenticated) under prefix
`agent-evidence/`. Add a lifecycle rule scoped by `matchesPrefix:
["agent-evidence/"]` deleting objects after 30 days, so other prefixes are
untouched. Upload with `gcloud storage rsync -r <dir> gs://…/<repo>/<slug>/`
and cite the `gs://` URI plus an authenticated console URL. A `diskm
evidence-push <dir> --repo <repo> --slug <slug>` wrapper keeps this on the
single CLI.

## Assumptions and Recommended Defaults

| Question | Auto-picked answer | Rationale |
|---|---|---|
| Which single worktree root? | `~/.worktrees` | AO already uses it for every project; discovery lib already scans it; survives reboot (worktrees hold unpushed work). |
| `/tmp` for worktrees too? | No | Reboot wipes `/tmp` (only 1 entry predates the 10-03 boot); conflicts with 7-day protection. |
| Layout under root? | `<repo>/<name>` recommended; any subpath compliant | AO uses flat `<project>-main`; strict layout would break AO for no disk benefit. |
| Block or warn on violations? | Block statically resolvable `git worktree add` outside root; warn (log) when unresolvable | Blocking is the only thing that changes Codex behavior; fail-open on unparseable avoids breaking variable-built paths. |
| Move existing worktrees? | No; age out | Moving live worktrees risks agent cwd loss / unpushed work. |
| Durable evidence store? | Gist where repo gate requires; else `gs://wa-test-evidence/agent-evidence/` | WA CI requires gist; bucket exists and auth works; avoids creating new buckets. |
| GCS retention? | 30-day lifecycle on `agent-evidence/` prefix only | Bounded cost, does not touch existing prefixes. |
| Protect `/tmp/<repo>/evidence` from 24h `--large` purge? | No | `/tmp` is defined as scratch; durable copies go to gist/GCS immediately. |
| New launchd job for layout-check? | No; reuse residual-drilldown + `audit` | Fewer jobs to keep alive (fleet-flapping history). |
| Supersede `2nw`/`9n1` helper? | Yes, with `diskm worktree-new` at `~/.worktrees` | One root, one CLI entry point. |
| Capped scratch volume? | Deferred | Bigger change; revisit with measured growth after rollout. |

## Implementation Preconditions

- **P1 (resolved 2026-10-05)** `WorktreeCreate` contract, per
  https://code.claude.com/docs/en/hooks#worktreecreate: stdin carries `name`
  and `cwd` (no ref, no base path); the hook fully replaces `git worktree
  add`; the last non-empty stdout line is the absolute path; non-zero exit
  fails creation; the path must be outside any repo checkout and not a
  symlink. Without a `WorktreeRemove` hook Claude falls back to `git worktree
  remove --force <path>`; Claude's own sweep skips hook-created worktrees, so
  our `~/.worktrees` discovery (D6) must cover them. The hook branches from
  `origin/HEAD` (fallback `HEAD`), matching the default `worktree.baseRef:
  fresh`, on branch `worktree-<name>`. Must be live-tested with an
  `isolation: "worktree"` subagent before claiming it works.
- **P2** GCS write: `gcloud storage cp` of a 1-byte probe to
  `gs://wa-test-evidence/agent-evidence/_probe` must succeed before the
  lifecycle rule and `evidence-push` ship.

## Verification

- Unit/shell tests per component (see plan), run under a temp `HOME`.
- Live: a `git worktree add /tmp/x-wt` via Claude Bash is denied with the
  message; `diskm worktree-new` creates under `~/.worktrees/`; Codex
  `codex exec` attempting the same is denied.
- `diskm layout-check --json` lists the legacy roots with counts.
- Deployed via `tools/deploy_uv_tool.sh`; `diskm --version` matches bump.

## Risks

- Codex CLI usage limit (resets 2026-10-10 23:31): Codex-side live checks
  (policy canary, `codex exec` deny test) wait until then; the Codex hook
  registration itself does not.
- Guard false-deny on an exotic but compliant path → message names the
  helper; env `DISK_MAGICIAN_WORKTREE_GUARD=off` disables it per session.
- Hook latency on every Bash call → substring pre-filter, measured budget.
- Policy edit drift → canary check per `~/.codex/AGENTS.md` signoff rule.
