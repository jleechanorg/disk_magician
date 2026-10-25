# Opt-in quota'd Scratch volume (`diskm volume`)

Date: 2026-10-25. This is revision 10, updated after Codex review of revision 9. Scope: disk_magician on the Mac (APFS container `disk3`). Planning only. This document does not authorize creating volumes, editing policy, deploying or merging.

## Outcome

Scratch requested through `diskm scratch-new` may land on one APFS volume with a quota. Exact usage comes from `diskutil`; nothing walks the tree for usage reporting. When the volume is unavailable, the request errors and nothing is written there. Aged entries are reclaimed by the existing per-entry C14 removal primitive. v1 is opt-in and covers Scratch only. Volume deletion and quota recreation are deferred; rollback retires the volume and drains eligible entries while keeping the volume available for inspection.

## Containment: what a quota does and does not do

- **Bounds only routed writes.** A quota limits writes that reach the volume. It does not reserve container space, and it does not contain producers that still write to Data.
- **A full container fails first.** If the container fills, the volume and Data both hit `ENOSPC` before any cap matters.
- **Data keeps today's protections.** These are the container free-space alarm (`disk_usage_alert.sh`, 20 GiB), `diskm admit`, budgets/`govern`, and the existing cleaners.
- **What the volume adds:** a ceiling on routed scratch, exact attribution, and an audit of scratch that is still on Data.
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
| How are aged entries reclaimed? | A new `volume reclaim [--clean]` enumerates exactly `<mp>/<repo>/<kind>/<entry>` and skips dot-names at every level. Each entry goes to `scratch_budget_quarantine_remove`, which runs C14 `--kind ephemeral`. The existing `tmp_scratch_sweep.sh` hourly job runs it | The existing cleaners do not reach these depths. One enumerator feeds the existing primitive, so no second quarantine root is needed |
| Will C14 accept these entries? | Not today: `c14_ephemeral_retention` in `scripts/lib/artifact_verdict.sh` only matches its own rows under `scratch_roots_get_unique`, so these entries return `kept:unproven-content`. Add one row: when the candidate is under a root from a new `scratch_roots_get_volumes` (in `scripts/lib/scratch_roots.sh`) and `rel` matches `^[^./][^/]*/(evidence\|build)/[^./][^/]*$`, return a hard-coded `2880` minutes (48 h), the same way the existing rows hard-code their retentions (`artifact_verdict.sh:176`) | Extends the existing classifier, not a parallel one. Recency, lease, live-cwd, fd, secret and repo checks stay in the same verdict |
| Is the mount at the root the registered volume? | Checked at removal time. In the `ephemeral` branch of `artifact_removal_verdict`, a candidate under a `scratch_roots_get_volumes` root first runs `volume.py verify-mount <root>`, which is the same UUID identity check `path` uses. A mismatch or error gives `kept:volume-identity` | A different volume at the configured path must never be trusted |
| Where does the scratch root come from? | `scratch_roots_get_volumes` reads `volumes.classes.*.mountpoint` from the same config file that `scratch_roots_protected` reads, and prints only existing canonical dirs. It is deliberately not part of `scratch_roots_get` | No hardcoded path. Being outside `scratch_roots_get` stops `protected_tmp_roots` basenames (`worldarchitect.ai`, …) from protecting `<mp>/<repo>` |
| Long-lived owners? | Extend `lease_write` with an explicit `--owner-pid PID` option that records both PID and process start identity; retain the caller identity as the default. `scratch-new` writes a lease for its producer, and child processes that continue writing must acquire their own lease before receiving the path. CI integrations must write/release leases around producer lifetime. Reclaim treats a PID whose start identity no longer matches as dead, but keeps entries on identity-read errors. Do not assume an agent lease propagates to detached children | PID reuse cannot release a live producer's lease; integration tests must cover detached children and PID/start identity |
| Reclaim health? | Each run writes `$STATE/volumes/reclaim_runs.json` (last two runs: `at`, `aged_scanned`, `removed`, top kept reason). `diskm status` prints one line, `volume_reclaim_stuck: aged=N removed=0 runs=2 reason=<r>`, when both runs scanned more than 0 aged entries and removed 0 | Detects a classifier gap before the volume reaches `ENOSPC`. No new daemon |
| Retention? | 48 h, hard-coded as 2880 in the classifier row; no config read | Matches the existing `pr*` row and how the classifier works |
| Full-quota recovery? | `create` verifies one 64 MiB ballast file, `<mp>/.diskm-ballast`, before activating the volume. Before any C14 filesystem mutation, reclaim serializes the complete existing inventory intent (preserving unknown fields) and measures its encoded byte length. The supported maximum is 32 MiB; larger or unmeasurable intent fails closed as `kept:intent-too-large`, with no sidecar, rename, or other destructive mutation. If the bounded sidecar write returns `kept:intent-write-failed` from `ENOSPC`, reclaim releases/logs the ballast and retries that same C14 removal once. A second failure remains kept; there is no loop. At run end, `ballast ensure` recreates it when free space is above 65 MiB. Tests prove oversized intent causes no mutation and the real C14 path releases/retries successfully within the 32 MiB bound. The 64 MiB reserve supports the tested bounded intent but cannot guarantee capacity against concurrent writers elsewhere in the APFS container; the bounded retry can still fail safely. `.dm-quarantine` creation failures remain kept and do not release the ballast | Without bounded intent and the retry, a full volume may not reclaim itself; the reserve improves recovery but is not a container-wide capacity guarantee |
| Quarantined/deferred entries? | Entries left in `.dm-quarantine` count toward the quota, and nothing calls `quarantine_reconcile`. This is an existing gap across all roots and is out of scope. The `volume_reclaim_stuck` line surfaces it | It belongs to the C14 owner, not this design |
| Cross-volume moves? | Forbidden. Nothing renames or copies between Data and the volume. Quarantine is per-parent, so it stays on the same filesystem. Rollback drains in place | Cross-volume `rename` fails with EXDEV, and a copy would double usage |
| OS-created dot-dirs? | `reclaim` skips every dot-name. In `delete`'s emptiness check, the contents of the index-only metadata dirs `.Spotlight-V100` and `.fseventsd` are ignored. `.Trashes`, `.TemporaryItems` and `.DocumentRevisions-V100` are ignored only when empty: any entry beneath them makes the volume non-empty. The regular file `.diskm-ballast` at the root is ignored by exact name | macOS creates these dirs on user volumes. Trash, temp items and document revisions can hold user data |
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

**Admission:** when `--dest` is on the volume and `quota − used − est < 1 GiB`, `diskm admit` also refuses (rc 75, `volume_full:scratch`). For example, 29.5 of 30 GiB used refuses for any estimate, because only 0.5 GiB of headroom remains. The Data zone check is unchanged.

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
  - `reclaim` removes an aged eligible entry through the real C14 path (no stub), keeps fresh, leased or live ones, and skips dot-dirs.
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
  - The late-write race is eliminated by unmounting and checking on a read-only private mount. The window note is removed.
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


## Revision 10 review resolutions

- C14 intent is explicitly bounded at 32 MiB against a verified 64 MiB reserve. Existing inventory serialization is measured before any filesystem mutation and preserves unknown fields; oversized intent is `kept:intent-too-large` with no destructive action.
- Ballast recovery is one release and one retry through the real C14 path. A concurrent container-wide allocation can consume headroom, so failure after retry remains kept and is not claimed impossible.
- Producer lifetime protection requires explicit PID plus process-start identity leases, including detached children and CI producers; agent leases are not assumed to propagate.

- Revision 10 defers `delete` and `recreate` from v1. Rollback is `retire scratch` followed by C14 drain; keep the retired volume mounted for inspection.
