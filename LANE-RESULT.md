# LANE-RESULT: wt-48h (branch feat/safeset-wt-48h-20261112)

Operator decision 2026-11-12 (Jeffrey): "Make this default 48hr" — default worktree recency floor is now 48 h (2880 min).

## Changed
- `scripts/safety_lib.sh`: new `safety_worktree_floor_minutes` (default/min 2880; config `worktree_min_stale_hours`,
  `worktree_min_stale_days`, legacy `min_stale_days`>7 may only raise), `worktree_floor_resolve_minutes <floor> <req_days>`
  (CLI/env day request may only raise), `worktree_floor_label`. `safety_worktree_floor_days` kept as a ceil wrapper.
- Minutes-based checks (`worktree_is_recently_active_minutes`) in: cleanup_worktrees.sh (incl. Antigravity orphans),
  cleanup_worktree_deps.sh, cleanup_worktree_venvs.sh, slim_worktree_checkouts.sh, worktree_hygiene.sh (default path),
  cleanup_claude_state.sh, worktree_remove_hook.sh (default spec `hours:48`, was `days:7`).
- Unchanged: AO 7 d bar + ownership veto, plf merged-clean exception (only when config raises floor to 7 d),
  DISK_MAGICIAN_WORKTREE_FLOOR_HOURS (>=12), DISK_MAGICIAN_REMOVE_HOOK_RECENCY (days:N>=7 / minutes:N>=60, minute spec still
  needs restore receipts), `--min-age-minutes` lease path, 90 d auto-approve gates, every other veto. Did not touch
  artifact_verdict.sh, rescue_ref.sh, CLI.
- `CLAUDE.md` (AGENTS.md/GEMINI.md are symlinks to it): 48 h paragraph with dated quote; 2026-10-08 text kept, marked superseded.
- `pyproject.toml` 0.2.368 -> 0.2.369 (other lanes may collide on this number; integrator should re-bump once).

## Tests
- New `tests/test_worktree_floor_48h.sh` (32 checks): 47 h kept, 49 h eligible, unmeasurable kept, config 7 d honored,
  config 1 d ignored, CLI/env 0 cannot lower, FLOOR_HOURS=12 still lowers; deps/venvs/slim dry-run 47 h vs 49 h. All pass.
- `test_worktree_remove_hook.sh` case 29e (47 h kept / 49 h remove via `hours:48`) passes.
- Updated tests that asserted old floors (each cites the decision): repo_local (2d->1d young), venvs (2d->1d, "Min age: 48 hours"),
  hygiene_preserve_wip (3d->1d young), single_age_walk (minutes stub folded onto day fixture), remove_hook labels.
- Compared ~37 worktree tests against a pristine HEAD clone: no test that passed at HEAD fails now.

## Caveats (pre-existing, not from this lane)
- On this Linux host many tests fail at HEAD (BSD `date -v` fixtures; live-cwd stubs that /proc detection bypasses:
  single_age_walk T1/T2/T7, remove_hook live-cwd cases). At HEAD several are masked because ageing fails and everything reads
  "young"; with ageing working, the fake-lsof live-cwd cases show worktrees removed. Real live-cwd detection is unchanged by this lane.
- `scripts/disk_history.sh` has a syntax error at HEAD (untouched).
- `sync-package-tree --check`: 0 drift; `check-version`: pass.
