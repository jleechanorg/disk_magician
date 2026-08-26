---
title: snapshot pipeline is healthy; the "stale" path is the retired backup/<host>/ layout
hostname: jeffreys-macbook-pro
date: 2026-08-25
status: active
paths:
  - ~/.disk_magician_backup/snapshots/disk_snapshot.json
  - ~/.disk_magician_backup/backup/<host>/disk_snapshot.json
safety_rule: none
---

## What

The 35-min disk-snapshot pipeline is healthy. `com.jleechanorg.disk-magician`
(PID 91048 as of 2026-08-25 11:51 PDT) commits to
`~/.disk_magician_backup/snapshots/disk_snapshot.json` on a steady cadence. The
"stale" appearance comes from inspecting the **retired** path
`backup/<host>/disk_snapshot.json`, which was the legacy location before the
state repo moved to a flat `snapshots/` directory.

## Why it matters

Operators who grep the state repo for any `disk_snapshot.json` see the legacy
host-prefixed path with a final commit of 2026-07-21 05:19:26 -0700 (SHA
3fbaa50, "chore: update disk snapshot for jeffreys-macbook-pro"). That
correctly looks abandoned and triggers an "is the sweeper dead?" panic — but
the sweeper is alive; only the path moved. The state repo's commit message
also changed (legacy: `chore: update disk snapshot for <host>`; current:
`snapshot 2026-08-25T18:50:32Z`), so anyone string-matching the old message
will see zero hits on healthy runs.

## Evidence (collected 2026-08-25 ~11:51 PDT)

Pipeline health — last 5 commits on `snapshots/disk_snapshot.json`:

| SHA      | Timestamp (local)      | Cadence from prior |
|----------|------------------------|--------------------|
| e12b2ab  | 2026-08-25 11:50:32    | (HEAD)             |
| 9d34bf1  | 2026-08-25 11:07:13    | 43.3 min           |
| 518f1bd  | 2026-08-25 10:25:07    | 42.1 min           |
| fa12add  | 2026-08-25 09:44:28    | 40.6 min           |
| f4dbda4  | 2026-08-25 09:03:51    | 40.6 min           |

Cadence is ~41 min (target 35 min; skew consistent with lock-contention
skips documented in `snapshot_commit.sh`). 30 commits sampled back to
2026-08-24 16:00 — no gap larger than ~45 min. Pipeline is healthy.

Legacy path — `backup/jeffreys-macbook-pro/disk_snapshot.json` last commit:

```
3fbaa50  2026-07-21 05:19:26 -0700  chore: update disk snapshot for jeffreys-macbook-pro
```

That is **5 weeks stale**. The current writer never touches it.

launchd confirmation:

```
$ launchctl list | grep com.jleechanorg.disk-magician
91048 0   com.jleechanorg.disk-magician
```

`com.jleechanorg.disk-magician` is loaded and running (PID 91048, exit
code 0 last cycle). It calls `snapshot_commit.sh` (the canonical orchestrator
at `src/disk_magician/scripts/snapshot_commit.sh`), which writes
`$STATE_DIR/snapshots/disk_snapshot.json` — see line 57 of that script:
`bash "$SNAP_BIN" --output "$STATE_DIR/snapshots/disk_snapshot.json"`.

Source confirms the path move: `src/disk_magician/disk_magician.sh:65`
defines `new_layout="$state_dir/snapshots/disk_snapshot.json"`, and the
snapshot script's design-doc comment at line 2 cites
`roadmap/2026-07-21-generic-split-state-repo-design.md` as the source of the
flat `snapshots/` layout.

## Guards / governance

- The launchd plist `com.jleechanorg.disk-magician` is the canonical
  invocation. `com.jleechan.user-scope-disk-snapshot` is the user-scope
  variant for `~/Library` and writes a separate repo (NOT this one).
- `snapshot_commit.sh` writes only to `snapshots/disk_snapshot.json`; there
  is no remaining writer to the legacy `backup/<host>/` path.
- STATE.md standing rule (safe-cleanup-30d-floor, §Ground truth): "Backup
  state repo: `~/.disk_magician_backup/` (1243 snapshot commits, healthy)".

## History

- 2026-08-25 — discovered: operator's main session flagged the legacy
  `backup/<host>/disk_snapshot.json` as "stale". Verified the
  `snapshots/disk_snapshot.json` writer is healthy (30 commits back to
  2026-08-24 16:00, ~41 min cadence, PID 91048 active).
