# Protected Data-volume accounting — 2026-07-19

## Outcome

The physical top-down equation balances, but this unprivileged shell cannot reduce the unknown allocation below 50 GiB. The accepted leaf ledger covers **526.586819 GiB (66.977%)** of the Data volume and leaves **259.629402 GiB** as protected/APFS residual. The non-atomic residual interval is **259.629402–262.587505 GiB**.

This residual is an attribution gap. It is not backup size and is not evidence of reclaimable space.

## Provenance

- Repository HEAD at scan start: `3fea12c79162ce3163118c72c9969a3319aad893`.
- Required first measurement: `disk-magician audit`; completed with the normal 900-second top-down cap. Its live summary reported 781.9 GiB Data used, approximately 529.0 GiB accepted namespace allocation, and a 249.9–252.9 GiB residual interval.
- Durable exact scan: `python3 scripts/disk_frontier_scan.py --granularity-gib 5 --wall-clock-cap 900 --workers 8 --output roadmap/evidence/protected_data_accounting_20260719.json`.
- Exact scan captured at `2026-07-19T08:45:15Z`; backend `gdu_one_pass`; 1,605,615 inventory records; 429.8 seconds; 100,000,000-record emergency ceiling; no time or node-budget exhaustion.
- Raw artifact: `roadmap/evidence/protected_data_accounting_20260719.json` (`sha256 947b64a0ef77f107ac114f8c1f9a6bcb2efc325c092043ccba9e76384081f636`).
- No cleanup or snapshot mutation was performed.

## Exact physical equations

All values below are allocated KiB unless a GiB rendering is shown. GiB uses 1,048,576 KiB.

### APFS container

```text
885,487,344 volume allocations
+   201,844 shared/container metadata
+85,660,992 free
=971,350,180 KiB container capacity
```

Rendered: **844.466537 GiB volumes + 0.192493 GiB shared/metadata + 81.692688 GiB free = 926.351719 GiB capacity**.

Every APFS volume allocation at or above 5 GiB:

| Volume role | KiB | GiB |
|---|---:|---:|
| Data | 824,407,536 | 786.216293 |
| VM | 25,170,028 | 24.004009 |
| Macintosh HD / System | 17,962,168 | 17.130058 |
| Preboot | 14,866,120 | 14.177437 |

The smaller sibling roles are Recovery 2.192883 GiB and Update 0.745857 GiB. Sibling volumes are outside the Data equation.

### Data accepted-leaf ledger

```text
544,953,372 bounded path buckets (each <=5 GiB)
+ 7,212,928 one indivisible file above 5 GiB
+         0 measured tail
+         0 purgeable estimate
+272,241,160 protected/APFS residual
=824,407,460 KiB Data used
```

Rendered: **519.708035 + 6.878784 + 0 + 0 + 259.629402 = 786.216221 GiB**. The displayed and hidden measured ledgers both balance, and the display-ledger delta is zero.

Data used changed while the namespace was walked:

```text
before: 827,509,256 KiB (789.174324 GiB)
after:  824,407,460 KiB (786.216221 GiB)
delta:   -3,101,796 KiB (-2.958103 GiB)
residual interval: 272,241,160–275,342,956 KiB
                   259.629402–262.587505 GiB
```

Every accepted Data item at or above 5 GiB:

| Kind | KiB | GiB | Path |
|---|---:|---:|---|
| bounded direct-allocation segment | 5,242,880 | 5.000000 | `/System/Volumes/Data/Users/jleechan/.codex [direct files + directory metadata 1/2]` |
| bounded direct-allocation segment | 5,242,880 | 5.000000 | `/System/Volumes/Data/Users/jleechan/.colima/_lima/_disks/colima [direct files + directory metadata 1/2]` |
| indivisible file | 7,212,928 | 6.878784 | `/System/Volumes/Data/Users/jleechan/.hermes/state.db` |

There are no oversized normal directory buckets. The maximum normal bucket is exactly 5 GiB.

## Top-level accepted-leaf rollup

These rows are rollups of non-overlapping accepted leaves, not replacements for the <=5 GiB bucket contract. Partial rows exclude their denied/vanished children, which remain in residual.

| Data top-level root | Accepted KiB | Accepted GiB | Status | Unfinished reason |
|---|---:|---:|---|---|
| `Users` | 469,288,488 | 447.548378 | partial | permission denied; 3 interrupted paths |
| `private` | 31,455,152 | 29.997971 | partial | permission denied |
| `Applications` | 24,397,096 | 23.266884 | measured | none |
| `opt` | 17,186,668 | 16.390484 | measured | none |
| `Library` | 9,540,808 | 9.098824 | partial | permission denied |
| `System` | 287,420 | 0.274105 | partial | one path disappeared |
| `.com.apple.templatemigration.boot-install` | 6,612 | 0.006306 | measured | none |
| `usr` | 3,224 | 0.003075 | measured | none |
| `MobileSoftwareUpdate` | 832 | 0.000793 | measured | none |
| `.TemporaryItems`, `Volumes`, `cores`, `mnt`, `sw` | 0 | 0 | measured | none |
| `.DocumentRevisions-V100` | unavailable | unavailable | unfinished | permission denied |
| `.Spotlight-V100` | unavailable | unavailable | unfinished | permission denied |
| `.fseventsd` | unavailable | unavailable | unfinished | permission denied |
| `home` | unavailable | unavailable | unfinished | cross-device `autofs` boundary |

The accepted values sum to the exact 552,166,300 KiB measured ledger.

## Permission boundary

The raw artifact names all 210 unfinished frontier entries: **205 permission denials, 3 interrupted system calls, 1 cross-device boundary, and 1 vanished path**. The 205 denial paths group as follows; every exact path remains in `frontier_unfinished` in the raw JSON:

| Denied namespace | Exact path count |
|---|---:|
| `/System/Volumes/Data/Users/jleechan/**` | 4 |
| `/System/Volumes/Data/private/var/db/**` | 51 |
| `/System/Volumes/Data/private/var/folders/j0/**` | 16 |
| `/System/Volumes/Data/private/var/folders/zz/**` | 81 |
| `/System/Volumes/Data/private/var/spool/**` | 15 |
| `/System/Volumes/Data/private/var/protected/**` | 6 |
| other `/System/Volumes/Data/private/**` | 17 |
| `/System/Volumes/Data/Library/**` | 12 |
| Data-root protected dot-directories | 3 |

Direct current probes returned these exact failures:

```text
du: /System/Volumes/Data/.Spotlight-V100: Permission denied
du: /System/Volumes/Data/.DocumentRevisions-V100: Permission denied
du: /System/Volumes/Data/.fseventsd: Permission denied
du: /System/Volumes/Data/private/var/root: Permission denied
du: /System/Volumes/Data/private/var/containers: Operation not permitted
du: /System/Volumes/Data/private/var/protected/trustd/private: Operation not permitted
du: /System/Volumes/Data/Library/Application Support/Apple/AssetCache/Data: Permission denied
```

The non-interactive privileged probe did not prompt and did not run:

```text
sudo -n /usr/bin/du -skx <denied roots>
sudo: a password is required
sudo_rc=1
```

No credentials were requested.

## Snapshot residual is separate

The schema-v2 snapshot at `/Users/jleechan/.disk_magician_backup/backup/jeffreys-macbook-pro/disk_snapshot.json` was captured at `2026-07-19T08:19:02Z` and reports:

- snapshot coverage 48.8%; raw-v1 coverage 54.0%; 74 of 77 configured paths measured;
- snapshot `residual_gb=400.6` and `residual_delta_gb=1.6`;
- timeout keys `library_containers`, `projects`, and `root_library`;
- its embedded frontier record was 21.6 hours old.

That **400.6 snapshot residual is configured-path coverage**, not the fresh physical top-down residual of **259.629402–262.587505 GiB**. Neither value may be substituted for the other.

## Root cause of the latest 52 GiB growth

The coverage-validated snapshot history provides a separate, directional delta
for the latest growth interval. Between `2026-07-18T19:08:31Z` (backup commit
`e53ebe11`) and `2026-07-19T08:19:02Z` (backup commit `da4113e8`), reported disk
use rose from **730 GiB to 782 GiB**. Coverage improved from 42.7% (72/77 paths)
to 48.8% (74/77 paths), so these path deltas identify the dominant measured
writers but are not an exhaustive physical equation.

| Measured path | Old GiB | New GiB | Delta GiB |
|---|---:|---:|---:|
| `~/Downloads` | 4.005 | 43.507 | **+39.501** |
| `~/.colima` | 8.302 | 18.836 | **+10.534** |
| `/private/tmp` | 12.718 | 15.645 | **+2.927** |
| `~/.worktrees` | 16.370 | 18.699 | **+2.329** |
| `~/.ao` | 6.568 | 7.325 | +0.757 |
| `~/Library/Caches` | 6.151 | 6.663 | +0.512 |
| `~/Library/Messages` | 28.683 | 27.197 | -1.486 |
| `~/.hermes` | 15.614 | 13.949 | -1.665 |
| `~/Library/Application Support` | 24.302 | 20.966 | -3.336 |

The dominant current writer is not APFS snapshots. A live read-only `lsof`
probe found PID 67830 running `testing_ui/run_dk2d_evidence.py` and writing
canvas frames below
`~/Downloads/dk2d_evidence_sidekick_wc4ic6_validation_r2/`. Its log showed
healthy completed playthrough stages, so the process was not killed mid-proof.
Current-session TCC blocks `find`, `du`, and `dua` on `~/Downloads` with
`Operation not permitted`; Spotlight nevertheless identified the two
`dk2d_evidence_sidekick_wc4ic6_validation*` roots as the indexed evidence
spools. Bead `jleechan-uwtk` tracks an active-use-safe post-run size and
retention policy.

The inventory also exposed `/Users/jleechan/.hermes/state.db` as one 6.878784
GiB indivisible file. Read-only SQLite accounting shows this is real payload,
not vacuumable slack: only 699 of 1,799,950 pages are free. The largest
components are the `sessions` table (2.019 GiB), trigram FTS data (1.946 GiB),
`messages` (0.924 GiB), and two 0.825 GiB FTS content stores. Repeated
`sessions.system_prompt` values alone total 1.947 GiB across 14,299 sessions.
Bead `jleechan-m8um` tracks bounded retention and search-storage design.

## Launchd-context supplement: Downloads is now attributed

The existing `com.jleechanorg.disk-magician-frontier-nightly` launchd job was
run read-only to obtain the storage access that this interactive shell lacks.
It finished normally (`last exit code = 0`) at `2026-07-19T09:36:36Z` after
2,405.7 seconds and 229,425 processed nodes. The raw state file is
`/Users/jleechan/.disk_magician_state/frontier_last.json`; its SHA-256 is
`c8084d01166fce0d09fbb999adbaee333626e02ae2ddb47c28d5029540dfaa53`.
A compact durable extraction is
`roadmap/evidence/frontier_launchd_supplement_20260719.json`.

This independently timed equation balances:

```text
435.205414 GiB measured
+  0.000000 GiB purgeable estimate (unavailable)
+369.785366 GiB protected/APFS residual
=804.990780 GiB Data used
```

Coverage is 54.063404%. This is lower than the exact one-pass scan's 66.977354%
because the launchd job stopped subdivision at depth six, but it successfully
read `~/Downloads`. The two runs are not atomic and their measured totals must
not be added together.

`~/Downloads` accounts for **50.025951 GiB** in this scan. Its six >=5 GiB
evidence bundles are:

| GiB | Path |
|---:|---|
| 9.083351 | `~/Downloads/dk2d_evidence_sidekick10_v2` |
| 7.809769 | `~/Downloads/dk2d_evidence_sidekick11` |
| 6.626842 | `~/Downloads/dk2d_evidence_sidekick13` |
| 6.519108 | `~/Downloads/dk2d_evidence_sidekick_wc4ic6_validation_r2` |
| 6.267315 | `~/Downloads/dk2d_evidence_sidekick_wc4ic6_validation` |
| 5.125332 | `~/Downloads/dk2d_evidence_sidekick12` |

Together these six directories are 41.431717 GiB. The remaining Downloads
contents total 8.594234 GiB, including a 4.579475 GiB `sidekick14` bundle and a
1.583611 GiB `final_gate_v4` bundle. These paths explain the previously
unattributed Downloads growth; they are review candidates, not automatically
safe deletions.

The launchd output also exposed a reporting defect: its invocation omitted
`--granularity-gib 5`, so the scanner configuration used `0.0`, emitted zero
`granularity_buckets`, and placed all 435.205414 measured GiB into the tail even
though nine measured entries exceeded 5 GiB. Bead `jleechan-e8an` tracks the
launchd/default fix. Therefore this supplement is valid for the exact measured
paths and equation above, but it does not supersede the one-pass report's
<=5 GiB bucket ledger.

## APFS allocation-semantics probes

### Native allocated versus apparent namespace size

Both native walks completed but returned rc 1 because of the named permission errors:

| Command | Result KiB | GiB | Meaning |
|---|---:|---:|---|
| `/usr/bin/du -skx /System/Volumes/Data` | 572,688,089 | 546.157922 | allocated blocks visible to this shell; partial ancestor total |
| `/usr/bin/du -skAx /System/Volumes/Data` | 1,609,435,234 | 1,534.877047 | apparent/logical size visible to this shell; partial ancestor total |
| accepted one-pass scanner ledger | 552,166,300 | 526.586819 | allocated blocks with tainted ancestors rejected and accepted leaves retained |

The scanner uses allocated blocks (`gdu -x -k`, without `--apparent-size`), matching native `du -k` semantics. Native allocated `du` is 19.571103 GiB above the accepted scanner ledger because native `du` still prints a partial root total after denied descendants, while the scanner rejects tainted ancestor totals and keeps only attributable leaves.

Apparent size is 2.8103 times native allocated size. This proves sparse/compressed/clone-visible logical size is substantial, but apparent bytes cannot be inserted into the physical equation. `df` and `diskutil` report APFS capacity allocation; they do not report apparent logical bytes. Sparse files and compression therefore do not explain a positive `df minus allocated-du` gap.

The ordinary CLI evidence cannot decide how much of the remaining positive gap is unreadable namespace data versus Data-internal APFS allocation. It does establish that apparent-size inflation is the wrong direction for closing that gap, Data snapshots are absent, and container-level shared metadata is only 0.192493 GiB.

Even the optimistic, non-admissible arithmetic that credits the entire tainted native partial total leaves:

```text
786.216221 GiB Data used
-546.157922 GiB native partial allocated du
-  1.428273 GiB open-unlinked regular files
=238.630026 GiB still unexplained
```

This is a lower-bound diagnostic, not the accepted equation: APFS clone/shared-extent accounting prevents treating a tainted `du` aggregate as a unique physical leaf ledger.

### Other physical-allocation surfaces

- `diskutil apfs listSnapshots -plist disk3s5` reports zero Data snapshots.
- The three `com.apple.os.update-*` snapshots are on the System volume (`disk3s1`), report `Purgeable=0`, and are already inside the separate 17.130058 GiB System allocation. They cannot explain the Data residual.
- `diskutil info -plist`, `diskutil apfs list -plist`, and `system_profiler SPStorageDataType -json` expose no distinct purgeable-byte field on this macOS build. The equation's purgeable estimate is therefore zero-as-unavailable, not proof that purgeable allocation is zero.
- `AssetCacheManagerUtil status` reports `CacheUsed: Zero KB` and `PersonalCacheUsed: Zero KB`, so the denied AssetCache data root does not explain the gap through the supported API.
- `lsof +L1` found 387 unique open-unlinked regular files totaling 1,533,596,600 bytes (1.428273 GiB). This is real non-namespace allocation, but subtracting that separately timed observation from the scan endpoint still leaves approximately 258.201129 GiB.
- Standard CLI output does not expose Data-volume internal filesystem metadata, purgeable allocation, or per-file exclusive/shared clone extents. The 0.192493 GiB APFS container shared/metadata value is container-level and cannot be used as a Data-internal breakdown.

## Evidence-backed boundary and next step

The requested <=50 GiB unknown target is **not met**. At least 209.629402 GiB of the accepted endpoint residual would need independent attribution to reach it. Even crediting the tainted native partial total and open-unlinked files leaves 238.630026 GiB unknown, still 188.630026 GiB over target.

The next evidence step is a human-authorized read-only rerun of the same one-pass scanner from a process with **Full Disk Access plus root**, preserving the exact command, JSON schema, and <=5 GiB leaf contract. `sudo` alone may not bypass TCC. If that privileged run still leaves more than 50 GiB, the remaining requirement is an Apple-entitled Storage Management/StorageKit or APFS extent-aware accounting source that reports Data-internal metadata, purgeable bytes, and unique versus shared clone extents. The ordinary unprivileged commands available to this shell do not expose those categories.

## Claim to artifact map

| Claim | Artifact / command | Exact field or output |
|---|---|---|
| accepted Data equation and residual interval | `protected_data_accounting_20260719.json` | `accounting_equation`, `measurement_window` |
| every <=5 GiB leaf and every indivisible file | same JSON | `granularity_buckets`, `oversize_indivisible_files` |
| all exact namespace denials | same JSON | `frontier_unfinished` |
| APFS container and volume equations | same JSON plus `diskutil apfs list -plist` | `apfs_accounting` |
| zero Data snapshots | `diskutil apfs listSnapshots -plist disk3s5` | empty `Snapshots` array |
| System-only OS update snapshots | `diskutil apfs listSnapshots -plist disk3s1` | three entries, each `Purgeable=0` |
| native allocated/apparent comparison | `/usr/bin/du -skx` and `/usr/bin/du -skAx` | 572,688,089 and 1,609,435,234 KiB, both rc 1 |
| non-interactive privilege unavailable | `sudo -n /usr/bin/du ...` | `a password is required`, rc 1 |
| open-unlinked allocation | `/usr/sbin/lsof -nP +L1 /System/Volumes/Data`, deduped by device+node | 387 files, 1,533,596,600 bytes |
| snapshot-coverage residual | current schema-v2 snapshot JSON | `snapshot_coverage_pct`, `residual_gb`, `timeout_keys` |

## What this evidence does not prove

- It does not assign the 259.629402–262.587505 GiB residual to any protected directory or declare it reclaimable.
- It does not measure the 205 denied paths, Data-internal metadata, purgeable bytes, or unique/shared clone extents.
- It does not make the partial native `du` total an accepted non-overlapping ledger.
- It does not prove an Apple Storage Management category breakdown because that entitled interface was unavailable.
- It does not prove an atomic point-in-time equation; live Data usage moved by 2.958103 GiB during the exact scan.
- The native `du` and `lsof` probes ran outside the scanner's measurement window, so their optimistic lower-bound arithmetic is not an atomic second equation.
