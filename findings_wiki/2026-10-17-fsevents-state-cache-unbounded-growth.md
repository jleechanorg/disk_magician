---
title: fsevents-projects.state.json grows without bound (665 MB, rotation-exempt)
hostname: jeffreys-macbook-pro
date: 2026-10-17
status: active
paths:
  - ~/.local/state/fsevents-projects.state.json
  - ~/.local/state/fsevents-projects.log
safety_rule: none
---

## What

`scripts/watch_projects_fsevents.sh` writes two things into `~/.local/state`:
a rotated log (`fsevents-projects.log`, rotated daily to
`fsevents-projects.log.YYYY-MM-DD` with a KEEP_DAYS/MAX_BYTES bound) and a
polling-fallback snapshot, `fsevents-projects.state.json` — described by the
script's own `--help` as a "State cache file for polling fallback". The
rotation filter explicitly excludes it
(`p.name.endswith(".state.json")` in the prune list), and nothing else bounds
its size, so it is a pure accumulator: measured **665,153,516 B (634 MiB)** on
2026-10-17 while every rotated log beside it was <=12 MB.

## Why it matters

634 MB of a 926 GiB volume is not a crisis by itself, but it is one of the
largest genuinely-regenerable items in the home tree that no canonical cleanup
script owns — `cleanup-dev-caches`, `cleanup-tmp`, `cleanup-claude-state`,
`cleanup-antigravity-brain`, `cleanup-dark-factory`, `cleanup-codex-db` and
`cleanup-uv-cache` all reported 0 eligible for it. Meanwhile the same tree's
truly large items (`~/.codex/sessions` 44 GiB, `~/.claude/projects` 14 GiB,
`~/.gemini/antigravity-cli/{conversations,brain}` 5.0 GiB) are never-delete or
age-protected by design, so this file is where a cache-only sweep can actually
land. It is safe to drop: the polling fallback rebuilds the snapshot on its
next poll.

## Guards / governance

None yet — manual vigilance. The file is not in any never-delete list and
`scripts/safety_check.sh` returns OK for it, but no scheduled job or cleanup
subcommand deletes it. Candidate follow-up: have
`scripts/cleanup_dev_caches.sh` drop this state cache when it is older than the
watcher's own retention window, so the fix lives behind the existing CLI
dispatch rather than a new script.

## History

- 2026-10-17 — discovered during a home state/cache disk-hunt (lane A);
  removed manually after `safety_check.sh` OK, reclaimed 634 MiB.
