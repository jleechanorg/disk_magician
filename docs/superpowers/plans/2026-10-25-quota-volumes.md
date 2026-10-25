# Opt-in Scratch Quota Volume Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship `diskm volume` for one opt-in Scratch volume with a quota.
- Paths come only from `diskm scratch-new`, and only while the volume is available (fail-closed).
- Reports show exact usage.
- At ≥90% quota use, the existing scheduled hourly sweep automatically trims eligible whole disposable artifacts oldest-content-mtime first through C14 until ≤80%; it preserves protected entries and reports when recovery cannot reach target. This is last-modified ordering, not access-time LRU. `diskm admit` and `scratch-new` each may request the same bounded reclaim once at high water before their final decision; they never loop.

**Architecture:**
- `scripts/volume.py` (stdlib) sits behind `disk_magician.sh volume)`. It handles registry, live fit, create, path, status, retire and the quota ballast file; delete/recreate are deferred from v1.
- `scripts/volume_reclaim.sh` is a small enumerator that feeds `scratch_budget_quarantine_remove`.
- Hooks into existing code: `scratch_new.sh`, `disk_budget.py` (admit), `disk_snapshot.sh`, `disk_usage_alert.sh`, `tmp_scratch_sweep.sh`.
- No new LaunchAgent, no symlinks, no wipe, no cross-volume copy.

**Tech Stack:** bash, Python 3 stdlib, unittest, repo shell tests.

**Spec:** `docs/superpowers/specs/2026-10-25-quota-volumes-design.md`. Steps marked **[COND P-x]** wait for that precondition.

## Conventions

- **Python test command:** `python3 -m unittest discover -s tests -p 'test_volume.py' -k <Name> -v`
- **Regression before each commit:** `python3 -m unittest discover -s tests -p 'test_*.py'` and `bash ./disk_magician.sh test-shell`
- **Test environment:** tests set these variables to temp paths:
  - `DISK_MAGICIAN_DISKUTIL_BIN=tests/lib/fake_diskutil.py`
  - `FAKE_DISKUTIL_STATE`, `FAKE_DISKUTIL_CALLS`
  - `DISK_MAGICIAN_LSOF_BIN`
  - `DISK_MAGICIAN_STATE_DIR`, `DISK_MAGICIAN_CONFIG`
  - `DISK_MAGICIAN_DELETION_LOG`
- **Never call the real `diskutil` in tests.** Never assert permissions on a mounted root.
- **Packaging:** after editing root scripts, run `bash scripts/sync_package_tree.sh` and stage the `src/disk_magician/` copies by explicit path.
- **Commits:** run `git branch --show-current` in the same command as the commit. Suffix `[claude][opus-5.5]`.

## Phase P1 — fit / create / status

### Task 1: Fake diskutil + parsing

**Files:**
- Create `tests/lib/fake_diskutil.py`, `scripts/volume.py`, `tests/test_volume.py`.

**What the fake does:**
- Answers `apfs list -plist` (`Containers[]` with `APFSContainerUUID`, `CapacityCeiling`, `CapacityFree`, `ContainerReference`, `Volumes[]` with `APFSVolumeUUID`, `CapacityInUse`, `CapacityQuota`, `DeviceIdentifier`, `Name`, `Roles`).
- Answers `info -plist <x>` (`MountPoint`, `VolumeUUID`, `APFSContainerReference`, `DeviceIdentifier`, `CapacityInUse`).
- Records `apfs addVolume`, mount and unmount in order.
- `FAKE_DISKUTIL_BUSY=1` makes `unmount` exit 1.
- `FAKE_DISKUTIL_FAIL_ADD=1` makes `addVolume` exit 1.
- `FAKE_DISKUTIL_HOOK=<cmd>` runs before each mutating verb; retained fake support for `deleteVolume` is unused by v1.

**Steps:**
1. **Failing test:**
   ```python
   class ParseTest(VolumeTestBase):
       def test_container_rows(self):
           c = volume.load_container()
           self.assertEqual((c.ref, c.ceiling), ("disk3", 994662584320))
           self.assertEqual(c.volume_by_role("Data").used, 889873108992)
       def test_fake_bin_in_use(self):
           self.assertNotEqual(volume.diskutil_bin(), "/usr/sbin/diskutil")
   ```
2. **RED:** `… -k ParseTest -v` fails with `ModuleNotFoundError: No module named 'volume'`.
3. **Implement:** `diskutil_bin()`, `_plist(args, timeout=8)`, and `load_container()` (`info -plist /System/Volumes/Data` → `APFSContainerReference` → `apfs list -plist`).
4. **GREEN** plus regression.
5. **Commit** the three files.

### Task 2: Live fit (`plan-fit`)

**Files:**
- Modify `config.json.template` (spec `volumes` block).
- Modify `scripts/volume.py` (`load_config()` via `resolve_config.resolve()`; `fit()`).
- Test in `tests/test_volume.py`.

**Steps:**
1. **Failing test:**
   ```python
   class FitTest(VolumeTestBase):            # seeded with the 2026-10-25 host numbers
       def test_live_fit_today(self):
           r = volume.fit(volume.load_config(), volume.load_container())
           self.assertFalse(r["ok"])                                  # 30 GiB requested
           self.assertAlmostEqual(r["max_quota_gb_that_fits"], 13.3, delta=0.2)
       def test_uses_live_data_not_constant(self):
           self.set_used("Data", 780 * 2**30)
           self.assertTrue(volume.fit(volume.load_config(), volume.load_container())["ok"])
       def test_vm_above_headroom_wins(self):
           self.set_used("VM", 45 * 2**30)
           r = volume.fit(volume.load_config(), volume.load_container())
           self.assertAlmostEqual(r["swap_term_gb"], 45, delta=0.1)
   ```
2. **RED:** `… -k FitTest -v` fails because `fit` is missing.
3. **Implement:** `quota + Data_used + system_used + max(VM_used, swap_headroom) + alarm_floor ≤ ceiling`, returning every term and `max_quota_gb_that_fits`.
4. **GREEN** plus regression.
5. **Commit.**

### Task 3: Registry + `status --json`

**Files:**
- Modify `scripts/volume.py`: `Registry` with flock, temp file, fsync and `os.replace`. A corrupt registry raises `RegistryError`. Add `status(snapshot=False)`.
- Test in `tests/test_volume.py`.

**Steps:**
1. **Failing test:**
   ```python
   class StatusTest(VolumeTestBase):
       def test_rows_follow_sibling_contract(self):
           self.seed_scratch(used=5*2**30, mounted="/Volumes/diskm-scratch")
           v = self.scratch_row()
           self.assertEqual((v["allocated_bytes"], v["quota_bytes"], v["attribution"]),
                            (5*2**30, 30*2**30, "exclusive_exact"))
       def test_corrupt_registry_fails_closed(self):
           self.registry_path.write_text("{")
           with self.assertRaises(volume.RegistryError): volume.Registry().load()
       def test_unreadable_usage_is_null(self):
           self.seed_scratch(used=None); self.assertIsNone(self.scratch_row()["allocated_bytes"])
   ```
2. **RED:** `… -k StatusTest -v`.
3. **Implement:** return rc 0 when healthy, 1 when degraded, 2 on identity or config errors.
4. **GREEN** plus regression.
5. **Commit.**

### Task 4: `create` as the enabling step; `path`; `retire`

**Files:**
- Modify `scripts/volume.py`: `create()`, `path_cmd()`, `retire()`, `verify_identity()`, and `ballast ensure|release`.
  - `BALLAST = ".diskm-ballast"`, exactly 64 MiB of allocated bytes at `<mp>/.diskm-ballast`; verify its size and allocation before registering the volume active.
  - `ensure` writes it only when measured free space (`quota − used`) is at least 64 MiB + 1 GiB (1,088 MiB), and does nothing below that threshold. `create --execute` must create and verify the ballast before setting registry state to active; on failure the registry remains unavailable.
  - `release` removes it if it is a regular file and logs the removal (`deletion_log volume release_ballast 0 <path> "uuid=…"`). It runs the same identity check as `path`.
- Modify `tests/test_deletion_log_coverage.sh` to register `volume.py`.
- Test in `tests/test_volume.py`.

**Steps:**
1. **Failing test:**
   ```python
   class EnableSequenceTest(VolumeTestBase):
       def test_create_then_path_then_retire(self):
           self.ack_unencrypted(); self.fit_passes()
           self.assertEqual(volume.main(["path", "scratch"]), 3)                  # nothing registered
           self.assertEqual(volume.main(["create", "scratch"]), 0)                # dry-run
           self.assertEqual(self.calls(), [])
           self.assertEqual(volume.main(["create", "scratch", "--execute"]), 0)   # enabling step
           self.assertIn("apfs addVolume disk3 APFS diskm-scratch -quota 30g", " ".join(self.calls()[0]))
           self.assertEqual(volume.main(["path", "scratch"]), 0)
           self.unmount_fake(); self.assertEqual(volume.main(["path", "scratch"]), 75)
           self.mount_fake(); volume.main(["retire", "scratch"])
           self.assertEqual(volume.main(["path", "scratch"]), 3)
           self.assertNotIn("deleteVolume", self.flat_calls())
       def test_refusals(self):
           for cond, rc in [("no_ack", 2), ("fit_fails", 2), ("name_exists", 2),
                            ("active_exists", 2), ("free_below_alarm", 75)]:
               with self.subTest(cond=cond):
                   self.reset(); self.ack_unencrypted(); self.fit_passes(); self.apply(cond)
                   self.assertEqual(volume.main(["create", "scratch", "--execute"]), rc)
       def test_mounted_elsewhere_is_unavailable(self):
           self.seed_scratch(mounted="/Volumes/diskm-scratch 1")
           self.assertEqual(volume.main(["path", "scratch"]), 75)
       def test_uuid_mismatch_is_unavailable(self):
           self.seed_scratch(mounted="/Volumes/diskm-scratch", registry_uuid="OTHER")
           self.assertEqual(volume.main(["path", "scratch"]), 75)
       def test_identity_rejects_system_roles(self):
           self.assertFalse(volume.verify_identity({"uuid": self.data_uuid, "name": "Data"}))
       def test_create_writes_allocated_ballast(self):
           self.ack_unencrypted(); self.fit_passes()
           self.assertEqual(volume.main(["create", "scratch", "--execute"]), 0)
           ballast = self.mp / ".diskm-ballast"
           self.assertEqual(ballast.stat().st_size, 64 * 2**20)
           self.assertGreaterEqual(ballast.stat().st_blocks * 512, 64 * 2**20)
       def test_sparse_ballast_rejected_and_create_stays_inactive(self):
           self.ack_unencrypted(); self.fit_passes(); self.inject_sparse_ballast_or_allocation_failure()
           self.assertNotEqual(volume.main(["create", "scratch", "--execute"]), 0)
           self.assertNotEqual(volume.load_registry()["classes"]["scratch"]["state"], "active")
       def test_ballast_release_and_ensure(self):
           self.mounted(used=5 * 2**30); volume.main(["ballast", "ensure"])
           self.assertTrue((self.mp / ".diskm-ballast").is_file())
           self.assertEqual(volume.main(["ballast", "release"]), 0)
           self.assertFalse((self.mp / ".diskm-ballast").exists()); self.assertEqual(len(self.deletion_log_lines()), 1)
           self.set_volume_used(30 * 2**30 - 512 * 2**20); volume.main(["ballast", "ensure"])   # free 0.5 GiB < ballast + 1 GiB
           self.assertFalse((self.mp / ".diskm-ballast").exists())
           self.set_volume_used(5 * 2**30); volume.main(["ballast", "ensure"])
           self.assertTrue((self.mp / ".diskm-ballast").is_file())
   ```
2. **RED:** `… -k EnableSequenceTest -v`.
3. **Implement.**
4. **GREEN** plus regression.
5. **Commit.**

### Task 5: Dispatch

**Files:**
- Modify `disk_magician.sh`: add `volume) exec python3 "$SCRIPT_DIR/scripts/volume.py" "$@" ;;` and a help line.
- Create `tests/test_volume_dispatch.sh`.

**Steps:**
1. **Failing test:** `bash ./disk_magician.sh volume plan-fit --json` (run with the fake) prints JSON with `max_quota_gb_that_fits`.
2. **RED:** fails with `Unknown command: volume`.
3. **Implement**, then run `bash scripts/sync_package_tree.sh`.
4. **GREEN**, `sync-package-tree --check`, regression.
5. **Commit.**

### Task 6: Snapshot embeds `diskm_volumes`

**Files:**
- Modify `scripts/disk_snapshot.sh`: next to the existing `diskutil apfs list -plist` probe (around lines 350–365), add `probe_timeout 8 python3 "$SCRIPT_DIR/volume.py" status --json --snapshot` with a `null` fallback.
- Create `tests/test_disk_snapshot_volumes.sh`, modelled on `tests/test_disk_snapshot_swap_vm.sh`.

**Steps:**
1. **Failing test:**
   - (a) A seeded volume yields `allocated_bytes == 5368709120`.
   - (b) A failing fake yields `diskm_volumes == null`.
2. **RED.**
3. **Implement.**
4. **GREEN**, plus `bash tests/test_disk_snapshot_swap_vm.sh`, plus regression.
5. **Commit.**

## Phase P2 — alarms + spikes

### Task 7: Alarms in `status` and `disk_usage_alert.sh`

**Files:**
- Modify `scripts/volume.py` (`alarms()`).
- Modify `scripts/disk_usage_alert.sh`: after the Data check, run `status --json --snapshot` and send each alarm through the existing notify/silence path.
- Tests in `tests/test_volume.py` and `tests/test_swap_warning.sh` (which already runs `disk_usage_alert.sh` against fakes).

**Steps:**
1. **Failing test:**
   - Free space 15 GiB with scratch at 28/30 yields `{"container_low", "volume_high"}` and status rc 1.
   - The alert script prints `volume_high scratch`.
2. **RED** for both tests.
3. **Implement.**
4. **GREEN** plus regression.
5. **Commit.**

### Task 8: Spike S1 **[COND P-3]**

**TDD: N/A.** This is an empirical platform check.

**Verification:** `/tmp/disk_magician/evidence/quota-volumes-spikes-<UTC>/RESULT.md` records the exact commands, return codes, and a final `diskutil list disk3` showing no `diskm-spike-*` volume.

**S1 (the user reboots):**
- Record the automount path after login.
- Record `ls -a <mp>` to get the real OS dot-dirs.
- While the volume is unmounted, `mkdir /Volumes/diskm-spike-1` must fail with EACCES. This is checked on the unmounted path, not the mounted root.
- If the real dot-dir list differs from the spec, update the constant `OS_DOT_DIRS` and its tests first (Task 11).


Deletion-specific read-only mount checks (S2) are deferred with volume deletion/recreation from v1.
## Phase P3 — routing + reclaim

### Task 9: `scratch-new` on the volume + `--kind build`

**Files:**
- Modify `scripts/scratch_new.sh`:
  - Accept `kind=build`.
  - For `evidence` and `build`, call `diskm volume path scratch` (overridable via `DISK_MAGICIAN_DISKM_BIN`):
    - rc 0: before handing out a path, read quota use. At ≥90%, request the same `diskm volume reclaim --clean` once, remeasure, and fail closed without creating the parent or printing a path if the high-water trigger remains. Never loop. Otherwise path is `<mp>/<repo>/<kind>/<purpose>-<UTC>`, with containment checked against `<mp>`. When it creates the `<repo>/<kind>` parent it first runs `mkdir -m 0700 <parent>/.dm-quarantine` (tolerating an existing directory; failure returns 1). C14 requires a directory owned by the user with mode exactly 0700 (`quarantine_rename.py:288-296`), so the mode must not depend on umask.
    - rc 75: return 75 and create nothing.
    - rc 3: keep the legacy `$EVIDENCE_TMP_ROOT/<repo>/<kind>/…`.
- Test in `tests/test_scratch_new.sh`.

**Steps:**
1. **Failing test:**
   - (a) rc 0 creates under the fake `<mp>`.
   - (b) rc 75 exits 75, and `test ! -e` passes for both candidate paths. At ≥90%, stub reclaim to count calls and mutate measured use: prove one call and remeasurement, successful handoff only after recovery below the trigger, and no path or parent on failed/unmeasurable reclaim; prove no retry loop.
   - (c) rc 3 produces the legacy path.
    - (d) `--kind build` with rc 3 produces `…/<repo>/build/…`.
   - (e) With rc 0, every parent `scratch-new` creates (evidence and build) has `.dm-quarantine` as a directory, mode 0700, owned by the user; a second call into an existing parent leaves it intact.
2. **RED:** `bash tests/test_scratch_new.sh`.
3. **Implement.**
4. **GREEN** plus regression.
5. **Commit.**

### Task 10: Admission volume headroom

**Files:**
- Modify `scripts/disk_budget.py`, admit path (around line 1018): when the dest realpath is under the scratch `<mp>` and current use is ≥90%, request `diskm volume reclaim --clean` once, then remeasure; do not loop. If fresh use remains ≥90%, return rc 75 with `volume_full:scratch` regardless of estimated headroom. Otherwise apply the existing admission rule: `quota − used − est ≥ 1 GiB` admits; less than 1 GiB returns rc 75. Reclaim failure or stale/unmeasurable quota fails closed.
- Tests in `tests/test_disk_budget.py` and `tests/test_admit.sh`: prove high-water admission invokes reclaim at most once then remeasures, enough headroom admits, insufficient headroom rejects, and unavailable/unmeasurable status fails closed.

**Steps:**
1. **Failing test:**
   - At 29.5/30 GiB, even `est=0.1` refuses if one reclaim leaves fresh use ≥90%; remaining high water takes precedence over headroom.
   - If one reclaim takes 29.5/30 below 90% to 26/30, `est=2` admits (2 GiB headroom) and `est=2.1` refuses (0.9 GiB headroom).
   - Below 90%, 20/30 GiB with `est=0.1` admits. Prove the final decision uses the post-reclaim measurement, and reclaim is called at most once.
2. **RED:** `python3 -m unittest discover -s tests -p 'test_disk_budget.py' -k volume -v`.
3. **Implement.**
4. **GREEN**, plus `bash tests/test_admit.sh`, plus regression.
5. **Commit.**

### Task 11: Extend the C14 ephemeral classifier, add a `volume reclaim` enumerator, and a stuck signal

Today `scratch_budget_quarantine_remove` runs C14 with `--kind ephemeral`. Its classifier, `c14_ephemeral_retention` in `scripts/lib/artifact_verdict.sh`, matches rows only under `scratch_roots_get_unique`. Volume entries therefore return `kept:unproven-content`. This task extends that classifier and adds no parallel one.

**Files:**
- Modify `scripts/lib/worktree_lease.sh` and focused tests compatibly: keep reading legacy single-owner `owner` files; represent concurrent writers in an `owners` array. Add `lease_add_owner --owner-pid PID` to add (idempotently) PID plus process-start identity, serialized with the existing lease mutation lock; add owner-scoped release that cannot remove another writer. Aggregate liveness: any alive/alive-expired or unknown owner keeps; permit reclaim only when all owners are dead/released. Wire producer/CI wrappers to acquire and release. A detached child acquires its own owner before receiving a scratch path. Test parent+child concurrent acquisition without replacement, either live owner blocking, one-owner release retaining the other, all-dead permitting reclaim, PID/start mismatch as dead, identity-read errors as unknown/kept, and CI acquire-release.
- Modify `scripts/lib/scratch_roots.sh`: add `scratch_roots_get_volumes [config.json]`.
  - It reads `volumes.classes.*.mountpoint` from the given config. If no config is given, it uses the path printed by `scripts/resolve_config.py`.
  - It prints each existing directory canonicalized with `cd && pwd -P`.
  - It is **not** added to `scratch_roots_get`, so `protected_tmp_roots` basenames never protect `<mp>/<repo>`.
- Modify `scripts/lib/artifact_verdict.sh` (`c14_ephemeral_retention`): after the existing `scratch_roots_get_unique` loop and before the `--archive-origin` early return, add one loop over `scratch_roots_get_volumes`.
  - When `rel` matches `^[^./][^/]*/(evidence|build)/[^./][^/]*$`, echo `2880`. This is hard-coded, like the existing rows at `artifact_verdict.sh:176`; no config read.
  - In the `ephemeral)` branch of `artifact_removal_verdict`, before calling the classifier: if the candidate is under a `scratch_roots_get_volumes` root, run `python3 "$_AV_DIR/../volume.py" verify-mount "$root"`. If its rc is not 0, echo `kept:volume-identity` and return.
- Modify `scripts/volume.py`: add `verify-mount <dir>`. It returns rc 0 only when `info -plist <dir>` shows a `VolumeUUID` equal to an active or retired registry UUID and a `MountPoint` equal to `<dir>`. It reuses `path`'s identity function.
- Create `scripts/volume_reclaim.sh`, which sources `scripts/lib/scratch_budget.sh`.
  - It gets `<mp>` from `diskm volume path scratch --for-reclaim`. That call accepts active or retired entries, so reclaim still works after `retire`. On rc ≠ 0 it prints `skipped:unavailable` and exits 0.
  - It takes `<mp>/<repo>/<kind>/<entry>` at exact depth 3 via globs, skipping names that start with `.` at every level.
  - It counts entries whose newest mtime exceeds retention as `aged`.
  - In dry-run it prints `would_check`. With `--clean` it runs `result=$(scratch_budget_quarantine_remove "$entry")` and counts `removed:*`, recording kept reasons.
  - In the existing C14 inventory serialization path in `scripts/quarantine_rename.py`, preserve unknown fields, serialize once, and measure the encoded bytes before creating `.dm-quarantine`, writing a sidecar, or renaming anything. Support up to 32 MiB; serialization failure or overflow returns `kept:intent-too-large`, with no candidate, parent, sidecar, or log mutation.
  - Preserve public reason `kept:intent-write-failed` and add typed `intent_write_errno` from `quarantine_rename.py` through the existing wrapper to reclaim. Only sidecar errno ENOSPC triggers; other errors never do. Do not infer errno from logs or reason text. If `result` is `kept:intent-write-failed` due to `ENOSPC` on the bounded C14 sidecar write, run `diskm volume ballast release` and retry that same removal once. A second failure remains kept; there is no loop. No other result releases the ballast. C14 checks are not bypassed: the retry goes through the same primitive. The 64 MiB reserve does not guarantee capacity against concurrent APFS-container writers.
  - After the run it runs `diskm volume ballast ensure`.
  - The enumeration excludes `.diskm-ballast` by exact name, in addition to the dot-name skip.
  - Each run atomically writes `$STATE/volumes/reclaim_runs.json` (last two runs: `at`, `quota_used_before_pct`, `quota_used_after_pct`, `aged_scanned`, `removed`, `target_pct`, `target_reached`, `top_kept_reason`). The CLI reports `trim_target_not_reached` with before/after usage and kept reasons when the 80% target remains unmet.
- Modify `scripts/volume.py` so the `reclaim` verb execs the script. (`ballast ensure|release` already exist from Task 4.)
- Reclaim trigger/ordering: retain the 48 h C14 eligibility floor. Read exact quota use from the existing volume status/diskutil path. Below 90%, do not trim. At ≥90%, order only eligible whole entries by ascending `scratch_budget_content_mtime` (the helper's newest real content mtime; never access-time), invoke the existing C14 primitive, and remeasure after each successful removal; stop at ≤80%. Unmeasurable entries are preserved/excluded. If the target cannot be reached because candidates are protected/leased/unmeasurable or removals fail, stop and report target-not-reached with retained reasons; do not broaden eligibility or claim recovery. The existing scheduled hourly sweep invokes this automatically; no operator reclaim call is part of acceptance and no new daemon/runner is added. A disposable pilot may use an accelerated schedule, but it must invoke the same scheduled entry point automatically.
- Modify `scripts/tmp_scratch_sweep.sh` to add a step after `run_cleanup_tmp` that runs `diskm volume reclaim` (with `--clean` when cleaning). The installed existing hourly job therefore triggers reclaim without operator action. A failure continues and sets rc=1.
- Modify `scripts/disk_status.py` to print one line when both runs in `reclaim_runs.json` have `aged_scanned>0` and `removed==0`: `volume_reclaim_stuck: aged=<n> removed=0 runs=2 reason=<r>`.
- Tests:
  - Create `tests/test_volume_reclaim.sh`.
  - Update `tests/test_tmp_scratch_sweep.sh`, `tests/test_scratch_roots.sh` and `tests/test_disk_status.py`.

**Steps:**

1. **Write the failing tests.** `tests/test_volume_reclaim.sh` runs the **real** `artifact_verdict.sh` / `quarantine.sh` / `quarantine_rename.py` path, with no stub of the primitive. Setup:
   - The fake `<mp>` is a temp dir.
   - A temp config has `volumes.classes.scratch.mountpoint=<mp>`; `DISK_MAGICIAN_CONFIG` points at it.
   - A fake `diskm volume path scratch --for-reclaim` prints `<mp>`. In case (j) the real `volume.py` and the fake diskutil are used instead.
   - `DISK_MAGICIAN_DELETION_LOG` is temp.
   - The test uses the sandbox env from `tests/lib/sandbox_env.sh`.
   - Mtimes are set with `touch -t`.

   Cases:
   - (a) `<mp>/wa/build/old`, aged 72 h, is removed with `--clean`. The result is `removed:*`, the path is gone, nothing remains in `<mp>/wa/build/.dm-quarantine`, and there is one deletion-log line.
   - (b) `<mp>/wa/evidence/fresh`, aged 30 min, is kept with `kept:recent-activity`.
   - (c) An aged entry held as cwd by `(cd <entry> && sleep 60) &` is kept with a `kept:*` live-cwd reason.
   - (d) An aged entry leased via `lease_write` is kept. Keep legacy single `owner` reads and store simultaneous producers in `owners`; add-owner/release operations serialize through the existing lease mutation lock. Reclaim keeps if any owner is alive or unknown, and permits removal only when all are dead/released.
   - (e) `<mp>/.Spotlight-V100/x`, `<mp>/.fseventsd/y`, `<mp>/wa/build/.dm-quarantine/z` and `<mp>/.diskm-ballast` are untouched and never listed.
   - (f) An unavailable volume gives `skipped:unavailable`, rc 0, and no removals.
   - (g) `<mp>/worldarchitect.ai/build/old`, aged 72 h, is removed even though `worldarchitect.ai` is in `protected_tmp_roots`.
   - (h) A `/private/tmp`-style path `$TMP/x/build/old` outside `<mp>` still returns `kept:unproven-content`. This proves the new row is scoped to the volume.
   - (j) Retire, then reclaim: after `diskm volume retire scratch` (real `volume.py`, fake diskutil, volume mounted), `path scratch` returns rc 3 and `path scratch --for-reclaim` returns rc 0. `reclaim --clean` removes an aged entry and keeps a fresh one and a leased one.
   - (k) A fake diskutil reports a different `VolumeUUID` mounted at `<mp>`. An aged entry is kept with `kept:volume-identity`, and nothing is removed.
   - (i) After two `--clean` runs where every aged entry is leased, `reclaim_runs.json` shows `aged_scanned>0`, `removed=0` ×2.
   - (l) Full quota. `<mp>/.diskm-ballast` is verified at exactly 64 MiB with physical blocks allocated; sparse logical-size files are rejected. Creation tests inject allocation/verification failure and assert `create` fails without an active registry entry. Recreate at measured free space 1,088 MiB succeeds and just below does not. With a serialized intent at the supported 32 MiB maximum, the test wraps `scratch_budget_quarantine_remove` in a shell function that calls the real function with `DISK_MAGICIAN_TEST_INTENT_ERRNO=28` (the existing intent-write fault hook in `quarantine_rename.py`) only while `<mp>/.diskm-ballast` exists. This simulates `ENOSPC` until the ballast is released, and the real C14, quarantine and rename path still runs. With real `volume.py` and the fake diskutil reporting 5 GiB used:
     - inject typed sidecar errno ENOSPC: the aged 72 h entry first returns public `kept:intent-write-failed`, ballast is released (one deletion-log line), and the single retry returns `removed:*` through the real path (entry gone, one more line); inject a different errno such as EIO and prove no ballast release/retry;
     - a fresh entry, a live-cwd entry and a leased entry are kept with their usual reasons and do not release the ballast;
     - after the run the ballast exists again at 64 MiB;
     - with the fake reporting used = quota − 0.5 GiB at the end of the run, the ballast is not recreated because 0.5 GiB is below the 1,088 MiB threshold.
   - (q) Missing `.dm-quarantine` plus a real `mkdir` `ENOSPC`. Add one hook at the C14 mkdir site, mirroring the existing `DISK_MAGICIAN_TEST_INTENT_ERRNO`: in `quarantine_rename.py`, just before `os.mkdir(".dm-quarantine", 0o700, dir_fd=pfd)`, `if ENV.get("DISK_MAGICIAN_TEST_MKDIR_ERRNO") and not os.path.isdir(os.path.join(parent, ".dm-quarantine")): raise OSError(int(ENV["DISK_MAGICIAN_TEST_MKDIR_ERRNO"]), "test")`. With `=28`:
     - an entry whose parent was made by `scratch-new` (so `.dm-quarantine` exists) is removed normally (the real `mkdir` on an existing directory raises `FileExistsError`, not `ENOSPC`);
     - a pre-existing parent with no `.dm-quarantine` returns `kept:check-failed`, does **not** release the ballast, is not retried, and the run ends rc 0 with `check-failed` as `top_kept_reason` in `reclaim_runs.json` (so the stuck line shows it rather than the failure being silent).
   - (m) With the hook forced on regardless of the ballast, the aged entry is attempted twice at most, the ballast is released once, the result is kept (`kept:intent-write-failed`), and the run ends rc 0.
   - (o) An intent larger than 32 MiB and an unmeasurable serialized intent both return `kept:intent-too-large`; assert the candidate, parent, `.dm-quarantine`, sidecar and deletion log are unchanged.
   - (p) Lease tests cover compatible legacy single-owner reads plus concurrent `owners` entries. Parent and child add owners simultaneously; neither overwrites the other. Either alive owner blocks reclaim, unknown identity blocks, and only all-dead permits removal. Cover child exit, PID/start mismatch, read errors and CI acquire/release. Release removes only the caller owner and leaves other owners intact.
   - (r) Force producer lease acquisition failure in `scratch-new`; assert nonzero exit, empty stdout (no path handoff), and no downstream path use. Successful producer lease acquisition must precede path output.
   - (s) With the fake volume at ≥90%, verify pressure-triggered ordering, one-at-a-time remeasurement, the ≤80% stop, protected retention, and explicit target-not-reached when all candidates are protected. This is a deterministic fake-volume unit case only; it does not satisfy the separate macOS/APFS pilot or release gate in Task 14.

   Also add these tests:
   - `test_scratch_roots.sh`: `scratch_roots_get_volumes` prints `<mp>` only when it exists, and `scratch_roots_get` does not include it.
   - `test_disk_status.py::test_volume_reclaim_stuck_line`: a fixture `reclaim_runs.json` (two zero-removal runs) prints the line; one run with removals prints nothing.
   - `test_tmp_scratch_sweep.sh`: a stub `diskm` records `volume reclaim --clean`.
2. **Run them to confirm RED.** `bash tests/test_volume_reclaim.sh` should fail with the script missing. Once the script exists but the classifier row does not, case (a) should yield `kept:unproven-content`. Case (l) fails because the entry stays `kept:intent-write-failed` (the script does not yet release the ballast); case (m) fails on the missing release count. The other three tests should fail on their new assertions.
3. **Write the minimal implementation**, in this order: `scratch_roots_get_volumes`, the classifier row, the enumerator, the ballast release-and-retry, the run record, the wrapper step, the status line.
4. **Run GREEN.** Then run:
   - `bash tests/test_artifact_verdict.sh`
   - `bash tests/test_scratch_budget.sh`
   - `bash tests/test_quarantine.sh`
   - `bash tests/test_cleanup_tmp_large_protections.sh`
   - `bash tests/test_deletion_log_coverage.sh` (register `volume_reclaim.sh` if required)
   - the full regression
5. **Commit.**

### Task 12: Unrouted-`/tmp` audit (the v1 success measure)

**Files:**
- Modify `scripts/volume.py`: `audit_tmp()` reads the latest snapshot through the path that `scripts/lib/resolve_snapshot_json.sh` resolves. It lists `/private/tmp/*` entries ≥1 GiB with `measured_at`, or returns `{"status": "unknown"}`.
- Test in `tests/test_volume.py`.

**Steps:**
1. **Failing test:**
   - A fixture snapshot with `/private/tmp/worldai_frontend` at 5 GiB is listed.
   - A missing snapshot gives `unknown`.
   - With `DISK_MAGICIAN_DU_BIN` set to a failing stub, the audit still succeeds (proves no walk).
2. **RED:** `… -k AuditTest -v`.
3. **Implement.**
4. **GREEN** plus regression.
5. **Commit.**

### Task 13: Deferred — volume deletion and quota recreation

Revision 10 removes deletion and recreation from v1. Rollback is `retire scratch` followed by `reclaim --clean`; keep the retired volume mounted and available for inspection. Do not implement `delete`, `recreate`, read-only remount emptiness checks, or `deleteVolume` in this release. Revisit only as a separately scoped follow-up with fresh approval and its own evidence plan.

### Task 14: Release and rollout **[COND P-1, P-2, P-3, P-4, P-5]**

**TDD: N/A.** This is release and deploy.

**Verification before release:**
- The separate disposable macOS/APFS automatic-trim pilot below passes and its measured results are recorded; fake-volume unit tests do not substitute for it.
- `check-version` and `sync-package-tree --check` pass.
- `/cs` passes.
- `MERGE APPROVED` is given.

**Separate macOS/APFS acceptance pilot (required before production activation):** This is an empirical platform pilot, not part of `tests/test_volume_reclaim.sh` and not replaceable by fake-volume tests. On a disposable test-only APFS quota volume, configure the existing scheduled sweep entry point (an accelerated documented schedule is allowed), fill with eligible ≥48 h disposable whole artifacts to measured ≥90%, and wait for the schedule to trigger automatically. Do not invoke manual `reclaim` or the sweep directly as the acceptance trigger. Verify exact oldest-content-mtime removals, remeasurement after each removal, ≤80% measured use, survival of leased/protected content, and a successful new `diskm scratch-new`-routed write. Record schedule interval, one sweep runtime, total recovery bound, before/after quota use, and the routed write result. Repeat with all candidates protected and verify no deletion plus explicit target-not-reached. A producer may receive `ENOSPC` before the next scheduled run. Use no production volume or arbitrary user data; if this pilot has not passed, do not activate the production volume.

**Steps:**
1. Bump `pyproject.toml` above the `origin/main` version.
2. After merge, from a clean `origin/main` checkout, run `tools/deploy_uv_tool.sh`.
3. Run `diskm volume plan-fit`. Its output must show the chosen cap fits.
4. Run `diskm volume create scratch` as a dry-run, then with `--execute` (the enabling step).
5. Run `diskm volume status --json`.

**Evidence:** keep outputs under `/tmp/disk_magician/evidence/quota-volumes-rollout-<UTC>/`.

**After 24 h:** record the audit's unrouted list as the success baseline, and record the `scratch-new` bytes on the volume.

**Rollback:** `retire scratch`, then `reclaim --clean`; keep the retired volume mounted and available for inspection. v1 has no volume-delete command.

## TDD Plan Check

| Task | Checked sequence |
|---|---|
| 1 | RED (module missing) → impl → GREEN → regression → commit |
| 2 | RED → impl → GREEN → commit; live 13.3 GiB matches the spec |
| 3 | RED → impl → GREEN → commit; `null` is never 0; corrupt registry fails closed |
| 4 | RED → impl → GREEN → commit; the create → path → retire sequence is tested (round-2 ordering fix); `create` writes the 64 MiB ballast; `ballast release`/`ensure` thresholds and deletion log |
| 5 | RED (`Unknown command`) → impl → GREEN + package check → commit |
| 6 | RED → impl → GREEN + swap_vm regression → commit |
| 7 | RED (two tests) → impl → GREEN → commit |
| 8 | TDD: N/A (platform spike); verify S1 automount, OS dot-dirs and fail-closed unmounted path [COND P-3] |
| 9 | RED → impl → GREEN → commit; rc 75 creates nothing; every created parent has a 0700 `.dm-quarantine` (case e) |
| 10 | RED → impl → GREEN + `test_admit.sh` → commit; after one reclaim, ≥90% still refuses; below 90%, independent 1 GiB headroom check applies (26/30 admits est 2, refuses est 2.1) |
| 11 | RED (script missing, then `kept:unproven-content` before the classifier row) → impl → GREEN + artifact_verdict/scratch_budget/quarantine/large-protections/deletion-log regressions → commit; real C14 removal of an aged entry; fresh/live/leased kept; dot-dirs skipped; row scoped to the volume; retire→reclaim drains; UUID mismatch → `kept:volume-identity`; stuck line in `diskm status`; full quota: typed ENOSPC on C14 sidecar alone releases ballast, one retry through real path removes aged entry, fresh/live/leased kept, EIO does not release, ballast recreated only at >=1,088 MiB, no retry loop; mkdir `ENOSPC` hook: pre-created parent removes normally, a parent lacking `.dm-quarantine` reports `kept:check-failed` without releasing the ballast (case q); pressure mode tests 90% trigger/80% stop, oldest eligible content-mtime ordering, remeasurement, protected retention, target-not-reached reporting; case (s) proves fake-volume pressure ordering/remeasurement/stop and all-protected fail-safe; the separate Mac/APFS scheduled pilot is a Task 14 release gate |
| 12 | RED → impl → GREEN → commit; no-walk stub |
| 13 | Deferred from v1: no RED/implementation/acceptance tests for volume deletion, read-only remount checks, or quota recreation. Rollback remains retire + C14 drain; keep the volume mounted for inspection. Re-scope separately before implementation |
| 14 | TDD: N/A (release/deploy); verified by fit output, status JSON and rollout evidence |

## Plan self-review

**Coverage by review source:**

| Source | Finding | Covered by |
|---|---|---|
| Codex | (a) Create before enable | Task 4 |
| Codex | (b) Reclaim mechanism | Task 11 |
| Codex + Opus (round 3) | C14 classifier row for volume entries, config-sourced root, real-path end-to-end test, stuck signal | Task 11 |
| Codex | (c) Reuse per-parent quarantine | Task 11 (no new quarantine root) |
| Opus | OS dot-dirs | Task 11; deletion-specific emptiness checks deferred with Task 13 |
| Opus | Markers dropped | (removed) |
| Web-advice | Live fit | Task 2 |
| Web-advice | No `find -newermt` | (recency helper used instead) |
| Web-advice | Permission check on unmounted path only | Task 8 |
| Web-advice | Unmount before delete | Superseded: deletion deferred from v1 |
| Web-advice | No cross-volume rename | (forbidden by design) |
| Codex (round 11) | Concurrent multi-owner leases, fail-closed scratch path handoff, one 1,088 MiB ballast threshold, typed ENOSPC result, physical allocation tests | Tasks 4, 9 and 11 |
| User acceptance correction (round 12) | Automatic pressure-triggered trim, oldest eligible whole disposable artifact ordering, low-water stop, protected preservation, recovered-space write-resume pilot | Task 11 fake-volume pressure case (s) plus separate Task 14 Mac/APFS scheduled pilot; only last-modified proxy is available, not access-time LRU |
| Codex (round 13) | Admission precedence after one reclaim; separate real Mac/APFS scheduled pilot is a release gate | Task 10 and Task 14; fake-volume case (s) is unit evidence only |
| Codex (round 7, superseded by revision 11) | Full-quota recovery: ballast released on C14 `ENOSPC`, one retry, recreated | Tasks 4 and 11 (case l, m) |
| Codex + Opus (round 8) | `.dm-quarantine` mkdir `ENOSPC` maps to `kept:check-failed`: `scratch-new` pre-creates it (Pilot 3 cited, defense in depth) | Tasks 9 and 11 (case q) |
| Codex (round 7) | Admission example contradicted the 1 GiB headroom rule | Task 10 |
| Opus (round 7, superseded by revision 10) | `recreate` requires `retire` first, with a defined message and rc | Deferred from v1 |
| Opus (round 7, superseded by revision 10) | S2 resolved by Pilot 2; target-machine re-check only | Deferred with deletion from v1 |
| — | Success measure (unrouted audit) | Tasks 12 and 14 |

**Other checks:**
- Shell/unit tests use fake volumes only. The separate disposable macOS/APFS scheduled pilot is empirical acceptance evidence, not a unit test; it must complete before production volume activation.
- Every deleter logs.
- No placeholders.
