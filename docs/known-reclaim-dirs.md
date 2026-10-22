# Known reclaim directories (how to read the per-host ledger)

Read the **per-host ledger first** in any disk investigation or cleanup. It names the directories that grew, were cleaned, and will grow again on that machine, so you re-clean them before hunting elsewhere. This file is machine-agnostic; the paths and sizes live in the machine's own state repo.

## Where the ledger is

| Machine | File |
|---|---|
| Any | `<state-repo>/reclaim/known-reclaim-dirs.md` (the state repo is `~/.disk_magician_backup` on the Mac, the XDG default `~/.local/state/disk-magician` on Linux; `diskm state status` prints it; the `MACHINE` marker names the host) |

Regenerate and commit it with `diskm reclaim-ledger` (`--stdout` previews without writing). The 30-minute snapshot job runs it too, so the committed copy is at most a half hour old. `--days N` changes the window (default 7).

## How to read it

Every section names its data source and time. A banner at the top says when the full-disk ledger is stale; in that case A and B are old or unavailable, while C and D (from the deletion log) are current.

| Section | Source | Use |
|---|---|---|
| C. Cleaned roots | deletion log, `~/Library/Logs/disk-magician-deletions.log` (`DISK_MAGICIAN_DELETION_LOG`) | Directories already reclaimed in the window, grouped by parent root, with the script that cleaned them. Re-clean these first. |
| D. Regrows fast | same log | Roots cleaned on many days or in many distinct hours. These are producers: cleaning treats the symptom, so stop or admit-control the producer. |
| B. Growth vs floor | `diskm history growth-top10` (committed ledger history) | Paths that grew since the lowest-used snapshot in the window. Needs a fresh complete scan. |
| A. Uncovered / needs-decision / protected | `check_uncovered_roots.py` over the frontier scan | Rows of 5 GiB or more with no sweeper owner. Class: *uncovered* = no owner (register or decide), *needs-decision* = report-only, the operator decides, *protected* = never-delete list. |

Sizes in C and D are `du` figures taken at deletion time, so they are upper bounds, not `df` deltas. Confirm a reclaim by the `df` change on one item before claiming it.

## Re-clean commands (dry-run first, `--clean` to act)

| Class | Command |
|---|---|
| Scratch under the OS temp dirs | `diskm cleanup-tmp --clean` (add `--large` with `LARGE_TMP_APPROVED=1` for the idle-hours tier; needs the scratch lock, which the main sweeper often holds) |
| Custom Xcode DerivedData and simulators | `bash scripts/cleanup_xcode.sh --clean` (no `diskm` route yet; `diskm clean --routine` runs it) |
| PR and task scratch | `diskm cleanup-pr-scratch --clean`, `diskm cleanup-task-scratch --clean` |
| Developer caches | `diskm cleanup-dev-caches --clean` |
| Eligible worktrees (3-day floor) | `WORKTREE_APPROVED=1 diskm cleanup-worktrees --clean` |
| Colima / Docker | `diskm cleanup-colima --clean` |
| Everything, as one routine | `diskm clean --routine` |

Route every deletion through these scripts so their recency and safety filters apply. Run `scripts/safety_check.sh <path>` before any manual removal.

## Do not chase

- Chrome `code_sign_clone` directories under `/private/var/folders/*/*/X/`: `du` shows tens to 100+ GiB, but they are APFS clones that share blocks with `/Applications`, so deleting them frees about nothing (`findings_wiki/2026-10-17-codesign-clone-du-is-phantom-when-versions-match.md`).
- Local Time Machine / APFS snapshots taken the same day as a deletion pin the freed blocks until they thin or expire. `df` can stay flat after a large delete; check `tmutil listlocalsnapshots /` before concluding a cleanup did nothing.
- `_disk_magician_archive` under the OS temp dir is the tool's own staging target for archived items, not a producer.
- The never-delete list: `~/.codex/sessions*`, `~/.codex/state*.sqlite`, `~/.codex/log`, `~/.claude/projects`.

## Caveats

- The deletion log undercounts removals that bypass logging primitives (agent `rm` commands carry no sizes) and, before the central-logging change, worktree reaps recorded only in `worktree_guard.log`.
- A cleanup can look large in C and still not move `df` if the same producer refilled the space; D is the check for that.
- Cleanup alone rarely reaches a large free-space target when producers refill 10-20 GiB per hour; the producers need admission control.
- The Mac and a Linux host keep separate ledgers; neither includes the other's deletions.
