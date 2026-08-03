# `/private/var/dirs_cleaner` mechanism: what it is, why it's accumulating, safe remediation (2026-08-02)

Related docs in this directory (not duplicated here): `2026-08-02-research-eintr-resistant-size-measurement.md`
(EINTR survival tooling) and `2026-08-02-research-persistent-eintr-root-cause.md` (Endpoint Security
AUTH-event root cause for the Mail/Messages/MobileSync EINTR). Those cover a different subsystem
(directory-size measurement under load); this doc is about a live macOS deletion-staging bug found
on the same box during the same session.

**Method note:** this investigation used *this exact machine* (macOS, Apple Silicon) as the primary
source — Apple's own installed man pages, launchd plist definitions, Mach-O binary strings, and
`log show` unified-log output — which is stronger evidence than secondary web sources for a
version-specific internal daemon. Web sources are cited only to corroborate the documented public
role of the daemon; all mechanism claims below are backed by direct on-system tool output, quoted
inline.

## Executive summary

- `/private/var/dirs_cleaner` is **Apple's own, standard staging root** for `deleted_helper`
  (`CacheDelete.framework`), the OS's automatic low-disk-space / purgeable-cache reclamation
  daemon. It is not a bespoke or third-party path — the literal string
  `/private/var/dirs_cleaner/` is compiled into both `/usr/libexec/dirs_cleaner` and
  `CacheDelete.framework/deleted_helper`, right alongside `deleted_helper`'s own service labels.
  **Confidence: high (direct binary/string evidence).**
- The 225.3 GiB is accumulating because of a **live, currently-repeating bug**, caught red-handed
  in this session's unified log: `deleted_helper`'s `nuke_dir` routine fails every single time it
  tries to clear `/private/var/dirs_cleaner/` with
  `removefile error for /private/var/dirs_cleaner/ : File name too long` (ENAMETOOLONG). This
  error recurred **86 times between 13:03 and 17:37 today (2026-08-02)** alone — every purge
  attempt across many separate `deleted_helper` process launches hit the identical error and
  aborted the entire pass, leaving all staged content in place. **Confidence: high (direct,
  timestamped log evidence, not inference).**
- The "rename scratch-tmp content out of the way, background-delete later" pattern is **exactly**
  Apple's documented mechanism here — it is `deleted`/`deleted_helper`'s "orphan" purge path
  (Mach service literally named `com.apple.cache_delete_orphan_dir_handler`), not APFS
  snapshot/unmount cleanup, Time Machine local-snapshot thinning, or a third-party tool.
  **Confidence: high.**
- Manual remediation is judged **safe**, with one required pre-check (confirm no live
  `deleted_helper`/`dirs_cleaner` process is running) and a caveat that plain `rm -rf`/`find
  -delete` is expected to succeed where Apple's own `removefile()`-based `nuke_dir` fails, because
  the failure is a path-length bug in that specific routine, not a legitimacy signal about the
  content. **Confidence: medium-high** — the content is independently corroborated (by its
  recognizable `/tmp`-scratch naming) as already-orphaned, already-decided-purgeable data; the
  residual uncertainty is only "will a *different* deletion tool hit the same long-path file," not
  "is this content live."

## Q1 — What invokes `dirs_cleaner`?

Not what the question assumed. There is **no** `/etc/periodic/daily` script and no boot-time
"clean /tmp" launchd job that calls the `dirs_cleaner` binary directly. Two separate, unrelated
mechanisms exist on this box, and only one touches `/private/var/dirs_cleaner`:

1. **`com.apple.tmp_cleaner`** (`/System/Library/LaunchDaemons/com.apple.tmp_cleaner.plist`,
   `StartCalendarInterval: {Hour: 0}`, i.e. runs once daily at midnight) → runs
   `/usr/libexec/tmp_cleaner`, which is a **plain POSIX shell script** (read in full on this box).
   It does classic BSD-style age-based cleanup of `/tmp` only (`find -atime +3 -mtime +3 -ctime +3
   -delete`), with no rename step and **no reference to `dirs_cleaner` at all**. This is the
   traditional "clean tmp nightly" mechanism the question hypothesized, but it is a red herring for
   this specific staging directory.
2. **`com.apple.deleted_helper`** (`/System/Library/LaunchDaemons/com.apple.deleted_helper.plist`,
   program `/System/Library/PrivateFrameworks/CacheDelete.framework/deleted_helper`) — **this is
   the actual caller.** Its `LaunchEvents` (read via `plutil -p` on this box) show two independent
   triggers:
   - `com.apple.dispatch.vfs` / "Monitor Low Disk Conditions" (`NearLowDisk: true`) — an
     **event-driven** VFS dispatch-source trigger that fires whenever the kernel reports
     near-low-disk pressure, **not** on a fixed schedule.
   - `com.apple.xpc.activity` `com.apple.deleted_helper.daily` (`Interval: 86400`, `Priority:
     Maintenance`, `PowerNap: true`) — a daily XPC Activity maintenance slot (opportunistic,
     scheduled by the system during idle/PowerNap windows, not a fixed clock time).

   `deleted_helper`'s parent daemon `deleted` has its own installed man page on this Mac (`man
   deleted`): *"deleted is a system daemon that keeps track of purgeable space via registered
   services. deleted listens for low-space events from the file system and attempts to avoid
   running out of disk space by requesting that clients purge space. deleted is not intended to be
   invoked directly."* This matches Apple's public documentation of `deleted_helper` as mirrored at
   the community man-page archive: *"the APFS purge daemon... purges APFS Purgeable files on
   demand... listens for purge messages from CacheDelete's daemon (deleted)... not intended to be
   invoked directly."* ([deleted_helper(8) mirror](https://keith.github.io/xcode-man-pages/deleted_helper.8.html))

   `launchctl print system/com.apple.deleted_helper` confirms both event triggers live on this box
   right now, and unified-log evidence (below) proves the VFS low-disk trigger has been firing
   repeatedly today — which explains why the parent directory's mtime was "literally now": it is
   **event-driven by live disk pressure**, not a scheduled midnight job.

Apple's public/open-source distributions (`opensource.apple.com`, `github.com/apple-oss-distributions`)
were not reachable for a source-level cross-check in this pass — the finding above is grounded
entirely in this machine's own installed binaries, plists, and logs, which is a stronger citation
for this exact OS build than a generic upstream source tree would be regardless.

## Q2 — Why is the staging directory accumulating instead of clearing?

**Root cause found directly in the unified log, not inferred.** Running
`log show --predicate 'process == "deleted_helper" AND eventMessage CONTAINS "removefile error"' --last 14d`
returned 86 matching lines, all identical in kind, spanning 2026-08-02 13:03:42 through 17:37:12
(the log buffer on this box only retains today's data — see the sibling EINTR docs for this
session's independent load history):

```
purge_orphans ENTRY urgency: 1 : <private> freespace: 54324011008
iterate_orphans calling block: /private/var/dirs_cleaner/
purge_orphans urgency: 1, clearing: /private/var/dirs_cleaner/
nuke_dir: removefile error for /private/var/dirs_cleaner/ : File name too long
purge_orphans EXIT urgency: 1 : <private> freespace: 54269005824
```

Every single purge attempt (dozens of them, across at least two separate `deleted_helper` process
launches, PIDs 88061 and 1074) enters `purge_orphans`, targets exactly `/private/var/dirs_cleaner/`
via its `iterate_orphans`/`nuke_dir` routine, and **aborts on ENAMETOOLONG** before finishing. This
is consistent with `removefile()` (the API `nuke_dir` uses, per the binary's own strings —
`APFSIOC_PURGE_FILES`, `dc_clean_sync`/`dc_clean_part_sync` in the sibling `dirs_cleaner` binary)
either constructing an absolute path string for a per-item callback (needed for its itemized-purge
accounting, e.g. `CACHE_DELETE_ITEMIZED_PURGEABLE`) or otherwise hitting `PATH_MAX`/`NAME_MAX`
(1024/255 bytes on macOS) somewhere under the 225 GiB tree. Given the recognizable content
(`node_modules`-style dependency trees, nested worktree/PR-scratch paths like
`wt_pr7855_link_check`, `cli_validation_codex_74102_1782531545`), a deeply nested or long-named
descendant is the plausible trigger, but the exact offending path was **not** pinpointed in this
pass — a full recursive `find` over the tree timed out under this box's load in the same way this
repo's `du`/`find` guidance already documents (`CLAUDE.md`: "`du` repeatedly stalls >60s on this
box under load"), so identifying the single bad path is a follow-up, not a blocker for the
mechanism finding.

Because the failure is **the same every time and repeats every purge cycle (multiple times per
hour)**, the accumulation is explained: `deleted_helper` keeps *renaming new orphaned content in*
(each new low-disk event stages another batch, e.g. today's `bT`), but its own delete pass for the
combined staging root has been unable to complete for as long as any one of the 9 batches has
contained the offending path — plausibly since as early as the oldest batch (`41`, mtime Jul 11).
The `deleted_helper.plist` also declares `com.apple.cache_delete_orphan_dir_handler` as a
dedicated Mach service specifically for **reconciling orphaned staging directories** — i.e. Apple's
own architecture anticipates exactly this "staged but not yet deleted" state as a known category,
but the reconciler evidently cannot make progress past the same ENAMETOOLONG error either, since
the content is still there after (per its own daily + event-driven triggers) many opportunities.
The separate `dirs_cleaner_93B5DEFF-...` CrashReporter stub, dated 2026-07-16, is consistent
with — though not proof of — an earlier hard crash of the `dirs_cleaner` binary itself on one of
these batches (the crash log's only populated field was `Date`, so it does not confirm which
subdirectory or whether it's the same bug).

`/private/var/dirs_cleaner` (and the iOS-side twin `/private/var/mobile/dirs_cleaner/`, also
found in the binary's strings) is the **standard, Apple-defined location** for this — confirmed by
the path literal being compiled into the OS binary itself, not something this machine's own tooling
created.

## Q3 — Is "rename into staging, then background-delete" Apple's real /tmp mechanism, or something else?

It **is** Apple's real mechanism — specifically `deleted`/`deleted_helper`'s orphan-purge design,
**not** APFS volume unmount/remount cleanup, Time Machine local-snapshot thinning, or a third-party
tool. Evidence: the `dirs_cleaner` man page's own semantics ("recursively deletes the entire
contents of each directory argument, while the directories themselves are not deleted... A cleaned
directory may be re-created in the process of cleaning") describe exactly a rename-in/delete-later
workflow, and the log lines above show `deleted_helper` driving that exact directory
(`/private/var/dirs_cleaner/`) through its own `purge_orphans`/`iterate_orphans`/`nuke_dir` calls.
It is unrelated to `com.apple.tmp_cleaner` (see Q1), which does in-place age-based `find -delete`
inside `/tmp` itself with no rename step at all.

## Q4 — Safe way to manually complete/retry the deletion

Given NOPASSWD `rm`, `mv`, `find`, `du`, `diskutil`, `apfs`, `disktool`, `ln` but **no** NOPASSWD for
the `dirs_cleaner`/`deleted_helper` binaries or general sudo:

- **The staged content is safe to delete.** By the tool's own contract, anything under
  `/private/var/dirs_cleaner/<batch>/` was *already* renamed there specifically because
  `deleted`/`deleted_helper` decided it was purgeable/orphaned — that decision already happened,
  independent of whether the subsequent unlink pass succeeds. The recognizable content
  (`ssh-hCbZK8eVCH6l`, `ios-simulator-mcp-*`, `pr7923_smoke_artifacts`, `wt_pr7855_link_check`,
  `com.apple.launchd.*`, `tmptn4bpr6q`) is exactly the disposable `/tmp`/`/var/tmp` scratch class
  this repo's own CLAUDE.md and findings already treat as safe-to-clean, not user data.
- **The failure mode (ENAMETOOLONG in `removefile()`/`nuke_dir`) is specific to Apple's API**,
  which appears to build/pass full path strings for itemized-purge accounting. BSD `rm`/`find` on
  macOS `chdir()` into each directory during traversal rather than building absolute path strings
  for every node, so they are expected to succeed where `nuke_dir` fails — this is inference, not a
  cited Apple statement, but it is consistent with the well-documented general distinction between
  path-based vs. fd/chdir-based recursive removal and with the fact that `dirs_cleaner`'s own man
  page separately warns "Recursive traversals do not cross mount points" (i.e. it is aware of
  boundary/traversal edge cases in its own design).
- **Risk assessment:** no evidence found of legitimate hardlink references from elsewhere (this
  content is disposable scratch, not e.g. APFS clone-shared source data), and dirs_cleaner's man
  page gives no indication the OS expects specific subdirectory *names* to persist across boot —
  only that the **parent directories themselves** (the mount points/roots) must not be deleted,
  which the procedure below respects.

### Recommended safe remediation procedure

```sh
# 1. PRE-CHECK — confirm nothing is mid-operation on this path right now.
#    A live deleted_helper/dirs_cleaner process here means a purge or rename is in flight;
#    do not delete concurrently with it.
ps aux | grep -E "deleted_helper|dirs_cleaner" | grep -v grep
launchctl print system/com.apple.deleted_helper 2>&1 | grep -E "^\s*state|^\s*runs"
# Expect: "state = not running" and no matching ps rows. If either shows a live/running
# process, STOP and re-check after it exits (it is jetsam/idle-exited quickly by design).

# 2. Re-confirm current size/contents via this repo's own safety gate before touching anything.
scripts/safety_check.sh /private/var/dirs_cleaner

# 3. Snapshot the batch list + sizes for the record (sudo needed — dir is root-owned, no
#    NOPASSWD "ls", so use the NOPASSWD "find"/"du" instead).
sudo -n find /private/var/dirs_cleaner -mindepth 1 -maxdepth 1 -exec stat -f "%N %z %Sm" {} \;
sudo -n du -sh /private/var/dirs_cleaner/41 /private/var/dirs_cleaner/1L \
                /private/var/dirs_cleaner/xu /private/var/dirs_cleaner/QW \
                /private/var/dirs_cleaner/bT /private/var/dirs_cleaner/B8 \
                /private/var/dirs_cleaner/Zn /private/var/dirs_cleaner/p0 \
                /private/var/dirs_cleaner/NQ /private/var/dirs_cleaner/qn

# 4. Delete CONTENTS only, never the staging root itself or the 9 batch directories'
#    existence assumptions beyond what dirs_cleaner's own contract implies. Use `find -delete`
#    (chdir-based, avoids the ENAMETOOLONG path-string construction that breaks nuke_dir) rather
#    than a single `rm -rf` invocation, and do it ONE BATCH AT A TIME (oldest first) so a repeat
#    of the same long-path failure is isolated to one batch, not the whole 225 GiB tree:
for d in 41 B8 xu p0 NQ QW 1L Zn bT qn; do
  echo "=== $d ==="
  sudo -n find "/private/var/dirs_cleaner/$d" -mindepth 1 -delete 2>&1 | tail -5
done

# 5. If any single batch still fails with "File name too long", isolate the offending path
#    instead of forcing it (never rm -rf blindly over a repeated failure):
sudo -n find /private/var/dirs_cleaner/<batch> -mindepth 1 \
  \( -name '*' \) 2>&1 | awk '{print length($0), $0}' | sort -rn | head -5
# then delete that one long path explicitly by cd-ing into its immediate parent first
# (shortens the path `rm` has to construct) rather than referencing it from the root.

# 6. Re-verify via a different layer than the deletion command itself (per this session's own
#    "verify before reporting" rule) — confirm via `du`, not by trusting `find -delete`'s exit code:
sudo -n du -sh /private/var/dirs_cleaner
df -H /
```

Do **not**: run the actual `/usr/libexec/dirs_cleaner` or `deleted_helper` binaries directly (no
NOPASSWD access, and their man pages explicitly say "not intended to be invoked directly"); delete
the `/private/var/dirs_cleaner` directory itself (only its *contents*, matching the tool's own
contract); or run a single unscoped `rm -rf /private/var/dirs_cleaner/*` without the pre-check in
step 1, since the VFS low-disk trigger can re-fire `deleted_helper` concurrently at any time disk
pressure crosses the threshold.

## Q5 — Live process check before touching anything

At the time of this research: **no live process** — `ps aux | grep -i -E
"deleted_helper|dirs_cleaner"` returned nothing, and `launchctl print
system/com.apple.deleted_helper` reported `state = not running`, `runs = 1`, `last exit reason =
JETSAM_REASON_MEMORY_IDLE_EXIT` (a normal idle teardown, not a crash). The process names to watch
for before any deletion are exactly **`deleted_helper`** (the actual mover/deleter) and
**`dirs_cleaner`** (the binary it may shell out to) — both confirmed present at
`/System/Library/PrivateFrameworks/CacheDelete.framework/deleted_helper` and
`/usr/libexec/dirs_cleaner` on this box. Because `deleted_helper` is **event-triggered** by VFS
low-disk-space dispatch events (not just the daily timer), the pre-check in the remediation
procedure above must be re-run immediately before each deletion pass, not just once at the start of
the session — free space state can flip the trigger on at any moment.

## REMEDIATION EXECUTED (2026-08-02, 18:22-18:31 PDT) — SUCCESS

Followed the procedure above exactly:
1. Pre-check: `deleted_helper` confirmed not running (`state = not running`,
   normal `JETSAM_REASON_MEMORY_IDLE_EXIT`, not a crash).
2. `scripts/safety_check.sh /private/var/dirs_cleaner` → OK.
3. Snapshot taken (10 batches, mtimes/sizes confirmed matching prior audit).
4. Deleted batch-by-batch, oldest/smallest-risk-first, backgrounded so a
   single foreground timeout couldn't kill mid-run:

   | Batch | Size | Result | Timing |
   |---|---|---|---|
   | 41 | 107 GiB | clean | 18:22:31-18:24:43 |
   | B8 | 12 GiB | clean | 18:24:43-18:25:13 |
   | xu | 20 GiB | **clean** (contained the pathological corrupted-`$PATH`-string filename that broke `du`'s path-based traversal — `find -delete`'s fd-relative approach handled it with zero errors, confirming the doc's hypothesis) | 18:25:13-18:25:58 |
   | p0 | 4.4 GiB | clean | 18:25:58-18:26:09 |
   | NQ | 2.6 GiB | clean | 18:26:09-18:26:17 |
   | QW | 19 GiB | clean | 18:26:17-18:27:28 |
   | 1L | 36 GiB | clean | 18:27:28-18:29:18 |
   | Zn | 8.2 GiB | clean | 18:29:18-18:29:45 |
   | bT | 16 GiB | clean | 18:29:45-18:30:37 |
   | qn | 13 MB | clean | 18:30:37-18:30:37 |

   **Zero ENAMETOOLONG errors across all 10 batches, 225.3 GiB total.**

5. Verified via a different layer than the deletion command's own exit
   status (per this repo's "verify before reporting" rule):
   `sudo -n du -sh /private/var/dirs_cleaner` → **0B**.
   `df -k /System/Volumes/Data` → 626.3 GiB used, **271.8 GiB free (70%)**,
   up from 99.4 GiB free before this remediation.

**Confirms the doc's core hypothesis at "medium-high" confidence — now
upgraded to confirmed-by-execution**: the ENAMETOOLONG bug is specific to
Apple's `removefile()`-based `nuke_dir` path-string construction, not a
property of the content itself; `find -delete`'s fd-relative traversal is
unaffected by the same pathological filename and completed cleanly.

Note: `deleted_helper` is event-triggered by VFS low-disk-space signals
and will likely resume staging new orphaned content into this same
directory in the future — this remediation clears the current backlog,
it does not fix Apple's own bug (which would require an OS update). If
this recurs, re-running the same batch-by-batch `find -delete` procedure
should work identically.
