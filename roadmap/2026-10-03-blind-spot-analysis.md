# Frontier blind-spot analysis — 2026-10-03 (read-only, no root)

Scan analysed: `~/.disk_magician_state/frontier_last.json`, run_id 71c9ce2f, captured 2026-10-03T10:50:19Z, 554 s, GNU `gdu -x -k` one pass. Probes run 2026-10-03 ~18:59Z at loadavg 174 (`uptime`). Nothing was deleted or modified; only this file was written. No sudo.

## 0. Units correction

Every figure in frontier JSON is KiB (df -k). The "55.9 GB" residual is `residual_kb = 55,894,484` KiB = **53.30 GiB = 57.2 GB (decimal)**. Interval over the non-atomic scan: 55,894,484 – 56,347,540 KiB (`measurement_window.residual_interval_kb`), i.e. +-0.43 GiB. Data used at scan: 892,474,872 KiB; measured 836,580,388 KiB (93.7%).

## 1. The 209 unfinished entries (all `inventory_permission_denied`)

Source: `frontier_unfinished` (len 209, one reason only). Grouped by top path; "entries" is derived from `lstat` of each dir: on this APFS, `st_size = 32*(entries+2)` (validated on 5 readable dirs: /private/var/at 256 = 6 entries, /private/var/db/dslocal 96 = 1, /private/var/vm 96 = 1, /private/var/folders 128 = 2, ~/.disk_magician_state 480 = 13). Entry count is structure only, not recursive size.

| Top path | n | Notes (lstat at 18:59Z) |
|---|---|---|
| /private/var/folders (user sandbox dirs under `.../0/`, `C/`, depth 6-8) | 96 | 74 lstat-able: 228 entries total, 27 empty. 22 lstat EPERM |
| /private/var/db (appinstalld, CoreDuet/Knowledge, DifferentialPrivacy, ExtensibleSSO, ConfigurationProfiles/Store...) | 51 | 47 lstat-able: 99 entries, 11 empty. Others EPERM (SIP/TCC) |
| /private/var/spool (mqueue, postfix/*) | 15 | 60 entries total, 9 empty |
| /Library (Caches/*, Application Support/Apple/{ParentalControls,AssetCache/Data}, Google/GoogleUpdater Crashpad, Tailscale) | 12 | /Library/Caches/* holds 3,151 entries across 2 dirs (the only count-heavy denied dirs); others tiny |
| /private/var/protected (trustd, sfanalytics) | 6 | 63 entries |
| /private/tmp/tmp-mount-* | 7 | all 0 entries (empty mountpoint dirs; `mount \| grep -c tmp-mount` = 0) |
| /private/var/{networkd 2, at 2, install, ma, jabberd, OOPJit, audit, root, lib/postfix, log/com.apple.xpc.launchd, containers, run/mds, dirs_cleaner, backups, agentx}, /private/etc/cups/certs | 17 | all <=3 entries; 7 empty |
| /.Spotlight-V100, /.DocumentRevisions-V100, /.fseventsd (whole top-level roots) | 3 | errno 13 (`fda_preflight`, `system_boundary_attestations`). Contents/size unknowable without root |
| ~/.cache/ezgha-laneb-readonly-20260718-01/virtiofs-mode-0444/pkg/locked | 1 | a 0444 dir the owner cannot read; user-owned, fixable without root (chmod u+rx) |

Totals: 176/209 lstat-able, **64 provably empty**, 33 lstat EPERM/EACCES (unknowable). Plausibly large: the three top-level index roots (Spotlight index and DocumentRevisions can be multi-GiB; sizes UNMEASURED), /Library/Caches (3,151 entries), /private/var/db protected stores (CoreDuet/Knowledge etc.), AssetCache/Data (3 entries, mtime 2026-04-29).

Partial roots (`top_level_ledger`; the file records measured subtotals only, **no per-root inaccessible subtotal is recorded**): Users partial, measured 759,745,968 KiB; Library partial, 7,217,304 KiB; private partial, 19,628,164 KiB. /private/var/folders has no total of its own; 411 child entries sum 8,809,648 KiB (T 3.64M, X 3.61M — the X code_sign_clone dir is readable).

## 2. Reconciliation of the residual (53.30 GiB)

| Rank | Bucket | GiB | Evidence |
|---|---|---|---|
| 1 | (a) Unreadable-without-root dirs + (d) APFS metadata not visible to st_blocks (catalog/extent B-trees for 17.9M inodes, xattrs) | **not separable; together >= ~51.8** (residual minus rows below) | `du` on denied dirs fails; df shows `iused 17892630`. Neither is exposed by any non-root tool. **UNMEASURED** |
| 2 | (b) Open-but-deleted files held by user processes | <= 1.0 (1,068,254,858 B over 743 unique pid/path pairs; includes mmaps/duplicates, so upper bound) | `timeout 25 lsof -nP +L1 -F pcsn`; largest agy.real .old 175 MB, DropboxFileProvider temp 158/127/95 MB. Root-owned processes not visible |
| 3 | (c) Non-atomic scan drift | +-0.43 | `measurement_window`: used before 892,927,928, after 892,474,872 KiB |
| 4 | (b) APFS local snapshots | **0** | `tmutil listlocalsnapshots /` empty; `diskutil apfs listSnapshots disk3s5` -> "No snapshots for disk3s5"; observer `time_machine.local_snapshot_count 0`; JSON `local_snapshots []`. Only snapshot is the sealed System-volume one (`disk3s1s1`), which is not Data |
| 5 | (b) Purgeable | UNMEASURED | `purgeable_kb 0` with method "unavailable: diskutil does not expose a distinct purgeable field". Purgeable files are normal files and appear in gdu totals if readable |
| 6 | (b) VM / swap | 0 of the Data residual | VM is its own volume (disk3s6): 10,490,256 KiB at scan (`sibling_volumes`), 20,983,480 KiB now (`df -k /System/Volumes/VM`); `vm.swapusage` 21189 MB used of 22528 MB. `/private/var/vm/sleepimage` 1,073,741,824 B is on Data and IS measured (1,048,576 KiB) |
| 7 | (c) Clones / hardlinks / sparse | 0 flagged | `clones_suspected false`, `clone_shared_adjustment_kb 0`. GNU du dedups hardlinks in one process but cannot see APFS clones; clones would inflate measured and so shrink residual, i.e. true unattributed space would be >= residual. Sparse: du counts st_blocks (allocated), consistent with df |
| 8 | /private/var/dirs_cleaner (deleted_helper staging) | ~0 | `du` denied (drwx------ root), but `stat -f %z` = 64 = 32*(0+2) = **0 entries**; mtime 2026-10-02 13:51 (it was emptied yesterday). `log show --predicate 'process == "deleted_helper"' --last 1d` shows the helper actively running. The Aug-02 225 GiB incident (memory `project_2026-08-02_dirs_cleaner_...`) is not present now |

Container cross-check: `diskutil apfs list` disk3 — Data 933.8 GB, VM 22.6 GB, System 11.3 GB, Preboot 8.0 GB, Recovery 2.3 GB, 978.1 GB in use, 16.6 GB unallocated; the frontier `apfs_accounting` shows `volume_allocations_kb 923,987,448`, `shared_allocation_kb 201,836`, `equation_balanced true`. Container free at the scan 47,160,884 KiB, now 14,798,480 KiB (`df -k`).

Honest bottom line: only ~1.5 GiB of the 53.3 GiB is attributable to named non-root mechanisms (open-deleted files, scan drift). The remaining ~51.8 GiB is "unreadable system data + APFS metadata", not separable without root. It is not snapshots, not purgeable-in-snapshots, not swap, not dirs_cleaner.

`scripts/check_system_residual.sh` was read and NOT run: it uses `sudo -n du -sm ... || echo 0`, so without sudo it prints "0 MB" (a false negative, not a measurement). Its `log show` leg is heavy at load 174. The stat-based dirs_cleaner check above replaces it.

## 3. Does the blind spot explain growth? Not on current evidence

- Since the scan (10:50Z -> 18:59Z): Data used 892,474,872 -> 912,244,656 KiB (+19,769,784 KiB = +18.9 GiB, `df -k /System/Volumes/Data`); VM volume +10,493,224 KiB (+10.0 GiB). Together +30.3M KiB of the 32.4M KiB drop in container free (~2.1M KiB unreconciled; samples not simultaneous).
- `disk_observer.jsonl` (2026-09-23 -> 10-03, 3-hourly sample) shows Data used swinging 805.7M -> 912.4M KiB (~100 GiB range, e.g. 10-02 21:15Z 890.7M -> 10-03 00:16Z 912.4M -> 10-03 09:18Z 892.8M) and swap sawtoothing 0 -> 39.7 GB. That is churn in readable user paths (known producers: AO scratch, Colima, agent venvs — memory 2026-07-11/07-29), far larger than a 53 GiB static residual.
- A single frontier scan cannot show residual growth. The only older scans (roadmap/evidence/frontier_post_dk2d_reclaim_20260720.json: residual 223.9M KiB at 613M measured, mode partial) used different coverage, so residual is not comparable. Verdict: residual is a floor-like constant until a second full scan exists; growth evidence points to readable paths.

## 4. Prior knowledge (do not redo)

- Bead `disk_magician-4y6` (P1 OPEN, created 2026-08-31): provision a root-owned immutable runner. `br show disk_magician-4y6`; `br search "frontier-root"` -> 0 results. Notes: unprivileged preflight EACCES on the same 3 roots; sudo needs a password; do not reuse the existing root APFS daemon.
- `roadmap/nextsteps-2026-09-01-full-attribution.md`, `roadmap/nextsteps-2026-09-11-disk-recurrence.md` item 7 ("Operator-only: sudo once for 4y6"), `roadmap/2026-09-11-disk-recurrence-rootcause-and-automation.md:150` ("Run `sudo -v` once and complete install_root_frontier_runner.sh interactively").
- Memory: `project_2026-08-02_dirs_cleaner_225gib_root_cause_and_fix`, `feedback_2026-08-27_fda_access_verified_and_tcc_floor_resolved` (user TCC data is readable; the unreadable set is the 3 system roots), `feedback_2026-08-21_consult_memory_before_live_probes`.

## 5. Root job: what is missing

Facts: `/usr/local/libexec/disk-magician` does not exist (`ls` -> No such file); `/Library/LaunchDaemons` has no disk-magician plist; log `/Library/Logs/disk-magician-frontier-root.log` repeats "can't open file '/usr/local/libexec/disk-magician/disk_frontier_scan.py'".

The code is **all in the repo**, only the operator step was never run:
- scanner: `scripts/disk_frontier_scan.py` (84 KB; `--help` runs under `/usr/bin/python3` 3.9.6 here)
- installer: `scripts/install_root_frontier_runner.sh` — mkdirs `/usr/local/libexec/disk-magician` and `/var/db/disk-magician` (root:wheel, with symlink/ancestor guards), copies the scanner 0755, smoke-tests `--help` under `/usr/bin/python3`, renders `launchd/com.jleechanorg.disk-magician-frontier-root.plist.template` (`@USER_HOME@`) into `/Library/LaunchDaemons/`, `launchctl bootout` + `bootstrap system`. `--dry-run` (run as me) prints the four planned actions and exits 0.
- consumer: `scripts/disk_snapshot.sh:874` already reads `/var/db/disk-magician/frontier_last.json`.
- Not wired: no other script calls the installer (`install_launchd_sweepers.sh` does not), so it is operator-only by design (bead 4y6).

One-line install is enough to get the job running (03:41 nightly via `StartCalendarInterval`). One real risk needing a small code change, not verified by run: the plist sets `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so `shutil.which("gdu")` (`disk_frontier_scan.py:80`) will not find `/opt/homebrew/bin/gdu` (GNU coreutils; the nightly user job gets it). The per-path `run_du` falls back to BSD `du`; whether the one-pass inventory at line 617 is guarded against `GDU_CMD=None` I did not verify. Fix: add `DISK_MAGICIAN_GDU_CMD` (honoured at line 79) to the plist template's `EnvironmentVariables` (and its `src/` mirror via `scripts/sync_package_tree.sh`). Caveat: `/opt/homebrew/bin` is jleechan-writable, so root executing it is a privilege-escalation path that conflicts with the 4y6 "immutable root-owned" intent; a root-owned copy of gdu under `/usr/local/libexec/disk-magician/` is the clean option. The installer copy is a snapshot: re-run it after any scanner change.

### Commands for the user (NOT run)

```
cd /Users/jleechan/projects_other/disk_magician
! sudo ./scripts/install_root_frontier_runner.sh --user jleechan
! sudo launchctl print system/com.jleechanorg.disk-magician-frontier-root | head -20
! sudo launchctl kickstart -k system/com.jleechanorg.disk-magician-frontier-root
# after ~10-20 min:
! sudo tail -20 /Library/Logs/disk-magician-frontier-root.log
! sudo python3 -c "import json;d=json.load(open('/var/db/disk-magician/frontier_last.json'));print(d['mode'],d['residual_kb'],d['coverage_envelope'],len(d['frontier_unfinished']),d['limits']['sudo_used'])"
# direct size answers for the blind spot while root:
! sudo du -sk /.Spotlight-V100 /.DocumentRevisions-V100 /.fseventsd /private/var/db /private/var/protected /Library/Caches /Library/Application\ Support/Apple/AssetCache/Data
```

The `kickstart` starts a full nightly-equivalent scan (heavy at current load); skip it to wait for 03:41.

## 6. Unmeasured / limits

Sizes of all 33 EPERM paths and the three index roots; APFS metadata overhead; purgeable bytes; open-deleted files held by root processes; per-partial-root inaccessible subtotals (not recorded in JSON). A second root-run scan is the only way to close rows 1 and 5.
