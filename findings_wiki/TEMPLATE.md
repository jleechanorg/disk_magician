---
title: <short finding title>
hostname: <hostname this applies to>
date: <YYYY-MM-DD discovered>
status: active   # active | mitigated | resolved
paths:
  - <absolute or ~-relative path(s) this finding is about>
safety_rule: <matching safety.local.json section/pattern, or none>
---

## What

<One paragraph: what the finding is — the hotspot, trap, or root cause.>

## Why it matters

<What breaks or bloats if this is forgotten: GB at stake, daemon that dies,
commits that would be lost.>

## Guards / governance

<What now protects or reclaims it: safety.local.json entry, launchd job,
cleanup script, or "none yet — manual vigilance". Link commits/beads.>

## History

- <YYYY-MM-DD> — <event: discovered / swept NN GB / governed by X>
