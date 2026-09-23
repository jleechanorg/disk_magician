# cleanup_tmp.sh: single lsof scan + one tmp tree — implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `pressure_sweep.sh` step 1 (`cleanup_tmp.sh --clean --large`)
finish reliably under `STEP_TIMEOUT=600` by replacing per-candidate
`lsof +w +D <dir>` calls with one memoized, whole-run `lsof -n -P -F n`
snapshot filtered in memory, and by collapsing `TMP_DIRS` to one tree.
Full rationale, measured timings (approach A: `+D /private/tmp` alone did
not finish in 120s; approach B: global `-n -P` scan = 2.77s), and design
decisions: `docs/superpowers/specs/2026-09-11-cleanup-tmp-single-lsof-design.md`.

**Architecture:** `scripts/cleanup_tmp.sh` gains one new function
(`init_lsof_snapshot`) and a rewritten `has_open_files()` body; both
existing call sites (`purge_aged_archives` line 360, `--large` branch line
629) are unchanged. `TMP_DIRS` drops its duplicate `/tmp` entry. No other
script (`pressure_sweep.sh` included) changes — pressure-sweep tests mock
`cleanup_tmp.sh` entirely and are unaffected.

**Tech Stack:** Bash (macOS default `/bin/bash` 3.2 compatible — no
associative arrays), `lsof -F n` field-output mode, `mktemp`, `grep -F`.

**Do NOT bump `pyproject.toml`'s version.** `pressure_sweep.sh` and the
drilldown job run this repo's root `scripts/cleanup_tmp.sh` directly via
`@REPO_ROOT@` substitution (CLAUDE.md "Deployment" section) — not the
uv-tool-packaged copy under `src/disk_magician/`. Still run
`scripts/sync_package_tree.sh` (Task 4) so the mirrored copy in
`src/disk_magician/` does not drift; `scripts/*.sh` is already a canonical
glob pattern there, so no new file registration is needed.

---

### Task 1: Replace `has_open_files()` with a memoized single-scan implementation

**Files:**
- Modify: `scripts/cleanup_tmp.sh`
- Test: `tests/test_cleanup_tmp_large_protections.sh`

1. Add a new GREEN case (place after the existing GREEN 6 block) that
   asserts single-scan memoization: build a fixture with ≥2 `--large`
   candidates (reuse `make_large_dir`) plus ≥1 aged archive entry past
   `LARGE_TMP_ARCHIVE_RETENTION_HOURS` (reuse the GREEN 6 aged-archive
   fixture pattern), run `cleanup_tmp.sh --clean --large`, and assert the
   captured output contains **exactly one** line matching `"Open-file
   snapshot: "` (`grep -c` on the output, `assert_rc`-style helper already
   used throughout this file — follow its existing `assert_*` conventions,
   do not invent a new one). Run the test file; expect this new assertion
   to fail (no such log line exists yet) while all pre-existing assertions
   still pass unmodified.
2. In `scripts/cleanup_tmp.sh`, add the new script-scope state right after
   the `log()`/`dry_prefix()` helper definitions (~line 155):
   ```bash
   LSOF_SNAPSHOT_INITIALIZED=false
   LSOF_SNAPSHOT_OK=false
   LSOF_SNAPSHOT_FILE=""
   ```
3. Add `init_lsof_snapshot()` immediately before `has_open_files()`
   (~line 240), implementing exactly the 7 steps in the design doc's
   "Design → `init_lsof_snapshot()`" section: binary resolution precedence
   identical to today's `has_open_files()` (`DISK_MAGICIAN_LSOF_BIN` →
   `/usr/sbin/lsof` if executable → `command -v lsof`); local
   `timeout`/`gtimeout` resolution (mirror `pressure_sweep.sh:94-96`,
   duplicated here since this file does not source that one);
   `scan_timeout="${DISK_MAGICIAN_LSOF_SCAN_TIMEOUT_SEC:-90}"`; run
   `"$lsof_bin" -n -P -F n` once, capturing rc/stdout/stderr; on any
   non-zero rc or missing binary, log the fail-closed diagnostic and set
   `LSOF_SNAPSHOT_OK=false`; on success, `sed -n 's/^n//p'` the captured
   stdout into `LSOF_SNAPSHOT_FILE`, log the captured-path count, and set
   `LSOF_SNAPSHOT_OK=true`. Guard re-entry via
   `LSOF_SNAPSHOT_INITIALIZED` set at function entry (before any early
   return).
4. Replace the body of `has_open_files()` (keep its signature and doc
   comment, update the comment to describe the new snapshot-based check)
   with the 3-branch implementation from the design doc: call
   `init_lsof_snapshot`; if not OK, `return 0` (fail closed); else
   `grep -qxF -- "$dir"` OR `grep -qF -- "$dir/"` against
   `LSOF_SNAPSHOT_FILE`, returning 0 (open) on a hit, 1 (closed)
   otherwise.
5. Re-run `tests/test_cleanup_tmp_large_protections.sh`; the new
   single-scan assertion from step 1 must now pass. GREEN 5f (real held-open
   fd inside an aged archive, asserting `"Skipping in-use aged archive"`)
   must still pass unmodified — it is the regression proof that an open fd
   is still detected under the new mechanism.
6. Commit the focused change.

### Task 2: Update the fail-closed test for the new whole-run failure semantics

**Files:**
- Modify: `tests/test_cleanup_tmp_large_protections.sh` (GREEN 6 block only)

1. GREEN 6 already stubs `DISK_MAGICIAN_LSOF_BIN` with a binary that
   prints an error and exits 1 (`make_lsof_failure_shim`), and already
   asserts both the fresh candidate and the aged archive entry survive.
   Update only its log-text assertion:
   ```
   assert_contains "GREEN 6: logs fail-closed lsof diagnostic" \
     "Open-file check failed" "$G6_OUT_CONTENT"
   ```
   →
   ```
   assert_contains "GREEN 6: logs fail-closed lsof diagnostic" \
     "Open-file snapshot scan failed" "$G6_OUT_CONTENT"
   ```
2. Run the test; expect GREEN 6 to fail against the pre-Task-1 code (it
   won't, since Task 1 is already applied at this point — this task is
   sequenced second only for review clarity; if executing strictly TDD,
   fold this edit into Task 1 step 1 instead so the RED state is genuine).
   Confirm it passes post-Task-1.
3. Commit the focused change (or fold into Task 1's commit if done
   together).

### Task 3: Collapse `TMP_DIRS` to one tree and prove no duplicate scan

**Files:**
- Modify: `scripts/cleanup_tmp.sh`
- Test: `tests/test_cleanup_tmp_large_protections.sh`

1. Add a new GREEN case asserting the log contains exactly one
   `"Scanning /private/tmp ..."` line and zero `"Scanning /tmp ..."`
   lines, using the existing `make_find_shim` fixture (its `/tmp` branch
   becomes inert after this change — do not delete the shim's `/tmp` case,
   other tests in this file still call `make_find_shim` with 3 args and
   must not break). Run the test; expect it to fail (today's log contains
   both scan lines).
2. In `scripts/cleanup_tmp.sh` line 145, change:
   ```bash
   TMP_DIRS=("/private/tmp" "/tmp")
   ```
   to:
   ```bash
   TMP_DIRS=("/private/tmp")
   ```
   Leave the `USER_TMP` append block (lines 146-151) unchanged.
3. Re-run the test from step 1; expect pass. Re-run the full
   `tests/test_cleanup_tmp_large_protections.sh` suite; expect no
   regressions (verified in design doc: no existing test places candidate
   content under the fake `/tmp` fixture tree).
4. Also run `tests/test_cleanup_tmp_archive_purge.sh` (unrelated to
   `TMP_DIRS`, but exercises `purge_aged_archives`/`has_open_files`
   end-to-end against the real system `lsof` with no stub — must still
   pass after Task 1+3 combined).
5. Commit the focused change.

### Task 4: Sync the packaged mirror and run the full local test matrix

**Files:**
- No source changes (verification-only task)

1. Run `scripts/sync_package_tree.sh --check`; it must report the
   `scripts/cleanup_tmp.sh` drift introduced by Tasks 1-3.
2. Run `scripts/sync_package_tree.sh` (no `--check`) to apply the sync.
3. Run `scripts/sync_package_tree.sh --check` again; expect zero drift.
4. **Do not** edit `pyproject.toml`'s version — this fix's consumer
   (`pressure_sweep.sh`) reads the repo-root script directly, not the
   uv-tool package.
5. Run the full local suite for this area:
   `bash tests/test_cleanup_tmp_large_protections.sh`,
   `bash tests/test_cleanup_tmp_archive_purge.sh`,
   `bash tests/test_pressure_sweep.sh` (mocks `cleanup_tmp.sh`; must still
   pass unmodified — proves this change is invisible to the pressure-sweep
   orchestration layer).
6. Commit any resulting `src/disk_magician/scripts/cleanup_tmp.sh` diff
   from step 2 as part of this task's commit (sync output is generated,
   not hand-edited).

### Task 5: Production verification (acceptance criterion 1 — post-deploy, not a unit test)

**Files:** none (observation-only)

1. After Tasks 1-4 land and the next scheduled `pressure_sweep.sh`
   launchd firing occurs (every 1800s when free space is healthy; more
   often under pressure), tail
   `~/Library/Logs/disk-magician-pressure-sweep.log` and confirm step
   1/2's `cleanup_tmp.sh --clean --large` line is followed by "done" (not
   "FAILED or timed out (rc=124)") for 3 consecutive firings.
2. `grep -c "rc=124" ~/Library/Logs/disk-magician-pressure-sweep.log`
   before vs. after: the count must not increase across those 3 firings.
3. Record the before/after count and the 3 timestamps in the bead
   `disk_magician-dcz` as the closing evidence comment; do not close the
   bead without this live confirmation (a passing unit test proves the
   mechanism is correct, not that the real host's `/private/tmp` state no
   longer trips `STEP_TIMEOUT`).

### Task 6: File cross-repo bead J (worldarchitect.ai) — tracking only, no code

**Files:** none in this repo

1. File the bead using the exact title/body/acceptance text in the design
   doc's "Appendix — bead J" section, in `jleechanorg/worldarchitect.ai`.
2. Link the created bead ID into `disk_magician-dcz`'s bead notes
   (acceptance criterion 3) and into the appendix section of the design
   doc (replace "NOT implemented here" with the filed bead ID).
