---
description: /disk_magician - Run disk diagnostics, audit space, identify regressions, and perform safe cleanups using disk_magician
type: utility
execution_mode: immediate
---
# /disk_magician - Disk Magician Utility

**Usage**: `/disk_magician <command> [options]`

## Purpose

Analyze disk usage, scan for blind spots, and run safe cleanups using the `disk-magician` tool.

## Skill Reference

Full integration guide and guidelines:
- `~/.claude/skills/disk_magician/SKILL.md`

## Ledger-first diagnosis

Follow fleet check -> `diskm reclaim-ledger --read-existing` -> existing
floor/buckets -> bounded `diskm audit`, respecting current CPU/RAM/I/O resource
gates. The existing state resolver selects this host's report; do not regenerate
history to read it. Missing/unreadable/stale is unknown, not no growth. Audit
prints fleet health and the report before any deeper scanner. Defer heavy scans
on a saturated host; no cleanup is implied by diagnosis.

## Quick Commands:
- **Audit**: `disk-magician audit`
- **Discover**: `disk-magician discover`
- **Clean (Safe)**: `disk-magician clean`
- **Clean All (Aggressive)**: `disk-magician clean-all`
- **History**: `disk-magician history`
- **Snapshot**: `disk-magician snapshot`

## Safety Constraints & Guardrails
- **Worktree 7-day rule (single source of truth):** the repo `CLAUDE.md` section "Worktree 7-day rule" — a worktree touched within 7 days is protected; recency is measured by `scripts/lib/worktree_recency.sh` and never re-derived from `stat <wt>/.git` or `stat <wt>` (both measure creation, not use); unmeasurable fails closed to protected. Agent sessions follow the same 7-day floor and need explicit `WORKTREE_APPROVED=1` from the user.
- **Never-delete list:** Do not delete `~/.codex/sessions`, `~/.codex/sessions_archive/`, `~/.codex/state*.sqlite`, `~/.codex/log`, or `~/.claude/projects` directly.
- **Dry-run First:** Always run with `--dry-run` or preview the action before running destructive cleanups.

## Execution

When invoked with `$ARGUMENTS`, read `~/.claude/skills/disk_magician/SKILL.md` and execute the appropriate `disk-magician` commands.
