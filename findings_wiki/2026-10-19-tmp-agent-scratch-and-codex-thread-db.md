---
title: /tmp agent scratch reservoirs and the 17 GiB Codex thread DB
hostname: jeffreys-macbook-pro
date: 2026-10-19
status: active
paths:
  - /tmp/advice-*
  - /tmp/frozen-*
  - /tmp/worldai-*
  - /tmp/ipad*
  - /tmp/dd_*
  - ~/.codex/thread_history_1.sqlite
  - ~/projects/worldarchitect.ai/.git
safety_rule: none
---

## What

A 2026-10-19 cleanup pass (started at **17.31 GiB free**, 861.59 GiB used) found
three distinct reservoir shapes the registry did not name:

1. **Per-run agent scratch under /tmp.** The advice-review pipeline, worldai
   fixtures, Xcode iOS builds and frozen-repo copies each leave a whole tree in
   /tmp: `/tmp/advice-*` (45 entries that day), `/tmp/worldai-*` (87),
   `/tmp/ipad*`, `/tmp/frozen-*`, `/tmp/dd_*`. Individually 2–5 GiB; they
   accumulated to ~38.5 GB of the 9h growth that tripped the free<40G gate.
2. **`~/.codex/thread_history_1.sqlite` at 17.1 GiB** — the single largest
   reclaimable item on the box. `cleanup_codex_db.sh` vacuums it, but it refuses
   whenever a live codex client holds the file; that day eight clients did.
3. **Git object packs.** `~/projects/worldarchitect.ai/.git` was 5.7 GiB;
   `git gc` took it to 3.1 GiB with no history loss.

## Why it matters

The /tmp reservoirs are the ones that actually trigger the pressure sweep: they
grow in hours, not weeks, and are invisible to a ledger snapshot that is even
9 hours old. The Codex DB is 17.1 GiB that will only be reclaimed during a
quiescent window, so it must be a scheduled opportunity rather than a manual
afterthought. The .git pack bloat recurs after every heavy fetch/rebase cycle.

## Guards / governance

Registered in `config.json.template` `monitored_globs` (and the live
`~/.disk_magician_backup/config/config.json`): `tmp_advice_scratch`,
`tmp_frozen_scratch`, `tmp_ipad_build`, `tmp_worldai_scratch`, `tmp_dd_dirs`,
`tmp_wf_derived_data`. The `/tmp/*_dd*` shape was deliberately narrowed to
`/tmp/dd_*` and `/tmp/wf*_dd*` because the broad glob matched ordinary Python
files such as `nrs_10364_dd64.py`.

`config/sweeper_roots.txt` now registers the six non-`state*.sqlite` Codex
databases against `cleanup_codex_db.sh` as **VACUUM-only** (no row deletion, and
skipped while a client holds them), and records the ten roots that
`check_uncovered_roots.py` still reports as UNCOVERED as explicit
`decision:check_uncovered_roots.py` entries, so they are visibly owned by a
human decision rather than silently unmonitored.

`~/.codex/state*.sqlite`, `~/.codex/sessions`, `~/.codex/log` and
`~/.claude/projects` remain **intentionally unregistered** — they are
never-delete, and registering them would wrongly imply a sweeper owns them.

## Open follow-up

The 17.1 GiB `thread_history_1.sqlite` vacuum needs a moment with no live codex
clients. It is not a deletion and needs no approval, but it cannot be forced
without killing user sessions, so it should be attempted opportunistically
(e.g. by the scheduled codex-vacuum job) rather than by an agent.
