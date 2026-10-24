---
name: disk-root-cause
description: Use when diagnosing why a disk is full, what consumes its capacity, what grew over time, or what may be safely reclaimed.
---

# Disk root-cause entrypoint

Read and follow the canonical repository skill at
`../../../skills/disk-root-cause/SKILL.md` in full before taking action.

Follow fleet check -> existing per-host ledger (`diskm reclaim-ledger --read-existing`)
-> floor/buckets -> bounded `diskm audit`, respecting current resource gates.
Audit displays fleet health and the existing ledger before starting its lanes.
Missing/unreadable/stale ledger data is unknown, not "no growth"; do not regenerate
history merely to read it. Keep cleanup read-only until the canonical approval gate.
