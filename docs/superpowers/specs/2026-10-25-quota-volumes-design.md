# Opt-in quota'd Scratch volume (`diskm volume`)

Date: 2026-10-25. This is revision 12, updated after the pilot acceptance correction and Codex review of revision 11. Scope: disk_magician on the Mac (APFS container `disk3`). Planning only. This document does not authorize creating volumes, editing policy, deploying or merging.

## Outcome

Scratch requested through `diskm scratch-new` may land on one APFS volume with a quota. Exact usage comes from `diskutil`; nothing walks the tree for usage reporting. When the volume is unavailable, the request errors and nothing is written there. At the existing hourly sweep, quota pressure triggers automatic trim through the existing per-entry C14 removal primitive: whole eligible disposable artifacts are considered oldest-content-mtime first until usage falls to the low-water target. This is an mtime-based last-modified proxy, not true access-time LRU; no access events are recorded. The fill→trim→space-recovered→write-resumes pilot is a required acceptance result, not established by the earlier primitive-only pilots. v1 is opt-in and covers Scratch only. Volume deletion and quota recreation are deferred; rollback retires the volume and drains eligible entries while keeping the volume available for inspection.

## Containment: what a quota does and does not do

- **Bounds only routed writes.** A quota limits writes that reach the volume. It does not reserve container space, and it does not contain producers that still write to Data.
- **A full container fails first.** If the container fills, the volume and Data both hit `ENOSPC` before any cap matters.
- **Data keeps today's protections.** These are the container free-space alarm (`disk_usage_alert.sh`, 20 GiB), `diskm admit`, budgets/`govern`, and the existing cleaners.
- **What the volume adds:** a ceiling on routed scratch, exact attribution, and an audit of scratch that is still on Data.
- **A quota pilot is incomplete until automatic recovery is demonstrated.** On a disposable test-only volume, prove fill→existing scheduled sweep→oldest-eligible whole-artifact trim→measured low-water recovery→successful new CLI-routed write; keep a leased/protected artifact and prove it survives. This is separate from the later 24-hour audit success measure.
- **v1 success is measured by the audit, not volume bytes.** Capture depends on producers adopting `scratch-new` (P-5 policy, P-6 `dd` repos). v1 succeeds when the audit's list of unrouted `/private/tmp` roots shrinks.

## Evidence

| Fact | Source |
|---|---|
| Container size is 926.4 GiB. System+Preboot+Recovery use 24.3 GiB, VM 27.9 GB, Data 889.9 GB (828.8 GiB), and 50.4 GB is unallocated | `diskutil apfs list disk3`, 2026-10-25 |
| Free space swings from 67 to 52 GiB within minutes. Scratch in `/private/tmp` is 16–22 GiB, of which `dd` builds are 13.8 GiB (mostly <48 h old) | operator measurement |
| `addVolume -quota` needs no sudo and takes about 1 s. The volume automounts at `/Volumes/<name>`, owned by the user. Writes hit `ENOSPC` at the quota, `diskutil info` reports exact usage, and `deleteVolume` takes 12 s | pilot `RESULT.md` |
| `/Volumes` is `root:wheel 0755`. `addVolume -mountpoint` is root-only. There is no in-place quota verb | `stat`; `diskutil apfs addVolume` usage |
| The removal primitive is `scratch_budget_quarantine_remove` → `quarantine_remove`. It runs `artifact_removal_verdict` (lease, live-cwd, fd inventory), then moves the entry into the per-parent `<parent>/.dm-quarantine` (same filesystem by construction). This is the C14 primitive | `scripts/lib/scratch_budget.sh:56`, `scripts/lib/quarantine.sh`, `scripts/quarantine_rename.py:141,288` |
| Existing cleaners enumerate top-level `/private/tmp` basenames plus named container roots. They would not reach `<mount>/<repo>/<kind>/<purpose>` | `scripts/cleanup_tmp.sh:132-155` |

Out of scope:
- **Codex transcripts.** Archive plus gzip remains the lever (it freed 44 GiB on 2026-10-24). A Transcripts volume is a possible later phase.
- **Dropbox.** It is unlinked (FileProvider -1004).
- **Simulator runtimes.** Only iOS 26.5 remains.

## Alternatives

| | Approach | Decision |
|---|---|---|
| A | Opt-in Scratch volume; paths only from `diskm scratch-new` | **Choose.** One cap, fail-closed routing, no sudo |
| B | Per-repo volumes at `/private/tmp/<repo>` | Reject. Caps fragment, and a missing mount leaves a writable `/tmp` path, so writes escape to Data |
| C | Data only, with admission and budgets | Keep this as Data's protection. It cannot bound growth after a directory is created |
| — | `/tmp/<root>` symlinks, or overmounting `/tmp` / `TMPDIR` | Reject. Symlinks escape when missing or replaced. Overmounts hide sockets or starve system processes |

## Assumptions and Recommended Defaults

| Question | Pick | Rationale |
|---|---|---|
| Which classes? | Scratch only; Worktrees deferred | Reviewer consensus |
| Cap? | 30 GiB requested, no reserve. `create` refuses unless the live fit passes, and prints the largest cap that fits | A reserve would take Data space. Caps must be checked against live usage |
| What does the fit use? | Live values at `create`/`plan-fit`: `quota + Data_used + system_used + max(VM_used, swap_headroom 40) + alarm_floor 20 ≤ container` | A constant floor understated live Data, which is 829–890 GiB |
| Fit today? | 926.4 − 828.8 − 24.3 − 40 − 20 = **13.3 GiB**, so a 30 GiB request fails. Either Data drops by about 17 GiB or the user picks a cap of 13 GiB or less (P-1) | Honest live arithmetic |
| How is it enabled? | `create scratch --execute` is the enabling step: the active registry entry is the switch. `retire scratch` disables it. There is no `enabled` config flag | Removes the ordering trap where create was refused while disabled |
| Mountpoint? | DiskArbitration's `/Volumes/diskm-scratch`, resolved by UUID | When unmounted, the path is absent and cannot be created under root-owned `/Volumes`. The OS enforces fail-closed; no custom mountpoint or permissions trick is needed |
| How are writes routed? | `scratch-new <repo> <purpose> --kind evidence\|build` → `<mp>/<repo>/<kind>/<purpose>-<UTC>`. It returns rc 75 when the volume is registered but unavailable, and rc 3 (legacy `/tmp`) when no volume is registered | The CLI is the only path source. When it creates a `<repo>/<kind>` parent it also creates `<mp>/<repo>/<kind>/.dm-quarantine` (mode 0700, owned by the user: what C14 checks at `quarantine_rename.py:288-296`) before the entry directory, so C14's own `mkdir` is never the first allocation at the cap |
| How does automatic trim work under quota pressure? | The existing hourly `tmp_scratch_sweep.sh` invokes the volume reclaim path. It is a no-op below 90% quota use; at or above 90%, it considers only eligible whole `<mp>/<repo>/<kind>/<entry>` disposable artifacts, oldest measured content mtime first, and stops once usage is at or below 80%. It skips dot-names and sends each candidate through `scratch_budget_quarantine_remove` / C14. This is last-modified ordering, not access-time LRU; access events are not recorded. If protected or unmeasurable entries prevent reaching 80%, it stops fail-closed and reports the shortfall; it never widens the candidate class | Reuses the existing hourly entry point and C14 primitive; explicit high/low watermarks bound reclaim work and avoid a parallel runner |
| What is the pilot acceptance? | Fill a disposable test-only quota volume to ≥90% with eligible aged artifacts plus at least one leased/protected artifact; let the configured existing scheduled sweep trigger automatically (an accelerated test schedule is allowed, but no manual reclaim or direct sweep invocation); prove oldest eligible whole artifacts are removed first, protected content remains, measured usage reaches ≤80%, then a new disposable CLI-routed write succeeds. Record recovery bound as schedule interval plus one sweep runtime; the writer may see `ENOSPC` before the next run. Repeat with every candidate protected and prove no deletion and no false recovery | Earlier pilots exercised three volume primitives only; they did not prove automatic multi-entry trim, recovered space, or resumed writes |
| Will C14 accept these entries? | Not today: `c14_ephemeral_retention` in `scripts/lib/artifact_verdict.sh` only matches its own rows under `scratch_roots_get_unique`, so these entries return `kept:unproven-content`. Add one row: when the candidate is under a root from a new `scratch_roots_get_volumes` (in `scripts/lib/scratch_roots.sh`) and `rel` matches `^[^./][^/]*/(evidence\|build)/[^./][^/]*$`, return a hard-coded `2880` minutes (48 h), the same way the existing rows hard-code their retentions (`artifact_verdict.sh:176`) | Extends the existing classifier, not a parallel one. Recency, lease, live-cwd, fd, secret and repo checks stay in the same verdict |
| Is the mount at the root the registered volume? | Checked at removal time. In the `ephemeral` branch of `artifact_removal_verdict`, a candidate under a `scratch_roots_get_volumes` root first runs `volume.py verify-mount <root>`, which is the same UUID identity check `path` uses. A mismatch or error gives `kept:volume-identity` | A different volume at the configured path must never be trusted |
| Where does the scratch root come from? | `scratch_roots_get_volumes` reads `volumes.classes.*.mountpoint` from the same config file that `scratch_roots_protected` reads, and prints only existing canonical dirs. It is deliberately not part of `scratch_roots_get` | No hardcoded path. Being outside `scratch_roots_get` stops `protected_tmp_roots` basenames (`worldarchitect.ai`, …) from protecting `<mp>/<repo>` |
| Long-lived owners? | Extend the existing path lease format compatibly: retain legacy single `owner` reads and write an `owners` array for concurrent producers. Add `lease_add_owner --owner-pid PID` (PID plus process-start identity) and owner-scoped release; serialize updates with the existing lease mutation lock so a child never replaces its parent. Reclaim keeps the entry if any owner is alive or identity is unknown; only all-dead/released owners permit removal. `scratch-new` acquires its producer lease before handing out the path; on acquisition failure it returns nonzero without printing the path. Detached children and CI writers acquire before receiving/using the path and release their own entry. | Simultaneous writers remain protected; test parent+child coexistence, child exit, all-dead, identity mismatch/read error, and failed path handoff |
| Reclaim health? | Each run writes `$STATE/volumes/reclaim_runs.json` (last two runs: `at`, `aged_scanned`, `removed`, top kept reason). `diskm status` prints one line, `volume_reclaim_stuck: aged=N removed=0 runs=2 reason=<r>`, when both runs scanned more than 0 aged entries and removed 0 | Detects a classifier gap before the volume reaches `ENOSPC`. No new daemon |
| Retention? | 48 h, hard-coded as 2880 in the classifier row; no config read | Matches the existing `pr*` row and how the classifier works |
| Full-quota recovery? | `create` verifies one 64 MiB ballast file, `<mp>/.diskm-ballast`, before activating the volume. Before any C14 filesystem mutation, reclaim serializes the complete existing inventory intent (preserving unknown fields) and measures its encoded byte length. The supported maximum is 32 MiB; larger or unmeasurable intent fails closed as `kept:intent-too-large`, with no sidecar, rename, or other destructive mutation. If the bounded sidecar write returns `kept:intent-write-failed` from `ENOSPC`, reclaim releases/logs the ballast and retries that same C14 removal once. A second failure remains kept; there is no loop. At run end, `ballast ensure` recreates it only when measured free space is at least 64 MiB + 1 GiB (1,088 MiB); below that it remains absent. Tests reject sparse logical-size-only ballast and prove activation fails when physical allocation or verification fails. Tests prove oversized intent causes no mutation and the real C14 path releases/retries successfully within the 32 MiB bound. The 64 MiB reserve supports the tested bounded intent but cannot guarantee capacity against concurrent writers elsewhere in the APFS container; the bounded retry can still fail safely. `.dm-quarantine` creation failures remain kept and do not release the ballast | Without bounded intent and the retry, a full volume may not reclaim itself; the reserve improves recovery but is not a container-wide capacity guarantee |
| Quarantined/deferred entries? | Entries left in `.dm-quarantine` count toward the quota, and nothing calls `quarantine_reconcile`. This is an existing gap across all roots and is out of scope. The `volume_reclaim_stuck` line surfaces it | It belongs to the C14 owner, not this design |
| Cross-volume moves? | Forbidden. Nothing renames or copies between Data and the volume. Quarantine is per-parent, so it stays on the same filesystem. Rollback drains in place | Cross-volume `rename` fails with EXDEV, and a copy would double usage |
| OS-created dot-dirs? | `reclaim` skips every dot-name; `.diskm-ballast` is recognized only by its exact root name. Any volume-deletion emptiness rules, including treatment of `.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems` and `.DocumentRevisions-V100`, are deferred with deletion/recreation from v1 | macOS creates these dirs on user volumes. Trash, temp items and document revisions can hold user data |
| Encryption? | Unencrypted, only with explicit user acknowledgment (P-2). The Keychain-passphrase variant needs credential creation and an unlock LaunchAgent, so it is a separate approval-gated follow-up | Keeps automount; scratch is ephemeral |
| Change the cap? | Deferred from v1. There is no `delete` or `recreate` command. A retired volume remains mounted for inspection; quota changes require a separately scoped follow-up | Avoids adding destructive volume lifecycle behavior to the opt-in v1 |
| Policy conflict? | Shared policy says scratch goes "strictly to `/tmp`". P-5 asks the user to allow `scratch-new` paths on `/Volumes/diskm-scratch` | That file is owned by the user |
| Tests? | `diskutil` and `lsof` are injected via `DISK_MAGICIAN_{DISKUTIL,LSOF}_BIN` and a stateful fake. No test creates a volume or asserts permissions on a mounted root | Follows the `DF_BIN`/`DU_BIN` precedent |
| ZFC? | Not applicable. Every decision is a mechanical gate on measured facts | |

## Design

**Config** (`config.json.template`):

```json
"volumes": {"swap_headroom_gb": 40, "alarm_floor_gb": 20, "encryption": "none",
            "encryption_acknowledged_at": null,
            "classes": {"scratch": {"name": "diskm-scratch", "quota_gb": 30, "mountpoint": "/Volumes/diskm-scratch"}}}
```

**Registry:** `$STATE/volumes/registry.json`, written under flock with atomic replace. A corrupt file fails closed. Each entry holds `{class, name, uuid, container_uuid, quota_bytes, created_at, state: active|retired}`.

Every mutation first re-checks identity. All of the following must hold, otherwise the command exits rc 2:
- the registry UUID equals the `diskutil info` UUID;
- the name has the `diskm-` prefix;
- `Roles` is empty;
- the container matches;
- the target is not the System, Data, VM, Preboot or Recovery volume.

**Commands (`diskm volume …`):**

| Command | Behavior |
|---|---|
| `status [--json] [--snapshot]` | Shows volume and container rows, live fit, alarms and the unrouted-`/tmp` audit. The audit lists `/private/tmp/*` entries of 1 GiB or more from the latest existing snapshot, with `measured_at`, or reports `unknown`. It never walks. `--snapshot` omits the audit. Exit codes: 0 healthy, 1 degraded, 2 identity or config error |
| `plan-fit [--json]` | Live fit (above), with every term and `max_quota_gb_that_fits` |
| `create scratch [--execute]` | Dry-run by default. Refuses if the encryption acknowledgment is missing (rc 2), an active entry or the name exists (rc 2), the live fit fails (rc 2), or free space is below the alarm floor (rc 75). Runs `addVolume <ctr> APFS diskm-scratch -quota <N>g`, writes and verifies the ballast, then registers the volume as active. If ballast creation or verification fails, the registry remains unavailable. This is the enabling step |
| `path scratch [--for-reclaim]` | rc 0 prints the mountpoint after verifying identity and that the actual `MountPoint` equals the configured `mountpoint`. rc 75: an entry exists but the volume is unmounted, locked, mismatched or mounted elsewhere. rc 3: no active entry. `--for-reclaim` also accepts a `retired` entry, so retirement stops new allocations while reclaim can still drain the volume. Only `reclaim` uses this flag |
| `reclaim [--clean]` | The enumerator described above, judged by the extended C14 ephemeral classifier. Dry-run by default. Each removal is logged by the primitive. If a removal returns `kept:intent-write-failed`, it releases the ballast and retries that removal once (see Full-quota recovery); it recreates the ballast at the end of the run when space allows. Each run writes `reclaim_runs.json` |
| `retire scratch` | Sets state to `retired`. `path` then returns rc 3 and new scratch goes back to `/tmp`, while `path --for-reclaim` still resolves the volume. Nothing is deleted |

**Alarms:**
- `container_low` (free < 20 GiB);
- `container_critical` (< 10 GiB);
- `volume_high` (≥ 90%);
- `volume_full` (100%, an expected cap hit).

Alarms surface through `status` rc 1, the snapshot rows, and one added check in `disk_usage_alert.sh` that uses its existing notify and silence path. No new LaunchAgent.

**Admission:** when `--dest` is on the volume and current use is ≥90%, `diskm admit` requests the same bounded reclaim once, remeasures, then makes its final decision. No loop. If `quota − used − est < 1 GiB`, it refuses (rc 75, `volume_full:scratch`); otherwise admission succeeds. Reclaim failure or unmeasurable/stale status fails closed. The Data zone check is unchanged. `scratch-new` follows the same one-reclaim rule before path handoff and creates/prints no path if usage remains at high water. Neither operation guarantees against concurrent container-wide allocation or later producer `ENOSPC`.

**Attribution** follows the sibling contract (`2026-10-24-directory-inventory-growth-ledger-design.md`):
- Volume row: `{host_id, filesystem_id: <uuid>, kind: "filesystem", source: "apfs_volume", path: <mp>, class, allocated_bytes: CapacityInUse, quota_bytes, measured_at, status, attribution: "exclusive_exact"}`.
- Container row: `{filesystem_id: <container uuid>, source: "apfs_container", ceiling_bytes, free_bytes}`.

`disk_snapshot.sh` embeds these rows as `diskm_volumes`. When the probe fails the value is `null`, never 0.

**Invariants kept:**
- The never-delete list is unchanged, and no state root is mounted over or symlinked.
- `diskm` remains the single entry point.
- Every deletion is logged.
- Per-entry recency, lease, live-cwd and safety gates are unchanged.
- No cross-volume rename or copy.

## Deferred: Worktrees volume

The Worktrees volume starts only when all of the following hold:
1. A live fit passes for its cap plus Scratch, with a hardlink/clone inflation factor measured from Scratch.
2. A guard and test ensure that `gc.worktreePruneExpire=7.days.ago` (`set_gc_worktree_prune.sh`) never deregisters worktrees while the volume is unmounted, and that discovery skips unmounted volumes.
3. Migration is recoverable: copy, verify, `git worktree repair`, then the existing quarantine, with a tested rollback.
4. Scratch has run for at least two weeks.

## Risks and rollback

| Risk | Mitigation |
|---|---|
| Producers keep writing to Data | Audit plus existing protections; this is stated openly |
| Volume fills and a build fails | That is the cap working. Admission refuses before creation, and an alarm fires at 90% |
| Clones and hardlinks are lost on the volume | Measured from rollout bytes; feeds the deferred Worktrees fit |
| A retired volume remains allocated after rollback | Retire and drain through C14; keep it mounted for inspection. Volume deletion and quota changes are deferred from v1 |
| Unencrypted volume | Requires explicit acknowledgment |

**Rollback:**
1. `retire scratch`. New scratch goes to `/tmp`.
2. `reclaim --clean` drains the volume under its gates.
3. Keep the retired volume mounted and inspect it. v1 does not delete or recreate volumes; no raw `diskutil` deletion is used.

## Acceptance criteria

- **P1:**
  - Mocked tests pass for live fit, `create` (dry-run default, refusals, and the create → `path` rc 0 sequence) and status rows.
  - The snapshot embeds the rows, or `null`.
- **P2:**
  - `path` returns rc 75 when unmounted.
  - Alarms fire through `disk_usage_alert.sh`.
  - Spike S1 verifies automount, the unmounted fail-closed path, and the real list of OS dot-dirs. S2 deletion checks are deferred from v1.
- **P3:**
  - `scratch-new` creates nothing on rc 75.
  - `reclaim` removes aged eligible whole artifacts through the real C14 path (no stub), keeps fresh, leased or live ones, and skips dot-dirs. Eligible entries are ordered by ascending newest content mtime (oldest last-modified first); this is not access-time LRU.
  - **Automatic-trim pilot (required):** on a disposable test-only volume, drive measured quota use to ≥90% while the existing scheduled sweep job is configured; let the job trigger automatically through the same `tmp_scratch_sweep.sh` entry point (an accelerated documented test schedule is allowed). The operator must not call `reclaim` or invoke the sweep directly to satisfy this pilot. Assert eligible whole artifacts are removed oldest-content-mtime first only until measured use is ≤80%, while leased/protected and unmeasurable entries survive. Bound and record recovery by the configured schedule interval plus one sweep runtime. Before the next run, a producer can still receive `ENOSPC`. After recovery, create/write a new disposable artifact through `diskm scratch-new`; assert the write succeeds. With all candidates leased/protected, assert no deletion and report that the low-water target was not reached. This closes the fill→automatic trim→space-recovered→writes-resume path; primitive-only volume tests do not satisfy it.
  - `diskm status` prints the stuck line after two zero-removal runs.
  - Admission refuses on low headroom.
  - At a full quota, a supported-size aged entry is retried once through the real C14 path after the ballast is released; the ballast is recreated when space returns if space permits.
  - The C14 row keeps entries when the mount's UUID mismatches (`kept:volume-identity`).
  - After 24 h live, the audit list is recorded as the success baseline.

## Implementation Preconditions

| ID | Precondition | Blocks |
|---|---|---|
| P-1 | The user picks a cap that passes the live fit (13.3 GiB today), or frees Data until 30 GiB fits | Real `create` |
| P-2 | The user acknowledges an unencrypted volume, or approves Keychain encryption as a follow-up | Real `create` |
| P-3 | The user authorizes 1 GiB spike volumes. S1: the user reboots; record the automount path and the OS dot-dirs, and confirm `/Volumes/<name>` cannot be created by the user while unmounted (EACCES). S2, which concerned read-only volume deletion, is deferred with deletion/recreation from v1 | P2 acceptance |
| P-4 | The diff exceeds 150 production lines: `/cs` and `MERGE APPROVED` are required | Deploy |
| P-5 | The user amends the shared policy to allow `scratch-new` paths on `/Volumes/diskm-scratch` | Real `create` (the enabling step) |
| P-6 | `dd` producer repos adopt `scratch-new --kind build` | Capturing `dd` builds |
| P-7 | The sibling inventory is implemented | Inventory ingestion (snapshot embedding ships without it) |
| P-8 | Automatic-trim pilot uses only disposable test artifacts on a test-only quota volume; the existing scheduled job triggers through `tmp_scratch_sweep.sh` automatically (no manual reclaim/direct sweep invocation); no production volume or arbitrary user data | Pilot acceptance above |

No path needs sudo.

## Self-review

- **Round-2 findings:**
  - (a) ordering: create is the enabling step, and the sequence is tested;
  - (b) reclaim: an enumerator feeds the existing primitive, with a kept/removed test;
  - (c) no second quarantine root: per-parent `.dm-quarantine` is reused.
- **Opus:** dot-dirs are ignored and tested, and the unwritten markers were dropped.
- **Web-advice:**
  - the fit uses live values (13.3 GiB stated);
  - no `find -newermt` remains (recency uses the canonical helper);
  - no permission assertions are made on mounted roots;
  - cross-volume moves are forbidden.
- **Round 3:**
  - The C14 classifier row is added in `c14_ephemeral_retention`.
  - The volume root comes from config via `scratch_roots_get_volumes`, which sits outside the `protected_tmp_roots` scope.
  - A test proves removal end to end through the real C14 path.
  - The reclaim-stuck line is added.
- **Round 4:**
  - `path --for-reclaim` lets a retired-but-mounted volume drain; the retire→reclaim sequence is tested.
  - The long-lived-owner behavior is documented.
- **Round 5:**
  - Historical revision 5 proposed volume recreation; revision 10 defers deletion and recreation from v1.
  - Tests cover a concurrent `scratch-new` call and an `addVolume` failure.
  - Retention is hard-coded at 2880.
  - The header is corrected.
  - The quarantine gap is documented.
- **Round 6:**
  - Historical revision 6 added gated deletion and recreation; revision 10 supersedes this for v1. Rollback now retires and drains without deleting.
  - Historical revision 6 claimed the late-write race was eliminated by a read-only private-mount check and removed its window note. That claim is superseded: deletion/recreation and S2 checks are deferred from v1; no current acceptance claim says post-check writes are impossible.
  - The C14 row now verifies the UUID.
- **Round 7:**
  - Full-quota recovery: the `.diskm-ballast` file, released only on a C14 `ENOSPC` result, with one retry, and recreated when space returns.
  - The admission example is fixed: 29.5/30 GiB refuses for any estimate.
  - Historical revision 7 required retirement before recreation; revision 10 defers recreation from v1.
  - Historical S2 cited Pilot 2 for the planned delete flow; revision 10 defers that flow from v1.
- **Round 8:**
  - `scratch-new` pre-creates `.dm-quarantine` (0700) with each `<repo>/<kind>` parent, so C14's `mkdir` is not the first allocation at the cap. The ballast trigger stays `kept:intent-write-failed` only.
  - Pilot 3 is historical evidence only; it does not prove that large sidecars or concurrent APFS-container allocations cannot fail.
- No placeholders remain.

### Revision 12 pilot acceptance correction

- The earlier volume pilot created three disposable volumes and tested 1 GiB/200 MiB/100 MiB primitives once; it did not test automatic trim under pressure, multi-entry oldest-first behavior, measured low-water recovery, or writes resuming. It is not automatic-trim pilot evidence.
- Keep 48 h C14 age eligibility. Among eligible whole disposable entries, order by ascending newest content mtime and stop after the 80% low-water target once reclaim was triggered at 90%. This is a last-modified proxy, not true access-time LRU; current paths do not record reads/access events.
- Required pilot uses only disposable test artifacts and the existing scheduled sweep job / `tmp_scratch_sweep.sh` path; it triggers automatically (no manual reclaim or direct sweep invocation). A test-only accelerated cadence is allowed. Measure recovery within configured cadence plus one sweep runtime and disclose that a producer may receive `ENOSPC` before the next sweep. Protected/leased candidates survive, all-protected fails safe, and no production-volume creation or arbitrary user-data deletion is authorized.

### Revision 12 automatic-trim and admission requirements

- The installed existing hourly sweep automatically triggers trim at ≥90% and stops at ≤80%; a disposable pilot may accelerate the scheduled cadence but must not manually invoke reclaim/sweep. Recovery bound is configured cadence plus one run; at-full writers may see `ENOSPC` until then.
- At ≥90%, `diskm admit` and `scratch-new` each invoke the same reclaim at most once before the final headroom/path decision, remeasure, and fail closed if still high or unmeasurable. No unbounded retries. Ordering remains oldest last-modified eligible content, not true access-time LRU.

### Revision 11 review resolutions

- Lease writes preserve simultaneous producers: a locked `lease_add_owner --owner-pid` updates an owner set, and release removes only that owner. C14 preserves legacy single-owner reads and fails closed if any owner is alive or unmeasurable. `scratch-new` does not print or hand off a path unless its producer lease was acquired.
- Ballast recreation uses measured free space >= 64 MiB + 1 GiB; activation tests prove allocated blocks and failure behavior.
- C14 retains `kept:intent-write-failed` publicly while returning the sidecar errno as a typed field; only errno ENOSPC releases ballast.


## Revision 10 review resolutions

- C14 intent is explicitly bounded at 32 MiB against a verified 64 MiB reserve. Existing inventory serialization is measured before any filesystem mutation and preserves unknown fields; oversized intent is `kept:intent-too-large` with no destructive action.
- Ballast recovery is one release and one retry through the real C14 path. A concurrent container-wide allocation can consume headroom, so failure after retry remains kept and is not claimed impossible.
- Producer lifetime protection requires explicit PID plus process-start identity leases, including detached children and CI producers; agent leases are not assumed to propagate.

- Revision 10 defers `delete` and `recreate` from v1. Rollback is `retire scratch` followed by C14 drain; keep the retired volume mounted for inspection.
