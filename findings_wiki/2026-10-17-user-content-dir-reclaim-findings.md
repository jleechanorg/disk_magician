---
title: User-content dirs hide two unmanaged producers — Downloads evidence-spool pattern drift and ~/Documents/Codex verifier clones
hostname: jeffreys-macbook-pro.local
date: 2026-10-17
status: active
paths:
  - ~/Downloads
  - ~/Documents/Codex
safety_rule: none — pattern widening and clone cleanup are policy decisions, not yet implemented
---

## What

Lane-E sweep of user content dirs (Downloads 2.2 GiB, Desktop 419 MiB,
Documents 16 GiB, Pictures 14 GiB — Photos library, Movies 22 MiB, Music 39 MiB,
.Trash 0 B) found two stale classes that no canonical script currently owns:

1. **Downloads evidence spools outside the configured patterns.**
   `scripts/cleanup_downloads_evidence.sh` defaults to `DK2D-* dk2d_*`, so a
   dry run reported 0 spools. The same class of directory — agent evidence
   bundles written directly into `~/Downloads` — had drifted to
   `*_evidence` / `*_evidence_*` names: 9 dirs, 223 MiB, mtimes 2026-02-21 ..
   2026-07-07 (`worldai_claw_evidence_20260707` 97 MiB,
   `world_sim_3x20_v3_evidence` 56 MiB, `world_sim_3x20_evidence` 50 MiB,
   `companion_long_campaign_evidence` 7 MiB, plus 5 sub-3 MiB dirs).
   Running the same script with
   `DISK_MAGICIAN_EVIDENCE_PATTERNS="DK2D-* dk2d_* *_evidence *_evidence_* *evidence_*"`
   removed all 9 on 2026-10-17 (keep-2-newest, 72h retention, lsof and
   `.keep`/`.in-use` markers still applied). The active
   `worldai_campaign_entries` dir (written same day, 978 entries) does not
   carry "evidence" in its name and was correctly untouched.
   This is the third documented instance of evidence-pattern drift
   (see the 2026-07-21 note in the script header).

2. **`~/Documents/Codex` — 14 GiB of per-task full repo clones.**
   Dated `YYYY-MM-DD/task-N/` dirs, 296,923 files, each a full `git clone`
   (`.git/objects/pack` blobs up to 1.28 GiB, plus `node_modules`). Growth:
   2026-10-03 7.0 GiB, 2026-10-15 4.8 GiB, 2026-10-08 1.7 GiB,
   2026-10-12 742 MiB; newest dir written 2026-10-17. Same producer family as
   `2026-09-23-verifier-lanes-should-use-worktrees-not-clones.md` (which
   covered `~/.claude/state`), now landing in Documents.
   **No canonical script matches it:** `cleanup_pr_scratch.sh` patterns are
   `pr[0-9]* pr-* pr_* pr9* claude-* claude_*` and its roots exclude
   `~/Documents`; the dir is only configured as a snapshot *measurement* root
   (`documents_codex` in config.json.template). It is not covered by the
   never-delete list (`~/.codex/sessions*` is a different path) but is also
   not authorized for deletion by any rule — deleting it is a policy call.

## Why it matters

`~/Documents` is the second-largest user root on this box (16 GiB) and 87% of
it is agent clone scratch, not user documents. Nothing sweeps it, so the
producer will keep refilling it silently — the same "no sweeper operates here"
shape that produced the 55.9 GiB Downloads incident in July.

## Guards / governance

- Do not hand-`rm` `~/Documents/Codex/task-*`. Either extend
  `scripts/cleanup_pr_scratch.sh` (pattern + root list, keeping its recency and
  protected-root gates) or leave it as a `needs_decision` entry.
- Anything with a live `2026-10-17` child is active — treat the newest 1-2
  dated dirs as in use.
- Widening `downloads_evidence_patterns` in `config.json` (rather than the env
  override) would make the fix durable; that is a config/safety decision.
