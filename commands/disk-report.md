---
name: disk-report
description: Generate a full ≥5GiB-granularity disk breakdown report — every node over 5 GiB expanded to its children until each is ≤5 GiB or genuinely opaque, all rows reconciled to total disk capacity (used+free), built via parallel subagent drill-down. Saves to docs/.
metadata:
  type: command
  runtime: claude
---

# /disk-report

Thin slash command that delegates to the `disk-report` skill. Same effects as invoking the skill directly; this command exists so users get a single namespace entry point.

## Behavior

When the user types `/disk-report`, this command:

1. Loads the skill at `skills/disk-report/SKILL.md`.
2. Falls back to the canonical skill invocation if the local copy is missing.
3. Returns whatever the skill returns.

## Examples

```text
/disk-report
/disk-report full breakdown
/disk-report show me every bucket over 5 GiB expanded
```

## Notes

- This command is intentionally read-only — no destructive commands are ever run. It only measures (shallow `du`/`ls` listings, bounded per-lane timeouts) and writes a markdown report to `docs/`.
- The skill selects a snapshot source (frontier or ledger), expands every >5GiB node to leaves, drills opaque leaves in parallel subagent lanes, reconciles two invariants (parent==sum(children); total accounted == df total capacity), and commits the report.
- See `skills/disk-report/SKILL.md` for the full procedure.
