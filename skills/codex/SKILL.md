---
name: disk-magician-codex
description: Use when a Codex agent needs disk usage diagnosis, growth history, or repository-gated cleanup guidance.
---

# Disk Magician — Codex Agent Skill

This skill teaches Codex how to integrate with `disk_magician` to perform automated node maintenance, monitor filesystem regressions, and safely delete orphaned resources.

## Usage Guide for Codex

1. **Run the default diagnosis first**:
   Launch top-down 5 GiB accounting, coverage-validated deltas, and safe quick wins concurrently:
   ```bash
   disk-magician audit
   ```
   Follow the full forensic procedure in `../disk-root-cause/SKILL.md` when deeper attribution is needed. Residual is not backup size or reclaimable without evidence.
2. **Retrieve Growth Regression Log**:
   Query the Git snapshot database to review recent space regressions:
   ```bash
   ./disk_magician.sh history
   ```
3. **Preview maintenance**:
   Keep cleanup behind the repository safety gates:
   ```bash
   ./disk_magician.sh clean
   ```

## Codex Safety Policies
- Codex agent session files inside `~/.codex/sessions` are protected under the global AGENTS policy and must never be deleted unless explicitly requested.
- Respect the worktree 7-day rule — single source of truth is the repo `CLAUDE.md` section "Worktree 7-day rule". A worktree touched within 7 days is protected and needs explicit `WORKTREE_APPROVED` user authorization. Recency comes from `scripts/lib/worktree_recency.sh`; never re-derive it from `stat <wt>/.git` or `stat <wt>` (both measure worktree creation, not use), and treat unmeasurable as protected.
- **Worktree Removal Forensics:** Never infer `git worktree remove` solely from `git worktree list` absence. Always inspect `ls -la $(git rev-parse --git-dir)/worktrees/<name>/` and `.git/worktrees/<name>/gitdir`. Admin directory presence confirms manual `rm -rf` rather than clean `git worktree remove`.
- **Multi-Agent History Search:** History sweeps must cover Antigravity (`~/.gemini`), Cursor (`~/.cursor`), Hermes (`~/.hermes`), Claude (`~/.claude`), and Codex (`~/.codex`) in parallel (see `~/.claude/skills/history-search/SKILL.md`).

