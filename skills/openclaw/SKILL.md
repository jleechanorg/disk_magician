---
name: disk-magician-openclaw
description: Openclaw disk diagnostic, growth regression tracker, and automated cleanup tool.
metadata:
  type: skill
  runtime: openclaw
---

# Disk Magician — Openclaw Skill

This skill teaches the Openclaw orchestration agent how to use `disk_magician` to perform host diagnostics and clean up stale runner/worker resources.

## Openclaw Commands

- **Check space status and alerts**:
  ```bash
  ./disk_magician.sh alert
  ```
- **Audit host resources**:
  ```bash
  ./disk_magician.sh audit
  ```
- **Clean stale worker tmp files, caches, and worktrees**:
  ```bash
  ./disk_magician.sh clean
  ```
- **Prune dead tmux worker sessions**:
  ```bash
  ./disk_magician.sh clean-all
  ```

## Openclaw Guardrails
- Check active tmux sessions list before deleting any directories under `~/.ao-sessions`.
- Always request user authorization for directories modified within the last 14 days.
