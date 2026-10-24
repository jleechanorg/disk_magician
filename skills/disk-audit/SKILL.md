---
name: disk-audit
description: Use when checking local disk capacity, investigating disk growth, or reviewing safe cleanup candidates.
---

# Disk audit compatibility entrypoint

Read and follow `../disk-root-cause/SKILL.md` in full before taking action.

Follow fleet check -> `diskm reclaim-ledger --read-existing` -> floor/buckets -> bounded `diskm audit`, after the resource gate. Audit prints fleet and ledger before concurrent deeper lanes; missing/unreadable/stale is not no growth. Never delete anything without explicit user approval.
