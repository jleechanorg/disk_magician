# jleechan-mrtr Implementation Plan — Real snapshot in state-repo E2E

> **For agentic workers:** Use superpowers:subagent-driven-development. TDD. Steps use `- [ ]`.

**Goal:** Remove `write_fixture_ledger()` from `tests/test_state_repo_e2e.sh`; derive
`ledger/topdown-5g.json` from the real disk_magician scanner/render path against the
sandbox fixture `$FIXTURE_FILE`, preserving the existing pass assertions.

**Architecture:** The real ledger is produced by the frontier scan → `scripts/render_topdown_ledger.py` (writes `<out_dir>/topdown-5g.json`). Drive that path against a bounded sandbox root; write into the test's `$STATE_DIR`; never touch `$HOME/.disk_magician_state`.

**Tech Stack:** bash test harness, python3 renderer, macOS `dd` sparse fixture.

---

### Task 1: Map the real snapshot→ledger command

- [ ] Read `scripts/disk_snapshot.sh`, `scripts/render_topdown_ledger.py`, and the frontier scanner it consumes. Determine the exact command sequence that produces `ledger/topdown-5g.json` for a **bounded root**, and which env vars redirect STATE_DIR / scan root to the sandbox (candidates: `XDG_STATE_HOME`, `DISK_SNAPSHOT_JSON`, `MONITORED_PATHS_FILE`, `DISK_MAGICIAN_*`). If a bounded-root invocation is impossible without a production flag, record it and switch to the STOP path in the spec's Error handling.
- [ ] Commit notes if any scratch file; otherwise proceed.

### Task 2: RED — make the E2E use the real path (baseline snapshot)

- [ ] In `tests/test_state_repo_e2e.sh`, add a `run_real_snapshot()` helper that runs the mapped command from Task 1 against a bounded sandbox root writing to `$STATE_DIR/ledger/topdown-5g.json`, then `git -C "$STATE_DIR" add ledger/topdown-5g.json`.
- [ ] Replace the first `write_fixture_ledger "$((4*gib))" ...` (line ~134) with a `run_real_snapshot` call whose sandbox contains ~4 GiB of controlled content (reuse/extend the existing sandbox dirs).
- [ ] Run `bash tests/test_state_repo_e2e.sh`; expect FAIL at the baseline `history diff --validate` (ledger shape not yet real). Capture output.

### Task 3: GREEN — baseline validates

- [ ] Adjust the bounded-root content / render args until the baseline `history diff --validate "$STATE_DIR/ledger/topdown-5g.json"` passes with a real ledger.
- [ ] Run the test; baseline section passes. Commit: `test(e2e): real baseline snapshot for state-repo E2E (jleechan-mrtr)`.

### Task 4: RED→GREEN — grown state with the 6 GiB fixture

- [ ] Replace the second `write_fixture_ledger "$((10*gib))" ... "$GROWN_BUCKETS"` (line ~158) with a `run_real_snapshot` call over a sandbox root that INCLUDES `$FIXTURE_FILE` (the sparse 6 GiB img at line ~145-148).
- [ ] Keep the existing assertion (line ~164): first ledger bucket line == `+6.00 GiB` and contains `$FIXTURE_FILE`.
- [ ] Run `bash tests/test_state_repo_e2e.sh`; iterate scan root / render invocation until the real scanner surfaces `$FIXTURE_FILE` as the top +6.00 GiB bucket. Capture output.
- [ ] Commit: `test(e2e): real grown-state snapshot surfaces 6GiB fixture (jleechan-mrtr)`.

### Task 5: Cleanup + full-suite green

- [ ] Delete the now-unused `write_fixture_ledger()` definition (line ~120) and its comment block (line ~117). Confirm `grep -c write_fixture_ledger tests/test_state_repo_e2e.sh` == 0.
- [ ] Run `bash tests/test_state_repo_e2e.sh` (exit 0) and the shell suite the repo CI runs. Ensure `$FIXTURE_FILE` is still `rm -f`'d at teardown (line ~172).
- [ ] Commit: `test(e2e): drop write_fixture_ledger; E2E exercises real scanner (jleechan-mrtr)`.

### Task 6: PR

- [ ] Open one PR. Body: what changed, before/after (fabricated JSON → real scan), the exit-criteria checklist, and full `bash tests/test_state_repo_e2e.sh` output. If the STOP path was taken, document the production-flag blocker instead and open no test change.
