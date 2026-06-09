---
name: disk-magician-codex
description: Disk space monitoring and cleanup tool for Codex agent nodes.
metadata:
  type: skill
  runtime: codex
---

# Disk Magician — Codex Agent Skill

This skill teaches Codex how to integrate with `disk_magician` to perform automated node maintenance, monitor filesystem regressions, and safely delete orphaned resources.

## Usage Guide for Codex

1. **Verify Node Disk Health**:
   Run the audit check to verify the current capacity:
   ```bash
   ./disk_magician.sh alert
   ```
2. **Retrieve Growth Regression Log**:
   Query the Git snapshot database to review recent space regressions:
   ```bash
   ./disk_magician.sh history
   ```
3. **Execute Automated Maintenance**:
   Prune stale temp folders, caches, and orphaned worktrees to restore disk space:
   ```bash
   ./disk_magician.sh clean
   ```

## Codex Safety Policies
- Codex agent session files inside `~/.codex/sessions` are protected under the global AGENTS policy and must never be deleted unless explicitly requested.
- Respect the mtime safety rule: any worktree folder modified < 14 days ago requires explicit `WORKTREE APPROVED` user authorization.
