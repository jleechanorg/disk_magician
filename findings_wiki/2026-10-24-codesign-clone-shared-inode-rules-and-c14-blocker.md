---
title: code_sign_clone shared-inode rules (launch-time keep-set) and the three-gate stack that still refuses deletion
hostname: jeffreys-macbook-pro
date: 2026-10-24
status: active
paths:
  - /private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone
safety_rule: never delete a clone while any process holds its inode; treat the whole bucket as non-reclaimable (APFS CoW), never as a reclaim pool
companion: 2026-10-17-codesign-clone-du-is-phantom-when-versions-match.md
---

## Verdict

`lsof +D <clone>` cannot tell you whether a clone is in use: it matches by
inode, and Chromium hard-links the app's main executable into **every** clone
plus `/Applications`. One live handle therefore reports the same pid for all
clones. Measured on 2026-10-24 while Chrome ran:

- `stat -f %l "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"`
  → `nlink=348`, `ino=2390441631`, and one hour later `nlink=433` for the same
  inode: the link count *is* the clone count.
- `X/com.google.Chrome.code_sign_clone` held **347** `code_sign_clone.*`
  children (432 an hour later); `X/at.studio.AsideBrowser.code_sign_clone`
  held 1.
- `lsof -Fpcn +D <one clone>` returned pids 1060, 10370, 53504 for a single
  path inside that clone (`.../Google Chrome.app.bundle/Contents/MacOS/Google
  Chrome`), i.e. the hard-linked inode, not a per-clone file.
- The same pids' **launch** paths were `/Applications/Google Chrome.app/...`
  (1060, 10370) and a system XPC service path (53504) — none of them was
  launched out of any clone. lsof's `n` record for a hardlinked vnode is
  whichever link name is cached, so it cannot attribute a handle to a clone.

Consequence: the sweeper's old predicate marked every clone `ACTIVE` (344
pinned bundles for 4 pids in the reported case) and the dry run could never
report anything as inactive.

## The two rules that replace "any lsof match means active"

1. **Per-clone evidence** — a clone is active only when a reported open file is
   *exclusive* (`nlink <= 1`), is not a regular file, or is already unlinked but
   still open, **or** when the reporting pid's launch path (`ps -p <pid> -o
   comm=`) lies inside that clone (`/var` and `/private/var` spellings are the
   same path).
2. **Launch-time keep-set** — when the only evidence is a hardlink-shared inode,
   preserve every clone created at or after the **oldest** live holder's start
   time (`ps -p <pid> -o lstart=`), because Chromium creates one clone per
   launch and keeps it for signature validity across a staged update. A clone
   that predates every live holder cannot belong to any of them. Unreadable
   start times or mtimes fail closed (preserve).

Keeping only the newest clone was rejected twice in `/advice` review (bead
`disk_magician-bd6`): it leaves a still-live holder's clone unpinned. The
launch-time rule is a superset of "keep the newest" and is what
`tests/test_cleanup_code_sign_clones.sh` now pins down (including a two-holder
case and an unreadable-start-time case).

## Why nothing is actually removed, and why that is fine

Three independent gates each re-check open handles by inode:

| gate | owner | reaction to a shared inode |
|---|---|---|
| candidate classification | `scripts/cleanup_code_sign_clones.sh` | fixed: per-clone evidence only (above) |
| artifact verdict `kept:open-file` | `scripts/lib/artifact_verdict.sh` + `scripts/c14_probe.py` | any lsof output keeps |
| quarantine re-verify `kept:live-user` | `scripts/quarantine_rename.py` | any lsof output keeps |

The last gate is deliberately kind-agnostic and fail-closed; relaxing it would
require a caller-supplied `--kind` to weaken an in-quarantine open-handle check
for every artifact kind, and the rename/rollback cycle it would force costs
~15 s per candidate. Since the reclaim is ~0, the classifier reports such
candidates as `SHARED-INODE … not reclaimable` and does not attempt them; the
destructive gates are untouched.

## Reclaim is ~0: fresh controlled measurement (2026-10-24)

`cp -c` (clonefile CoW), 300 MB source, two clones, on this host:

| step | du total | `df` avail on /System/Volumes/Data |
|---|---|---|
| before | — | 14,734,176 KB |
| after creating src + 2 clones | 921,600 KB (3 × 307,200) | 14,426,164 KB (−300.8 MB) |
| after deleting both clones | 307,200 KB | 14,420,352 KB (−2,088 KB, i.e. noise) |

Three copies cost one copy physically; deleting two of them returned ~0 MB
while `du` reported 600 MB freed. This reproduces the 2026-10-06 production
observation (73 clones, du 104.1 GiB, `df` 8.2 → 8.5 GiB) and the 2026-10-17
version-match finding.

## Traps recorded while measuring

- `ps -Ao comm=` costs **2m15s** with 2071 processes on this host
  (`ps -Ao pid=` 23 s, `ps -p <pid> -o comm=` 11 ms). Any per-candidate gate
  must ask per pid; a global snapshot per candidate turns the sweep into an
  hour-long job and once delayed the whole suite by 3 minutes per run.
- `ps -p <pid> -o lstart=` has trailing spaces; trim before `date -j -f`.
- GNU `stat -f %l` is a *filesystem* format (max filename length, 255), not a
  link count — using it on Linux would read an exclusive file as "shared".
  Branch on `uname -s`.
- C14's `kept:recent-activity` floor reads **content** mtimes, so fixtures must
  be aged with `find … -exec touch -t`, not just the directory.
