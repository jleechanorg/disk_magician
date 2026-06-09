---
name: disk-magician-hermes
description: Workstation maintenance and growth analytics tool for Hermes.
metadata:
  type: skill
  runtime: hermes
---

# Disk Magician — Hermes Skill

This skill teaches the Hermes agent how to manage disk usage, diagnose growth regressions, and execute cleanup tasks.

## Commands for Hermes

* **Validate System Health**:
  ```bash
  ./disk_magician.sh alert
  ```
* **Audit candidates for cleanup**:
  ```bash
  ./disk_magician.sh audit
  ```
* **Perform safe caches and temporary files deletion**:
  ```bash
  ./disk_magician.sh clean
  ```
* **Review history and regressions**:
  ```bash
  ./disk_magician.sh history
  ```

## Hermes Guardrails
- Ensure you perform a dry-run check before executing any deletions.
- If deleting directories modified within the last 14 days, verify that user approval is in context or prompt the user for confirmation.
