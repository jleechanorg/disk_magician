# Nextsteps — Disk Magician full attribution — 2026-09-01

## Table of contents

- [Executive summary](#executive-summary)
- [Context](#context)
- [Bead index](#bead-index)
- [Work queue](#work-queue)
- [PR / merge state](#pr--merge-state)
- [Learnings pointer](#learnings-pointer)
- [Roadmap pointer](#roadmap-pointer)

## Executive summary

- Released fail-closed FDA evidence hardening in `15b8a08` (package 0.2.82), then corrected the CI-home-dependent scanner test fixture in `87f4438`.
- The deployed 0.2.82 snapshot at `2026-09-01T01:59:18Z` completed but is not full attribution: snapshot coverage 59.9%, residual 295.5 GiB, and its embedded frontier remains partial (11/17 roots, 203 unfinished entries).
- `/er` therefore remains FAIL for a current complete ledger. The only safe completion path is a dedicated immutable root runner; the current user LaunchAgent and existing root APFS plist must not be elevated or reused.
- A noninteractive privilege probe still reports `sudo: a password is required`; confirm the active terminal's sudo ticket before attempting installation.
- The catalog audit also found host-specific defaults checked into supposedly portable lists; this is tracked separately.

## Context

This work block ran in `/Users/jleechan/projects_other/disk_magician` on `main`. It repaired the FDA proof boundary, deployed the package, took a fresh snapshot, and reviewed the independent-versus-machine-specific directory-list contract. No cleanup/deletion, launchd mutation, root-daemon reuse, or privilege bypass was performed. The source tree has unrelated user changes and must remain selectively staged.

## Bead index

| Bead | Title | Status | Link |
|---|---|---|---|
| [disk_magician-4y6](br://disk_magician-4y6) | Provision root-owned full-attribution snapshot runner | P1 OPEN | [br show](br://disk_magician-4y6) |
| [disk_magician-q6h](br://disk_magician-q6h) | Separate host-specific directory defaults from upstream observer catalogs | P2 CLOSED | [GitHub issue #56](https://github.com/jleechanorg/disk_magician/issues/56) |

## Work queue

1. Install and verify a separate root-owned frontier runner — [disk_magician-4y6](br://disk_magician-4y6). It must copy fixed scanner code/config beneath `/usr/local/libexec/disk-magician`, use a distinct root-owned `/Library/LaunchDaemons` plist, and write atomically to a root-owned readable state path. Acceptance: no ProgramArguments or imports resolve through the checkout, `$HOME`, user configuration, or PATH; ownership/modes prove root-only writes; `launchctl print` confirms the exact job. (Blocked on interactive `sudo` password requirement).
2. Run the installed root runner with `DISK_MAGICIAN_SCAN_USER_HOME=/Users/jleechan`, then publish only if its new report has `mode=complete`, `coverage_envelope.complete=true`, 17/17 measured roots, and zero unfinished paths. Run the deployed snapshot, `history diff --days 7`, `history diff --days 30`, and a new `/er`; do not treat the 2026-08-31 complete ledger as fresh proof. (Blocked on runner installation).
3. [DONE] Diagnosed the failed CI at `87f4438`: fixed `test_disk_audit_topdown.sh` to allow `"no_targets"` in `report["limits"]["full_disk_access"]` when run on CI runners where TCC paths do not exist; fixed `test_safety_lib.sh` 7-day default; repaired test fixtures in `test_history_diff_dispatch.sh` and `test_state_repo_e2e.sh`.
4. [DONE] Corrected the catalog ownership split — [disk_magician-q6h](br://disk_magician-q6h), [GitHub issue #56](https://github.com/jleechanorg/disk_magician/issues/56). Cleaned `DEFAULT_HOT_DIRS` and `config.json.template`, added catalog purity tests in `test_disk_observer.py`, synced package tree, and bumped to `0.2.83`.

## PR / merge state

- No pull request is associated with this main-branch work block. Current remote commits are https://github.com/jleechanorg/disk_magician/commit/15b8a08d367e1cbb1334e2f8310529a4ba4df995 and https://github.com/jleechanorg/disk_magician/commit/87f4438a0b25a23112dca977a7bde105da58a989.

## Learnings pointer

- `/Users/jleechan/roadmap/learnings-2026-09.md` — records the fail-closed FDA boundary, stale-ledger rule, privilege boundary, and directory-catalog leakage finding.

## Roadmap pointer

- Appended `roadmap/activity/2026-09-01.md` and added the day link to `roadmap/README.md`.
