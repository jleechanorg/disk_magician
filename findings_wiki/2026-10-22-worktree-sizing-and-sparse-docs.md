# 2026-10-22 — worktree sizing on jeff-ubuntu: what actually shrinks a checkout

Machine: Jeff-Ubuntu (Linux, `/dev/nvme0n1p6`). Measured during a 91%→77 G free recovery.

## The per-worktree cost is tracked documentation, not git objects

`~/projects/worldarchitect.ai` is 5.9 G total: `.git` 2.7 G (12 packs, 2.05 GiB
packed, 516,834 objects, LFS only 4.8 M) plus a ~3.2 G working tree. All 289
checkouts share that object store, so per-worktree size is *checked-out*
content. Tracked bytes at HEAD: docs 156.8 MB, evidence 61.1 MB, mvp_site
32.4 MB, `.beads` 14.1 MB, testing_ui 13.8 MB.

`docs/` is 2407 files, of which `docs/user-stories-ui` alone is 91.9 MB (134
PNGs = 89.8 MB). Each worktree therefore carries ~162 MiB of docs — 46.8 GiB
across the tree, 39% of the 119.5 GiB worktree total.

## Media options, measured — only one shrinks checkouts

| option | per-worktree saving | why |
|---|---|---|
| move media to `docs/media/` | **0** | rename only; still one copy per checkout |
| git-lfs migrate | **0** | smudge materializes the same bytes in every working tree; `.git/lfs` is 4.8 MB, so it is not the bloat |
| sparse-checkout excluding `docs/` | **162 MiB** (46.8 GiB total) | files never materialize; history untouched |

LFS would only shrink the *shared* pack, and the videos it already covers are
6 files. The media decision is therefore: sparse-exclude, not LFS, not a move.

## Mechanism and its trap

`extensions.worktreeConfig=true` is set in worldarchitect.ai, so
`git -C <linked-wt> sparse-checkout set --no-cone '/*' '!/docs/'` writes to that
worktree's own `$GIT_DIR/worktrees/<id>/info/sparse-checkout` and does **not**
leak to siblings. Without that extension the config lands in the shared
`.git/config` and would hit all 600 registrations.

**Trap pinned 2026-10-22:** the first version of `slim_worktree_checkouts.sh`
guarded AO worktrees with the pattern `*/ao/data/worktrees/*`, which does not
match `~/.ao/data/worktrees/...` (the component is `.ao`, not `ao`). The dry run
offered 591 worktrees / 73.7 GB including 400+ live AO agent checkouts. Correct
pattern: `*/.ao/data/worktrees/*`, plus `ao_worktree_dirs` from the AO config.
After the fix the eligible set fell to 188 worktrees / 20.6 GB and 740 AO-owned
were skipped. Any new root guard must be tested against a literal path.

## Environments are not interchangeable

39 worktrees still hold a real env (17 `venv` ~810 MB, 21 `.venv` ~670 MB, 27
GiB) while 330 symlink to `~/.venvs/worldarchitect.ai/venv` (813 MB, py3.12.13).
Package counts are 293 / 299 / 300 / 304 / 310 / 311 — bulk symlinking would
silently change dependency sets, so it was rejected. The canonical env's
`pyvenv.cfg` `command` points at
`~/mirror/projects/stateprimary-20261003/runtime/venv`, so 330 symlinks depend
on a mirror path that this cleanup campaign decommissions: repoint before
removing mirror content. Bead `disk_magician-venv-share-uv-project-environment-k7nv`.

## `.beads` is tracked despite `.gitignore`

`.beads/issues.jsonl` (12.9 MB) is in HEAD even though `.gitignore:278-287`
lists it; tracked status wins. 289 checkouts × 14.1 MB = 5.3 GiB of mutable
issue export, which also conflicts on any `br` write in a worktree. Bead
`disk_magician-beads-jsonl-tracked-dup-vxz9`.

## Stale registrations were 8, not 312

`git worktree list` showed 600 entries against 289 live dirs, which reads like
mass stale metadata; a direct `prunable` audit found **8** dead paths in
worldarchitect.ai plus 1 in disk_magician (all `gitdir file points to
non-existent location`). The rest are `.ao` and other-root worktrees. No script
may prune them: `tests/test_removal_sites.sh` fails any file containing
`git worktree prune`. Bead `disk_magician-worktree-prune-policy-okms`.

## Sparse-checkout safety gates used

`scripts/slim_worktree_checkouts.sh` (CLI: `diskm slim-worktrees`) applies:
recency floor 3 d via `worktree_is_recently_active`, live-cwd skip, AO-owned
skip, `safety_gate`, and skip-if-local-changes-under-an-excluded-path (so
uncommitted docs edits are never hidden). Dry-run default; `--clean` requires
`WORKTREE_APPROVED=1`. Reversal per worktree: `git sparse-checkout disable`.

Two known readers break if docs/ is excluded: `scripts/run_web_advice_ip_wizard.py`
reads `docs/user-stories-ui/NEW-tv-show-ip-campaign-wizard.md`, and
`scripts/tests/test_shared_config_concurrency_defaults.sh:317` globs
`*/docs/user-stories-ui/reviews/*`. That is why the gate targets dormant
worktrees only.
