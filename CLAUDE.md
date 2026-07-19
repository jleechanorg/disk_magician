# disk_magician — agent instructions

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

## Deployment — commit is NOT deploy (two consumers, two paths)

1. The 35-min snapshot launchd job (`com.jleechanorg.disk-magician`) runs the
   **uv-tool-packaged copy** at
   `~/.local/share/uv/tools/disk-magician/.../disk_magician/`, built from
   `src/disk_magician/` — NOT the repo root files.
2. The drilldown / frontier-nightly / pressure-sweep launchd jobs run
   **repo-root scripts** directly (`@REPO_ROOT@` substitution).

After changing root scripts: run `scripts/sync_package_tree.sh` (use
`--check` in review), **bump the version in pyproject.toml** (uv caches
wheels by version), merge the change, then run `tools/deploy_uv_tool.sh` from
the exact clean `origin/main`. The wrapper fetches `origin/main`, refuses a
dirty or divergent source tree, reinstalls the uv tool, and verifies the
installed package against source. Verify the deployed tree, not the repo,
before claiming production behavior (stale-deploy incident 2026-07-11: v2
code was committed for hours while production ran v1).

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
