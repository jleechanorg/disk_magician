---
title: Daily growth-tracking snapshot silently broken by hardcoded python3.13 path
hostname: jeffreys-macbook-pro.local
date: 2026-07-29
status: mitigated
paths:
  - ~/Library/LaunchAgents/com.jleechan.user-scope-disk-snapshot.plist
  - ~/projects/user_scope/dotfiles/launchd/com.jleechan.user-scope-disk-snapshot.plist
  - ~/projects/user_scope/backup/Mac/disk_snapshot.json
safety_rule: none (launchd ProgramArguments bug)
---

## What

The daily 4am `com.jleechan.user-scope-disk-snapshot` launchd job — which
writes the growth-tracking snapshot consumed by the user_scope backup
report (and by this mission's coverage-validated-delta lane) — had been
failing every single day since 2026-07-25 with `last exit code = 78`
(`EX_CONFIG`). Its `ProgramArguments` hardcoded
`~/.local/share/uv/tools/disk-magician/lib/python3.13/site-packages/disk_magician/disk_magician.sh`,
but the uv-installed tool now lives under `.../lib/python3.14/...` — the
python3.13 path simply stopped existing after a `uv tool install
--reinstall` bumped the interpreter minor version. The general risk was
already tracked in bead `disk_magician-3fi` ("Bump pyproject.toml version
after Python 3.14 deploy fix"), but this is the concrete, currently-active
manifestation: the growth-tracking snapshot file
(`~/projects/user_scope/backup/Mac/disk_snapshot.json`) was stale at
2026-07-25 04:47 for 4 days before this was found.

A second, unrelated bug was found in the same template while fixing the
first: `--output` and `DISK_MAGICIAN_CONFIG` pointed at
`@HOME@/projects_other/user_scope/...`, a directory that does not exist —
the real repo is at `~/projects/user_scope`. The live plist had the
correct path hardcoded (so the job, when it did run pre-2026-07-25, wrote
to the right place), but the *template* had drifted and would have shipped
the broken path on the next reinstall from source.

## Why it matters

This is the daily backstop for growth-delta tracking used by both the
user_scope backup report and any disk-mission audit that wants
day-over-day snapshot deltas rather than a single point-in-time frontier
scan. A silently-EX_CONFIG'd job produces no error surfacing to the user
(launchd doesn't notify on user-agent failure) — it just quietly stops
updating the file, and anyone reading `disk_snapshot.json` "the file
exists and has a schema" without checking its mtime would be working from
4-day-stale data without knowing it.

## Guards / governance

Fixed 2026-07-29: `ProgramArguments` now points at the stable uv-tool
entrypoint `~/.local/bin/disk-magician` instead of the
version-pinned `lib/pythonX.Y/site-packages/...` path. The entrypoint
(`disk_magician.cli:main`) self-locates `disk_magician.sh` relative to its
own package directory at runtime, so it survives future interpreter
version bumps without any plist edit. Also fixed the `projects_other` →
`projects` path drift in both `--output` and `DISK_MAGICIAN_CONFIG`.
Verified: `launchctl bootout` + `bootstrap` reload, exit code now `0`
(clean lock-skip against the concurrent 35-min snapshot job) instead of
`78`. Both the live plist and its source template
(`~/projects/user_scope/dotfiles/launchd/...`) were updated so the next
`install.sh`-driven reinstall won't reintroduce either bug.

General lesson for any future uv-tool-backed launchd job in this fleet:
never hardcode `lib/pythonX.Y/site-packages/...` in a `ProgramArguments`
array — always call the package's installed console-script entrypoint
under `~/.local/bin/`, which uv keeps stable across interpreter bumps.

## History

- 2026-07-24 — Python 3.14 deploy fix landed without a version bump
  (tracked in `disk_magician-3fi`), leaving stale-path risk documented but
  not yet manifested.
- 2026-07-25 04:47 — last successful daily snapshot before the path broke.
- 2026-07-29 — sidekick mission (`disk_magician-7io`) found the live
  `EX_CONFIG` failure via `launchctl print`, traced it to the missing
  `python3.13` path, found the second `projects_other` template bug while
  fixing it, and repaired both in the live plist and source template.
