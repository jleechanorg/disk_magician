# Standard worktree root + evidence location — implementation plan

Spec: `docs/superpowers/specs/2026-10-05-standard-worktree-root-and-evidence-location-design.md`

**Goal:** new worktrees only under `~/.worktrees/`, evidence only under
`/tmp/<repo>/evidence/` or gist/GCS, enforced by hooks and reported by `diskm`.

**Architecture:** all logic ships in disk_magician behind `diskm` subcommands
(single entry point); live config (`~/.claude/settings.json`,
`~/.codex/hooks.json`, `~/.codex/AGENTS.md`, skills) only *registers* or
*points to* those subcommands.

**Conventions for every task:** TDD (failing test first, run it, then code);
tests run under a temp `HOME` and never touch real worktrees; new shell code
passes `bash -n` + `shellcheck --severity=error --external-sources`; never
`stat` a worktree for age (use `scripts/lib/worktree_recency.sh`); never
`plutil -extract` without `-o -`.

Work happens in worktree `~/.worktrees/disk_magician/standard-layout` on
branch `feat/standard-worktree-root-evidence` (dogfoods the standard).

## Lane A — disk_magician code (one PR)

### A1. `scripts/lib/layout_standard.sh`
- Test `tests/test_layout_standard.sh`: with `HOME=$tmp`, sourcing yields
  `STANDARD_WORKTREE_ROOT=$tmp/.worktrees`, `EVIDENCE_TMP_ROOT=/tmp`,
  `EVIDENCE_GCS_PREFIX=gs://wa-test-evidence/agent-evidence`; env overrides
  win; `standard_worktree_path myrepo feat-x` → `$tmp/.worktrees/myrepo/feat-x`;
  `path_is_under_standard_root` true for `$tmp/.worktrees/a/b`, false for
  `$tmp/.worktreesX/a`, `/tmp/a`, and for `..` escapes.
- Implement: exports + two functions; resolve with `cd -P`/python realpath for
  existing parents, lexical normalization otherwise.

### A2. `diskm worktree-new`
- Test `tests/test_worktree_new.sh`: in a temp git repo with an `origin`,
  `diskm worktree-new <repo> feat/x` creates
  `$HOME/.worktrees/<repo-basename>/feat-x` on new branch `feat/x` from
  `origin/HEAD` (fallback `HEAD`); `--base`, `--name` honored; existing branch
  checked out without `-b`; existing target path → exit 1, nothing created;
  stdout is exactly the absolute path.
- Implement `scripts/worktree_new.sh`; dispatch arm
  `worktree_new|worktree-new` + help line in `disk_magician.sh`.

### A3. `diskm guard-worktree-add` (PreToolUse guard)
- Test `tests/test_worktree_guard.py` (unittest, feeds JSON on stdin):
  - non-Bash tool or command without `worktree` → exit 0, empty stdout;
  - `git worktree add /tmp/x -b b` → deny JSON (schema in spec D3) whose
    reason names `diskm worktree-new`;
  - `git -C /r worktree add ../wt` with `cwd=/r` → resolves `/wt` → deny;
  - `cd ~/.worktrees/r && git worktree add ./n` → allow;
  - `git worktree add "$HOME/.worktrees/r/n"` and `~/.worktrees/r/n` → allow
    (expand `$HOME`/`~` only);
  - `WT=$(mktemp -d /tmp/x_XXXX) && git worktree add "$WT"` → deny;
    `WT=$(mktemp -d $HOME/.worktrees/r/x_XXXX) && git worktree add "$WT"` →
    allow; `WT=/tmp/y; git worktree add $WT` → deny;
  - `git worktree add "$WT"` with no in-command assignment / bare
    `$(mktemp -d)` → allow + log line in
    `$HOME/.disk_magician_state/worktree_guard.log`;
  - `git worktree list` / `remove` / `prune` → allow;
  - `DISK_MAGICIAN_WORKTREE_GUARD=off` → allow;
  - malformed stdin → allow (placement guard is fail-open, see spec D3);
  - chained `a && git worktree add /tmp/y` → deny.
- Implement `scripts/worktree_guard.py` (stdlib only, `shlex` per `&&`/`;`/`|`
  segment; first non-option arg after `add` is the path; skip values of
  `-b/-B/--reason`); dispatch `guard_worktree_add|guard-worktree-add`.
- Latency: `for i in $(seq 20); do /usr/bin/time diskm guard-worktree-add < ls.json; done`;
  record p50. If > 150 ms, the hook registration in B1 uses
  `python3 <installed pkg>/scripts/worktree_guard.py` instead of `diskm`.

### A4. `diskm worktree-create-hook` (Claude `WorktreeCreate`)
- Test `tests/test_worktree_create_hook.sh`: stdin
  `{"name":"bold-oak","cwd":"<repo>/sub"}` → creates
  `$HOME/.worktrees/<repo>/bold-oak` on branch `worktree-bold-oak` from
  `origin/HEAD` (fallback `HEAD`), last stdout line is that path, git output
  on stderr; `cwd` inside an existing linked worktree maps to the main repo via
  `--git-common-dir`; non-repo cwd → exit 1; name with `/` or `..` → exit 1;
  existing branch `worktree-bold-oak` → uses `worktree-bold-oak-2`; no
  `git fetch` is ever invoked (fake `git` wrapper on PATH asserts it);
  `DISK_MAGICIAN_WORKTREE_HOOK=off` → path `<repo>/.claude/worktrees/bold-oak`.
- Implement `scripts/worktree_create_hook.sh` reusing A2's function; dispatch
  `worktree_create_hook|worktree-create-hook`.

### A5. `diskm layout-check`
- Test `tests/test_layout_check.py`: temp HOME with one repo having worktrees
  at `$HOME/.worktrees/r/a` (compliant), `$HOME/projects/worktree_b`,
  `/tmp/<unique>/c`; evidence dirs `$HOME/dk2d_evidence`,
  `$HOME/Downloads/x_evidence`, `$HOME/.codex/evidence-pr1`; guard log with
  2 entries. `--json` output: `worktrees_outside_root` grouped by parent with
  counts (b, c — not a), `evidence_outside_tmp` (3 paths), `guard_bypasses_7d`
  == 2; exit 0 always; finishes < 60 s with every subprocess under `timeout`.
- Implement `scripts/layout_check.py`, using
  `scripts/lib/worktree_repo_discovery.sh` (via `bash -c`) plus legacy roots
  `~/wc-wt ~/project_worldaiclaw ~/worktrees ~/.mctrl/worktrees` for repo
  discovery; `git worktree list --porcelain` per repo; age via
  `worktree_recency.sh`. Dispatch `layout_check|layout-check`; add as a
  section in `scripts/disk_audit.sh` and a step in
  `scripts/residual_drilldown.sh` (report only).

### A6. Sweepers cover `~/.worktrees`
- Extend `tests/test_cleanup_worktrees_repo_local.sh`: a 10-day-old (content
  mtime) merged clean worktree at `$HOME/.worktrees/r/old` is listed ELIGIBLE;
  a 2-day-old one is protected; a 10-day-old one under a fake AO
  `worktreeDir` (fixture yaml via `DISK_MAGICIAN_AO_CONFIG`) is skipped; one
  that is the cwd of a live `sleep` process is skipped; a failing `lsof`
  (fake on PATH) skips the whole standard root; the existing `~/wc-wt`/`~/project_worldaiclaw`
  discovery lines remain.
- `scripts/cleanup_worktrees.sh`: add `find_repos_from_worktrees
  "$HOME/.worktrees"` beside `:95-98` (keep the uncommitted 2 lines) and accept
  `"$abs_path" == "$STANDARD_WORKTREE_ROOT/"*` in the filter at `:378-387`,
  excluding AO `worktreeDir` roots and live-cwd worktrees as in spec D6.
- `scripts/cleanup_worktree_venvs.sh:58-60`: add `$HOME/.worktrees`; extend
  `tests/test_cleanup_worktree_venvs.sh` accordingly.
- `config/sweeper_roots.txt`: add `$HOME/.worktrees\tcleanup_worktrees.sh\tstandard worktree root`;
  update `tests/test_check_uncovered_roots.py` if it pins the registry.

### A7. `diskm evidence-push`
- Test `tests/test_evidence_push.sh` with a fake `gcloud` on `PATH` that logs
  argv: `diskm evidence-push /tmp/r/evidence/s --repo r --slug s` runs
  `gcloud storage rsync -r /tmp/r/evidence/s gs://wa-test-evidence/agent-evidence/r/s/`
  and prints the `gs://` URI and
  `https://console.cloud.google.com/storage/browser/wa-test-evidence/agent-evidence/r/s`;
  source outside `/tmp`/`/private/tmp` → exit 2 (no upload); missing gcloud →
  exit 1; secret-shaped filenames (`.env`, `*.pem`, `id_rsa*`) → refuse.
- Implement `scripts/evidence_push.sh`; dispatch `evidence_push|evidence-push`.

### A8. Package, verify, PR, deploy
- `bash scripts/sync_package_tree.sh`; bump `pyproject.toml` version
  (0.2.132 → next); run the CI-equivalent sequence:
  `bash scripts/sync_package_tree.sh --check && python3 scripts/check_version_monotonic.py && bash -n` +
  shellcheck over changed files, `python3 -m unittest discover -s tests -p 'test_*.py'`,
  and every `tests/test_*.sh` with `timeout 300`.
- Commit (message ends `[claude][claude-opus-5-5]`), push, open PR with CLI +
  model labels, drive `/green`, merge (disk_magician is not under the
  worldarchitect.ai merge gate), then `tools/deploy_uv_tool.sh` from a clean
  `origin/main` checkout; verify `diskm guard-worktree-add`,
  `diskm layout-check --json`, `diskm worktree-new --help` from the installed
  tool and `~/.disk_magician_state/deployed.json` hash.

## Lane B — live config (after A8 is deployed)

### B1. Register hooks
- Back up `~/.claude/settings.json` and `~/.codex/hooks.json` to
  `<file>.bak.20261005-standard-layout`.
- Claude: add PreToolUse `{matcher:"Bash", hooks:[{type:"command", command:"diskm guard-worktree-add"}]}`.
  Register `WorktreeCreate: [{hooks:[{type:"command", command:"diskm worktree-create-hook", timeout: 60}]}]`
  only after a canary: run one `isolation:"worktree"` subagent with the hook
  in a project-local `.claude/settings.local.json` of a scratch repo, confirm
  its `pwd` is under `~/.worktrees/` and removal works, then promote to the
  global file
  (edit JSON with `python3 -c 'json.load/dump'`, preserving other keys).
- Codex: add the same PreToolUse Bash entry to `~/.codex/hooks.json`.
- Verify both files parse (`python3 -m json.tool`).

### B2. Codex deletion guard
- `~/.codex/hooks/path-deletion-guard.py`: add `$HOME/.worktrees` to the
  allowlist; block message → "Move it under ~/.worktrees, ~/projects, or /tmp
  (or $TMPDIR)". Run its tests in `~/.codex/hooks/tests/`; add a case that
  `rm -rf ~/.worktrees/r/x` is allowed and `rm -rf ~/.worktrees` (root) is
  denied.

### B3. Shared policy (`~/.codex/AGENTS.md`)
- Add the spec D7 sentence to "Workspace and method fidelity". Close bead
  `disk_magician-codex-agents-md-scratch-policy-2gp` with a note.
- Canary (semantic-signoff rule; the `codex exec` half waits for the Codex
  usage-limit reset 2026-10-10 23:31): run `claude -p` and `codex exec` (background,
  `timeout 300`) with "create a worktree for branch test/canary in
  ~/projects_other/disk_magician" and confirm each picks `~/.worktrees/...`
  or `diskm worktree-new` without asking; then remove the canary worktree via
  `git worktree remove` and delete the branch.

### B4. Skills
Edit in `~/.claude/skills/` (canonical; `user_scope` snapshots it):
- `superpowers-using-git-worktrees`: location step → `~/.worktrees/<repo>/<branch>`
  via `diskm worktree-new`; drop in-repo `.worktrees` and the `check-ignore`
  step.
- `claude-code-claudem:16-17`, `headless:56-69`, `factory-evolve:156`: use
  `diskm worktree-new`.
- `testing-gap-close:36-37`, `pr-babysit:229`, `pre-cr-checklist:22-25`:
  replace `docs/evidence/pr-<N>/` with "publish per evidence-standards (gist,
  or `diskm evidence-push` to GCS)".
- `evidence-standards`: scratch namespace `/tmp/<repo>/evidence/<slug>/`;
  durable store options gist or `gs://wa-test-evidence/agent-evidence/<repo>/<slug>/`
  via `diskm evidence-push`.
- Verify: `grep -rn "docs/evidence/pr-" ~/.claude/skills` → only historical
  notes; `grep -rn "worktree add" ~/.claude/skills` → no non-standard targets.

### B5. GCS
- Probe: `printf x > /tmp/disk_magician/evidence/_probe && gcloud storage cp … gs://wa-test-evidence/agent-evidence/_probe` then delete the probe object.
- Lifecycle: read current policy (`gcloud storage buckets describe
  gs://wa-test-evidence --format=json(lifecycle_config)`), merge in
  `{action:{type:Delete}, condition:{age:30, matchesPrefix:["agent-evidence/"]}}`
  preserving existing rules, apply with
  `gcloud storage buckets update --lifecycle-file`.

## Lane C — dark-factory (delegated to `/dot`)

- Ask the dot: in `jleechanorg/dark-factory`, change
  `runner/review_snapshot.py:_default_snapshot_root()` to return
  `~/.worktrees/dark-factory-review-snapshots`, with a unit test asserting the
  default and that `snapshot_root` overrides still work; open a PR titled
  `... [<cli>][<model>]`; do not merge. Monitor per the `/dot` backoff, verify
  the PR diff/CI at the source.

## Lane D — live verification (after A–C)

1. Claude Bash: `git worktree add /tmp/wt-guard-probe -b probe/x` in a scratch
   repo → denied with the helper message.
2. `diskm worktree-new <scratch repo> probe/y` → path under `~/.worktrees/`.
3. Agent tool with `isolation: "worktree"` → `pwd` reports
   `~/.worktrees/<repo>/<name>`; worktree removed on finish.
4. `codex exec` attempting step 1 → denied (after Codex usage-limit reset
   2026-10-10 23:31; until then verify by piping a recorded Codex PreToolUse
   payload into the registered hook command).
5. `diskm layout-check --json` lists legacy roots with counts; save to
   `/tmp/disk_magician/evidence/standard-layout/` and publish via
   `diskm evidence-push`.
6. Clean up probe worktrees/branches; record results in
   `roadmap/activity/2026-10-05.md` and close/supersede beads `2nw`, `9n1`,
   `2gp`, `663`.

## Self-review

- Every spec section maps to a task: D1→A1, D2→A2, D3→A3/A4/B1, D4→B2,
  D5→A5, D6→A6, D7→B3/B4/C, D8→A7/B5. Verification → Lane D.
- No task deletes existing worktrees or evidence; deletion paths stay behind
  the 7-day floor and `WORKTREE_APPROVED=1`.
- Lane B depends on A8's deploy (hooks call the installed `diskm`); B5 depends
  on the probe succeeding.
