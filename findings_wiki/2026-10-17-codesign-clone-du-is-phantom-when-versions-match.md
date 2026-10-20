---
title: code_sign_clone 66 GiB is phantom when all clones share the installed version
hostname: jeffreys-macbook-pro
date: 2026-10-17
status: active
paths:
  - /private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone
safety_rule: none for measurement; do NOT delete while Chrome runs, and do not expect free space from this bucket while versions match
companion: 2026-08-25-code-sign-clone-attribution.md
---

## Verdict

`du` reports **66.17 GiB** for `com.google.Chrome.code_sign_clone` (50 subdirs),
but on 2026-10-17 the **actual on-disk cost was ≈ 0 GiB**: every clone held
version `155.0.8059.80`, identical to the installed `/Applications/Google
Chrome.app`. `clonefile(2)` CoW means those extents are shared with the
installed bundle, so `du` (block-based, CoW-blind) sums shared blocks once per
clone.

The earlier attribution doc left the cost as "somewhere between 0 and 66 GiB
depending on how many clones share the same prior version." This pins it: when
**all** clones match the installed version, the cost is 0 — reclaiming the
bucket frees nothing. The bucket only becomes real disk after an auto-update,
when the old-version framework extents inside each clone become exclusive.

## Evidence

- 50 clone subdirs; `PlistBuddy CFBundleShortVersionString` on every one:
  `50 × 155.0.8059.80`; installed app: `155.0.8059.80`. Zero version diversity.
- Controlled CoW test (3 × 200 MB, `cp -c`): `du -skc` reported 595,084 KB total,
  while `df` avail dropped only ~195,000 KB — `du` over-reported 3×.
- Creation is continuous while Chrome relaunches: clone count went 48 → 50 in
  ~1 minute (14:22–14:23), each `du`-appearing as 1.41 GiB, while `df` used went
  845 → 844.22 GiB (no growth).

## Trap: the cleanup gate false-positives on a shared inode

`scripts/cleanup_code_sign_clones.sh` gates each candidate with
`lsof +D <clone>`. Chromium drops a **hard link** to the app's main executable
into every clone, so all 50 clones plus the installed app share one inode:

```
dev=16777234 ino=2332731698 nlink=51
/Applications/Google Chrome.app/Contents/MacOS/Google Chrome
.../X/com.google.Chrome.code_sign_clone/code_sign_clone.*/Google Chrome.app.bundle/Contents/MacOS/Google Chrome
```

The running Chrome necessarily holds that inode open, so `lsof +D` reports
`pid=<chrome> command=Google Chrome` for **every** clone regardless of age. A
2026-10-17 dry run therefore printed `ACTIVE — preserving` for all 50 candidates
and reported `Dirs removed: 0`. That verdict is an artifact of inode identity,
not evidence that a given clone is in use. Two of the cited pids (15487, 15581)
were already dead seconds later, confirming the attribution tracks a shared
inode rather than a live handle inside the clone.

Consequence: while Chrome runs, the canonical cleaner can never reclaim this
bucket. That is safe-by-accident here (the content is phantom anyway), but it
means "run the cleaner to fix the disk" is not a valid expectation for this
path, and quitting Chrome to unlock the cleaner buys ~0 GiB when versions match.

## How to tell phantom from real

```sh
X=~/../../private/var/folders/j0/byd1z6px50v88lf679bgt0h00000gn/X/com.google.Chrome.code_sign_clone
installed=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
  "/Applications/Google Chrome.app/Contents/Info.plist")
for c in "$X"/code_sign_clone.*; do
  /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$c"/*/Contents/Info.plist
done | sort | uniq -c   # a single line equal to $installed => phantom
```

Any version differing from `installed` is exclusive extents: real reclaim, and
only then does the cleanup script's deletion actually return free space.
