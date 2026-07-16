---
name: disk-root-cause
description: Use when diagnosing why a disk is full, what consumes its capacity, what grew over time, or what may be safely reclaimed.
---

# Disk root-cause entrypoint

Read and follow the canonical repository skill at
`../../../skills/disk-root-cause/SKILL.md` in full before taking action.

The first command for a whole-disk investigation is `disk-magician audit`.
It runs the top-down 5 GiB accounting, coverage-validated snapshot deltas,
and safe quick-win analysis concurrently. Keep every cleanup read-only until
the canonical skill's approval gate is satisfied.
